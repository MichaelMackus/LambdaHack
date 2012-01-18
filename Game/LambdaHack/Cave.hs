-- | Generation of caves (not yet inhabited dungeon levels) from cave kinds.
module Game.LambdaHack.Cave
  ( TileMapXY, SecretMapXY, ItemMapXY, Cave(..), buildCave
  ) where

import Control.Monad
import qualified Data.Map as M
import qualified Data.List as L

import Game.LambdaHack.Geometry
import Game.LambdaHack.Area
import Game.LambdaHack.AreaRnd
import Game.LambdaHack.Item
import Game.LambdaHack.Random
import qualified Game.LambdaHack.Tile as Tile
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Content.CaveKind
import Game.LambdaHack.Content.TileKind
import qualified Game.LambdaHack.Feature as F
import Game.LambdaHack.Place

-- | The map of starting secrecy strength of tiles in a cave. The map is sparse.
-- Unspecified tiles have secrecy strength of 0.
type SecretMapXY = M.Map (X, Y) Tile.SecretStrength

-- | The map of starting items in tiles of a cave. The map is sparse.
-- Unspecified tiles have no starting items.
type ItemMapXY = M.Map (X, Y) Item

-- | The type of caves (not yet inhabited dungeon levels).
data Cave = Cave
  { dkind     :: !(Kind.Id CaveKind)  -- ^ the kind of the cave
  , dmap      :: TileMapXY            -- ^ tile kinds in the case
  , dsecret   :: SecretMapXY          -- ^ secrecy strength of cave tiles
  , ditem     :: ItemMapXY            -- ^ starting items in the cave
  , dmeta     :: String               -- ^ debug information about the cave
  , dplaces   :: [Place]              -- ^ places generated in the cave
  }
  deriving Show

{-
Rogue cave is generated by an algorithm inspired by the original Rogue,
as follows:

  * The available area is divided into a grid, e.g, 3 by 3,
    where each of the 9 grid cells has approximately the same size.

  * In each of the 9 grid cells one room is placed at a random location
    and with a random size, but larger than The minimum size,
    e.g, 2 by 2 floor tiles.

  * Rooms that are on horizontally or vertically adjacent grid cells
    may be connected by a corridor. Corridors consist of 3 segments of straight
    lines (either "horizontal, vertical, horizontal" or "vertical, horizontal,
    vertical"). They end in openings in the walls of the room they connect.
    It is possible that one or two of the 3 segments have length 0, such that
    the resulting corridor is L-shaped or even a single straight line.

  * Corridors are generated randomly in such a way that at least every room
    on the grid is connected, and a few more might be. It is not sufficient
    to always connect all adjacent rooms.
-}
-- TODO: fix identifier naming and split, after the code grows some more
-- | Cave generation by an algorithm inspired by the original Rogue,
buildCave :: Kind.COps         -- ^ content definitions
          -> Int               -- ^ depth of the level to generate
          -> Int               -- ^ maximum depth of the dungeon
          -> Kind.Id CaveKind  -- ^ cave kind to use for generation
          -> Rnd Cave
buildCave cops@Kind.COps{ cotile=cotile@Kind.Ops{okind=tokind, opick}
                        , cocave=Kind.Ops{okind} }
          lvl depth ci = do
  let CaveKind{..} = okind ci
  lgrid@(gx, gy) <- rollDiceXY cgrid
  lminplace <- rollDiceXY $ cminPlaceSize
  let gs = grid lgrid (0, 0, cxsize - 1, cysize - 1)
  mandatory1 <- replicateM (cnonVoidMin `div` 2) $
                  xyInArea (0, 0, gx `div` 3, gy - 1)
  mandatory2 <- replicateM (cnonVoidMin `divUp` 2) $
                  xyInArea (gx - 1 - (gx `div` 3), 0, gx - 1, gy - 1)
  places0 <- mapM (\ (i, r) -> do
                     rv <- chance $ cvoidChance
                     r' <- if rv && i `notElem` (mandatory1 ++ mandatory2)
                           then mkVoidRoom r
                           else mkRoom lminplace r
                     return (i, r')) gs
  connects <- connectGrid lgrid
  addedConnects <-
    if gx * gy > 1
    then let caux = round $ cauxConnects * fromIntegral (gx * gy)
         in replicateM caux (randomConnection lgrid)
    else return []
  let allConnects = L.nub (addedConnects ++ connects)
      places = M.fromList places0
  cs <- mapM (\ (p0, p1) -> do
                 let r0 = places M.! p0
                     r1 = places M.! p1
                 connectPlaces r0 r1) allConnects
  wallId <- opick "fillerWall" (const True)
  let fenceBounds = (1, 1, cxsize - 2, cysize - 2)
      fence = buildFence wallId fenceBounds
  pickedCorTile <- opick ccorTile (const True)
  let addPl (m, pls) (_, (x0, _, x1, _)) | x0 == x1 = return (m, pls)
      addPl (m, pls) (_, r) = do
        (tmap, place) <-
          addPlace cops wallId pickedCorTile cdarkChance lvl depth r
        return (M.union tmap m, place : pls)
  (lplaces, dplaces) <- foldM addPl (fence, []) places0
  let lcorridors = M.unions (L.map (digCorridors pickedCorTile) cs)
  hiddenMap <- mapToHidden cotile
  let lm = M.unionWith (mergeCorridor cotile hiddenMap) lcorridors lplaces
  -- Convert openings into doors, possibly.
  (dmap, secretMap) <-
    let f (l, le) ((x, y), t) =
          if Tile.hasFeature cotile F.Hidden t
          then do
            -- Openings have a certain chance to be doors;
            -- doors have a certain chance to be open; and
            -- closed doors have a certain chance to be hidden
            rd <- chance cdoorChance
            if not rd
              then return (M.insert (x, y) pickedCorTile l, le)
              else do
                doorClosedId <- trigger cotile t
                doorOpenId   <- trigger cotile doorClosedId
                ro <- chance copenChance
                if ro
                  then do
                    return (M.insert (x, y) doorOpenId l, le)
                  else do
                    rs <- chance chiddenChance
                    if not rs
                      then return (M.insert (x, y) doorClosedId l, le)
                      else do
                        secret <- rollSecret(tokind t)
                        return (l, M.insert (x, y) secret le)
          else return (l, le)
    in foldM f (lm, M.empty) (M.toList lm)
  let cave = Cave
        { dkind = ci
        , dsecret = secretMap
        , ditem = M.empty
        , dmap
        , dmeta = show allConnects
        , dplaces
        }
  return cave

rollSecret :: TileKind -> Rnd Tile.SecretStrength
rollSecret t = do
  let getDice (F.Secret dice) _ = dice
      getDice _ acc = acc
      defaultDice = RollDice 5 2
      d = foldr getDice defaultDice (tfeature t)
  secret <- rollDice d
  return $ Tile.SecretStrength secret

trigger :: Kind.Ops TileKind -> Kind.Id TileKind -> Rnd (Kind.Id TileKind)
trigger Kind.Ops{okind, opick} t =
  let getTo (F.ChangeTo group) _ = Just group
      getTo _ acc = acc
  in case foldr getTo Nothing (tfeature (okind t)) of
       Nothing    -> return t
       Just group -> opick group (const True)

digCorridors :: Kind.Id TileKind -> Corridor -> TileMapXY
digCorridors tile (p1:p2:ps) =
  M.union corPos (digCorridors tile (p2:ps))
 where
  corXY  = fromTo p1 p2
  corPos = M.fromList $ L.zip corXY (repeat tile)
digCorridors _ _ = M.empty

passable :: [F.Feature]
passable = [F.Walkable, F.Openable, F.Hidden]

mapToHidden :: Kind.Ops TileKind
            -> Rnd (M.Map (Kind.Id TileKind) (Kind.Id TileKind))
mapToHidden cotile@Kind.Ops{ofoldrWithKey, opick} =
  let getHidden ti tk acc =
        if Tile.canBeHidden cotile tk
        then do
          ti2 <- opick "hidden" $ \ k -> Tile.kindHasFeature F.Hidden k
                                         && Tile.similar k tk
          fmap (M.insert ti ti2) acc
        else acc
  in ofoldrWithKey getHidden (return M.empty)

mergeCorridor :: Kind.Ops TileKind
              -> (M.Map (Kind.Id TileKind) (Kind.Id TileKind))
              -> Kind.Id TileKind -> Kind.Id TileKind -> Kind.Id TileKind
mergeCorridor cotile _    _ t
  | L.any (\ f -> Tile.hasFeature cotile f t) passable = t
mergeCorridor _ hiddenMap _ t = hiddenMap M.! t

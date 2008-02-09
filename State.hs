module State where

import Control.Monad
import Data.Binary

import Monster

type Time = Int

data State = State
               { splayer  :: Monster,
                 ssensory :: SensoryMode,
                 sdisplay :: DisplayMode,
                 stime    :: Time
               }
  deriving Show

defaultState ploc =
  State
    (Monster Player maxHP Nothing ploc)
    Implicit Normal
    0

smellTimeout :: Time
smellTimeout = 100 -- TODO: make configurable
maxHP = 20

updatePlayer :: State -> (Monster -> Monster) -> State
updatePlayer s f = s { splayer = f (splayer s) }

toggleVision :: State -> State
toggleVision s = s { ssensory = if ssensory s == Vision then Implicit else Vision }

toggleSmell :: State -> State
toggleSmell s = s { ssensory = if ssensory s == Smell then Implicit else Smell }

toggleOmniscient :: State -> State
toggleOmniscient s = s { sdisplay = if sdisplay s == Omniscient then Normal else Omniscient }

toggleTerrain :: State -> State
toggleTerrain s = s { sdisplay = if sdisplay s == Terrain then Normal else Terrain }

instance Binary State where
  put (State player sense disp time) =
    do
      put player
      put sense
      put disp
      put time
  get = liftM4 State get get get get

data SensoryMode =
    Implicit
  | Vision
  | Smell
  deriving (Show, Eq)

instance Binary SensoryMode where
  put Implicit = putWord8 0
  put Vision   = putWord8 1
  put Smell    = putWord8 2
  get = do
          tag <- getWord8
          case tag of
            0 -> return Implicit
            1 -> return Vision
            2 -> return Smell
            _ -> fail "no parse (SensoryMode)"

data DisplayMode =
    Normal
  | Omniscient
  | Terrain
  deriving (Show, Eq)

instance Binary DisplayMode where
  put Normal     = putWord8 0
  put Omniscient = putWord8 1
  put Terrain    = putWord8 2
  get = do
          tag <- getWord8
          case tag of
            0 -> return Normal
            1 -> return Omniscient
            2 -> return Terrain
            _ -> fail "no parse (DisplayMode)"


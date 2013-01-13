{-# LANGUAGE OverloadedStrings #-}
-- | The main loop of the game, processing player and AI moves turn by turn.
module Game.LambdaHack.Turn ( handleTurn ) where

import Control.Arrow ((&&&))
import Control.Monad
import Control.Monad.Writer.Strict (WriterT, runWriterT)
import qualified Data.IntMap as IM
import qualified Data.List as L
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Ord as Ord

import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.Binding
import qualified Game.LambdaHack.Command as Command
import Game.LambdaHack.CommandAction
import Game.LambdaHack.EffectAction
import Game.LambdaHack.Faction
import qualified Game.LambdaHack.Key as K
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Msg
import Game.LambdaHack.Random
import Game.LambdaHack.Running
import Game.LambdaHack.ServerAction
import Game.LambdaHack.State
import Game.LambdaHack.Strategy
import Game.LambdaHack.StrategyAction
import Game.LambdaHack.Time
import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.Vector

-- One clip proceeds through the following functions:
--
-- handleTurn
-- handleActors
-- handleAI or handlePlayer
-- handleActors
-- handleAI or handlePlayer
-- ...
-- handleTurn (again)

-- What's happening where:
--
-- handleTurn: HP regeneration, monster generation, determine who moves next,
--   dispatch to handlePlayer and handleActors, advance global game time
--
-- handleActors: find an actor that can move, advance actor time,
--   update perception, remember, push frame, repeat
--
-- handlePlayer: update perception, remember, display frames,
--   get and process commmands (zero or more), update smell map
--
-- handleAI: determine and process actor's action

-- | Start a clip (a part of a turn for which one or more frames
-- will be generated). Do whatever has to be done
-- every fixed number of time units, e.g., monster generation.
-- Run the leader and other actors moves. Eventually advance the time
-- and repeat.
handleTurn :: MonadAction m => m ()
handleTurn = do
  debug "handleTurn"
  time <- getsGlobal getTime  -- the end time of this clip, inclusive
  let clipN = (time `timeFit` timeClip) `mod` (timeTurn `timeFit` timeClip)
  -- Regenerate HP and add monsters each turn, not each clip.
  when (clipN == 1) checkEndGame
  when (clipN == 2) regenerateLevelHP
  when (clipN == 3) generateMonster
  debug $ "handleTurn: time =" <+> showT time
  handleActors timeZero
  modifyGlobal (updateTime (timeAdd timeClip))
  endOrLoop handleTurn

-- TODO: switch levels alternating between player factions,
-- if there are many and on distinct levels.
-- TODO: If a faction has no actors left in the dungeon,
-- announce game end for this faction. Not sure if here's the right place.
-- TODO: Let the spawning factions that remain duke it out somehow,
-- if the player requests to see it.
-- | If no actor of a non-spawning faction on the level,
-- switch levels. If no level to switch to, end game globally.
checkEndGame :: MonadAction m => m ()
checkEndGame = do
  -- Actors on the current level go first so that we don't switch levels
  -- unnecessarily.
  as <- getsGlobal allActorsAnyLevel
  loc <- getLocal
  let aNotSp = filter (not . isSpawningFaction loc . bfaction . snd . snd) as
  case aNotSp of
    [] -> gameOver True
    (lid, _) : _ ->
      -- Switch to the level (can be the currently selected level, too).
      modifyGlobal $ updateSelectedArena lid

-- TODO: We should replace this structure using a priority search queue/tree.
-- | Perform moves for individual actors, as long as there are actors
-- with the next move time less than or equal to the current time.
-- Some very fast actors may move many times a clip and then
-- we introduce subclips and produce many frames per clip to avoid
-- jerky movement. Otherwise we push exactly one frame or frame delay.
-- We start by updating perception, because the selected level of dungeon
-- has changed since last time (every change, whether by player or AI
-- or @generateMonster@ is followd by a call to @handleActors@).
handleActors :: MonadAction m
             => Time  -- ^ start time of current subclip, exclusive
             -> m ()
handleActors subclipStart = withPerception $ do
  debug "handleActors"
  remember
  Kind.COps{coactor} <- getsGlobal scops
  time <- getsGlobal getTime  -- the end time of this clip, inclusive
   -- Older actors act earlier.
  lactor <- getsGlobal (IM.toList . lactor . getArena)
  quit <- getsServer squit
  let mnext = if null lactor  -- wait until any actor spawned
              then Nothing
              else let -- Heroes move first then monsters, then the rest.
                       order = Ord.comparing (btime . snd &&& bfaction . snd)
                       (actor, m) = L.minimumBy order lactor
                   in if btime m > time
                      then Nothing  -- no actor is ready for another move
                      else Just (actor, m)
  case mnext of
    _ | isJust quit -> return ()
    Nothing -> when (subclipStart == timeZero) $ displayFramesPush [Nothing]
    Just (actor, m) -> do
      let side = bfaction m
      switchGlobalSelectedSide side
      arena <- getsGlobal sarena
      void $ askClient side $ SetArenaLeaderCli arena

      arenaOld <- getsLocal sarena
      leaderOld <- getsClient getLeader
      -- Old leader may have been killed by enemies since @side@ last moved
      -- or local arena changed and the side has not elected a new leader yet
      -- or global arena changed the old leader is on the old arena.
      leader <- if arenaOld /= arena
                then do
                  modifyClient invalidateSelectedLeader
                  modifyLocal $ updateSelectedArena arena
                  return actor
                else return $! fromMaybe actor leaderOld
      loc <- getLocal
      modifyClient $ updateSelectedLeader leader loc
      return leader

      isPlayer <- getsGlobal $ flip isPlayerFaction side
      if actor == leader && isPlayer
        then do
          -- Player moves always start a new subclip.
          void $ sendToPl [] $ DisplayPushCli
          void $ askClient side $ HandlePlayerCli leader
      here read and execute commands until ResponseCli(reqNo, (arenaNew, leaderNew))
          leaderNew <- getsClient getLeader

          modifyGlobal $ updateSelectedArena arenaNew
          squitNew <- getsServer squit
          -- Advance time once, after the leader switched perhaps many times.
          -- Ending and especially saving does not take time.
          -- TODO: this is correct only when all heroes have the same
          -- speed and can't switch leaders by, e.g., aiming a wand
          -- of domination. We need to generalize by displaying
          -- "(next move in .3s [RET]" when switching leaders.
          -- RET waits .3s and gives back control,
          -- Any other key does the .3s wait and the action form the key
          -- at once. This requires quite a bit of refactoring
          -- and is perhaps better done when the other factions have
          -- selected leaders as well.
          unless (isJust squitNew) $ maybe (return ()) advanceTime leaderNew
          handleActors $ btime m
        else do
--          recordHistory
          advanceTime actor  -- advance time while the actor still alive
          let subclipStartDelta = timeAddFromSpeed coactor m subclipStart
          if isPlayer && not (bproj m)
             || subclipStart == timeZero
             || btime m > subclipStartDelta
            then do
              -- Start a new subclip if its our own faction moving
              -- or it's another faction, but it's the first move of
              -- this whole clip or the actor has already moved during
              -- this subclip, so his multiple moves would be collapsed.
              -- TODO: store frames somewhere for each faction and display
              -- the frames only after a "Faction X taking over..." prompt.
              void $ sendToPl [] $ DisplayPushCli
              handleAI actor
              handleActors $ btime m
            else do
              -- No new subclip.
              handleAI actor
              handleActors subclipStart

-- | Handle the move of a single monster.
handleAI :: MonadAction m => ActorId -> m ()
handleAI actor = do
  stratTarget <- targetStrategy actor
  -- Choose a target from those proposed by AI for the actor.
  btarget <- rndToAction $ frequency $ bestVariant stratTarget
  modifyClient $ updateTarget actor (const btarget)
  stratAction <- actionStrategy actor
  -- debug
  loc <- getLocal
  debug $ "handleAI factionAI:"
     <+> showT (gAiIdle $ sfaction loc IM.! bfaction (getActorBody actor loc))
     <>          ", symbol:"    <+> showT (bsymbol (getActorBody actor loc))
     <>          ", loc:"       <+> showT (bpos (getActorBody actor loc))
     <> "\nhandleAI target:"    <+> showT stratTarget
     <> "\nhandleAI move:"      <+> showT stratAction
  -- Run the AI: choses an action from those given by the AI strategy.
  join $ rndToAction $ frequency $ bestVariant $ stratAction

-- | Continue running in the given direction.
continueRun :: MonadClient m => ActorId -> (Vector, Int) -> m ()
continueRun leader dd = do
  dir <- continueRunDir leader dd
  -- Attacks and opening doors disallowed when continuing to run.
  runSer leader dir

-- | Handle the move of the hero.
handlePlayer :: MonadClient m => ActorId -> m ()
handlePlayer leader = do
  -- When running, stop if aborted by a disturbance.
  -- Otherwise let the player issue commands, until any of them takes time.
  -- First time, just after pushing frames, ask for commands in Push mode.
  tryWith (\ msg -> stopRunning >> playerCommand msg) $ do
    srunning <- getsClient srunning
    maybe abort (continueRun leader) srunning
--  addSmell leader

-- | Determine and process the next player command. The argument is the last
-- abort message due to running, if any.
playerCommand :: forall m. MonadClient m => Msg -> m ()
playerCommand msgRunAbort = do
  -- The frame state is now Push.
  kmPush <- case msgRunAbort of
    "" -> getKeyCommand (Just True)
    _  -> do
      slides <- promptToSlideshow msgRunAbort
      getKeyOverlayCommand $ head $ runSlideshow slides
  -- The frame state is now None and remains so between each pair
  -- of lines of @loop@ (but can change within called actions).
  let loop :: K.KM -> m ()
      loop km = do
        -- Messages shown, so update history and reset current report.
        recordHistory
        -- On abort, just reset state and call loop again below.
        -- Each abort that gets this far generates a slide to be shown.
        (timed, slides) <- runWriterT $ tryWithSlide (return False) $ do
          -- Look up the key.
          Binding{kcmd} <- askBinding
          case M.lookup km kcmd of
            Just (_, _, cmd) -> do
              -- Query and clear the last command key.
              lastKey <- getsClient slastKey
              -- TODO: perhaps replace slastKey
              -- with test 'kmNext == km'
              -- or an extra arg to 'loop'.
              -- Depends on whether slastKey
              -- is needed in other parts of code.
              modifyClient (\st -> st {slastKey = Just km})
              (t, arena) <- if (Just km == lastKey)
                then cmdSemantics Command.Clear
                else cmdSemantics cmd
              return t
            Nothing -> let msgKey = "unknown command <" <> K.showKM km <> ">"
                       in abortWith msgKey
        -- The command was aborted or successful and if the latter,
        -- possibly took some time.
        if timed
          then assert (null (runSlideshow slides) `blame` slides) $ do
            -- Exit the loop and let other actors act. No next key needed
            -- and no slides could have been generated.
            modifyClient (\st -> st {slastKey = Nothing})
          else
            -- If no time taken, rinse and repeat.
            -- Analyse the obtained slides.
            case reverse (runSlideshow slides) of
              [] -> do
                -- Nothing special to be shown; by default draw current state.
                modifyClient (\st -> st {slastKey = Nothing})
                sli <- promptToSlideshow ""
                kmNext <- getKeyOverlayCommand $ head $ runSlideshow sli
                loop kmNext
              sLast : sls -> do
                -- Show, one by one, all but the last slide.
                -- Note: the code that generates the slides is responsible
                -- for inserting the @more@ prompt.
                b <- getManyConfirms [km] $ toSlideshow $ reverse sls
                -- Display the last slide while waiting for the next key,
                -- or display current state if slideshow interrupted.
                kmNext <- if b
                          then getKeyOverlayCommand sLast
                          else do
                            modifyClient (\st -> st {slastKey = Nothing})
                            sli <- promptToSlideshow ""
                            getKeyOverlayCommand $ head $ runSlideshow sli
                -- Look up and perform the next command.
                loop kmNext
  loop kmPush

-- | Advance (or rewind) the move time for the given actor.
advanceTime :: MonadAction m => ActorId -> m ()
advanceTime actor = do
  Kind.COps{coactor} <- getsGlobal scops
  let upd m@Actor{btime} = m {btime = timeAddFromSpeed coactor m btime}
  modifyGlobal $ updateActorBody actor upd

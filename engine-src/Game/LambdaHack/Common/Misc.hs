-- | Hacks that haven't found their home yet.
module Game.LambdaHack.Common.Misc
  ( makePhrase, makeSentence, squashedWWandW
  , appDataDir
  , xM, xD, minusM, minusM1, minusM2, oneM, tenthM
  , show64With2
  , workaroundOnMainThreadMVar
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import           Control.Concurrent
import qualified Data.Char as Char
import           Data.Int (Int64)
import qualified Data.Map as M
import qualified NLP.Miniutter.English as MU
import           System.Directory (getAppUserDataDirectory)
import           System.Environment (getProgName)
import           System.IO.Unsafe (unsafePerformIO)

-- | Re-exported English phrase creation functions, applied to our custom
-- irregular word sets.
makePhrase, makeSentence :: [MU.Part] -> Text
makePhrase = MU.makePhrase irregular
makeSentence = MU.makeSentence irregular

irregular :: MU.Irregular
irregular = MU.Irregular
  { irrPlural =
      M.fromList
        [ ("merchandise", "merchandise")
        , ("Merchandise", "Merchandise") ]
            -- this is both countable and uncountable, but I use it here
            -- only as uncountable, do I overwrite the default
      `M.union` MU.irrPlural MU.defIrregular
  , irrIndefinite = MU.irrIndefinite MU.defIrregular
  }

-- | Apply the @WWandW@ constructor, first representing repetitions
-- as @CardinalWs@.
-- The parts are not sorted, only grouped, to keep the order.
-- The internal structure of speech parts is compared, not their string
-- rendering, so some coincidental clashes are avoided (and code is simpler).
squashedWWandW :: [MU.Part] -> (MU.Part, MU.Person)
squashedWWandW parts =
  let repetitions = group parts
      f [] = error $ "empty group" `showFailure` parts
      f [part] = (part, MU.Sg3rd)  -- avoid prefixing hero names with "a"
      f l@(part : _) = (MU.CardinalWs (length l) part, MU.PlEtc)
      cars = map f repetitions
      person = case cars of
        [] -> error $ "empty cars" `showFailure` parts
        [(_, person1)] -> person1
        _ -> MU.PlEtc
  in (MU.WWandW $ map fst cars, person)

-- | Personal data directory for the game. Depends on the OS and the game,
-- e.g., for LambdaHack under Linux it's @~\/.LambdaHack\/@.
appDataDir :: IO FilePath
appDataDir = do
  progName <- getProgName
  let name = takeWhile Char.isAlphaNum progName
  getAppUserDataDirectory name

xM :: Int -> Int64
xM k = fromIntegral k * 1000000

xD :: Double -> Double
xD k = k * 1000000

minusM, minusM1, minusM2, oneM, tenthM :: Int64
minusM = xM (-1)
minusM1 = xM (-1) - 1
minusM2 = xM (-1) - 2
oneM = xM 1
tenthM = 100000

show64With2 :: Int64 -> Text
show64With2 n =
  let k = 100 * n `div` oneM
      l = k `div` 100
      x = k - l * 100
      y = x `div` 10
  in tshow l
     <> if | x == 0 -> ""
           | x == y * 10 -> "." <> tshow y
           | x < 10 -> ".0" <> tshow x
           | otherwise -> "." <> tshow x

-- Global variable for passing the action to run on main thread, if any.
workaroundOnMainThreadMVar :: MVar (IO ())
{-# NOINLINE workaroundOnMainThreadMVar #-}
workaroundOnMainThreadMVar = unsafePerformIO newEmptyMVar
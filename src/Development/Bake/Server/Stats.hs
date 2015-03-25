{-# LANGUAGE RecordWildCards, TupleSections, ViewPatterns, CPP #-}

module Development.Bake.Server.Stats(
    stats,
    record, recordIO
    ) where

import Control.DeepSeq
import Control.Applicative
import Control.Monad
import Development.Bake.Core.Type
import Development.Bake.Server.Brain
import Data.IORef
import Data.Monoid
import Data.List.Extra
import General.HTML
import General.Extra
import General.Str
import GHC.Stats
import System.IO.Unsafe
import System.Time.Extra
import Control.Exception
import Data.Tuple.Extra
import Numeric.Extra
import qualified Data.Map as Map
import Prelude


data Stat = Stat {statHistory :: [Double], statCount :: !Int, statSum :: !Double, statMax :: !Double}

instance Monoid Stat where
    mempty = Stat [] 0 0 0
    mappend (Stat x1 x2 x3 x4) (Stat y1 y2 y3 y4) = Stat (take 10 $ x1 ++ y1) (x2+y2) (x3+y3) (x4 `max` y4)


{-# NOINLINE recorded #-}
recorded :: IORef (Map.Map String Stat)
recorded = unsafePerformIO $ newIORef Map.empty

record :: NFData b => (a -> ([String], b)) -> a -> b
record f x = unsafePerformIO $ recordIO $ return $ f x

recordIO :: NFData a => IO ([String], a) -> IO a
recordIO x = do
    (d, (msg,x)) <- duration $ do x <- x; evaluate $ rnf x; return x
    forM_ (inits msg) $ \msg ->
        atomicModifyIORef recorded $ (,()) .  Map.insertWith mappend (unwords msg) (Stat [d] 1 d d)
    return x

mean :: [Double] -> Double
mean xs = sum xs / intToDouble (length xs)


stats :: Oven State Patch Test -> Memory -> IO HTML
stats Oven{..} Memory{..} = do
    recorded <- readIORef recorded
#if __GLASGOW_HASKELL__ < 706
    getGCStatsEnabled <- return True
#else
    getGCStatsEnabled <- getGCStatsEnabled
#endif
    stats <- if getGCStatsEnabled then Just <$> getGCStats else return Nothing
    info <- strInfo
    rel <- relativeTime
    return $ do
        p_ $ str_ $ "Requests = " ++ show (length history) ++ ", updates = " ++ show (length updates)

        h2_ $ str_ "Sampled statistics"
        let ms x = show $ (ceiling $ x * 1000 :: Integer)
        table ["Counter","Count","Mean (ms)","Sum (ms)","Max (ms)","Last 10 (ms)"]
            [ (if null name then i_ $ str_ "All" else str_ name) :
              map str_ [show statCount, ms $ statSum / intToDouble statCount, ms statSum
                       ,ms statMax, unwords $ map ms statHistory] 
            | (name,Stat{..}) <- Map.toAscList recorded]

        h2_ $ str_ "Slowest 25 tests"
        table ["Test","Count","Mean","Sum","Max","Last 10"] $
            -- deliberately group by Pretty string, not by raw string, so we group similar looking tests
            let xs = [(maybe "Preparing " (stringyPretty ovenStringyTest) qTest, aDuration) | (_,Question{..}, Answer{..}) <- history]
                f name xs = name : map str_ [show (length xs), showDuration (mean xs), showDuration (sum xs)
                                            ,showDuration (maximum xs), unwords $ map showDuration $ take 10 xs]
            in [f (i_ $ str_ "All") (map snd xs) | not $ null xs] ++
               [f (str_ test) dur | (test,dur) <- take 25 $ sortOn (negate . mean . snd) $ groupSort xs]

        h2_ $ str_ "Requests per client"
        let historyRunning = map (\(t,q,a) -> (t,q,Just a)) history ++ map (\(t,q) -> (t,q,Nothing)) running
        table ["Client","Requests","Utilisation (last hour)","Utilisation"]
            [ map str_ [fromClient c, show $ length xs, f $ 60*60, f $ maximum $ map fst3 xs]
            | c <- Map.keys pings
              -- how long ago you started, duration
            , let xs = [(rel t, maybe (rel t) aDuration a, qThreads q) | (t,q,a) <- historyRunning, qClient q == c]
            , not $ null xs
            , let f z = show (floor $ sum [ max 0 $ intToDouble threads * (dur - max 0 (start - z))
                                          | (start,dur,threads) <- xs] * 100 / z) ++ "%"]

            -- how many seconds ago you started, duration
            -- start dur z   max 0 (start-z)
            -- 75 10 60 = 0   15
            -- 65 10 60 = 5   5
            -- 55 10 60 = 10  0

        h2_ $ str_ "String pool statistics"
        pre_ $ str_ info

        h2_ $ str_ "GHC statistics"
        case stats of
            Nothing -> p_ $ str_ "No GHC stats, rerun with +RTS -T"
            Just x -> pre_ $ str_ $ replace ", " "\n" $ takeWhile (/= '}') $ drop 1 $ dropWhile (/= '{') $ show x


table :: [String] -> [[HTML]] -> HTML
table cols body = table_ $ do
    thead_ $ tr_ $ mconcat $ map (td_ . str_) cols
    tbody_ $ mconcat $ [tr_ $ mconcat $ map td_ x | x <- body]

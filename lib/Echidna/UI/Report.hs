module Echidna.UI.Report where

import Control.Monad (forM)
import Control.Monad.Reader (MonadReader, MonadIO (liftIO), asks, ask)
import Data.IORef (readIORef)
import Data.Function (on)
import Data.List (nub, sortBy)
import Data.Map qualified as Map
import Data.Maybe (catMaybes, fromJust)
import Data.Text (unpack)
import Data.Text qualified as T
import Data.Time (LocalTime)
import Text.Printf (printf)

import EVM.Format (showTraceTree)
import EVM.Types (W256, VM(labels), VMType(Concrete), FunctionSelector, CheatCallStats(..))

import Echidna.ABI (encodeSig)
import Echidna.ContractName (contractNameForAddr)
import Echidna.LogicalCoverage (mergeLogicalCoverage, formatLogicalCoverageReport)
import Echidna.Pretty (ppTxCall)
import Echidna.Types.Campaign
import Echidna.Types.Config
import Echidna.Types.Corpus (corpusSize)
import Echidna.Types.Coverage (coverageStats)
import Echidna.Types.Test (EchidnaTest(..), TestState(..), TestType(..))
import Echidna.Types.Tx (Tx(..), TxCall(..))
import Echidna.Types.Worker
import Echidna.Utility (timePrefix)
import Echidna.Worker

ppLogLine :: (MonadReader Env m, MonadIO m) => VM Concrete -> (LocalTime, CampaignEvent) -> m String
ppLogLine vm (time, event@(WorkerEvent workerId FuzzWorker _)) =
  ((timePrefix time <> "[Worker " <> show workerId <> "] ") <>) <$> ppCampaignEventLog vm event
ppLogLine vm (time, event@(WorkerEvent workerId SymbolicWorker _)) =
  ((timePrefix time <> "[Worker " <> show workerId <> ", symbolic] ") <>) <$> ppCampaignEventLog vm event
ppLogLine vm (time, event) =
  ((timePrefix time <> " ") <>) <$> ppCampaignEventLog vm event

ppCampaignEventLog :: (MonadReader Env m, MonadIO m) => VM Concrete -> CampaignEvent -> m String
ppCampaignEventLog vm ev = (ppCampaignEvent ev <>) <$> ppTxIfHas where
  ppTxIfHas = case ev of
    (WorkerEvent _ _ (TestFalsified test)) -> ("\n  Call sequence:\n" <>) . unlines <$> mapM (ppTx vm $ length (nub $ (.src) <$> test.reproducer) /= 1) test.reproducer
    _ -> pure ""

ppTotalCalls :: [WorkerState] -> String
ppTotalCalls workerStates = "Total calls: " <> show calls
  where
    calls = sum $ (.ncalls) <$> workerStates

mergeCheatCallStats :: [WorkerState] -> Map.Map FunctionSelector CheatCallStats
mergeCheatCallStats workerStates =
  Map.unionsWith combine (map (.cheatCallStats) workerStates)
  where
    combine a b = CheatCallStats
      { totalCalls = a.totalCalls + b.totalCalls
      , successCalls = a.successCalls + b.successCalls
      , failedCalls = a.failedCalls + b.failedCalls
      }

formatCheatCallStats :: Map.Map FunctionSelector CheatCallStats -> [String]
formatCheatCallStats stats =
  map formatEntry $ sortBy (flip compare `on` (\(_, st) -> st.totalCalls)) (Map.toList stats)
  where
    formatEntry (sel, st) =
      let total = st.totalCalls
          ok = st.successCalls
          bad = st.failedCalls
          pct :: Double
          pct = if total == 0 then 0 else fromIntegral ok * 100 / fromIntegral total
      in show sel <> ": " <> show ok <> "/" <> show total <> " ok (" <> printf "%.1f%%" pct <> "), " <> show bad <> " failed"

formatCheatStatsSummary :: Map.Map FunctionSelector CheatCallStats -> String
formatCheatStatsSummary stats =
  case sortBy (flip compare `on` (\(_, st) -> st.totalCalls)) (Map.toList stats) of
    [] -> ""
    (sel, st):rest ->
      let total = st.totalCalls
          ok = st.successCalls
          pct :: Double
          pct = if total == 0 then 0 else fromIntegral ok * 100 / fromIntegral total
          more = if null rest then "" else " +" <> show (length rest)
      in "tracked: " <> show sel <> " " <> show ok <> "/" <> show total <> " (" <> printf "%.1f%%" pct <> ")" <> more

ppCheatCallStats :: [WorkerState] -> String
ppCheatCallStats workerStates =
  let merged = mergeCheatCallStats workerStates
  in if Map.null merged
     then "Tracked calls: none"
     else "Tracked calls:\n" <> unlines (("  " <>) <$> formatCheatCallStats merged)

ppSeed :: [WorkerState] -> String
ppSeed [] = "unknown" -- should not happen
ppSeed (campaign:_) = show campaign.genDict.defSeed

ppCampaign :: (MonadIO m, MonadReader Env m) => [WorkerState] -> m String
ppCampaign workerStates = do
  tests <- liftIO . traverse readIORef =<< asks (.testRefs)
  testsPrinted <- ppTests tests
  coveragePrinted <- ppCoverage
  let seedPrinted = "Seed: " <> ppSeed workerStates
  corpusPrinted <- ppCorpus
  let callsPrinted = ppTotalCalls workerStates
  let cheatStatsPrinted = ppCheatCallStats workerStates
  logicalCoveragePrinted <- ppLogicalCoverage workerStates
  pure $ unlines
    [ testsPrinted
    , coveragePrinted
    , corpusPrinted
    , seedPrinted
    , callsPrinted
    , cheatStatsPrinted
    , logicalCoveragePrinted
    ]

ppLogicalCoverage :: (MonadIO m, MonadReader Env m) => [WorkerState] -> m String
ppLogicalCoverage workerStates = do
  conf <- asks (.cfg.campaignConf)
  if not conf.logicalCoverage then
    pure "Logical coverage: disabled"
  else do
    let merged = mergeLogicalCoverage conf.logicalCoverageMaxReasons (map (.logicalCoverage) workerStates)
    pure $ unlines (formatLogicalCoverageReport conf.logicalCoverageTopN merged)

-- | Given rules for pretty-printing associated addresses, and whether to print
-- them, pretty-print a 'Transaction'.
ppTx :: (MonadReader Env m, MonadIO m) => VM Concrete -> Bool -> Tx -> m String
ppTx _ _ Tx { call = NoCall, delay } =
  pure $ "*wait*" <> ppDelay delay
ppTx vm printName tx = do
  contractName <- case tx.call of
    SolCall _ -> Just <$> contractNameForAddr vm tx.dst
    _ -> pure Nothing
  names <- asks (.cfg.namesConf)
  tGas  <- asks (.cfg.txConf.txGas)
  pure $
    unpack (maybe "" (<> ".") contractName) <> ppTxCall vm.labels tx.call
    <> (if not printName then "" else prettyName names Sender tx.src <> prettyName names Receiver tx.dst)
    <> (if tx.gas == tGas then "" else " Gas: " <> show tx.gas)
    <> (if tx.gasprice == 0 then "" else " Gas price: " <> show tx.gasprice)
    <> (if tx.value == 0 then "" else " Value: " <> show tx.value)
    <> ppDelay tx.delay
  where
    prettyName names t addr = case names t addr of
      "" -> ""
      s -> s <> label addr
    label addr = case Map.lookup addr vm.labels of
      Nothing -> ""
      Just l -> " «" <> T.unpack l <> "»"

ppDelay :: (W256, W256) -> [Char]
ppDelay (time, block) =
  (if time == 0 then "" else " Time delay: " <> show (toInteger time) <> " seconds")
  <> (if block == 0 then "" else " Block delay: " <> show (toInteger block))

-- | Pretty-print the coverage a 'Campaign' has obtained.
ppCoverage :: (MonadIO m, MonadReader Env m) => m String
ppCoverage = do
  env <- ask
  (points, uniqueCodehashes) <- liftIO $ coverageStats env.coverageRefInit env.coverageRefRuntime
  pure $ "Unique instructions: " <> show points <> "\n" <>
         "Unique codehashes: " <> show uniqueCodehashes

-- | Pretty-print the corpus a 'Campaign' has obtained.
ppCorpus :: (MonadIO m, MonadReader Env m) => m String
ppCorpus = do
  corpus <- liftIO . readIORef =<< asks (.corpusRef)
  pure $ "Corpus size: " <> show (corpusSize corpus)

-- | Pretty-print the status of a solved test.
ppFail :: (MonadReader Env m, MonadIO m) => Maybe (Int, Int) -> VM Concrete -> [Tx] -> m String
ppFail _ _ []  = pure "failed with no transactions made ⁉️ "
ppFail b vm xs = do
  let status = case b of
        Nothing    -> ""
        Just (n,m) -> ", shrinking " <> progress n m
  prettyTxs <- mapM (ppTx vm $ length (nub $ (.src) <$> xs) /= 1) xs
  dappInfo <- asks (.dapp)
  pure $ "failed!💥  \n  Call sequence" <> status <> ":\n"
         <> unlines (("    " <>) <$> prettyTxs) <> "\n"
         <> "Traces: \n" <> T.unpack (showTraceTree dappInfo vm)

-- | Pretty-print the status of a solved test.
ppFailWithTraces :: (MonadReader Env m, MonadIO m) => Maybe (Int, Int) -> VM Concrete -> [(Tx, VM Concrete)] -> m String
ppFailWithTraces  _ _ []  = pure "failed with no transactions made ⁉️ "
ppFailWithTraces b finalVM results = do
  dappInfo <- asks (.dapp)
  let xs = fst <$> results
  let status = case b of
        Nothing    -> ""
        Just (n,m) -> ", shrinking " <> progress n m
  let printName = length (nub $ (.src) <$> xs) /= 1
  prettyTxs <- forM results $ \(tx, vm) -> do
    txPrinted <- ppTx vm printName tx
    pure $ txPrinted <> "\nTraces:\n" <> T.unpack (showTraceTree dappInfo vm)
  pure $ "failed!💥  \n  Call sequence" <> status <> ":\n"
         <> unlines (("    " <>) <$> prettyTxs) <> "\n"
         <> "Test traces: \n" <> T.unpack (showTraceTree dappInfo finalVM)

-- | Pretty-print the status of a test.

ppTS :: (MonadReader Env m, MonadIO m) => TestState -> VM Concrete -> [Tx] -> m String
ppTS (Failed e) _ _  = pure $ "could not evaluate ☣\n  " <> show e
ppTS Solved     vm l = ppFail Nothing vm l
ppTS Passed     _ _  = pure " passed! 🎉"
ppTS Open      _ []  = pure "passing"
ppTS Unsolvable _ _ = pure "verified ✅"
ppTS Open      vm r  = ppFail Nothing vm r
ppTS (Large n) vm l  = do
  m <- asks (.cfg.campaignConf.shrinkLimit)
  ppFail (if n < m then Just (n, m) else Nothing) vm l

ppOPT :: (MonadReader Env m, MonadIO m) => TestState -> VM Concrete -> [Tx] -> m String
ppOPT (Failed e) _ _  = pure $ "could not evaluate ☣\n  " <> show e
ppOPT Solved     vm l = ppOptimized Nothing vm l
ppOPT Passed     _ _  = pure " passed! 🎉"
ppOPT Unsolvable _ _ = error "unreachable: optimization tests should not be unsolvable"
ppOPT Open      vm r  = ppOptimized Nothing vm r
ppOPT (Large n) vm l  = do
  m <- asks (.cfg.campaignConf.shrinkLimit)
  ppOptimized (if n < m then Just (n, m) else Nothing) vm l

-- | Pretty-print the status of an optimized test.
ppOptimized :: (MonadReader Env m, MonadIO m) => Maybe (Int, Int) -> VM Concrete -> [Tx] -> m String
ppOptimized _ _ []  = pure "Call sequence:\n(no transactions)"
ppOptimized b vm xs = do
  let status = case b of
        Nothing    -> ""
        Just (n,m) -> ", shrinking " <> progress n m
  prettyTxs <- mapM (ppTx vm $ length (nub $ (.src) <$> xs) /= 1) xs
  dappInfo <- asks (.dapp)
  pure $ "\n  Call sequence" <> status <> ":\n"
         <> unlines (("    " <>) <$> prettyTxs) <> "\n"
         <> "Traces: \n" <> T.unpack (showTraceTree dappInfo vm)

-- | Pretty-print the status of all 'SolTest's in a 'Campaign'.
ppTests :: (MonadReader Env m, MonadIO m) => [EchidnaTest] -> m String
ppTests tests = do
  unlines . catMaybes <$> mapM pp tests
  where
  pp t =
    case t.testType of
      PropertyTest n _ -> do
        status <- ppTS t.state (fromJust t.vm) t.reproducer
        pure $ Just (T.unpack n <> ": " <> status)
      CallTest n _ -> do
        status <- ppTS t.state (fromJust t.vm) t.reproducer
        pure $ Just (T.unpack n <> ": " <> status)
      AssertionTest _ s _ -> do
        status <- ppTS t.state (fromJust t.vm) t.reproducer
        pure $ Just (T.unpack (encodeSig s) <> ": " <> status)
      OptimizationTest n _ -> do
        status <- ppOPT t.state (fromJust t.vm) t.reproducer
        pure $ Just (T.unpack n <> ": max value: " <> show t.value <> "\n" <> status)
      Exploration -> pure Nothing

ppTestName :: EchidnaTest -> String
ppTestName t =
  case t.testType of
    PropertyTest n _ -> T.unpack n
    CallTest n _ -> T.unpack n
    AssertionTest _ s _ -> T.unpack (encodeSig s)
    OptimizationTest n _ -> T.unpack n <> ": max value: " <> show t.value
    Exploration -> "<exploration>"

-- | Given a number of boxes checked and a number of total boxes, pretty-print
-- progress in box-checking.
progress :: Int -> Int -> String
progress n m = show n <> "/" <> show m

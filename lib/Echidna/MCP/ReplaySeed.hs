{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | The @replay_seed@ MCP tool: replay one named seed into a running campaign.
--
-- A caller hands over a transaction sequence and a name. The sequence is
-- checked, then replayed twice from the campaign's initial VM:
--
-- 1. against private, empty coverage maps, which gives the coverage of this
--    seed alone (the answer the caller gets back), and
-- 2. against the campaign's own coverage maps, so the campaign's coverage
--    feeds include the seed without a restart.
--
-- A seed that passes is written to @<corpus-dir>/coverage/<name>.txt@ and
-- added to the in-memory corpus the fuzz workers mutate from. A seed that
-- fails a check is neither replayed nor saved.
--
-- Every test of the campaign is evaluated after each transaction, as a fuzz
-- worker does for its own sequences. A seed that falsifies a test is a break:
-- the answer says so (@broken@, @falsified@), and a test that was still open
-- is marked falsified in the campaign with the seed's prefix as its
-- reproducer, so the break is reported, saved and shrunk like any other.
--
-- The replay runs on the MCP request thread, not on a fuzz worker, so it also
-- answers while the workers are still replaying the initial corpus.
module Echidna.MCP.ReplaySeed
  ( ReplaySeedArgs(..)
  , ReplaySeedError(..)
  , replaySeed
  , replaySeedErrorText
  , replaySeedFileName
  , replaySeedDecodeTxs
  , replaySeedLcov
  , replaySeedTimeoutUsec
  , replaySeedTestName
  ) where

import Control.Concurrent.STM (atomically, writeTChan)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (foldM, forM, when)
import Control.Monad.Reader (runReaderT)
import Control.Monad.State.Strict (runStateT)
import Data.Aeson (FromJSON(..), Result(..), Value(..), eitherDecodeStrict, encodeFile, fromJSON, object, toJSON, withObject, (.:), (.=))
import Data.Char (isAlphaNum, isAscii)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe)
import Data.Primitive.PrimVar (atomicReadInt, newPrimVar)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Vector qualified as V
import Data.Word (Word64)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath ((<.>), (</>))
import System.Timeout (timeout)

import Optics.Core ((%), (^..), ix)

import EVM.Dapp (DappInfo(..))
import EVM.Types (Expr(LitAddr), VM(..), VMType(..))

import Echidna.Exec (clearTxBookkeeping, execTxWithCov, resetTxTransientState)
import Echidna.Output.Source (CoverageSnapshot(..), coverageLineHits, snapshotCoverage)
import Echidna.Types.Campaign (CampaignConf(..))
import Echidna.Types.Config (EConfig(..), Env(..))
import Echidna.Types.Coverage (CovSlot, coverageStats, newCovSlot)
import Echidna.Types.InterWorker (AgentId(..), BroadcastMsg(..), Message(..), WrappedMessage(..))
import Echidna.Test (checkETest, compactVMForReport, getResultFromVM)
import Echidna.Types.Test (EchidnaTest, TestState(..), TestType(..), TestValue(..))
import Echidna.Types.Test qualified as Test
import Echidna.Types.Tx (Tx(..), TxCall(..), TxResult, getResult)
import Echidna.Types.Corpus (corpusSize)
import Echidna.Types.Worker (CampaignEvent(..), WorkerEvent(..), WorkerType(..))
import Echidna.Worker (pushCampaignEvent)

-- | Arguments of the tool. @transactions@ is the seed in the corpus file
-- format: a JSON array of transactions, or a string holding that array.
data ReplaySeedArgs = ReplaySeedArgs
  { name :: Text
  , transactions :: Value
  }

instance FromJSON ReplaySeedArgs where
  parseJSON = withObject "ReplaySeedArgs" $ \o ->
    ReplaySeedArgs <$> o .: "name" <*> o .: "transactions"

-- | Why a seed was turned down. Nothing was replayed or saved in either case.
data ReplaySeedError
  = InvalidSeed Text
    -- ^ the request itself is wrong: bad name, unreadable or empty sequence,
    -- or a call to an address the campaign never deployed
  | ReplayFailed Text
    -- ^ the sequence was well formed but could not be executed
  deriving (Eq, Show)

replaySeedErrorText :: ReplaySeedError -> Text
replaySeedErrorText = \case
  InvalidSeed why -> "invalid seed, not replayed: " <> why
  ReplayFailed why -> "seed replay failed, not saved: " <> why

-- | One replay may take this long before it is given up on.
replaySeedTimeoutUsec :: Int
replaySeedTimeoutUsec = 300_000_000

maxSeedNameLength :: Int
maxSeedNameLength = 200

-- | The corpus file name for a seed name. A name is a single path component of
-- ASCII letters, digits, @.@, @_@ and @-@ that does not start with a dot, so it
-- cannot leave the corpus directory. A trailing @.txt@ is accepted and not
-- doubled.
replaySeedFileName :: Text -> Either Text FilePath
replaySeedFileName raw
  | T.null stem = Left "name is empty"
  | T.length stem > maxSeedNameLength =
      Left $ "name is longer than " <> T.pack (show maxSeedNameLength) <> " characters"
  | T.head stem == '.' = Left "name must not start with a dot"
  | not (T.all allowed stem) =
      Left "name may only contain ASCII letters, digits, '.', '_' and '-'"
  | otherwise = Right (T.unpack stem <.> "txt")
  where
    trimmed = T.strip raw
    stem = fromMaybe trimmed (T.stripSuffix ".txt" trimmed)
    allowed c = isAscii c && (isAlphaNum c || c `elem` ("._-" :: String))

-- | Read the transaction sequence out of the @transactions@ argument.
replaySeedDecodeTxs :: Value -> Either Text [Tx]
replaySeedDecodeTxs = \case
  String raw ->
    case eitherDecodeStrict (encodeUtf8 raw) of
      Left err -> Left $ "transactions is not a JSON transaction array: " <> T.pack err
      Right txs -> nonEmpty txs
  value@(Array _) ->
    case fromJSON value of
      Error err -> Left $ "transactions is not a transaction array: " <> T.pack err
      Success txs -> nonEmpty txs
  _ -> Left "transactions must be a JSON array of transactions or a string holding one"
  where
    nonEmpty [] = Left "transactions is empty"
    nonEmpty txs = Right txs

-- | Replay a named seed. See the module header.
replaySeed :: Env -> VM Concrete -> ReplaySeedArgs -> IO (Either ReplaySeedError Value)
replaySeed env vm args =
  case validate of
    Left why -> pure . Left $ InvalidSeed why
    Right (fileName, txs) -> do
      (seedEnv, seedSlot) <- isolatedCoverageEnv env
      -- Every test is checked, whatever the campaign already knows about it:
      -- whether this seed breaks a test does not depend on who broke it first.
      tests <- zip env.testRefs <$> traverse readIORef env.testRefs
      alone <- runSeed seedEnv seedSlot vm tests txs
      case alone of
        Left why -> pure . Left $ ReplayFailed why
        Right (results, _, breaks) -> do
          covered <- coveredLines seedEnv
          -- The slot is private to this request: campaign slots belong to
          -- their agents, and a slot must never be used from two threads.
          liveSlot <- newCovSlot (V.length env.coverageSlots)
          live <- runSeed env liveSlot vm [] txs
          case live of
            Left why -> pure . Left $ ReplayFailed why
            Right (_, grew, _) -> do
              saved <- saveSeed env fileName txs
              newSize <- addToLiveCorpus env txs
              -- The same signals a fuzz worker's own discovery gives.
              mapM_ (pushCampaignEvent env . ReproducerSaved . fst) saved
              when grew $ announceNewCoverage env newSize txs
              falsified <- forM breaks $ \seedBreak -> do
                newly <- reportBreak env seedBreak
                pure $ object
                  [ "test" .= replaySeedTestName seedBreak.test
                  , "txIndex" .= seedBreak.txIndex
                  , "result" .= seedBreak.result
                  , "newlyFalsified" .= newly
                  ]
              pushCampaignEvent env . ServerLog $
                "Seed " <> fileName <> " replayed over MCP: "
                  <> show (length txs) <> " transaction(s), "
                  <> (if grew then "new" else "no new") <> " campaign coverage, "
                  <> show (length breaks) <> " test(s) falsified"
              pure . Right $ object
                [ "replayed" .= True
                , "name" .= fileName
                , "file" .= fmap fst saved
                , "replacedExisting" .= maybe False snd saved
                , "transactions" .= length txs
                , "results" .= results
                , "newCoverage" .= grew
                , "broken" .= not (null breaks)
                , "falsified" .= falsified
                , "coverage" .= covered
                , "lcov" .= replaySeedLcov covered
                ]
  where
    validate = do
      fileName <- replaySeedFileName args.name
      txs <- replaySeedDecodeTxs args.transactions
      case find (not . targetsDeployedContract vm) txs of
        Just tx -> Left $ "transaction calls " <> T.pack (show tx.dst)
          <> ", which is not a contract of this campaign"
        Nothing -> Right (fileName, txs)

-- | A call must target a contract the campaign deployed, as the initial
-- corpus replay requires; a pure delay has no target.
targetsDeployedContract :: VM Concrete -> Tx -> Bool
targetsDeployedContract vm tx = case tx.call of
  NoCall -> True
  -- The deployed contracts come from the VM. The field label is used rather
  -- than 'vm.env.contracts': hevm's fields have no selectors under
  -- NoFieldSelectors, so the label is the way to reach them.
  _ -> not . null $ vm ^.. #env % #contracts % ix (LitAddr tx.dst)

-- | The campaign's environment with empty coverage maps of its own, so a
-- replay through it records one seed's coverage and nothing else. Hit counts
-- are off: only which lines ran is reported.
isolatedCoverageEnv :: Env -> IO (Env, CovSlot)
isolatedCoverageEnv env = do
  initRef <- newIORef mempty
  runtimeRef <- newIORef mempty
  points <- newPrimVar 0
  edgePoints <- newPrimVar 0
  used <- newPrimVar 0
  slot <- newCovSlot 0
  pure
    ( env { coverageRefInit = initRef
          , coverageRefRuntime = runtimeRef
          , coveragePoints = points
          , coverageEdgePoints = edgePoints
          , hitCountBudget = 0
          , hitCountUsed = used
          , coverageSlots = V.singleton slot
          , deploymentSlot = slot
          }
    , slot
    )

-- | A test the seed falsified.
data SeedBreak = SeedBreak
  { testRef :: IORef EchidnaTest
    -- ^ the campaign's record of the test
  , test :: EchidnaTest
  , txIndex :: Int
    -- ^ position in the seed of the transaction after which the test failed
  , reproducer :: [Tx]
    -- ^ the seed up to and including that transaction
  , result :: TxResult
  , failedVm :: VM Concrete
    -- ^ the state the test failed in
  }

-- | Execute the sequence from the given VM, recording coverage through the
-- slot, and evaluate the given tests after every transaction, in the state a
-- fuzz worker evaluates them in. Returns each transaction's result, whether
-- the coverage maps of the environment gained anything, and the tests the
-- sequence falsified, each at the first transaction that falsified it.
runSeed
  :: Env -> CovSlot -> VM Concrete -> [(IORef EchidnaTest, EchidnaTest)] -> [Tx]
  -> IO (Either Text ([TxResult], Bool, [SeedBreak]))
runSeed env slot vm0 tests0 txs = do
  outcome <- try (timeout replaySeedTimeoutUsec (runReaderT (go vm0 tests0 [] (zip [0 ..] txs)) env))
    :: IO (Either SomeException (Maybe ([TxResult], Bool, [SeedBreak])))
  pure $ case outcome of
    Left err -> Left . T.pack $ displayException err
    Right Nothing -> Left "replay timed out"
    Right (Just done) -> Right done
  where
    go _ _ _ [] = pure ([], False, [])
    go vm tests executed ((index, tx) : rest) = do
      ((vmResult, grew), vm') <- runStateT (execTxWithCov slot tx) (resetTxTransientState vm)
      -- Force the result before moving on so a failure surfaces here.
      let !txResult = getResult vmResult
          vmAfter = clearTxBookkeeping vm'
          executed' = tx : executed
      (stillPassing, breaksNow) <- foldM (check vmAfter index (reverse executed')) ([], []) tests
      (results, grewLater, breaksLater) <- go vmAfter (reverse stillPassing) executed' rest
      pure (txResult : results, grew || grewLater, reverse breaksNow <> breaksLater)

    check vmAfter index reproducer (passing, breaks) entry@(testRef, test) = do
      (value, checkedVm) <- checkETest test vmAfter
      pure $ case value of
        BoolValue False ->
          let found = SeedBreak
                { testRef, test, txIndex = index, reproducer
                , result = getResultFromVM checkedVm, failedVm = vmAfter }
          in (passing, found : breaks)
        _ -> (entry : passing, breaks)

-- | Record a break in the campaign, as the worker that found it would: a test
-- still open becomes falsified with the seed's prefix as its reproducer, and
-- the 'TestFalsified' event is published, which reports it, saves the
-- reproducer and hands it to worker 0 for shrinking. Returns whether the
-- campaign learned of the break from this seed; a test already decided is
-- left as it is.
reportBreak :: Env -> SeedBreak -> IO Bool
reportBreak env seedBreak = do
  updated <- atomicModifyIORef' seedBreak.testRef $ \current ->
    case current.state of
      Open ->
        let falsified = current
              { Test.state = Large 0
              , Test.reproducer = seedBreak.reproducer
              , Test.vm = Just (compactVMForReport seedBreak.failedVm)
              , Test.result = seedBreak.result
              , Test.workerId = Just seedWorkerId
              }
        in (falsified, Just falsified)
      _ -> (current, Nothing)
  case updated of
    Nothing -> pure False
    Just falsified -> do
      pushCampaignEvent env . WorkerEvent seedWorkerId FuzzWorker $
        TestFalsified (falsified { Test.vm = Nothing })
      pure True

-- | The name a test is reported under.
replaySeedTestName :: EchidnaTest -> Text
replaySeedTestName test = case test.testType of
  PropertyTest name _ -> name
  OptimizationTest name _ -> name
  AssertionTest _ (name, _) _ -> name
  CallTest name _ -> name
  Exploration -> "exploration"

-- | Lines the environment's coverage maps record as executed, per source file.
coveredLines :: Env -> IO (Map FilePath (Map Int Word64))
coveredLines env = do
  snapshot <- snapshotCoverage env
  let contracts = Map.elems env.dapp.solcByName
      excludes = env.cfg.campaignConf.coverageExcludes
      hits = coverageLineHits env.sourceCache snapshot.merged contracts excludes
  pure . Map.filter (not . Map.null) $ Map.map (Map.filter (> 0)) hits

-- | The covered lines as LCOV text: one record per file, one @DA@ entry per
-- executed line.
replaySeedLcov :: Map FilePath (Map Int Word64) -> Text
replaySeedLcov covered = T.unlines $ concatMap record (Map.toAscList covered)
  where
    record (file, fileLines) =
      ["TN:", "SF:" <> T.pack file]
        <> [ "DA:" <> T.pack (show line) <> "," <> T.pack (show hits)
           | (line, hits) <- Map.toAscList fileLines ]
        <> ["end_of_record"]

-- | Write the seed under its name in the corpus's coverage directory, through
-- a temporary file so a reader never sees half of it. Returns the path and
-- whether a seed of that name was there before; 'Nothing' when the campaign
-- has no corpus directory.
saveSeed :: Env -> FilePath -> [Tx] -> IO (Maybe (FilePath, Bool))
saveSeed env fileName txs =
  case env.cfg.campaignConf.corpusDir of
    Nothing -> pure Nothing
    Just corpusDir -> do
      let dir = corpusDir </> "coverage"
          file = dir </> fileName
          partial = dir </> ("." <> fileName <> ".partial")
      createDirectoryIfMissing True dir
      existed <- doesFileExist file
      encodeFile partial (toJSON txs)
      renameFile partial file
      pure $ Just (file, existed)

-- | Report that the campaign's coverage grew, the way a fuzz worker does: the
-- 'NewCoverage' event that status lines, the MCP event feed and the coverage
-- feeds' refresh react to, and the broadcast the symbolic worker listens for.
--
-- The event carries no transactions. The corpus saver writes an event's
-- transactions under a hash name, and this seed is already saved under its
-- own name; a second copy would be replayed twice at every start.
announceNewCoverage :: Env -> Int -> [Tx] -> IO ()
announceNewCoverage env newSize txs = do
  (points, numCodehashes) <- coverageStats env.coveragePoints env.coverageRefInit env.coverageRefRuntime
  edges <- atomicReadInt env.coverageEdgePoints
  pushCampaignEvent env . WorkerEvent seedWorkerId FuzzWorker $
    NewCoverage { points, numCodehashes, edges, corpusSize = newSize, transactions = [] }
  atomically . writeTChan env.bus $
    WrappedMessage AIId (Broadcast (NewCoverageInfo points txs False))

-- | Make the sequence available to every fuzz worker: they all draw the
-- sequences they mutate from this one shared corpus.
-- Returns the corpus size afterwards.
addToLiveCorpus :: Env -> [Tx] -> IO Int
addToLiveCorpus env txs =
  atomicModifyIORef' env.corpusRef $ \corpus ->
    let known = Set.member txs (Set.map snd corpus)
        nextId = if Set.null corpus then 1 else fst (Set.findMax corpus) + 1
        corpus' = if known then corpus else Set.insert (nextId, txs) corpus
    in (corpus', corpusSize corpus')

-- | Events of a replayed seed are reported under worker 0: campaign events
-- have no sender other than a worker.
seedWorkerId :: Int
seedWorkerId = 0

module Tests.CorpusArchive (corpusArchiveTests) where

import Control.Monad (forM_)
import Control.Monad.Reader (runReaderT)
import Control.Monad.State.Strict (evalStateT)
import Data.Aeson (decodeFileStrict, encodeFile, toJSON)
import Data.IORef (readIORef)
import Data.List (isInfixOf, sort)
import Data.Set qualified as Set
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))

import Echidna (loadInitialCorpus)
import Echidna.Execution (replayCorpus)
import Echidna.Output.Corpus (archiveSeed, defaultArchiveDir, isNamedSeed, preferNamedSeeds, saveMissingTxs)
import Echidna.Types.Campaign (WorkerState(..), initialWorkerState)
import Echidna.Types.Campaign qualified as Campaign
import Echidna.Types.Config (EConfig(..), Env(..))
import Echidna.Types.Tx (Tx(..), TxCall(..))
import Echidna.Types.Worker (CampaignEvent(..), WorkerEvent(..))
import Echidna.Worker (subscribeEvents)

import Tests.ReplaySeed (Campaign(..), drain, withCampaignConfig)

-- The campaigns below run on tests/solidity/basic/flags.sol. set0(0) takes
-- the branch that clears flag0; set1(0) after it takes the branch that clears
-- flag1. Replaying a sequence a second time adds nothing.

corpusArchiveTests :: TestTree
corpusArchiveTests = testGroup "Corpus archive"
  [ testCase "seeds that add no coverage are moved, the others stay" $
      withArchive $ \c -> do
        let first = [c.set0 0]
            longer = [c.set0 0, c.set1 0]
        writeSeeds c "coverage" [("a.txt", first), ("b.txt", first), ("c.txt", longer), ("d.txt", longer)]
        replay c [("a.txt", first), ("b.txt", first), ("c.txt", longer), ("d.txt", longer)]
        filesIn (c.corpusDir </> "coverage") >>= (@?= ["a.txt", "c.txt"])
        filesIn (archiveDir c) >>= (@?= ["b.txt", "d.txt"])

  , testCase "an archived seed keeps its name and its transactions" $
      withArchive $ \c -> do
        let seed = [c.set0 0, c.set1 0]
        writeSeeds c "coverage" [("keep.txt", seed), ("gap-7.txt", seed)]
        replay c [("keep.txt", seed), ("gap-7.txt", seed)]
        decodeFileStrict (archiveDir c </> "gap-7.txt") >>= (@?= Just seed)
        decodeFileStrict (c.corpusDir </> "coverage" </> "keep.txt") >>= (@?= Just seed)

  , testCase "only the kept seeds are in the corpus the workers mutate from" $
      withArchive $ \c -> do
        let first = [c.set0 0]
        writeSeeds c "coverage" [("a.txt", first), ("b.txt", first)]
        replay c [("a.txt", first), ("b.txt", first)]
        corpus <- readCorpus c
        corpus @?= [first]

  , testCase "the number of archived seeds is logged once" $
      withArchive $ \c -> do
        let first = [c.set0 0]
        writeSeeds c "coverage" [("a.txt", first), ("b.txt", first), ("c.txt", first)]
        events <- subscribeEvents c.env
        replay c [("a.txt", first), ("b.txt", first), ("c.txt", first)]
        seen <- drain events
        [line | WorkerEvent _ _ (Log line) <- seen, "Archived" `isInfixOf` line]
          @?= ["Archived 2 of 3 replayed sequences that added no coverage"]

  , testCase "nothing is logged when every seed adds coverage" $
      withArchive $ \c -> do
        writeSeeds c "coverage" [("a.txt", [c.set0 0])]
        events <- subscribeEvents c.env
        replay c [("a.txt", [c.set0 0])]
        seen <- drain events
        [line | WorkerEvent _ _ (Log line) <- seen, "Archived" `isInfixOf` line] @?= []
        doesDirectoryExist (archiveDir c) >>= assertBool "no archive directory is created" . not

  , testCase "without corpusArchiveDir the archive is echidna-archive next to the corpus" $
      -- The corpus is a subdirectory here so its neighbour is removed with the test.
      withCampaignConfig (\cfg dir -> withCorpus cfg (dir </> "echidna-corpus")) $ \c -> do
        let first = [c.set0 0]
            coverage = c.corpusDir </> "echidna-corpus" </> "coverage"
        createDirectoryIfMissing True coverage
        forM_ ["a.txt", "b.txt"] $ \file -> encodeFile (coverage </> file) (toJSON first)
        replay c [("a.txt", first), ("b.txt", first)]
        filesIn coverage >>= (@?= ["a.txt"])
        filesIn (c.corpusDir </> "echidna-archive") >>= (@?= ["b.txt"])

  , testCase "the default archive of a corpus path with a trailing slash is still its neighbour" $ do
      defaultArchiveDir "run/echidna-corpus/" @?= "run" </> "echidna-archive"
      defaultArchiveDir "echidna-corpus" @?= "." </> "echidna-archive"

  , testCase "a name starting with seed is named, decimal and hex hash names are not" $ do
      isNamedSeed "seed_gap_v1_c2VudHJ5.txt" @?= True
      isNamedSeed "seed-1.txt" @?= True
      isNamedSeed "1057085892809747560.txt" @?= False
      isNamedSeed "09daf68c1fc37b4b28fb.txt" @?= False
      isNamedSeed "gap-1.txt" @?= False

  , testCase "named seeds are replayed before the others, each group in name order" $ do
      let seeds = [("111.txt", [1]), ("seed_gap_2.txt", [2]), ("0abc.txt", [3]), ("seed_gap_1.txt", [4])]
      fst (preferNamedSeeds' seeds) @?= ["seed_gap_1.txt", "seed_gap_2.txt", "0abc.txt", "111.txt"]

  , testCase "of seeds with the same transactions the named one is kept" $ do
      let seeds = [("111.txt", [7]), ("09daf68c.txt", [7]), ("seed_gap_1.txt", [7]), ("222.txt", [8])]
      preferNamedSeeds' seeds @?= (["seed_gap_1.txt", "222.txt"], ["09daf68c.txt", "111.txt"])

  , testCase "a decimal and a hex name for the same transactions leave one seed" $ do
      let seeds = [("1057085892809747560.txt", [7]), ("09daf68c1fc37b4b28fb.txt", [7])]
      preferNamedSeeds' seeds @?= (["09daf68c1fc37b4b28fb.txt"], ["1057085892809747560.txt"])

  , testCase "identical named seeds leave one seed" $ do
      let seeds = [("seed_gap_b.txt", [7]), ("seed_gap_a.txt", [7]), ("seed_gap_c.txt", [7])]
      preferNamedSeeds' seeds @?= (["seed_gap_a.txt"], ["seed_gap_b.txt", "seed_gap_c.txt"])

  , testCase "loading the corpus archives the copies and keeps the named seed" $
      withArchive $ \c -> do
        let seed = [c.set0 0, c.set1 0]
        writeSeeds c "coverage"
          [("12345.txt", seed), ("0abc12.txt", seed), ("seed_gap_1.txt", seed), ("678.txt", [c.set0 0])]
        loaded <- loadInitialCorpus c.env
        map fst loaded @?= ["seed_gap_1.txt", "678.txt"]
        filesIn (c.corpusDir </> "coverage") >>= (@?= ["678.txt", "seed_gap_1.txt"])
        filesIn (archiveDir c) >>= (@?= ["0abc12.txt", "12345.txt"])

  , testCase "a named seed keeps its place over a hash-named seed with the same coverage" $
      withArchive $ \c -> do
        -- Different transactions, same coverage: set0(100) takes the branch set0(0) takes.
        writeSeeds c "coverage" [("999.txt", [c.set0 0]), ("seed_gap_1.txt", [c.set0 100])]
        loaded <- loadInitialCorpus c.env
        replay c loaded
        filesIn (c.corpusDir </> "coverage") >>= (@?= ["seed_gap_1.txt"])
        filesIn (archiveDir c) >>= (@?= ["999.txt"])

  , testCase "a replayed seed that adds coverage is not saved a second time" $
      withArchive $ \c -> do
        writeSeeds c "coverage" [("seed_gap_1.txt", [c.set0 0])]
        events <- subscribeEvents c.env
        replay c [("seed_gap_1.txt", [c.set0 0])]
        seen <- drain events
        -- The corpus saver writes a file for an event with transactions.
        [txs | WorkerEvent _ _ NewCoverage { transactions = txs } <- seen] @?= [[]]
        readCorpus c >>= (@?= [[c.set0 0]])

  , testCase "saving the corpus at exit adds no copy of a seed that is on disk under another name" $
      withArchive $ \c -> do
        let named = [c.set0 0]
            hexNamed = [c.set0 0, c.set1 0]
            discovered = [c.set1 7]
        writeSeeds c "coverage" [("seed_gap_1.txt", named), ("1b9dc0655c8a046cbbb7.txt", hexNamed)]
        saveMissingTxs c.env (c.corpusDir </> "coverage") [named, hexNamed, discovered]
        files <- filesIn (c.corpusDir </> "coverage")
        length files @?= 3
        assertBool "the seeds on disk keep their names" $
          all (`elem` files) ["seed_gap_1.txt", "1b9dc0655c8a046cbbb7.txt"]
        saved <- traverse (\file -> decodeFileStrict (c.corpusDir </> "coverage" </> file)) files
        sort saved @?= sort [Just named, Just hexNamed, Just discovered]

  , testCase "replaying a corpus and saving it at exit leaves the files that added coverage" $
      withArchive $ \c -> do
        let first = [c.set0 0]
            longer = [c.set0 0, c.set1 0]
        writeSeeds c "coverage"
          [("0a.txt", first), ("0b.txt", first), ("0c.txt", longer), ("seed_x.txt", [c.set0 100])]
        loaded <- loadInitialCorpus c.env
        replay c loaded
        corpus <- readCorpus c
        saveMissingTxs c.env (c.corpusDir </> "coverage") corpus
        -- seed_x goes first and covers what 0a would; 0b is a copy of 0a.
        filesIn (c.corpusDir </> "coverage") >>= (@?= ["0c.txt", "seed_x.txt"])
        length corpus @?= 2

  , testCase "nothing is moved when coverage is off" $
      withCampaignConfig (\cfg dir -> coverageOff (withArchiveDir cfg dir)) $ \c -> do
        let first = [c.set0 0]
        writeSeeds c "coverage" [("a.txt", first), ("b.txt", first)]
        replay c [("a.txt", first), ("b.txt", first)]
        filesIn (c.corpusDir </> "coverage") >>= (@?= ["a.txt", "b.txt"])
        doesDirectoryExist (archiveDir c) >>= assertBool "no archive directory" . not

  , testCase "reproducers are never moved" $
      withArchive $ \c -> do
        let first = [c.set0 0]
        writeSeeds c "coverage" [("a.txt", first)]
        writeSeeds c "reproducers" [("r.txt", first)]
        replay c [("a.txt", first), ("r.txt", first)]
        filesIn (c.corpusDir </> "reproducers") >>= (@?= ["r.txt"])
        filesIn (c.corpusDir </> "coverage") >>= (@?= ["a.txt"])
        doesDirectoryExist (archiveDir c) >>= assertBool "no archive directory" . not

  , testCase "a seed that cannot be replayed stays where it is" $
      withArchive $ \c -> do
        let stray = [(c.set0 0) { dst = 0xdeadbeef }]
        writeSeeds c "coverage" [("stray.txt", stray)]
        replay c [("stray.txt", stray)]
        filesIn (c.corpusDir </> "coverage") >>= (@?= ["stray.txt"])
        doesDirectoryExist (archiveDir c) >>= assertBool "no archive directory" . not

  , testCase "a seed of the same name already in the archive is replaced" $
      withArchive $ \c -> do
        let old = [c.set1 5]
            new = [c.set0 0]
        createDirectoryIfMissing True (archiveDir c)
        encodeFile (archiveDir c </> "b.txt") (toJSON old)
        writeSeeds c "coverage" [("b.txt", new)]
        archiveSeed c.env "b.txt" >>= (@?= True)
        decodeFileStrict (archiveDir c </> "b.txt") >>= (@?= Just new)
        doesFileExist (c.corpusDir </> "coverage" </> "b.txt") >>= assertBool "moved out of coverage" . not

  , testCase "archiving a file that is not in coverage moves nothing" $
      withArchive $ \c -> do
        archiveSeed c.env "missing.txt" >>= (@?= False)
        doesDirectoryExist (archiveDir c) >>= assertBool "no archive directory" . not
  ]

withArchive :: (Campaign -> Assertion) -> Assertion
withArchive = withCampaignConfig withArchiveDir

withCorpus :: EConfig -> FilePath -> EConfig
withCorpus cfg dir =
  cfg { campaignConf = cfg.campaignConf { Campaign.corpusDir = Just dir } }

withArchiveDir :: EConfig -> FilePath -> EConfig
withArchiveDir cfg dir =
  let withDir = withCorpus cfg dir
  in withDir { campaignConf = withDir.campaignConf { Campaign.corpusArchiveDir = Just (dir </> "echidna-archive") } }

coverageOff :: EConfig -> EConfig
coverageOff cfg = cfg { campaignConf = cfg.campaignConf { Campaign.coverageEnabled = False } }

archiveDir :: Campaign -> FilePath
archiveDir c = c.corpusDir </> "echidna-archive"

writeSeeds :: Campaign -> FilePath -> [(FilePath, [Tx])] -> IO ()
writeSeeds c subdir seeds = do
  let dir = c.corpusDir </> subdir
  createDirectoryIfMissing True dir
  forM_ seeds $ \(file, txs) -> encodeFile (dir </> file) (toJSON txs)

-- | Replay the sequences as a fuzz worker replays its share of the initial
-- corpus: file names without a directory, in the given order.
replay :: Campaign -> [(FilePath, [Tx])] -> IO ()
replay c seeds =
  runReaderT (evalStateT (replayCorpus (pure ()) c.vm seeds) worker) c.env
  where
    worker = initialWorkerState { genDict = c.dict }

readCorpus :: Campaign -> IO [[Tx]]
readCorpus c = map snd . Set.toList <$> readIORef c.env.corpusRef

-- | 'preferNamedSeeds' on file names, with a number standing in for each
-- seed's transactions: seeds with the same number have the same transactions.
preferNamedSeeds' :: [(FilePath, [Int])] -> ([FilePath], [FilePath])
preferNamedSeeds' seeds = (fst <$> ordered, copies)
  where
    (ordered, copies) = preferNamedSeeds [(file, map wait ids) | (file, ids) <- seeds]
    wait n = Tx NoCall 0 0 0 0 0 (fromIntegral n, 0)

filesIn :: FilePath -> IO [FilePath]
filesIn dir = do
  exists <- doesDirectoryExist dir
  if exists then sort <$> listDirectory dir else pure []

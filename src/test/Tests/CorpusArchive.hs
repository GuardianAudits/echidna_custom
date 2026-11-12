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
import Echidna.Output.Corpus (archiveSeed, defaultArchiveDir, preferNamedSeeds)
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

  , testCase "named seeds are replayed before hash-named ones" $ do
      let seeds = [("111.txt", [1]), ("gap-2.txt", [2]), ("222.txt", [3]), ("gap-1.txt", [4])]
      fst (preferNamedSeeds' seeds) @?= ["gap-2.txt", "gap-1.txt", "111.txt", "222.txt"]

  , testCase "a hash-named copy of a named seed is set aside, other seeds are not" $ do
      let seeds = [("111.txt", [7]), ("gap-1.txt", [7]), ("222.txt", [8]), ("333.txt", [8])]
      preferNamedSeeds' seeds @?= (["gap-1.txt", "222.txt", "333.txt"], ["111.txt"])

  , testCase "loading the corpus archives the hash-named copy and keeps the named seed" $
      withArchive $ \c -> do
        let seed = [c.set0 0, c.set1 0]
        writeSeeds c "coverage" [("12345.txt", seed), ("gap-1.txt", seed), ("678.txt", [c.set0 0])]
        loaded <- loadInitialCorpus c.env
        map fst loaded @?= ["gap-1.txt", "678.txt"]
        filesIn (c.corpusDir </> "coverage") >>= (@?= ["678.txt", "gap-1.txt"])
        filesIn (archiveDir c) >>= (@?= ["12345.txt"])

  , testCase "a named seed replayed first keeps its place over a hash-named seed with the same coverage" $
      withArchive $ \c -> do
        -- Different transactions, same coverage: set0(100) takes the branch set0(0) takes.
        writeSeeds c "coverage" [("999.txt", [c.set0 0]), ("gap-1.txt", [c.set0 100])]
        loaded <- loadInitialCorpus c.env
        replay c loaded
        filesIn (c.corpusDir </> "coverage") >>= (@?= ["gap-1.txt"])
        filesIn (archiveDir c) >>= (@?= ["999.txt"])

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

module Tests.ReplaySeed (replaySeedTests) where

import Control.Concurrent.STM (TChan, atomically, tryReadTChan)
import Control.Exception (bracket)
import Data.Aeson (Value(..), decodeFileStrict, eitherDecodeStrict, encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef)
import Data.List (isSuffixOf)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (LocalTime, UTCTime)
import Data.Vector qualified as Vector
import Data.Word (Word64)
import System.Directory
  (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, listDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

import EVM.ABI (AbiValue(..))
import EVM.Dapp (DappInfo(..))
import EVM.Types (Addr, VM, VMType(Concrete))

import Common (testConfig)
import Echidna (prepareContract)
import Echidna.MCP
  ( StreamableCoverageState(..), StreamableEventBuffer(..), StreamableMCPState(..)
  , streamableToolsCall, streamableToolsList
  )
import Echidna.MCP.ReplaySeed
  ( ReplaySeedArgs(..), ReplaySeedError(..), replaySeed, replaySeedDecodeTxs
  , replaySeedErrorText, replaySeedFileName, replaySeedLcov
  )
import Echidna.Output.Source (CoverageSnapshot(..), coverageLineHits, snapshotCoverage)
import Echidna.Solidity (compileContracts)
import Echidna.Types.Campaign qualified as Campaign
import Echidna.Types.Config (EConfig(..), Env(..), InitialCorpusReplayState(..))
import Echidna.Types.Solidity (SolConf(..))
import Echidna.Types.Tx (Tx(..), TxCall(..), maxGasPerBlock)
import Echidna.Types.Worker (CampaignEvent(..), WorkerEvent(..))
import Echidna.Worker (subscribeEvents)

-- Lines of tests/solidity/basic/flags.sol the seeds below do or do not reach.
set0Condition, set0Assignment, set1Condition, set1Assignment :: Int
set0Condition = 8    -- if (val % 100 == 0)
set0Assignment = 9   --   flag0 = false;
set1Condition = 14   -- if (val % 10 == 0 && !flag0)
set1Assignment = 15  --   flag1 = false;

replaySeedTests :: TestTree
replaySeedTests = testGroup "MCP replay_seed"
  [ testGroup "seed name"
      [ testCase "a gap id becomes a .txt file name" $
          replaySeedFileName "seed_gap_v1_c2VudHJ5LXRlc3Q-Zm9v" @?= Right "seed_gap_v1_c2VudHJ5LXRlc3Q-Zm9v.txt"
      , testCase "a trailing .txt is not doubled" $
          replaySeedFileName "gap-1.txt" @?= Right "gap-1.txt"
      , testCase "surrounding whitespace is dropped" $
          replaySeedFileName "  gap-1 \n" @?= Right "gap-1.txt"
      , testCase "an empty name is refused" $ do
          assertBool "empty" . isLeft $ replaySeedFileName ""
          assertBool "only an extension" . isLeft $ replaySeedFileName ".txt"
      , testCase "a name cannot leave the corpus directory" $ do
          assertBool "parent directory" . isLeft $ replaySeedFileName "../outside"
          assertBool "sub directory" . isLeft $ replaySeedFileName "nested/seed"
          assertBool "windows separator" . isLeft $ replaySeedFileName "nested\\seed"
          assertBool "absolute path" . isLeft $ replaySeedFileName "/etc/passwd"
          assertBool "hidden file" . isLeft $ replaySeedFileName ".hidden"
      , testCase "other characters are refused" $ do
          assertBool "space" . isLeft $ replaySeedFileName "gap 1"
          assertBool "non-ASCII letter" . isLeft $ replaySeedFileName "gäp"
          assertBool "NUL" . isLeft $ replaySeedFileName "gap\0"
      , testCase "an overlong name is refused" $ do
          assertBool "200 characters fit" $ replaySeedFileName (T.replicate 200 "a") == Right (replicate 200 'a' <> ".txt")
          assertBool "201 characters do not" . isLeft $ replaySeedFileName (T.replicate 201 "a")
      ]

  , testGroup "seed transactions"
      [ testCase "an array and a string holding that array decode alike" $ do
          let txs = [call 0x10000 0x20000 "set0" 0, call 0x10000 0x20000 "set1" 10]
              asArray = toJSON txs
              asString = String (jsonText asArray)
          replaySeedDecodeTxs asArray @?= Right txs
          replaySeedDecodeTxs asString @?= Right txs
      , testCase "an empty sequence is refused" $ do
          assertBool "empty array" . isLeft $ replaySeedDecodeTxs (toJSON ([] :: [Tx]))
          assertBool "empty array in a string" . isLeft $ replaySeedDecodeTxs (String "[]")
      , testCase "anything else is refused" $ do
          assertBool "object" . isLeft $ replaySeedDecodeTxs (object ["call" .= ("set0" :: Text)])
          assertBool "number" . isLeft $ replaySeedDecodeTxs (Number 1)
          assertBool "broken JSON in a string" . isLeft $ replaySeedDecodeTxs (String "[{")
          assertBool "array of non-transactions" . isLeft $ replaySeedDecodeTxs (toJSON [1 :: Int, 2])
      ]

  , testGroup "LCOV"
      [ testCase "one record per file, one DA line per covered line" $
          replaySeedLcov (Map.fromList [("b.sol", Map.fromList [(7, 1)]), ("a.sol", Map.fromList [(9, 2), (3, 1)])])
            @?= "TN:\nSF:a.sol\nDA:3,1\nDA:9,2\nend_of_record\nTN:\nSF:b.sol\nDA:7,1\nend_of_record\n"
      , testCase "no coverage is an empty report" $
          replaySeedLcov Map.empty @?= ""
      ]

  , testGroup "replay"
      [ testCase "a valid seed is replayed and answered with its own coverage" $
          withCampaign $ \c -> do
            report <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-set0" [c.set0 0])
            field "replayed" report @?= Just (Bool True)
            field "name" report @?= Just (String "gap-set0.txt")
            field "transactions" report @?= Just (Number 1)
            field "newCoverage" report @?= Just (Bool True)
            let covered = coveredLinesOf report
            assertBool "the seed's own lines are reported" $ all (`elem` covered) [set0Condition, set0Assignment]
            assertBool "lines the seed did not run are not reported" $ all (`notElem` covered) [set1Condition, set1Assignment]
            case field "lcov" report of
              Just (String lcov) -> do
                assertBool "LCOV names the source file" $ "flags.sol" `T.isInfixOf` lcov
                assertBool "LCOV lists the covered line" $ ("DA:" <> T.pack (show set0Assignment) <> ",") `T.isInfixOf` lcov
                assertBool "LCOV leaves out lines that did not run" . not $ ("DA:" <> T.pack (show set1Assignment) <> ",") `T.isInfixOf` lcov
              other -> assertFailure ("lcov is not text: " <> show other)

      , testCase "the seed is saved under its name in the corpus coverage directory" $
          withCampaign $ \c -> do
            let txs = [c.set0 0, c.set1 10]
            report <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-both" txs)
            let file = c.corpusDir </> "coverage" </> "gap-both.txt"
            field "file" report @?= Just (String (T.pack file))
            field "replacedExisting" report @?= Just (Bool False)
            saved <- decodeFileStrict file
            saved @?= Just txs
            -- Only the named file: no hash-named copy, no leftover partial file.
            listDirectory (c.corpusDir </> "coverage") >>= (@?= ["gap-both.txt"])

      , testCase "a seed sent again under the same name replaces the file" $
          withCampaign $ \c -> do
            _ <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-1" [c.set0 1])
            report <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-1" [c.set0 0])
            field "replacedExisting" report @?= Just (Bool True)
            saved <- decodeFileStrict (c.corpusDir </> "coverage" </> "gap-1.txt")
            saved @?= Just [c.set0 0]

      , testCase "the seed joins the campaign's coverage" $
          withCampaign $ \c -> do
            before <- campaignCoveredLines c.env
            assertBool "the campaign has not run set0 yet" $ set0Assignment `notElem` before
            _ <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-set0" [c.set0 0])
            after <- campaignCoveredLines c.env
            assertBool "the campaign coverage now has the seed's lines" $ all (`elem` after) [set0Condition, set0Assignment]

      , testCase "the seed joins the corpus every worker mutates from, once" $
          withCampaign $ \c -> do
            let txs = [c.set0 0]
            readIORef c.env.corpusRef >>= (@?= 0) . Set.size
            _ <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-a" txs)
            _ <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-a-again" txs)
            corpus <- readIORef c.env.corpusRef
            map snd (Set.toList corpus) @?= [txs]

      , testCase "each seed is replayed from the initial state and reports only itself" $
          withCampaign $ \c -> do
            -- set0(0) clears flag0 in its own replay. If state or coverage
            -- leaked into the next seed, set1(0) would reach its assignment
            -- and the report would carry set0's lines.
            _ <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-set0" [c.set0 0])
            report <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-set1" [c.set1 0])
            let covered = coveredLinesOf report
            assertBool "set1 ran" $ set1Condition `elem` covered
            assertBool "set1 did not see set0's state change" $ set1Assignment `notElem` covered
            assertBool "set0's coverage is not in set1's report" $ all (`notElem` covered) [set0Condition, set0Assignment]

      , testCase "a sequence carries state from one transaction to the next" $
          withCampaign $ \c -> do
            report <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-chain" [c.set0 0, c.set1 0])
            assertBool "set1 saw flag0 cleared by set0" $ set1Assignment `elem` coveredLinesOf report
            fmap arrayLength (field "results" report) @?= Just 2

      , testCase "coverage the campaign already has is not reported as new" $
          withCampaign $ \c -> do
            first <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-a" [c.set0 0])
            second <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-b" [c.set0 0])
            field "newCoverage" first @?= Just (Bool True)
            field "newCoverage" second @?= Just (Bool False)
            -- The second seed still reports its own lines and is still saved.
            assertBool "own coverage is reported regardless" $ set0Assignment `elem` coveredLinesOf second
            doesFileExist (c.corpusDir </> "coverage" </> "gap-b.txt") >>= assertBool "saved regardless"

      , testCase "a replayed seed gives the events of a worker's own discovery" $
          withCampaign $ \c -> do
            events <- subscribeEvents c.env
            _ <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-set0" [c.set0 0])
            seen <- drain events
            let file = c.corpusDir </> "coverage" </> "gap-set0.txt"
            assertBool "the saved file is announced" $ any (isSaved file) seen
            -- Empty on purpose: the corpus saver would write the transactions
            -- a second time under a hash name.
            [txs | WorkerEvent _ _ NewCoverage { transactions = txs } <- seen] @?= [[]]

      , testCase "a seed calling an address the campaign never deployed is not replayed" $
          withCampaign $ \c -> do
            let stray = (c.set0 0) { dst = 0xdeadbeef }
            before <- campaignCoveredLines c.env
            result <- replaySeed c.env c.vm (seedArgs "gap-stray" [c.set0 0, stray])
            expectInvalid result
            assertUntouched c before

      , testCase "a seed with a bad name is not replayed" $
          withCampaign $ \c -> do
            before <- campaignCoveredLines c.env
            replaySeed c.env c.vm (seedArgs "../escape" [c.set0 0]) >>= expectInvalid
            assertUntouched c before
            doesFileExist (c.corpusDir </> "escape.txt") >>= assertBool "nothing written outside coverage/" . not

      , testCase "an empty seed is not replayed" $
          withCampaign $ \c -> do
            before <- campaignCoveredLines c.env
            replaySeed c.env c.vm (seedArgs "gap-empty" []) >>= expectInvalid
            assertUntouched c before

      , testCase "an invalid seed says so" $
          replaySeedErrorText (InvalidSeed "name is empty") @?= "invalid seed, not replayed: name is empty"

      , testCase "a campaign without a corpus directory replays without saving" $
          withCampaignConfig (const id) $ \c -> do
            report <- expectReplayed =<< replaySeed c.env c.vm (seedArgs "gap-set0" [c.set0 0])
            field "file" report @?= Just Null
            assertBool "coverage is still reported" $ set0Assignment `elem` coveredLinesOf report
            readIORef c.env.corpusRef >>= (@?= 1) . Set.size
      ]

  , testGroup "tool"
      [ testCase "replay_seed is listed with its arguments" $ do
          let props = toolProperties "replay_seed" streamableToolsList
          assertBool "name argument" $ "name" `elem` props
          assertBool "transactions argument" $ "transactions" `elem` props

      , testCase "a tool call replays the seed and returns the report" $
          withCampaign $ \c -> do
            st <- mkState (Just c.vm)
            response <- streamableToolsCall (Number 1) c.env [] st . Just $ object
              [ "name" .= ("replay_seed" :: Text)
              , "arguments" .= object ["name" .= ("gap-tool" :: Text), "transactions" .= toJSON [c.set0 0]]
              ]
            toolIsError response @?= False
            report <- either (assertFailure . ("report is not JSON: " <>)) pure . eitherDecodeStrict . encodeUtf8 $ toolText response
            field "replayed" report @?= Just (Bool True)
            assertBool "coverage of the seed" $ set0Assignment `elem` coveredLinesOf report
            doesFileExist (c.corpusDir </> "coverage" </> "gap-tool.txt") >>= assertBool "seed saved"

      , testCase "a tool call with an invalid seed is an error and replays nothing" $
          withCampaign $ \c -> do
            st <- mkState (Just c.vm)
            before <- campaignCoveredLines c.env
            response <- streamableToolsCall (Number 1) c.env [] st . Just $ object
              [ "name" .= ("replay_seed" :: Text)
              , "arguments" .= object ["name" .= ("no/slashes" :: Text), "transactions" .= toJSON [c.set0 0]]
              ]
            toolIsError response @?= True
            assertBool "the answer says the seed was not replayed" $ "invalid seed, not replayed" `T.isPrefixOf` toolText response
            assertUntouched c before

      , testCase "a tool call without the arguments is an error" $
          withCampaign $ \c -> do
            st <- mkState (Just c.vm)
            before <- campaignCoveredLines c.env
            response <- streamableToolsCall (Number 1) c.env [] st . Just $ object
              [ "name" .= ("replay_seed" :: Text), "arguments" .= object ["name" .= ("gap-x" :: Text)] ]
            toolIsError response @?= True
            assertUntouched c before
      ]
  ]

-- | A prepared campaign on basic/flags.sol that has executed nothing yet.
data Campaign = Campaign
  { env :: Env
  , vm :: VM Concrete
  , corpusDir :: FilePath
  , set0 :: Int -> Tx
  , set1 :: Int -> Tx
  }

withCampaign :: (Campaign -> Assertion) -> Assertion
withCampaign = withCampaignConfig $ \cfg dir ->
  cfg { campaignConf = cfg.campaignConf { Campaign.corpusDir = Just dir } }

withCampaignConfig :: (EConfig -> FilePath -> EConfig) -> (Campaign -> Assertion) -> Assertion
withCampaignConfig configure body =
  bracket makeDir removeDir $ \dir -> do
    let cfg = configure testConfig dir
        files = "basic/flags.sol" :| []
    buildOutput <- compileContracts cfg.solConf files
    (vm, env, _) <- prepareContract cfg files buildOutput Nothing 0
    let sender = Set.findMin cfg.solConf.sender
        target = cfg.solConf.contractAddr
    body Campaign
      { env, vm, corpusDir = dir
      , set0 = call sender target "set0"
      , set1 = call sender target "set1"
      }
  where
    makeDir = do
      tmp <- getTemporaryDirectory
      let go :: Int -> IO FilePath
          go n = do
            let dir = tmp </> ("echidna-replay-seed-test-" <> show n)
            taken <- doesDirectoryExist dir
            if taken then go (n + 1) else createDirectoryIfMissing True dir >> pure dir
      go 0
    removeDir = removeDirectoryRecursive

call :: Addr -> Addr -> Text -> Int -> Tx
call sender target function arg =
  Tx (SolCall (function, [AbiInt 256 (fromIntegral arg)])) sender target maxGasPerBlock 0 0 (0, 0)

seedArgs :: Text -> [Tx] -> ReplaySeedArgs
seedArgs name txs = ReplaySeedArgs { name, transactions = toJSON txs }

expectReplayed :: Either ReplaySeedError Value -> IO Value
expectReplayed = either (assertFailure . ("seed was not replayed: " <>) . show) pure

expectInvalid :: Either ReplaySeedError Value -> Assertion
expectInvalid = \case
  Left (InvalidSeed _) -> pure ()
  other -> assertFailure ("expected an invalid seed, got: " <> show other)

-- | Nothing of a refused seed reached the campaign: no file, no corpus entry,
-- no coverage. @before@ is the campaign's coverage before the request;
-- deploying the contract already covers its header and initialisers.
assertUntouched :: Campaign -> [Int] -> Assertion
assertUntouched c before = do
  let dir = c.corpusDir </> "coverage"
  exists <- doesDirectoryExist dir
  files <- if exists then listDirectory dir else pure []
  files @?= []
  readIORef c.env.corpusRef >>= (@?= 0) . Set.size
  campaignCoveredLines c.env >>= (@?= before)

-- | Lines of flags.sol the campaign's own coverage maps record as executed.
campaignCoveredLines :: Env -> IO [Int]
campaignCoveredLines env = do
  snapshot <- snapshotCoverage env
  let hits = coverageLineHits env.sourceCache snapshot.merged (Map.elems env.dapp.solcByName) []
  pure $ flagsLines (Map.map (Map.filter (> 0)) hits)

flagsLines :: Map FilePath (Map Int Word64) -> [Int]
flagsLines hits =
  concat [Map.keys fileLines | (file, fileLines) <- Map.toList hits, "flags.sol" `isSuffixOf` file]

-- | Lines of flags.sol in a report's @coverage@ field.
coveredLinesOf :: Value -> [Int]
coveredLinesOf report = case field "coverage" report of
  Just (Object files) ->
    concat [ map (read . K.toString) (KM.keys fileLines)
           | (file, Object fileLines) <- KM.toList files
           , "flags.sol" `isSuffixOf` K.toString file ]
  _ -> []

field :: Text -> Value -> Maybe Value
field key = \case
  Object o -> KM.lookup (K.fromText key) o
  _ -> Nothing

arrayLength :: Value -> Int
arrayLength = \case
  Array xs -> Vector.length xs
  _ -> -1

jsonText :: Value -> Text
jsonText = decodeUtf8 . LBS.toStrict . encode

-- | Every event published so far, oldest first.
drain :: TChan (LocalTime, CampaignEvent) -> IO [CampaignEvent]
drain events = atomically (tryReadTChan events) >>= \case
  Nothing -> pure []
  Just (_, event) -> (event :) <$> drain events

isSaved :: FilePath -> CampaignEvent -> Bool
isSaved file = \case
  ReproducerSaved saved -> saved == file
  _ -> False

toolText :: Value -> Text
toolText response = fromMaybe "" $ do
  result <- field "result" response
  Array content <- field "content" result
  first <- content Vector.!? 0
  String text <- field "text" first
  pure text

toolIsError :: Value -> Bool
toolIsError response = (field "result" response >>= field "isError") == Just (Bool True)

toolProperties :: Text -> Value -> [Text]
toolProperties toolName tools = fromMaybe [] $ do
  Array xs <- field "tools" tools
  tool <- Vector.find (\t -> field "name" t == Just (String toolName)) xs
  Object props <- field "inputSchema" tool >>= field "properties"
  pure $ map K.toText (KM.keys props)

mkState :: Maybe (VM Concrete) -> IO StreamableMCPState
mkState initialVm = do
  eventsRef <- newIORef (StreamableEventBuffer 0 [])
  coverageRef <- newIORef StreamableCoverageNotComputed
  coverageExecutionsRef <- newIORef StreamableCoverageNotComputed
  reproducerCacheRef <- newIORef Map.empty
  initialCorpusReplayRef <- newIORef InitialCorpusReplayComplete
  let started = read "2026-06-06 00:00:00 UTC" :: UTCTime
  pure $ StreamableMCPState eventsRef started 100 1048576 coverageRef coverageExecutionsRef reproducerCacheRef initialCorpusReplayRef initialVm

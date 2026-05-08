module Tests.MCP (mcpTests) where

import Data.Aeson (FromJSON, Result(..), Value(..), fromJSON)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Function ((&))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Word (Word64)
import EVM.Types (Addr(..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

import Common (loadSolTests, overrideQuiet)
import Echidna.Config (defaultConfig)
import Echidna.MCP (recordTestState, runStatus)
import Echidna.MCP.Store (MCPState(..), newMCPState)
import Echidna.MCP.Types (MCPRunCounters(..))
import Echidna.Solidity (compileContracts)
import Echidna.Test (createTest)
import Echidna.Types.Config (EConfig(..), Env(..), MCPConf(..))
import Echidna.Types.Test (EchidnaTest(..), TestState(..), TestType(..))

mcpTests :: TestTree
mcpTests =
  testGroup "MCP tests"
    [ testCase "runStatus exposes monotonic elapsedMs and top-level summary fields" $ do
        let baseCfg = defaultConfig & overrideQuiet
            cfg = baseCfg { mcpConf = baseCfg.mcpConf { enabled = True } }
        (resolvedSolConf, buildOutput) <- compileContracts cfg.solConf (pure "basic/flags.sol")
        (_, env, _) <- loadSolTests (cfg { solConf = resolvedSolConf }) buildOutput Nothing
        st0 <- case env.mcpState of
          Just st -> pure st
          Nothing -> assertFailure "expected MCP state to be enabled" >> error "unreachable"

        nowRef <- newIORef (11500000000 :: Word64)
        let st =
              st0
                { startedAtMonotonicNs = 10000000000
                , monotonicNowNs = readIORef nowRef
                }

        case env.testRefs of
          [test0Ref, test1Ref, test2Ref] -> do
            test0 <- readIORef test0Ref
            test1 <- readIORef test1Ref
            test2 <- readIORef test2Ref
            writeIORef test0Ref test0 { state = Solved }
            writeIORef test1Ref test1 { state = Large 0 }
            writeIORef test2Ref test2 { state = Passed }
          refs ->
            assertFailure $ "expected 3 tests in basic/flags.sol, got " <> show (length refs)

        writeIORef env.corpusRef (Set.fromList [(0, []), (1, [])])
        writeIORef st.counters (MCPRunCounters 42 40 2)

        status1 <- runStatus env st
        writeIORef nowRef 13000000000
        status2 <- runStatus env st

        assertEqual "runs" (42 :: Int) =<< fieldAs "runs" status1
        assertEqual "counters.totalCalls" (42 :: Int) =<< (fieldAs "totalCalls" =<< field "counters" status1)
        assertEqual "tests.total" (3 :: Int) =<< (fieldAs "total" =<< field "tests" status1)
        assertEqual "tests.failed" (2 :: Int) =<< (fieldAs "failed" =<< field "tests" status1)
        assertEqual "corpus.size" (2 :: Int) =<< (fieldAs "size" =<< field "corpus" status1)
        assertEqual "legacy corpusSize" (2 :: Int) =<< fieldAs "corpusSize" status1

        elapsed1 <- fieldAs "elapsedMs" status1
        elapsed2 <- fieldAs "elapsedMs" status2
        assertEqual "elapsedMs first poll" (1500 :: Int) elapsed1
        assertEqual "elapsedMs second poll" (3000 :: Int) elapsed2
        assertBool "elapsedMs should increase with the monotonic clock" (elapsed2 > elapsed1)
    , testCase "fresh reproducer artifacts are not purged before the TTL" $ do
        st <- newMCPState 10 10 10 10 10 10 120 256000 False "campaign"
        let test0 = solvedProperty "echidna_first" 0x100
            test1 = solvedProperty "echidna_second" 0x200

        recordTestState st 0 test0
        recordTestState st 1 test1

        artifacts <- readIORef st.reproducerArtifacts
        assertEqual "fresh artifacts retained" (2 :: Int) (Map.size artifacts)
    ]

solvedProperty :: Text -> Addr -> EchidnaTest
solvedProperty name addr =
  (createTest (PropertyTest name addr)) { state = Solved }

field :: Text -> Value -> IO Value
field name (Object obj) =
  case KM.lookup (K.fromText name) obj of
    Just value -> pure value
    Nothing -> assertFailure ("missing field: " <> show name) >> error "unreachable"
field name value =
  assertFailure ("expected JSON object when looking up " <> show name <> ", got " <> show value) >> error "unreachable"

fieldAs :: FromJSON a => Text -> Value -> IO a
fieldAs name value = do
  value' <- field name value
  case fromJSON value' of
    Success result -> pure result
    Error err ->
      assertFailure ("failed to decode field " <> show name <> ": " <> err) >> error "unreachable"

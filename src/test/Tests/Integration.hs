{-# LANGUAGE LambdaCase #-}

module Tests.Integration (integrationTests) where

import Control.Exception (try)
import Control.Monad (foldM, replicateM, void)
import Control.Monad.Random.Strict (evalRandT)
import Control.Monad.Reader (ReaderT, runReaderT)
import Data.Functor ((<&>))
import Data.IORef (readIORef)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Text (pack, unpack)
import System.Random (mkStdGen)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

import EVM.ABI (AbiValue(..))
import EVM.Types (VM, VMType(Concrete))

import Common (testContract, testContractV, solcV, testContract', checkConstructorConditions, passed, solved, solvedLen, solvedWith, solvedWithout, overrideQuiet)
import Echidna (prepareContract)
import Echidna.ABI (emptyDict, genInteractionsM)
import Echidna.Campaign (runWorker)
import Echidna.Config (parseConfig)
import Echidna.Exec (execTx)
import Echidna.Solidity (compileContracts)
import Echidna.Test (checkETest)
import Echidna.Types.Campaign (CampaignConf(..))
import Echidna.Types.Config (Env(..), EConfig(..), EConfigWithUsage(..))
import Echidna.Types.Signature (ContractName, WeightedSignature(..))
import Echidna.Types.Solidity (SolException(..))
import Echidna.Types.Test (EchidnaTest(..), TestType(..), TestValue(..), didFail)
import Echidna.Types.Tx (Tx(..), TxCall(..))
import Echidna.Types.Worker (WorkerType(..))

integrationTests :: TestTree
integrationTests = testGroup "Solidity Integration Testing"
  [ testContract "basic/true.sol" Nothing
      [ ("echidna_true failed", passed "echidna_true") ]
  , testContract "basic/flags.sol" Nothing
      [ ("echidna_alwaystrue failed",                      passed      "echidna_alwaystrue")
      , ("echidna_revert_always failed",                   passed      "echidna_revert_always")
      , ("echidna_sometimesfalse passed",                  solved      "echidna_sometimesfalse")
      , ("echidna_sometimesfalse didn't shrink optimally", solvedLen 2 "echidna_sometimesfalse")
      ]
  , testContract "basic/flags.sol" (Just "basic/whitelist.yaml")
      [ ("echidna_alwaystrue failed",                      passed      "echidna_alwaystrue")
      , ("echidna_revert_always failed",                   passed      "echidna_revert_always")
      , ("echidna_sometimesfalse passed",                  passed      "echidna_sometimesfalse")
      ]
  , testContract "basic/flags.sol" (Just "basic/whitelist_all.yaml")
      [ ("echidna_alwaystrue failed",                      passed      "echidna_alwaystrue")
      , ("echidna_revert_always failed",                   passed      "echidna_revert_always")
      , ("echidna_sometimesfalse passed",                  solved      "echidna_sometimesfalse")
      ]
  , testContract "basic/flags.sol" (Just "basic/blacklist.yaml")
      [ ("echidna_alwaystrue failed",                      passed      "echidna_alwaystrue")
      , ("echidna_revert_always failed",                   passed      "echidna_revert_always")
      , ("echidna_sometimesfalse passed",                  passed      "echidna_sometimesfalse")
      ]
  , testContract "basic/revert.sol" Nothing
      [ ("echidna_fails_on_revert passed", solved "echidna_fails_on_revert")
      , ("echidna_fails_on_revert didn't shrink to one transaction",
         solvedLen 1 "echidna_fails_on_revert")
      , ("echidna_revert_is_false didn't shrink to f(-1, 0x0, 0xdeadbeef)",
         solvedWith (SolCall ("f", [AbiInt 256 (-1), AbiAddress 0, AbiAddress 0xdeadbeef])) "echidna_fails_on_revert")
      ]
  , testContract "basic/multisender.sol" (Just "basic/multisender.yaml") $
      [ ("echidna_all_sender passed",                      solved             "echidna_all_sender")
      , ("echidna_all_sender didn't shrink optimally",     solvedLen 3        "echidna_all_sender")
      ] ++ (["s1", "s2", "s3"] <&> \n ->
        ("echidna_all_sender solved without " ++ unpack n, solvedWith (SolCall (n, [])) "echidna_all_sender"))
  , testContract "basic/memory-reset.sol" Nothing
      [ ("echidna_memory failed",                  passed      "echidna_memory") ]
  , testContract "basic/contractAddr.sol" (Just "basic/contractAddr.yaml")
      [ ("echidna_address failed",                 passed      "echidna_address") ]
  , testContractV "basic/balance.sol"     (Just (< solcV (0,8,0)))  (Just "basic/balance.yaml")
      [ ("echidna_balance failed",                 passed      "echidna_balance")
      , ("echidna_balance_new failed",             passed      "echidna_balance_new")
      , ("echidna_low_level_call failed",          passed      "echidna_low_level_call")
      , ("echidna_no_magic failed",                passed      "echidna_no_magic")
      ]
  , testContract "basic/library.sol"      (Just "basic/library.yaml")
      [ ("echidna_library_call failed",            solved      "echidna_library_call")
      , ("echidna_valid_timestamp failed",         passed      "echidna_valid_timestamp")
      ]
  , testContractV "basic/fallback.sol"   (Just (< solcV (0,6,0))) Nothing
      [ ("echidna_fallback failed",                solved      "echidna_fallback") ]
  , testContract "basic/push_long.sol" (Just "basic/push_long.yaml")
      [ ("test_long_5 passed",                     solvedWithout NoCall "test_long_5")]
  , testContract "basic/propGasLimit.sol" (Just "basic/propGasLimit.yaml")
      [ ("echidna_runForever passed",              solved      "echidna_runForever") ]
  , testContract "basic/delay.sol"        Nothing
      [ ("echidna_block_number passed",            solved    "echidna_block_number")
      , ("echidna_timestamp passed",               solved    "echidna_timestamp") ]
  , testCase "basic/shrink-revert-delay.sol" $ do
      (vm, env, shrinkBugTest) <- prepareShrinkRevertDelay
      assertBool "expected fuzz_withdraw assertion to be falsified" $ didFail shrinkBugTest

      replayedVm <- flip runReaderT env $ foldM replay vm shrinkBugTest.reproducer
      (replayedValue, _) <- flip runReaderT env $ checkETest shrinkBugTest replayedVm

      assertBool ("expected stored reproducer to remain falsifying, got " ++ show replayedValue) $
        replayedValue == BoolValue False
  , testContractV "basic/immutable.sol"    (Just (>= solcV (0,6,0))) Nothing
      [ ("echidna_test passed",                    solved      "echidna_test") ]
  , testContractV "basic/immutable-2.sol"    (Just (>= solcV (0,6,0))) Nothing
      [ ("echidna_test passed",                    solved      "echidna_test") ]
  , testContract "basic/construct.sol"    Nothing
      [ ("echidna_construct passed",               solved      "echidna_construct") ]
  , testContract "basic/gasprice.sol"     (Just "basic/gasprice.yaml")
      [ ("echidna_state passed",                   solved      "echidna_state") ]
  , testContract' "basic/allContracts.sol" (Just "B") Nothing (Just "basic/allContracts.yaml") True FuzzWorker
      [ ("echidna_test passed",                    solved      "echidna_test") ]
  , testContract "basic/array-mutation.sol"   Nothing
      [ ("echidna_mutated passed",                 solved      "echidna_mutated") ]
  , testContract "basic/darray-mutation.sol"  Nothing
      [ ("echidna_mutated passed",                 solved      "echidna_mutated") ]
  , testContract "basic/gaslimit.sol"  Nothing
      [ ("echidna_gaslimit passed",                passed      "echidna_gaslimit") ]
  , testContract "basic/gasleft.sol"     (Just "basic/gasleft.yaml")
      [ ("unexpected gas left",                    passed      "echidna_expected_gasleft") ]
  ,  checkConstructorConditions "basic/codesize.sol"
      "invalid codesize"
  , testContractV "basic/eip-170.sol" (Just (>= solcV (0,5,0))) (Just "basic/eip-170.yaml")
      [ ("echidna_test passed",                    passed      "echidna_test") ]
  , testContract' "basic/deploy.sol" (Just "Test") Nothing (Just "basic/deployContract.yaml") True FuzzWorker
      [ ("test passed",                    solved     "test") ]
  , testContract' "basic/deploy.sol" (Just "Test") Nothing (Just "basic/deployBytecode.yaml") True FuzzWorker
      [ ("test passed",                    solved     "test") ]
  , testContractV "tstore/tstore.sol" (Just (>= solcV (0,8,25))) Nothing
      [ ("echidna_foo passed", solved "echidna_foo") ]
  , testCase "functionWeights bias fresh function selection" $ do
      let weightedSignatures =
            WeightedSignature
              { signature = ("heavy", [])
              , qualifiedSignature = pack "Test.heavy()"
              , weight = 20
              }
            :| [ WeightedSignature
                   { signature = ("light", [])
                   , qualifiedSignature = pack "Test.light()"
                   , weight = 1
                   }
               ]
      calls <- evalRandT (replicateM 256 (genInteractionsM emptyDict weightedSignatures)) (mkStdGen 7)
      let heavyCount = length [() | ("heavy", _) <- calls]
          lightCount = length [() | ("light", _) <- calls]
      assertBool ("expected heavy calls to dominate, got " ++ show (heavyCount, lightCount)) $
        heavyCount > lightCount
  , testCase "functionWeights reject unknown signatures" $
      assertPrepareContractFailure "basic/flags.sol" Nothing "basic/function-weights-unknown.yaml" $
        \case
          InvalidFunctionWeights [sig] -> sig == pack "Test.missing(int256)"
          _ -> False
  , testCase "functionWeights reject filtered signatures" $
      assertPrepareContractFailure "basic/flags.sol" Nothing "basic/function-weights-filtered.yaml" $
        \case
          InvalidFunctionWeights [sig] -> sig == pack "Test.set0(int256)"
          _ -> False
  , testCase "functionWeights support allContracts mode" $
      void $ prepareContractWithConfig "basic/allContracts.sol" (Just $ pack "B") "basic/allContracts-weighted.yaml"
  ]

prepareContractWithConfig :: FilePath -> Maybe ContractName -> FilePath -> IO ()
prepareContractWithConfig contractPath selectedContract configPath = do
  cfg <- (.econfig) <$> parseConfig configPath
  let cfg' = overrideQuiet cfg
      contractPaths = contractPath :| []
  (resolvedSolConf, buildOutput) <- compileContracts cfg'.solConf contractPaths
  void $ prepareContract (cfg' { solConf = resolvedSolConf }) contractPaths buildOutput selectedContract 0

assertPrepareContractFailure
  :: FilePath
  -> Maybe ContractName
  -> FilePath
  -> (SolException -> Bool)
  -> IO ()
assertPrepareContractFailure contractPath selectedContract configPath predicate = do
  result <- try (prepareContractWithConfig contractPath selectedContract configPath) :: IO (Either SolException ())
  case result of
    Left err | predicate err -> pure ()
             | otherwise -> assertFailure $ "unexpected failure: " ++ show err
    Right _ -> assertFailure "expected contract preparation to fail"

prepareShrinkRevertDelay :: IO (VM Concrete, Env, EchidnaTest)
prepareShrinkRevertDelay = do
  EConfigWithUsage cfg _ _ <- parseConfig "basic/shrink-revert-delay.yaml"
  let cfg' = overrideQuiet cfg
      contractPaths = "basic/shrink-revert-delay.sol" :| []

  seed <- case cfg'.campaignConf.seed of
    Just seed -> pure seed
    Nothing -> assertFailure "missing seed in basic/shrink-revert-delay.yaml" >> fail "unreachable"

  (resolvedSolConf, buildOutput) <- compileContracts cfg'.solConf contractPaths
  let cfg'' = cfg' { solConf = resolvedSolConf }

  (vm, env, dict) <- prepareContract cfg'' contractPaths buildOutput (Just $ pack "ShrinkBug") seed
  void $ flip runReaderT env $
    runWorker FuzzWorker (pure ()) vm dict 0 [] cfg''.campaignConf.testLimit (Just $ pack "ShrinkBug")

  tests <- traverse readIORef env.testRefs
  shrinkBugTest <- case filter isShrinkBugWithdraw tests of
    [test] -> pure test
    [] -> assertFailure "missing fuzz_withdraw assertion test" >> fail "unreachable"
    _ -> assertFailure "multiple fuzz_withdraw assertion tests found" >> fail "unreachable"

  pure (vm, env, shrinkBugTest)
  where
    isShrinkBugWithdraw EchidnaTest { testType = AssertionTest False (name, _) _ } =
      name == pack "fuzz_withdraw"
    isShrinkBugWithdraw _ = False

replay :: VM Concrete -> Tx -> ReaderT Env IO (VM Concrete)
replay vm tx = snd <$> execTx vm tx

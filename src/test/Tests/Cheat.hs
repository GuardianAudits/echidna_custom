module Tests.Cheat (cheatTests) where

import Test.Tasty (TestTree, testGroup)

import Common (testContract', solcV, solved, passed)
import Echidna.Types.Worker (WorkerType(..))

cheatTests :: TestTree
cheatTests =
  testGroup "Cheatcodes Tests"
    [ testContract' "cheat/ffi.sol" (Just "TestFFI") (Just (> solcV (0,5,0))) (Just "cheat/ffi.yaml") False FuzzWorker
        [ ("echidna_ffi passed", solved "echidna_ffi") ]
    , testContract' "cheat/ffi2.sol" (Just "TestFFI") (Just (> solcV (0,5,0))) (Just "cheat/ffi.yaml") False FuzzWorker
        [ ("echidna_ffi passed", solved "echidna_ffi") ]
    , testContract' "cheat/gas.sol" (Just "TestCheatGas") (Just (> solcV (0,5,0))) (Just "cheat/ffi.yaml") False FuzzWorker
        [ ("echidna_gas_zero passed", solved "echidna_gas_zero") ]
    , testContract' "cheat/prank.sol" (Just "TestPrank") (Just (> solcV (0,6,0))) (Just "cheat/prank.yaml") False FuzzWorker
        [ ("withPrank failed",               passed "withPrank")
        , ("withStartPrank failed",          passed "withStartPrank")
        , ("withStartPrankStopPrank failed", passed "withStartPrankStopPrank")
        , ("withNothing failed",             passed "withNothing")
        , ("withDoubleDeploy failed",        passed "withDoubleDeploy")
        ]
    , testContract' "cheat/getCode.sol" (Just "TestGetCode") (Just (> solcV (0,5,0))) (Just "cheat/getCode.yaml") False FuzzWorker
        [ ("echidna_getCode_success_paths failed", passed "echidna_getCode_success_paths")
        , ("echidna_getCode_rejects_bad_inputs failed", passed "echidna_getCode_rejects_bad_inputs")
        ]
    , testContract' "cheat/getCode.sol" (Just "TestGetCodeNoFFI") (Just (> solcV (0,5,0))) (Just "cheat/getCode_noffi.yaml") False FuzzWorker
        [ ("echidna_getCode_reverts_without_allowffi failed", passed "echidna_getCode_reverts_without_allowffi")
        ]
    , testContract' "cheat/invalidUtf8String.sol" (Just "TestInvalidUtf8String") (Just (> solcV (0,8,0))) (Just "cheat/invalidUtf8String.yaml") False FuzzWorker
        [ ("echidna_invalid_utf8_cheatcode_string_is_escaped failed", passed "echidna_invalid_utf8_cheatcode_string_is_escaped")
        ]
    , testContract' "cheat/recordReset.sol" (Just "TestRecordReset") (Just (> solcV (0,8,0))) (Just "cheat/recordReset.yaml") False FuzzWorker
        [ ("recordingEndsWithTx failed", passed "recordingEndsWithTx")
        , ("recordWithinTx failed",      passed "recordWithinTx")
        ]
    , testContract' "cheat/overAskGas.sol" (Just "TestCheatOverAskGas") (Just (> solcV (0,8,0))) (Just "cheat/overAskGas.yaml") False FuzzWorker
        [ ("echidna_over_ask_in_constructor failed", passed "echidna_over_ask_in_constructor")
        , ("echidna_over_ask_in_call failed",        passed "echidna_over_ask_in_call")
        , ("echidna_under_ask_keeps_gas failed",     passed "echidna_under_ask_keeps_gas")
        , ("echidna_failed_cheat_keeps_gas failed",  passed "echidna_failed_cheat_keeps_gas")
        ]
    ]

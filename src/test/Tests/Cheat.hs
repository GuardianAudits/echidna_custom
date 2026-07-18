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
    , testContract' "cheat/rvm.sol" (Just "TestRvm") (Just (>= solcV (0,8,0))) (Just "cheat/rvm.yaml") False FuzzWorker
        [ ("named RVM reads failed", passed "echidna_rvm_reads_named_packed_mapping_and_array")
        , ("raw packed RVM reads failed", passed "echidna_rvm_reads_raw_packed_fields")
        , ("RVM writes failed", passed "echidna_rvm_writes_preserve_adjacent_packed_fields")
        , ("solc JSON layout registration failed", passed "echidna_rvm_accepts_solc_json_layout")
        , ("base-slot namespace RVM reads failed", passed "echidna_rvm_register_namespace_base_slot_loads_decimal_path")
        , ("namespace RVM registrations were not idempotent", passed "echidna_rvm_namespace_registration_upserts_and_preserves_namespaces")
        , ("namespace RVM errors fell back to automatic layouts", passed "echidna_rvm_namespace_errors_do_not_fallback_to_automatic_layout")
        , ("bad RVM layout registrations did not revert immediately", passed "echidna_rvm_rejects_bad_layout_registration_immediately")
        , ("RVM resolution errors escaped as fatal VM failures", passed "echidna_rvm_resolution_errors_revert_only_the_call")
        , ("RVM writes were not rolled back on revert", passed "echidna_rvm_store_is_rolled_back_on_revert")
        ]
    ]

module Tests.Shrinking (shrinkingTests) where

import Test.Tasty (TestTree, testGroup)

import Common (checkShowShrinkingEveryConfig, solved, solvedLen, testContract)

shrinkingTests :: TestTree
shrinkingTests =
  testGroup "Shrinking tests"
    [ testContract "basic/flags.sol" (Just "basic/show-shrinking-test.yaml")
        [ ("showShrinkingEvery config set to 10", checkShowShrinkingEveryConfig (Just 10))
        , ("echidna_sometimesfalse solved with shrinking display enabled", solved "echidna_sometimesfalse")
        , ("echidna_sometimesfalse shrunk to 2 txs with display enabled", solvedLen 2 "echidna_sometimesfalse")
        ]
    , testContract "basic/flags.sol" Nothing
        [ ("echidna_sometimesfalse solved without shrinking display", solved "echidna_sometimesfalse")
        , ("echidna_sometimesfalse shrunk to 2 txs", solvedLen 2 "echidna_sometimesfalse")
        ]
    ]

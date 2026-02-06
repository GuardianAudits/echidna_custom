module Tests.Shrinking (shrinkingTests) where

import Test.Tasty (TestTree, testGroup)

import Common (testContract, solved, solvedLen)

shrinkingTests :: TestTree
shrinkingTests = testGroup "Shrinking tests"
  [ -- Verify shrinking still works correctly with the refactored Shrink.hs
    -- and showShrinkingEvery config option enabled
    testContract "basic/flags.sol" (Just "basic/show-shrinking-test.yaml")
      [ ("echidna_sometimesfalse solved with shrinking display enabled",
          solved "echidna_sometimesfalse")
      , ("echidna_sometimesfalse shrunk to 2 txs with display enabled",
          solvedLen 2 "echidna_sometimesfalse")
      ]

  -- Verify shrinking works without the display option (default behavior)
  , testContract "basic/flags.sol" Nothing
      [ ("echidna_sometimesfalse solved without shrinking display",
          solved "echidna_sometimesfalse")
      , ("echidna_sometimesfalse shrunk to 2 txs",
          solvedLen 2 "echidna_sometimesfalse")
      ]
  ]

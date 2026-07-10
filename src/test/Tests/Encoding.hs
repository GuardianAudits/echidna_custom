module Tests.Encoding (encodingJSONTests) where

import Data.Aeson (encode, decode)
import Data.ByteString qualified as BS
import Data.Map qualified as Map
import Data.Text (pack)
import Data.Text qualified as T
import Data.Vector.Unboxed qualified as VU
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), assertBool, testCase)
import Test.Tasty.QuickCheck (Arbitrary(..), Gen, (===), property, testProperty, resize)

import EVM.Solidity (SourceCache(..))
import EVM.Types (Addr, W256)

import Echidna.Output.Source (coverageLineHits, ppCoveredCode)
import Echidna.Types.Coverage (CoverageFileType(..))
import Echidna.Types.Tx (TxCall(..), Tx(..))

instance Arbitrary Addr where
  arbitrary = fromInteger <$> arbitrary

instance Arbitrary W256 where
  arbitrary = fromInteger <$> arbitrary

instance Arbitrary TxCall where
  arbitrary = do
    s <- arbitrary
    cs <- resize 32 arbitrary
    return $ SolCall (pack s, cs)

instance Arbitrary Tx where
  arbitrary = Tx <$> a <*> a <*> a <*> a <*> a <*> a <*> a
    where a :: Arbitrary a => Gen a
          a = arbitrary

encodingJSONTests :: TestTree
encodingJSONTests =
  testGroup "Tx JSON encoding"
    [ testProperty "decode . encode = id" $ property $ do
        t <- arbitrary :: Gen Tx
        return $ decode (encode t) === Just t
    , testCase "coverage output escapes invalid source bytes" $ do
        let sourceCache = SourceCache
              { files = Map.singleton 0 ("Bad.sol", BS.pack [0x63, 0x6f, 0xfd, 0x0a, 0x6f, 0x6b])
              , lines = mempty
              , asts = mempty
              }
            covMap = Map.singleton (0 :: W256) VU.empty
            output = ppCoveredCode Txt sourceCache [] covMap Nothing "test" [] []
        assertBool "expected escaped invalid byte in coverage output" ("\\xfd" `T.isInfixOf` output)
        coverageLineHits sourceCache covMap [] [] [] @?= Map.singleton "Bad.sol" Map.empty
    ]

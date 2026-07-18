module Tests.RVM (rvmTests) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.String (fromString)
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import EVM.Types (W256, keccak', word256Bytes)

import Echidna.RVM

rvmTests :: TestTree
rvmTests = testGroup "RVM storage layouts"
  [ testCase "parses exact solc JSON and resolves a packed struct member" $ do
      layout <- expectRight $ parseStorageLayout solcLayout
      resolveStoragePath layout "config.fee" BS.empty
        @?= Right (ResolvedSlot 7 16 16)
  , testCase "compact fixed arrays pack primitive elements across words" $ do
      layout <- expectRight $ parseCompactLayout
        "uint8[40] tiny, uint128[4] halves, uint256 after"
      resolveStoragePath layout "tiny" (abiWords [31])
        @?= Right (ResolvedSlot 0 31 1)
      resolveStoragePath layout "tiny" (abiWords [32])
        @?= Right (ResolvedSlot 1 0 1)
      resolveStoragePath layout "halves" (abiWords [3])
        @?= Right (ResolvedSlot 3 16 16)
      resolveStoragePath layout "after" BS.empty
        @?= Right (ResolvedSlot 4 0 32)
  , testCase "dynamic packed arrays derive the data slot and byte offset" $ do
      layout <- expectRight $ parseCompactLayout "uint8[] values"
      let start = keccak' (word256Bytes 0)
      resolveStoragePath layout "values" (abiWords [33])
        @?= Right (ResolvedSlot (start + 1) 1 1)
  , testCase "dynamic arrays reject out-of-bounds indexes when length is available" $ do
      layout <- expectRight $ parseCompactLayout "uint256[] values"
      resolveStoragePathWithLengths readLength layout "values" (abiWords [2])
        @?= Left (ArrayIndexOutOfBounds "uint256[]" 2 2)
  , testCase "nested mappings consume ABI words left to right" $ do
      layout <- expectRight $ parseCompactLayout
        "mapping(address => mapping(uint256 => (uint128 amount, bool live))) positions"
      let firstSlot = keccak' (word256Bytes 1 <> word256Bytes 0)
          finalSlot = keccak' (word256Bytes 2 <> word256Bytes firstSlot)
          keys = abiWords [1, 2]
      resolveStoragePath layout "positions.amount" keys
        @?= Right (ResolvedSlot finalSlot 0 16)
      resolveStoragePath layout "positions.live" keys
        @?= Right (ResolvedSlot finalSlot 16 1)
  , testCase "nested compact structs resolve dotted member paths" $ do
      layout <- expectRight $ parseCompactLayout
        "((uint32 x, bool y) inner, uint256 tail) config"
      resolveStoragePath layout "config.inner.y" BS.empty
        @?= Right (ResolvedSlot 0 4 1)
      resolveStoragePath layout "config.tail" BS.empty
        @?= Right (ResolvedSlot 1 0 32)
      resolveStoragePath layout "config" BS.empty
        @?= Left (ValueSpansMultipleSlots "struct rvm_2" 64)
  , testCase "string mapping keys use unpadded key bytes in the slot hash" $ do
      layout <- expectRight $ parseCompactLayout "mapping(string => uint256) names"
      let expected = keccak' ("alice" <> word256Bytes 0)
      resolveStoragePath layout "names" (abiString "alice")
        @?= Right (ResolvedSlot expected 0 32)
  , testCase "static mapping keys must use canonical ABI words" $ do
      addressLayout <- expectRight $ parseCompactLayout "mapping(address => uint256) accounts"
      uintLayout <- expectRight $ parseCompactLayout "mapping(uint8 => uint256) smalls"
      intLayout <- expectRight $ parseCompactLayout "mapping(int8 => uint256) ints"
      boolLayout <- expectRight $ parseCompactLayout "mapping(bool => uint256) flags"
      bytesLayout <- expectRight $ parseCompactLayout "mapping(bytes4 => uint256) sigs"
      assertInvalidABIKey $
        resolveStoragePath addressLayout "accounts" (BS.singleton 1 <> BS.replicate 31 0)
      assertInvalidABIKey $ resolveStoragePath uintLayout "smalls" (word256Bytes 0x100)
      assertInvalidABIKey $ resolveStoragePath intLayout "ints" (word256Bytes 0xff)
      assertInvalidABIKey $ resolveStoragePath boolLayout "flags" (word256Bytes 2)
      assertInvalidABIKey $ resolveStoragePath bytesLayout "sigs" (word256Bytes 0xdeadbeef)
      let canonicalBytes4 = BS.pack [0xde, 0xad, 0xbe, 0xef] <> BS.replicate 28 0
          expected = keccak' (canonicalBytes4 <> word256Bytes 0)
      resolveStoragePath bytesLayout "sigs" canonicalBytes4
        @?= Right (ResolvedSlot expected 0 32)
  , testCase "fixed arrays reject out-of-bounds indexes" $ do
      layout <- expectRight $ parseCompactLayout "uint16[3] values"
      assertBool "expected a detailed bounds error" $
        case resolveStoragePath layout "values" (abiWords [3]) of
          Left (ArrayIndexOutOfBounds "uint16[3]" 3 3) -> True
          _ -> False
  , testCase "ERC-7201 namespaces preserve relative member slots" $ do
      layout <- expectRight $ parseCompactLayout "uint256 value, address owner"
      namespaced <- expectRight $ applyNamespace "example.main" layout
      let baseSlot = read
            "0x183a6125c38840424c4a85fa12bab2ab606c4b6d0e7cc73c0c06ba5300eab500"
      erc7201Slot "example.main" @?= baseSlot
      resolveStoragePath namespaced "example.main.value" BS.empty
        @?= Right (ResolvedSlot baseSlot 0 32)
      resolveStoragePath namespaced "example.main.owner" BS.empty
        @?= Right (ResolvedSlot (baseSlot + 1) 0 20)
  , testCase "base-slot namespaces use decimal ns labels" $ do
      layout <- expectRight $ parseCompactLayout "bool protocolPaused"
      namespaced <- expectRight $ applyNamespaceAt 123456789 layout
      resolveStoragePath namespaced "ns_123456789.protocolPaused" BS.empty
        @?= Right (ResolvedSlot 123456789 0 1)
  , testCase "layout merge rejects ambiguous duplicate variables" $ do
      left <- expectRight $ parseCompactLayout "uint256 value"
      right <- expectRight $ parseCompactLayout "address value"
      mergeStorageLayouts left right @?= Left (DuplicateVariable "value")
  , testCase "independent namespace structs have collision-free type IDs" $ do
      firstLayout <- expectRight $ parseCompactLayout "(uint128 x, bool live) item"
      secondLayout <- expectRight $ parseCompactLayout "(address owner, uint96 amount) item"
      firstNamespace <- expectRight $ applyNamespace "example.first" firstLayout
      secondNamespace <- expectRight $ applyNamespace "example.second" secondLayout
      merged <- expectRight $ mergeStorageLayouts firstNamespace secondNamespace
      resolveStoragePath merged "example.first.item.live" BS.empty
        @?= Right (ResolvedSlot (erc7201Slot "example.first") 16 1)
      resolveStoragePath merged "example.second.item.amount" BS.empty
        @?= Right (ResolvedSlot (erc7201Slot "example.second") 20 12)
  , testCase "packed extraction and insertion preserve adjacent bytes" $ do
      insertPacked 0x112200 1 1 0xff @?= Right 0x11ff00
      extractPacked 0x11ff00 1 1 @?= Right 0xff
  , testCase "malformed numeric JSON is rejected rather than defaulted" $
      assertBool "expected invalid slot text to fail" $
        case parseStorageLayout invalidSlotLayout of
          Left (LayoutJSONError _) -> True
          _ -> False
  , testCase "inherited duplicate labels load but resolve as ambiguous" $ do
      layout <- expectRight $ parseStorageLayout duplicateLabelLayout
      resolveStoragePath layout "stdstore" BS.empty
        @?= Left (AmbiguousVariable "stdstore" [1, 14])
  ]

expectRight :: (Show error) => Either error value -> IO value
expectRight = either (fail . show) pure

assertInvalidABIKey :: Show a => Either RVMError a -> IO ()
assertInvalidABIKey result =
  assertBool "expected InvalidABIKeys" $
    case result of
      Left (InvalidABIKeys _) -> True
      _ -> False

abiWords :: [W256] -> ByteString
abiWords = BS.concat . map word256Bytes

abiString :: ByteString -> ByteString
abiString bytes =
  word256Bytes 32
    <> word256Bytes (fromIntegral $ BS.length bytes)
    <> bytes
    <> BS.replicate padding 0
  where
    padding = (32 - BS.length bytes `mod` 32) `mod` 32

readLength :: W256 -> Either RVMError W256
readLength 0 = Right 2
readLength slot = Left $ ArrayLengthUnavailable ("unexpected length slot " <> showText slot)

showText :: Show a => a -> Text
showText = fromString . show

solcLayout :: Text
solcLayout =
  "{\"storage\":["
  <> "{\"label\":\"config\",\"offset\":0,\"slot\":\"7\","
  <> "\"type\":\"t_struct(Config)1_storage\"}],"
  <> "\"types\":{\"t_uint128\":{\"encoding\":\"inplace\","
  <> "\"label\":\"uint128\",\"numberOfBytes\":\"16\"},"
  <> "\"t_struct(Config)1_storage\":{\"encoding\":\"inplace\","
  <> "\"label\":\"struct Config\",\"numberOfBytes\":\"32\",\"members\":["
  <> "{\"label\":\"limit\",\"offset\":0,\"slot\":\"0\",\"type\":\"t_uint128\"},"
  <> "{\"label\":\"fee\",\"offset\":16,\"slot\":\"0\",\"type\":\"t_uint128\"}"
  <> "]}}}"

invalidSlotLayout :: Text
invalidSlotLayout =
  "{\"storage\":[{\"label\":\"value\",\"offset\":0,"
  <> "\"slot\":\"not-a-number\",\"type\":\"t_uint256\"}],"
  <> "\"types\":{\"t_uint256\":{\"encoding\":\"inplace\","
  <> "\"label\":\"uint256\",\"numberOfBytes\":\"32\"}}}"

duplicateLabelLayout :: Text
duplicateLabelLayout =
  "{\"storage\":["
  <> "{\"label\":\"stdstore\",\"offset\":0,\"slot\":\"1\",\"type\":\"t_uint256\"},"
  <> "{\"label\":\"stdstore\",\"offset\":0,\"slot\":\"14\",\"type\":\"t_uint256\"}],"
  <> "\"types\":{\"t_uint256\":{\"encoding\":\"inplace\","
  <> "\"label\":\"uint256\",\"numberOfBytes\":\"32\"}}}"

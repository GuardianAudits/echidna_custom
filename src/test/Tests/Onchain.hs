module Tests.Onchain (onchainTests) where

import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

import EVM.Fetch qualified as Fetch

import Echidna.Onchain (fetchWithFallbacks)

onchainTests :: TestTree
onchainTests = testGroup "On-chain RPC"
  [ testCase "rotates away from a failed RPC URL across calls" $ do
      nonce <- Text.pack . show <$> getPOSIXTime
      let primary = "https://primary.example/" <> nonce
          fallback = "https://fallback.example/" <> nonce
          urls = [primary, fallback]
      attempts <- newIORef []

      first <- fetchWithFallbacks urls $ \url -> do
        modifyIORef' attempts (<> [url])
        if url == primary
          then pure $ Fetch.FetchError "connection reset by peer"
          else pure $ Fetch.FetchSuccess ("ok" :: Text) Fetch.Fresh

      assertFetchSuccess first
      assertEqual "first call should try primary then fallback" urls =<< readIORef attempts

      writeIORef attempts []
      second <- fetchWithFallbacks urls $ \url -> do
        modifyIORef' attempts (<> [url])
        pure $ Fetch.FetchSuccess ("ok" :: Text) Fetch.Fresh

      assertFetchSuccess second
      assertEqual "cooled primary should be skipped on the next call" [fallback] =<< readIORef attempts
  ]

assertFetchSuccess :: Fetch.FetchResult Text -> IO ()
assertFetchSuccess (Fetch.FetchSuccess "ok" _) = pure ()
assertFetchSuccess _ = assertFailure "expected FetchSuccess"

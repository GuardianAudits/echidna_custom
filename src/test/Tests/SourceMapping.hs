module Tests.SourceMapping (sourceMappingTests) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_, replicateM, void)
import Data.ByteString qualified as BS
import Data.Foldable (foldl')
import Data.IORef (newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import EVM (initialContract)
import EVM.Dapp (dappInfo, emptyDapp)
import EVM.Solidity (BuildOutput(..), CodeType(..), Contracts(..), Reference(..), SolcContract(..))
import EVM.Types (Contract(..), ContractCode(..), RuntimeCode(..), word256Bytes)

import Echidna.Solidity (readSolcBatch)
import Echidna.Solidity.Foundry (restoreImmutableReferences)
import Echidna.SourceMapping
  (cacheCodehash, findSrcForReal, lookupCodehash, maxCodehashCacheEntries, stripFinalMetadata)
import Echidna.SymExec.Symbolic (forceWord)

sourceMappingTests :: TestTree
sourceMappingTests = testGroup "Source mapping"
  [ testCase "deployment aliases stay bounded and evicted aliases still resolve" $ do
      (build, child) <- fixture "solar-ipfs"
      let dapp = dappInfo "" build
          deployment value = initialContract $
            InitCode (child.creationCode <> word256Bytes value) mempty
          resolve ref value = do
            let contract = deployment value
            lookupCodehash ref (forceWord contract.codehash) contract dapp
      cache <- newIORef Map.empty
      forM_ [1 .. fromIntegral (3 * maxCodehashCacheEntries)] $ \value -> do
        resolve cache value >>= (@?= child.creationCodehash)
        readIORef cache >>= assertBool "unbounded deployment cache" . (<= maxCodehashCacheEntries) . Map.size
      resolve cache 1 >>= (@?= child.creationCodehash)

  , testCase "concurrent cache insertion stays bounded and separates code kinds" $ do
      cache <- newIORef Map.empty
      done <- replicateM 8 newEmptyMVar
      forM_ (zip [0 :: Int ..] done) $ \(worker, signal) -> void $ forkIO $ do
        forM_ [1 .. maxCodehashCacheEntries] $ \i ->
          cacheCodehash cache Runtime (fromIntegral $ worker * maxCodehashCacheEntries + i) 7
        putMVar signal ()
      mapM_ takeMVar done
      readIORef cache >>= assertBool "concurrent cache exceeded its bound" . (<= maxCodehashCacheEntries) . Map.size
      cacheCodehash cache Creation 42 1
      cacheCodehash cache Runtime 42 2
      saved <- readIORef cache
      Map.lookup (Creation, 42) saved @?= Just 1
      Map.lookup (Runtime, 42) saved @?= Just 2

  , testCase "Solar and solc immutables match without an IPFS hash" $
      forM_ ["solar-none", "solc-none"] $ \variant -> do
        (build, child) <- fixture variant
        assertBool "compiler immutable locations were lost" $ not (Map.null child.immutableReferences)
        forM_ [1, 255] $ \value -> do
          let instanceCode = patchImmutables value child
              contract = initialContract $ RuntimeCode $ ConcreteRuntimeCode instanceCode
          fmap (.runtimeCodehash) (findSrcForReal (dappInfo "" build) contract)
            @?= Just child.runtimeCodehash

  , testCase "archived code matches the program despite different metadata" $ do
      (oldBuild, oldChild) <- fixture "solar-ipfs"
      (newBuild, newChild) <- fixture "solar-stored-ipfs"
      assertBool "fixture metadata must differ" $ oldChild.runtimeCode /= newChild.runtimeCode
      let dapp = dappInfo "" newBuild
          runtime = initialContract $ RuntimeCode $ ConcreteRuntimeCode $ patchImmutables 77 oldChild
          creation = initialContract $ InitCode (oldChild.creationCode <> word256Bytes 77) mempty
      fmap (.runtimeCodehash) (findSrcForReal dapp runtime) @?= Just newChild.runtimeCodehash
      fmap (.creationCodehash) (findSrcForReal dapp creation) @?= Just newChild.creationCodehash
      -- The old build still identifies itself, too.
      fmap (.runtimeCodehash) (findSrcForReal (dappInfo "" oldBuild) runtime) @?= Just oldChild.runtimeCodehash

  , testCase "unknown code and changes outside immutable locations stay distinct" $ do
      (build, child) <- fixture "solar-none"
      let changed = BS.cons 0xfe $ BS.drop 1 $ patchImmutables 7 child
          contract = initialContract $ RuntimeCode $ ConcreteRuntimeCode changed
          changedInit = initialContract $ InitCode
            (BS.cons 0xfe $ BS.drop 1 child.creationCode <> word256Bytes 7) mempty
          truncatedInit = initialContract $ InitCode (BS.init child.creationCode) mempty
      findSrcForReal (dappInfo "" build) contract @?= Nothing
      findSrcForReal emptyDapp contract @?= Nothing
      findSrcForReal (dappInfo "" build) changedInit @?= Nothing
      findSrcForReal (dappInfo "" build) truncatedInit @?= Nothing

  , testCase "metadata length comes from the final trailer" $ do
      (_, child) <- fixture "solar-ipfs"
      let withSuffix = child.runtimeCode <> BS.singleton 0xfe
      stripFinalMetadata withSuffix @?= withSuffix
      assertBool "valid final metadata was not removed" $
        BS.length (stripFinalMetadata child.runtimeCode) < BS.length child.runtimeCode
      -- Hash bytes can look like an earlier length field (0x000b at offset 11).
      let marker = BS.pack [0xa2, 0x64, 0x69, 0x70, 0x66, 0x73, 0x58, 0x22]
          (program, metadata) = BS.breakSubstring marker child.runtimeCode
          ambiguous = program <> BS.take 11 metadata <> BS.pack [0, 11] <> BS.drop 13 metadata
      assertBool "fixture has no IPFS metadata" $ not (BS.null metadata)
      stripFinalMetadata ambiguous @?= program

  , testCase "a stale Foundry artifact cannot supply immutable locations" $ do
      raw@(BuildOutput (Contracts contracts) sources) <- rawFixture "solar-none"
      let changed = Map.map (\c -> c { runtimeCode = BS.cons 0xfe $ BS.drop 1 c.runtimeCode }) contracts
      restored <- restoreImmutableReferences ["--foundry-out-directory", "out"]
        (fixtureRoot "solar-none") (BuildOutput (Contracts changed) sources)
      let BuildOutput (Contracts actual) _ = restored
      assertBool "stale locations were used" $ all (Map.null . (.immutableReferences)) actual
      -- Equal runtime bytes alone do not prove that the current constructor
      -- writes the same locations as an older artifact's constructor.
      let changedCreation = Map.map (\c -> c { creationCode = BS.cons 0xfe $ BS.drop 1 c.creationCode }) contracts
      restoredCreation <- restoreImmutableReferences ["--foundry-out-directory", "out"]
        (fixtureRoot "solar-none") (BuildOutput (Contracts changedCreation) sources)
      let BuildOutput (Contracts actualCreation) _ = restoredCreation
      assertBool "stale constructor locations were used" $ all (Map.null . (.immutableReferences)) actualCreation
      -- The unmodified fixture supplies the locations, proving this is not a no-op.
      restoredOriginal <- restoreImmutableReferences ["--foundry-out-directory", "out"]
        (fixtureRoot "solar-none") raw
      assertBool "valid locations were not restored" $ not (Map.null $ (childOf restoredOriginal).immutableReferences)
  ]

fixtureRoot :: String -> FilePath
fixtureRoot variant = "coverage/immutables/" <> variant

rawFixture :: String -> IO BuildOutput
rawFixture variant = mconcat <$> readSolcBatch [] (fixtureRoot variant <> "/export")

fixture :: String -> IO (BuildOutput, SolcContract)
fixture variant = do
  raw <- rawFixture variant
  build <- restoreImmutableReferences ["--foundry-out-directory", "out"] (fixtureRoot variant) raw
  pure (build, childOf build)

childOf :: BuildOutput -> SolcContract
childOf (BuildOutput (Contracts contracts) _) =
  case [c | c <- Map.elems contracts, ":Child" `T.isSuffixOf` c.contractName] of
    [child] -> child
    _ -> error "fixture must contain exactly one Child contract"

patchImmutables :: Int -> SolcContract -> BS.ByteString
patchImmutables value contract =
  foldl' patch contract.runtimeCode (concat $ Map.elems contract.immutableReferences)
  where
  patch bytes (Reference start len) =
    BS.take start bytes <> BS.replicate (len - 1) 0 <> BS.singleton (fromIntegral value)
      <> BS.drop (start + len) bytes

module Tests.LinkedLibraries (linkedLibrariesTests) where

import Control.Exception (bracket)
import Data.List (intercalate)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (unpack)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

import System.Directory
  ( createDirectoryIfMissing, createTempDirectory, getTemporaryDirectory
  , removePathForcibly )
import System.FilePath (takeDirectory, (</>))

import EVM.Types (Addr)

import Echidna.Config (defaultConfig)
import Echidna.Solidity.LinkedLibraries
  ( LibraryLinkInfo(..)
  , autoConfigureFoundryLibraries
  , assignLibraryAddresses
  )
import Echidna.Types.Solidity (SolConf)

linkedLibrariesTests :: TestTree
linkedLibrariesTests = testGroup "Linked library auto-configuration"
  [ testCase "detects bytecode linkReferences" testBytecodeReferences
  , testCase "detects deployedBytecode linkReferences" testDeployedBytecodeReferences
  , testCase "skips malformed link entries" testSkipsMalformedEntries
  , testCase "honors library dependency order" testDependencyOrder
  , testCase "errors on duplicate library names" testDuplicateLibraryNames
  , testCase "respects manual library configuration" testManualLibraryMode
  , testCase "assignLibraryAddresses respects occupancy and max settings" testAssignLibraryAddresses
  ]

testBytecodeReferences :: IO ()
testBytecodeReferences = withFixture
  [("out/Target.json", mkArtifact "Target" [("bytecode", [("src/libs/Math.sol", ["Math"])])])] $ \_ conf -> do
    solved <- requireRight $ autoConfigureFoundryLibraries conf
    assertEqual "compile libraries arg" ["--compile-libraries=(Math,0x10)"] solved.cryticArgs
    assertEqual "library deploy order" [(0x10, "src/libs/Math.sol:Math")] solved.deployContracts

testDeployedBytecodeReferences :: IO ()
testDeployedBytecodeReferences = withFixture
  [("out/Target.json", mkArtifact "Target" [("deployedBytecode", [("src/libs/Math.sol", ["Math"])])])] $ \_ conf -> do
    solved <- requireRight $ autoConfigureFoundryLibraries conf
    assertBool "compile libraries arg generated" $
      "--compile-libraries=(Math,0x10)" `elem` solved.cryticArgs
    assertEqual "library deploy order" [(0x10, "src/libs/Math.sol:Math")] solved.deployContracts

testSkipsMalformedEntries :: IO ()
testSkipsMalformedEntries = withFixture
  [ ( "out/Target.json"
    , mkArtifact "Target" [("bytecode", [("", [""]), ("src/libs/Good.sol", ["", "Good"]), ("", ["Bad"])])
    )
  ] $ \_ conf -> do
    solved <- requireRight $ autoConfigureFoundryLibraries conf
    assertEqual "malformed links are skipped" [(0x10, "src/libs/Good.sol:Good")] solved.deployContracts

testDependencyOrder :: IO ()
testDependencyOrder = withFixture
  [ ("out/LibA.json", mkArtifact "LibA" [])
  , ("out/LibB.json", mkArtifact "LibB" [("bytecode", [("src/libs/LibA.sol", ["LibA"])]) )
  , ("out/Target.json", mkArtifact "Target" [("bytecode", [("src/libs/LibB.sol", ["LibB"])]) )
  ] $ \_ conf -> do
    solved <- requireRight $ autoConfigureFoundryLibraries conf
    assertEqual "dependency order preserves LibA before LibB"
      [(0x10, "src/libs/LibA.sol:LibA"), (0x11, "src/libs/LibB.sol:LibB")]
      solved.deployContracts

testDuplicateLibraryNames :: IO ()
testDuplicateLibraryNames = withFixture
  [ ("out/SourceA.json", mkArtifact "SourceA" [("bytecode", [("src/libs/SourceA.sol", ["Common"])]) )
  , ("out/SourceB.json", mkArtifact "SourceB" [("bytecode", [("src/libs/SourceB.sol", ["Common"])]) )
  ] $ \_ conf -> do
    result <- autoConfigureFoundryLibraries conf
    case result of
      Left _ -> pure ()
      Right _ -> assertFailure "expected duplicate library names error"

testManualLibraryMode :: IO ()
testManualLibraryMode = withFixture
  [("out/Target.json", mkArtifact "Target" [("bytecode", [("src/libs/Math.sol", ["Math"])])])] $ \_ conf -> do
    let manualConf = conf
          { solcLibs = ["Math"]
          , cryticArgs = []
          }
    solved <- requireRight $ autoConfigureFoundryLibraries manualConf
    assertBool "solcLibs disables auto configure" $ null solved.cryticArgs
    assertBool "solcLibs disables deploy injection" $ null solved.deployContracts

testAssignLibraryAddresses :: IO ()
testAssignLibraryAddresses = do
  let occupied :: Set Addr
      occupied = Set.fromList [0x11]
      infos :: [LibraryLinkInfo]
      infos =
        [ LibraryLinkInfo
            { lliName = "LibA"
            , lliSourceFile = "src/libs/LibA.sol"
            , lliKey = "src/libs/LibA.sol:LibA"
            , lliDependencies = mempty
            }
        , LibraryLinkInfo
            { lliName = "LibB"
            , lliSourceFile = "src/libs/LibB.sol"
            , lliKey = "src/libs/LibB.sol:LibB"
            , lliDependencies = mempty
            }
        ]
  case assignLibraryAddresses 0x10 1 occupied infos of
    Left _ -> pure ()
    Right _ -> assertFailure "expected range exhaustion"

  case assignLibraryAddresses 0x10 3 occupied infos of
    Left e -> assertFailure $ "address assignment failed: " ++ e
    Right assigned ->
      assertEqual "skips occupied and assigns remaining in order"
        [(0x10, "src/libs/LibA.sol:LibA"), (0x12, "src/libs/LibB.sol:LibB")]
        [ renderDeployment info addr | (info, addr) <- assigned ]

renderDeployment :: LibraryLinkInfo -> Addr -> (Addr, String)
renderDeployment info addr = (addr, info.lliSourceFile ++ ":" ++ unpack info.lliName)

requireRight :: IO (Either String SolConf) -> IO SolConf
requireRight action = do
  result <- action
  case result of
    Left err -> assertFailure err >> pure defaultConfig.solConf
    Right conf -> pure conf

withFixture
  :: [(FilePath, String)]
  -> (FilePath -> SolConf -> IO a)
  -> IO a
withFixture artifacts action = do
  base <- getTemporaryDirectory
  bracket (createTempDirectory base "echidna-linked-libraries") removePathForcibly $ \root -> do
    let sourcePath = root </> "src" </> "Target.sol"
        conf = defaultConfig.solConf
          { autoLinkLibraries = True
          , autoLinkLibrariesOutDir = Just "out"
          }
    createDirectoryIfMissing True (root </> "src")
    createDirectoryIfMissing True (root </> "out")
    writeFile (root </> "foundry.toml") "out = \"out\"\n"
    writeFile sourcePath "contract Target {}"
    mapM_ (writeArtifact root) artifacts
    action sourcePath conf
  where
    writeArtifact :: FilePath -> (FilePath, String) -> IO ()
    writeArtifact root (relPath, content) = do
      let path = root </> relPath
      createDirectoryIfMissing True (takeDirectory path)
      writeFile path content

mkArtifact :: String -> [(String, [(FilePath, [String])])] -> String
mkArtifact name sections =
  let sectionPairs = [mkSection sec refs | (sec, refs) <- sections]
      sectionJson = if null sectionPairs then "" else intercalate "," sectionPairs
  in "{\"contractName\":\"" ++ name ++ "\"" ++
     (if null sectionJson then "" else "," ++ sectionJson) ++ "}"
  where
  mkSection :: String -> [(FilePath, [String])] -> String
  mkSection sec refs = "\"" ++ sec ++ "\":{\"linkReferences\":" ++ mkLinkReferences refs ++ "}"

  mkLinkReferences :: [(FilePath, [String])] -> String
  mkLinkReferences refs =
    "{" ++ intercalate "," (map mkSource refs) ++ "}"

  mkSource :: (FilePath, [String]) -> String
  mkSource (source, libs) =
    "\"" ++ source ++ "\":{" ++ intercalate "," (map mkLib libs) ++ "}"

  mkLib :: String -> String
  mkLib lib = "\"" ++ lib ++ "\":{}"

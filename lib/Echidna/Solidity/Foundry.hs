-- | What Foundry records about its own builds: which compiler built each
-- compilation unit, and which id that compiler gave each of the unit's files.
--
-- A source map names a file by its compiler id. solc numbers a unit's files in
-- path order, which is the order crytic-compile lists them in, so the position
-- of a file in its export is its id. Solar numbers them in another order, so a
-- unit Foundry built with Solar takes its ids from the build-info that
-- crytic-compile read it from.
module Echidna.Solidity.Foundry
  ( Compiler(..)
  , FoundryBuild(..)
  , compilerFromVersion
  , readFoundryBuilds
  , restoreImmutableReferences
  , foundryOutArg
  , compilerIdsFor
  , foundryPath
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, guard)
import Data.Aeson
  ( FromJSON(..), Value, eitherDecode, eitherDecodeFileStrict, withObject
  , (.:), (.:?), (.!=) )
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy.Char8 qualified as BSL
import Data.Functor ((<&>))
import Data.List (nub, sort)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory, makeAbsolute)
import System.Exit (ExitCode(..))
import System.FilePath
  (joinPath, normalise, splitDirectories, takeBaseName, takeExtension, takeFileName, (</>))
import System.Process (cwd, proc, readCreateProcessWithExitCode)
import Text.Read (readMaybe)

import EVM.Solidity (BuildOutput(..), Contracts(..), Reference(..), SolcContract(..))
import EVM.Types (W256)

data Compiler = Solc | Solar
  deriving (Eq, Show)

-- | Foundry records Solar under versions such as
-- @0.8.38+commit.a2b44354.solar.0.3.0-dev@ and solc under plain ones.
compilerFromVersion :: Text -> Compiler
compilerFromVersion version
  | "solar" `T.isInfixOf` T.toLower version = Solar
  | otherwise = Solc

-- | One Foundry build-info file.
data FoundryBuild = FoundryBuild
  { buildId :: Text
    -- ^ the build-info's file name, which crytic-compile also gives the
    -- unit's export when there are several
  , compiler :: Compiler
  , sourceIds :: Map FilePath Int
    -- ^ the compiler's file ids, keyed by path as Foundry wrote it: relative
    -- to the project root, or absolute for a file outside it
  }
  deriving (Eq, Show)

-- | The builds crytic-compile read for the Foundry project at the given root:
-- every build-info in @<out>/build-info@, where @<out>@ is the
-- @--foundry-out-directory@ crytic-compile was given, or else the active
-- profile's out directory. Each one is a unit of crytic-compile's export.
-- None when the root is not a Foundry project.
readFoundryBuilds :: [String] -> FilePath -> IO [FoundryBuild]
readFoundryBuilds cryticArgs root = do
  isFoundry <- doesFileExist (root </> "foundry.toml")
  if not isFoundry then pure [] else do
    out <- maybe (forgeOut root) pure (foundryOutArg cryticArgs)
    readBuildInfoDir root (root </> out </> "build-info")

-- crytic-compile's combined JSON drops immutable locations. Recover them from
-- the corresponding Foundry artifact, but only when its complete bytecode
-- matches this export. A stale artifact must never mask code bytes.
restoreImmutableReferences :: [String] -> FilePath -> BuildOutput -> IO BuildOutput
restoreImmutableReferences args root original@(BuildOutput (Contracts contracts) sources) = do
  isFoundry <- doesFileExist (root </> "foundry.toml")
  if not isFoundry then pure original else do
    out <- maybe (forgeOut root) pure (foundryOutArg args)
    restored <- traverse (restore (root </> out)) contracts
    pure $ BuildOutput (Contracts restored) sources
  where
  restore out contract
    | BS.null contract.runtimeCode || not (Map.null contract.immutableReferences) = pure contract
    | otherwise = do
        let (source, name) = T.breakOnEnd ":" contract.contractName
            path = out </> takeFileName (T.unpack $ T.dropEnd 1 source)
                       </> T.unpack name <> ".json"
        exists <- doesFileExist path
        artifact <- if exists then either (const Nothing) Just <$> eitherDecodeFileStrict path
                              else pure Nothing
        pure $ case artifact >>= parseMaybe runtimeReferences of
          Just (creation, runtime, refs)
            | matches creation contract.creationCode
            , matches runtime contract.runtimeCode
            , all (validReference $ BS.length contract.runtimeCode) (concat $ Map.elems refs)
            -> contract { immutableReferences = refs }
          _ -> contract

  validReference size (Reference start len) =
    start >= 0 && len > 0 && len <= size && start <= size - len

  matches code bytes =
    T.toLower (maybe code id $ T.stripPrefix "0x" code)
      == TE.decodeUtf8 (Base16.encode bytes)

  runtimeReferences :: Value -> Parser (Text, Text, Map W256 [Reference])
  runtimeReferences = withObject "artifact" $ \artifact -> do
    creation <- artifact .: "bytecode" >>= withObject "creation bytecode" (.: "object")
    deployed <- artifact .: "deployedBytecode"
    withObject "deployed bytecode" (\code ->
      (creation,,) <$> code .: "object" <*> code .:? "immutableReferences" .!= mempty) deployed

-- | The out directory crytic-compile's @--foundry-out-directory@ names.
foundryOutArg :: [String] -> Maybe FilePath
foundryOutArg args = listToMaybe $ mapMaybe outDir (zip args (drop 1 args <> [""]))
  where
  outDir ("--foundry-out-directory", dir) | not (null dir) = Just dir
  outDir (arg, _) = T.unpack <$> T.stripPrefix "--foundry-out-directory=" (T.pack arg)

newtype ForgeOut = ForgeOut FilePath

instance FromJSON ForgeOut where
  parseJSON = withObject "forge config" $ \o -> ForgeOut <$> o .:? "out" .!= "out"

-- | The active profile's out directory, as @forge config@ resolves it, or
-- Foundry's default when forge can't tell.
forgeOut :: FilePath -> IO FilePath
forgeOut root = do
  result <- try (readCreateProcessWithExitCode (proc "forge" ["config", "--json"]) { cwd = Just root } "")
  pure $ case result :: Either IOException (ExitCode, String, String) of
    Right (ExitSuccess, out, _) | Right (ForgeOut dir) <- eitherDecode (BSL.pack out) -> dir
    _ -> "out"

-- | Every readable build-info file in a directory.
readBuildInfoDir :: FilePath -> FilePath -> IO [FoundryBuild]
readBuildInfoDir root dir = do
  exists <- doesDirectoryExist dir
  if not exists then pure [] else do
    files <- sort . filter ((== ".json") . takeExtension) <$> listDirectory dir
    absRoot <- makeAbsolute root
    fmap catMaybes $ forM files $ \file -> do
      info <- either (const Nothing) Just <$> eitherDecodeFileStrict (dir </> file)
      pure $ info <&> \(BuildInfo version ids) -> FoundryBuild
        { buildId = T.pack (takeBaseName file)
        , compiler = maybe Solc compilerFromVersion version
        , sourceIds = Map.mapKeys (foundryPath absRoot) ids
        }

-- | A build-info file's compiler version and file ids, keyed by path relative
-- to the project root. Newer Foundry versions write the ids as
-- @source_id_to_path@, older ones only in the compiler output.
data BuildInfo = BuildInfo
  { version :: Maybe Text
  , ids :: Map FilePath Int
  }

instance FromJSON BuildInfo where
  parseJSON = withObject "build-info" $ \o -> do
    version <- o .:? "solcLongVersion"
    ids <- o .:? "source_id_to_path" >>= \case
      Just byId -> Map.fromList <$> mapM swap (Map.toList (byId :: Map Text FilePath))
      Nothing -> do
        output <- o .: "output"
        sources <- output .: "sources" :: Parser (Map FilePath Value)
        traverse (withObject "source" (.: "id")) sources
    pure BuildInfo { version, ids }
    where
    swap (i, path) = maybe (fail $ "source id is not a number: " <> T.unpack i)
                           (pure . (path,)) (readMaybe (T.unpack i))

-- | A file outside the project root is written relative to it (@../x.sol@),
-- so it is turned into an absolute path, without resolving links: the case of
-- a path matters, since two imports of one file that differ only in case are
-- two files to the compiler.
foundryPath :: FilePath -> FilePath -> FilePath
foundryPath absRoot path
  | ".." `elem` splitDirectories path = collapse (absRoot </> path)
  | otherwise = normalise path
  where
  collapse = joinPath . reverse . foldl step [] . splitDirectories
  step (dir : dirs) ".." | dir /= "/" = dirs
  step dirs "." = dirs
  step dirs part = part : dirs

-- | The compiler ids of a unit's files, keyed by the ids hevm gave them, when
-- Foundry built the unit with Solar. The unit is the build that lists exactly
-- its files: crytic-compile's paths may be absolute, so each one matches the
-- longest trailing part of it that the build lists. 'Left' explains why a
-- Solar unit could not be matched; 'Right Nothing' means the unit's position
-- ids are already the compiler's.
compilerIdsFor :: [FoundryBuild] -> Map Int FilePath -> Either String (Maybe (Map Int Int))
compilerIdsFor builds files =
  case nub [ (b.compiler, ids) | b <- builds, Just ids <- [idsIn b] ] of
    [] | any ((== Solar) . (.compiler)) builds ->
           Left "no Solar build-info lists exactly this unit's files"
       | otherwise -> Right Nothing
    [(Solc, _)] -> Right Nothing
    [(Solar, ids)] -> Right (Just ids)
    matches
      | all ((== Solc) . fst) matches -> Right Nothing
      | otherwise ->
          Left "several build-infos list this unit's files with different ids"
  where
  idsIn build = do
    guard (Map.size build.sourceIds == Map.size files)
    ids <- traverse (lookupPathSuffix build.sourceIds) files
    guard (length (nub (Map.elems ids)) == Map.size ids)
    pure ids

-- | The entry for the longest trailing part of a path that the map lists.
lookupPathSuffix :: Map FilePath a -> FilePath -> Maybe a
lookupPathSuffix m path = listToMaybe $ mapMaybe (`Map.lookup` m) suffixes
  where
  parts = splitDirectories (normalise path)
  suffixes = [joinPath (drop n parts) | n <- [0 .. length parts - 1]]

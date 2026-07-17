module Echidna.RVM.Artifacts
  ( findFoundryProjectRoot
  , loadFoundryStorageLayouts
  , loadFoundryStorageLayoutsFromCurrentDirectory
  , loadStorageLayoutsFromArtifacts
  ) where

import Control.Applicative ((<|>))
import Control.Exception (IOException, displayException, try)
import Control.Monad (foldM, forM)
import Data.Aeson (Value(..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.Char (toLower)
import Data.Foldable (toList)
import Data.List (foldl', isSuffixOf, nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , findExecutable
  , getCurrentDirectory
  , listDirectory
  , makeAbsolute
  , pathIsSymbolicLink
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.FilePath
  ( hasExtension
  , isAbsolute
  , normalise
  , takeBaseName
  , takeDirectory
  , takeExtension
  , takeFileName
  , (</>)
  )
import System.Process qualified as Process

import Echidna.RVM (StorageLayout, parseStorageLayoutValue)

-- | Find the closest Foundry project containing the supplied path. The path may
-- name either a directory or a source file. A path outside a Foundry project is
-- deliberately not an error because Echidna also supports non-Foundry inputs.
findFoundryProjectRoot :: FilePath -> IO (Maybe FilePath)
findFoundryProjectRoot start = do
  absolute <- normalise <$> makeAbsolute start
  isDirectory <- doesDirectoryExist absolute
  isFile <- doesFileExist absolute
  let initialDirectory
        | isDirectory = absolute
        | isFile || hasExtension absolute = takeDirectory absolute
        | otherwise = absolute
  go initialDirectory
  where
    go directory = do
      found <- doesFileExist (directory </> "foundry.toml")
      if found
        then pure (Just directory)
        else do
          let parent = takeDirectory directory
          if parent == directory then pure Nothing else go parent

-- | Find, build, and load storage layouts for the Foundry project containing a
-- path. When @forge@ is unavailable, existing artifacts are still usable. Build
-- and configuration failures are returned with command output for caller logs.
loadFoundryStorageLayouts
  :: FilePath
  -> IO (Either Text (Map Text StorageLayout))
loadFoundryStorageLayouts start = do
  result <- tryIO (loadFoundryStorageLayoutsUnchecked start)
  pure $ first (renderIOException "loading Foundry storage layouts" start) result >>= id

-- | Convenience wrapper for callers whose project context is the process cwd.
loadFoundryStorageLayoutsFromCurrentDirectory
  :: IO (Either Text (Map Text StorageLayout))
loadFoundryStorageLayoutsFromCurrentDirectory =
  getCurrentDirectory >>= loadFoundryStorageLayouts

-- | Load already-built layouts from an artifact directory without invoking
-- Foundry. This is useful when another compiler step has just produced output.
loadStorageLayoutsFromArtifacts
  :: FilePath
  -> IO (Either Text (Map Text StorageLayout))
loadStorageLayoutsFromArtifacts artifactDirectory = do
  result <- tryIO (loadStorageLayoutsFromArtifactsUnchecked artifactDirectory)
  pure $ first (renderIOException "reading storage-layout artifacts" artifactDirectory) result >>= id

loadFoundryStorageLayoutsUnchecked
  :: FilePath
  -> IO (Either Text (Map Text StorageLayout))
loadFoundryStorageLayoutsUnchecked start = findFoundryProjectRoot start >>= \case
  Nothing -> pure (Right Map.empty)
  Just projectRoot -> do
    forge <- findExecutable "forge"
    outputDirectoryResult <- case forge of
      Just forgeExecutable -> findConfiguredOutput forgeExecutable projectRoot
      Nothing -> Right <$> findConfiguredOutputWithoutForge projectRoot
    case outputDirectoryResult of
      Left err -> pure (Left err)
      Right outputDirectory -> do
        buildResult <- case forge of
          Nothing -> pure (Right ())
          Just forgeExecutable -> runForgeBuild forgeExecutable projectRoot
        case buildResult of
          Left err -> pure (Left err)
          Right () -> do
            outputExists <- doesDirectoryExist outputDirectory
            if outputExists
              then fmap (fmap $ addProjectRootAliases projectRoot) $
                loadStorageLayoutsFromArtifactsUnchecked outputDirectory
              else pure . Left $
                "Foundry artifact directory does not exist: " <> T.pack outputDirectory
                <> if forge == Nothing
                     then " (forge is unavailable, so existing artifacts are required)"
                     else " (forge build succeeded but did not create the configured output directory)"

findConfiguredOutput
  :: FilePath
  -> FilePath
  -> IO (Either Text FilePath)
findConfiguredOutput forgeExecutable projectRoot = do
  let arguments = ["config", "--json", "--root", projectRoot]
      command = "forge config --json --root " <> projectRoot
  (exitCode, stdout, stderr) <- Process.readCreateProcessWithExitCode
    (Process.proc forgeExecutable arguments) { Process.cwd = Just projectRoot }
    ""
  pure $ case exitCode of
    ExitFailure _ -> Left $ renderCommandFailure command projectRoot exitCode stdout stderr
    ExitSuccess -> case eitherDecodeStrict' (TE.encodeUtf8 $ T.pack stdout) of
      Left decodeError -> Left $
        "Unable to decode `" <> T.pack command <> "` output: " <> T.pack decodeError
        <> "\nstdout:\n" <> T.pack stdout
        <> "\nstderr:\n" <> T.pack stderr
      Right (Object config) -> case KeyMap.lookup "out" config of
        Just (String outputDirectory) ->
          Right $ resolveFromProjectRoot projectRoot (T.unpack outputDirectory)
        _ -> Left $
          "`" <> T.pack command <> "` did not return a string `out` setting"
          <> "\nstdout:\n" <> T.pack stdout
      Right _ -> Left $
        "`" <> T.pack command <> "` returned JSON that was not an object"
        <> "\nstdout:\n" <> T.pack stdout

findConfiguredOutputWithoutForge :: FilePath -> IO FilePath
findConfiguredOutputWithoutForge projectRoot = do
  environmentOutput <- lookupEnv "FOUNDRY_OUT"
  activeProfile <- T.pack . fromMaybe "default" <$> lookupEnv "FOUNDRY_PROFILE"
  config <- TIO.readFile (projectRoot </> "foundry.toml")
  let outputDirectory = fromMaybe "out" $
        nonEmptyString environmentOutput
        <|> (T.unpack <$> findTomlOutput activeProfile config)
  pure $ resolveFromProjectRoot projectRoot outputDirectory
  where
    nonEmptyString = \case
      Just value | not (null value) -> Just value
      _ -> Nothing

runForgeBuild :: FilePath -> FilePath -> IO (Either Text ())
runForgeBuild forgeExecutable projectRoot = do
  let arguments = ["build", "--build-info", "--extra-output", "storageLayout"]
      command = "forge build --build-info --extra-output storageLayout"
  (exitCode, stdout, stderr) <- Process.readCreateProcessWithExitCode
    (Process.proc forgeExecutable arguments) { Process.cwd = Just projectRoot }
    ""
  pure $ case exitCode of
    ExitSuccess -> Right ()
    ExitFailure _ -> Left $ renderCommandFailure command projectRoot exitCode stdout stderr

renderCommandFailure :: String -> FilePath -> ExitCode -> String -> String -> Text
renderCommandFailure command workingDirectory exitCode stdout stderr =
  "Command failed in " <> T.pack workingDirectory
  <> ": `" <> T.pack command <> "` (" <> T.pack (show exitCode) <> ")"
  <> "\nstdout:\n" <> T.pack stdout
  <> "\nstderr:\n" <> T.pack stderr

resolveFromProjectRoot :: FilePath -> FilePath -> FilePath
resolveFromProjectRoot projectRoot configuredPath
  | isAbsolute configuredPath = normalise configuredPath
  | otherwise = normalise (projectRoot </> configuredPath)

loadStorageLayoutsFromArtifactsUnchecked
  :: FilePath
  -> IO (Either Text (Map Text StorageLayout))
loadStorageLayoutsFromArtifactsUnchecked artifactDirectory = do
  files <- collectArtifactFiles artifactDirectory
  indexed <- foldM loadOne (Right Map.empty) files
  pure $ Map.mapMaybe id <$> indexed
  where
    loadOne (Left err) _ = pure (Left err)
    loadOne (Right layouts) path = do
      bytes <- BS.readFile path
      pure $ case eitherDecodeStrict' bytes of
        -- The output tree can contain compiler cache, metadata, and arbitrary
        -- JSON. A file is an artifact only if it has a storageLayout member.
        Left _ -> Right layouts
        Right value -> case parseArtifactStorageLayout path value of
          Left err -> Left err
          Right Nothing -> Right layouts
          Right (Just (names, layout)) -> Right $
            foldl' (insertLayout layout) layouts names

    insertLayout layout layouts name = insertIndexedLayout name layout layouts

type LayoutIndex = Map Text (Maybe StorageLayout)

-- Keep an alias only while every artifact that claims it has the same layout.
-- Projects commonly contain duplicate simple contract names; silently taking
-- the first makes automatic and explicit assignments depend on directory order.
insertIndexedLayout :: Text -> StorageLayout -> LayoutIndex -> LayoutIndex
insertIndexedLayout name layout = Map.alter update name
  where
    update Nothing = Just (Just layout)
    update (Just (Just existing))
      | existing == layout = Just (Just existing)
      | otherwise = Just Nothing
    update (Just Nothing) = Just Nothing

addProjectRootAliases :: FilePath -> Map Text StorageLayout -> Map Text StorageLayout
addProjectRootAliases projectRoot layouts =
  Map.mapMaybe id $ foldl' addAlias initial (Map.toList layouts)
  where
    initial = Just <$> layouts
    addAlias index (name, layout) = case splitQualifiedName name of
      Nothing -> index
      Just (source, contractName) ->
        let absoluteSource = if isAbsolute (T.unpack source)
              then normalise (T.unpack source)
              else normalise (projectRoot </> T.unpack source)
            absoluteName = T.pack absoluteSource <> ":" <> contractName
        in insertIndexedLayout absoluteName layout index

splitQualifiedName :: Text -> Maybe (Text, Text)
splitQualifiedName name = do
  let (sourceWithColon, contractName) = T.breakOnEnd ":" name
  source <- T.stripSuffix ":" sourceWithColon
  if T.null source || T.null contractName
    then Nothing
    else Just (source, contractName)

collectArtifactFiles :: FilePath -> IO [FilePath]
collectArtifactFiles = walk
  where
    walk directory = do
      entries <- sort <$> listDirectory directory
      fmap concat . forM entries $ \entry -> do
        let path = directory </> entry
        isDirectory <- doesDirectoryExist path
        if isDirectory
          then do
            symbolicLink <- pathIsSymbolicLink path
            if symbolicLink || ignoredDirectory entry then pure [] else walk path
          else pure [path | isArtifactCandidate entry]

    ignoredDirectory entry =
      map toLower entry `elem` ["build-info", "cache", "cache_forge", "cache_hardhat"]

    isArtifactCandidate entry =
      let lower = map toLower entry
      in takeExtension lower == ".json"
         && not ("." `isPrefixOfString` lower)
         && not (".dbg.json" `isSuffixOf` lower)
         && not (".metadata.json" `isSuffixOf` lower)
         && lower /= "cache.json"
         && lower /= "solidity-files-cache.json"

    isPrefixOfString prefix value = take (length prefix) value == prefix

parseArtifactStorageLayout
  :: FilePath
  -> Value
  -> Either Text (Maybe ([Text], StorageLayout))
parseArtifactStorageLayout path artifact@(Object object) =
  case KeyMap.lookup "storageLayout" object of
    Nothing -> Right Nothing
    Just Null -> Right Nothing
    Just layoutValue
      | isEmptyInterface object layoutValue -> Right Nothing
      | otherwise -> case parseStorageLayoutValue layoutValue of
          Left err -> Left $
            "Unable to parse storageLayout in " <> T.pack path <> ": " <> T.pack (show err)
          Right layout -> Right . Just $ (artifactContractNames path artifact layoutValue, layout)
parseArtifactStorageLayout _ _ = Right Nothing

-- Interfaces have no bytecode and an explicitly empty storage list. Abstract
-- contracts with declared storage are retained so their layouts can be assigned.
isEmptyInterface :: KeyMap.KeyMap Value -> Value -> Bool
isEmptyInterface artifact layoutValue =
  hasExplicitlyEmptyStorage layoutValue && hasEmptyBytecode artifact
  where
    hasExplicitlyEmptyStorage (Object layout) = case KeyMap.lookup "storage" layout of
      Just (Array entries) -> null entries
      _ -> False
    hasExplicitlyEmptyStorage _ = False

    hasEmptyBytecode object = case KeyMap.lookup "bytecode" object of
      Just (Object bytecode) -> case KeyMap.lookup "object" bytecode of
        Just (String value) -> T.null value || value == "0x"
        _ -> False
      _ -> False

artifactContractNames :: FilePath -> Value -> Value -> [Text]
artifactContractNames path artifact layoutValue =
  nub . filter (not . T.null) $
    simpleNames <> qualifiedNames
  where
    artifactName = T.pack (takeBaseName path)
    layoutNames = storageLayoutContractNames layoutValue
    targets = compilationTargets artifact
    simpleNames =
      artifactName
      : mapMaybe simpleNameFromQualified layoutNames
      <> map snd targets
    qualifiedNames =
      layoutNames
      <> [qualify source contractName | (source, contractName) <- targets]
      <> maybe [] (pure . (`qualify` artifactName)) (artifactAbsolutePath artifact)
      <> [qualify (T.pack . takeFileName . takeDirectory $ path) artifactName]

storageLayoutContractNames :: Value -> [Text]
storageLayoutContractNames (Object layout) = case KeyMap.lookup "storage" layout of
  Just (Array entries) -> mapMaybe contractName (toList entries)
  _ -> []
  where
    contractName (Object entry) = case KeyMap.lookup "contract" entry of
      Just (String name) -> Just (normaliseSourceName name)
      _ -> Nothing
    contractName _ = Nothing
storageLayoutContractNames _ = []

compilationTargets :: Value -> [(Text, Text)]
compilationTargets (Object artifact) =
  maybe [] targetsFromMetadata (KeyMap.lookup "metadata" artifact >>= metadataValue)
  where
    metadataValue value@(Object _) = Just value
    metadataValue (String encoded) =
      either (const Nothing) Just (eitherDecodeStrict' $ TE.encodeUtf8 encoded)
    metadataValue _ = Nothing

    targetsFromMetadata (Object metadata) =
      case KeyMap.lookup "settings" metadata of
        Just (Object settings) -> case KeyMap.lookup "compilationTarget" settings of
          Just (Object targets) ->
            [ (normaliseSourceName $ Key.toText source, contractName)
            | (source, String contractName) <- KeyMap.toList targets
            ]
          _ -> []
        _ -> []
    targetsFromMetadata _ = []
compilationTargets _ = []

artifactAbsolutePath :: Value -> Maybe Text
artifactAbsolutePath (Object artifact) = case KeyMap.lookup "ast" artifact of
  Just (Object ast) -> case KeyMap.lookup "absolutePath" ast of
    Just (String path) -> Just (normaliseSourceName path)
    _ -> Nothing
  _ -> Nothing
artifactAbsolutePath _ = Nothing

qualify :: Text -> Text -> Text
qualify source contractName = normaliseSourceName source <> ":" <> contractName

normaliseSourceName :: Text -> Text
normaliseSourceName = T.replace "\\" "/"

simpleNameFromQualified :: Text -> Maybe Text
simpleNameFromQualified qualified = case T.breakOnEnd ":" qualified of
  (prefix, name) | not (T.null prefix) && not (T.null name) -> Just name
  _ -> Nothing

findTomlOutput :: Text -> Text -> Maybe Text
findTomlOutput activeProfile input =
  listToMaybe . mapMaybe (`Map.lookup` values) $
    ["profile." <> activeProfile]
    <> ["profile.default" | activeProfile /= "default"]
    <> ["default", ""]
  where
    (_, values) = foldl' parseLine ("", Map.empty) (T.lines input)

    parseLine (section, outputs) rawLine =
      let line = T.strip (stripTomlComment rawLine)
      in case parseTomlSection line of
        Just nextSection -> (nextSection, outputs)
        Nothing -> case parseTomlOutput line of
          Just output -> (section, Map.insert section output outputs)
          Nothing -> (section, outputs)

parseTomlSection :: Text -> Maybe Text
parseTomlSection line = do
  body <- T.stripPrefix "[" line >>= T.stripSuffix "]"
  if T.null body || T.isPrefixOf "[" body
    then Nothing
    else Just (T.strip body)

parseTomlOutput :: Text -> Maybe Text
parseTomlOutput line = do
  let (key, rest) = T.breakOn "=" line
  value <- T.stripPrefix "=" rest
  if T.strip key == "out" then parseTomlString (T.strip value) else Nothing

parseTomlString :: Text -> Maybe Text
parseTomlString value = case T.uncons value of
  Just ('\'', rest) -> nonEmptyText (fst $ T.breakOn "'" rest)
  Just ('"', _) -> case reads (T.unpack value) :: [(String, String)] of
    [(decoded, _)] -> nonEmptyText (T.pack decoded)
    _ -> Nothing
  _ -> nonEmptyText . T.takeWhile (not . (`elem` [' ', '\t'])) $ value

stripTomlComment :: Text -> Text
stripTomlComment = T.pack . go Nothing False . T.unpack
  where
    go _ _ [] = []
    go Nothing _ ('#':_) = []
    go quote escaped (character:rest)
      | escaped = character : go quote False rest
      | quote == Just '"' && character == '\\' = character : go quote True rest
      | quote == Just character = character : go Nothing False rest
      | quote == Nothing && character `elem` ['\'', '"'] =
          character : go (Just character) False rest
      | otherwise = character : go quote False rest

nonEmptyText :: Text -> Maybe Text
nonEmptyText value
  | T.null value = Nothing
  | otherwise = Just value

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

renderIOException :: Text -> FilePath -> IOException -> Text
renderIOException action path exception =
  "I/O error while " <> action <> " for " <> T.pack path <> ": "
  <> T.pack (displayException exception)

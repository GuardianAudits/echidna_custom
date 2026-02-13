{-# LANGUAGE LambdaCase #-}

module Echidna.Solidity.LinkedLibraries where

import Control.Applicative ((<|>))
import Control.Monad (forM, unless)
import Data.Aeson (Object, Value(..), eitherDecodeStrict')
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.List (intercalate, isPrefixOf, isSuffixOf, sort)
import Data.Map (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, listToMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import EVM.Types (Addr)
import System.Directory (doesDirectoryExist, doesFileExist, findExecutable, listDirectory)
import System.Exit (ExitCode(..))
import System.FilePath (isRelative, (</>), takeBaseName, takeDirectory, takeFileName)
import System.IO (hPutStrLn, stderr)
import System.Process (readCreateProcessWithExitCode, proc)

import Echidna.Types.Solidity

-- | Information about a discovered Solidity library.
data LibraryLinkInfo = LibraryLinkInfo
  { lliName :: Text
  , lliSourceFile :: FilePath
  , lliKey :: Text
  , lliDependencies :: Set Text
  } deriving (Eq, Ord, Show)

-- | Find the foundry root for a CLI path.
findFoundryRoot :: FilePath -> IO FilePath
findFoundryRoot fp = do
  isFile <- doesFileExist fp
  isDir <- doesDirectoryExist fp
  let start = if isFile then takeDirectory fp else fp
  let root = if isDir then fp else start
  climb root
  where
    climb :: FilePath -> IO FilePath
    climb dir = do
      hasToml <- doesFileExist (dir </> "foundry.toml")
      if hasToml
        then pure dir
        else do
          let parent = takeDirectory dir
          if parent == dir then pure dir else climb parent

-- | Resolve the foundry output directory.
-- If not provided by config, fallback to `foundry.toml` `out = ...` or `out`.
getFoundryOutDir :: FilePath -> Maybe FilePath -> IO FilePath
getFoundryOutDir root mOut = do
  outDir <- case mOut of
    Just out -> pure out
    Nothing -> do
      mFromToml <- parseFoundryOut root
      pure $ maybe "out" id mFromToml
  pure $ if isRelative outDir then root </> outDir else outDir

-- | Parse foundry.toml and read the configured out directory.
parseFoundryOut :: FilePath -> IO (Maybe FilePath)
parseFoundryOut root = do
  let path = root </> "foundry.toml"
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else parseFoundryTomlOut <$> readFile path

parseFoundryTomlOut :: String -> Maybe FilePath
parseFoundryTomlOut = listToMaybe . mapMaybe parseLine . lines
  where
    parseLine :: String -> Maybe FilePath
    parseLine line =
      let cleaned = trim (takeWhile (/= '#') line)
          (rawKey, rawValue) = splitEq cleaned
      in if T.strip (T.pack rawKey) == "out"
           then parseTomlValue rawValue
           else Nothing

    splitEq :: String -> (String, String)
    splitEq s = case break (== '=') s of
      (k, '=':v) -> (k, v)
      (k, _) -> (k, [])

    parseTomlValue :: String -> Maybe FilePath
    parseTomlValue raw = do
      let v = T.strip (T.pack raw)
      if T.null v
        then Nothing
        else if T.length v >= 2 && sameQuote v
               then Just $ T.unpack $ T.init (T.tail v)
               else Just $ T.unpack v
      where
        sameQuote t =
          (T.head t == '"' && T.last t == '"') || (T.head t == '\'' && T.last t == '\'')

    trim :: String -> String
    trim = T.unpack . T.strip . T.pack

-- | Collect all foundry artifact json files under a directory.
collectArtifactJsons :: FilePath -> IO [FilePath]
collectArtifactJsons root = do
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else sort <$> go root
  where
    shouldSkipDir :: FilePath -> Bool
    shouldSkipDir fp = takeFileName fp `elem` ["build-info", "kompiled"]

    isMetadataJson :: FilePath -> Bool
    isMetadataJson fp = ".metadata.json" `isSuffixOf` fp

    isJson :: FilePath -> Bool
    isJson fp = ".json" `isSuffixOf` fp

    go :: FilePath -> IO [FilePath]
    go dir = do
      entries <- listDirectory dir
      concat <$> forM entries $ \entry -> do
        let fp = dir </> entry
        isDir <- doesDirectoryExist fp
        isFile <- doesFileExist fp
        if isDir
          then if shouldSkipDir fp then pure [] else go fp
          else if isFile && isJson fp && not (isMetadataJson fp)
            then pure [fp]
            else pure []

-- | Scan artifacts for contract-level link references and all unique library keys.
scanArtifactsForLinkReferences :: [FilePath] -> IO (Map Text (Set Text), Set Text)
scanArtifactsForLinkReferences fps = do
  parsed <- catMaybes <$> traverse parseFoundryArtifact fps
  let contractDeps = Map.fromListWith Set.union parsed
      linkedLibraries = foldMap snd parsed
  pure (contractDeps, linkedLibraries)

parseFoundryArtifact :: FilePath -> IO (Maybe (Text, Set Text))
parseFoundryArtifact fp = do
  raw <- BS.readFile fp
  case eitherDecodeStrict' raw of
    Left _ -> pure Nothing
    Right (v :: Value) -> case v of
      Object obj -> do
        let name = parseContractName fp obj
            deps = extractLinkReferences obj
        pure $ Just (name, deps)
      _ -> pure Nothing

parseContractName :: FilePath -> Object -> Text
parseContractName fp obj =
  fromMaybeText (lookupText "contractName" <|> lookupText "sourceName" <|> Just defaultName)
  where
    lookupText :: Text -> Maybe Text
    lookupText name = case KeyMap.lookup (AesonKey.fromText name) obj of
      Just (String v)
        | not (T.null (T.strip v)) -> Just (T.strip v)
      _ -> Nothing

    defaultName = T.pack (takeBaseName fp)

    fromMaybeText :: Maybe Text -> Text
    fromMaybeText = maybe "" id

-- | Build ordered library infos in dependency order.
buildLibraryInfoOrder :: Map Text (Set Text) -> Set Text -> Either String [LibraryLinkInfo]
buildLibraryInfoOrder contractDeps libraryKeys = do
  parsed <- mapM parseLibraryKey (Set.toList libraryKeys)

  let byName = Map.fromListWith (++) [(name, [lliKey]) | (_, name, lliKey) <- parsed]
  let duplicateNames = Map.toList $ Map.filter ((> 1) . length) byName
  unless (null duplicateNames) $
    Left $ "found duplicate library names for different sources: " ++ show (map fst duplicateNames)

  let libraryInfoByKey = Map.fromList
        [ (lliKey, mkLibraryInfo (T.unpack source) name lliKey)
        | (source, name, lliKey) <- parsed
        ]
      depsByKey = Map.map lliDependencies libraryInfoByKey
      order = topologicalSort depsByKey
  pure $ map (libraryInfoByKey Map.!) order
  where
    parseLibraryKey :: Text -> Either String (Text, Text, Text)
    parseLibraryKey key = do
      let (sourcePrefix, name) = T.breakOnEnd ":" key
          source = T.dropEnd 1 sourcePrefix
      if T.null source || T.null name
        then Left $ "invalid library key: " ++ T.unpack key
        else Right (source, name, key)

    mkLibraryInfo :: Text -> Text -> Text -> LibraryLinkInfo
    mkLibraryInfo source name key =
      let deps = Set.delete key (Map.findWithDefault mempty name contractDeps `Set.intersection` libraryKeys)
      in LibraryLinkInfo
           { lliName = name
           , lliSourceFile = T.unpack source
           , lliKey = key
           , lliDependencies = deps
           }

    topologicalSort :: Map Text (Set Text) -> [Text]
    topologicalSort deps = go deps []
      where
        go g ordered
          | Map.null g = reverse ordered
          | null ready = reverse ordered ++ sort (Map.keys g)
          | otherwise =
              let current = head ready
                  g' = Map.map (Set.delete current) $ Map.delete current g
              in go g' (current : ordered)
          where
            ready = sort . Map.keys $ Map.filter Set.null g

-- | Assign deterministic addresses to discovered libraries.
assignLibraryAddresses
  :: Addr
  -> Int
  -> Set Addr
  -> [LibraryLinkInfo]
  -> Either String [(LibraryLinkInfo, Addr)]
assignLibraryAddresses start maxCount deployed libs
  | maxCount <= 0 = Left "auto-link library range must be greater than 0"
  | otherwise = assign startInteger occupied [] libs
  where
    startInteger :: Integer
    startInteger = toInteger start

    occupied :: Set Integer
    occupied = Set.map toInteger deployed

    assign
      :: Integer
      -> Set Integer
      -> [(LibraryLinkInfo, Addr)]
      -> [LibraryLinkInfo]
      -> Either String [(LibraryLinkInfo, Addr)]
    assign _ _ acc [] = Right (reverse acc)
    assign current used acc (lib:rest)
      | current >= startInteger + fromIntegral maxCount
        = Left $
          "auto-link library range exhausted from 0x" ++ show start ++
          " with " ++ show maxCount ++ " slots; increase autoLinkLibrariesMax or free an address"
      | Set.member current used
        = assign (current + 1) used acc (lib : rest)
      | otherwise
        = let addr = fromInteger current
              used' = Set.insert current used
          in assign (current + 1) used' ((lib, addr) : acc) rest

-- | Format --compile-libraries argument items.
formatCompileLibrariesArg :: [(Text, Addr)] -> String
formatCompileLibrariesArg entries =
  "--compile-libraries=" ++ intercalate "," [ "(" ++ T.unpack name ++ "," ++ show addr ++ ")" | (name, addr) <- entries ]

-- | Inject auto-link configuration into compilation config when safe.
autoConfigureFoundryLibraries :: SolConf -> FilePath -> IO (Either String SolConf)
autoConfigureFoundryLibraries solConf cliFilePath = do
  if not (autoLinkEnabled solConf)
    then pure (Right solConf)
    else do
      foundryRoot <- findFoundryRoot cliFilePath
      outDir <- getFoundryOutDir foundryRoot solConf.autoLinkLibrariesOutDir
      artifacts <- do
        existing <- collectArtifactJsons outDir
        if not (null existing)
          then pure existing
          else do
            _ <- runForgeBuild foundryRoot
            collectArtifactJsons outDir

      if null artifacts
        then pure (Right solConf)
        else do
          (contractDeps, libraryKeys) <- scanArtifactsForLinkReferences artifacts
          if Set.null libraryKeys
            then pure (Right solConf)
            else do
              libraryInfos <- buildLibraryInfoOrder contractDeps libraryKeys
              assigned <- assignLibraryAddresses
                solConf.autoLinkLibrariesStart
                solConf.autoLinkLibrariesMax
                (Set.fromList (fst <$> solConf.deployContracts))
                libraryInfos
              let deploys = [ (addr, lliSourceFile info ++ ":" ++ T.unpack (lliName info))
                            | (info, addr) <- assigned ]
                  libArg = formatCompileLibrariesArg [(lliName info, addr) | (info, addr) <- assigned]
                  autoConf = solConf
                    { cryticArgs = solConf.cryticArgs ++ [libArg]
                    , deployContracts = deploys ++ solConf.deployContracts
                    }
              pure (Right autoConf)
  where
    autoLinkEnabled :: SolConf -> Bool
    autoLinkEnabled conf =
      conf.autoLinkLibraries
      && null conf.solcLibs
      && not (any isCompileLibrariesArg conf.cryticArgs)

    isCompileLibrariesArg :: String -> Bool
    isCompileLibrariesArg arg =
      arg == "--compile-libraries" || "--compile-libraries=" `isPrefixOf` arg

    runForgeBuild :: FilePath -> IO Bool
    runForgeBuild root = do
      mForge <- findExecutable "forge"
      case mForge of
        Nothing -> do
          hPutStrLn stderr "warning: forge not found; skipping auto build of foundry artifacts"
          pure False
        Just _ -> do
          (ec, _, err) <- readCreateProcessWithExitCode (proc "forge" ["build", "--root", root]) ""
          case ec of
            ExitSuccess -> pure True
            ExitFailure _ -> do
              hPutStrLn stderr "warning: forge build failed; auto-link configuration may be incomplete"
              hPutStrLn stderr err
              pure False

    extractLinkReferences :: Object -> Set Text
    extractLinkReferences obj =
      Set.union (extractLinksFromSection (lookupSection "bytecode")) (extractLinksFromSection (lookupSection "deployedBytecode"))
      where
        lookupSection :: Text -> Object
        lookupSection k = case KeyMap.lookup (AesonKey.fromText k) obj of
          Just (Object o) -> o
          _ -> mempty

        extractLinksFromSection :: Object -> Set Text
        extractLinksFromSection section = case KeyMap.lookup "linkReferences" section of
          Just (Object links) ->
            Set.fromList . catMaybes . concatMap extractSourceLinks . KeyMap.toList $ links
          _ -> mempty

        extractSourceLinks :: (Key, Value) -> [Maybe Text]
        extractSourceLinks (sourceKey, Object libs) =
          let source = AesonKey.toText sourceKey
          in if T.null (T.strip source)
            then []
            else [formatKey source libName | libName <- KeyMap.keys libs]
        extractSourceLinks _ = []

        formatKey :: Text -> Key -> Maybe Text
        formatKey source libKey =
          let lib = AesonKey.toText libKey
          in if T.null (T.strip lib)
            then Nothing
            else Just (source <> ":" <> lib)

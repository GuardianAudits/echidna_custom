module Echidna.RVM
  ( StorageLayout(..)
  , StorageEntry(..)
  , StorageType(..)
  , ResolvedSlot(..)
  , RVMError(..)
  , parseStorageLayout
  , parseStorageLayoutValue
  , parseCompactLayout
  , resolveStoragePath
  , resolveStoragePathWithLengths
  , erc7201Slot
  , applyNamespace
  , applyNamespaceAt
  , namespaceStorageLayout
  , mergeStorageLayouts
  , extractPacked
  , insertPacked
  )
where

import Control.Monad (foldM, unless, when)
import Control.Monad.State.Strict (StateT, evalStateT, get, lift, modify')
import Data.Aeson (FromJSON(..), Value(..), eitherDecodeStrict', withObject, (.:), (.:?))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.Bits ((.&.), (.|.), complement, shiftL, shiftR)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAlpha, isAlphaNum, isSpace)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Text.Read qualified as TextRead

import EVM.Types (W256, keccak', word, word256Bytes)

-- | A normalized solc storage layout. Decimal strings from compiler JSON are
-- validated and converted at the parser boundary.
data StorageLayout = StorageLayout
  { storage :: [StorageEntry]
  , types :: Map Text StorageType
  } deriving (Eq, Show)

data StorageEntry = StorageEntry
  { label :: Text
  , offset :: Int
  , slot :: W256
  , typeId :: Text
  , contract :: Maybe Text
  } deriving (Eq, Show)

data StorageType = StorageType
  { encoding :: Text
  , label :: Text
  , numberOfBytes :: Int
  , key :: Maybe Text
  , value :: Maybe Text
  , base :: Maybe Text
  , members :: Maybe [StorageEntry]
  } deriving (Eq, Show)

data ResolvedSlot = ResolvedSlot
  { slot :: W256
  , byteOffset :: Int
  , byteSize :: Int
  } deriving (Eq, Show)

-- | Errors deliberately retain the path/type/context that failed. Callers can
-- render these constructors directly without losing the underlying detail.
data RVMError
  = LayoutJSONError Text
  | InvalidDecimal Text Text
  | NumericOutOfRange Text Integer
  | InvalidLayout Text
  | CompactLayoutError Text
  | VariableNotFound Text
  | AmbiguousVariable Text [W256]
  | TypeNotFound Text
  | MemberNotFound Text Text
  | PathContinuesPastLeaf Text Text
  | MissingKey Text Int Int
  | InvalidABIKeys Text
  | UnsupportedEncoding Text Text
  | UnsupportedMappingKey Text Text
  | ArrayLengthUnavailable Text
  | ArrayIndexOutOfBounds Text W256 Integer
  | ValueSpansMultipleSlots Text Int
  | DuplicateVariable Text
  | TypeCollision Text
  | InvalidPackedRange Int Int
  deriving (Eq, Show)

-- JSON parsing -----------------------------------------------------------------

instance FromJSON StorageLayout where
  parseJSON = withObject "solc storageLayout" $ \obj ->
    StorageLayout <$> obj .: "storage" <*> obj .: "types"

instance FromJSON StorageEntry where
  parseJSON = withObject "storage entry" $ \obj -> do
    entryLabel <- obj .: "label"
    entryOffset <- obj .: "offset"
    rawSlot <- obj .: "slot"
    entrySlot <- parseDecimalW256P ("slot for " <> entryLabel) rawSlot
    entryType <- obj .: "type"
    entryContract <- obj .:? "contract"
    pure $ StorageEntry entryLabel entryOffset entrySlot entryType entryContract

instance FromJSON StorageType where
  parseJSON = withObject "storage type" $ \obj -> do
    typeEncoding <- obj .: "encoding"
    typeLabel <- obj .: "label"
    rawSize <- obj .: "numberOfBytes"
    typeSize <- parsePositiveIntP ("numberOfBytes for " <> typeLabel) rawSize
    StorageType typeEncoding typeLabel typeSize
      <$> obj .:? "key"
      <*> obj .:? "value"
      <*> obj .:? "base"
      <*> obj .:? "members"

-- | Parse either exact solc storage-layout JSON or the compact declaration
-- format accepted by @registerStorageLayout@.
parseStorageLayout :: Text -> Either RVMError StorageLayout
parseStorageLayout input
  | T.isPrefixOf "{" trimmed = do
      value <- first (LayoutJSONError . T.pack) $
        eitherDecodeStrict' (encodeUtf8 trimmed)
      parseStorageLayoutValue value
  | otherwise = parseCompactLayout trimmed
  where
    trimmed = T.strip input

-- | Parse a storage-layout JSON value. For convenience this accepts both the
-- exact solc object and a Foundry-style @{ "storageLayout": ... }@ wrapper.
parseStorageLayoutValue :: Value -> Either RVMError StorageLayout
parseStorageLayoutValue input = do
  let direct = case input of
        Object obj -> maybe input id (KeyMap.lookup "storageLayout" obj)
        _ -> input
  layout <- first (LayoutJSONError . T.pack) (parseEither parseJSON direct)
  validateStorageLayout layout

parseDecimalW256P :: Text -> Text -> Parser W256
parseDecimalW256P context raw =
  either (fail . show) pure (parseDecimalW256 context raw)

parsePositiveIntP :: Text -> Text -> Parser Int
parsePositiveIntP context raw =
  either (fail . show) pure (parsePositiveInt context raw)

parseDecimalW256 :: Text -> Text -> Either RVMError W256
parseDecimalW256 context raw = do
  n <- parseDecimalInteger context raw
  if n > toInteger (maxBound :: W256)
    then Left $ NumericOutOfRange context n
    else pure (fromInteger n)

parsePositiveInt :: Text -> Text -> Either RVMError Int
parsePositiveInt context raw = do
  n <- parseDecimalInteger context raw
  if n == 0 || n > toInteger (maxBound :: Int)
    then Left $ NumericOutOfRange context n
    else pure (fromInteger n)

parseDecimalInteger :: Text -> Text -> Either RVMError Integer
parseDecimalInteger context raw =
  case TextRead.decimal raw of
    Right (n, rest) | T.null rest -> Right n
    _ -> Left $ InvalidDecimal context raw

validateStorageLayout :: StorageLayout -> Either RVMError StorageLayout
validateStorageLayout layout = do
  validateEntries layout.types "storage" layout.storage
  mapM_ (uncurry $ validateType layout.types) (Map.toList layout.types)
  pure layout

validateEntries :: Map Text StorageType -> Text -> [StorageEntry] -> Either RVMError ()
validateEntries typeMap context entries = do
  -- Valid solc output can repeat a top-level label through inheritance (for
  -- example, two forge-std bases both declaring `stdstore`). Keep such
  -- artifacts loadable; compact layouts and explicit merges remain strict.
  unless (context == "storage") $ rejectDuplicateLabels entries
  mapM_ validateEntry entries
  where
    validateEntry entry = do
      when (entry.offset < 0 || entry.offset >= 32) $
        Left $ InvalidLayout
          (context <> " entry `" <> entry.label <> "` has byte offset "
            <> T.pack (show entry.offset) <> ", expected 0..31")
      ty <- lookupType typeMap entry.typeId
      let composite = isComposite ty
      when (composite && entry.offset /= 0) $
        Left $ InvalidLayout
          (context <> " entry `" <> entry.label <> "` has composite type `"
            <> entry.typeId <> "` at nonzero byte offset")
      unless composite $
        when (entry.offset + ty.numberOfBytes > 32) $
          Left $ InvalidLayout
            (context <> " entry `" <> entry.label <> "` exceeds its storage word")

validateType :: Map Text StorageType -> Text -> StorageType -> Either RVMError ()
validateType typeMap typeId ty = do
  when (ty.numberOfBytes <= 0) $
    Left $ InvalidLayout ("type `" <> typeId <> "` has a non-positive size")
  when (isJust ty.members && isJust ty.base) $
    Left $ InvalidLayout ("type `" <> typeId <> "` has both members and an array base")
  case ty.encoding of
    "inplace" -> do
      maybe (pure ()) (validateEntries typeMap ("members of " <> typeId)) ty.members
      case ty.base of
        Nothing -> pure ()
        Just ref -> () <$ first
          (const $ TypeNotFound (typeId <> ":" <> ref))
          (lookupType typeMap ref)
    "mapping" -> do
      requireReference "key" ty.key
      requireReference "value" ty.value
    "dynamic_array" -> requireReference "base" ty.base
    "bytes" -> pure ()
    other -> Left $ UnsupportedEncoding typeId other
  where
    requireReference fieldName = \case
      Nothing -> Left $ InvalidLayout
        ("type `" <> typeId <> "` is missing its `" <> fieldName <> "` reference")
      Just ref -> () <$ lookupType typeMap ref

rejectDuplicateLabels :: [StorageEntry] -> Either RVMError ()
rejectDuplicateLabels entries =
  case Map.keys $ Map.filter (> (1 :: Int)) counts of
    duplicate : _ -> Left $ DuplicateVariable duplicate
    [] -> Right ()
  where
    counts = Map.fromListWith (+) [(entry.label, 1 :: Int) | entry <- entries]

lookupType :: Map Text StorageType -> Text -> Either RVMError StorageType
lookupType typeMap typeId =
  maybe (Left $ TypeNotFound typeId) Right (Map.lookup typeId typeMap)

-- Compact layout parsing --------------------------------------------------------

data CompactType
  = CompactPrimitive Text Text Int
  | CompactBytes Text Text
  | CompactTuple [(Text, CompactType)]
  | CompactMapping CompactType CompactType
  | CompactArray CompactType (Maybe Integer)
  deriving (Eq, Show)

data CompactBuild = CompactBuild
  { builtTypes :: Map Text StorageType
  , nextStructId :: Int
  }

type Build = StateT CompactBuild (Either RVMError)

parseCompactLayout :: Text -> Either RVMError StorageLayout
parseCompactLayout input = do
  fieldTexts <- splitTopLevelFields (T.strip input)
  fields <- traverse parseNamedField fieldTexts
  (typedFields, finalState) <- runBuild fields
  (entries, _) <- placeEntries finalState.builtTypes typedFields
  rejectDuplicateLabels entries
  validateStorageLayout $ StorageLayout entries finalState.builtTypes
  where
    runBuild fields = do
      let initial = CompactBuild Map.empty 0
      flip evalStateT initial $ do
        typed <- traverse (\(name, ty) -> (name,) <$> internCompactType ty) fields
        state <- get
        pure (typed, state)

splitTopLevelFields :: Text -> Either RVMError [Text]
splitTopLevelFields input
  | T.null input = Left $ CompactLayoutError "empty compact layout"
  | otherwise = go 0 0 [] [] (T.unpack input)
  where
    go :: Int -> Int -> String -> [Text] -> String -> Either RVMError [Text]
    go parens brackets current fields []
      | parens /= 0 = Left $ CompactLayoutError "unbalanced parentheses"
      | brackets /= 0 = Left $ CompactLayoutError "unbalanced array brackets"
      | otherwise = finish current fields
    go parens brackets current fields (char : rest) = case char of
      '(' -> go (parens + 1) brackets (char : current) fields rest
      ')' | parens == 0 -> Left $ CompactLayoutError "unexpected `)`"
          | otherwise -> go (parens - 1) brackets (char : current) fields rest
      '[' -> go parens (brackets + 1) (char : current) fields rest
      ']' | brackets == 0 -> Left $ CompactLayoutError "unexpected `]`"
          | otherwise -> go parens (brackets - 1) (char : current) fields rest
      ',' | parens == 0 && brackets == 0 -> do
        field <- nonemptyField current
        go parens brackets [] (field : fields) rest
      _ -> go parens brackets (char : current) fields rest
    finish :: String -> [Text] -> Either RVMError [Text]
    finish current fields = do
      field <- nonemptyField current
      pure $ reverse (field : fields)
    nonemptyField chars =
      let field = T.strip . T.pack $ reverse chars
      in if T.null field
          then Left $ CompactLayoutError "empty field between separators"
          else Right field

parseNamedField :: Text -> Either RVMError (Text, CompactType)
parseNamedField field = do
  splitAtIndex <- maybe
    (Left $ CompactLayoutError ("expected a field name after `" <> field <> "`"))
    Right
    (lastTopLevelSpace field)
  let rawType = T.strip $ T.take splitAtIndex field
      name = T.strip $ T.drop (splitAtIndex + 1) field
  when (T.null rawType || not (validIdentifier name)) $
    Left $ CompactLayoutError ("invalid field declaration `" <> field <> "`")
  (name,) <$> parseCompactType rawType

lastTopLevelSpace :: Text -> Maybe Int
lastTopLevelSpace = go 0 0 Nothing 0 . T.unpack
  where
    go :: Int -> Int -> Maybe Int -> Int -> String -> Maybe Int
    go _ _ found _ [] = found
    go parens brackets found index (char : rest) =
      let parens' = case char of
            '(' -> parens + 1
            ')' -> max 0 (parens - 1)
            _ -> parens
          brackets' = case char of
            '[' -> brackets + 1
            ']' -> max 0 (brackets - 1)
            _ -> brackets
          found' = if isSpace char && parens == 0 && brackets == 0
            then Just index
            else found
      in go parens' brackets' found' (index + 1) rest

validIdentifier :: Text -> Bool
validIdentifier name = case T.uncons name of
  Nothing -> False
  Just (firstChar, rest) ->
    validFirst firstChar && T.all validRest rest
  where
    validFirst char = isAlpha char || char == '_' || char == '$'
    validRest char = isAlphaNum char || char == '_' || char == '$'

parseCompactType :: Text -> Either RVMError CompactType
parseCompactType rawType
  | Just (baseType, rawLength) <- stripArraySuffix ty = do
      parsedBase <- parseCompactType baseType
      length' <- if T.null rawLength
        then Right Nothing
        else do
          n <- parseDecimalInteger ("array length in `" <> ty <> "`") rawLength
          if n == 0
            then Left $ CompactLayoutError ("array length must be positive in `" <> ty <> "`")
            else Right (Just n)
      Right $ CompactArray parsedBase length'
  | Just mappingInner <- stripWholeCall "mapping" ty = do
      arrow <- findTopLevelArrow mappingInner
      let rawKey = T.strip $ T.take arrow mappingInner
          rawValue = T.strip $ T.drop (arrow + 2) mappingInner
      when (T.null rawKey || T.null rawValue) $
        Left $ CompactLayoutError ("invalid mapping type `" <> ty <> "`")
      CompactMapping <$> parseCompactType rawKey <*> parseCompactType rawValue
  | Just tupleInner <- stripWholeParens ty = do
      tupleFields <- splitTopLevelFields tupleInner
      CompactTuple <$> traverse parseNamedField tupleFields
  | otherwise = parsePrimitive ty
  where
    ty = T.strip rawType

parsePrimitive :: Text -> Either RVMError CompactType
parsePrimitive = \case
  "bool" -> pure $ CompactPrimitive "t_bool" "bool" 1
  "address" -> pure $ CompactPrimitive "t_address" "address" 20
  "address payable" -> pure $ CompactPrimitive "t_address_payable" "address payable" 20
  "uint" -> pure $ CompactPrimitive "t_uint256" "uint256" 32
  "int" -> pure $ CompactPrimitive "t_int256" "int256" 32
  "bytes" -> pure $ CompactBytes "t_bytes_storage" "bytes"
  "string" -> pure $ CompactBytes "t_string_storage" "string"
  ty
    | Just bitsText <- T.stripPrefix "uint" ty -> integerPrimitive "uint" bitsText ty
    | Just bitsText <- T.stripPrefix "int" ty -> integerPrimitive "int" bitsText ty
    | Just bytesText <- T.stripPrefix "bytes" ty -> fixedBytes bytesText ty
    | otherwise -> Left $ CompactLayoutError ("unsupported compact type `" <> ty <> "`")
  where
    integerPrimitive prefix bitsText original = do
      bits <- parseDecimalInteger ("bit width in `" <> original <> "`") bitsText
      when (bits == 0 || bits > 256 || bits `mod` 8 /= 0) $
        Left $ CompactLayoutError ("invalid integer width in `" <> original <> "`")
      pure $ CompactPrimitive
        ("t_" <> prefix <> T.pack (show bits))
        original
        (fromInteger $ bits `div` 8)
    fixedBytes bytesText original = do
      width <- parseDecimalInteger ("byte width in `" <> original <> "`") bytesText
      when (width == 0 || width > 32) $
        Left $ CompactLayoutError ("invalid fixed-bytes width in `" <> original <> "`")
      pure $ CompactPrimitive
        ("t_bytes" <> T.pack (show width))
        original
        (fromInteger width)

stripArraySuffix :: Text -> Maybe (Text, Text)
stripArraySuffix ty = do
  (withoutClose, close) <- T.unsnoc ty
  if close /= ']' then Nothing else do
    openIndex <- findMatchingOpenBracket withoutClose
    let baseType = T.strip $ T.take openIndex withoutClose
        rawLength = T.drop (openIndex + 1) withoutClose
    if T.null baseType then Nothing else Just (baseType, rawLength)
  where
    findMatchingOpenBracket text = go 0 (T.length text - 1)
      where
        go :: Int -> Int -> Maybe Int
        go _ index | index < 0 = Nothing
        go depth index = case T.index text index of
          ']' -> go (depth + 1) (index - 1)
          '[' | depth == 0 -> Just index
              | otherwise -> go (depth - 1) (index - 1)
          _ -> go depth (index - 1)

stripWholeCall :: Text -> Text -> Maybe Text
stripWholeCall name ty = do
  innerWithClose <- T.stripPrefix (name <> "(") ty
  (inner, close) <- T.unsnoc innerWithClose
  if close == ')' && balancedParens inner then Just inner else Nothing

stripWholeParens :: Text -> Maybe Text
stripWholeParens ty = do
  afterOpen <- T.stripPrefix "(" ty
  (inner, close) <- T.unsnoc afterOpen
  if close == ')' && balancedParens inner then Just inner else Nothing

balancedParens :: Text -> Bool
balancedParens = (== Just 0) . foldM step 0 . T.unpack
  where
    step :: Int -> Char -> Maybe Int
    step depth '(' = Just (depth + 1)
    step 0 ')' = Nothing
    step depth ')' = Just (depth - 1)
    step depth _ = Just depth

findTopLevelArrow :: Text -> Either RVMError Int
findTopLevelArrow text = go 0 0 (T.unpack text)
  where
    go :: Int -> Int -> String -> Either RVMError Int
    go _ _ [] = Left $ CompactLayoutError
      ("mapping is missing a top-level `=>` in `" <> text <> "`")
    go depth index ('=' : '>' : _) | depth == 0 = Right index
    go depth index (char : rest) = case char of
      '(' -> go (depth + 1) (index + 1) rest
      ')' -> go (max 0 $ depth - 1) (index + 1) rest
      _ -> go depth (index + 1) rest

internCompactType :: CompactType -> Build Text
internCompactType = \case
  CompactPrimitive typeId typeLabel size -> do
    insertBuiltType typeId $ StorageType "inplace" typeLabel size Nothing Nothing Nothing Nothing
    pure typeId
  CompactBytes typeId typeLabel -> do
    insertBuiltType typeId $ StorageType "bytes" typeLabel 32 Nothing Nothing Nothing Nothing
    pure typeId
  CompactTuple fields -> do
    typedFields <- traverse (\(name, ty) -> (name,) <$> internCompactType ty) fields
    state <- get
    (entries, spanBytes) <- lift $ placeEntries state.builtTypes typedFields
    let structId = state.nextStructId + 1
        typeId = "t_struct(rvm_" <> T.pack (show structId) <> ")_storage"
        ty = StorageType "inplace" ("struct rvm_" <> T.pack (show structId))
          spanBytes Nothing Nothing Nothing (Just entries)
    modify' $ \s -> s
      { builtTypes = Map.insert typeId ty s.builtTypes
      , nextStructId = structId
      }
    pure typeId
  CompactMapping keyType valueType -> do
    keyId <- internCompactType keyType
    valueId <- internCompactType valueType
    state <- get
    keyTy <- lift $ lookupType state.builtTypes keyId
    valueTy <- lift $ lookupType state.builtTypes valueId
    unless (validMappingKeyType keyTy) $
      lift . Left $ CompactLayoutError
        ("unsupported mapping key type `" <> keyTy.label <> "`")
    let typeId = "t_mapping(" <> keyId <> "," <> valueId <> ")"
        typeLabel = "mapping(" <> keyTy.label <> " => " <> valueTy.label <> ")"
    insertBuiltType typeId $
      StorageType "mapping" typeLabel 32 (Just keyId) (Just valueId) Nothing Nothing
    pure typeId
  CompactArray baseType arrayLength -> do
    baseId <- internCompactType baseType
    state <- get
    baseTy <- lift $ lookupType state.builtTypes baseId
    case arrayLength of
      Nothing -> do
        let typeId = "t_array(" <> baseId <> ")dyn_storage"
        insertBuiltType typeId $
          StorageType "dynamic_array" (baseTy.label <> "[]") 32
            Nothing Nothing (Just baseId) Nothing
        pure typeId
      Just length' -> do
        spanBytes <- lift $ fixedArraySpan baseTy length'
        let lengthText = T.pack (show length')
            typeId = "t_array(" <> baseId <> ")" <> lengthText <> "_storage"
        insertBuiltType typeId $
          StorageType "inplace" (baseTy.label <> "[" <> lengthText <> "]") spanBytes
            Nothing Nothing (Just baseId) Nothing
        pure typeId

insertBuiltType :: Text -> StorageType -> Build ()
insertBuiltType typeId ty = do
  state <- get
  case Map.lookup typeId state.builtTypes of
    Nothing -> modify' $ \s -> s { builtTypes = Map.insert typeId ty s.builtTypes }
    Just existing
      | existing == ty -> pure ()
      | otherwise -> lift . Left $ TypeCollision typeId

placeEntries
  :: Map Text StorageType
  -> [(Text, Text)]
  -> Either RVMError ([StorageEntry], Int)
placeEntries typeMap fields = do
  (entries, finalSlot, finalOffset) <- foldM place ([], 0 :: Integer, 0 :: Int) fields
  let slotsUsed = finalSlot + if finalOffset > 0 then 1 else 0
      totalBytes = slotsUsed * 32
  if totalBytes > toInteger (maxBound :: Int)
    then Left $ NumericOutOfRange "compact layout storage span" totalBytes
    else pure (reverse entries, max 32 $ fromInteger totalBytes)
  where
    place (entries, currentSlot, currentOffset) (name, typeId) = do
      ty <- lookupType typeMap typeId
      if isPackableLeaf ty
        then do
          let startsNewWord = currentOffset + ty.numberOfBytes > 32
              entrySlot = if startsNewWord then currentSlot + 1 else currentSlot
              entryOffset = if startsNewWord then 0 else currentOffset
              offsetAfter = entryOffset + ty.numberOfBytes
              (slotAfter, finalOffset) = if offsetAfter == 32
                then (entrySlot + 1, 0)
                else (entrySlot, offsetAfter)
          pure
            ( StorageEntry name entryOffset (fromInteger entrySlot) typeId Nothing : entries
            , slotAfter
            , finalOffset
            )
        else do
          let entrySlot = currentSlot + if currentOffset > 0 then 1 else 0
              slots = slotsForBytes ty.numberOfBytes
          pure
            ( StorageEntry name 0 (fromInteger entrySlot) typeId Nothing : entries
            , entrySlot + toInteger slots
            , 0
            )

fixedArraySpan :: StorageType -> Integer -> Either RVMError Int
fixedArraySpan baseTy length'
  | length' <= 0 = Left $ CompactLayoutError "fixed-array length must be positive"
  | otherwise = do
      let slots
            | isPackableLeaf baseTy =
                let perSlot = toInteger (32 `div` baseTy.numberOfBytes)
                in ceilingDiv length' perSlot
            | otherwise = length' * toInteger (slotsForBytes baseTy.numberOfBytes)
          bytes = slots * 32
      if bytes > toInteger (maxBound :: Int)
        then Left $ NumericOutOfRange "fixed-array storage span" bytes
        else pure (fromInteger bytes)

-- Storage path resolution -------------------------------------------------------

data KeyCursor = KeyCursor
  { nextHead :: Int
  , dynamicRanges :: [(Int, Int)]
  }

resolveStoragePath
  :: StorageLayout
  -> Text
  -> ByteString
  -> Either RVMError ResolvedSlot
resolveStoragePath = resolveStoragePathInternal Nothing

resolveStoragePathWithLengths
  :: (W256 -> Either RVMError W256)
  -> StorageLayout
  -> Text
  -> ByteString
  -> Either RVMError ResolvedSlot
resolveStoragePathWithLengths readLength =
  resolveStoragePathInternal (Just readLength)

resolveStoragePathInternal
  :: Maybe (W256 -> Either RVMError W256)
  -> StorageLayout
  -> Text
  -> ByteString
  -> Either RVMError ResolvedSlot
resolveStoragePathInternal readLength layout rawPath keys = do
  when (BS.length keys `mod` 32 /= 0) $
    Left $ InvalidABIKeys
      ("ABI key payload length is " <> T.pack (show $ BS.length keys)
        <> " bytes; expected a multiple of 32")
  (entry, remainingPath) <- findTopLevelEntry layout.storage path
  (resolved, cursor) <- resolveInner readLength layout entry.slot entry.offset entry.typeId
    remainingPath keys (KeyCursor 0 [])
  validateConsumedKeys keys cursor
  pure resolved
  where
    path = T.strip rawPath

findTopLevelEntry :: [StorageEntry] -> Text -> Either RVMError (StorageEntry, [Text])
findTopLevelEntry entries path
  | T.null path = Left $ VariableNotFound path
  | otherwise = case candidates of
      [] -> Left $ VariableNotFound path
      _ ->
        let longestLength = maximum (map snd candidates)
            longest = [entry | (entry, consumed) <- candidates, consumed == longestLength]
        in case longest of
          [entry] -> Right (entry, drop longestLength parts)
          ambiguous -> Left $ AmbiguousVariable path (map (.slot) ambiguous)
  where
    parts = T.splitOn "." path
    candidates =
      [ (entry, length labelParts)
      | entry <- entries
      , let labelParts = T.splitOn "." entry.label
      , labelParts == take (length labelParts) parts
      ]

resolveInner
  :: Maybe (W256 -> Either RVMError W256)
  -> StorageLayout
  -> W256
  -> Int
  -> Text
  -> [Text]
  -> ByteString
  -> KeyCursor
  -> Either RVMError (ResolvedSlot, KeyCursor)
resolveInner readLength layout currentSlot currentOffset typeId remainingPath keys cursor = do
  ty <- lookupType layout.types typeId
  case ty.encoding of
    "inplace"
      | Just typeMembers <- ty.members ->
          resolveStruct ty typeMembers
      | Just baseId <- ty.base ->
          resolveFixedArray ty baseId
      | otherwise -> resolveLeaf ty
    "mapping" -> resolveMapping ty
    "dynamic_array" -> resolveDynamicArray ty
    "bytes" -> resolveLeaf ty
    other -> Left $ UnsupportedEncoding typeId other
  where
    resolveLeaf ty = case remainingPath of
      [] -> Right (ResolvedSlot currentSlot currentOffset ty.numberOfBytes, cursor)
      segment : _ -> Left $ PathContinuesPastLeaf segment typeId

    resolveStruct ty typeMembers = case remainingPath of
      []
        | ty.numberOfBytes > 32 -> Left $ ValueSpansMultipleSlots ty.label ty.numberOfBytes
        | otherwise -> Right (ResolvedSlot currentSlot currentOffset ty.numberOfBytes, cursor)
      memberName : rest -> do
        member <- maybe
          (Left $ MemberNotFound typeId memberName)
          Right
          (findEntry memberName typeMembers)
        resolveInner readLength layout (currentSlot + member.slot) member.offset member.typeId
          rest keys cursor

    resolveMapping ty = do
      keyId <- requireTypeReference typeId "key" ty.key
      valueId <- requireTypeReference typeId "value" ty.value
      keyType <- lookupType layout.types keyId
      (encodedKey, nextCursor) <- consumeMappingKey keyType keyId keys cursor
      let derivedSlot = keccak' (encodedKey <> word256Bytes currentSlot)
      resolveInner readLength layout derivedSlot 0 valueId remainingPath keys nextCursor

    resolveDynamicArray ty = do
      baseId <- requireTypeReference typeId "base" ty.base
      baseTy <- lookupType layout.types baseId
      (index, nextCursor) <- consumeIndex ty.label keys cursor
      case readLength of
        Nothing -> pure ()
        Just readLength' -> do
          length' <- readLength' currentSlot
          when (index >= length') $
            Left $ ArrayIndexOutOfBounds ty.label index (toInteger length')
      let dataStart = keccak' (word256Bytes currentSlot)
          (elementSlot, elementOffset) = arrayElementLocation dataStart baseTy index
      resolveInner readLength layout elementSlot elementOffset baseId remainingPath keys nextCursor

    resolveFixedArray ty baseId = do
      baseTy <- lookupType layout.types baseId
      length' <- fixedArrayLength ty
      (index, nextCursor) <- consumeIndex ty.label keys cursor
      when (toInteger index >= length') $
        Left $ ArrayIndexOutOfBounds ty.label index length'
      let (elementSlot, elementOffset) = arrayElementLocation currentSlot baseTy index
      resolveInner readLength layout elementSlot elementOffset baseId remainingPath keys nextCursor

findEntry :: Text -> [StorageEntry] -> Maybe StorageEntry
findEntry name = go
  where
    go [] = Nothing
    go (entry : rest)
      | entry.label == name = Just entry
      | otherwise = go rest

requireTypeReference :: Text -> Text -> Maybe Text -> Either RVMError Text
requireTypeReference typeId fieldName = maybe
  (Left $ InvalidLayout
    ("type `" <> typeId <> "` is missing its `" <> fieldName <> "` reference"))
  Right

consumeIndex
  :: Text
  -> ByteString
  -> KeyCursor
  -> Either RVMError (W256, KeyCursor)
consumeIndex context keys cursor = do
  (keyWord, nextCursor) <- consumeHead context keys cursor
  pure (word keyWord, nextCursor)

consumeMappingKey
  :: StorageType
  -> Text
  -> ByteString
  -> KeyCursor
  -> Either RVMError (ByteString, KeyCursor)
consumeMappingKey keyType keyId keys cursor
  | keyType.encoding == "bytes" = consumeDynamicKey keyType.label keys cursor
  | validStaticMappingKey keyType = consumeHead keyType.label keys cursor
  | otherwise = Left $ UnsupportedMappingKey keyId keyType.label

consumeHead
  :: Text
  -> ByteString
  -> KeyCursor
  -> Either RVMError (ByteString, KeyCursor)
consumeHead context keys cursor =
  let start = cursor.nextHead * 32
      available = max 0 (BS.length keys - start)
  in if available < 32
      then Left $ MissingKey context cursor.nextHead available
      else Right
        ( BS.take 32 $ BS.drop start keys
        , cursor { nextHead = cursor.nextHead + 1 }
        )

consumeDynamicKey
  :: Text
  -> ByteString
  -> KeyCursor
  -> Either RVMError (ByteString, KeyCursor)
consumeDynamicKey context keys cursor = do
  (offsetWord, cursorAfterHead) <- consumeHead context keys cursor
  offsetInteger <- w256ToBoundedInt ("dynamic key offset for " <> context) (word offsetWord)
  when (offsetInteger `mod` 32 /= 0) $
    Left $ InvalidABIKeys
      ("dynamic key offset for `" <> context <> "` is not 32-byte aligned")
  lengthWord <- sliceExact
    ("dynamic key length for `" <> context <> "`")
    offsetInteger 32 keys
  length' <- w256ToBoundedInt ("dynamic key length for " <> context) (word lengthWord)
  let dataStart = offsetInteger + 32
      paddedEnd = dataStart + roundUp32 length'
  when (paddedEnd < dataStart || paddedEnd > BS.length keys) $
    Left $ InvalidABIKeys
      ("dynamic key data for `" <> context <> "` exceeds the ABI payload")
  keyBytes <- sliceExact ("dynamic key data for `" <> context <> "`") dataStart length' keys
  pure
    ( keyBytes
    , cursorAfterHead
        { dynamicRanges = (offsetInteger, paddedEnd) : cursorAfterHead.dynamicRanges }
    )

sliceExact :: Text -> Int -> Int -> ByteString -> Either RVMError ByteString
sliceExact context start size bytes
  | start < 0 || size < 0 || start > BS.length bytes - size =
      Left $ InvalidABIKeys (context <> " is outside the ABI payload")
  | otherwise = Right $ BS.take size (BS.drop start bytes)

w256ToBoundedInt :: Text -> W256 -> Either RVMError Int
w256ToBoundedInt context value
  | integerValue > toInteger (maxBound :: Int) =
      Left $ NumericOutOfRange context integerValue
  | otherwise = Right $ fromInteger integerValue
  where
    integerValue = toInteger value

validateConsumedKeys :: ByteString -> KeyCursor -> Either RVMError ()
validateConsumedKeys keys cursor = do
  let headEnd = cursor.nextHead * 32
      payloadEnd = BS.length keys
      sortedRanges = sortOn fst cursor.dynamicRanges
  when (headEnd > payloadEnd) $
    Left $ InvalidABIKeys "ABI key head exceeds the payload"
  case sortedRanges of
    [] -> when (headEnd /= payloadEnd) $
      Left $ InvalidABIKeys
        ("resolved " <> T.pack (show cursor.nextHead) <> " key(s), but the payload contains "
          <> T.pack (show $ payloadEnd `div` 32) <> " word(s)")
    ranges -> do
      finalEnd <- foldM checkRange headEnd ranges
      when (finalEnd /= payloadEnd) $
        Left $ InvalidABIKeys "unused or non-canonical bytes remain in the ABI key payload"
  where
    checkRange expectedStart (start, end)
      | start /= expectedStart = Left $ InvalidABIKeys
          "dynamic ABI key tails are overlapping, out of order, or leave unused bytes"
      | end < start = Left $ InvalidABIKeys "dynamic ABI key tail has an invalid range"
      | otherwise = Right end

arrayElementLocation :: W256 -> StorageType -> W256 -> (W256, Int)
arrayElementLocation dataStart baseTy index
  | isPackableLeaf baseTy =
      let perSlot = fromIntegral (32 `div` baseTy.numberOfBytes) :: W256
          slotDelta = index `div` perSlot
          offset = fromIntegral (index `mod` perSlot) * baseTy.numberOfBytes
      in (dataStart + slotDelta, offset)
  | otherwise =
      let slotsPerElement = fromIntegral (slotsForBytes baseTy.numberOfBytes)
      in (dataStart + index * slotsPerElement, 0)

fixedArrayLength :: StorageType -> Either RVMError Integer
fixedArrayLength ty =
  case T.unsnoc ty.label of
    Just (withoutClose, ']') ->
      let (prefix, rawLength) = T.breakOnEnd "[" withoutClose
      in if T.null prefix || T.null rawLength
          then Left $ ArrayLengthUnavailable ty.label
          else parseDecimalInteger ("array length in `" <> ty.label <> "`") rawLength
    _ -> Left $ ArrayLengthUnavailable ty.label

validMappingKeyType :: StorageType -> Bool
validMappingKeyType ty = ty.encoding == "bytes" || validStaticMappingKey ty

validStaticMappingKey :: StorageType -> Bool
validStaticMappingKey ty =
  ty.encoding == "inplace"
    && not (isJust ty.members)
    && not (isJust ty.base)
    && ty.numberOfBytes <= 32

isPackableLeaf :: StorageType -> Bool
isPackableLeaf ty = validStaticMappingKey ty && ty.numberOfBytes < 32

isComposite :: StorageType -> Bool
isComposite ty =
  ty.encoding /= "inplace" || isJust ty.members || isJust ty.base || ty.numberOfBytes > 32

slotsForBytes :: Int -> Int
slotsForBytes size = max 1 (ceilingDiv size 32)

ceilingDiv :: Integral a => a -> a -> a
ceilingDiv numerator denominator = (numerator + denominator - 1) `div` denominator

roundUp32 :: Int -> Int
roundUp32 size = ceilingDiv size 32 * 32

-- Namespaced layouts ------------------------------------------------------------

-- | ERC-7201: @keccak256(abi.encode(uint256(keccak256(ns)) - 1)) & ~0xff@.
erc7201Slot :: Text -> W256
erc7201Slot namespace =
  keccak' (word256Bytes $ keccak' (encodeUtf8 namespace) - 1) .&. complement 0xff

applyNamespace :: Text -> StorageLayout -> Either RVMError StorageLayout
applyNamespace namespace = namespaceStorageLayout namespace (erc7201Slot namespace)

applyNamespaceAt :: W256 -> StorageLayout -> Either RVMError StorageLayout
applyNamespaceAt baseSlot =
  namespaceStorageLayout ("ns_" <> T.pack (show (toInteger baseSlot))) baseSlot

-- | Wrap a relative layout in a synthetic struct rooted at the supplied slot.
-- This retains dotted namespace labels without mutating nested type references.
namespaceStorageLayout
  :: Text
  -> W256
  -> StorageLayout
  -> Either RVMError StorageLayout
namespaceStorageLayout namespace baseSlot layout = do
  when (T.null $ T.strip namespace) $
    Left $ InvalidLayout "namespace label is empty"
  validated <- validateStorageLayout (scopeLayoutTypes namespace layout)
  spanBytes <- layoutSpanBytes validated
  let namespaceTypeId = "t_rvm_namespace(" <> namespace <> ")"
      namespaceType = StorageType
        "inplace"
        ("namespace " <> namespace)
        spanBytes
        Nothing Nothing Nothing
        (Just validated.storage)
  case Map.lookup namespaceTypeId validated.types of
    Just existing | existing /= namespaceType -> Left $ TypeCollision namespaceTypeId
    _ -> pure $ StorageLayout
      [StorageEntry namespace 0 baseSlot namespaceTypeId Nothing]
      (Map.insert namespaceTypeId namespaceType validated.types)

-- Each independently parsed compact layout starts its synthetic struct IDs at
-- one. Scope every referenced type before namespace layouts are merged so two
-- namespaces can safely contain different structs with the same local ID.
scopeLayoutTypes :: Text -> StorageLayout -> StorageLayout
scopeLayoutTypes scope (StorageLayout entries typeMap) =
  StorageLayout
    (map renameEntry entries)
    (Map.fromList
      [ (renameTypeId oldId, renameType ty)
      | (oldId, ty) <- Map.toList typeMap
      ])
  where
    renameTypeId oldId = "t_rvm_scoped(" <> scope <> "):" <> oldId
    renameEntry (StorageEntry entryLabel entryOffset entrySlot entryType entryContract) =
      StorageEntry entryLabel entryOffset entrySlot (renameTypeId entryType) entryContract
    renameType (StorageType typeEncoding typeLabel typeSize typeKey typeValue typeBase typeMembers) =
      StorageType typeEncoding typeLabel typeSize
        (renameTypeId <$> typeKey)
        (renameTypeId <$> typeValue)
        (renameTypeId <$> typeBase)
        (map renameEntry <$> typeMembers)

layoutSpanBytes :: StorageLayout -> Either RVMError Int
layoutSpanBytes layout = do
  ends <- traverse entryEnd layout.storage
  pure . max 32 . roundUp32 $ maximum (0 : ends)
  where
    entryEnd entry = do
      ty <- lookupType layout.types entry.typeId
      slotNumber <- w256ToBoundedInt ("namespace member slot for " <> entry.label) entry.slot
      let end = toInteger slotNumber * 32
              + toInteger entry.offset
              + toInteger ty.numberOfBytes
      if end > toInteger (maxBound :: Int)
        then Left $ NumericOutOfRange ("namespace span for " <> entry.label) end
        else Right (fromInteger end)

mergeStorageLayouts
  :: StorageLayout
  -> StorageLayout
  -> Either RVMError StorageLayout
mergeStorageLayouts left right = do
  left' <- validateStorageLayout left
  right' <- validateStorageLayout right
  rejectDuplicateLabels (left'.storage <> right'.storage)
  mergedTypes <- foldM insertType left'.types (Map.toList right'.types)
  validateStorageLayout $ StorageLayout (left'.storage <> right'.storage) mergedTypes
  where
    insertType typeMap (typeId, ty) = case Map.lookup typeId typeMap of
      Nothing -> Right $ Map.insert typeId ty typeMap
      Just existing
        | existing == ty -> Right typeMap
        | otherwise -> Left $ TypeCollision typeId

-- Packed word operations --------------------------------------------------------

extractPacked :: W256 -> Int -> Int -> Either RVMError W256
extractPacked raw offset size = do
  validatePackedRange offset size
  pure $ (raw `shiftR` (offset * 8)) .&. packedMask size

insertPacked :: W256 -> Int -> Int -> W256 -> Either RVMError W256
insertPacked raw offset size newValue = do
  validatePackedRange offset size
  let shift = offset * 8
      mask = packedMask size
      cleared = raw .&. complement (mask `shiftL` shift)
  pure $ cleared .|. ((newValue .&. mask) `shiftL` shift)

validatePackedRange :: Int -> Int -> Either RVMError ()
validatePackedRange offset size
  | offset < 0 || size <= 0 || size > 32 || offset + size > 32 =
      Left $ InvalidPackedRange offset size
  | otherwise = Right ()

packedMask :: Int -> W256
packedMask 32 = maxBound
packedMask size = (1 `shiftL` (size * 8)) - 1

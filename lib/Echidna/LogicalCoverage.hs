{-# LANGUAGE RecordWildCards #-}

module Echidna.LogicalCoverage
  ( LogicalCoverage(..)
  , CallStats(..)
  , ParamStats(..)
  , emptyLogicalCoverage
  , mergeLogicalCoverage
  , logicalCoverageToJSON
  , updateLogicalCoverage
  , formatLogicalStatus
  , formatLogicalCoverageReport
  ) where

import Control.Monad.Reader (MonadReader, MonadIO)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as BS16
import Data.List (sortBy)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe, maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Vector qualified as V
import Text.Printf (printf)

import EVM.ABI (AbiValue(..), abiValueType)
import EVM.Types (VM(..), VMResult(..), VMType(Concrete), EvmError(..), Expr(..))

import Echidna.ABI (signatureCall, encodeSig, encodeSigWithName, abiCalldata)
import Echidna.ContractName (contractNameForAddr)
import Echidna.Events (decodeRevertMsg)
import Echidna.LogicalCoverage.Types
  ( LogicalCoverage(..)
  , CallStats(..)
  , ParamStats(..)
  , emptyLogicalCoverage
  , emptyCallStats
  , mergeLogicalCoverage
  , logicalCoverageToJSON
  , trimReasons
  )
import Echidna.Types.Config (Env(..))
import Echidna.Types.Signature (SolCall)
import Echidna.Types.Tx (Tx(..), TxCall(..))

updateLogicalCoverage
  :: (MonadReader Env m, MonadIO m)
  => Int
  -> VM Concrete
  -> Tx
  -> VMResult Concrete
  -> LogicalCoverage
  -> m LogicalCoverage
updateLogicalCoverage maxReasons vm tx result (LogicalCoverage m) =
  case tx.call of
    SolCall solCall -> do
      contractName <- contractNameForAddr vm tx.dst
      let sig = signatureCall solCall
      let methodKey = encodeSigWithName contractName sig
      let calldataLen = calldataLength solCall
      let success = isSuccess result
      let reason = if success then Nothing else failureReason result
      let existing = Map.findWithDefault (emptyCallStats (length (snd solCall))) methodKey m
      let updated = applyCallUpdate maxReasons success calldataLen (snd solCall) reason existing
      pure $ LogicalCoverage $ Map.insert methodKey updated m
    _ -> pure $ LogicalCoverage m

formatLogicalStatus :: LogicalCoverage -> String
formatLogicalStatus (LogicalCoverage stats) =
  case selectTopMethod stats of
    Nothing -> ""
    Just (name, st) ->
      let total = st.totalCalls
          ok = st.successCalls
          pct :: Double
          pct = if total == 0 then 0 else fromIntegral ok * 100 / fromIntegral total
          arg0 = formatArg0 st
          suffix = if null arg0 then "" else ", " <> arg0
      in "logic: " <> T.unpack name <> " " <> show ok <> "/" <> show total <> " ok (" <> printf "%.1f%%" pct <> ")" <> suffix

formatLogicalCoverageReport :: Int -> LogicalCoverage -> [String]
formatLogicalCoverageReport topN (LogicalCoverage stats)
  | Map.null stats = ["Logical coverage: none"]
  | otherwise =
      "Logical coverage:" : concatMap formatEntry (take topN sorted)
  where
    sorted = sortMethods stats

formatEntry :: (Text, CallStats) -> [String]
formatEntry (name, st) =
  let total = st.totalCalls
      ok = st.successCalls
      pct :: Double
      pct = if total == 0 then 0 else fromIntegral ok * 100 / fromIntegral total
      header = "  " <> T.unpack name <> ": " <> printf "%.1f%%" pct <> " success (" <> show ok <> "/" <> show total <> ")"
      argLines = formatArgLines st
      reasonLine = formatReasonLine st.revertReasons
  in [header] <> argLines <> maybeToList reasonLine

formatArgLines :: CallStats -> [String]
formatArgLines st =
  let successLines = formatParamRanges "success" st.argStatsSuccess
      failureLines = formatParamRanges "failure" st.argStatsFailure
  in successLines <> failureLines

formatParamRanges :: String -> [ParamStats] -> [String]
formatParamRanges label =
  concatMap (\(idx, stat) -> maybeToList (formatParamRange idx label stat)) . zip [0..]

formatParamRange :: Int -> String -> ParamStats -> Maybe String
formatParamRange idx label = \case
  ParamNumeric{..} ->
    Just $ "    arg" <> show idx <> " " <> label <> " range: [" <> show minValue <> ".." <> show maxValue <> "]"
  ParamBool{..} ->
    Just $ "    arg" <> show idx <> " " <> label <> " bools: true=" <> show trueCount <> ", false=" <> show falseCount
  ParamUnsupported -> Nothing

formatReasonLine :: Map Text Int -> Maybe String
formatReasonLine reasons
  | Map.null reasons = Nothing
  | otherwise =
      let entries = sortBy compareReason (Map.toList reasons)
          formatted = T.intercalate ", " $ map (\(r, c) -> r <> " x" <> T.pack (show c)) entries
      in Just $ "    revert reasons: " <> T.unpack formatted
  where
    compareReason (k1, v1) (k2, v2) = compare v2 v1 <> compare k1 k2

selectTopMethod :: Map Text CallStats -> Maybe (Text, CallStats)
selectTopMethod stats
  | Map.null stats = Nothing
  | otherwise =
      let entries = sortMethods stats
      in case entries of
           [] -> Nothing
           (x:_) -> Just x

sortMethods :: Map Text CallStats -> [(Text, CallStats)]
sortMethods stats =
  sortBy compareMethods (Map.toList stats)
  where
    compareMethods (n1, s1) (n2, s2) =
      compare (s1.failedCalls == 0) (s2.failedCalls == 0)
        <> compare s2.failedCalls s1.failedCalls
        <> compare s2.totalCalls s1.totalCalls
        <> compare n1 n2

applyCallUpdate
  :: Int
  -> Bool
  -> Maybe Int
  -> [AbiValue]
  -> Maybe Text
  -> CallStats
  -> CallStats
applyCallUpdate maxReasons success calldataLen args reason stats =
  stats
    { totalCalls = stats.totalCalls + 1
    , successCalls = stats.successCalls + if success then 1 else 0
    , failedCalls = stats.failedCalls + if success then 0 else 1
    , calldataLenMin = updateMin stats.calldataLenMin calldataLen
    , calldataLenMax = updateMax stats.calldataLenMax calldataLen
    , revertReasons = if success then stats.revertReasons else updateReasons maxReasons stats.revertReasons reason
    , argStatsSuccess =
        if success then updateParamStatsList stats.argStatsSuccess args else stats.argStatsSuccess
    , argStatsFailure =
        if success then stats.argStatsFailure else updateParamStatsList stats.argStatsFailure args
    }

updateParamStatsList :: [ParamStats] -> [AbiValue] -> [ParamStats]
updateParamStatsList existing values =
  let targetLen = max (length existing) (length values)
      padded = existing ++ replicate (targetLen - length existing) ParamUnsupported
      updated = zipWith updateParamStats padded values
  in updated ++ drop (length updated) padded

updateParamStats :: ParamStats -> AbiValue -> ParamStats
updateParamStats stat val =
  case classifyParam val of
    Nothing -> stat
    Just (Left num) ->
      case stat of
        ParamNumeric{..} ->
          ParamNumeric { minValue = min minValue num, maxValue = max maxValue num, count = count + 1 }
        ParamUnsupported -> ParamNumeric { minValue = num, maxValue = num, count = 1 }
        ParamBool{} -> stat
    Just (Right b) ->
      case stat of
        ParamBool{..} ->
          ParamBool { trueCount = trueCount + if b then 1 else 0
                    , falseCount = falseCount + if b then 0 else 1
                    }
        ParamUnsupported ->
          ParamBool { trueCount = if b then 1 else 0, falseCount = if b then 0 else 1 }
        ParamNumeric{} -> stat

classifyParam :: AbiValue -> Maybe (Either Integer Bool)
classifyParam = \case
  AbiUInt _ n -> Just (Left (toInteger n))
  AbiInt _ n -> Just (Left (toInteger n))
  AbiBool b -> Just (Right b)
  _ -> Nothing

updateReasons :: Int -> Map Text Int -> Maybe Text -> Map Text Int
updateReasons maxReasons reasons reason =
  case reason of
    Nothing -> reasons
    Just r ->
      let updated = Map.insertWith (+) r 1 reasons
      in trimReasons maxReasons updated

updateMin :: Ord a => Maybe a -> Maybe a -> Maybe a
updateMin existing newVal = case (existing, newVal) of
  (Nothing, x) -> x
  (x, Nothing) -> x
  (Just x, Just y) -> Just (min x y)

updateMax :: Ord a => Maybe a -> Maybe a -> Maybe a
updateMax existing newVal = case (existing, newVal) of
  (Nothing, x) -> x
  (x, Nothing) -> x
  (Just x, Just y) -> Just (max x y)

calldataLength :: SolCall -> Maybe Int
calldataLength (fname, args) =
  let sig = encodeSig (fname, abiValueType <$> args)
      calldata = abiCalldata sig (V.fromList args)
  in Just (BS.length calldata)

isSuccess :: VMResult Concrete -> Bool
isSuccess = \case
  VMSuccess _ -> True
  _ -> False

failureReason :: VMResult Concrete -> Maybe Text
failureReason = \case
  VMFailure (Revert (ConcreteBuf bs)) -> Just $ decodeRevertReason bs
  VMFailure err -> Just $ "Error(" <> T.pack (show err) <> ")"
  _ -> Nothing

decodeRevertReason :: BS.ByteString -> Text
decodeRevertReason bs =
  fromMaybe fallback (decodeRevertMsg True bs)
  where
    fallback =
      if BS.length bs >= 4
        then "CustomError(" <> selectorHex bs <> ")"
        else "UnknownRevert(" <> T.pack (show (BS.length bs)) <> ")"
    selectorHex bytes =
      let hex = decodeUtf8 (BS16.encode (BS.take 4 bytes))
      in "0x" <> hex

formatArg0 :: CallStats -> String
formatArg0 st =
  case st.argStatsSuccess of
    (ParamNumeric{..}:_) -> "arg0=[" <> show minValue <> ".." <> show maxValue <> "]"
    _ -> ""

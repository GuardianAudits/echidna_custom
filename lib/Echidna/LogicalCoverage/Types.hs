{-# LANGUAGE RecordWildCards #-}

module Echidna.LogicalCoverage.Types
  ( LogicalCoverage(..)
  , CallStats(..)
  , ParamStats(..)
  , emptyLogicalCoverage
  , emptyCallStats
  , mergeLogicalCoverage
  , logicalCoverageToJSON
  , trimReasons
  ) where

import Data.Aeson (ToJSON(..), object, (.=), encode)
import Data.ByteString.Lazy qualified as LBS
import Data.List (sortBy)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)

newtype LogicalCoverage = LogicalCoverage
  { methods :: Map Text CallStats
  } deriving (Eq, Show)

data CallStats = CallStats
  { totalCalls      :: !Int
  , successCalls    :: !Int
  , failedCalls     :: !Int
  , calldataLenMin  :: !(Maybe Int)
  , calldataLenMax  :: !(Maybe Int)
  , revertReasons   :: !(Map Text Int)
  , argStatsSuccess :: ![ParamStats]
  , argStatsFailure :: ![ParamStats]
  } deriving (Eq, Show)

data ParamStats
  = ParamNumeric
      { minValue :: !Integer
      , maxValue :: !Integer
      , count    :: !Int
      }
  | ParamBool
      { trueCount  :: !Int
      , falseCount :: !Int
      }
  | ParamUnsupported
  deriving (Eq, Show)

instance ToJSON ParamStats where
  toJSON = \case
    ParamNumeric{..} ->
      object
        [ "kind" .= ("numeric" :: Text)
        , "min" .= minValue
        , "max" .= maxValue
        , "count" .= count
        ]
    ParamBool{..} ->
      object
        [ "kind" .= ("bool" :: Text)
        , "true" .= trueCount
        , "false" .= falseCount
        ]
    ParamUnsupported ->
      object [ "kind" .= ("unsupported" :: Text) ]

instance ToJSON CallStats where
  toJSON CallStats{..} =
    object
      [ "totalCalls" .= totalCalls
      , "successCalls" .= successCalls
      , "failedCalls" .= failedCalls
      , "calldataLenMin" .= calldataLenMin
      , "calldataLenMax" .= calldataLenMax
      , "revertReasons" .= revertReasons
      , "argStatsSuccess" .= argStatsSuccess
      , "argStatsFailure" .= argStatsFailure
      ]

instance ToJSON LogicalCoverage where
  toJSON (LogicalCoverage m) =
    object [ "methods" .= m ]

logicalCoverageToJSON :: LogicalCoverage -> LBS.ByteString
logicalCoverageToJSON = encode

emptyLogicalCoverage :: LogicalCoverage
emptyLogicalCoverage = LogicalCoverage mempty

emptyCallStats :: Int -> CallStats
emptyCallStats argCount =
  CallStats
    { totalCalls = 0
    , successCalls = 0
    , failedCalls = 0
    , calldataLenMin = Nothing
    , calldataLenMax = Nothing
    , revertReasons = mempty
    , argStatsSuccess = replicate argCount ParamUnsupported
    , argStatsFailure = replicate argCount ParamUnsupported
    }

mergeLogicalCoverage :: Int -> [LogicalCoverage] -> LogicalCoverage
mergeLogicalCoverage maxReasons coverages =
  LogicalCoverage $
    Map.map (trimReasons maxReasons) $
      Map.unionsWith mergeCallStats (map (.methods) coverages)

mergeCallStats :: CallStats -> CallStats -> CallStats
mergeCallStats a b =
  CallStats
    { totalCalls = a.totalCalls + b.totalCalls
    , successCalls = a.successCalls + b.successCalls
    , failedCalls = a.failedCalls + b.failedCalls
    , calldataLenMin = minMaybe a.calldataLenMin b.calldataLenMin
    , calldataLenMax = maxMaybe a.calldataLenMax b.calldataLenMax
    , revertReasons = Map.unionWith (+) a.revertReasons b.revertReasons
    , argStatsSuccess = mergeParamStatsList a.argStatsSuccess b.argStatsSuccess
    , argStatsFailure = mergeParamStatsList a.argStatsFailure b.argStatsFailure
    }

mergeParamStatsList :: [ParamStats] -> [ParamStats] -> [ParamStats]
mergeParamStatsList a b =
  let targetLen = max (length a) (length b)
      pad xs = xs ++ replicate (targetLen - length xs) ParamUnsupported
      zipped = zipWith mergeParamStats (pad a) (pad b)
  in zipped

mergeParamStats :: ParamStats -> ParamStats -> ParamStats
mergeParamStats x y = case (x, y) of
  (ParamNumeric minA maxA countA, ParamNumeric minB maxB countB) ->
    ParamNumeric { minValue = min minA minB, maxValue = max maxA maxB, count = countA + countB }
  (ParamBool tA fA, ParamBool tB fB) ->
    ParamBool { trueCount = tA + tB, falseCount = fA + fB }
  (ParamUnsupported, other) -> other
  (other, ParamUnsupported) -> other
  _ -> x

trimReasons :: Int -> Map Text Int -> Map Text Int
trimReasons maxReasons reasons
  | maxReasons <= 0 = mempty
  | Map.size reasons <= maxReasons = reasons
  | otherwise = Map.fromList $ take maxReasons $ sortBy compareReason (Map.toList reasons)
  where
    compareReason (k1, v1) (k2, v2) = compare v2 v1 <> compare k1 k2

minMaybe :: Ord a => Maybe a -> Maybe a -> Maybe a
minMaybe a b = case (a, b) of
  (Nothing, x) -> x
  (x, Nothing) -> x
  (Just x, Just y) -> Just (min x y)

maxMaybe :: Ord a => Maybe a -> Maybe a -> Maybe a
maxMaybe a b = case (a, b) of
  (Nothing, x) -> x
  (x, Nothing) -> x
  (Just x, Just y) -> Just (max x y)

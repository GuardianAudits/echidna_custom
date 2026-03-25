module Echidna.Recent
  ( RecentMap
  , emptyRecentMap
  , lookupRecent
  , insertRecent
  , deleteRecent
  , sizeRecent
  , keysRecent
  , pruneRecentBy
  ) where

import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq(..))
import Data.Sequence qualified as Seq

data RecentMap k v = RecentMap
  { limit :: !Int
  , order :: !(Seq k)
  , items :: !(Map k v)
  }

emptyRecentMap :: Int -> RecentMap k v
emptyRecentMap n = RecentMap (max 1 n) Seq.empty Map.empty

lookupRecent :: Ord k => k -> RecentMap k v -> Maybe v
lookupRecent key recent = Map.lookup key recent.items

insertRecent :: Ord k => k -> v -> RecentMap k v -> RecentMap k v
insertRecent key value recent =
  trimToLimit $
    RecentMap
      { limit = recent.limit
      , order = Seq.filter (/= key) recent.order Seq.|> key
      , items = Map.insert key value recent.items
      }

deleteRecent :: Ord k => k -> RecentMap k v -> RecentMap k v
deleteRecent key recent =
  RecentMap
    { limit = recent.limit
    , order = Seq.filter (/= key) recent.order
    , items = Map.delete key recent.items
    }

sizeRecent :: RecentMap k v -> Int
sizeRecent recent = Map.size recent.items

keysRecent :: RecentMap k v -> [k]
keysRecent recent = toList recent.order

pruneRecentBy :: Ord k => (k -> v -> Bool) -> RecentMap k v -> RecentMap k v
pruneRecentBy keep recent =
  foldr pruneOne recent (keysRecent recent)
  where
    pruneOne key acc =
      case Map.lookup key acc.items of
        Just value | keep key value -> acc
        _ -> deleteRecent key acc

trimToLimit :: Ord k => RecentMap k v -> RecentMap k v
trimToLimit recent
  | sizeRecent recent <= recent.limit = recent
  | otherwise =
      case Seq.viewl recent.order of
        Seq.EmptyL -> recent
        key Seq.:< rest ->
          trimToLimit $
            RecentMap
              { limit = recent.limit
              , order = rest
              , items = Map.delete key recent.items
              }

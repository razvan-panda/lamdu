-- | A Data.Map wrapper with saner Semigroup/Monoid instances
{-# LANGUAGE TemplateHaskell, GeneralizedNewtypeDeriving, TypeFamilies, FlexibleInstances, MultiParamTypeClasses #-}
module Data.MMap
    ( MMap(..), _MMap
    , fromList
    , fromSet, keysSet
    , filter, mapMaybe
    ) where

import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Data.Binary (Binary)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Semigroup (Semigroup(..))
import           Data.Set (Set)

import           Prelude hiding (filter)

-- | A Map with a sensible Monoid/Semigroup instance
newtype MMap k v = MMap (Map k v)
    deriving (Eq, Ord, Show, Read, Binary, Functor, Foldable, Traversable)

Lens.makePrisms ''MMap

instance Lens.FunctorWithIndex k (MMap k) where imap f = _MMap %~ Lens.imap f
instance Lens.FoldableWithIndex k (MMap k) where ifoldMap f = Lens.ifoldMap f . (^. _MMap)
instance Lens.TraversableWithIndex k (MMap k) where itraverse f = _MMap %%~ Lens.itraverse f

type instance Lens.Index (MMap k v) = k
type instance Lens.IxValue (MMap k v) = v
instance Ord k => Lens.Ixed (MMap k v) where ix k = _MMap . Lens.ix k
instance Ord k => Lens.At (MMap k v) where at k = _MMap . Lens.at k

instance (Ord k, Semigroup v) => Semigroup (MMap k v) where
    MMap m1 <> MMap m2 = Map.unionWith (<>) m1 m2 & MMap

instance (Ord k, Monoid v) => Monoid (MMap k v) where
    mempty = MMap Map.empty
    MMap m1 `mappend` MMap m2 = Map.unionWith mappend m1 m2 & MMap

fromList :: Ord k => [(k, v)] -> MMap k v
fromList = MMap . Map.fromList

fromSet :: (k -> v) -> Set k -> MMap k v
fromSet f = MMap . Map.fromSet f

keysSet :: MMap k v -> Set k
keysSet (MMap m) = Map.keysSet m

filter :: (v -> Bool) -> MMap k v -> MMap k v
filter p = _MMap %~ Map.filter p

mapMaybe :: (a -> Maybe b) -> MMap k a -> MMap k b
mapMaybe f = _MMap %~ Map.mapMaybe f

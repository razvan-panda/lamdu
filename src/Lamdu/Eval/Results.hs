{-# LANGUAGE TemplateHaskell, GeneralizedNewtypeDeriving #-}
module Lamdu.Eval.Results
    ( Body(..), _RRecExtend, _RInject, _RFunc, _RRecEmpty, _RPrimVal, _RError, _RArray
    , Val(..), payload, body
    , ScopeId(..), topLevelScopeId
    , EvalError(..)
    , EvalResults(..), erExprValues, erAppliesOfLam, erCache, empty
    , extractField
    ) where

import qualified Control.Lens as Lens
import           Data.Binary (Binary)
import           Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import qualified Data.Map as Map
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Calc.Val as V

import           Lamdu.Prelude

newtype ScopeId = ScopeId Int
    deriving (Show, Eq, Ord, Binary)

data EvalError
    = EvalHole
    | EvalTypeError String
    deriving (Show, Eq, Ord)

topLevelScopeId :: ScopeId
topLevelScopeId = ScopeId 0

data Body val
    = RRecExtend (V.RecExtend val)
    | RInject (V.Inject val)
    | RFunc Int -- Identifier for function instance
    | RRecEmpty
    | RPrimVal V.PrimVal
    | RArray [val]
    | RError EvalError
    deriving (Show, Functor, Foldable, Traversable)

data Val pl = Val
    { _payload :: pl
    , _body :: Body (Val pl)
    } deriving (Show, Functor, Foldable, Traversable)

extractField :: Show a => a -> T.Tag -> Val a -> Val a
extractField errPl tag (Val _ (RRecExtend (V.RecExtend vt vv vr)))
    | vt == tag = vv
    | otherwise = extractField errPl tag vr
extractField _ _ v@(Val _ RError {}) = v
extractField errPl tag x =
    "Expected record with tag: " ++ show tag ++ " got: " ++ show x
    & EvalTypeError & RError & Val errPl

data EvalResults srcId =
    EvalResults
    { _erExprValues :: Map srcId (Map ScopeId (Val ()))
    , _erAppliesOfLam :: Map srcId (Map ScopeId [(ScopeId, Val ())])
    , _erCache :: IntMap (Val ())
    } deriving Show

empty :: EvalResults srcId
empty =
    EvalResults
    { _erExprValues = Map.empty
    , _erAppliesOfLam = Map.empty
    , _erCache = IntMap.empty
    }

Lens.makeLenses ''EvalResults
Lens.makeLenses ''Val
Lens.makePrisms ''Body

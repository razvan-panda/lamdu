{-# LANGUAGE TemplateHaskell #-}
module Lamdu.Sugar.Types.GetVar
    ( NameRef(..), nrName, nrGotoDefinition
    , ParamRef(..), pNameRef, pBinderMode
    , BinderVarForm(..), _GetDefinition, _GetLet
    , DefinitionForm(..), _DefUpToDate, _DefDeleted, _DefTypeChanged
    , DefinitionOutdatedType(..), defTypeWhenUsed, defTypeCurrent, defTypeUseCurrent
    , BinderVarInline(..), _InlineVar, _CannotInlineDueToUses, _CannotInline
    , BinderVarRef(..), bvNameRef, bvForm, bvVar, bvInline
    , BinderMode(..)
    , GetVar(..), _GetParam, _GetParamsRecord, _GetBinder
    , ParamsRecordVarRef(..), prvFieldNames
    ) where

import qualified Control.Lens as Lens
import qualified Lamdu.Calc.Val as V
import           Lamdu.Sugar.Internal.EntityId (EntityId)
import           Lamdu.Sugar.Types.Type

import           Lamdu.Prelude

data BinderMode = NormalBinder | LightLambda

data NameRef name m = NameRef
    { _nrName :: name
    , _nrGotoDefinition :: m EntityId
    }
instance Show name => Show (NameRef name m) where
    show (NameRef name _) = show name

data ParamRef name m = ParamRef
    { _pNameRef :: NameRef name m
    , _pBinderMode :: BinderMode
    }

data DefinitionOutdatedType name a = DefinitionOutdatedType
    { _defTypeWhenUsed :: Scheme name
    , _defTypeCurrent :: Scheme name
    , _defTypeUseCurrent :: a
    } deriving (Functor, Foldable, Traversable)
instance Show name => Show (DefinitionOutdatedType name a) where
    show (DefinitionOutdatedType usedType newType _) =
        "(Used @type: " ++ show usedType ++ " now type: " ++ show newType ++ ")"

data DefinitionForm name m =
    DefUpToDate | DefDeleted | DefTypeChanged (DefinitionOutdatedType name (m EntityId))
    deriving Show

data BinderVarForm name m = GetDefinition (DefinitionForm name m) | GetLet deriving Show

data BinderVarInline m
    = InlineVar (m EntityId)
    | CannotInlineDueToUses [EntityId]
    | CannotInline

data BinderVarRef name m = BinderVarRef
    { _bvNameRef :: NameRef name m
    , _bvForm :: BinderVarForm name m
    , _bvVar :: V.Var
    , -- Just means it is stored and inlinable:
      _bvInline :: BinderVarInline m
    }
instance Show name => Show (BinderVarRef name m) where
    show (BinderVarRef nameRef form _ _) = "(BinderVar " ++ show nameRef ++ " (form=" ++ show form ++ "))"

newtype ParamsRecordVarRef name = ParamsRecordVarRef
    { _prvFieldNames :: [name]
    } deriving (Eq, Ord, Functor, Foldable, Traversable)

data GetVar name m
    = GetParam (ParamRef name m)
    | GetParamsRecord (ParamsRecordVarRef name)
    | GetBinder (BinderVarRef name m)

Lens.makeLenses ''BinderVarRef
Lens.makeLenses ''DefinitionOutdatedType
Lens.makeLenses ''NameRef
Lens.makeLenses ''ParamRef
Lens.makeLenses ''ParamsRecordVarRef
Lens.makePrisms ''BinderVarForm
Lens.makePrisms ''BinderVarInline
Lens.makePrisms ''DefinitionForm
Lens.makePrisms ''GetVar

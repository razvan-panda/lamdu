module Lamdu.Eval.Results.Process
    ( addTypes
    ) where

import qualified Control.Lens as Lens
import qualified Data.Map as Map
import qualified Lamdu.Builtins.Anchors as Builtins
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Calc.Type.FlatComposite as FlatComposite
import qualified Lamdu.Calc.Type.Nominal as N
import           Lamdu.Calc.Type.Scheme (schemeType)
import qualified Lamdu.Calc.Val as V
import           Lamdu.Eval.Results (Val(..), Body(..))
import qualified Lamdu.Eval.Results as ER
import           Lamdu.Infer (applyNominal)

import           Lamdu.Prelude

extractRecordTypeField :: T.Tag -> T.Type -> Maybe (T.Type, T.Type)
extractRecordTypeField tag typ =
    do
        comp <- typ ^? T._TRecord
        let flat = FlatComposite.fromComposite comp
        fieldType <- flat ^. FlatComposite.fields . Lens.at tag
        Just
            ( fieldType
            , flat
              & FlatComposite.fields . Lens.at tag .~ Nothing
              & FlatComposite.toComposite & T.TRecord
            )

extractVariantTypeField :: T.Tag -> T.Type -> Maybe T.Type
extractVariantTypeField tag typ =
    do
        comp <- typ ^? T._TVariant
        FlatComposite.fromComposite comp ^. FlatComposite.fields . Lens.at tag

type AddTypes val res = (T.Type -> val -> res) -> T.Type -> Body res

addTypesRecExtend :: V.RecExtend val -> AddTypes val res
addTypesRecExtend (V.RecExtend tag val rest) go typ =
    case extractRecordTypeField tag typ of
    Nothing ->
        -- TODO: this is a work-around for a bug. HACK
        -- we currently don't know types for eval results of polymorphic values
        case typ of
        T.TVar{} ->
            V.RecExtend tag
            (go typ val)
            (go typ rest)
            & RRecExtend
        T.TInst{} ->
            -- Work around for MutRefs: todo better presentation which shows their current value?
            RRecEmpty
        _ -> "addTypesRecExtend got " ++ show typ & ER.EvalTypeError & RError
    Just (valType, restType) ->
        V.RecExtend tag
        (go valType val)
        (go restType rest)
        & RRecExtend

addTypesInject :: V.Inject val -> AddTypes val res
addTypesInject (V.Inject tag val) go typ =
    case extractVariantTypeField tag typ of
    Nothing ->
        -- TODO: this is a work-around for a bug. HACK
        -- we currently don't know types for eval results of polymorphic values
        case typ of
        T.TVar{} -> go typ val & V.Inject tag & RInject
        _ -> "addTypesInject got " ++ show typ & ER.EvalTypeError & RError
    Just valType -> go valType val & V.Inject tag & RInject

addTypesArray :: [val] -> AddTypes val res
addTypesArray items go typ =
    case typ ^? T._TInst . _2 . Lens.ix Builtins.valTypeParamId of
    Nothing ->
        -- TODO: this is a work-around for a bug. HACK
        -- we currently don't know types for eval results of polymorphic values
        case typ of
        T.TVar{} -> items <&> go typ & RArray
        _ -> "addTypesArray got " ++ show typ & ER.EvalTypeError & RError
    Just paramType -> items <&> go paramType & RArray

addTypes :: Map T.NominalId N.Nominal -> T.Type -> Val () -> Val T.Type
addTypes nomsMap typ (Val () b) =
    case b of
    RRecExtend recExtend -> recurse (addTypesRecExtend recExtend)
    RInject inject -> recurse (addTypesInject inject)
    RArray items -> recurse (addTypesArray items)
    RFunc x -> RFunc x
    RRecEmpty -> RRecEmpty
    RPrimVal l -> RPrimVal l
    RError e -> RError e
    & Val typ
    where
        recurse f = f (addTypes nomsMap) (unwrapTInsts nomsMap typ)

-- Will loop forever for bottoms like: newtype Void = Void Void
unwrapTInsts :: Map T.NominalId N.Nominal -> T.Type -> T.Type
unwrapTInsts nomsMap typ =
    case typ of
    T.TInst tid params ->
        Map.lookup tid nomsMap
        & fromMaybe (error "addTypes: nominal missing from map")
        & applyNominal params
        & \case
          N.OpaqueNominal -> typ
          N.NominalType scheme -> scheme ^. schemeType & unwrapTInsts nomsMap
    _ -> typ

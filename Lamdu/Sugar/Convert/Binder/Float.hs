{-# LANGUAGE PatternGuards, NoImplicitPrelude #-}

module Lamdu.Sugar.Convert.Binder.Float
    ( makeFloatLetToOuterScope
    ) where

import qualified Control.Lens as Lens
import           Control.Lens.Operators
import qualified Data.Set as Set
import qualified Data.Store.Property as Property
import           Data.Store.Transaction (Transaction)
import qualified Lamdu.Calc.Type as T
import qualified Lamdu.Calc.Val as V
import           Lamdu.Calc.Val.Annotated (Val(..))
import qualified Lamdu.Calc.Val.Annotated as Val
import qualified Lamdu.Data.Ops as DataOps
import qualified Lamdu.Data.Ops.Subexprs as SubExprs
import           Lamdu.Expr.IRef (ValI, ValIProperty)
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Lens as ExprLens
import qualified Lamdu.Sugar.Convert.Binder.Params as Params
import           Lamdu.Sugar.Convert.Binder.Redex (Redex(..))
import qualified Lamdu.Sugar.Convert.Binder.Redex as Redex
import           Lamdu.Sugar.Convert.Binder.Types (BinderKind(..))
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import qualified Lamdu.Sugar.Convert.Monad as ConvertM
import qualified Lamdu.Sugar.Internal.EntityId as EntityId
import           Lamdu.Sugar.OrderTags (orderedClosedFlatComposite)
import           Lamdu.Sugar.Types

import           Prelude.Compat

type T = Transaction

moveToGlobalScope :: Monad m => ConvertM.Context m -> V.Var -> ValI m -> T m ()
moveToGlobalScope ctx param letI =
    DataOps.newPublicDefinitionToIRef
    (ctx ^. ConvertM.scCodeAnchors) letI (ExprIRef.defI param)

data NewLet m = NewLet
    { nlIRef :: ValI m
    , nlMVarToTags :: Maybe VarToTags
    }

isVarAlwaysApplied :: V.Var -> Val a -> Bool
isVarAlwaysApplied var =
    go False
    where
        go isApplied (Val _ (V.BLeaf (V.LVar v))) | v == var = isApplied
        go _ (Val _ (V.BApp (V.Apply f a))) = go True f && go False a
        go _ v = all (go False) (v ^.. Val.body . Lens.traverse)

convertLetToLam ::
    Monad m => V.Var -> Redex (ValIProperty m) -> T m (NewLet m)
convertLetToLam varToReplace redex =
    do
        (ParamAddResultNewVar _ newParam, newValI) <-
            Params.convertBinderToFunction mkArg
            (BinderKindLet (redex ^. Redex.redexLam)) (redex ^. Redex.redexArg)
        let toNewParam prop =
                V.LVar newParam & V.BLeaf &
                ExprIRef.writeValBody (Property.value prop)
        SubExprs.onGetVars toNewParam varToReplace (redex ^. Redex.redexArg)
        return NewLet
            { nlIRef = newValI
            , nlMVarToTags = Nothing
            }
    where
        mkArg = V.LVar varToReplace & V.BLeaf & ExprIRef.newValBody

convertVarToGetFieldParam ::
    Monad m =>
    V.Var -> T.Tag -> V.Lam (Val (ValIProperty m)) -> T m ()
convertVarToGetFieldParam oldVar paramTag (V.Lam lamVar lamBody) =
    SubExprs.onGetVars toNewParam oldVar lamBody
    where
        toNewParam prop =
            V.LVar lamVar & V.BLeaf
            & ExprIRef.newValBody
            <&> (`V.GetField` paramTag) <&> V.BGetField
            >>= ExprIRef.writeValBody (Property.value prop)

convertLetParamToRecord ::
    Monad m =>
    V.Var -> V.Lam (Val (ValIProperty m)) -> Params.StoredLam m -> T m (NewLet m)
convertLetParamToRecord varToReplace letLam storedLam =
    do
        vtt <-
            Params.convertToRecordParams
            mkNewArg (BinderKindLet letLam) storedLam Params.NewParamAfter
        convertVarToGetFieldParam varToReplace (vttNewTag vtt ^. tagVal)
            (storedLam ^. Params.slLam)
        return NewLet
            { nlIRef = Params.slLambdaProp storedLam & Property.value
            , nlMVarToTags = Just vtt
            }
    where
        mkNewArg = V.LVar varToReplace & V.BLeaf & ExprIRef.newValBody

addFieldToLetParamsRecord ::
    Monad m =>
    [T.Tag] -> V.Var -> V.Lam (Val (ValIProperty m)) -> Params.StoredLam m ->
    T m (NewLet m)
addFieldToLetParamsRecord fieldTags varToReplace letLam storedLam =
    do
        newParamTag <-
            Params.addFieldParam mkNewArg (BinderKindLet letLam)
            ((fieldTags ++) . return) storedLam
        convertVarToGetFieldParam varToReplace (newParamTag ^. tagVal)
            (storedLam ^. Params.slLam)
        return NewLet
            { nlIRef = Params.slLambdaProp storedLam & Property.value
            , nlMVarToTags = Nothing
            }
    where
        mkNewArg = V.LVar varToReplace & V.BLeaf & ExprIRef.newValBody

addLetParam ::
    Monad m => V.Var -> Redex (ValIProperty m) -> T m (NewLet m)
addLetParam varToReplace redex =
    case redex ^. Redex.redexArg . Val.body of
    V.BLam lam | isVarAlwaysApplied param body ->
        case redex ^. Redex.redexArgType of
        T.TFun (T.TRecord composite) _
            | Just fields <- composite ^? orderedClosedFlatComposite
            , Params.isParamAlwaysUsedWithGetField lam ->
            addFieldToLetParamsRecord
                (fields <&> fst) varToReplace (redex ^. Redex.redexLam) storedLam
        _ -> convertLetParamToRecord varToReplace (redex ^. Redex.redexLam) storedLam
        where
            storedLam = Params.StoredLam lam (redex ^. Redex.redexArg . Val.payload)
    _ -> convertLetToLam varToReplace redex
    where
        V.Lam param body = redex ^. Redex.redexLam

sameLet :: Redex (ValIProperty m) -> NewLet m
sameLet redex =
    NewLet
    { nlIRef = redex ^. Redex.redexArg . Val.payload & Property.value
    , nlMVarToTags = Nothing
    }

floatLetToOuterScope ::
    Monad m =>
    (ValI m -> T m ()) ->
    Redex (ValIProperty m) -> ConvertM.Context m ->
    T m LetFloatResult
floatLetToOuterScope setTopLevel redex ctx =
    do
        newLet <-
            case varsToRemove of
            [] -> sameLet redex & return
            [x] -> addLetParam x redex
            _ -> error "multiple osiVarsUnderPos not expected!?"
        redex ^. Redex.redexLam . V.lamResult . Val.payload . Property.pVal & setTopLevel
        resultEntity <-
            case outerScopeInfo ^. ConvertM.osiPos of
            Nothing ->
                EntityId.ofIRef (ExprIRef.defI param) <$
                moveToGlobalScope ctx param (nlIRef newLet)
            Just outerScope ->
                EntityId.ofLambdaParam param <$
                DataOps.redexWrapWithGivenParam param (nlIRef newLet) outerScope
        return LetFloatResult
            { lfrNewEntity = resultEntity
            , lfrMVarToTags = nlMVarToTags newLet
            }
    where
        param = redex ^. Redex.redexLam . V.lamParamId
        varsToRemove =
            filter (`Set.member` usedVars)
            (outerScopeInfo ^. ConvertM.osiVarsUnderPos)
        outerScopeInfo = ctx ^. ConvertM.scScopeInfo . ConvertM.siOuter
        usedVars =
            redex ^.. Redex.redexArg . ExprLens.valLeafs . V._LVar
            & Set.fromList

makeFloatLetToOuterScope ::
    Monad m =>
    (ValI m -> T m ()) -> Redex (ValIProperty m) ->
    ConvertM m (T m LetFloatResult)
makeFloatLetToOuterScope setTopLevel redex =
    ConvertM.readContext <&> floatLetToOuterScope setTopLevel redex

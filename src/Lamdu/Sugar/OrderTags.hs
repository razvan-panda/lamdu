module Lamdu.Sugar.OrderTags
    ( orderDef, orderType, orderExpr
    , orderedClosedFlatComposite
    ) where

import qualified Control.Lens as Lens
import           Control.Lens.Utils (tagged)
import           Control.Monad ((>=>))
import           Data.List (sortOn)
import qualified Data.Property as Property
import qualified Lamdu.Calc.Type as T
import           Lamdu.Data.Anchors (assocTagOrder)
import qualified Lamdu.Sugar.Lens as SugarLens
import qualified Lamdu.Sugar.Types as Sugar
import           Revision.Deltum.Transaction (Transaction)

import           Lamdu.Prelude

type T = Transaction
type Order m x = x -> T m x

orderByTag :: Monad m => (a -> Sugar.TagInfo name) -> Order m [a]
orderByTag toTag =
    fmap (map fst . sortOn snd) . mapM loadOrder
    where
        loadOrder x =
            toTag x ^. Sugar.tagVal
            & assocTagOrder
            & Property.getP
            <&> (,) x

orderComposite :: Monad m => Order m (Sugar.CompositeFields p name (Sugar.Type a))
orderComposite =
    Sugar.compositeFields $
    \fields -> fields & orderByTag (^. _1) >>= traverse . _2 %%~ orderType

orderTBody :: Monad m => Order m (Sugar.TBody name (Sugar.Type name))
orderTBody t =
    t
    & Sugar._TRecord %%~ orderComposite
    >>= Sugar._TVariant %%~ orderComposite
    >>= traverse orderType

orderType :: Monad m => Order m (Sugar.Type name)
orderType = Sugar.tBody %%~ orderTBody

orderRecord :: Monad m => Order m (Sugar.Composite name (T f) a)
orderRecord = Sugar.cItems %%~ orderByTag (^. Sugar.ciTag . Sugar.tagInfo)

orderLabeledApply :: Monad m => Order m (Sugar.LabeledApply name binderVar a)
orderLabeledApply = Sugar.aAnnotatedArgs %%~ orderByTag (^. Sugar.aaTag)

orderCase :: Monad m => Order m (Sugar.Case name (T m) a)
orderCase = Sugar.cBody %%~ orderRecord

orderLam :: Monad m => Order m (Sugar.Lambda name (T m) a)
orderLam = Sugar.lamBinder orderBinder

orderBody :: Monad m => Order m (Sugar.Body name (T m) a)
orderBody (Sugar.BodyLam l) = orderLam l <&> Sugar.BodyLam
orderBody (Sugar.BodyRecord r) = orderRecord r <&> Sugar.BodyRecord
orderBody (Sugar.BodyLabeledApply a) = orderLabeledApply a <&> Sugar.BodyLabeledApply
orderBody (Sugar.BodyCase c) = orderCase c <&> Sugar.BodyCase
orderBody (Sugar.BodyHole a) = SugarLens.holeTransformExprs orderExpr a & Sugar.BodyHole & pure
orderBody (Sugar.BodyFragment a) =
    a
    & Sugar.fOptions . Lens.mapped . Lens.mapped %~ SugarLens.holeOptionTransformExprs orderExpr
    & Sugar.BodyFragment
    & pure
orderBody x@Sugar.BodyIfElse{} = pure x
orderBody x@Sugar.BodySimpleApply{} = pure x
orderBody x@Sugar.BodyLiteral{} = pure x
orderBody x@Sugar.BodyGetField{} = pure x
orderBody x@Sugar.BodyGetVar{} = pure x
orderBody x@Sugar.BodyInject{} = pure x
orderBody x@Sugar.BodyToNom{} = pure x
orderBody x@Sugar.BodyFromNom{} = pure x
orderBody x@Sugar.BodyPlaceHolder{} = pure x

orderExpr :: Monad m => Order m (Sugar.Expression name (T m) a)
orderExpr e =
    e
    & Sugar.rPayload . Sugar.plAnnotation . Sugar.aInferredType %%~ orderType
    >>= Sugar.rBody %%~ orderBody
    >>= Sugar.rBody . Lens.traversed %%~ orderExpr

orderBinder :: Monad m => Order m (Sugar.Binder name (T m) a)
orderBinder =
    -- The ordering for binder params already occurs at the Binder's conversion,
    -- because it needs to be consistent with the presentation mode.
    pure

orderDef ::
    Monad m => Order m (Sugar.Definition name (T m) (Sugar.Expression name (T m) a))
orderDef def =
    def
    & SugarLens.defSchemes . Sugar.schemeType %%~ orderType
    >>= Sugar.drBody . Sugar._DefinitionBodyExpression . Sugar.deContent
        %%~ (orderBinder >=> Lens.traversed %%~ orderExpr)

{-# INLINE orderedFlatComposite #-}
orderedFlatComposite ::
    Lens.Iso (T.Composite a) (T.Composite b)
    ([(T.Tag, T.Type)], Maybe (T.Var (T.Composite a)))
    ([(T.Tag, T.Type)], Maybe (T.Var (T.Composite b)))
orderedFlatComposite =
    Lens.iso to from
    where
        to T.CEmpty = ([], Nothing)
        to (T.CVar x) = ([], Just x)
        to (T.CExtend tag typ rest) = to rest & Lens._1 %~ (:) (tag, typ)
        from ([], Nothing) = T.CEmpty
        from ([], Just x) = T.CVar x
        from ((tag,typ):rest, v) = (rest, v) & from & T.CExtend tag typ

orderedClosedFlatComposite :: Lens.Prism' (T.Composite b) [(T.Tag, T.Type)]
orderedClosedFlatComposite = orderedFlatComposite . tagged Lens._Nothing

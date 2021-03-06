-- | Convert Text ToNoms to their own sugar construct
module Lamdu.Sugar.Convert.Text
     ( text
     ) where

import           Control.Monad (mzero)
import           Control.Monad.Trans.Maybe (MaybeT(..))
import           Data.Maybe.Utils (maybeToMPlus)
import           Data.Property (Property(..))
import qualified Data.Property as Property
import           Data.Text.Encoding (decodeUtf8', encodeUtf8)
import qualified Lamdu.Builtins.Anchors as Builtins
import qualified Lamdu.Builtins.PrimVal as PrimVal
import qualified Lamdu.Calc.Val as V
import           Lamdu.Calc.Val.Annotated (Val(..))
import qualified Lamdu.Expr.IRef as ExprIRef
import qualified Lamdu.Expr.Lens as ExprLens
import           Lamdu.Sugar.Convert.Expression.Actions (addActions)
import qualified Lamdu.Sugar.Convert.Input as Input
import           Lamdu.Sugar.Convert.Monad (ConvertM)
import           Lamdu.Sugar.Internal
import           Lamdu.Sugar.Types

import           Lamdu.Prelude

text ::
    Monad m =>
    V.Nom (Val (Input.Payload m a)) -> Input.Payload m a ->
    MaybeT (ConvertM m) (ExpressionU m a)
text (V.Nom tid (Val litPl body)) toNomPl =
    do
        guard $ tid == Builtins.textTid
        lit <- body ^? ExprLens.valBodyLiteral & maybeToMPlus
        txt <-
            case PrimVal.toKnown lit of
            PrimVal.Bytes utf8Bytes ->
                case decodeUtf8' utf8Bytes of
                Right txt -> pure txt
                Left{} -> mzero
            _ -> mzero
        Property
            { _pVal = txt
            , _pSet =
                ExprIRef.writeValBody litIRef . V.BLeaf . V.LLiteral .
                PrimVal.fromKnown . PrimVal.Bytes . encodeUtf8
            } & LiteralText & BodyLiteral & addActions toNomPl
            & lift
    where
        litIRef = litPl ^. Input.stored . Property.pVal

{-# LANGUAGE NoImplicitPrelude #-}

module Lamdu.Sugar.EvalResults
    ( addToWorkArea
    ) where

import           Data.CurAndPrev (CurAndPrev(..))
import           Lamdu.Eval.Results (EvalResults)
import           Lamdu.Expr.IRef (ValI)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

addToWorkArea ::
    CurAndPrev (EvalResults (ValI m)) ->
    Sugar.WorkArea a b c -> Sugar.WorkArea a b c
addToWorkArea _ = undefined

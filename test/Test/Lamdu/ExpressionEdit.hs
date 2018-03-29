-- | Test expression edits against sequences of inputs

module Test.Lamdu.ExpressionEdit
    ( testExpr
    ) where

import           Data.Vector.Vector2 (Vector2(..))
import qualified GUI.Momentu.Main as Main
import           GUI.Momentu.State (GUIState(..))
import qualified GUI.Momentu.Test as MomentuTest
import qualified GUI.Momentu.Zoom as Zoom
import qualified Lamdu.GUI.ExpressionEdit as ExpressionEdit
import qualified Lamdu.GUI.WidgetIds as WidgetIds

import           Lamdu.Prelude

mkWidget :: Main.Env -> IO (Widget (MomentuTest.Update IO))

testExpr valExpr =
    do
        zoom <- Zoom.makeUnscaled 1
        let initEnv =
                Main.Env
                { Main._eZoom = zoom
                , Main._eWindowSize = Vector2 800 600
                , Main._eState = GUIState myId mempty
                }
        MomentuTest.mainLoop initEnv mkWidget _events
    where
        myId = WidgetIds.fromExprPayload pl
        exprEdit = ExpressionEdit.make sugarExpr

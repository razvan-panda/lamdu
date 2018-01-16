{-# LANGUAGE NoImplicitPrelude, OverloadedStrings #-}
module Lamdu.GUI.ExpressionEdit.HoleEdit
    ( make
    ) where

import qualified Control.Lens as Lens
import qualified Data.Char as Char
import           Data.Store.Transaction (Transaction)
import qualified Data.Text as Text
import qualified GUI.Momentu.State as GuiState
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Menu as Menu
import qualified Lamdu.GUI.ExpressionEdit.EventMap as ExprEventMap
import           Lamdu.GUI.ExpressionEdit.HoleEdit.LiteralText (makeLiteralTextEventMap)
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.SearchArea as SearchArea
import           Lamdu.GUI.ExpressionEdit.HoleEdit.WidgetIds (WidgetIds(..))
import qualified Lamdu.GUI.ExpressionEdit.HoleEdit.WidgetIds as HoleWidgetIds
import           Lamdu.GUI.ExpressionGui (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui as ExprGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import           Lamdu.Name (Name)
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

type T = Transaction

allowedHoleSearchTerm :: Text -> Bool
allowedHoleSearchTerm searchTerm =
    any (searchTerm &)
    [SearchArea.allowedSearchTermCommon, isPositiveNumber, isNegativeNumber, isLiteralBytes]
    where
        isPositiveNumber t =
            case Text.splitOn "." t of
            [digits]             -> Text.all Char.isDigit digits
            [digits, moreDigits] -> Text.all Char.isDigit (digits <> moreDigits)
            _ -> False
        isLiteralBytes = prefixed '#' (Text.all Char.isHexDigit)
        isNegativeNumber = prefixed '-' isPositiveNumber
        prefixed char restPred t =
            case Text.uncons t of
            Just (c, rest) -> c == char && restPred rest
            _ -> False

make ::
    Monad m =>
    Sugar.Hole (T m) (Sugar.Expression (Name (T m)) (T m) ()) ->
    Sugar.Payload (T m) ExprGui.Payload ->
    ExprGuiM m (ExpressionGui m)
make hole pl =
    ExprEventMap.add options pl
    <*> ( SearchArea.make (hole ^. Sugar.holeOptions)
            (Just (hole ^. Sugar.holeOptionLiteral)) pl allowedHoleSearchTerm ?? Menu.AnyPlace
        )
    <&> Widget.widget . Widget.eventMapMaker . Lens.mapped %~ (<> txtEventMap)
    & GuiState.assignCursor (hidHole widgetIds) (hidOpen widgetIds)
    where
        txtEventMap = makeLiteralTextEventMap hole
        widgetIds = HoleWidgetIds.make (pl ^. Sugar.plEntityId)
        options =
            ExprEventMap.defaultOptions
            { ExprEventMap.addOperatorSetHoleState = Just (pl ^. Sugar.plEntityId)
            }

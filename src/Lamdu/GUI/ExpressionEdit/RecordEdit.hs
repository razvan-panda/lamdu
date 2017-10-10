{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, FlexibleContexts #-}
module Lamdu.GUI.ExpressionEdit.RecordEdit
    ( make
    ) where

import           Control.Applicative (liftA2)
import qualified Control.Lens as Lens
import           Data.Store.Transaction (Transaction)
import           Data.Vector.Vector2 (Vector2(..))
import           GUI.Momentu.Align (Aligned(Aligned))
import qualified GUI.Momentu.Align as Align
import           GUI.Momentu.Animation (AnimId)
import qualified GUI.Momentu.Animation as Anim
import qualified GUI.Momentu.Element as Element
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Glue ((/-/), (/|/))
import qualified GUI.Momentu.Responsive as Responsive
import           GUI.Momentu.View (View)
import qualified GUI.Momentu.View as View
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import           Lamdu.Config (Config)
import qualified Lamdu.Config as Config
import qualified Lamdu.Config.Theme as Theme
import           Lamdu.GUI.ExpressionEdit.Composite (destCursorId)
import qualified Lamdu.GUI.ExpressionEdit.TagEdit as TagEdit
import           Lamdu.GUI.ExpressionGui (ExpressionGui)
import qualified Lamdu.GUI.ExpressionGui as ExpressionGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import qualified Lamdu.GUI.ExpressionGui.Types as ExprGuiT
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name(..))
import qualified Lamdu.Sugar.Types as Sugar

import           Lamdu.Prelude

type T = Transaction

doc :: E.Subtitle -> E.Doc
doc text = E.Doc ["Edit", "Record", text]

mkAddFieldEventMap ::
    Functor f =>
    Config -> f Sugar.CompositeAddItemResult -> E.EventMap (f Widget.EventResult)
mkAddFieldEventMap config addField =
    addField
    <&> (^. Sugar.cairNewTag . Sugar.tagInstance)
    <&> WidgetIds.fromEntityId
    <&> TagEdit.tagHoleId
    & Widget.keysEventMapMovesCursor (Config.recordAddFieldKeys config)
      (doc "Add Field")

makeUnit ::
    Monad m =>
    Sugar.ClosedCompositeActions (T m) -> T m Sugar.CompositeAddItemResult ->
    Sugar.Payload (T m) ExprGuiT.Payload -> ExprGuiM m (ExpressionGui m)
makeUnit _actions addField pl =
    do
        config <- Lens.view Config.config
        makeFocusable <- Widget.makeFocusableView ?? myId <&> (Align.tValue %~)
        view <- liftA2 (/|/) (ExpressionGui.grammarLabel "{") (ExpressionGui.grammarLabel "}")
        makeFocusable view
            & Responsive.fromWithTextPos
            & E.weakerEvents (mkAddFieldEventMap config addField)
            & pure
    -- Don't add the closedRecordEventMap (_actions) - it only adds the open
    -- action which is equivalent ot deletion on the unit record
    & ExpressionGui.stdWrap pl
    where
        myId = WidgetIds.fromExprPayload pl

make ::
    Monad m =>
    Sugar.Composite (Name (T m)) (T m) (ExprGuiT.SugarExpr m) ->
    Sugar.Payload (T m) ExprGuiT.Payload ->
    ExprGuiM m (ExpressionGui m)
make (Sugar.Composite [] (Sugar.ClosedComposite actions) addField) pl =
    makeUnit actions addField pl
make (Sugar.Composite fields recordTail addField) pl =
    do
        config <- Lens.view Config.config
        let eventMap =
                case recordTail of
                Sugar.ClosedComposite actions ->
                    closedRecordEventMap config actions
                Sugar.OpenComposite actions restExpr ->
                    openRecordEventMap config actions restExpr
        let addFieldEventMap = mkAddFieldEventMap config addField
        makeRecord fields addFieldEventMap postProcess
            & ExpressionGui.stdWrapParentExpr pl defaultDestCursor
            <&> E.weakerEvents (eventMap <> addFieldEventMap)
    where
        defaultDestCursor = destCursorId fields (pl ^. Sugar.plEntityId)
        animId = WidgetIds.fromExprPayload pl & Widget.toAnimId
        postProcess =
            case recordTail of
            Sugar.OpenComposite actions restExpr ->
                makeOpenRecord actions restExpr animId
            _ -> pure

makeRecord ::
    Monad m =>
    [Sugar.CompositeItem (Name (T m)) (T m) (ExprGuiT.SugarExpr m)] ->
    E.EventMap (T m Widget.EventResult) ->
    (ExpressionGui m -> ExprGuiM m (ExpressionGui m)) ->
    ExprGuiM m (ExpressionGui m)
makeRecord fields addFieldEventMap postProcess =
    do
        (innerGui, resultPicker) <-
            Responsive.taggedList <*> mapM makeFieldRow fields
            >>= postProcess
            & ExprGuiM.listenResultPicker
        opener <- ExpressionGui.grammarLabel "{"
        closer <- ExpressionGui.grammarLabel "}" <&> (^. Align.tValue)
        let withCloser w = (Aligned 1 w /|/ Aligned 1 closer) ^. Align.value
        opener /|/ innerGui
            & Responsive.render . Lens.argument .
              Responsive.layoutMode . Responsive.modeWidths -~ closer ^. Element.size . _1
            & Responsive.render . Lens.mapped %~ withCloser
            & E.weakerEvents (ExprGuiM.withHolePicker resultPicker addFieldEventMap)
            & (ExpressionGui.addValFrame ??)

makeFieldRow ::
    Monad m =>
    Sugar.CompositeItem (Name (T m)) (T m) (ExprGuiT.SugarExpr m) ->
    ExprGuiM m (Responsive.TaggedItem (T m Widget.EventResult))
makeFieldRow (Sugar.CompositeItem delete tag fieldExpr) =
    do
        config <- Lens.view Config.config
        let itemEventMap = recordDelEventMap config delete
        tagLabel <-
            TagEdit.makeRecordTag TagEdit.WithTagHoles (ExprGuiT.nextHolesBefore fieldExpr) tag
            <&> Align.tValue %~ E.weakerEvents itemEventMap
        hspace <- Spacer.stdHSpace
        fieldGui <- ExprGuiM.makeSubexpression fieldExpr
        pure Responsive.TaggedItem
            { Responsive._tagPre = tagLabel /|/ hspace
            , Responsive._taggedItem = E.weakerEvents itemEventMap fieldGui
            }

separationBar :: Theme.CodeForegroundColors -> Widget.R -> Anim.AnimId -> View
separationBar theme width animId =
    View.unitSquare (animId <> ["tailsep"])
    & Element.tint (Theme.recordTailColor theme)
    & Element.scale (Vector2 width 10)

makeOpenRecord ::
    Monad m =>
    Sugar.OpenCompositeActions (T m) -> ExprGuiT.SugarExpr m ->
    AnimId -> ExpressionGui m -> ExprGuiM m (ExpressionGui m)
makeOpenRecord (Sugar.OpenCompositeActions close) rest animId fieldsGui =
    do
        theme <- Lens.view Theme.theme
        vspace <- Spacer.stdVSpace
        restExpr <- ExpressionGui.addValPadding <*> ExprGuiM.makeSubexpression rest
        config <- Lens.view Config.config
        let restEventMap =
                close <&> WidgetIds.fromEntityId
                & Widget.keysEventMapMovesCursor (Config.delKeys config) (doc "Close")
        let layout layoutMode fields =
                fields
                /-/
                separationBar (Theme.codeForegroundColors theme) (max minWidth targetWidth) animId
                /-/
                vspace
                /-/
                restW
                where
                    restW =
                        (restExpr ^. Responsive.render) layoutMode
                        <&> E.weakerEvents restEventMap
                    minWidth = restW ^. Element.width
                    targetWidth = fields ^. Element.width
        fieldsGui & Responsive.render . Lens.imapped %@~ layout & pure

openRecordEventMap ::
    Functor m =>
    Config -> Sugar.OpenCompositeActions (T m) ->
    Sugar.Expression name (T m) a ->
    Widget.EventMap (T m Widget.EventResult)
openRecordEventMap config (Sugar.OpenCompositeActions close) restExpr
    | isHole restExpr =
        close <&> WidgetIds.fromEntityId
        & Widget.keysEventMapMovesCursor (Config.recordCloseKeys config) (doc "Close")
    | otherwise = mempty
    where
        isHole = Lens.has (Sugar.rBody . Sugar._BodyHole)

closedRecordEventMap ::
    Functor m =>
    Config -> Sugar.ClosedCompositeActions (T m) ->
    Widget.EventMap (T m Widget.EventResult)
closedRecordEventMap config (Sugar.ClosedCompositeActions open) =
    open <&> WidgetIds.fromEntityId
    & Widget.keysEventMapMovesCursor (Config.recordOpenKeys config) (doc "Open")

recordDelEventMap ::
    Functor m =>
    Config -> m Sugar.EntityId -> Widget.EventMap (m Widget.EventResult)
recordDelEventMap config delete =
    delete <&> WidgetIds.fromEntityId
    & Widget.keysEventMapMovesCursor (Config.delKeys config) (doc "Delete Field")

{-# LANGUAGE NamedFieldPuns, DisambiguateRecordFields, MultiParamTypeClasses #-}
module Lamdu.GUI.CodeEdit
    ( make
    , HasEvalResults(..)
    , ReplEdit.ExportRepl(..), ExportActions(..), HasExportActions(..)
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.Transaction (MonadTransaction(..))
import           Data.CurAndPrev (CurAndPrev(..))
import           Data.Functor.Identity (Identity(..))
import           Data.Orphans () -- Imported for Monoid (IO ()) instance
import qualified Data.Property as Property
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Element as Element
import           GUI.Momentu.EventMap (EventMap)
import qualified GUI.Momentu.EventMap as E
import           GUI.Momentu.Responsive (Responsive)
import qualified GUI.Momentu.Responsive as Responsive
import qualified GUI.Momentu.State as GuiState
import           GUI.Momentu.Widget (Widget)
import qualified GUI.Momentu.Widget as Widget
import qualified GUI.Momentu.Widgets.Spacer as Spacer
import qualified Lamdu.Builtins.Anchors as Builtins
import qualified Lamdu.Calc.Type.Scheme as Scheme
import qualified Lamdu.Calc.Val as V
import           Lamdu.Config (config)
import qualified Lamdu.Config as Config
import qualified Lamdu.Config.Theme as Theme
import qualified Lamdu.Data.Anchors as Anchors
import           Lamdu.Data.Definition (Definition(..))
import qualified Lamdu.Data.Definition as Definition
import qualified Lamdu.Data.Ops as DataOps
import           Lamdu.Eval.Results (EvalResults)
import           Lamdu.Expr.IRef (ValI)
import qualified Lamdu.GUI.AnnotationsPass as AnnotationsPass
import qualified Lamdu.GUI.DefinitionEdit as DefinitionEdit
import qualified Lamdu.GUI.ExpressionEdit as ExpressionEdit
import qualified Lamdu.GUI.ExpressionGui as ExprGui
import           Lamdu.GUI.ExpressionGui.Monad (ExprGuiM)
import qualified Lamdu.GUI.ExpressionGui.Monad as ExprGuiM
import           Lamdu.GUI.IOTrans (IOTrans(..))
import qualified Lamdu.GUI.IOTrans as IOTrans
import qualified Lamdu.GUI.ReplEdit as ReplEdit
import qualified Lamdu.GUI.Styled as Styled
import qualified Lamdu.GUI.WidgetIds as WidgetIds
import           Lamdu.Name (Name)
import           Lamdu.Settings (HasSettings)
import           Lamdu.Style (HasStyle)
import qualified Lamdu.Sugar.Convert as SugarConvert
import qualified Lamdu.Sugar.Lens as SugarLens
import qualified Lamdu.Sugar.Names.Add as AddNames
import           Lamdu.Sugar.NearestHoles (NearestHoles)
import qualified Lamdu.Sugar.NearestHoles as NearestHoles
import qualified Lamdu.Sugar.Parens as AddParens
import qualified Lamdu.Sugar.Types as Sugar
import           Revision.Deltum.Transaction (Transaction)

import           Lamdu.Prelude

type T = Transaction

data ExportActions m = ExportActions
    { exportAll :: IOTrans m ()
    , exportReplActions :: ReplEdit.ExportRepl m
    , exportDef :: V.Var -> IOTrans m ()
    , importAll :: FilePath -> IOTrans m ()
    }

class HasEvalResults env m where
    evalResults :: Lens' env (CurAndPrev (EvalResults (ValI m)))

class HasExportActions env m where exportActions :: Lens' env (ExportActions m)

toExprGuiMPayload ::
    ( AddParens.MinOpPrec, AddParens.NeedsParens
    , ( ExprGui.ShowAnnotation
      , ([Sugar.EntityId], NearestHoles)
      )
    ) -> ExprGui.Payload
toExprGuiMPayload (minOpPrec, needParens, (showAnn, (entityIds, nearestHoles))) =
    ExprGui.Payload entityIds nearestHoles showAnn
    (needParens == AddParens.NeedsParens)
    minOpPrec

traverseAddNearestHoles ::
    Traversable t =>
    t (Sugar.Expression name m a) ->
    t (Sugar.Expression name m (a, NearestHoles))
traverseAddNearestHoles binder =
    binder
    <&> Lens.mapped %~ (,)
    & NearestHoles.add traverse

exprAddNearestHoles ::
    Sugar.Expression name m a ->
    Sugar.Expression name m (a, NearestHoles)
exprAddNearestHoles expr =
    Identity expr
    & traverseAddNearestHoles
    & runIdentity

postProcessExpr ::
    Sugar.Expression (Name n) m ([Sugar.EntityId], NearestHoles) ->
    Sugar.Expression (Name n) m ExprGui.Payload
postProcessExpr =
    fmap toExprGuiMPayload . AddParens.add . AnnotationsPass.markAnnotationsToDisplay

loadWorkArea ::
    Monad m =>
    CurAndPrev (EvalResults (ValI m)) ->
    Anchors.CodeAnchors m ->
    T m (Sugar.WorkArea (Name (T m)) (T m) ExprGui.Payload)
loadWorkArea theEvalResults cp =
    SugarConvert.loadWorkArea theEvalResults cp
    >>= AddNames.addToWorkArea (Anchors.tags cp)
    <&>
    \Sugar.WorkArea { _waPanes, _waRepl } ->
    Sugar.WorkArea
    { _waPanes = _waPanes <&> Sugar.paneDefinition %~ traverseAddNearestHoles
    , _waRepl = _waRepl & exprAddNearestHoles
    }
    & SugarLens.workAreaExpressions %~ postProcessExpr

make ::
    ( MonadTransaction m n, MonadReader env n, Config.HasConfig env
    , Theme.HasTheme env, GuiState.HasState env
    , Spacer.HasStdSpacing env, HasEvalResults env m, HasExportActions env m
    , HasSettings env, HasStyle env
    ) =>
    Anchors.CodeAnchors m -> Anchors.GuiAnchors (T m) -> Widget.R ->
    n (Widget (IOTrans m GuiState.Update))
make cp gp width =
    do
        theEvalResults <- Lens.view evalResults
        theExportActions <- Lens.view exportActions
        workArea <- loadWorkArea theEvalResults cp & transaction
        do
            replGui <-
                ReplEdit.make (exportReplActions theExportActions)
                (workArea ^. Sugar.waRepl)
            panesEdits <-
                workArea ^. Sugar.waPanes
                & traverse (makePaneEdit theExportActions)
            newDefinitionButton <- makeNewDefinitionButton cp <&> fmap IOTrans.liftTrans <&> Responsive.fromWidget
            eventMap <-
                panesEventMap theExportActions cp gp
                (workArea ^. Sugar.waRepl . Sugar.rPayload . Sugar.plAnnotation . Sugar.aInferredType)
            Responsive.vboxSpaced
                ?? (replGui : panesEdits ++ [newDefinitionButton])
                <&> Widget.widget . Widget.eventMapMaker . Lens.mapped %~ (<> eventMap)
            & ExprGuiM.run ExpressionEdit.make gp
            <&> render
            <&> (^. Align.tValue)
    where
        render gui =
            Responsive.LayoutParams
            { _layoutMode = Responsive.LayoutNarrow width
            , _layoutContext = Responsive.LayoutClear
            } & gui ^. Responsive.render

makePaneEdit ::
    Monad m =>
    ExportActions m ->
    Sugar.Pane (Name (T m)) (T m) ExprGui.Payload ->
    ExprGuiM m (Responsive (IOTrans m GuiState.Update))
makePaneEdit theExportActions pane =
    do
        theConfig <- Lens.view config
        let paneEventMap =
                [ pane ^. Sugar.paneClose & IOTrans.liftTrans
                  <&> WidgetIds.fromEntityId
                  & E.keysEventMapMovesCursor (paneConfig ^. Config.paneCloseKeys)
                    (E.Doc ["View", "Pane", "Close"])
                , pane ^. Sugar.paneMoveDown <&> IOTrans.liftTrans
                  & foldMap
                    (E.keysEventMap (paneConfig ^. Config.paneMoveDownKeys)
                    (E.Doc ["View", "Pane", "Move down"]))
                , pane ^. Sugar.paneMoveUp <&> IOTrans.liftTrans
                  & foldMap
                    (E.keysEventMap (paneConfig ^. Config.paneMoveUpKeys)
                    (E.Doc ["View", "Pane", "Move up"]))
                , exportDef theExportActions (pane ^. Sugar.paneDefinition . Sugar.drDefI)
                  & E.keysEventMap exportKeys
                    (E.Doc ["Collaboration", "Export definition to JSON file"])
                ] & mconcat
            lhsEventMap =
                do
                    Property.setP
                        (pane ^. Sugar.paneDefinition . Sugar.drDefinitionState & Property.MkProperty)
                        Sugar.DeletedDefinition
                    pane ^. Sugar.paneClose
                <&> WidgetIds.fromEntityId
                & E.keysEventMapMovesCursor (Config.delKeys theConfig)
                    (E.Doc ["Edit", "Definition", "Delete"])
            paneConfig = theConfig ^. Config.pane
            exportKeys = theConfig ^. Config.export . Config.exportKeys
        DefinitionEdit.make lhsEventMap (pane ^. Sugar.paneDefinition)
            <&> Lens.mapped %~ IOTrans.liftTrans
            <&> Widget.weakerEvents paneEventMap

makeNewDefinition :: Monad m => Anchors.CodeAnchors m -> ExprGuiM m (T m Widget.Id)
makeNewDefinition cp =
    ExprGuiM.mkPrejumpPosSaver <&>
    \savePrecursor ->
    do
        savePrecursor
        holeI <- DataOps.newHole
        Definition
            (Definition.BodyExpr (Definition.Expr holeI mempty))
            Scheme.any ()
            & DataOps.newPublicDefinitionWithPane cp
    <&> WidgetIds.newDest . WidgetIds.fromIRef

newDefinitionDoc :: E.Doc
newDefinitionDoc = E.Doc ["Edit", "New definition"]

makeNewDefinitionButton ::
    Monad m => Anchors.CodeAnchors m -> ExprGuiM m (Widget (T m GuiState.Update))
makeNewDefinitionButton cp =
    do
        newDefId <- Element.subAnimId ["New definition"] <&> Widget.Id
        makeNewDefinition cp
            >>= Styled.actionable newDefId "New..." newDefinitionDoc
            <&> (^. Align.tValue)

jumpBack :: Monad m => Anchors.GuiAnchors (T m) -> T m (Maybe (T m Widget.Id))
jumpBack gp =
    Property.getP (Anchors.preJumps gp)
    <&> \case
    [] -> Nothing
    (j:js) -> j <$ Property.setP (Anchors.preJumps gp) js & Just

panesEventMap ::
    Monad m =>
    ExportActions m -> Anchors.CodeAnchors m -> Anchors.GuiAnchors (T m) ->
    Sugar.Type name -> ExprGuiM m (EventMap (IOTrans m GuiState.Update))
panesEventMap theExportActions cp gp replType =
    do
        theConfig <- Lens.view config
        let exportConfig = theConfig ^. Config.export
        mJumpBack <- jumpBack gp & transaction <&> fmap IOTrans.liftTrans
        newDefinitionEventMap <-
            makeNewDefinition cp
            <&> E.keysEventMapMovesCursor
            (theConfig ^. Config.pane . Config.newDefinitionKeys) newDefinitionDoc
        pure $ mconcat
            [ newDefinitionEventMap <&> IOTrans.liftTrans
            , E.dropEventMap "Drag&drop JSON files"
              (E.Doc ["Collaboration", "Import JSON file"]) (Just . traverse_ importAll)
              <&> fmap (\() -> mempty)
            , foldMap
              (E.keysEventMapMovesCursor (theConfig ^. Config.previousCursorKeys)
               (E.Doc ["Navigation", "Go back"])) mJumpBack
            , E.keysEventMap (exportConfig ^. Config.exportAllKeys)
              (E.Doc ["Collaboration", "Export everything to JSON file"]) exportAll
            , importAll (exportConfig ^. Config.exportPath)
              & E.keysEventMap (exportConfig ^. Config.importKeys)
                (E.Doc ["Collaboration", "Import repl from JSON file"])
            , case replType ^. Sugar.tBody of
                Sugar.TInst tid _
                    | tid ^. Sugar.tidTId == Builtins.mutTid ->
                        E.keysEventMap (exportConfig ^. Config.executeKeys)
                        (E.Doc ["Execute Repl Process"])
                        (IOTrans.liftIO executeRepl)
                _ -> mempty
            ]
    where
        executeRepl = exportReplActions theExportActions & ReplEdit.executeIOProcess
        ExportActions{importAll,exportAll} = theExportActions

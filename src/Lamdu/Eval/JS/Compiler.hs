{-# LANGUAGE GeneralizedNewtypeDeriving, TemplateHaskell, QuasiQuotes, PolymorphicComponents #-}
-- | Compile Lamdu vals to Javascript

module Lamdu.Eval.JS.Compiler
    ( Actions(..)
    , ValId(..)
    , compile, Mode(..), loggingEnabled
    ) where

import qualified Control.Lens as Lens
import           Control.Monad.Trans.FastRWS (RWST, runRWST)
import qualified Control.Monad.Trans.FastRWS as RWS
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Hex
import qualified Data.Char as Char
import           Data.Default () -- instances
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import           Data.Text.Encoding (decodeUtf8)
import           Data.UUID.Types (UUID)
import qualified Data.UUID.Utils as UUIDUtils
import qualified Lamdu.Builtins.Anchors as Builtins
import qualified Lamdu.Builtins.PrimVal as PrimVal
import           Lamdu.Calc.Identifier (identHex)
import qualified Lamdu.Calc.Type as T
import           Lamdu.Calc.Type.Scheme (Scheme)
import qualified Lamdu.Calc.Type.Scheme as Scheme
import qualified Lamdu.Calc.Val as V
import           Lamdu.Calc.Val.Annotated (Val(..))
import qualified Lamdu.Calc.Val.Annotated as Val
import qualified Lamdu.Compiler.Flatten as Flatten
import           Lamdu.Data.Anchors (anonTag)
import qualified Lamdu.Data.Definition as Definition
import qualified Lamdu.Expr.Lens as ExprLens
import qualified Lamdu.Expr.UniqueId as UniqueId
import qualified Lamdu.Infer as Infer
import qualified Language.ECMAScript3.PrettyPrint as JSPP
import qualified Language.ECMAScript3.Syntax as JSS
import qualified Language.ECMAScript3.Syntax.CodeGen as JS
import           Language.ECMAScript3.Syntax.QuasiQuote (jsstmt)
import           Numeric.Lens (hex)
import qualified Text.PrettyPrint.Leijen as Pretty

import           Lamdu.Prelude

newtype ValId = ValId UUID

data Mode = FastSilent | SlowLogging LoggingInfo
    deriving Show

data Actions m = Actions
    { readAssocName :: T.Tag -> m Text
    , readAssocTag :: UUID -> m T.Tag
    , readGlobal :: V.Var -> m (Definition.Definition (Val ValId) ())
    , readGlobalType :: V.Var -> m Scheme
    , output :: String -> m ()
    , loggingMode :: Mode
    }

type LocalVarName = JSS.Id ()
type GlobalVarName = JSS.Id ()

newtype LoggingInfo = LoggingInfo
    { _liScopeDepth :: Int
    } deriving Show
Lens.makeLenses ''LoggingInfo

data Env m = Env
    { _envActions :: Actions m
    , _envLocals :: Map V.Var LocalVarName
    , _envMode :: Mode
    , _envExpectedTypes :: Map V.Var Scheme
    }
Lens.makeLenses ''Env

data State = State
    { _freshId :: Int
    , _names :: Map Text (Map UUID Text)
    , _globalVarNames :: Map V.Var GlobalVarName
    , _globalTypes :: Map V.Var Scheme
    }
Lens.makeLenses ''State

data LogUsed
    = LogUnused
    | LogUsed
    deriving (Eq, Ord, Show)
instance Semigroup LogUsed where
    LogUsed <> _ = LogUsed
    _ <> LogUsed = LogUsed
    _ <> _ = LogUnused
instance Monoid LogUsed where
    mempty = LogUnused
    mappend = (<>)

newtype M m a = M { unM :: RWST (Env m) LogUsed State m a }
    deriving (Functor, Applicative, Monad)

infixl 4 $.
($.) :: JSS.Expression () -> JSS.Id () -> JSS.Expression ()
($.) = JS.dot

infixl 3 $$
($$) :: JSS.Expression () -> JSS.Expression () -> JSS.Expression ()
f $$ x = f `JS.call` [x]

pp :: JSS.Statement () -> String
pp = (`Pretty.displayS`"") . Pretty.renderPretty 1.0 90 . JSPP.prettyPrint

performAction :: Monad m => (Actions m -> m a) -> M m a
performAction f = RWS.asks (f . _envActions) >>= lift & M

ppOut :: Monad m => JSS.Statement () -> M m ()
ppOut stmt = performAction (`output` pp stmt)

-- Multiple vars using a single "var" is badly formatted and generally
-- less readable than a vardecl for each:
varinit :: JSS.Id () -> JSS.Expression () -> JSS.Statement ()
varinit ident expr = JS.vardecls [JS.varinit ident expr]

scopeIdent :: Int -> JSS.Id ()
scopeIdent depth = "scopeId_" ++ show depth & JS.ident

declLog :: Int -> JSS.Statement ()
declLog depth =
    varinit "log" $
    JS.lambda ["exprId", "result"]
    [ (JS.var "rts" $. "logResult") `JS.call`
      [ JS.var (scopeIdent depth)
      , JS.var "exprId"
      , JS.var "result"
      ] & JS.returns
    ]

-- | Taken from http://www.ecma-international.org/ecma-262/6.0/#sec-keywords
jsReservedKeywords :: Set Text
jsReservedKeywords =
    Set.fromList
    [ "break"    , "do"        , "in"        , "typeof"
    , "case"     , "else"      , "instanceof", "var"
    , "catch"    , "export"    , "new"       , "void"
    , "class"    , "extends"   , "return"    , "while"
    , "const"    , "finally"   , "super"     , "with"
    , "continue" , "for"       , "switch"    , "yield"
    , "debugger" , "function"  , "this"      , "default"
    , "if"       , "throw"     , "delete"    , "import"
    , "try"      , "let"       , "static"    , "enum"
    , "await"    , "implements", "package"   , "protected"
    , "interface", "private"   , "public"
    ]

jsReservedNamespace :: Set Text
jsReservedNamespace =
    Set.fromList
    [ "x", "repl"
    , "Object", "console", "repl"
    , "log", "scopeCounter", "rts"
    , "tag", "data", "array", "bytes", "func", "cacheId", "number"
    ]

jsAllReserved :: Set Text
jsAllReserved = jsReservedNamespace `mappend` jsReservedKeywords

isReservedName :: Text -> Bool
isReservedName name =
    name `Set.member` jsAllReserved
    || any (`Text.isPrefixOf` name)
    [ "global_"
    , "local_"
    , "scopeId_"
    ]

topLevelDecls :: Mode -> [JSS.Statement ()]
topLevelDecls mode =
    ( [ [jsstmt|"use strict";|]
      , [jsstmt|var rts = require('./rts.js');|]
      ] <&> void
    ) ++
    case mode of
    FastSilent -> []
    SlowLogging{} ->
        ( [ [jsstmt|var scopeId_0 = 0;|]
          , [jsstmt|var scopeCounter = 1;|]
          ] <&> void
        ) ++
        [ declLog 0
        ]

loggingEnabled :: Mode
loggingEnabled = SlowLogging LoggingInfo { _liScopeDepth = 0 }

compile :: Monad m => Actions m -> Definition.Expr (Val ValId) -> m ()
compile actions defExpr = compileDefExpr defExpr & run actions

run :: Monad m => Actions m -> M m CodeGen -> m ()
run actions act =
    runRWST
    (do
        traverse_ ppOut (topLevelDecls (loggingMode actions))
        act <&> codeGenExpression <&> varinit "repl" >>= ppOut
        [ [jsstmt|rts.logRepl(repl);|]
          , -- This form avoids outputing repl's value in interactive mode
            [jsstmt|(function() { module.exports = repl; })();|]
            ] <&> void & traverse_ ppOut
    & unM
    )
    Env
    { _envActions = actions
    , _envLocals = mempty
    , _envMode = loggingMode actions
    , _envExpectedTypes = mempty
    }
    State
    { _freshId = 0
    , _names = mempty
    , _globalVarNames = mempty
    , _globalTypes = mempty
    }
    <&> (^. _1)

-- | Reset reader/writer components of RWS for a new global compilation context
resetRW :: Monad m => M m a -> M m a
resetRW (M act) =
    act
    & RWS.censor (const LogUnused)
    & RWS.local (envLocals .~ mempty)
    & RWS.local (\x -> x & envMode .~ loggingMode (x ^. envActions))
    & M

freshName :: Monad m => Text -> M m Text
freshName prefix =
    freshId <+= 1
    <&> show
    <&> Text.pack
    <&> (prefix <>)
    & M

avoidReservedNames :: Text -> Text
avoidReservedNames name
    | isReservedName name = "_" <> name
    | otherwise = name

escapeName :: Text -> Text
escapeName name =
    case Text.unpack name of
    (d:xs) | Char.isDigit d -> '_' : d : replaceSpecialChars xs
    xs -> replaceSpecialChars xs
    & Text.pack

replaceSpecialChars :: String -> String
replaceSpecialChars = concatMap replaceSpecial
    where
        replaceSpecial x
            | Char.isAlphaNum x = [x]
            | x == '_' = "__"
            | otherwise = '_' : ((hex #) . Char.ord) x ++ "_"

readName :: (UniqueId.ToUUID a, Monad m) => a -> M m Text -> M m Text
readName g act =
    do
        tag <- performAction (`readAssocTag` uuid)
        (if tag == anonTag then act else readTagName tag act)
            >>= generatedName uuid
    where
        uuid = UniqueId.toUUID g

generatedName :: Monad m => UUID -> Text -> M m Text
generatedName uuid name =
    names . Lens.at name %%=
    \case
    Nothing -> (name, Just (Map.singleton uuid name))
    Just uuidMap ->
        uuidMap
        & Lens.at uuid %%~
        \case
        Nothing -> (newName, Just newName)
            where
                newName = name <> Text.pack (show (Map.size uuidMap))
        Just oldName -> (oldName, Just oldName)
        <&> Just
    & M

readTagName :: Monad m => T.Tag -> M m Text -> M m Text
readTagName tag act =
    performAction (`readAssocName` tag)
    <&> avoidReservedNames
    <&> escapeName
    >>=
    \case
    "" -> act
    name -> pure name

freshStoredName :: (Monad m, UniqueId.ToUUID a) => a -> Text -> M m Text
freshStoredName g prefix = readName g (freshName prefix)

tagString :: Monad m => T.Tag -> M m Text
tagString tag@(T.Tag ident) =
    "tag" ++ identHex ident & Text.pack & pure
    & readTagName tag
    >>= generatedName (UniqueId.toUUID tag)

tagIdent :: Monad m => T.Tag -> M m (JSS.Id ())
tagIdent = fmap (JS.ident . Text.unpack) . tagString

local :: (Env m -> Env m) -> M m a -> M m a
local f (M act) = M (RWS.local f act)

withLocalVar :: Monad m => V.Var -> M m a -> M m (LocalVarName, a)
withLocalVar v act =
    do
        varName <- freshStoredName v "local_" <&> Text.unpack <&> JS.ident
        res <- local (envLocals . Lens.at v ?~ varName) act
        pure (varName, res)

compileDefExpr :: Monad m => Definition.Expr (Val ValId) -> M m CodeGen
compileDefExpr (Definition.Expr val frozenDeps) =
    compileVal val & local (envExpectedTypes .~ frozenDeps ^. Infer.depsGlobalTypes)

compileGlobal :: Monad m => V.Var -> M m (JSS.Expression ())
compileGlobal globalId =
    do
        def <- performAction (`readGlobal` globalId)
        globalTypes . Lens.at globalId ?= def ^. Definition.defType & M
        case def ^. Definition.defBody of
            Definition.BodyBuiltin ffiName -> ffiCompile ffiName & pure
            Definition.BodyExpr defExpr -> compileDefExpr defExpr <&> codeGenExpression
    & resetRW

compileGlobalVar :: Monad m => V.Var -> M m CodeGen
compileGlobalVar var =
    Lens.view (envExpectedTypes . Lens.at var) & M
    >>= maybe loadGlobal verifyType
    where
        loadGlobal =
            Lens.use (globalVarNames . Lens.at var) & M
            >>= maybe newGlobal pure
            <&> JS.var
            <&> codeGenFromExpr
        newGlobal =
            do
                varName <- freshStoredName var "global_" <&> Text.unpack <&> JS.ident
                globalVarNames . Lens.at var ?= varName & M
                compileGlobal var
                    <&> varinit varName
                    >>= ppOut
                pure varName
        verifyType expectedType =
            do
                scheme <-
                    Lens.use (globalTypes . Lens.at var) & M
                    >>= maybe newGlobalType pure
                if Scheme.alphaEq scheme expectedType
                    then loadGlobal
                    else
                        readName var (pure "unnamed")
                        <&> ("Reached broken def: " <>) <&> throwStr
        newGlobalType =
            do
                scheme <- performAction (`readGlobalType` var)
                globalTypes . Lens.at var ?= scheme & M
                pure scheme

compileLocalVar :: JSS.Id () -> CodeGen
compileLocalVar = codeGenFromExpr . JS.var

compileVar :: Monad m => V.Var -> M m CodeGen
compileVar v =
    Lens.view (envLocals . Lens.at v) & M
    >>= maybe (compileGlobalVar v) (pure . compileLocalVar)

data CodeGen = CodeGen
    { codeGenLamStmts :: [JSS.Statement ()]
    , codeGenExpression :: JSS.Expression ()
    }

unitRedex :: [JSS.Statement ()] -> JSS.Expression ()
unitRedex stmts = JS.lambda [] stmts `JS.call` []

throwStr :: Text -> CodeGen
throwStr str = codeGenFromLamStmts [JS.throw (JS.string (Text.unpack str))]

codeGenFromLamStmts :: [JSS.Statement ()] -> CodeGen
codeGenFromLamStmts stmts =
    CodeGen
    { codeGenLamStmts = stmts
    , codeGenExpression = unitRedex stmts
    }

codeGenFromExpr :: JSS.Expression () -> CodeGen
codeGenFromExpr expr =
    CodeGen
    { codeGenLamStmts = [JS.returns expr]
    , codeGenExpression = expr
    }

lam ::
    Monad m => Text ->
    (JSS.Expression () -> M m [JSS.Statement ()]) ->
    M m (JSS.Expression ())
lam prefix code =
    do
        var <- freshName prefix <&> Text.unpack <&> JS.ident
        code (JS.var var) <&> JS.lambda [var]

inject :: JSS.Expression () -> JSS.Expression () -> JSS.Expression ()
inject tagStr dat' =
    JS.object
    [ (JS.propId "tag", tagStr)
    , (JS.propId "data", dat')
    ]

ffiCompile :: Definition.FFIName -> JSS.Expression ()
ffiCompile (Definition.FFIName modul funcName) =
    foldl ($.) (JS.var "rts" $. "builtins") (modul <&> Text.unpack <&> JS.ident)
    `JS.brack` JS.string (Text.unpack funcName)

compileLiteral :: V.PrimVal -> CodeGen
compileLiteral literal =
    case PrimVal.toKnown literal of
    PrimVal.Bytes bytes ->
        JS.var "rts" $. "bytes" $$ JS.array ints & codeGenFromExpr
        where
            ints = [JS.int (fromIntegral byte) | byte <- BS.unpack bytes]
    PrimVal.Float num -> JS.number num & codeGenFromExpr

compileRecExtend :: Monad m => V.RecExtend (Val ValId) -> M m CodeGen
compileRecExtend x =
    do
        Flatten.Composite tags mRest <- Flatten.recExtend x & Lens.traverse compileVal
        extends <-
            Map.toList tags
            <&> _2 %~ codeGenExpression
            & Lens.traversed . _1 %%~ tagString
            <&> Lens.mapped . _1 %~ JS.propId . JS.ident . Text.unpack
            <&> JS.object
        case mRest of
            Nothing -> codeGenFromExpr extends
            Just rest ->
                codeGenFromLamStmts
                [ varinit "x"
                    ((JS.var "Object" $. "assign") `JS.call` [extends, codeGenExpression rest])
                , JS.expr (JS.delete (JS.var "x" $. "cacheId"))
                , JS.returns (JS.var "x")
                ]
            & pure

compileInject :: Monad m => V.Inject (Val ValId) -> M m CodeGen
compileInject (V.Inject tag dat) =
    do
        tagStr <- tagString tag <&> Text.unpack <&> JS.string
        dat' <- compileVal dat
        inject tagStr (codeGenExpression dat') & codeGenFromExpr & pure

compileCase :: Monad m => V.Case (Val ValId) -> M m CodeGen
compileCase = fmap codeGenFromExpr . lam "x" . compileCaseOnVar

compileCaseOnVar ::
    Monad m => V.Case (Val ValId) -> JSS.Expression () -> M m [JSS.Statement ()]
compileCaseOnVar x scrutineeVar =
    do
        tagsStr <- Map.toList tags & Lens.traverse . _1 %%~ tagString
        cases <- traverse makeCase tagsStr
        defaultCase <-
            case mRestHandler of
            Nothing ->
                pure [JS.throw (JS.string "Unhandled case? This is a type error!")]
            Just restHandler ->
                compileAppliedFunc restHandler scrutineeVar
                <&> codeGenLamStmts
            <&> JS.defaultc
        pure [JS.switch (scrutineeVar $. "tag") (cases ++ [defaultCase])]
    where
        Flatten.Composite tags mRestHandler = Flatten.case_ x
        makeCase (tagStr, handler) =
            compileAppliedFunc handler (scrutineeVar $. "data")
            <&> codeGenLamStmts
            <&> JS.casee (JS.string (Text.unpack tagStr))

compileGetField :: Monad m => V.GetField (Val ValId) -> M m CodeGen
compileGetField (V.GetField record tag) =
    do
        tagId <- tagIdent tag
        compileVal record
            <&> codeGenExpression <&> (`JS.dot` tagId)
            <&> codeGenFromExpr

declMyScopeDepth :: Int -> JSS.Statement ()
declMyScopeDepth depth =
    varinit (scopeIdent depth) $
    JS.uassign JSS.PostfixInc "scopeCounter"

jsValId :: ValId -> JSS.Expression ()
jsValId (ValId uuid) = (JS.string . Text.unpack . decodeUtf8 . Hex.encode . UUIDUtils.toSBS16) uuid

callLogNewScope :: Int -> Int -> ValId -> JSS.Expression () -> JSS.Statement ()
callLogNewScope parentDepth myDepth lamValId argVal =
    (JS.var "rts" $. "logNewScope") `JS.call`
    [ JS.var (scopeIdent parentDepth)
    , JS.var (scopeIdent myDepth)
    , jsValId lamValId
    , argVal
    ] & JS.expr

slowLoggingLambdaPrefix ::
    LogUsed -> Int -> ValId -> JSS.Expression () -> [JSS.Statement ()]
slowLoggingLambdaPrefix logUsed parentScopeDepth lamValId argVal =
    [ declMyScopeDepth myScopeDepth
    , callLogNewScope parentScopeDepth myScopeDepth lamValId argVal
    ] ++
    [ declLog myScopeDepth | LogUsed <- [logUsed] ]
    where
        myScopeDepth = parentScopeDepth + 1

listenNoTellLogUsed :: Monad m => M m a -> M m (a, LogUsed)
listenNoTellLogUsed act =
    act & unM & RWS.listen & RWS.censor (const LogUnused) & M

compileLambda :: Monad m => V.Lam (Val ValId) -> ValId -> M m CodeGen
compileLambda (V.Lam v res) valId =
    Lens.view envMode & M
    >>= \case
        FastSilent -> compileRes <&> mkLambda
        SlowLogging loggingInfo ->
            do
                ((varName, lamStmts), logUsed) <-
                    compileRes
                    & local
                      (envMode .~ SlowLogging (loggingInfo & liScopeDepth .~ 1 + parentScopeDepth))
                    & listenNoTellLogUsed
                let stmts =
                        slowLoggingLambdaPrefix logUsed parentScopeDepth valId
                        (JS.var varName)
                fastLam <- compileRes & local (envMode .~ FastSilent) <&> mkLambda
                (JS.var "rts" $. "wrap") `JS.call`
                    [fastLam, JS.lambda [varName] (stmts ++ lamStmts)] & pure
            where
                parentScopeDepth = loggingInfo ^. liScopeDepth
    <&> codeGenFromExpr
    where
        mkLambda (varId, lamStmts) = JS.lambda [varId] lamStmts
        compileRes = compileVal res <&> codeGenLamStmts & withLocalVar v

compileApply :: Monad m => V.Apply (Val ValId) -> M m CodeGen
compileApply (V.Apply func arg) =
    do
        arg' <- compileVal arg <&> codeGenExpression
        compileAppliedFunc func arg'

maybeLogSubexprResult :: Monad m => ValId -> CodeGen -> M m CodeGen
maybeLogSubexprResult valId codeGen =
    Lens.view envMode & M
    >>= \case
    FastSilent -> pure codeGen
    SlowLogging _ -> logSubexprResult valId codeGen

logSubexprResult :: Monad m => ValId -> CodeGen -> M m CodeGen
logSubexprResult valId codeGen =
    codeGenFromExpr
    (JS.var "log" `JS.call` [jsValId valId, codeGenExpression codeGen])
    <$ RWS.tell LogUsed
    & M

compileAppliedFunc :: Monad m => Val ValId -> JSS.Expression () -> M m CodeGen
compileAppliedFunc func arg' =
    do
        mode <- Lens.view envMode & M
        case (func ^. Val.body, mode) of
            (V.BCase case_, FastSilent) ->
                compileCaseOnVar case_ (JS.var "x")
                <&> (varinit "x" arg' :)
                <&> codeGenFromLamStmts
            (V.BLam (V.Lam v res), FastSilent) ->
                compileVal res <&> codeGenLamStmts & withLocalVar v
                <&> \(vId, lamStmts) ->
                CodeGen
                { codeGenLamStmts = varinit vId arg' : lamStmts
                , codeGenExpression =
                    -- Can't really optimize a redex in expr
                    -- context, as at least 1 redex must be paid
                    JS.lambda [vId] lamStmts $$ arg'
                }
            _ ->
                compileVal func
                <&> codeGenExpression
                <&> ($$ arg')
                <&> codeGenFromExpr

compileLeaf :: Monad m => V.Leaf -> ValId -> M m CodeGen
compileLeaf leaf valId =
    case leaf of
    V.LHole -> throwStr "Reached hole!" & pure
    V.LRecEmpty -> JS.object [] & codeGenFromExpr & pure
    V.LAbsurd -> throwStr "Reached absurd!" & pure
    V.LVar var -> compileVar var >>= maybeLogSubexprResult valId
    V.LLiteral literal -> compileLiteral literal & pure

compileToNom :: Monad m => V.Nom (Val ValId) -> ValId -> M m CodeGen
compileToNom (V.Nom tId val) valId =
    case val ^? ExprLens.valLiteral <&> PrimVal.toKnown of
    Just (PrimVal.Bytes bytes)
        | tId == Builtins.textTid
        && all (< 128) (BS.unpack bytes) ->
            -- The JS is more readable with string constants
            JS.var "rts" $. "bytesFromAscii" $$ JS.string (Text.unpack (decodeUtf8 bytes))
            & codeGenFromExpr & pure
    _ -> compileVal val >>= maybeLogSubexprResult valId

compileVal :: Monad m => Val ValId -> M m CodeGen
compileVal (Val valId body) =
    case body of
    V.BLeaf leaf                -> compileLeaf leaf valId
    V.BApp x                    -> compileApply x    >>= maybeLog
    V.BGetField x               -> compileGetField x >>= maybeLog
    V.BLam x                    -> compileLambda x valId
    V.BInject x                 -> compileInject x   >>= maybeLog
    V.BRecExtend x              -> compileRecExtend x
    V.BCase x                   -> compileCase x
    V.BFromNom (V.Nom _tId val) -> compileVal val    >>= maybeLog
    V.BToNom x                  -> compileToNom x valId
    where
        maybeLog = maybeLogSubexprResult valId

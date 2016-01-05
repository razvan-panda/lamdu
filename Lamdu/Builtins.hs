{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
module Lamdu.Builtins
    ( eval
    ) where

import           Control.Lens.Operators
import           Control.Monad (join, void, when)
import           Data.Binary.Utils (encodeS, decodeS)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Map.Utils (matchKeys)
import qualified Lamdu.Builtins.Anchors as Builtins
import qualified Lamdu.Data.Definition as Def
import           Lamdu.Eval.Val (EvalResult, Val(..), EvalError(..))
import           Lamdu.Expr.Type (Tag)
import qualified Lamdu.Expr.Type as T
import qualified Lamdu.Expr.Val as V

import           Prelude.Compat

flatRecord :: EvalResult srcId -> Either EvalError (Map Tag (EvalResult srcId))
flatRecord (Left err) = Left err
flatRecord (Right HRecEmpty) = Right Map.empty
flatRecord (Right (HRecExtend (V.RecExtend t v rest))) =
    flatRecord rest <&> Map.insert t v
flatRecord _ = "Param record is not a record" & EvalTypeError & Left

extractRecordParams ::
    (Traversable t, Show (t Tag)) =>
    t Tag -> EvalResult srcId -> Either EvalError (t (EvalResult srcId))
extractRecordParams expectedTags val =
    do
        paramsMap <- flatRecord val
        case matchKeys expectedTags paramsMap of
            Nothing ->
                "Builtin expected params: " ++ show expectedTags ++ " got: " ++
                show (void val) & EvalTypeError & Left
            Just x -> Right x

data V2 a = V2 a a   deriving (Show, Functor, Foldable, Traversable)
data V3 a = V3 a a a deriving (Show, Functor, Foldable, Traversable)

extractInfixParams :: EvalResult srcId -> Either EvalError (V2 (EvalResult srcId))
extractInfixParams =
        extractRecordParams (V2 Builtins.infixlTag Builtins.infixrTag)

class GuestType t where
    toGuestVal :: t -> Val srcId
    fromGuestVal :: Val srcId -> Either EvalError t

toGuest :: GuestType t => t -> EvalResult srcId
toGuest = Right . toGuestVal

fromGuest :: GuestType t => EvalResult srcId -> Either EvalError t
fromGuest = (>>= fromGuestVal)

instance GuestType Double where
    toGuestVal = HLiteral . V.Literal Builtins.floatId . encodeS
    fromGuestVal (HLiteral (V.Literal primId x))
        | primId == Builtins.floatId = Right (decodeS x)
    fromGuestVal x = "expected num, got " ++ show (void x) & EvalTypeError & Left

instance GuestType Bool where
    toGuestVal b =
        record [] & V.Inject (tag b) & HInject
        where
            tag True = Builtins.trueTag
            tag False = Builtins.falseTag
    fromGuestVal v =
        case v of
        HInject (V.Inject boolTag _)
            | boolTag == Builtins.trueTag -> Right True
            | boolTag == Builtins.falseTag -> Right False
        _ -> "Expected bool, got: " ++ show (void v) & EvalTypeError & Left

record :: [(T.Tag, EvalResult srcId)] -> EvalResult srcId
record [] = Right HRecEmpty
record ((tag, val) : xs) =
    record xs & V.RecExtend tag val & HRecExtend & Right

builtin1 :: (GuestType a, GuestType b) => (a -> b) -> EvalResult srcId -> EvalResult srcId
builtin1 f val = fromGuest val <&> f >>= toGuest

builtin2Infix ::
    ( GuestType a
    , GuestType b
    , GuestType c ) =>
    (a -> b -> c) -> EvalResult srcId -> EvalResult srcId
builtin2Infix f thunkId =
    do
        V2 x y <- extractInfixParams thunkId
        f <$> fromGuest x <*> fromGuest y >>= toGuest

eq :: EvalResult t -> EvalResult t -> Either EvalError Bool
eq x y = eqVal <$> x <*> y & join

eqVal :: Val t -> Val t -> Either EvalError Bool
eqVal HFunc {} _    = EvalTodoError "Eq of func" & Left
eqVal HAbsurd {} _  = EvalTodoError "Eq of absurd" & Left
eqVal HCase {} _    = EvalTodoError "Eq of case" & Left
eqVal HBuiltin {} _ = EvalTodoError "Eq of builtin" & Left
eqVal (HLiteral (V.Literal xTId x)) (HLiteral (V.Literal yTId y))
    | xTId == yTId = Right (x == y)
    | otherwise = EvalTypeError "Comparison of different literal types!" & Left
eqVal (HRecExtend x) (HRecExtend y) =
    do
        fx <- HRecExtend x & Right & flatRecord
        fy <- HRecExtend y & Right & flatRecord
        when (Map.keysSet fx /= Map.keysSet fy) $
            "Comparing different record types: " ++
            show (Map.keys fx) ++ " vs. " ++
            show (Map.keys fy)
            & EvalTypeError & Left
        Map.intersectionWith eq fx fy
            & Map.elems & sequence <&> and
eqVal HRecEmpty HRecEmpty = Right True
eqVal (HInject (V.Inject xf xv)) (HInject (V.Inject yf yv))
    | xf == yf = eq xv yv
    | otherwise = Right False
eqVal _ _ = Right False -- assume type checking ruled out errorenous equalities already

builtinEqH :: GuestType t => (Bool -> t) -> EvalResult srcId -> EvalResult srcId
builtinEqH f val =
    do
        V2 x y <- extractInfixParams val
        eq x y <&> f >>= toGuest

builtinEq :: EvalResult srcId -> EvalResult srcId
builtinEq = builtinEqH id

builtinNotEq :: EvalResult srcId -> EvalResult srcId
builtinNotEq = builtinEqH not

floatArg :: (Double -> a) -> Double -> a
floatArg = id

genericDiv :: (RealFrac a, Integral b) => a -> a -> b
genericDiv n d = n / d & floor

genericMod :: RealFrac a => a -> a -> a
genericMod n d = n - d * fromIntegral (genericDiv n d :: Int)

eval :: Def.FFIName -> EvalResult srcId -> EvalResult srcId
eval name =
    case name of
    Def.FFIName ["Prelude"] "=="     -> builtinEq
    Def.FFIName ["Prelude"] "/="     -> builtinNotEq
    Def.FFIName ["Prelude"] "<"      -> builtin2Infix $ floatArg (<)
    Def.FFIName ["Prelude"] "<="     -> builtin2Infix $ floatArg (<=)
    Def.FFIName ["Prelude"] ">"      -> builtin2Infix $ floatArg (>)
    Def.FFIName ["Prelude"] ">="     -> builtin2Infix $ floatArg (>=)
    Def.FFIName ["Prelude"] "*"      -> builtin2Infix $ floatArg (*)
    Def.FFIName ["Prelude"] "+"      -> builtin2Infix $ floatArg (+)
    Def.FFIName ["Prelude"] "-"      -> builtin2Infix $ floatArg (-)
    Def.FFIName ["Prelude"] "/"      -> builtin2Infix $ floatArg (/)
    Def.FFIName ["Prelude"] "div"    -> builtin2Infix $ ((fromIntegral :: Int -> Double) .) . floatArg genericDiv
    Def.FFIName ["Prelude"] "mod"    -> builtin2Infix $ floatArg genericMod
    Def.FFIName ["Prelude"] "negate" -> builtin1      $ floatArg negate
    Def.FFIName ["Prelude"] "sqrt"   -> builtin1      $ floatArg sqrt
    _ -> name & EvalMissingBuiltin & Left & const

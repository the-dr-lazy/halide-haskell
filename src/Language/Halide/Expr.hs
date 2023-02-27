{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- |
-- Module      : Language.Halide.Expr
-- Description : Scalar expressions
-- Copyright   : (c) Tom Westerhout, 2023
module Language.Halide.Expr
  ( -- * Scalar expressions

    -- | The basic building block of Halide pipelines is 'Expr'. @'Expr' a@ represents a scalar expression of
    -- type @a@.
    Expr (..)
  , Int32
  , mkExpr
  , mkVar
  , mkRVar
  , cast
  , equal
  , lessThan
  , greaterThan
  , bool
  , undef
    -- | For debugging, it's often useful to observe the value of an expression when it's evaluated. If you
    -- have a complex expression that does not depend on any buffers or indices, you can 'evaluate' it.
  , evaluate
    -- | However, often an expression is only used within a definition of a pipeline, and it's impossible to
    -- call 'evaluate' on it. In such cases, it can be wrapped with 'printed' to indicate to Halide that the
    -- value of the expression should be dumped to screen when it's computed.
  , printed
  , toIntImm

    -- * Internal
  , exprToForeignPtr
  , cxxConstructExpr
  -- , wrapCxxExpr
  , wrapCxxRVar
  , wrapCxxVarOrRVar
  , wrapCxxParameter
  , asExpr
  , asVar
  , asRVar
  , asVarOrRVar
  , asScalarParam
  , asVectorOf
  , withMany
  , binaryOp
  , unaryOp
  , checkType
  )
where

import Control.Exception (bracket)
import Control.Monad (unless, (>=>))
import Data.IORef
import Data.Int (Int32)
import Data.Proxy
import Data.Ratio (denominator, numerator)
import Data.Text (Text, unpack)
import qualified Data.Text.Encoding as T
import qualified Data.Vector.Storable.Mutable as SM
import Foreign.C.Types (CDouble)
import Foreign.ForeignPtr
import Foreign.Marshal (alloca, allocaArray, peekArray, toBool, with)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek)
import GHC.Stack (HasCallStack)
import qualified Language.C.Inline as C
import qualified Language.C.Inline.Cpp.Exception as C
import qualified Language.C.Inline.Unsafe as CU
import Language.Halide.Buffer
import Language.Halide.Context
import Language.Halide.Type
import Language.Halide.Utils
import System.IO.Unsafe (unsafePerformIO)
import Prelude hiding (min)

importHalide

instanceCxxConstructible "Halide::Expr"
instanceCxxConstructible "Halide::Var"
instanceCxxConstructible "Halide::RVar"
instanceCxxConstructible "Halide::VarOrRVar"

defineIsHalideTypeInstances

instanceHasCxxVector "Halide::Expr"
instanceHasCxxVector "Halide::Var"
instanceHasCxxVector "Halide::RVar"
instanceHasCxxVector "Halide::VarOrRVar"

-- instanceCxxConstructible "Halide::Var"
-- instanceCxxConstructible "Halide::RVar"
-- instanceCxxConstructible "Halide::VarOrRVar"

instance IsHalideType Bool where
  halideTypeFor _ = HalideType HalideTypeUInt 1 1
  toCxxExpr (fromIntegral . fromEnum -> x) =
    cxxConstruct $ \ptr ->
      [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{cast(Halide::UInt(1), Halide::Expr{$(int x)})} } |]

type instance FromTuple (Expr a) = Arguments '[Expr a]

-- | A scalar expression in Halide.
--
-- This is a wrapper around [@Halide::Expr@](https://halide-lang.org/docs/struct_halide_1_1_expr.html) C++ type.
--
-- We want to derive 'Num', 'Floating' etc. instances for t'Expr', so we can't
-- encode v'Expr', 'Var' and 'RVar' as different types.
data Expr a
  = -- | Scalar expression.
    Expr (ForeignPtr CxxExpr)
  | -- | Index variable.
    Var (ForeignPtr CxxVar)
  | -- | Reduction variable.
    RVar (ForeignPtr CxxRVar)
  | -- | Scalar parameter.
    --
    -- The 'IORef' is initialized with 'Nothing' and filled in on the first
    -- call to 'asExpr'.
    ScalarParam (IORef (Maybe (ForeignPtr CxxParameter)))

-- | Create a scalar expression from a Haskell value.
mkExpr :: IsHalideType a => a -> Expr a
mkExpr x = unsafePerformIO $! Expr <$> toCxxExpr x

-- | Create a named index variable.
mkVar :: Text -> IO (Expr Int32)
mkVar (T.encodeUtf8 -> s) = fmap Var . cxxConstruct $ \ptr ->
  [CU.exp| void {
    new ($(Halide::Var* ptr)) Halide::Var{std::string{$bs-ptr:s, static_cast<size_t>($bs-len:s)}} } |]

-- | Wrap a raw @Halide::Var@ pointer in a Haskell value.
--
-- __Note:__ 'Var' objects correspond to expressions of type 'Int32'.
-- wrapCxxVar :: Ptr CxxVar -> IO (Expr Int32)
-- wrapCxxVar = fmap Var . newForeignPtr deleter
--   where
--     deleter = [C.funPtr| void deleteExpr(Halide::Var *p) { delete p; } |]

--
--
mkRVar :: Text -> Expr Int32 -> Expr Int32 -> IO (Expr Int32)
mkRVar name min extent =
  asExpr min $ \min' ->
    asExpr extent $ \extent' ->
      wrapCxxRVar
        =<< [CU.exp| Halide::RVar* {
              new Halide::RVar{static_cast<Halide::RVar>(Halide::RDom{
                *$(const Halide::Expr* min'),
                *$(const Halide::Expr* extent'),
                std::string{$bs-ptr:s, static_cast<size_t>($bs-len:s)}
                })}
            } |]
  where
    s = T.encodeUtf8 name

-- | Return an undef value of the given type.
--
-- For more information, see [@Halide::undef@](https://halide-lang.org/docs/namespace_halide.html#a9389bcacbed602df70eae94826312e03).
undef :: forall a. IsHalideType a => Expr a
undef = unsafePerformIO $
  with (halideTypeFor (Proxy @a)) $ \tp ->
    cxxConstructExpr $ \ptr ->
      [CU.exp| void {
        new ($(Halide::Expr* ptr))
          Halide::Expr{Halide::undef(Halide::Type{*$(const halide_type_t* tp)})} } |]
{-# NOINLINE undef #-}

-- | Create a named reduction variable.
-- mkRVar :: Text -> IO (Expr Int32)
-- mkRVar name =
--   wrapCxxRVar
--     =<< [CU.exp| Halide::RVar* {
--           new Halide::RVar{std::string{$bs-ptr:s, static_cast<size_t>($bs-len:s)}} } |]
--   where
--     s = T.encodeUtf8 name

-- | Cast a scalar expression to a different type.
--
-- Use TypeApplications with this function, e.g. 'cast @Float x'.
cast :: forall to from. (HasCallStack, IsHalideType to, IsHalideType from) => Expr from -> Expr to
cast expr = unsafePerformIO $!
  asExpr expr $ \e ->
    with (halideTypeFor (Proxy @to)) $ \t ->
      cxxConstructExpr $ \ptr ->
        [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{
          Halide::cast(Halide::Type{*$(halide_type_t* t)}, *$(Halide::Expr* e))} } |]

-- | Print the expression to stdout when it's evaluated.
--
-- This is useful for debugging Halide pipelines.
printed :: IsHalideType a => Expr a -> Expr a
printed = unaryOp $ \e ptr ->
  [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{print(*$(Halide::Expr* e))} } |]

-- | Compare two scalar expressions for equality.
equal :: (HasCallStack, IsHalideType a) => Expr a -> Expr a -> Expr Bool
equal a' b' = unsafePerformIO $!
  asExpr a' $ \a -> asExpr b' $ \b ->
    cxxConstructExpr $ \ptr ->
      [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{
        (*$(Halide::Expr* a)) == (*$(Halide::Expr* b))} } |]

lessThan :: (HasCallStack, IsHalideType a) => Expr a -> Expr a -> Expr Bool
lessThan a' b' = unsafePerformIO $!
  asExpr a' $ \a -> asExpr b' $ \b ->
    cxxConstructExpr $ \ptr ->
      [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{
        (*$(Halide::Expr* a)) < (*$(Halide::Expr* b))} } |]

greaterThan :: (HasCallStack, IsHalideType a) => Expr a -> Expr a -> Expr Bool
greaterThan a' b' = unsafePerformIO $!
  asExpr a' $ \a -> asExpr b' $ \b ->
    cxxConstructExpr $ \ptr ->
      [CU.exp| void { new (($(Halide::Expr* ptr))) Halide::Expr{
        (*$(Halide::Expr* a)) > (*$(Halide::Expr* b))} } |]

-- | Similar to the standard @bool@ function from Prelude except that it's
-- lifted to work with 'Expr' types.
bool :: (HasCallStack, IsHalideType a) => Expr Bool -> Expr a -> Expr a -> Expr a
bool condExpr trueExpr falseExpr = unsafePerformIO $!
  asExpr condExpr $ \p ->
    asExpr trueExpr $ \t ->
      asExpr falseExpr $ \f ->
        cxxConstructExpr $ \ptr ->
          [CU.exp| void {
            new ($(Halide::Expr* ptr)) Halide::Expr{
              Halide::select(*$(Halide::Expr* p),
                *$(Halide::Expr* t), *$(Halide::Expr* f))} } |]

-- | Evaluate a scalar expression. It should contain no parameters.
evaluate :: forall a. IsHalideType a => Expr a -> IO a
evaluate expr =
  asExpr expr $ \e -> do
    out <- SM.new 1
    withHalideBuffer out $ \buffer -> do
      let b = castPtr (buffer :: Ptr (HalideBuffer 1 a))
      [C.throwBlock| void {
        handle_halide_exceptions([=]() {
          Halide::Func f;
          Halide::Var i;
          f(i) = *$(Halide::Expr* e);
          f.realize(Halide::Pipeline::RealizationArg{$(halide_buffer_t* b)});
        });
      } |]
    SM.read out 0

toIntImm :: IsHalideType a => Expr a -> Maybe Int
toIntImm expr = unsafePerformIO $
  asExpr expr $ \expr' -> do
    intPtr <-
      [CU.block| const int64_t* {
        auto expr = *$(const Halide::Expr* expr');
        Halide::Internal::IntImm const* node = expr.as<Halide::Internal::IntImm>();
        if (node == nullptr) return nullptr;
        return &node->value;
      } |]
    if intPtr == nullPtr
      then pure Nothing
      else Just . fromIntegral <$> peek intPtr

instance IsTuple (Arguments '[Expr a]) (Expr a) where
  toTuple (x ::: Nil) = x
  fromTuple x = x ::: Nil

instance IsHalideType a => Show (Expr a) where
  show (Expr expr) = unpack . unsafePerformIO $ do
    withForeignPtr expr $ \x ->
      peekAndDeleteCxxString
        =<< [CU.exp| std::string* { to_string_via_iostream(*$(const Halide::Expr* x)) } |]
  show (Var var) = unpack . unsafePerformIO $ do
    withForeignPtr var $ \x ->
      peekAndDeleteCxxString
        =<< [CU.exp| std::string* { to_string_via_iostream(*$(const Halide::Var* x)) } |]
  show (RVar rvar) = unpack . unsafePerformIO $ do
    withForeignPtr rvar $ \x ->
      peekAndDeleteCxxString
        =<< [CU.exp| std::string* { to_string_via_iostream(*$(const Halide::RVar* x)) } |]
  show (ScalarParam r) = unpack . unsafePerformIO $ do
    maybeParam <- readIORef r
    case maybeParam of
      Just fp ->
        withForeignPtr fp $ \x ->
          peekAndDeleteCxxString
            =<< [CU.exp| std::string* {
                  new std::string{$(const Halide::Internal::Parameter* x)->name()} } |]
      Nothing -> pure "ScalarParam"

-- | When 'Expr' is a 'ScalarParam', this function let's you set its name.
-- This name will be used in the code generated by Halide.
instance IsHalideType a => Named (Expr a) where
  setName :: HasCallStack => Expr a -> Text -> IO ()
  setName (ScalarParam r) name = do
    readIORef r >>= \case
      Just _ -> error "the name of this Expr has already been set"
      Nothing -> do
        fp <- mkScalarParameter @a (Just name)
        writeIORef r (Just fp)
  setName _ _ = error "cannot set the name of an expression that is not a parameter"

instance (IsHalideType a, Num a) => Num (Expr a) where
  fromInteger :: Integer -> Expr a
  fromInteger x = mkExpr (fromInteger x :: a)
  (+) :: Expr a -> Expr a -> Expr a
  (+) = binaryOp $ \a b ptr ->
    [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{*$(Halide::Expr* a) + *$(Halide::Expr* b)} } |]
  (-) :: Expr a -> Expr a -> Expr a
  (-) = binaryOp $ \a b ptr ->
    [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{*$(Halide::Expr* a) - *$(Halide::Expr* b)} } |]
  (*) :: Expr a -> Expr a -> Expr a
  (*) = binaryOp $ \a b ptr ->
    [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{*$(Halide::Expr* a) * *$(Halide::Expr* b)} } |]

  abs :: Expr a -> Expr a
  abs = unaryOp $ \a ptr ->
    -- If the type is unsigned, then abs does nothing Also note that for signed
    -- integers, in Halide abs returns the unsigned version, so we manually
    -- cast it back.
    [CU.block| void {
      if ($(Halide::Expr* a)->type().is_uint()) {
        new ($(Halide::Expr* ptr)) Halide::Expr{*$(Halide::Expr* a)};
      }
      else {
        new ($(Halide::Expr* ptr)) Halide::Expr{
          Halide::cast($(Halide::Expr* a)->type(), Halide::abs(*$(Halide::Expr* a)))};
      }
    } |]
  negate :: Expr a -> Expr a
  negate = unaryOp $ \a ptr ->
    [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{ -(*$(Halide::Expr* a))} } |]
  signum :: Expr a -> Expr a
  signum = error "Num instance of (Expr a) does not implement signum"

instance (IsHalideType a, Fractional a) => Fractional (Expr a) where
  (/) :: Expr a -> Expr a -> Expr a
  (/) = binaryOp $ \a b ptr ->
    [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{*$(Halide::Expr* a) / *$(Halide::Expr* b)} } |]
  fromRational :: Rational -> Expr a
  fromRational r = fromInteger (numerator r) / fromInteger (denominator r)

instance (IsHalideType a, Floating a) => Floating (Expr a) where
  pi :: Expr a
  pi = cast @a @Double $! mkExpr (pi :: Double)
  exp :: Expr a -> Expr a
  exp = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::exp(*$(Halide::Expr* a))} } |]
  log :: Expr a -> Expr a
  log = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::log(*$(Halide::Expr* a))} } |]
  sqrt :: Expr a -> Expr a
  sqrt = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::sqrt(*$(Halide::Expr* a))} } |]
  (**) :: Expr a -> Expr a -> Expr a
  (**) = binaryOp $ \a b ptr ->
    [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::pow(*$(Halide::Expr* a), *$(Halide::Expr* b))} } |]
  sin :: Expr a -> Expr a
  sin = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::sin(*$(Halide::Expr* a))} } |]
  cos :: Expr a -> Expr a
  cos = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::cos(*$(Halide::Expr* a))} } |]
  tan :: Expr a -> Expr a
  tan = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::tan(*$(Halide::Expr* a))} } |]
  asin :: Expr a -> Expr a
  asin = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::asin(*$(Halide::Expr* a))} } |]
  acos :: Expr a -> Expr a
  acos = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::acos(*$(Halide::Expr* a))} } |]
  atan :: Expr a -> Expr a
  atan = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::atan(*$(Halide::Expr* a))} } |]
  sinh :: Expr a -> Expr a
  sinh = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::sinh(*$(Halide::Expr* a))} } |]
  cosh :: Expr a -> Expr a
  cosh = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::cosh(*$(Halide::Expr* a))} } |]
  tanh :: Expr a -> Expr a
  tanh = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::tanh(*$(Halide::Expr* a))} } |]
  asinh :: Expr a -> Expr a
  asinh = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::asinh(*$(Halide::Expr* a))} } |]
  acosh :: Expr a -> Expr a
  acosh = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::acosh(*$(Halide::Expr* a))} } |]
  atanh :: Expr a -> Expr a
  atanh = unaryOp $ \a ptr -> [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{Halide::atanh(*$(Halide::Expr* a))} } |]

-- | Wrap a raw @Halide::Expr@ pointer in a Haskell value.
--
-- __Note:__ This function checks the runtime type of the expression.
-- wrapCxxExpr :: forall a. (HasCallStack, IsHalideType a) => Ptr CxxExpr -> IO (Expr a)
-- wrapCxxExpr p = do
--   checkType @a p
--   Expr <$> newForeignPtr deleter p
--   where
--     deleter = [C.funPtr| void deleteExpr(Halide::Expr *p) { delete p; } |]
cxxConstructExpr :: forall a. (HasCallStack, IsHalideType a) => (Ptr CxxExpr -> IO ()) -> IO (Expr a)
cxxConstructExpr construct = do
  fp <- cxxConstruct construct
  withForeignPtr fp (checkType @a)
  pure (Expr fp)

-- | Wrap a raw @Halide::RVar@ pointer in a Haskell value.
--
-- __Note:__ 'Var' objects correspond to expressions of type 'Int32'.
wrapCxxRVar :: Ptr CxxRVar -> IO (Expr Int32)
wrapCxxRVar = fmap RVar . newForeignPtr deleter
  where
    deleter = [C.funPtr| void deleteExpr(Halide::RVar *p) { delete p; } |]

wrapCxxVarOrRVar :: Ptr CxxVarOrRVar -> IO (Expr Int32)
wrapCxxVarOrRVar p = do
  isRVar <- toBool <$> [CU.exp| bool { $(const Halide::VarOrRVar* p)->is_rvar } |]
  expr <-
    if isRVar
      then wrapCxxRVar =<< [CU.exp| Halide::RVar* { new Halide::RVar{$(const Halide::VarOrRVar* p)->rvar} } |]
      else fmap Var . cxxConstruct $ \ptr ->
        [CU.exp| void { new ($(Halide::Var* ptr)) Halide::Var{$(const Halide::VarOrRVar* p)->var} } |]
  [CU.exp| void { delete $(const Halide::VarOrRVar* p) } |]
  pure expr

class HasHalideType a where
  getHalideType :: a -> IO HalideType

instance HasHalideType (Expr a) where
  getHalideType (Expr fp) =
    withForeignPtr fp $ \e -> alloca $ \t -> do
      [CU.block| void {
        *$(halide_type_t* t) = static_cast<halide_type_t>(
          $(Halide::Expr* e)->type()); } |]
      peek t
  getHalideType (Var fp) =
    withForeignPtr fp $ \e -> alloca $ \t -> do
      [CU.block| void {
        *$(halide_type_t* t) = static_cast<halide_type_t>(
          static_cast<Halide::Expr>(*$(Halide::Var* e)).type()); } |]
      peek t
  getHalideType (RVar fp) =
    withForeignPtr fp $ \e -> alloca $ \t -> do
      [CU.block| void {
        *$(halide_type_t* t) = static_cast<halide_type_t>(
          static_cast<Halide::Expr>(*$(Halide::RVar* e)).type()); } |]
      peek t
  getHalideType _ = error "not implemented"

instance HasHalideType (Ptr CxxExpr) where
  getHalideType e =
    alloca $ \t -> do
      [CU.block| void {
        *$(halide_type_t* t) = static_cast<halide_type_t>($(Halide::Expr* e)->type()); } |]
      peek t

instance HasHalideType (Ptr CxxVar) where
  getHalideType _ = pure $ halideTypeFor (Proxy @Int32)

instance HasHalideType (Ptr CxxRVar) where
  getHalideType _ = pure $ halideTypeFor (Proxy @Int32)

instance HasHalideType (Ptr CxxParameter) where
  getHalideType p =
    alloca $ \t -> do
      [CU.block| void {
        *$(halide_type_t* t) = static_cast<halide_type_t>($(Halide::Internal::Parameter* p)->type()); } |]
      peek t

-- | Wrap a raw @Halide::Internal::Parameter@ pointer in a Haskell value.
--
-- __Note:__ 'Var' objects correspond to expressions of type 'Int32'.
wrapCxxParameter :: Ptr CxxParameter -> IO (ForeignPtr CxxParameter)
wrapCxxParameter = newForeignPtr deleter
  where
    deleter = [C.funPtr| void deleteParameter(Halide::Internal::Parameter *p) { delete p; } |]

-- | Helper function to assert that the runtime type of the expression matches it's
-- compile-time type.
--
-- Essentially, given an @(x :: 'Expr' a)@, we check that @x.type()@ in C++ is equal to
-- @'halideTypeFor' (Proxy \@a)@ in Haskell.
checkType :: forall a t. (HasCallStack, IsHalideType a, HasHalideType t) => t -> IO ()
checkType x = do
  let hsType = halideTypeFor (Proxy @a)
  cxxType <- getHalideType x
  unless (cxxType == hsType) . error $
    "Type mismatch: C++ Expr has type "
      <> show cxxType
      <> ", but its Haskell counterpart has type "
      <> show hsType

mkScalarParameter :: forall a. IsHalideType a => Maybe Text -> IO (ForeignPtr CxxParameter)
mkScalarParameter maybeName = do
  with (halideTypeFor (Proxy @a)) $ \t -> do
    let createWithoutName =
          [CU.exp| Halide::Internal::Parameter* {
            new Halide::Internal::Parameter{Halide::Type{*$(halide_type_t* t)}, false, 0} } |]
        createWithName name =
          let s = T.encodeUtf8 name
           in [CU.exp| Halide::Internal::Parameter* {
                new Halide::Internal::Parameter{
                  Halide::Type{*$(halide_type_t* t)},
                  false,
                  0,
                  std::string{$bs-ptr:s, static_cast<size_t>($bs-len:s)}}
              } |]
    p <- maybe createWithoutName createWithName maybeName
    checkType @a p
    wrapCxxParameter p

getScalarParameter
  :: forall a
   . IsHalideType a
  => Maybe Text
  -> IORef (Maybe (ForeignPtr CxxParameter))
  -> IO (ForeignPtr CxxParameter)
getScalarParameter name r = do
  readIORef r >>= \case
    Just fp -> pure fp
    Nothing -> do
      fp <- mkScalarParameter @a name
      writeIORef r (Just fp)
      pure fp

-- | Make sure that the expression is fully constructed. That means that if we
-- are dealing with a 'ScalarParam' rather than an 'Expr', we force the
-- construction of the underlying @Halide::Internal::Parameter@ and convert it
-- to an 'Expr'.
forceExpr :: forall a. (HasCallStack, IsHalideType a) => Expr a -> IO (Expr a)
forceExpr x@(Expr _) = pure x
forceExpr (Var fp) =
  withForeignPtr fp $ \varPtr ->
    cxxConstructExpr $ \ptr ->
      [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{
        static_cast<Halide::Expr>(*$(Halide::Var* varPtr))} } |]
forceExpr (RVar fp) =
  withForeignPtr fp $ \rvarPtr ->
    cxxConstructExpr $ \ptr ->
      [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{
        static_cast<Halide::Expr>(*$(Halide::RVar* rvarPtr))} } |]
forceExpr (ScalarParam r) =
  getScalarParameter @a Nothing r >>= \fp -> withForeignPtr fp $ \paramPtr ->
    cxxConstructExpr $ \ptr ->
      [CU.exp| void { new ($(Halide::Expr* ptr)) Halide::Expr{
        Halide::Internal::Variable::make(
          $(Halide::Internal::Parameter* paramPtr)->type(),
          $(Halide::Internal::Parameter* paramPtr)->name(),
          *$(Halide::Internal::Parameter* paramPtr))} } |]

-- | Use the underlying @Halide::Expr@ in an 'IO' action.
asExpr :: IsHalideType a => Expr a -> (Ptr CxxExpr -> IO b) -> IO b
asExpr x = withForeignPtr (exprToForeignPtr x)

-- | Allows applying 'asExpr', 'asVar', 'asRVar', and 'asVarOrRVar' to multiple arguments.
--
-- Example usage:
--
-- > asVectorOf @((~) (Expr Int32)) asVarOrRVar (fromTuple args) $ \v -> do
-- >   withFunc func $ \f ->
-- >     [C.throwBlock| void { $(Halide::Func* f)->reorder(
-- >                             *$(std::vector<Halide::VarOrRVar>* v)); } |]
asVectorOf
  :: forall c k ts a
   . (All c ts, HasCxxVector k)
  => (forall t b. c t => t -> (Ptr k -> IO b) -> IO b)
  -> Arguments ts
  -> (Ptr (CxxVector k) -> IO a)
  -> IO a
asVectorOf asPtr args action =
  bracket (newCxxVector Nothing) deleteCxxVector (go args)
  where
    go
      :: All c ts'
      => Arguments ts'
      -> Ptr (CxxVector k)
      -> IO a
    go Nil v = action v
    go (x ::: xs) v = asPtr x $ \p -> cxxVectorPushBack v p >> go xs v

withMany
  :: forall k t a
   . (HasCxxVector k)
  => (t -> (Ptr k -> IO a) -> IO a)
  -> [t]
  -> (Ptr (CxxVector k) -> IO a)
  -> IO a
withMany asPtr args action =
  bracket (newCxxVector Nothing) deleteCxxVector (go args)
  where
    go [] v = action v
    go (x : xs) v = asPtr x $ \p -> cxxVectorPushBack v p >> go xs v

-- | Use the underlying @Halide::Var@ in an 'IO' action.
asVar :: HasCallStack => Expr Int32 -> (Ptr CxxVar -> IO b) -> IO b
asVar (Var fp) = withForeignPtr fp
asVar _ = error "the expression is not a Var"

-- | Use the underlying @Halide::RVar@ in an 'IO' action.
asRVar :: HasCallStack => Expr Int32 -> (Ptr CxxRVar -> IO b) -> IO b
asRVar (RVar fp) = withForeignPtr fp
asRVar _ = error "the expression is not an RVar"

-- | Use the underlying 'Var' or 'RVar' as @Halide::VarOrRVar@ in an 'IO' action.
asVarOrRVar :: HasCallStack => Expr Int32 -> (Ptr CxxVarOrRVar -> IO b) -> IO b
asVarOrRVar x action = case x of
  Var fp ->
    let allocate p = [CU.exp| Halide::VarOrRVar* { new Halide::VarOrRVar{*$(Halide::Var* p)} } |]
     in withForeignPtr fp (run . allocate)
  RVar fp ->
    let allocate p = [CU.exp| Halide::VarOrRVar* { new Halide::VarOrRVar{*$(Halide::RVar* p)} } |]
     in withForeignPtr fp (run . allocate)
  _ -> error "the expression is not a Var or an RVar"
  where
    destroy p = [CU.exp| void { delete $(Halide::VarOrRVar* p) } |]
    run allocate = bracket allocate destroy action

-- | Use the underlying @Halide::RVar@ in an 'IO' action.
asScalarParam :: forall a b. (HasCallStack, IsHalideType a) => Expr a -> (Ptr CxxParameter -> IO b) -> IO b
asScalarParam (ScalarParam r) action = do
  fp <- getScalarParameter @a Nothing r
  withForeignPtr fp action
asScalarParam _ _ = error "the expression is not a ScalarParam"

-- | Get the underlying 'ForeignPtr CxxExpr'.
exprToForeignPtr :: IsHalideType a => Expr a -> ForeignPtr CxxExpr
exprToForeignPtr x =
  unsafePerformIO $!
    forceExpr x >>= \case
      (Expr fp) -> pure fp
      _ -> error "this cannot happen"

-- | Lift a unary function working with @Halide::Expr@ to work with 'Expr'.
unaryOp :: IsHalideType a => (Ptr CxxExpr -> Ptr CxxExpr -> IO ()) -> Expr a -> Expr a
unaryOp f a = unsafePerformIO $
  asExpr a $ \aPtr ->
    cxxConstructExpr $ \destPtr ->
      f aPtr destPtr

-- | Lift a binary function working with @Halide::Expr@ to work with 'Expr'.
binaryOp :: IsHalideType a => (Ptr CxxExpr -> Ptr CxxExpr -> Ptr CxxExpr -> IO ()) -> Expr a -> Expr a -> Expr a
binaryOp f a b = unsafePerformIO $
  asExpr a $ \aPtr -> asExpr b $ \bPtr ->
    cxxConstructExpr $ \destPtr ->
      f aPtr bPtr destPtr

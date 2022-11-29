{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}

module Inferno.Types.Value where

import Control.Monad.Except (MonadError)
import Control.Monad.Fix (MonadFix)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader (MonadReader, ReaderT (..))
import Data.Int (Int64)
import qualified Data.Map as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word16, Word32, Word64)
import GHC.TypeLits (Symbol)
import Inferno.Types.Syntax (ExtIdent, Ident (..), InfernoType)
import Inferno.Types.VersionControl (VCObjectHash)
import Numeric (showHex)
import Prettyprinter
  ( Pretty (pretty),
    align,
    comma,
    encloseSep,
    lbracket,
    rbracket,
    tupled,
    (<+>),
  )
import System.Posix.Types (EpochTime)

data Value custom m
  = VInt Int64
  | VDouble Double
  | VWord16 Word16
  | VWord32 Word32
  | VWord64 Word64
  | VEpochTime EpochTime
  | VText Text
  | VEnum VCObjectHash Ident
  | VArray [Value custom m]
  | VTuple [Value custom m]
  | VOne (Value custom m)
  | VEmpty
  | VFun (Value custom m -> m (Value custom m))
  | VTypeRep InfernoType
  | VCustom custom

instance Eq c => Eq (Value c m) where
  (VInt i1) == (VInt i2) = i1 == i2
  (VDouble v1) == (VDouble v2) = v1 == v2
  (VWord16 w1) == (VWord16 w2) = w1 == w2
  (VWord32 w1) == (VWord32 w2) = w1 == w2
  (VWord64 w1) == (VWord64 w2) = w1 == w2
  (VEpochTime t1) == (VEpochTime t2) = t1 == t2
  (VText t1) == (VText t2) = t1 == t2
  (VEnum h1 e1) == (VEnum h2 e2) = h1 == h2 && e1 == e2
  (VOne v1) == (VOne v2) = v1 == v2
  VEmpty == VEmpty = True
  (VArray a1) == (VArray a2) = length a1 == length a2 && (foldr ((&&) . (uncurry (==))) True $ zip a1 a2)
  (VTuple a1) == (VTuple a2) = length a1 == length a2 && (foldr ((&&) . (uncurry (==))) True $ zip a1 a2)
  (VTypeRep t1) == (VTypeRep t2) = t1 == t2
  (VCustom c1) == (VCustom c2) = c1 == c2
  _ == _ = False

instance Pretty c => Pretty (Value c m) where
  pretty = \case
    VInt n -> pretty n
    VDouble n -> pretty n
    VWord16 w -> "0x" <> (pretty $ showHex w "")
    VWord32 w -> "0x" <> (pretty $ showHex w "")
    VWord64 w -> "0x" <> (pretty $ showHex w "")
    VText t -> pretty $ Text.pack $ show t
    VEnum _ (Ident s) -> "#" <> pretty s
    VArray vs -> encloseSep lbracket rbracket comma $ map pretty vs
    VTuple vs -> tupled $ map pretty vs
    VOne v -> "Some" <+> align (pretty v)
    VEmpty -> "None"
    VFun {} -> "<<function>>"
    VEpochTime t -> pretty $ show t <> "s"
    VTypeRep t -> "@" <> pretty t
    VCustom c -> pretty c

newtype ImplEnvM m c a = ImplEnvM {unImplEnvM :: ReaderT (Map.Map ExtIdent (Value c (ImplEnvM m c))) m a}
  deriving (Applicative, Functor, Monad, MonadReader (Map.Map ExtIdent (Value c (ImplEnvM m c))), MonadError e, MonadFix, MonadIO)

runImplEnvM :: Map.Map ExtIdent (Value c (ImplEnvM m c)) -> ImplEnvM m c a -> m a
runImplEnvM env = flip runReaderT env . unImplEnvM

newtype ImplicitCast (lbl :: Symbol) a b c = ImplicitCast (a -> b -> c)

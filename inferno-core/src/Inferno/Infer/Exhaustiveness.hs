{-# LANGUAGE ExistentialQuantification #-}

-- this module is an implementation of the exhaustiveness checker from this paper:
-- MARANGET, L. (2007). Warnings for pattern matching.
-- Journal of Functional Programming, 17(3), 387-421.
-- doi:10.1017/S0956796807006223

module Inferno.Infer.Exhaustiveness
  ( mkEnumText,
    Pattern (W),
    exhaustive,
    checkUsefullness,
    cInf,
    cEnum,
    cOne,
    cEmpty,
    cTuple,
  )
where

import Data.List (intercalate)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Inferno.Types.VersionControl (VCObjectHash)
import Prettyprinter (Pretty (pretty), align, tupled, (<+>))

data Con = COne | CEmpty | CTuple Int | forall a. (Show a, Pretty a, Enum a) => CInf a | CEnum VCObjectHash Text

instance Eq Con where
  COne == COne = True
  CEmpty == CEmpty = True
  (CTuple i) == (CTuple j) = i == j
  (CEnum e _) == (CEnum f _) = e == f
  (CInf a) == (CInf b) = (show a) == (show b)
  _ == _ = False

-- we don't really care about the ord instance here
instance Ord Con where
  compare a b = compare (mkOrd a) (mkOrd b)
    where
      mkOrd = \case
        COne -> "one"
        CEmpty -> "empty"
        CTuple n -> show n
        CInf v -> show v
        CEnum _ e -> show e

-- We define a more abstract type of a pattern here, which only deals with (C)onstructors and
-- holes/(W)ildcards, as we do not need to make a distinction between a variable and a wildcard
-- in the setting of exhaustiveness checking.
data Pattern = C Con [Pattern] | W deriving (Eq, Ord)

instance Show Pattern where
  show = \case
    W -> "_"
    C COne [x] -> "one " <> show x
    C CEmpty _ -> "empty"
    C (CTuple _) xs -> "(" <> intercalate "," (map show xs) <> ")"
    C (CInf x) _ -> show x
    C (CEnum _ x) _ -> "#" <> show x
    C _ _ -> "undefined"

instance Pretty Pattern where
  pretty = \case
    W -> "_"
    C COne [x] -> "one" <+> align (pretty x)
    C CEmpty _ -> "empty"
    C (CTuple _) xs -> tupled (map pretty xs)
    C (CInf x) _ -> pretty x
    C (CEnum _ x) _ -> "#" <> pretty x
    C _ _ -> "undefined"

type PMatrix = [[Pattern]]

cSize :: Con -> Int
cSize = \case
  COne -> 1
  CEmpty -> 0
  CTuple s -> s
  CInf _ -> 0
  CEnum _ _ -> 0

specialize :: Con -> PMatrix -> PMatrix
specialize _ [] = []
specialize c ((pi1 : pis) : rest) = case pi1 of
  C c' rs ->
    if c == c'
      then (rs ++ pis) : specialize c rest
      else specialize c rest
  W -> (replicate (cSize c) W ++ pis) : specialize c rest
specialize _ ([] : _) = error "malformed PMatrix"

specializeVec :: Con -> [Pattern] -> Maybe [Pattern]
specializeVec c p = case specialize c [p] of
  [p'] -> Just p'
  _ -> Nothing

col :: PMatrix -> [Pattern]
col [] = []
col ([] : _) = []
col ((x : _) : rest) = x : col rest

conNames :: [Pattern] -> Set Con
conNames [] = Set.empty
conNames (p : ps) = case p of
  C c _ -> Set.insert c $ conNames ps
  W -> conNames ps

data IsComplete = Complete | Incomplete Pattern

isComplete :: IsComplete -> Bool
isComplete Complete = True
isComplete _ = False

-- This function checks if a set Σ of patterns is a complete signature w.r.t the definition of the datatype, i.e.:
-- the set `{}` is always an incomplete signature (we disallow empty case exprs),
-- the set `{empty, one _}` is a complete signature for the optional type,
-- the set containing all constructors of some enum `E` is complete,
-- the set `{(_,...,_)}` is always complete for an n-tuple type,
-- the set containing any int/double/text/word patterns is always incomplete, because these sets are (theoretically) infinite
isCompleteSignature :: Map VCObjectHash (Set (VCObjectHash, Text)) -> Set Con -> IsComplete
isCompleteSignature enum_sigs s =
  if Set.null s
    then Incomplete W
    else case Set.findMin s of
      CEmpty -> if s == Set.fromList [COne, CEmpty] then Complete else Incomplete $ C COne [W]
      COne -> if s == Set.fromList [COne, CEmpty] then Complete else Incomplete $ C CEmpty []
      CTuple _ -> Complete
      CEnum e _ ->
        let e_sig = Set.map (uncurry CEnum) $ enum_sigs Map.! e
         in if s == e_sig
              then Complete
              else Incomplete $ C (Set.findMin $ e_sig `Set.difference` s) []
      CInf n -> Incomplete $ C (findSucc n) []
  where
    findSucc :: (Show a, Pretty a, Enum a) => a -> Con
    findSucc n = let sn = (CInf $ succ n) in if sn `Set.member` s then findSucc (succ n) else sn

isUseful :: Map VCObjectHash (Set (VCObjectHash, Text)) -> PMatrix -> [Pattern] -> Bool
isUseful _ [] _ = True
isUseful _ ([] : _) _ = False
isUseful _ _ [] = False -- [Pattern] should never be empty
isUseful sigs p q@(q1 : qs) = case q1 of
  C c _ ->
    let sP = specialize c p
     in case specializeVec c q of
          Just sq -> isUseful sigs sP sq
          Nothing -> error "unreachable specializeVec"
  W ->
    let sig = conNames $ col p
     in if isComplete $ isCompleteSignature sigs sig
          then
            any
              ( \ck -> case specializeVec ck q of
                  Just sq ->
                    let sP = specialize ck p
                     in isUseful sigs sP sq
                  Nothing -> False
              )
              sig
          else isUseful sigs (defaultMatrix p) qs

defaultMatrix :: PMatrix -> PMatrix
defaultMatrix [] = []
defaultMatrix ((C _ _ : _) : rest) = defaultMatrix rest
defaultMatrix ((W : pis) : rest) = pis : defaultMatrix rest
defaultMatrix _ = error "malformed PMatrix"

cTuple :: [Pattern] -> Pattern
cTuple xs = C (CTuple (length xs)) xs

cOne :: Pattern -> Pattern
cOne x = C COne [x]

cEmpty :: Pattern
cEmpty = C CEmpty []

cEnum :: VCObjectHash -> Text -> Pattern
cEnum h t = C (CEnum h t) []

cInf :: (Show a, Pretty a, Enum a) => a -> Pattern
cInf n = C (CInf n) []

exhaustive :: Map VCObjectHash (Set (VCObjectHash, Text)) -> PMatrix -> Maybe [Pattern]
exhaustive sigs pm = i sigs pm 1
  where
    -- i is a specialized version of isUseful, which returns a missing pattern list instead of just bool
    i :: Map VCObjectHash (Set (VCObjectHash, Text)) -> PMatrix -> Int -> Maybe [Pattern]
    i _ [] n = Just $ replicate n W
    i _ ([] : _) 0 = Nothing
    i enum_sigs p n =
      let sig = conNames $ col p
       in case isCompleteSignature enum_sigs sig of
            Complete -> go $ Set.toList sig
            Incomplete somePat -> (somePat :) <$> i enum_sigs (defaultMatrix p) (n -1)
      where
        go [] = Nothing
        go (ck : rest) =
          let sP = specialize ck p
           in case i sigs sP (cSize ck + n - 1) of
                Nothing -> go rest
                Just pat ->
                  Just $
                    [C ck $ take (cSize ck) pat] ++ drop (cSize ck) pat

checkUsefullness :: Map VCObjectHash (Set (VCObjectHash, Text)) -> PMatrix -> [(Int, Int)]
checkUsefullness enum_sigs p = go 0 [] p
  where
    go _ _ [] = []
    go n preceding (p_i : rest) =
      if isUseful enum_sigs preceding p_i
        then go (n + 1) (preceding ++ [p_i]) rest
        else (n, findOverlap p_i 0 preceding) : go (n + 1) (preceding ++ [p_i]) rest

    findOverlap :: [Pattern] -> Int -> PMatrix -> Int
    findOverlap _ n [] = n
    findOverlap p_i n (x : xs) =
      if isUseful enum_sigs [x] p_i
        then findOverlap p_i (n + 1) xs
        else n

-- DO NOT export the constructor EnumText or use EnumText for anything else
-- It is used purely as a hack to give Text a half defined Enum instance,
-- specifically we abuse the `succ` function to be able to generate an
-- example of an incomplete match on text
newtype EnumText = EnumText Text

mkEnumText :: Text -> EnumText
mkEnumText = EnumText

instance Show EnumText where
  show (EnumText t) = show t

instance Pretty EnumText where
  pretty (EnumText t) = pretty $ show t

instance Enum EnumText where
  toEnum = undefined
  fromEnum = undefined
  succ (EnumText t) =
    EnumText $
      if Text.null t
        then "a"
        else t <> t

{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Inferno.Eval where

-- import Control.Monad (foldM, when)
import Control.Monad.Catch (MonadCatch, SomeException, try)
import Control.Monad.Except
  ( Except,
    ExceptT,
    MonadError (throwError),
    forM,
    runExcept,
    runExceptT,
  )
import Control.Monad.Identity (Identity)
import Control.Monad.Reader (ask, local)
import Data.Foldable (foldrM)
import Data.List.NonEmpty (NonEmpty (..), toList)
import qualified Data.Map as Map
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
import Inferno.Eval.Error
  ( EvalError (AssertionFailed, RuntimeError),
  )
import Inferno.Module.Builtin (enumBoolHash)
import Inferno.Types.Syntax
  ( BaseType (..),
    Expr (..),
    ExtIdent (..),
    Ident (..),
    ImplExpl (..),
    InfernoType (TBase),
    Lit (LDouble, LHex, LInt, LText),
    Pat (..),
    tListToList,
    toEitherList,
  )
import Inferno.Types.Value
  ( ImplEnvM,
    Value
      ( VArray,
        VDouble,
        VEmpty,
        VEnum,
        VFun,
        VInt,
        VOne,
        VText,
        VTuple,
        VTypeRep,
        VWord64
      ),
    runImplEnvM,
  )
import Inferno.Types.VersionControl (VCObjectHash)
import Inferno.Utils.Prettyprinter (renderPretty)
import Prettyprinter
  ( LayoutOptions (LayoutOptions),
    PageWidth (Unbounded),
    Pretty (pretty),
    layoutPretty,
  )
import Prettyprinter.Render.Text (renderStrict)

type TermEnv hash c m = (Map.Map ExtIdent (Value c m), Map.Map hash (Value c m))

type Interpreter t = Except EvalError t

emptyTmenv :: TermEnv hash c m
emptyTmenv = (Map.empty, Map.empty)

eval :: (MonadError EvalError m, MonadError EvalError (ImplEnvM m c), Pretty c) => TermEnv VCObjectHash c (ImplEnvM m c) -> Expr (Maybe VCObjectHash) a -> ImplEnvM m c (Value c (ImplEnvM m c))
eval env@(localEnv, pinnedEnv) expr = case expr of
  Lit_ (LInt k) -> return $
    VFun $ \case
      VTypeRep (TBase TInt) -> return $ VInt k
      VTypeRep (TBase TDouble) -> return $ VDouble $ fromIntegral k
      _ -> throwError $ RuntimeError "Invalid runtime rep for numeric constant."
  Lit_ (LDouble k) -> return $ VDouble k
  Lit_ (LHex w) -> return $ VWord64 w
  Lit_ (LText t) -> return $ VText t
  InterpolatedString_ es -> do
    res <- forM (toEitherList es) $ either (return . VText) (\(_, e, _) -> eval env e)
    return $ VText $ Text.concat $ map toText res
    where
      toText (VText t) = t
      toText e = renderStrict $ layoutPretty (LayoutOptions Unbounded) $ pretty e
  Array_ es ->
    foldrM (\(e, _) vs -> eval env e >>= return . (: vs)) [] es >>= return . VArray
  ArrayComp_ e srcs mCond -> do
    vals <- sequence' env srcs
    VArray <$> case mCond of
      Nothing ->
        forM vals $ \vs ->
          let nenv = foldr (uncurry Map.insert) localEnv vs in eval (nenv, pinnedEnv) e
      Just (_, cond) ->
        catMaybes
          <$> ( forM vals $ \vs -> do
                  let nenv = foldr (uncurry Map.insert) localEnv vs
                  eval (nenv, pinnedEnv) cond >>= \case
                    VEnum hash "true" ->
                      if hash == enumBoolHash
                        then Just <$> (eval (nenv, pinnedEnv) e)
                        else throwError $ RuntimeError "failed to match with a bool"
                    VEnum hash "false" ->
                      if hash == enumBoolHash
                        then return Nothing
                        else throwError $ RuntimeError "failed to match with a bool"
                    _ -> throwError $ RuntimeError "failed to match with a bool"
              )
    where
      sequence' :: (MonadError EvalError m, Pretty c) => TermEnv VCObjectHash c (ImplEnvM m c) -> NonEmpty (a, Ident, a, Expr (Maybe VCObjectHash) a, Maybe a) -> ImplEnvM m c [[(ExtIdent, Value c (ImplEnvM m c))]]
      sequence' env'@(localEnv', pinnedEnv') = \case
        (_, Ident x, _, e_s, _) :| [] -> do
          eval env' e_s >>= \case
            VArray vals -> return $ map ((: []) . (ExtIdent $ Right x,)) vals
            _ -> throwError $ RuntimeError "failed to match with an array"
        (_, Ident x, _, e_s, _) :| (r : rs) -> do
          eval env' e_s >>= \case
            VArray vals ->
              concat
                <$> ( forM vals $ \v -> do
                        res <- sequence' (Map.insert (ExtIdent $ Right x) v localEnv', pinnedEnv') (r :| rs)
                        return $ map ((ExtIdent $ Right x, v) :) res
                    )
            _ -> throwError $ RuntimeError "failed to match with an array"
  Enum_ (Just hash) _ i -> return $ VEnum hash i
  Enum_ Nothing _ _ -> throwError $ RuntimeError "All enums must be pinned"
  Var_ (Just hash) _ x ->
    case Map.lookup hash pinnedEnv of
      Just v -> return v
      Nothing -> throwError $ RuntimeError $ show x <> "(" <> show hash <> ") not found in the pinned env"
  Var_ Nothing _ (Expl x) -> do
    case Map.lookup x localEnv of
      Just v -> return v
      Nothing -> throwError $ RuntimeError $ show x <> " not found in the unpinned env"
  Var_ Nothing _ (Impl x) -> do
    implEnv <- ask
    case Map.lookup x implEnv of
      Just v -> return v
      Nothing -> throwError $ RuntimeError $ show x <> " not found in the implicit env"
  OpVar_ (Just hash) _ x ->
    case Map.lookup hash pinnedEnv of
      Just v -> return v
      Nothing -> throwError $ RuntimeError $ show x <> "(" <> show hash <> ") not found in the pinned env"
  OpVar_ Nothing _ (Ident x) -> do
    case Map.lookup (ExtIdent $ Right x) localEnv of
      Just v -> return v
      Nothing -> throwError $ RuntimeError $ show x <> " not found in env"
  TypeRep_ t -> pure $ VTypeRep t
  Op_ _ Nothing _ op _ -> throwError $ RuntimeError $ show op <> " should be pinned"
  Op_ a (Just hash) _ns op b -> do
    a' <- eval env a
    b' <- eval env b
    case Map.lookup hash pinnedEnv of
      Nothing -> throwError $ RuntimeError $ show op <> "(" <> show hash <> ") not found in the pinned env"
      Just (VFun f) ->
        f a' >>= \case
          VFun f' -> f' b'
          _ -> throwError $ RuntimeError $ show op <> " not bound to a binary function in env"
      Just _ -> throwError $ RuntimeError $ show op <> " not bound to a function in env"
  PreOp_ Nothing _ op _ -> throwError $ RuntimeError $ show op <> " should be pinned"
  PreOp_ (Just hash) _ns op a -> do
    a' <- eval env a
    case Map.lookup hash pinnedEnv of
      Nothing -> throwError $ RuntimeError $ show op <> "(" <> show hash <> ") not found in the pinned env"
      Just (VFun f) -> f a'
      Just _ -> throwError $ RuntimeError $ show op <> " not bound to a function in env"
  Lam_ args body -> go localEnv $ toList args
    where
      go nenv = \case
        [] -> eval (nenv, pinnedEnv) body
        (_, Just x) : xs ->
          return $ VFun $ \arg -> go (Map.insert x arg nenv) xs
        (_, Nothing) : xs -> return $ VFun $ \_arg -> go nenv xs
  App_ fun arg -> do
    eval env fun >>= \case
      VFun f -> do
        argv <- eval env arg
        f argv
      _ -> throwError $ RuntimeError "failed to match with a function"
  Let_ (Expl x) e body -> do
    e' <- eval env e
    let nenv = Map.insert x e' localEnv
    eval (nenv, pinnedEnv) body
  Let_ (Impl x) e body -> do
    e' <- eval env e
    local (\impEnv -> Map.insert x e' impEnv) $ eval env body
  If_ cond tr fl ->
    eval env cond >>= \case
      VEnum hash "true" ->
        if hash == enumBoolHash
          then eval env tr
          else throwError $ RuntimeError "failed to match with a bool"
      VEnum hash "false" ->
        if hash == enumBoolHash
          then eval env fl
          else throwError $ RuntimeError "failed to match with a bool"
      _ -> throwError $ RuntimeError "failed to match with a bool"
  Tuple_ es ->
    foldrM (\(e, _) vs -> eval env e >>= return . (: vs)) [] (tListToList es) >>= return . VTuple
  One_ e -> eval env e >>= return . VOne
  Empty_ -> return $ VEmpty
  Assert_ cond e ->
    eval env cond >>= \case
      VEnum hash "false" ->
        if hash == enumBoolHash
          then throwError AssertionFailed
          else throwError $ RuntimeError "failed to match with a bool"
      VEnum hash "true" ->
        if hash == enumBoolHash
          then eval env e
          else throwError $ RuntimeError "failed to match with a bool"
      _ -> throwError $ RuntimeError "failed to match with a bool"
  Case_ e pats -> do
    v <- eval env e
    matchAny v pats
    where
      matchAny v ((_, p, _, body) :| []) = case match v p of
        Just nenv -> eval nenv body
        Nothing -> throwError $ RuntimeError $ "non-exhaustive patterns in case detected in " <> (Text.unpack $ renderPretty v)
      matchAny v ((_, p, _, body) :| (r : rs)) = case match v p of
        Just nenv -> eval nenv body
        Nothing -> matchAny v (r :| rs)

      match v p = case (v, p) of
        (_, PVar _ (Just (Ident x))) -> Just $ (Map.insert (ExtIdent $ Right x) v localEnv, pinnedEnv)
        (_, PVar _ Nothing) -> Just env
        (VEnum h1 _, PEnum _ (Just h2) _ _) ->
          if h1 == h2
            then Just env
            else Nothing
        (VInt i1, PLit _ (LInt i2)) ->
          if i1 == i2
            then Just env
            else Nothing
        (VDouble d1, PLit _ (LDouble d2)) ->
          if d1 == d2
            then Just env
            else Nothing
        (VText t1, PLit _ (LText t2)) ->
          if t1 == t2
            then Just env
            else Nothing
        (VWord64 h1, PLit _ (LHex h2)) ->
          if h1 == h2
            then Just env
            else Nothing
        (VOne v', POne _ p') -> match v' p'
        (VEmpty, PEmpty _) -> Just env
        (VTuple vs, PTuple _ ps _) -> matchTuple vs $ tListToList ps
        _ -> Nothing

      matchTuple [] [] = Just env
      matchTuple (v' : vs) ((p', _) : ps) = do
        env1 <- match v' p'
        env2 <- matchTuple vs ps
        -- since variables in patterns must be linear,
        -- env1 and env2 should not overlap
        return $ env1 <> env2
      matchTuple _ _ = Nothing
  CommentAbove _ e -> eval env e
  CommentAfter e _ -> eval env e
  CommentBelow e _ -> eval env e
  Bracketed_ e -> eval env e
  RenameModule_ _ _ e -> eval env e
  OpenModule_ _ _ e -> eval env e

runEvalIO ::
  (MonadCatch m, Pretty c) =>
  ImplEnvM (ExceptT EvalError m) c (TermEnv VCObjectHash c (ImplEnvM (ExceptT EvalError m) c)) ->
  Map.Map ExtIdent (Value c (ImplEnvM (ExceptT EvalError m) c)) ->
  Expr (Maybe VCObjectHash) a ->
  m (Either EvalError (Value c (ImplEnvM (ExceptT EvalError m) c)))
runEvalIO env implicitEnv ex = do
  input <- try $ runExceptT $ runImplEnvM implicitEnv $ (env >>= \env' -> eval env' ex)
  return $ case input of
    Left (e :: SomeException) -> Left $ RuntimeError $ show e
    Right res -> res

pureEval ::
  (Pretty c) =>
  TermEnv VCObjectHash c (ImplEnvM (ExceptT EvalError Identity) c) ->
  Map.Map ExtIdent (Value c (ImplEnvM (ExceptT EvalError Identity) c)) ->
  Expr (Maybe VCObjectHash) a ->
  Either EvalError (Value c (ImplEnvM (ExceptT EvalError Identity) c))
pureEval env implicitEnv ex = runExcept $ runImplEnvM implicitEnv $ eval env ex

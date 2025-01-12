{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeInType #-}

module Inferno.LSP.Server where

import Colog.Core.Action (LogAction (..))
import Control.Concurrent (forkIO)
import Control.Concurrent.STM.TChan (TChan, newTChan, readTChan, writeTChan)
import Control.Concurrent.STM.TVar (TVar, modifyTVar, newTVar, readTVar)
import qualified Control.Exception as E
import Control.Monad (forever)
import Control.Monad.Except (MonadError)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.STM (atomically)
import Control.Monad.Trans.Reader (ReaderT (..), ask)
-- import qualified Data.Aeson as J
-- import           Data.Int (Int32)
import qualified Data.ByteString as BS
import Data.ByteString.Builder.Extra (defaultChunkSize)
import qualified Data.ByteString.Lazy as BSL
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (catMaybes, fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Utf16.Rope as Rope
import Data.Time.Clock (UTCTime, getCurrentTime)
import qualified Data.UUID.V4 as UUID.V4
import Inferno.Eval.Error (EvalError)
import Inferno.LSP.Completion (completionQueryAt, filterModuleNameCompletionItems, findInPrelude, identifierCompletionItems, mkCompletionItem, rwsCompletionItems)
import Inferno.LSP.ParseInfer (parseAndInfer)
import Inferno.Module.Prelude (ModuleMap, preludeNameToTypeMap)
import Inferno.Types.Syntax (Expr, Ident (..), InfernoType)
import Inferno.Types.Type (TCScheme)
import Inferno.Types.VersionControl (Pinned)
import Inferno.VersionControl.Types (VCObjectHash)
import Keys.UUID (UUID (..))
import Language.LSP.Diagnostics (partitionBySource)
import Language.LSP.Server
  ( Handler,
    Handlers (..),
    LspT (..),
    Options (..),
    ServerDefinition (..),
    defaultOptions,
    getLspEnv,
    getVirtualFile,
    mapHandlers,
    notificationHandler,
    publishDiagnostics,
    requestHandler,
    runLspT,
    runServerWith,
    type (<~>) (Iso),
  )
import qualified Language.LSP.Types as J
import qualified Language.LSP.Types.Lens as J
import Language.LSP.VFS (VirtualFile (..))
import Lens.Micro (to, (^.))
import Plow.Logging (IOTracer (..), traceWith)
import Plow.Logging.Async (withAsyncHandleTracer)
import Prettyprinter (Pretty)
import System.IO (BufferMode (NoBuffering), hFlush, hSetBuffering, hSetEncoding, stdin, stdout, utf8)

-- import           System.Exit

-- This is the entry point for launching an LSP server, explicitly passing in handles for input and output
-- the `getIdents` parameter is a handle for input parameters, only used by the frontend.
-- This is used in the script editor, where the user only specifies the body of the script in the editor
-- and defines the input arguments separately in the sidebar. When processing in the LSP server, we have to
-- manually join the body of the script coming from the monaco editor with the parameters. i.e. if the user
-- specifies parameters ["a", "b"] and the body of the script is "a + b", then we will pass "fun a b -> a + b"
-- to the inferno typechecker.
runInfernoLspServerWith ::
  forall m c.
  (MonadError EvalError m, Pretty c, Eq c) =>
  IOTracer T.Text ->
  IO BS.ByteString ->
  (BSL.ByteString -> IO ()) ->
  ModuleMap m c ->
  IO [Maybe Ident] ->
  (InfernoType -> Either T.Text ()) ->
  -- | Action to run before start parsing
  ((UUID, UTCTime) -> IO ()) ->
  -- | Action to run after parsing is done
  ((UUID, UTCTime) -> ParsedResult -> IO ParsedResult) ->
  IO Int
runInfernoLspServerWith tracer clientIn clientOut prelude getIdents validateInput before after = flip E.catches handlers $ do
  rin <- atomically newTChan :: IO (TChan ReactorInput)
  docMap <- atomically $ newTVar mempty
  let infernoEnv = InfernoEnv docMap tracer getIdents before after validateInput

  let serverDefinition =
        ServerDefinition
          { defaultConfig = (),
            onConfigurationChange = \old _v -> Right old,
            doInitialize = \env _ -> forkIO (reactor tracer rin) >> pure (Right env),
            staticHandlers = lspHandlers @m @c prelude rin,
            interpretHandler = \env -> Iso (flip runReaderT infernoEnv . runLspT env) liftIO,
            options = lspOptions
          }

  let serverTracer = traceWith tracer . T.pack . show
  i <- runServerWith (LogAction serverTracer) (LogAction (liftIO . serverTracer)) clientIn clientOut serverDefinition
  traceWith tracer "shutting down..."
  pure i
  where
    handlers =
      [ E.Handler ioExcept,
        E.Handler someExcept
      ]
    ioExcept (e :: E.IOException) = traceWith tracer (T.pack (show e)) >> return 1
    someExcept (e :: E.SomeException) = traceWith tracer (T.pack (show e)) >> return 1

runInfernoLspServer :: forall m c. (MonadError EvalError m, Pretty c, Eq c) => ModuleMap m c -> IO Int
runInfernoLspServer prelude = do
  hSetBuffering stdin NoBuffering
  hSetEncoding stdin utf8

  hSetBuffering stdout NoBuffering
  hSetEncoding stdout utf8

  let clientIn = BS.hGetSome stdin defaultChunkSize

      clientOut out = do
        BSL.hPut stdout out
        hFlush stdout
      getIdents = pure []

  withAsyncHandleTracer stdout 100 $ \tracer -> do
    let beforeParse _ = pure ()
        afterParse _ = pure
    runInfernoLspServerWith @m @c tracer clientIn clientOut prelude getIdents (const $ Right ()) beforeParse afterParse

-- ---------------------------------------------------------------------

syncOptions :: J.TextDocumentSyncOptions
syncOptions =
  J.TextDocumentSyncOptions
    { J._openClose = Just True,
      J._change = Just J.TdSyncIncremental,
      J._willSave = Just False,
      J._willSaveWaitUntil = Just False,
      J._save = Just $ J.InR $ J.SaveOptions $ Just False
    }

lspOptions :: Options
lspOptions =
  defaultOptions
    { textDocumentSync = Just syncOptions,
      executeCommandCommands = Nothing
    }

-- ---------------------------------------------------------------------

-- The reactor is a process that serialises and buffers all requests from the
-- LSP client, so they can be sent to the backend compiler one at a time, and a
-- reply sent.

-- | Helper type to reduce typing
type ParsedResult = Either [J.Diagnostic] (Expr (Pinned VCObjectHash) (), TCScheme, [(J.Range, J.MarkupContent)])

withParseAndInfer :: MonadIO m => ((UUID, UTCTime) -> m ()) -> ((UUID, UTCTime) -> ParsedResult -> m ParsedResult) -> m ParsedResult -> m ParsedResult
withParseAndInfer before after action = do
  ts <- liftIO getCurrentTime
  uuid <- UUID <$> liftIO UUID.V4.nextRandom

  before (uuid, ts)
  result <- action
  after (uuid, ts) result

data InfernoEnv = InfernoEnv
  { hovers :: TVar (Map (J.NormalizedUri, J.Int32) [(J.Range, J.MarkupContent)]),
    tracer :: IOTracer T.Text,
    getIdents :: IO [Maybe Ident],
    -- | Action to run before start parsing
    beforeParse :: (UUID, UTCTime) -> IO (),
    -- | Action to run after parsing is done
    afterParse :: (UUID, UTCTime) -> ParsedResult -> IO ParsedResult,
    -- | If you don't care about the input type use (const $ Right ())
    validateInput :: InfernoType -> Either T.Text ()
  }

type InfernoLspM = LspT () (ReaderT InfernoEnv IO)

newtype ReactorInput
  = ReactorAction (IO ())

-- ---------------------------------------------------------------------

-- | The single point that all events flow through, allowing management of state
-- to stitch replies and requests together from the two asynchronous sides: lsp
-- server and backend compiler
reactor :: IOTracer T.Text -> TChan ReactorInput -> IO ()
reactor tracer inp = do
  traceWith tracer "Started the reactor"
  forever $ do
    ReactorAction act <- atomically $ readTChan inp
    act

getInfernoEnv :: InfernoLspM InfernoEnv
getInfernoEnv = LspT $ ReaderT $ \_ -> ask

trace :: String -> InfernoLspM ()
trace s = LspT $
  ReaderT $ \_ -> do
    InfernoEnv {tracer} <- ask
    traceWith tracer (T.pack s)

sendDiagnostics :: J.NormalizedUri -> J.TextDocumentVersion -> [J.Diagnostic] -> InfernoLspM ()
sendDiagnostics fileUri version diags =
  publishDiagnostics 100 fileUri version (partitionBySource diags)

-- | Check if we have a handler, and if we create a haskell-lsp handler to pass it as
-- input into the reactor
lspHandlers :: forall m c. (MonadError EvalError m, Pretty c, Eq c) => ModuleMap m c -> TChan ReactorInput -> Handlers InfernoLspM
lspHandlers prelude rin = mapHandlers goReq goNot (handle @m @c prelude)
  where
    goReq :: forall (a :: J.Method 'J.FromClient 'J.Request). Handler InfernoLspM a -> Handler InfernoLspM a
    goReq f = \msg k -> do
      env <- getLspEnv
      infernoEnv <- getInfernoEnv
      liftIO $ atomically $ writeTChan rin $ ReactorAction (flip runReaderT infernoEnv $ runLspT env $ f msg k)

    goNot :: forall (a :: J.Method 'J.FromClient 'J.Notification). Handler InfernoLspM a -> Handler InfernoLspM a
    goNot f = \msg -> do
      env <- getLspEnv
      infernoEnv <- getInfernoEnv
      liftIO $ atomically $ writeTChan rin $ ReactorAction (flip runReaderT infernoEnv $ runLspT env $ f msg)

-- | Where the actual logic resides for handling requests and notifications.
handle :: forall m c. (MonadError EvalError m, Pretty c, Eq c) => ModuleMap m c -> Handlers InfernoLspM
handle prelude =
  mconcat
    [ notificationHandler J.STextDocumentDidOpen $ \msg -> do
        InfernoEnv {hovers = hoversTV, getIdents, beforeParse, afterParse, validateInput} <- getInfernoEnv
        let doc_uri = msg ^. J.params . J.textDocument . J.uri . to J.toNormalizedUri
            doc_txt = msg ^. J.params . J.textDocument . J.text
        idents <- liftIO getIdents
        trace $ "Processing DidOpenTextDocument for: " ++ show doc_uri
        hovers <-
          withParseAndInfer (liftIO . beforeParse) (\x y -> liftIO $ afterParse x y) (parseAndInfer @m @_ @c prelude idents doc_txt validateInput) >>= \case
            Left errs -> do
              sendDiagnostics doc_uri (Just 0) errs
              pure mempty
            Right (_expr, _ty, hovers) -> do
              trace $ "Created hovers for: " ++ show doc_uri
              sendDiagnostics doc_uri (Just 0) []
              pure hovers

        doc_version <-
          getVirtualFile doc_uri >>= \case
            Just (VirtualFile doc_version _ _) -> pure doc_version
            Nothing -> pure 0 -- Maybe a good default?
        liftIO $ atomically $ modifyTVar hoversTV $ \hoversMap -> Map.insert (doc_uri, doc_version) hovers hoversMap,
      notificationHandler J.STextDocumentDidChange $ \msg -> do
        InfernoEnv {hovers = hoversTV, getIdents, beforeParse, afterParse, validateInput} <- getInfernoEnv
        let doc_uri =
              msg
                ^. J.params
                  . J.textDocument
                  . J.uri
                  . to J.toNormalizedUri
        getVirtualFile doc_uri >>= \case
          Just (VirtualFile doc_version _ rope) -> do
            let txt = Rope.toText rope
            trace $ "Processing DidChangeTextDocument for: " ++ show doc_uri ++ " - " ++ show doc_version
            idents <- liftIO getIdents
            hovers <-
              withParseAndInfer (liftIO . beforeParse) (\x y -> liftIO $ afterParse x y) (parseAndInfer @m @_ @c prelude idents txt validateInput) >>= \case
                Left errs -> do
                  trace $ "Sending errs: " ++ show errs
                  sendDiagnostics doc_uri (Just doc_version) errs
                  pure mempty
                Right (_expr, _ty, hovers) -> do
                  trace $ "Updated hovers for: " ++ show doc_uri ++ " - " ++ show doc_version
                  sendDiagnostics doc_uri (Just doc_version) []
                  pure hovers
            trace $ "Setting hovers: " ++ show hovers
            liftIO $ atomically $ modifyTVar hoversTV $ \hoversMap -> Map.insert (doc_uri, doc_version) hovers hoversMap
          Nothing -> pure (),
      requestHandler J.STextDocumentCompletion $ \req responder -> do
        InfernoEnv {getIdents} <- getInfernoEnv
        let doc_uri = req ^. J.params . J.textDocument . J.uri . to J.toNormalizedUri
            pos = req ^. J.params . J.position

        completionPrefix <-
          getVirtualFile doc_uri >>= \case
            Just (VirtualFile _ _ rope) -> do
              let txt = Rope.toText rope
              let (_completionLeadup, completionPrefix) = completionQueryAt txt pos
              pure $ Just completionPrefix
            Nothing -> pure Nothing
        trace $ "Completion prefix: " <> show completionPrefix
        mIdents <- liftIO $ getIdents
        let completions = maybe [] id $ findInPrelude @c (preludeNameToTypeMap prelude) <$> completionPrefix
            idents = unIdent <$> catMaybes mIdents
            identCompletions = maybe [] id $ identifierCompletionItems idents <$> completionPrefix
            rwsCompletions = maybe [] id $ rwsCompletionItems <$> completionPrefix
            moduleCompletions = maybe [] id $ filterModuleNameCompletionItems @c (preludeNameToTypeMap prelude) <$> completionPrefix
            allCompletions = rwsCompletions ++ moduleCompletions ++ identCompletions ++ map (uncurry $ mkCompletionItem prelude $ fromMaybe "" completionPrefix) completions

        trace $ "Ident completions: " <> show identCompletions
        trace $ "Found completions: " <> show completions

        responder $ Right $ J.InL $ J.List $ allCompletions,
      requestHandler J.STextDocumentHover $ \req responder -> do
        InfernoEnv {hovers = hoversTV} <- getInfernoEnv
        trace "Processing a textDocument/hover request"
        let J.Position l c = req ^. J.params . J.position
            doc_uri =
              req
                ^. J.params
                  . J.textDocument
                  . J.uri
                  . to J.toNormalizedUri

        mDoc_version <-
          getVirtualFile doc_uri >>= \case
            Just (VirtualFile doc_version _ _) -> pure $ Just doc_version
            Nothing -> pure Nothing

        hoversMap <- liftIO $ atomically $ readTVar hoversTV
        responder $
          Right $ case mDoc_version of
            Just doc_version -> case Map.lookup (doc_uri, doc_version) hoversMap of
              Just hovers ->
                (\(r, t) -> J.Hover (J.HoverContents t) (Just r))
                  <$> ( findSmallestRange $
                          flip filter hovers $
                            \(J.Range (J.Position lStart cStart) (J.Position lEnd cEnd), _) ->
                              if l < lStart || l > lEnd
                                then False
                                else
                                  if l == lStart && c < cStart
                                    then False
                                    else
                                      if l == lEnd && c > cEnd
                                        then False
                                        else True
                      )
              Nothing -> Nothing
            Nothing -> Nothing
    ]

findSmallestRange :: [(J.Range, a)] -> Maybe (J.Range, a)
findSmallestRange = \case
  [] -> Nothing
  (r : rs) -> Just $ foldr (\x@(a, _) y@(b, _) -> if a `containsRange` b then y else x) r rs
  where
    containsRange
      (J.Range (J.Position aStartLine aStartColumn) (J.Position aEndLine aEndColumn))
      (J.Range (J.Position bStartLine bStartColumn) (J.Position bEndLine bEndColumn)) =
        if bStartLine < aStartLine || bEndLine < aStartLine
          then False
          else
            if bStartLine > aEndLine || bEndLine > aEndLine
              then False
              else
                if bStartLine == aStartLine && bStartColumn < aStartColumn
                  then False
                  else
                    if bEndLine == aEndLine && bEndColumn > aEndColumn
                      then False
                      else True

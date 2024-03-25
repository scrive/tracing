{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-} -- For the MonadReader instance.
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

-- | This module is useful mostly for tracing backend implementors. If you are only interested in
-- adding tracing to an application, start at "Monitor.Tracing".
module Control.Monad.Trace (
  -- * Tracers
  Tracer, newTracer,
  runTraceT, runTraceT', TraceT,

  -- * Collected data
  -- | Tracers currently expose two pieces of data: completed spans and pending span count. Note
  -- that only sampled spans are eligible: spans which are 'Control.Monad.Trace.Class.neverSampled'
  -- appear in neither.

  -- ** Completed spans
  spanSamples, Sample(..), Tags, Logs,

  -- ** Pending spans
  pendingSpanCount,

  -- ** SBQueue
  SBQueue,
  defaultQueueCapacity,
  newSBQueueIO,
  isEmptySBQueue,
  readSBQueue,
  readSBQueueOnce,
  writeSBQueue
) where

import Prelude hiding (span)

import Control.Monad.Trace.Class
import Control.Monad.Trace.Internal

import Control.Applicative ((<|>))
import Control.Monad.STM (retry)
import Control.Concurrent.STM.Lifted
import Control.Exception.Lifted
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (ReaderT(ReaderT), ask, asks, local, runReaderT)
import Control.Monad.Reader.Class (MonadReader)
import Control.Monad.Trans.Class (MonadTrans, lift)
import Control.Monad.Base (MonadBase)
import Control.Monad.Catch (MonadCatch, MonadMask, MonadThrow)
import Control.Monad.Trans.Control
import Control.Monad.Except (MonadError)
import qualified Data.Aeson as JSON
import Data.Foldable (for_)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Time.Clock (NominalDiffTime)
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)

-- | A collection of span tags.
type Tags = Map Key JSON.Value

-- | A collection of span logs.
type Logs = [(POSIXTime, Key, JSON.Value)]

-- | A sampled span and its associated metadata.
data Sample = Sample
  { sampleSpan :: !Span
  -- ^ The sampled span.
  , sampleTags :: !Tags
  -- ^ Tags collected during this span.
  , sampleLogs :: !Logs
  -- ^ Logs collected during this span, sorted in chronological order.
  , sampleStart :: !POSIXTime
  -- ^ The time the span started at.
  , sampleDuration :: !NominalDiffTime
  -- ^ The span's duration.
  }

-- SBQueue implementation and helpers are all taken shamelessly from logbase

-- | Default capacity of log queues (TBQueue for regular logger, 'SBQueue' for
-- bulk loggers). This corresponds to approximately 200 MiB memory residency
-- when the queue is full.
defaultQueueCapacity :: Int
defaultQueueCapacity = 1000000

-- | A simple STM based bounded queue.
data SBQueue a = SBQueue !(TVar [a]) !(TVar Int) !Int

-- | Create an instance of 'SBQueue' with a given capacity.
newSBQueueIO :: Int -> IO (SBQueue a)
newSBQueueIO capacity = SBQueue <$> newTVarIO [] <*> newTVarIO 0 <*> pure capacity

-- | Check if an 'SBQueue' is empty.
isEmptySBQueue :: SBQueue a -> STM Bool
isEmptySBQueue (SBQueue queue count _capacity) = do
  isEmpty  <- null <$> readTVar queue
  numElems <- readTVar count
  assert (if isEmpty then numElems == 0 else numElems > 0) $
    return isEmpty

data ShouldRetry = Retry | OnlyOnce
  deriving (Eq)

readSBQueue' :: ShouldRetry -> SBQueue a -> STM [a]
readSBQueue' shouldRetry (SBQueue queue count _capacity) = do
  elems <- readTVar queue
  when (null elems && shouldRetry == Retry) retry
  writeTVar queue []
  writeTVar count 0
  pure $ reverse elems

-- | Read all the values stored in an 'SBQueue'. Retry if none are available.
readSBQueue :: SBQueue a -> STM [a]
readSBQueue = readSBQueue' Retry

-- | A non-retrying version of readSBQueue
readSBQueueOnce :: SBQueue a -> STM [a]
readSBQueueOnce = readSBQueue' OnlyOnce

-- | Write a value to an 'SBQueue'.
writeSBQueue :: SBQueue a -> a -> STM ()
writeSBQueue (SBQueue queue count capacity) a = do
  numElems <- readTVar count
  when (numElems < capacity) $ do
    modifyTVar queue (a :)
    -- Strict modification of the queue size to avoid space leak
    modifyTVar' count (+1)


-- | A tracer is a producer of spans.
--
-- More specifically, a tracer:
--
-- * runs 'MonadTrace' actions via 'runTraceT',
-- * transparently collects their generated spans,
-- * and outputs them to a channel (available via 'spanSamples').
--
-- These samples can then be consumed independently, decoupling downstream span processing from
-- their production.
data Tracer = Tracer
  { tracerQueue :: SBQueue Sample
  , tracerPendingCount :: TVar Int
  }

-- | Creates a new 'Tracer'.
newTracer :: MonadIO m => m Tracer
newTracer = liftIO $ Tracer <$> newSBQueueIO defaultQueueCapacity <*> newTVarIO 0

-- | Returns the number of spans currently in flight (started but not yet completed).
pendingSpanCount :: Tracer -> TVar Int
pendingSpanCount = tracerPendingCount

-- | Returns all newly completed spans' samples. The samples become available in the same order they
-- are completed.
spanSamples :: Tracer -> SBQueue Sample
spanSamples = tracerQueue

data Scope = Scope
  { scopeTracer :: !Tracer
  , scopeSpan :: !(Maybe Span)
  , scopeTags :: !(Maybe (TVar Tags))
  , scopeLogs :: !(Maybe (TVar Logs))
  }

-- | A span generation monad.
newtype TraceT m a = TraceT { traceTReader :: ReaderT (Maybe Scope) m a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadTrans,
            MonadMask, MonadThrow, MonadFail, MonadCatch)

deriving instance MonadBaseControl IO m => MonadBaseControl IO (TraceT m)
deriving instance MonadBase IO m => MonadBase IO (TraceT m)
deriving instance MonadError e m => MonadError e (TraceT m)

instance MonadReader r m => MonadReader r (TraceT m) where
  ask = lift ask
  local f (TraceT (ReaderT g)) = TraceT $ ReaderT $ \r -> local f $ g r

instance MonadTransControl TraceT where
  type StT TraceT m = StT (ReaderT (Maybe Scope)) m
  liftWith = defaultLiftWith TraceT traceTReader
  restoreT = defaultRestoreT TraceT

instance (MonadBaseControl IO m, MonadIO m) => MonadTrace (TraceT m) where
  trace bldr (TraceT reader) = TraceT $ ask >>= \case
    Nothing -> reader
    Just parentScope -> do
      let
        mbParentSpn = scopeSpan parentScope
        mbParentCtx = spanContext <$> mbParentSpn
        mbTraceID = contextTraceID <$> mbParentCtx
      spanID <- maybe (liftIO randomSpanID) pure $ builderSpanID bldr
      traceID <- maybe (liftIO randomTraceID) pure $ builderTraceID bldr <|> mbTraceID
      sampling <- case builderSamplingPolicy bldr of
        Just policy -> liftIO policy
        Nothing -> pure $ fromMaybe Never (spanSamplingDecision <$> mbParentSpn)
      let
        baggages = fromMaybe Map.empty $ contextBaggages <$> mbParentCtx
        ctx = Context traceID spanID (builderBaggages bldr `Map.union` baggages)
        spn = Span (builderName bldr) ctx (builderReferences bldr) sampling
        tracer = scopeTracer parentScope
      if spanIsSampled spn
        then do
          tagsTV <- newTVarIO $ builderTags bldr
          logsTV <- newTVarIO []
          startTV <- newTVarIO Nothing -- To detect whether an exception happened during span setup.
          let
            scope = Scope tracer (Just spn) (Just tagsTV) (Just logsTV)
            run = do
              start <- liftIO $ getPOSIXTime
              atomically $ do
                writeTVar startTV (Just start)
                modifyTVar' (tracerPendingCount tracer) (+1)
              local (const $ Just scope) reader
            cleanup = do
              end <- liftIO $ getPOSIXTime
              atomically $ readTVar startTV >>= \case
                Nothing -> pure () -- The action was interrupted before the span was pending.
                Just start -> do
                  modifyTVar' (tracerPendingCount tracer) (\n -> n - 1)
                  tags <- readTVar tagsTV
                  logs <- sortOn (\(t, k, _) -> (t, k)) <$> readTVar logsTV
                  writeSBQueue (tracerQueue tracer) (Sample spn tags logs start (end - start))
          run `finally` cleanup
        else local (const $ Just $ Scope tracer (Just spn) Nothing Nothing) reader

  activeSpan = TraceT $ asks (>>= scopeSpan)

  addSpanEntry key (TagValue val) = TraceT $ do
    mbTV <- asks (>>= scopeTags)
    ReaderT $ \_ -> for_ mbTV $ \tv -> atomically $ modifyTVar' tv $ Map.insert key val
  addSpanEntry key (LogValue val mbTime)  = TraceT $ do
    mbTV <- asks (>>= scopeLogs)
    ReaderT $ \_ -> for_ mbTV $ \tv -> do
      time <- maybe (liftIO getPOSIXTime) pure mbTime
      atomically $ modifyTVar' tv ((time, key, val) :)

-- | Trace an action, sampling its generated spans. This method is thread-safe and can be used to
-- trace multiple actions concurrently.
--
-- Unless you are implementing a custom span publication backend, you should not need to call this
-- method explicitly. Instead, prefer to use the backend's functionality directly (e.g.
-- 'Monitor.Tracing.Zipkin.run' for Zipkin). To ease debugging in certain cases,
-- 'Monitor.Tracing.Local.collectSpanSamples' is also available.
--
-- See 'runTraceT'' for a variant which allows discarding spans.
runTraceT :: TraceT m a -> Tracer -> m a
runTraceT actn tracer = runTraceT' actn (Just tracer)

-- | Maybe trace an action. If the tracer is 'Nothing', no spans will be published.
runTraceT' :: TraceT m a -> Maybe Tracer -> m a
runTraceT' (TraceT reader) mbTracer =
  let scope = fmap (\tracer -> Scope tracer Nothing Nothing Nothing) mbTracer
  in runReaderT reader scope

{-# LANGUAGE FlexibleContexts #-}
-- | This module provides convenience functionality to debug traces locally. For production use,
-- prefer alternatives, e.g. "Monitor.Tracing.Zipkin".
module Monitor.Tracing.Local (
  collectSpanSamples
) where

import Control.Monad.Trace

import Control.Concurrent.STM.Lifted (atomically, readTVar)
import Control.Monad.Fix (fix)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.IORef (modifyIORef', newIORef, readIORef)

-- | Runs a 'TraceT' action, returning any collected samples alongside its output. The samples are
-- sorted chronologically by completion time (e.g. the head is the first span to complete).
--
-- Spans which start before the action returns are guaranteed to be collected, even if they complete
-- after (in this case collection will block until their completion). More precisely,
-- 'collectSpanSamples' will return the first time there are no pending spans after the action is
-- done. For example:
--
-- > collectSpanSamples $ rootSpan alwaysSampled "parent" $ do
-- >   forkIO $ childSpan "child" $ threadDelay 2000000 -- Asynchronous 2 second child span.
-- >   threadDelay 1000000 -- Returns after one second, but the child span will still be sampled.
collectSpanSamples :: (MonadBaseControl IO m, MonadIO m) => TraceT m a -> m (a, [Sample])
collectSpanSamples actn = do
  tracer <- newTracer
  rv <- runTraceT actn tracer
  ref <- liftIO $ newIORef []
  let
    addSample spl = liftIO $ modifyIORef' ref (spl:)
    samplesTC = spanSamples tracer
    pendingTV = pendingSpanCount tracer
  liftIO $ fix $ \loop -> do
    (mbSample, pending) <- atomically $ (,) <$> readSBQueue samplesTC <*> readTVar pendingTV
    case mbSample of
      (x:xs) -> mapM_ addSample (x:xs) >> loop
      [] | pending > 0 -> do
        toAdd <- liftIO (atomically $ readSBQueue samplesTC)
        mapM_ addSample toAdd
        loop
      _ -> pure ()
  spls <- reverse <$> liftIO (readIORef ref)
  pure (rv, spls)

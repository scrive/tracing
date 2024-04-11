{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Effectful.Trace
    (
        -- * Effect
        Trace

        -- * Handler
    ,   runTrace
    ,   runNoTrace

        -- * Zipkin utilities
    ,   runZipkinTrace
    ,   withZipkin

        -- * Reexport
    ,  module Monitor.Tracing
    ) where

import Control.Monad.Catch (finally)
import Control.Monad.Trace
import Control.Monad.Trace.Class
import Effectful
import Effectful.Dispatch.Dynamic
import Effectful.Reader.Static
import Monitor.Tracing
import Monitor.Tracing.Zipkin (Zipkin(zipkinTracer), Settings, new, publish)

-- | Provides the ability to send traces to a backend.
data Trace :: Effect where
  Trace :: Builder -> m a -> Trace m a
  ActiveSpan :: Trace m (Maybe Span)
  AddSpanEntry :: Key -> Value -> Trace m ()

type instance DispatchOf Trace = Dynamic

-- | Run the 'Trace' effect.
--
-- /Note:/ this is the @effectful@ version of 'runTraceT'.
runTrace
  :: IOE :> es
  => Tracer
  -> Eff (Trace : es) a
  -> Eff es a
runTrace tracer = reinterpret (runReader initialScope) $ \env -> \case
  Trace bldr action -> localSeqUnlift env $ \unlift -> do
    scope <- ask
    withSeqEffToIO $ \runInIO -> do
      traceWith bldr scope $ \childScope -> do
        runInIO . local (const childScope) $ unlift action
  ActiveSpan -> asks scopeSpan
  AddSpanEntry key value -> do
    scope <- ask
    liftIO $ addSpanEntryWith (Just scope) key value
  where
    initialScope = Scope tracer Nothing Nothing Nothing

-- | Run the 'Trace' effect with a dummy handler that does no tracing.
runNoTrace :: IOE :> es => Eff (Trace : es) a -> Eff es a
runNoTrace = interpret $ \env -> \case
  Trace _ action -> localSeqUnlift env $ \unlift -> unlift action
  ActiveSpan -> pure Nothing
  AddSpanEntry _ _ -> pure ()

-- | Convenience method to start a 'Zipkin', run an action, and publish all
-- spans before returning.
withZipkin :: (IOE :> es) => Settings -> (Zipkin -> Eff es a) -> Eff es a
withZipkin settings f = do
  zipkin <- liftIO $ new settings
  f zipkin `finally` publish zipkin

-- | Runs a 'TraceT' action, sampling spans appropriately. Note that this method does not publish
-- spans on its own; to do so, either call 'publish' manually or specify a positive
-- 'settingsPublishPeriod' to publish in the background.
runZipkinTrace :: (IOE :> es) => Zipkin -> Eff (Trace : es) a -> Eff es a
runZipkinTrace zipkin = runTrace (zipkinTracer zipkin)

-- | Orphan, canonical instance.
instance Trace :> es => MonadTrace (Eff es) where
  trace bldr action = send (Trace bldr action)
  activeSpan = send ActiveSpan
  addSpanEntry key value = send (AddSpanEntry key value)

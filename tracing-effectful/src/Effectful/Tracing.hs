{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Effectful.Tracing
    (
        -- * Effect
        Trace
    
        -- * Handler
    ,   runTracing
    ,   runTracing'

        -- * Zipkin utilities
    ,   runZipkinTracing
    ,   withZipkin

        -- * Reexport
    ,  module Monitor.Tracing
    ) where

import Effectful
import Effectful.Dispatch.Static
import Control.Monad.Trace
import Control.Monad.Trace.Class
import Control.Monad.Catch (finally)
import Monitor.Tracing
import Monitor.Tracing.Zipkin (Zipkin(zipkinTracer), Settings, new, publish)

-- | Provides the ability to send traces to a backend
data Trace :: Effect

type instance DispatchOf Trace = Static WithSideEffects
newtype instance StaticRep Trace = Trace (Maybe Scope)

-- | Run the 'Tracing' effect.
--
-- /Note:/ this is the @effectful@ version of 'runTracingT'.
runTracing
  :: IOE :> es
  => Eff (Trace : es) a
  -> Tracer
  -> Eff es a
runTracing actn = runTracing'  actn . pure

runTracing' 
  :: IOE :> es
  => Eff (Trace : es) a
  -> Maybe Tracer
  -> Eff es a
runTracing' actn mbTracer = 
  let scope = fmap (\tracer -> Scope tracer Nothing Nothing Nothing) mbTracer
  in evalStaticRep (Trace scope) actn

-- | Convenience method to start a 'Zipkin', run an action, and publish all spans before returning.
withZipkin :: (IOE :> es) => Settings -> (Zipkin -> Eff es a) -> Eff es a
withZipkin settings f = do
  zipkin <- unsafeEff_ $ new settings
  f zipkin `finally` publish zipkin

-- | Runs a 'TraceT' action, sampling spans appropriately. Note that this method does not publish
-- spans on its own; to do so, either call 'publish' manually or specify a positive
-- 'settingsPublishPeriod' to publish in the background.
runZipkinTracing :: (IOE :> es) => Eff (Trace : es) a -> Zipkin -> Eff es a
runZipkinTracing actn zipkin = runTracing actn (zipkinTracer zipkin)

-- | Orphan, canonical instance.
instance Trace :> es => MonadTrace (Eff es) where
  trace bldr f = getStaticRep >>= \case
    Trace Nothing -> f
    Trace (Just scope) -> unsafeSeqUnliftIO $ \unlift -> do
      traceWith2 bldr scope $ \childScope -> do
        unlift $ localStaticRep (const . Trace $ Just childScope) f

  activeSpan = do
    Trace scope <- getStaticRep
    pure (scope >>= scopeSpan)

  addSpanEntry key value = do
    Trace scope <- getStaticRep
    unsafeEff_ $ addSpanEntryWith2 scope key value

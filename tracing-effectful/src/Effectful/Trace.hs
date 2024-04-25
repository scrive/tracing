{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Effectful.Trace
    (
        -- * Effect
        Trace

        -- * Handler
    ,   runTrace
    ,   runNoTrace

        -- * Reexport
    ,  module Monitor.Tracing
    ) where

import Control.Monad.Trace
import Control.Monad.Trace.Class
import Effectful
import Effectful.Dispatch.Dynamic
import Effectful.Reader.Static
import Monitor.Tracing

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

-- | Orphan, canonical instance.
instance Trace :> es => MonadTrace (Eff es) where
  trace bldr action = send (Trace bldr action)
  activeSpan = send ActiveSpan
  addSpanEntry key value = send (AddSpanEntry key value)

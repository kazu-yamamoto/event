{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module GHC.Event.Thread (
  ensureIOManagerIsRunning
  , getSystemEventManager
  , shutdownManagers
  , threadWaitRead
  , threadWaitWrite
  , threadWaitReadSTM
  , threadWaitWriteSTM
  , closeFdWith
  , threadDelay
  , registerDelay
  ) where


import GHC.Base
import Data.Maybe (Maybe(..))
import System.Posix.Types (Fd)
import GHC.MVar (MVar, newEmptyMVar, newMVar, putMVar, takeMVar)
import qualified GHC.Event.Internal as E
import qualified GHC.Event.Manager as NE
import qualified GHC.Event.SequentialManager as SM
import qualified GHC.Event.IntMap as IM
import Foreign.C.Error
import Control.Exception
import Data.IORef
import GHC.Conc.Sync
import System.IO.Unsafe
import Control.Monad (sequence_, forM, zipWithM_)
import GHC.Num
import Foreign.Ptr (Ptr)
import GHC.IOArray

shutdownManagers :: IO ()
shutdownManagers =
  do sequence_ [do mmgr <- readIOArray eventManagerRef i
                   case mmgr of
                     Nothing -> return ()
                     Just (_,mgr) -> SM.shutdown mgr
               | i <- [0,1..numCapabilities-1]
               ]
     mtmgr <- getTimerManager
     case mtmgr of
       Nothing -> return ()
       Just tmgr -> NE.shutdown tmgr

getSystemEventManager :: IO SM.EventManager
getSystemEventManager =
  do t <- myThreadId
     (cap, _) <- threadCapability t
     Just (_,mgr) <- readIOArray eventManagerRef cap
     return mgr

getTimerManager :: IO (Maybe NE.EventManager)
getTimerManager = readIORef timerManagerRef

eventManagerRef :: IOArray Int (Maybe (ThreadId,SM.EventManager))
eventManagerRef = unsafePerformIO $ do
  mgrs <- newIOArray (0, numCapabilities) Nothing
  sharedCAF mgrs getOrSetSystemEventThreadIOManagerArray
{-# NOINLINE eventManagerRef #-}

eventManagerLock :: MVar ()
eventManagerLock = unsafePerformIO $ do
  em <- newMVar ()
  sharedCAF em getOrSetSystemEventThreadEventManagerLock
{-# NOINLINE eventManagerLock #-}

timerManagerRef :: IORef (Maybe NE.EventManager)
timerManagerRef = unsafePerformIO $ do
  em <- newIORef Nothing
  sharedCAF em getOrSetSystemEventThreadEventManagerStore
{-# NOINLINE timerManagerRef #-}

{-# NOINLINE timerManagerThreadRef #-}
timerManagerThreadRef :: MVar (Maybe ThreadId)
timerManagerThreadRef = unsafePerformIO $ do
   m <- newMVar Nothing
   sharedCAF m getOrSetSystemEventThreadIOManagerThreadStore

ensureTimerManagerIsRunning :: IO ()
ensureTimerManagerIsRunning
  | not threaded = return ()
  | otherwise =
      modifyMVar_ timerManagerThreadRef $ \old -> do
         let createTimerMgr =  do !tmgr <- NE.new
                                  writeIORef timerManagerRef (Just tmgr)
                                  !tid <- forkIO (NE.loop tmgr)
                                  labelThread tid "TimerManager"
                                  return (Just tid)
         case old of
           Nothing -> createTimerMgr
           st@(Just t) -> do
             s <- threadStatus t
             case s of
               ThreadFinished -> createTimerMgr
               ThreadDied     -> do
                 -- Sanity check: if the thread has died, there is a chance
                 -- that event manager is still alive. This could happend during
                 -- the fork, for example. In this case we should clean up
                 -- open pipes and everything else related to the event manager.
                 -- See #4449
                 mem <- readIORef timerManagerRef
                 _ <- case mem of
                   Nothing -> return ()
                   Just em -> NE.cleanup em
                 createTimerMgr
               _other         -> return st

ensureIOManagerIsRunning :: IO ()
ensureIOManagerIsRunning
  | not threaded = return ()
  | otherwise =
    do ensureTimerManagerIsRunning
       modifyMVar_ eventManagerLock $ \() -> do
         sequence_ [ do m <- readIOArray eventManagerRef i
                        case m of
                          Nothing -> create i
                          Just (tid,mgr) -> do
                            s <- threadStatus tid
                            case s of
                              ThreadFinished -> create i
                              ThreadDied     -> SM.cleanup mgr >> create i
                              _other         -> return ()
                   | i <- [0,1..numCapabilities-1]]
         return ()
  where
    create i = do mgr <- SM.new
                  t   <- forkOn i (SM.loop mgr)
                  labelThread t "IOManager"
                  writeIOArray eventManagerRef i (Just (t,mgr))


threadWaitSTM :: NE.Event -> Fd -> IO (STM ())
threadWaitSTM evt fd = mask_ $ do
  m <- newTVarIO Nothing
  !mgr <- getSystemEventManager
  _ <- SM.registerFd_ mgr (\_ ev -> atomically (writeTVar m (Just ev))) fd evt
  return (do mevt <- readTVar m
             case mevt of
               Nothing -> retry
               Just ev ->
                 if ev `E.eventIs` E.evtClose
                 then throwSTM $ errnoToIOError "threadWait" eBADF Nothing Nothing
                 else return ()
         )

threadWaitReadSTM :: Fd -> IO (STM ())
threadWaitReadSTM = threadWaitSTM SM.evtRead
{-# INLINE threadWaitReadSTM #-}

threadWaitWriteSTM :: Fd -> IO (STM ())
threadWaitWriteSTM = threadWaitSTM SM.evtWrite
{-# INLINE threadWaitWriteSTM #-}


threadWait :: NE.Event -> Fd -> IO ()
threadWait evt fd = mask_ $ do
  m <- newEmptyMVar
  !mgr <- getSystemEventManager
  _ <- SM.registerFd_ mgr (\_ ev -> putMVar m ev) fd evt
  evt' <- takeMVar m
  if evt' `E.eventIs` E.evtClose
    then ioError $ errnoToIOError "threadWait" eBADF Nothing Nothing
    else return ()

threadWaitRead :: Fd -> IO ()
threadWaitRead = threadWait SM.evtRead
{-# INLINE threadWaitRead #-}

threadWaitWrite :: Fd -> IO ()
threadWaitWrite = threadWait SM.evtWrite
{-# INLINE threadWaitWrite #-}

{- Somewhat complicated to avoid some race conditions:
(a) grab tables (and hence locks, always in ascending order from 0..n-1);
(b) close the fd
(c) delete callbacks, call them, and put the updated table into the table variables
TODO: Explain why this is needed.
TODO: Harden this: what happens if there is an exception (synchronous or asynchronous)? Need to restore the locks properly.
-}
closeFdWith :: (Fd -> IO ())        -- ^ Action that performs the close.
            -> Fd                   -- ^ File descriptor to close.
            -> IO ()
closeFdWith close fd = do
  tableVars <- forM [0,1..numCapabilities-1] (getCallbackTableVar fd)
  tables    <- forM tableVars takeMVar
  close fd
  zipWithM_ (\tableVar table -> SM.closeFd_ table fd >>= putMVar tableVar) tableVars tables

getCallbackTableVar :: Fd -> Int -> IO (MVar (IM.IntMap [SM.FdData]))
getCallbackTableVar fd cap =
  do Just (_,!mgr) <- readIOArray eventManagerRef cap
     return (SM.callbackTableVar mgr fd)


threadDelay :: Int -> IO ()
threadDelay usecs = mask_ $ do
  Just mgr <- getTimerManager
  m <- newEmptyMVar
  reg <- NE.registerTimeout mgr usecs (putMVar m ())
  takeMVar m `onException` NE.unregisterTimeout mgr reg

registerDelay :: Int -> IO (TVar Bool)
registerDelay usecs = do
  t <- atomically $ newTVar False
  Just mgr <- getTimerManager
  _ <- NE.registerTimeout mgr usecs . atomically $ writeTVar t True
  return t



foreign import ccall unsafe "getOrSetSystemEventThreadEventManagerStore"
    getOrSetSystemEventThreadEventManagerStore :: Ptr a -> IO (Ptr a)

foreign import ccall unsafe "getOrSetSystemEventThreadIOManagerThreadStore"
    getOrSetSystemEventThreadIOManagerThreadStore :: Ptr a -> IO (Ptr a)


foreign import ccall unsafe "getOrSetSystemEventThreadEventManagerLock"
    getOrSetSystemEventThreadEventManagerLock :: Ptr a -> IO (Ptr a)

foreign import ccall unsafe "getOrSetSystemEventThreadIOManagerArray"
    getOrSetSystemEventThreadIOManagerArray :: Ptr a -> IO (Ptr a)

foreign import ccall unsafe "rtsSupportsBoundThreads" threaded :: Bool

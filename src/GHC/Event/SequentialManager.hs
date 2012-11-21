{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE BangPatterns
           , CPP
           , ExistentialQuantification
           , NoImplicitPrelude
           , RecordWildCards
           , TypeSynonymInstances
           , FlexibleInstances
  #-}

module GHC.Event.SequentialManager
    ( -- * Types
      EventManager

      -- * Creation
    , new
    , newWith
    , newDefaultBackend

      -- * Running
    , finished
    , loop
    , step
    , shutdown
    , cleanup
    , wakeManager

      -- * Registering interest in I/O events
    , Event
    , evtRead
    , evtWrite
    , IOCallback
    , FdKey
    , registerFd_
    , registerFd
    , closeFd
    , closeFd_
    , callbackTableVar
    , FdData
    ) where

#include "EventConfig.h"

------------------------------------------------------------------------
-- Imports

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (finally)
import Control.Monad ((=<<), forM_, liftM, sequence, sequence_, when)
import Data.IORef (IORef, atomicModifyIORef, mkWeakIORef, newIORef, readIORef,
                   writeIORef)
import Data.Maybe (Maybe(..))
import Data.Monoid (mappend, mconcat, mempty)
import GHC.Base
import GHC.Conc.Signal (runHandlers)
import GHC.Conc.Sync (yield)
import GHC.List (filter, replicate)
import GHC.Num (Num(..))
import GHC.Real ((/), fromIntegral, mod)
import GHC.Show (Show(..))
import GHC.Event.Clock (getCurrentTime)
import GHC.Event.Control
import GHC.Event.Internal (Backend, Event, evtClose, evtRead, evtWrite,
                           Timeout(..))
import System.Posix.Types (Fd)
import GHC.Event.Unique (Unique, UniqueSource, newSource, newUnique)
import qualified GHC.Event.IntMap as IM
import qualified GHC.Event.Internal as I
import qualified GHC.Event.PSQ as Q
import GHC.Arr

#if defined(HAVE_KQUEUE)
import qualified GHC.Event.KQueue as KQueue
#elif defined(HAVE_EPOLL)
import qualified GHC.Event.EPoll  as EPoll
#elif defined(HAVE_POLL)
import qualified GHC.Event.Poll   as Poll
#else
# error not implemented for this operating system
#endif


arraySize :: Int
arraySize = 32

hashFd :: Fd -> Int
hashFd fd = fromIntegral fd `mod` arraySize
{-# INLINE hashFd #-}

callbackTableVar :: EventManager -> Fd -> MVar (IM.IntMap [FdData])
callbackTableVar mgr fd = emFds mgr ! hashFd fd


#if defined(HAVE_EPOLL)
------------------------------------------------------------------------
-- Types

data FdData = FdData {
      fdEvents    :: {-# UNPACK #-} !Event
    , _fdCallback :: !IOCallback
    }

-- | A file descriptor registration cookie.
type FdKey = Fd

-- | Callback invoked on I/O events.
type IOCallback = Fd -> Event -> IO ()

data State = Created
           | Running
           | Dying
           | Finished
             deriving (Eq, Show)

-- | The event manager state.
data EventManager = EventManager
    { emBackend      :: !Backend
    , emFds          :: {-# UNPACK #-} !(Array Int (MVar (IM.IntMap [FdData])))
    , emState        :: {-# UNPACK #-} !(IORef State)
    , emControl      :: {-# UNPACK #-} !Control
    }

------------------------------------------------------------------------
-- Creation

handleControlEvent :: EventManager -> Fd -> Event -> IO ()
handleControlEvent mgr fd _evt = do
  msg <- readControlMessage (emControl mgr) fd
  case msg of
    CMsgWakeup      -> return ()
    CMsgDie         -> writeIORef (emState mgr) Finished
    CMsgSignal fp s -> runHandlers fp s

newDefaultBackend :: IO Backend
newDefaultBackend = EPoll.new

-- | Create a new event manager.
new :: IO EventManager
new = newWith =<< newDefaultBackend

newWith :: Backend -> IO EventManager
newWith be = do
  fdVars <- sequence $ replicate arraySize (newMVar IM.empty)
  let !iofds = listArray (0, arraySize - 1) fdVars
  ctrl <- newControl
  state <- newIORef Created
  _ <- mkWeakIORef state $ do
               st <- atomicModifyIORef state $ \s -> (Finished, s)
               when (st /= Finished) $ do
                 I.delete be
                 closeControl ctrl
  let mgr = EventManager { emBackend = be
                         , emFds = iofds
                         , emState = state
                         , emControl = ctrl
                         }
  _ <- registerControlFd mgr (controlReadFd ctrl) evtRead
  _ <- registerControlFd mgr (wakeupReadFd ctrl) evtRead
  return mgr

  
  
-- | Asynchronously shuts down the event manager, if running.
shutdown :: EventManager -> IO ()
shutdown mgr = do
  state <- atomicModifyIORef (emState mgr) $ \s -> (Dying, s)
  when (state == Running) $ sendDie (emControl mgr)

finished :: EventManager -> IO Bool
finished mgr = (== Finished) `liftM` readIORef (emState mgr)

cleanup :: EventManager -> IO ()
cleanup EventManager{..} = do
  writeIORef emState Finished
  I.delete emBackend
  closeControl emControl

------------------------------------------------------------------------
-- Event loop

-- | Start handling events.  This function loops until told to stop,
-- using 'shutdown'.
--
-- /Note/: This loop can only be run once per 'EventManager', as it
-- closes all of its control resources when it finishes.
loop :: EventManager -> IO ()
loop mgr@EventManager{..} = do
  state <- atomicModifyIORef emState $ \s -> case s of
    Created -> (Running, s)
    _       -> (s, s)
  case state of
    Created -> go `finally` cleanup mgr
    Dying   -> cleanup mgr
    _       -> do cleanup mgr
                  error $ "GHC.Event.SequentialManager.loop: state is already " ++
                      show state
 where
  go = do running <- step mgr
          when running (yield >> go) 

step :: EventManager -> IO Bool
step mgr@EventManager{..} = do
  waitForIO 
  state <- readIORef emState
  state `seq` return (state == Running)
 where
  waitForIO = 
    do n <- I.pollNonBlock emBackend (onFdEvent mgr)
       when (n <= 0) (do yield
                         n <- I.pollNonBlock emBackend (onFdEvent mgr)
                         when (n <= 0) (I.poll emBackend Forever (onFdEvent mgr) >> return ())
                     )


------------------------------------------------------------------------
-- Registering interest in I/O events


-- | Register interest in the given events, without waking the event
-- manager thread.  The 'Bool' return value indicates whether the
-- event manager ought to be woken.
registerControlFd :: EventManager -> Fd -> Event -> IO ()
registerControlFd mgr fd evs = I.modifyFd (emBackend mgr) fd mempty evs



-- | Register interest in the given events, without waking the event
-- manager thread.  
registerFd_ :: EventManager -> IOCallback -> Fd -> Event -> IO ()
registerFd_ mgr@EventManager{..} cb fd evs = do
  modifyMVar_ (emFds ! hashFd fd)
     (\oldMap -> 
       case IM.insertWith (++) (fromIntegral fd) [FdData evs cb] oldMap of
         (Nothing,   n) -> do I.modifyFdOnce emBackend fd evs
                              return n
         (Just prev, n) -> do I.modifyFdOnce emBackend fd (combineEvents evs prev) 
                              return n
     )
{-# INLINE registerFd_ #-}


-- | @registerFd mgr cb fd evs@ registers interest in the events @evs@
-- on the file descriptor @fd@.  @cb@ is called for each event that
-- occurs.  Returns a cookie that can be handed to 'unregisterFd'.
registerFd :: EventManager -> IOCallback -> Fd -> Event -> IO ()
registerFd mgr cb fd evs = do
  registerFd_ mgr cb fd evs
  wakeManager mgr
{-# INLINE registerFd #-}


-- | Wake up the event manager.
wakeManager :: EventManager -> IO ()
wakeManager mgr = sendWakeup (emControl mgr)

eventsOf :: [FdData] -> Event
eventsOf = mconcat . map fdEvents

combineEvents :: Event -> [FdData] -> Event
combineEvents ev [fdd] = mappend ev (fdEvents fdd)
combineEvents ev fdds = mappend ev (eventsOf fdds)
{-# INLINE combineEvents #-}


-- | Close a file descriptor in a race-safe way.
closeFd :: EventManager -> Fd -> IO ()
closeFd mgr fd = do
  do mfds <- 
       modifyMVar (emFds mgr ! hashFd fd)
       (\oldMap -> 
         case IM.delete (fromIntegral fd) oldMap of
           (Nothing,  _)       -> return (oldMap, Nothing)
           (Just fds, !newMap) -> return (newMap, Just fds)
       )
     case mfds of
       Nothing -> return ()
       Just fds -> do forM_ fds $ \(FdData ev cb) -> cb fd (ev `mappend` evtClose)

closeFd_ :: IM.IntMap [FdData] -> Fd -> IO (IM.IntMap [FdData])
closeFd_ oldMap fd = do
  case IM.delete (fromIntegral fd) oldMap of
    (Nothing,  _)       -> return oldMap
    (Just fds, !newMap) -> do forM_ fds $ \(FdData ev cb) -> cb fd (ev `mappend` evtClose)
                              return newMap



------------------------------------------------------------------------
-- Utilities

-- | Call the callbacks corresponding to the given file descriptor.
onFdEvent :: EventManager -> Fd -> Event -> IO ()
onFdEvent mgr@EventManager{..} fd evs = 
  if (fd == controlReadFd emControl || fd == wakeupReadFd emControl)
  then handleControlEvent mgr fd evs
  else do mcbs <- modifyMVar (emFds ! hashFd fd)
                   (\oldMap -> return (case IM.delete (fromIntegral fd) oldMap of { (mcbs,x) -> (x,mcbs) }))
          case mcbs of
            Just cbs -> forM_ cbs $ \(FdData _ cb) -> cb fd evs
            Nothing  -> return ()

#else


------------------------------------------------------------------------
-- Types

data FdData = FdData {
      fdKey       :: {-# UNPACK #-} !FdKey
    , fdEvents    :: {-# UNPACK #-} !Event
    , _fdCallback :: !IOCallback
    }

-- | A file descriptor registration cookie.
data FdKey = FdKey {
      keyFd     :: {-# UNPACK #-} !Fd
    , keyUnique :: {-# UNPACK #-} !Unique
    } deriving (Eq, Show)

-- | Callback invoked on I/O events.
type IOCallback = FdKey -> Event -> IO ()

data State = Created
           | Running
           | Dying
           | Finished
             deriving (Eq, Show)

-- | The event manager state.
data EventManager = EventManager
    { emBackend      :: !Backend
    , emFds          :: {-# UNPACK #-} !(Array Int (MVar (IM.IntMap [FdData])))
    , emState        :: {-# UNPACK #-} !(IORef State)
    , emUniqueSource :: {-# UNPACK #-} !UniqueSource      
    , emControl      :: {-# UNPACK #-} !Control
    }

------------------------------------------------------------------------
-- Creation

handleControlEvent :: EventManager -> FdKey -> Event -> IO ()
handleControlEvent mgr reg _evt = do
  msg <- readControlMessage (emControl mgr) (keyFd reg)
  case msg of
    CMsgWakeup      -> return ()
    CMsgDie         -> writeIORef (emState mgr) Finished
    CMsgSignal fp s -> runHandlers fp s

newDefaultBackend :: IO Backend
newDefaultBackend = EPoll.new

-- | Create a new event manager.
new :: IO EventManager
new = newWith =<< newDefaultBackend

newWith :: Backend -> IO EventManager
newWith be = do
  fdVars <- sequence $ replicate arraySize (newMVar IM.empty)
  let !iofds = listArray (0, arraySize - 1) fdVars
  ctrl <- newControl
  state <- newIORef Created
  us <- newSource  
  _ <- mkWeakIORef state $ do
               st <- atomicModifyIORef state $ \s -> (Finished, s)
               when (st /= Finished) $ do
                 I.delete be
                 closeControl ctrl
  let mgr = EventManager { emBackend = be
                         , emFds = iofds
                         , emState = state
                         , emUniqueRef = uref
                         , emControl = ctrl
                         }
  _ <- registerFdPersistent_ mgr (handleControlEvent mgr) (controlReadFd ctrl) evtRead
  _ <- registerFdPersistent_ mgr (handleControlEvent mgr) (wakeupReadFd ctrl) evtRead
  return mgr

-- | Asynchronously shuts down the event manager, if running.
shutdown :: EventManager -> IO ()
shutdown mgr = do
  state <- atomicModifyIORef (emState mgr) $ \s -> (Dying, s)
  when (state == Running) $ sendDie (emControl mgr)

finished :: EventManager -> IO Bool
finished mgr = (== Finished) `liftM` readIORef (emState mgr)

cleanup :: EventManager -> IO ()
cleanup EventManager{..} = do
  writeIORef emState Finished
  I.delete emBackend
  closeControl emControl

------------------------------------------------------------------------
-- Event loop

-- | Start handling events.  This function loops until told to stop,
-- using 'shutdown'.
--
-- /Note/: This loop can only be run once per 'EventManager', as it
-- closes all of its control resources when it finishes.
loop :: EventManager -> IO ()
loop mgr@EventManager{..} = do
  state <- atomicModifyIORef emState $ \s -> case s of
    Created -> (Running, s)
    _       -> (s, s)
  case state of
    Created -> go `finally` cleanup mgr
    Dying   -> cleanup mgr
    _       -> do cleanup mgr
                  error $ "GHC.Event.Manager.loop: state is already " ++
                      show state
 where
  go = do running <- step mgr
          when running (yield >> go) 

step :: EventManager -> IO Bool
step mgr@EventManager{..} = do
  waitForIO 
  state <- readIORef emState
  state `seq` return (state == Running)
 where
  waitForIO = 
    do n <- I.pollNonBlock emBackend (onFdEvent mgr)
       when (n <= 0) (do yield
                         n <- I.pollNonBlock emBackend (onFdEvent mgr)
                         when (n <= 0) (I.poll emBackend Forever (onFdEvent mgr) >> return ())
                     )


------------------------------------------------------------------------
-- Registering interest in I/O events


-- | Register interest in the given events, without waking the event
-- manager thread.  The 'Bool' return value indicates whether the
-- event manager ought to be woken.
registerFdPersistent_ :: EventManager -> IOCallback -> Fd -> Event
                         -> IO (FdKey, Bool)
registerFdPersistent_ mgr@EventManager{..} cb fd evs = do
  u <- newUnique emUniqueSource
  let !reg  = FdKey fd u
      !fd'  = fromIntegral fd
      !fdd = FdData reg evs cb
  modify <- 
    modifyMVar (emFds ! hashFd fd)
     (\oldMap -> 
       let (!newMap, (oldEvs, newEvs)) =
             case IM.insertWith (++) fd' [fdd] oldMap of
               (Nothing,   n) -> (n, (mempty, evs))
               (Just prev, n) -> (n, pairEvents prev newMap fd')
           !modify = oldEvs /= newEvs               
       in do when modify $ I.modifyFd emBackend fd oldEvs newEvs
             return (newMap, modify)
     )
  return (reg, modify)
{-# INLINE registerFdPersistent_ #-}


-- | Register interest in the given events, without waking the event
-- manager thread.  The 'Bool' return value indicates whether the
-- event manager ought to be woken.
registerFd_ :: EventManager -> IOCallback -> Fd -> Event
            -> IO (FdKey, Bool)
registerFd_ mgr cb fd evs = registerFdPersistent_ mgr (\reg ev -> unregisterFd_ mgr reg >> cb reg ev) fd evs            
{-# INLINE registerFd_ #-}

-- | @registerFd mgr cb fd evs@ registers interest in the events @evs@
-- on the file descriptor @fd@.  @cb@ is called for each event that
-- occurs.  Returns a cookie that can be handed to 'unregisterFd'.
registerFd :: EventManager -> IOCallback -> Fd -> Event -> IO FdKey
registerFd mgr cb fd evs = do
  (r,wake) <- registerFd_ mgr cb fd evs
  when wake $ wakeManager mgr
  return r
{-# INLINE registerFd #-}


-- | Wake up the event manager.
wakeManager :: EventManager -> IO ()
wakeManager mgr = sendWakeup (emControl mgr)

eventsOf :: [FdData] -> Event
eventsOf = mconcat . map fdEvents

pairEvents :: [FdData] -> IM.IntMap [FdData] -> Int -> (Event, Event)
pairEvents prev m fd = let l = eventsOf prev
                           r = case IM.lookup fd m of
                                 Nothing  -> mempty
                                 Just fds -> eventsOf fds
                       in (l, r)

-- | Drop a previous file descriptor registration, without waking the
-- event manager thread.  The return value indicates whether the event
-- manager ought to be woken.
unregisterFd_ :: EventManager -> FdKey -> IO Bool
unregisterFd_ EventManager{..} (FdKey fd u) =
  do (oldEvs, newEvs) <- 
       modifyMVar (emFds ! hashFd fd)
       (\oldMap -> 
         let dropReg cbs = case filter ((/= u) . keyUnique . fdKey) cbs of
                               []   -> Nothing
                               cbs' -> Just cbs'
             fd' = fromIntegral fd
             (!newMap, (oldEvs, newEvs)) =
               case IM.updateWith dropReg fd' oldMap of
                 (Nothing,   _)    -> (oldMap, (mempty, mempty))
                 (Just prev, newm) -> (newm, pairEvents prev newm fd')
         in return (newMap, (oldEvs, newEvs))
       )
     let !modify = oldEvs /= newEvs
     when modify $ I.modifyFd emBackend fd oldEvs newEvs
     return modify


-- | Drop a previous file descriptor registration.
unregisterFd :: EventManager -> FdKey -> IO ()
unregisterFd mgr reg = do
  wake <- unregisterFd_ mgr reg
  when wake $ wakeManager mgr

-- | Close a file descriptor in a race-safe way.
closeFd :: EventManager -> Fd -> IO ()
closeFd mgr fd = do
  do mfds <- 
       modifyMVar (emFds mgr ! hashFd fd)
       (\oldMap -> 
         case IM.delete (fromIntegral fd) oldMap of
           (Nothing,  _)       -> return (oldMap, Nothing)
           (Just fds, !newMap) -> return (newMap, Just fds)
       )
     case mfds of
       Nothing -> return ()
       Just fds -> do wakeManager mgr
                      forM_ fds $ \(FdData reg ev cb) -> cb reg (ev `mappend` evtClose)

closeFd_ :: IM.IntMap [FdData] -> Fd -> IO (IM.IntMap [FdData])
closeFd_ oldMap fd = do
  case IM.delete (fromIntegral fd) oldMap of
    (Nothing,  _)       -> return oldMap
    (Just fds, !newMap) -> do forM_ fds $ \(FdData ev cb) -> cb (ev `mappend` evtClose)
                              return newMap

------------------------------------------------------------------------
-- Utilities

-- | Call the callbacks corresponding to the given file descriptor.
onFdEvent :: EventManager -> Fd -> Event -> IO ()
onFdEvent mgr fd evs = do
  fdMap <- readMVar (emFds mgr ! hashFd fd)
  case IM.lookup (fromIntegral fd) fdMap of
      Just cbs -> forM_ cbs $ \(FdData reg ev cb) ->
                       when (evs `I.eventIs` ev) (cb reg evs)
      Nothing  -> return ()


#endif






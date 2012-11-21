{-# LANGUAGE Trustworthy #-}

-- ----------------------------------------------------------------------------
-- | This module provides scalable event notification for file
-- descriptors and timeouts.
--
-- This module should be considered GHC internal.
--
-- ----------------------------------------------------------------------------

module GHC.Event
    ( -- * Types
      EventManager

      -- * Creation
    , new
    , getSystemEventManager

      -- * Running
    , loop

    -- ** Stepwise running
    , step
    , shutdown

      -- * Registering interest in I/O events
    , Event
    , evtRead
    , evtWrite
    , IOCallback
    , registerFd
    , closeFd

    ) where

import GHC.Event.SequentialManager
import GHC.Event.Thread (getSystemEventManager)


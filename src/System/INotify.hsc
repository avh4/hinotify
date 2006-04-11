-----------------------------------------------------------------------------
-- |
-- Module      :  System.INotify
-- Copyright   :  (c) Lennart Kolmodin 2006
-- License     :  GPL
-- Maintainer  :  kolmodin@dtek.chalmers.se
-- Stability   :  experimental
-- Portability :  hc portable, x86 linux only
--
-- A Haskell binding to INotify.
-- See <http://www.kernel.org/pub/linux/kernel/people/rml/inotify/>.
--
-----------------------------------------------------------------------------

module System.INotify
    ( inotify_init
    , inotify_add_watch
    , inotify_rm_watch
    , INotify
    , WatchDescriptor
    , Event(..)
    , EventVariety(..)
    ) where

#include "inotify.h"

import Control.Monad
import Control.Concurrent
import Control.Concurrent.MVar
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as Map
import GHC.Handle
import Foreign.C
import Foreign.Marshal
import Foreign.Ptr
import Foreign.Storable
import System.Directory
import System.IO
import System.IO.Error
import System.Posix.Internals

import System.INotify.Masks

type FD = CInt
type WD = CInt
type Cookie = CUInt
type Masks = CUInt

type EventMap = Map WD (Event -> IO ())
type WDEvent = (WD, Event)

data INotify = INotify Handle FD (MVar EventMap)
data WatchDescriptor = WatchDescriptor Handle WD deriving Eq

data FDEvent = FDEvent WD Masks Cookie (Maybe String) deriving Show

data Event = 
    -- | A file was accessed. @Accessed isDirectory file@
      Accessed 
        Bool
        (Maybe FilePath)
    -- | A file was modified. @Modified isDiroctory file@
    | Modified    Bool (Maybe FilePath)
    -- | A files attributes where changed. @Attributes isDirectory file@
    | Attributes  Bool (Maybe FilePath)
    -- | A file was closed. @Closed isDirectory wasWritable file@
    | Closed
        Bool
        Bool
        (Maybe FilePath)
    -- | A file was opened. @Opened isDirectory maybeFilePath@
    | Opened
        Bool
        (Maybe FilePath)
    -- | A file was moved away from the watched dir. @MovedFrom isDirectory from@
    | MovedOut Bool FilePath
    -- | A file was moved into the watched dir. MovedTo isDirectory to@
    | MovedIn  Bool FilePath
    -- | The watched file was moved. @MovedSelf isDirectory@
    | MovedSelf Bool
    -- | A file was created. @Created isDirectory file@
    | Created Bool FilePath
    -- | A file was deleted. @Deleted isDirectory file@
    | Deleted Bool FilePath
    -- | The file watched was deleted.
    | DeletedSelf
    -- | The file watched was unmounted.
    | Unmounted
    -- | The queue overflowed.
    | QOverflow
    | Ignored
    | Unknown FDEvent
    deriving Show

data EventVariety
    = Access
    | Modify
    | Attrib
    | Close
    | CloseWrite
    | CloseNoWrite
    | Open
    | Move
    | MoveIn
    | MoveOut
    | MoveSelf
    | Create
    | Delete
    | DeleteSelf
    | OnlyDir
    | NoSymlink
    | MaskAdd
    | OneShot
    | AllEvents
    deriving Eq

instance Show INotify where
    show (INotify _ fd _) =
        showString "<inotify fd=" . 
        shows fd $ ">"

instance Show WatchDescriptor where
    show (WatchDescriptor _ wd) = showString "<wd=" . shows wd $ ">"

inotify_init :: IO INotify
inotify_init = do
    fd <- c_inotify_init
    em <- newMVar Map.empty
    let desc = showString "<inotify handle, fd=" . shows fd $ ">"
    h <- openFd (fromIntegral fd) (Just Stream) False{-is_socket-} desc ReadMode True{-binary-}
    inotify_start_thread h em
    return (INotify h fd em)

inotify_add_watch :: INotify -> [EventVariety] -> FilePath -> (Event -> IO ()) -> IO WatchDescriptor
inotify_add_watch (INotify h fd em) masks fp cb = do
    is_dir <- doesDirectoryExist fp
    when (not is_dir) $ do
        file_exist <- doesFileExist fp
        when (not file_exist) $ do
            -- it's not a directory, and not a file...
            -- it doesn't exist
            ioError $ mkIOError doesNotExistErrorType
                                "can't watch what isn't there"
                                Nothing 
                                (Just fp)
    let mask = joinMasks (map eventVarietyToMask masks)
    em' <- takeMVar em
    wd <- withCString fp $ \fp_c ->
              c_inotify_add_watch (fromIntegral fd) fp_c mask
    let event = \e -> do
            when (OneShot `elem` masks) $
              modifyMVar_ em (return . Map.delete wd)
            cb e
    putMVar em (Map.insert wd event em')
    return (WatchDescriptor h wd)
    where
    eventVarietyToMask ev =
        case ev of
            Access -> inAccess
            Modify -> inModify
            Attrib -> inAttrib
            Close -> inClose
            CloseWrite -> inCloseWrite
            CloseNoWrite -> inCloseNowrite
            Open -> inOpen
            Move -> inMove
            MoveIn -> inMovedTo
            MoveOut -> inMovedFrom
            MoveSelf -> inMoveSelf
            Create -> inCreate
            Delete -> inDelete
            DeleteSelf-> inDeleteSelf
            OneShot -> inOneshot
            AllEvents -> inAllMask

inotify_rm_watch :: INotify -> WatchDescriptor -> IO ()
inotify_rm_watch (INotify _ fd em) (WatchDescriptor _ wd) = do
    c_inotify_rm_watch (fromIntegral fd) wd
    modifyMVar_ em (return . Map.delete wd)

read_events :: Handle -> IO [WDEvent]
read_events h = 
    let maxRead = 16385 in
    allocaBytes maxRead $ \buffer -> do
        hWaitForInput h (-1)  -- wait forever
        r <- hGetBufNonBlocking h buffer maxRead
        read_events' buffer r
    where
    read_events' :: Ptr a -> Int -> IO [WDEvent]
    read_events' _ r |  r <= 0 = return []
    read_events' ptr r = do
        wd     <- (#peek struct inotify_event, wd)     ptr :: IO CInt
        mask   <- (#peek struct inotify_event, mask)   ptr :: IO CUInt
        cookie <- (#peek struct inotify_event, cookie) ptr :: IO CUInt
        len    <- (#peek struct inotify_event, len)    ptr :: IO CUInt
        nameM  <- if len == 0
                    then return Nothing
                    else fmap Just $ peekCString ((#ptr struct inotify_event, name) ptr)
        let event_size = (#size struct inotify_event) + (fromIntegral len) 
            event = interprete (FDEvent wd mask cookie nameM)
        rest <- read_events' (ptr `plusPtr` event_size) (r - event_size)
        return (event:rest)
    interprete :: FDEvent 
               -> WDEvent
    interprete fdevent@(FDEvent wd _ _ _)
        = (wd, interprete' fdevent)
    interprete' fdevent@(FDEvent _ mask cookie nameM)
        | isSet inAccess     = Accessed isDir nameM
        | isSet inModify     = Modified isDir nameM
        | isSet inAttrib     = Attributes isDir nameM
        | isSet inClose      = Closed isDir (isSet inCloseWrite) nameM
        | isSet inOpen       = Opened isDir nameM
        | isSet inMovedFrom  = MovedOut isDir name
        | isSet inMovedTo    = MovedIn isDir name
        | isSet inMoveSelf   = MovedSelf isDir
        | isSet inCreate     = Created isDir name
        | isSet inDelete     = Deleted isDir name
        | isSet inDeleteSelf = DeletedSelf
        | isSet inUnmount    = Unmounted
        | isSet inQOverflow  = QOverflow
        | isSet inIgnored    = Ignored
        | otherwise          = Unknown fdevent
        where
        isDir = isSet inIsdir
        isSet bits = maskIsSet bits mask
        name = fromJust nameM
       
inotify_start_thread :: Handle -> MVar EventMap -> IO ()
inotify_start_thread h em = do
    chan_events <- newChan
    forkIO (dispatcher chan_events)
    forkIO (start_thread chan_events)
    return ()
    where
    start_thread :: Chan [WDEvent] -> IO ()
    start_thread chan_events = do
        events <- read_events h
        writeChan chan_events events
        start_thread chan_events
    dispatcher :: Chan [WDEvent] -> IO ()
    dispatcher chan_events = do
        events <- readChan chan_events
        mapM_ runHandler events
        dispatcher chan_events
    runHandler :: WDEvent -> IO ()
    runHandler (wd, event) = do 
        handlers <- readMVar em
        let handlerM = Map.lookup wd handlers
        case handlerM of
          Nothing -> putStrLn "runHandler: couldn't find handler" -- impossible?
                                                                  -- no.  qoverflow has wd=-1
          Just handler -> handler event
        

-- TODO:
-- Until I get the compilation right, this is a workaround.
-- The preferred way is to used the commented out code, but I can't get it
-- to link. As a consequence, the library only works for x86 linux.
-- Loading package HINotify-0.1 ... linking ... ghc-6.4.1: /usr/local/lib/HINotify-0.1/ghc-6.4.1/HSHINotify-0.1.o: unknown symbol `inotify_rm_watch'


{-
foreign import ccall unsafe "inotify-syscalls.h inotify_init" c_inotify_init :: IO CInt
foreign import ccall unsafe "inotify-syscalls.h inotify_add_watch" c_inotify_add_watch :: CInt -> CString -> CUInt -> IO CInt
foreign import ccall unsafe "inotify-syscalls.h inotify_rm_watch" c_inotify_rm_watch :: CInt -> CInt -> IO CInt
-}

c_inotify_init :: IO CInt
c_inotify_init = syscall1 __NR_inotify_init

c_inotify_add_watch :: CInt -> CString -> CUInt -> IO CInt
c_inotify_add_watch = syscall4 __NR_inotify_add_watch

c_inotify_rm_watch :: CInt -> CInt -> IO CInt
c_inotify_rm_watch = syscall3 __NR_inotify_rm_watch

__NR_inotify_init      = 291
__NR_inotify_add_watch = 292
__NR_inotify_rm_watch  = 293

foreign import ccall "syscall" syscall1 :: CInt -> IO CInt
foreign import ccall "syscall" syscall3 :: CInt -> CInt -> CInt -> IO CInt
foreign import ccall "syscall" syscall4 :: CInt -> CInt -> CString -> CUInt -> IO CInt

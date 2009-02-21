module System.Posix.Daemonize 
    (daemonize, Logger, Program(..), defaultProgram) where

{- originally based on code from 
   http://sneakymustard.com/2008/12/11/haskell-daemons -}

import Control.Exception
import System
import System.Directory
import System.Exit
import System.Posix
import System.Posix.Syslog

-- | The simplest possible interface to syslog.
type Logger = String -> IO ()

-- | A program is defined by three things: start action, which is
--   called when the daemon starts; stop action, which is a TERM
--   signal handler; and reload, which is a SIGHUP signal handler.
data Program = 
    Program { start  :: IO (),
              stop   :: IO (),
              reload :: IO () }

-- | Default program does nothing.
defaultProgram :: Program
defaultProgram = Program pass pass pass

-- | Turns a program into a UNIX daemon, doing the necessary daemon
--   rain dance, providing it with the simplest possible interface to
--   the system log, writing a /var/run/$name.pid file, which
--   guarantees that only one instance is running, dropping
--   priviledges to $name:$name or daemon:daemon if $name is not
--   available, and handling start/stop/restart/reload command-line
--   arguments. The stop argument does a soft kill first, and if that
--   fails for 1 second, does a hard kill.
daemonize :: (Logger -> IO Program) -> IO ()
daemonize program = do name <- getProgName
                       args <- getArgs
                       process name args
    where

      process name ["start"]   = startd name
      process name ["stop"]    = 
          do pid <- pidRead name
             let ifdo x f = x >>= \x -> if x then f else pass
             case pid of
               Nothing  -> pass
               Just pid -> 
                   (do signalProcess sigTERM pid
                       usleep (10^6)
                       ifdo (pidLive pid) $ 
                            do usleep (3*10^6)
                               ifdo (pidLive pid) (signalProcess sigKILL pid))
                   `finally`
                   removeLink (pidFile name)

      process name ["reload"]  = 
          do pid <- pidRead name
             case pid of 
               Nothing  -> pass
               Just pid -> signalProcess sigHUP pid
      process name ["restart"] = process name ["stop"] >>
                                 process name ["start"]
      process name _ = 
          putStrLn $ "usage: " ++ name ++ " {start|stop|restart|reload}"

      startd name = pidExists name >>= decide
          where

            decide False = 
                do setFileCreationMask 0 
                   forkProcess p2
                   exitSuccess
            decide True = 
                error "PID file exists. Process already running?"
                exitFailure

            p2 = do createSession
                    pid <- forkProcess p3
                    pidWrite name pid
                    exitSuccess        

            p3 = withSyslog name [] DAEMON $ 
                do setCurrentDirectory "/"
                   p <- program (syslog Notice)
                   installHandler sigPIPE Ignore Nothing
                   installHandler sigHUP (Catch $ reload p) Nothing
                   installHandler sigTERM (Catch $ stop p) Nothing
                   dropPriviledges name
                   devNullFd <- 
                       openFd "/dev/null" ReadWrite Nothing defaultFileFlags
                   mapM_ (closeAndDupTo devNullFd) $
                             [stdInput, stdOutput, stdError]
                   forever (syslog Error) (start p)
                       where
                         closeAndDupTo dupFd fd = closeFd fd >> dupTo dupFd fd

            forever log prog = 
                prog `finally` restart where
                    restart = 
                        do log "STOPPED UNEXPECTEDLY. RESTARTING IN 5 SECONDS..."
                           usleep (5 * 10^6)
                           forever log prog

getGroupID :: String -> IO (Maybe GroupID)
getGroupID group = 
    try (fmap groupID (getGroupEntryForName group)) >>= return . f where
        f :: Either IOException GroupID -> Maybe GroupID
        f (Left e)    = Nothing
        f (Right gid) = Just gid

getUserID :: String -> IO (Maybe UserID)
getUserID user = 
    try (fmap userID (getUserEntryForName user)) >>= return . f where
        f :: Either IOException UserID -> Maybe UserID
        f (Left e)    = Nothing
        f (Right uid) = Just uid

dropPriviledges :: String -> IO ()
dropPriviledges name = 
    do Just ud <- getUserID "daemon"
       Just gd <- getGroupID "daemon"
       u       <- fmap (maybe ud id) $ getUserID name
       g       <- fmap (maybe gd id) $ getGroupID name
       setGroupID g 
       setUserID u

pidFile:: String -> String
pidFile name = "/var/run/" ++ name ++ ".pid"

pidExists :: String -> IO Bool
pidExists name = fileExist (pidFile name)

pidRead :: String -> IO (Maybe CPid)
pidRead name = pidExists name >>= choose where
    choose True  = fmap (Just . read) $ readFile (pidFile name)
    choose False = return Nothing

pidWrite :: String -> CPid -> IO ()
pidWrite name pid =
    writeFile (pidFile name) (show pid)

pidLive :: CPid -> IO Bool
pidLive pid = 
    (getProcessPriority pid >> return True) `Control.Exception.catch` f where
        f :: IOException -> IO Bool
        f _ = return False
        
pass :: IO () 
pass = return ()
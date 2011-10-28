{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE BangPatterns               #-}

module Snap.Snaplet.Internal.Initializer
( addPostInitHook
  , addPostInitHookBase
  , toSnapletHook
  , bracketInit
  , modifyCfg
  , nestSnaplet
  , embedSnaplet
  , makeSnaplet
  , nameSnaplet
  , onUnload
  , addRoutes
  , wrapHandlers
  , runInitializer
  , runSnaplet
  , combineConfig
  , serveSnaplet
  , printInfo
  ) where

import           Prelude hiding ((.), id, catch)
import           Control.Category
import           Control.Concurrent.MVar
import           Control.Exception (SomeException)
import           Control.Monad
import           Control.Monad.CatchIO hiding (Handler)
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Trans.Writer hiding (pass)
import           Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import           Data.Configurator
import           Data.IORef
import           Data.Maybe
import           Data.Lens.Lazy
import           Data.Text (Text)
import qualified Data.Text as T
import           Snap.Http.Server
import           Snap.Core
import           Snap.Util.GZip
import           System.Directory
import           System.Directory.Tree
import           System.FilePath.Posix
import           System.IO

import qualified Snap.Snaplet.Internal.LensT as LT
import qualified Snap.Snaplet.Internal.Lensed as L
import           Snap.Snaplet.Internal.Types


------------------------------------------------------------------------------
-- | 'get' for InitializerState.
iGet :: Initializer b v (InitializerState b)
iGet = Initializer $ LT.getBase


------------------------------------------------------------------------------
-- | 'modify' for InitializerState.
iModify :: (InitializerState b -> InitializerState b) -> Initializer b v ()
iModify f = Initializer $ do
    b <- LT.getBase
    LT.putBase $ f b


------------------------------------------------------------------------------
-- | 'gets' for InitializerState.
iGets :: (InitializerState b -> a) -> Initializer b v a
iGets f = Initializer $ do
    b <- LT.getBase
    return $ f b


------------------------------------------------------------------------------
-- | Converts a plain hook into a Snaplet hook.
toSnapletHook :: (v -> IO v) -> (Snaplet v -> IO (Snaplet v))
toSnapletHook f (Snaplet cfg val) = do
    val' <- f val
    return $! Snaplet cfg val'


------------------------------------------------------------------------------
-- | Adds an IO action that modifies the current snaplet state to be run at
-- the end of initialization on the state that was created.  This makes it
-- easier to allow one snaplet's state to be modified by another snaplet's
-- initializer.  A good example of this is when a snaplet has templates that
-- define its views.  The Heist snaplet provides the 'addTemplates' function
-- which allows other snaplets to set up their own templates.  'addTemplates'
-- is implemented using this function.
addPostInitHook :: (v -> IO v) -> Initializer b v ()
addPostInitHook = addPostInitHook' . toSnapletHook


addPostInitHook' :: (Snaplet v -> IO (Snaplet v)) -> Initializer b v ()
addPostInitHook' h = do
    h' <- upHook h
    addPostInitHookBase h'


------------------------------------------------------------------------------
addPostInitHookBase :: (Snaplet b -> IO (Snaplet b))
                    -> Initializer b v ()
addPostInitHookBase = Initializer . lift . tell . Hook


------------------------------------------------------------------------------
-- | Helper function for transforming hooks.
upHook :: (Snaplet v -> IO (Snaplet v))
       -> Initializer b v (Snaplet b -> IO (Snaplet b))
upHook h = Initializer $ do
    l <- ask
    return $ upHook' l h


------------------------------------------------------------------------------
-- | Helper function for transforming hooks.
upHook' :: (Lens b a) -> (a -> IO a) -> b -> IO b
upHook' l h b = do
    v <- h (getL l b)
    return $ setL l v b


------------------------------------------------------------------------------
-- | Modifies the Initializer's SnapletConfig.
modifyCfg :: (SnapletConfig -> SnapletConfig) -> Initializer b v ()
modifyCfg f = iModify $ modL curConfig $ \c -> f c


------------------------------------------------------------------------------
-- | If a snaplet has a filesystem presence, this function creates and copies
-- the files if they dont' already exist.
setupFilesystem :: Maybe (IO FilePath)
                -- ^ The directory where the snaplet's reference files are
                -- stored.  Nothing if the snaplet doesn't come with any files
                -- that need to be installed.
                -> FilePath
                -- ^ Directory where the files should be copied.
                -> Initializer b v ()
setupFilesystem Nothing _ = return ()
setupFilesystem (Just getSnapletDataDir) targetDir = do
    exists <- liftIO $ doesDirectoryExist targetDir
    unless exists $ do
        printInfo "...setting up filesystem"
        liftIO $ createDirectoryIfMissing True targetDir
        srcDir <- liftIO getSnapletDataDir
        (_ :/ dTree) <- liftIO $ readDirectoryWith B.readFile srcDir
        let (topDir,snapletId) = splitFileName targetDir
        _ <- liftIO $ writeDirectoryWith B.writeFile
               (topDir :/ dTree { name = snapletId })
        return ()


------------------------------------------------------------------------------
-- | All snaplet initializers must be wrapped in a call to @makeSnaplet@,
-- which handles standardized housekeeping common to all snaplets.
-- Common usage will look something like
-- this:
--
-- @
-- fooInit :: SnapletInit b Foo
-- fooInit = makeSnaplet \"foo\" \"An example snaplet\" Nothing $ do
--     -- Your initializer code here
--     return $ Foo 42
-- @
--
-- Note that you're writing your initializer code in the Initializer monad,
-- and makeSnaplet converts it into an opaque SnapletInit type.  This allows
-- us to use the type system to ensure that the API is used correctly.
makeSnaplet :: Text
       -- ^ A default id for this snaplet.  This is only used when the
       -- end-user has not already set an id using the nameSnaplet function.
       -> Text
       -- ^ A human readable description of this snaplet.
       -> Maybe (IO FilePath)
       -- ^ The path to the directory holding the snaplet's reference
       -- filesystem content.  This will almost always be the directory
       -- returned by Cabal's getDataDir command, but it has to be passed in
       -- because it is defined in a package-specific import.  Setting this
       -- value to Nothing doesn't preclude the snaplet from having files in
       -- in the filesystem, it just means that they won't be copied there
       -- automatically.
       -> Initializer b v v
       -- ^ Snaplet initializer.
       -> SnapletInit b v
makeSnaplet snapletId desc getSnapletDataDir m = SnapletInit $ do
    modifyCfg $ \c -> if isNothing $ _scId c
        then setL scId (Just snapletId) c else c
    sid <- iGets (T.unpack . fromJust . _scId . _curConfig)
    topLevel <- iGets _isTopLevel
    unless topLevel $ modifyCfg $ \c -> setL scFilePath
        (_scFilePath c </> "snaplets" </> sid) c
    iModify (setL isTopLevel False)
    modifyCfg $ modL scUserConfig (subconfig (T.pack sid))
    modifyCfg $ setL scDescription desc
    cfg <- iGets _curConfig
    printInfo $ T.pack $ concat
      ["Initializing "
      ,sid
      ," @ /"
      ,B.unpack $ buildPath $ _scRouteContext cfg
      ]

    -- This has to happen here because it needs to be after scFilePath is set
    -- up but before snaplet.cfg is read.
    setupFilesystem getSnapletDataDir (_scFilePath cfg)

    liftIO $ addToConfig [Optional (_scFilePath cfg </> "snaplet.cfg")]
                         (_scUserConfig cfg)
    mkSnaplet m


------------------------------------------------------------------------------
-- | Internal function that gets the SnapletConfig out of the initializer
-- state and uses it to create a (Snaplet a).
mkSnaplet :: Initializer b v a -> Initializer b v (Snaplet a)
mkSnaplet m = do
    res <- m
    cfg <- iGets _curConfig
    return $ Snaplet cfg res


------------------------------------------------------------------------------
-- | Brackets an initializer computation, restoring curConfig after the
-- computation returns.
bracketInit :: Initializer b v a -> Initializer b v a
bracketInit m = do
    s <- iGet
    res <- m
    iModify (setL curConfig (_curConfig s))
    return res


------------------------------------------------------------------------------
-- | Handles modifications to InitializerState that need to happen before a
-- snaplet is called with either nestSnaplet or embedSnaplet.
setupSnapletCall :: ByteString -> Initializer b v ()
setupSnapletCall rte = do
    curId <- iGets (fromJust . _scId . _curConfig)
    modifyCfg (modL scAncestry (curId:))
    modifyCfg (modL scId (const Nothing))
    unless (B.null rte) $ modifyCfg (modL scRouteContext (rte:))


------------------------------------------------------------------------------
-- | Runs another snaplet's initializer and returns the initialized Snaplet
-- value.  Calling an initializer with nestSnaplet gives the nested snaplet
-- access to the same base state that the current snaplet has.  This makes it
-- possible for the child snaplet to make use of functionality provided by
-- sibling snaplets.
nestSnaplet :: ByteString
            -- ^ The root url for all the snaplet's routes.  An empty string
            -- gives the routes the same root as the parent snaplet's routes.
            -> (Lens v (Snaplet v1))
            -- ^ Lens identifying the snaplet
            -> SnapletInit b v1
            -- ^ The initializer function for the subsnaplet.
            -> Initializer b v (Snaplet v1)
nestSnaplet rte l (SnapletInit snaplet) = with l $ bracketInit $ do
    setupSnapletCall rte
    snaplet


------------------------------------------------------------------------------
-- | Runs another snaplet's initializer and returns the initialized Snaplet
-- value.  The difference between this and nestSnaplet is the first type
-- parameter in the third argument.  The \"v1 v1\" makes the child snaplet
-- think that it is top-level, which means that it will not be able to use
-- functionality provided by snaplets included above it in the snaplet tree.
-- This strongly isolates the child snaplet, and allows you to eliminate the b
-- type variable.  The embedded snaplet can still get functionality from other
-- snaplets, but only if it nests or embeds the snaplet itself.
embedSnaplet :: ByteString
             -- ^ The root url for all the snaplet's routes.  An empty string
             -- gives the routes the same root as the parent snaplet's routes.
             --
             -- NOTE: Because of the stronger isolation provided by
             -- embedSnaplet, you should be more careful about using an empty
             -- string here.
             -> (Lens v (Snaplet v1))
             -- ^ Lens identifying the snaplet
             -> SnapletInit v1 v1
             -- ^ The initializer function for the subsnaplet.
             -> Initializer b v (Snaplet v1)
embedSnaplet rte l (SnapletInit snaplet) = bracketInit $ do
    curLens <- getLens
    setupSnapletCall rte
    chroot rte (subSnaplet l . curLens) snaplet


------------------------------------------------------------------------------
-- | Changes the base state of an initializer.
chroot :: ByteString
       -> (Lens (Snaplet b) (Snaplet v1))
       -> Initializer v1 v1 a
       -> Initializer b v a
chroot rte l (Initializer m) = do
    curState <- iGet
    ((a,s), (Hook hook)) <- liftIO $ runWriterT $ LT.runLensT m id $
        curState {
          _handlers = [],
          _hFilter = id
        }
    let handler = chrootHandler l $ _hFilter s $ route $ _handlers s
    iModify $ modL handlers (++[(rte,handler)])
            . setL cleanup (_cleanup s)
    addPostInitHookBase $ upHook' l hook
    return a


------------------------------------------------------------------------------
-- | Changes the base state of a handler.
chrootHandler :: (Lens (Snaplet v) (Snaplet b'))
              -> Handler b' b' a -> Handler b v a
chrootHandler l (Handler h) = Handler $ do
    s <- get
    (a, s') <- liftSnap $ L.runLensed h id (getL l s)
    modify $ setL l s'
    return a


------------------------------------------------------------------------------
-- | Sets a snaplet's name.  All snaplets have a default name set by the
-- snaplet author.  This function allows you to override that name.  You will
-- have to do this if you have more than one instance of the same kind of
-- snaplet because snaplet names must be unique.  This function must
-- immediately surround the snaplet's initializer.  For example:
--
-- @fooState <- nestSnaplet \"fooA\" $ nameSnaplet \"myFoo\" $ fooInit@
nameSnaplet :: Text
            -- ^ The snaplet name
            -> SnapletInit b v
            -- ^ The snaplet initializer function
            -> SnapletInit b v
nameSnaplet nm (SnapletInit m) = SnapletInit $
    modifyCfg (setL scId (Just nm)) >> m


------------------------------------------------------------------------------
-- | Adds routing to the current 'Handler'.  The new routes are merged with
-- the main routing section and take precedence over existing routing that was
-- previously defined.
addRoutes :: [(ByteString, Handler b v ())]
           -> Initializer b v ()
addRoutes rs = do
    l <- getLens
    ctx <- iGets (_scRouteContext . _curConfig)
    let rs' = map (\(r,h) -> (buildPath (r:ctx), withTop' l h)) rs
    iModify (\v -> modL handlers (++rs') v)


------------------------------------------------------------------------------
-- | Wraps the snaplet's routing.  This can be used to provide a snaplet that
-- does per-request setup and cleanup, but then dispatches to the rest of the
-- application.
wrapHandlers :: (Handler b v () -> Handler b v ()) -> Initializer b v ()
wrapHandlers f0 = do
    f <- mungeFilter f0
    iModify (\v -> modL hFilter (f.) v)


------------------------------------------------------------------------------
mungeFilter :: (Handler b v () -> Handler b v ())
            -> Initializer b v (Handler b b () -> Handler b b ())
mungeFilter f = do
    myLens <- Initializer ask
    return $ \m -> with' myLens $ f' m
  where
    f' (Handler m)       = f $ Handler $ L.withTop id m


------------------------------------------------------------------------------
-- | Attaches an unload handler to the snaplet.  The unload handler will be
-- called when the server shuts down, or is reloaded.
onUnload :: IO () -> Initializer b v ()
onUnload m = iModify (\v -> modL cleanup (m>>) v)


------------------------------------------------------------------------------
-- |
logInitMsg :: IORef Text -> Text -> IO ()
logInitMsg ref msg = atomicModifyIORef ref (\cur -> (cur `T.append` msg, ()))


------------------------------------------------------------------------------
-- | Initializers should use this function for all informational or error
-- messages to be displayed to the user.  On application startup they will be
-- sent to the console.  When executed from the reloader, they will be sent
-- back to the user in the HTTP response.
printInfo :: Text -> Initializer b v ()
printInfo msg = do
    logRef <- iGets _initMessages
    liftIO $ logInitMsg logRef (msg `T.append` "\n")


------------------------------------------------------------------------------
-- | Builds an IO reload action for storage in the SnapletState.
mkReloader :: MVar (Snaplet b)
           -> Initializer b b (Snaplet b)
           -> IO (Either String String)
mkReloader mvar i = do
    !res <- try $ runInitializer mvar i
    either bad good res
  where
    bad e = do
        return $ Left $ show (e :: SomeException)
    good (b,is) = do
        _ <- swapMVar mvar b
        msgs <- readIORef $ _initMessages is
        return $ Right $ T.unpack msgs


------------------------------------------------------------------------------
-- | Runs a top-level snaplet in the Snap monad.
runBase :: Handler b b a
        -> MVar (Snaplet b)
        -> Snap a
runBase (Handler m) mvar = do
    !b <- liftIO (readMVar mvar)
    (!a, _) <- L.runLensed m id b
    return $! a


------------------------------------------------------------------------------
-- |
runInitializer :: MVar (Snaplet b)
               -> Initializer b b (Snaplet b)
               -> IO (Snaplet b, InitializerState b)
runInitializer mvar b@(Initializer i) = do
    userConfig <- load [Optional "snaplet.cfg"]
    let builtinHandlers = [("/admin/reload", reloadSite)]
    let cfg = SnapletConfig [] "" Nothing "" userConfig [] (mkReloader mvar b)
    logRef <- newIORef ""
    ((res, s), (Hook hook)) <- runWriterT $ LT.runLensT i id $
        InitializerState True (return ()) builtinHandlers id cfg logRef
    res' <- hook res
    return (res', s)


------------------------------------------------------------------------------
-- | Given a Snaplet initializer, produce the set of messages generated during
-- initialization, a snap handler, and a cleanup action.
runSnaplet :: SnapletInit b b -> IO (Text, Snap (), IO ())
runSnaplet (SnapletInit b) = do
    snapletMVar <- newEmptyMVar
    (siteSnaplet, is) <- runInitializer snapletMVar b
    putMVar snapletMVar siteSnaplet

    msgs <- liftIO $ readIORef $ _initMessages is
    let handler = runBase (_hFilter is $ route $ _handlers is) snapletMVar

    return (msgs, handler, _cleanup is)


------------------------------------------------------------------------------
-- | Given a configuration and a snap handler, complete it and produce the
-- completed configuration as well as a new toplevel handler with things like
-- compression and a 500 handler set up.
combineConfig :: Config Snap a -> Snap () -> IO (Config Snap a, Snap ())
combineConfig config handler = do
    conf <- completeConfig config

    let catch500 = (flip catch $ fromJust $ getErrorHandler conf)
    let compress = if fromJust (getCompression conf)
                     then withCompression else id
    let site     = compress $ catch500 handler

    return (conf, site)


------------------------------------------------------------------------------
-- | Serves a top-level snaplet as a web application. Reads command-line
-- arguments. FIXME: document this.
serveSnaplet :: Config Snap a -> SnapletInit b b -> IO ()
serveSnaplet startConfig initializer = do
    (msgs, handler, doCleanup) <- runSnaplet initializer

    config       <- commandLineConfig startConfig
    (conf, site) <- combineConfig config handler
    let serve = simpleHttpServe conf

    liftIO $ hPutStrLn stderr $ T.unpack msgs
    _ <- try $ serve $ site
         :: IO (Either SomeException ())
    doCleanup



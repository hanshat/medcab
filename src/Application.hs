{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Application
    ( getApplicationDev
    , appMain
    , develMain
    , makeFoundation
    , makeLogWare
    -- * for DevelMain
    , getApplicationRepl
    , shutdownApp
    -- * for GHCI
    , handler
    , db
    ) where

import Control.Monad.Logger ( liftLoc, runLoggingT )
import Database.Persist.Sqlite
    ( runSqlPool, sqlDatabase, sqlPoolSize, createSqlitePoolWithConfig
    , ConnectionPoolConfig
      ( ConnectionPoolConfig, connectionPoolConfigStripes
      , connectionPoolConfigIdleTimeout, connectionPoolConfigSize
      )
    )
import Import
import Language.Haskell.TH.Syntax ( qLocation )
import Network.HTTP.Client.TLS ( getGlobalManager )
import Network.Wai (Middleware)
import Network.Wai.Middleware.Gzip
    ( gzip, GzipSettings (gzipFiles), GzipFiles (GzipCompress) )
import Network.Wai.Handler.Warp
    ( Settings, defaultSettings, defaultShouldDisplayException
    , runSettings, setHost, setOnException, setPort, getPort
    )
import Network.Wai.Middleware.RequestLogger
    ( Destination (Logger),IPAddrSource (..), OutputFormat (..)
    , destination, mkRequestLogger, outputFormat
    )
import System.Log.FastLogger
    ( defaultBufSize, newStdoutLoggerSet, toLogStr )

-- Import all relevant handler modules here.
-- Don't forget to add new modules to your cabal file!

import Handler.Doctors
    ( getDoctorsR, getDoctorPhotoR, getDoctorR
    )

import Handler.Records
    ( getRecordsR, getRecordR, getRecordNewR, postRecordsR, getRecordEditR
    , postRecordDeleR, postRecordR, getRecordMeasurementsR, getRecordMeasurementR
    , getRecordMeasurementNewR, postRecordMeasurementsR, getRecordMeasurementEditR
    , postRecordMeasurementDeleR, postRecordMeasurementR
    )

import Handler.Accounts
    ( getAccountPhotoR
    , getAccountEditR
    , getAccountsR
    , getAccountR
    , postAccountR
    , getAccountInfoR
    , getAccountInfoEditR
    , postAccountInfoR
    )
    
import Handler.Video ( getVideoR )
import Handler.Home ( getHomeR )

import Handler.Common
    ( getRobotsR, getFaviconR, getSitemapR, getWebAppManifestR )

import Handler.Resources (getDocsR)

import Handler.MedSigns
    ( getMedSignsR, getMedSignR, getMedSignAddR, postMedSignDeleR
    , getMedSignEditR, postMedSignsR, postMedSignR, getSignTagsR, getSignTagR
    , getSignTagAddR, getSignTagEditR, postSignTagDeleR, postSignTagsR
    , postSignTagR
    )

import Handler.Units
    ( getUnitsR, getUnitAddR, getUnitR, postUnitsR, getUnitEditR, postUnitR
    , postUnitDeleR, getQuantitiesR, getQuantityR, getQuantityAddR
    , postQuantitiesR, getQuantityEditR, postQuantityDeleR, postQuantityR
    , getQuantityUnitsR, getQuantityUnitCreateR, postQuantityUnitsR
    , getQuantityUnitR, getQuantityUnitEditR, postQuantityUnitDeleR
    , postQuantityUnitR
    )

import Handler.Staff
    ( getStaffR, getDoctorCreateR, getStaffPhotoR, postStaffR
    , getMemberR, postDoctorDeleR, getDoctorEditR, postMemberR
    , getDoctorSpecialtiesR, getDoctorSpecialtyCreateR, postDoctorSpecialtiesR
    , getSpecialistR, getSpecialistEditR, postSpecialistDeleR, postSpecialistR
    )

import Handler.Specialties
    ( getSpecialtiesR, postSpecialtiesR, getSpecialtyCreateR, getSpecialtyR
    , getSpecialtyEditR, postSpecialtyR, postSpecialtyDeleR
    , getSpecialtyDoctorsR, getSpecialtyDoctorR, postSpecialtyDoctorDeleR
    , getSpecialtyDoctorEditR, getSpecialtyDoctorCreateR, postSpecialtyDoctorsR
    , postSpecialtyDoctorR
    )

import Handler.Tokens
    ( getTokensR, postTokensR, getTokensHookR, postTokensClearR
    )

import Handler.Users
    ( getUsersR, getUserR, postUserDeleR, getUserEditR
    , getUserPhotoR, postUserR
    )
    
import Demo.DemoEn (fillDemoEn)
import Yesod.Auth.Email (saltPass)

-- This line actually creates our YesodDispatch instance. It is the second half
-- of the call to mkYesodData which occurs in Foundation.hs. Please see the
-- comments there for more details.
mkYesodDispatch "App" resourcesApp

-- | This function allocates resources (such as a database connection pool),
-- performs initialization and returns a foundation datatype value. This is also
-- the place to put your migrate statements to have automatic database
-- migrations handled by Yesod.
makeFoundation :: AppSettings -> IO App
makeFoundation appSettings = do
    -- Some basic initializations: HTTP connection manager, logger, and static
    -- subsite.
    appHttpManager <- getGlobalManager
    appLogger <- newStdoutLoggerSet defaultBufSize >>= makeYesodLogger
    appStatic <-
        (if appMutableStatic appSettings then staticDevel else static)
        (appStaticDir appSettings)

    -- We need a log function to create a connection pool. We need a connection
    -- pool to create our foundation. And we need our foundation to get a
    -- logging function. To get out of this loop, we initially create a
    -- temporary foundation without a real connection pool, get a log function
    -- from there, and then create the real foundation.
    let mkFoundation appConnPool = App {..}
        -- The App {..} syntax is an example of record wild cards. For more
        -- information, see:
        -- https://ocharles.org.uk/blog/posts/2014-12-04-record-wildcards.html
        tempFoundation = mkFoundation $ error "connPool forced in tempFoundation"
        logFunc = messageLoggerSource tempFoundation appLogger

    -- Create the database connection pool
    pool <- flip runLoggingT logFunc $ createSqlitePoolWithConfig
        (sqlDatabase $ appDatabaseConf appSettings)
        ConnectionPoolConfig { connectionPoolConfigStripes = 1
                             , connectionPoolConfigIdleTimeout = appIdleTimeout appSettings
                             , connectionPoolConfigSize = sqlPoolSize $ appDatabaseConf appSettings
                             }

    -- Perform database migration using our application's logging settings.
    flip runLoggingT logFunc $ flip runSqlPool pool $ do
        runMigration migrateAll
        
        superpass <- liftIO $ saltPass (appSuperuserPassword appSettings)
        insert_ User { userEmail = appSuperuserUsername appSettings
                     , userAuthType = UserAuthTypePassword
                     , userPassword = Just superpass
                     , userVerkey = Nothing
                     , userVerified = True
                     , userName = Just "Super User"
                     , userSuperuser = True
                     , userAdmin = True
                     }
        fillDemoEn

    -- Return the foundation
    return $ mkFoundation pool

-- | Convert our foundation to a WAI Application by calling @toWaiAppPlain@ and
-- applying some additional middlewares.
makeApplication :: App -> IO Application
makeApplication foundation = do
    logWare <- makeLogWare foundation
    -- Create the WAI application and apply middlewares
    appPlain <- toWaiAppPlain foundation
    return $ logWare $ defaultMiddlewaresNoLogging $ gzip def { gzipFiles = GzipCompress } appPlain

makeLogWare :: App -> IO Middleware
makeLogWare foundation =
    mkRequestLogger def
        { outputFormat =
            if appDetailedRequestLogging $ appSettings foundation
                then Detailed True
                else Apache
                        (if appIpFromHeader $ appSettings foundation
                            then FromFallback
                            else FromSocket)
        , destination = Logger $ loggerSet $ appLogger foundation
        }


-- | Warp settings for the given foundation value.
warpSettings :: App -> Settings
warpSettings foundation =
      setPort (appPort $ appSettings foundation)
    $ setHost (appHost $ appSettings foundation)
    $ setOnException (\_req e ->
        when (defaultShouldDisplayException e) $ messageLoggerSource
            foundation
            (appLogger foundation)
            $(qLocation >>= liftLoc)
            "yesod"
            LevelError
            (toLogStr $ "Exception from Warp: " ++ show e))
      defaultSettings

-- | For yesod devel, return the Warp settings and WAI Application.
getApplicationDev :: IO (Settings, Application)
getApplicationDev = do
    settings <- getAppSettings
    foundation <- makeFoundation settings
    wsettings <- getDevSettings $ warpSettings foundation
    app <- makeApplication foundation
    return (wsettings, app)

getAppSettings :: IO AppSettings
getAppSettings = loadYamlSettings [configSettingsYml] [] useEnv

-- | main function for use by yesod devel
develMain :: IO ()
develMain = develMainHelper getApplicationDev

-- | The @main@ function for an executable running this site.
appMain :: IO ()
appMain = do
    -- Get the settings from all relevant sources
    settings <- loadYamlSettingsArgs
        -- fall back to compile-time values, set to [] to require values at runtime
        [configSettingsYmlValue]

        -- allow environment variables to override
        useEnv

    -- Generate the foundation from the settings
    foundation <- makeFoundation settings

    -- Generate a WAI Application from the foundation
    app <- makeApplication foundation

    -- Run the application with Warp
    runSettings (warpSettings foundation) app


--------------------------------------------------------------
-- Functions for DevelMain.hs (a way to run the app from GHCi)
--------------------------------------------------------------
getApplicationRepl :: IO (Int, App, Application)
getApplicationRepl = do
    settings <- getAppSettings
    foundation <- makeFoundation settings
    wsettings <- getDevSettings $ warpSettings foundation
    app1 <- makeApplication foundation
    return (getPort wsettings, foundation, app1)

shutdownApp :: App -> IO ()
shutdownApp _ = return ()


---------------------------------------------
-- Functions for use in development with GHCi
---------------------------------------------

-- | Run a handler
handler :: Handler a -> IO a
handler h = getAppSettings >>= makeFoundation >>= flip unsafeHandler h

-- | Run DB queries
db :: ReaderT SqlBackend Handler a -> IO a
db = handler . runDB

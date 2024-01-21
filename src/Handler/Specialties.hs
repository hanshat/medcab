{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE OverloadedStrings #-}

module Handler.Specialties
  ( getSpecialtiesR
  , postSpecialtiesR
  , getSpecialtyCreateR
  , getSpecialtyR
  , getSpecialtyEditR
  , postSpecialtyR
  , postSpecialtyDeleR
  ) where

import Control.Monad (when, unless)
import Database.Esqueleto.Experimental
    ( Entity (entityVal), select, from, table, orderBy, asc, val, where_
    , (^.), (==.)
    , selectOne, isNothing_, just
    )
import Database.Persist (Entity (Entity), PersistStoreWrite (replace, delete))
import Handler.Material3 (md3textField, md3textareaField)
import Handler.Menu (menu)
import Model
    ( Specialty
      (Specialty, specialtyName, specialtyCode, specialtyDescr, specialtyGroup)
    , EntityField (SpecialtyName, SpecialtyId, SpecialtyGroup)
    , AvatarColor (AvatarColorLight), statusSuccess, SpecialtyId, statusError
    , Specialties (Specialties)
    )
import Foundation
    ( Handler, Widget
    , Route (DataR, AuthR, AccountR, AccountPhotoR, StaticR)
    , DataR
      ( SpecialtiesR, SpecialtyCreateR, SpecialtyR, SpecialtyEditR
      , SpecialtyDeleR
      )
    , AppMessage
      ( MsgSpecialties, MsgUserAccount, MsgNoSpecialtiesYet, MsgSignIn
      , MsgSignOut, MsgPhoto, MsgEdit, MsgSpecialty, MsgDescription
      , MsgCode, MsgName, MsgSave, MsgCancel, MsgRecordCreated, MsgTabs
      , MsgBack, MsgDele, MsgRecordEdited, MsgInvalidFormData, MsgRecordDeleted
      , MsgDeleteAreYouSure, MsgConfirmPlease, MsgSubspecialties, MsgDetails
      , MsgNoSubspecialtiesYet, MsgSubspecialty
      )
    )
import Settings (widgetFile)
import Settings.StaticFiles
    ( js_specialties_specialties_min_js, js_specialties_create_min_js
    , js_specialties_specialty_min_js, js_specialties_subspecialties_min_js
    )
import Text.Hamlet (Html)
import Yesod.Auth (Route (LoginR, LogoutR), maybeAuth)
import Yesod.Core
    ( Yesod (defaultLayout), newIdent, addScript, SomeMessage (SomeMessage)
    , getMessageRender, addMessageI, redirect, getMessages, whamlet, setUltDestCurrent
    )
import Yesod.Core.Widget (setTitleI)
import Yesod.Persist (YesodPersist (runDB), PersistStoreWrite (insert_))
import Yesod.Form.Functions (generateFormPost, mreq, mopt, runFormPost)
import Yesod.Form.Types
    ( MForm, FormResult (FormSuccess)
    , FieldSettings (FieldSettings, fsLabel, fsTooltip, fsId, fsName, fsAttrs)
    , FieldView (fvInput)
    )
import qualified Data.List.Safe as LS


postSpecialtyDeleR :: SpecialtyId -> Specialties -> Handler Html
postSpecialtyDeleR sid ps@(Specialties sids) = do

    specialty <- runDB $ selectOne $ do
        x <- from $ table @Specialty
        where_ $ x ^. SpecialtyId ==. val sid
        return x

    ((fr,fw),et) <- runFormPost formDelete
    case fr of
      FormSuccess () -> do
          runDB $ delete sid
          addMessageI statusSuccess MsgRecordDeleted
          redirect $ DataR $ SpecialtiesR ps
      _otherwise -> defaultLayout $ do
          setTitleI MsgSpecialty
          addMessageI statusError MsgInvalidFormData
          msgs <- getMessages
          addScript (StaticR js_specialties_specialty_min_js)
          idPanelDetails <- newIdent
          $(widgetFile "data/specialties/specialty")


formDelete :: Html -> MForm Handler (FormResult (), Widget)
formDelete extra = return (pure (),[whamlet|#{extra}|])


postSpecialtyR :: SpecialtyId -> Specialties -> Handler Html
postSpecialtyR sid ps@(Specialties sids) = do

    specialty <- runDB $ selectOne $ do
        x <- from $ table @Specialty
        where_ $ x ^. SpecialtyId ==. val sid
        return x

    ((fr,fw),et) <- runFormPost $ formSpecialty Nothing specialty

    case fr of
      FormSuccess r -> do
          runDB $ replace sid r { specialtyGroup = LS.last sids }
          addMessageI statusSuccess MsgRecordEdited
          redirect $ DataR (SpecialtyR sid ps)
      _otherwise -> defaultLayout $ do
          setTitleI MsgSpecialty
          addScript (StaticR js_specialties_create_min_js)
          $(widgetFile "data/specialties/edit")


getSpecialtyEditR :: SpecialtyId -> Specialties -> Handler Html
getSpecialtyEditR sid ps@(Specialties sids) = do

    specialty <- runDB $ selectOne $ do
        x <- from $ table @Specialty
        where_ $ x ^. SpecialtyId ==. val sid
        return x

    (fw,et) <- generateFormPost $ formSpecialty Nothing specialty
    defaultLayout $ do
        setTitleI MsgSpecialty
        addScript (StaticR js_specialties_create_min_js)
        $(widgetFile "data/specialties/edit")


getSpecialtyCreateR :: Specialties -> Handler Html
getSpecialtyCreateR ps@(Specialties sids) = do
    (fw,et) <- generateFormPost $ formSpecialty Nothing Nothing
    defaultLayout $ do
        setTitleI MsgSpecialty
        addScript (StaticR js_specialties_create_min_js)
        $(widgetFile "data/specialties/create")


formSpecialty :: Maybe SpecialtyId -> Maybe (Entity Specialty)
              -> Html -> MForm Handler (FormResult Specialty, Widget)
formSpecialty group specialty extra = do
    rndr <- getMessageRender
    (nameR,nameV) <- mreq md3textField FieldSettings
        { fsLabel = SomeMessage MsgName
        , fsTooltip = Nothing, fsId = Nothing, fsName = Nothing
        , fsAttrs = [("label",rndr MsgName)]
        } (specialtyName . entityVal <$> specialty)
    (codeR,codeV) <- mopt md3textField FieldSettings
        { fsLabel = SomeMessage MsgCode
        , fsTooltip = Nothing, fsId = Nothing, fsName = Nothing
        , fsAttrs = [("label",rndr MsgCode)]
        } (specialtyCode . entityVal <$> specialty)
    (descrR,descrV) <- mopt md3textareaField FieldSettings
        { fsLabel = SomeMessage MsgDescription
        , fsTooltip = Nothing, fsId = Nothing, fsName = Nothing
        , fsAttrs = [("label",rndr MsgDescription)]
        } (specialtyDescr . entityVal <$> specialty)

    let r = Specialty <$> nameR <*> codeR <*> descrR <*> pure group
    let w = $(widgetFile "data/specialties/form")
    return (r,w)


getSpecialtyR :: SpecialtyId -> Specialties -> Handler Html
getSpecialtyR sid ps@(Specialties sids) = do

    specialty <- runDB $ selectOne $ do
        x <- from $ table @Specialty
        where_ $ x ^. SpecialtyId ==. val sid
        return x

    (fw,et) <- generateFormPost formDelete

    msgs <- getMessages
    defaultLayout $ do
        setTitleI MsgSpecialty
        addScript (StaticR js_specialties_specialty_min_js)
        idPanelDetails <- newIdent
        $(widgetFile "data/specialties/specialty")


postSpecialtiesR :: Specialties -> Handler Html
postSpecialtiesR ps@(Specialties sids) = do
    ((fr,fw),et) <- runFormPost $ formSpecialty Nothing Nothing
    case fr of
      FormSuccess r -> do
          when (null sids) $ runDB $ insert_ r
          unless (null sids) $ runDB $ insert_ r { specialtyGroup = Just (last sids) }
          addMessageI statusSuccess MsgRecordCreated
          redirect $ DataR $ SpecialtiesR ps
      _otherwise -> defaultLayout $ do
          setTitleI MsgSpecialty
          $(widgetFile "data/specialties/create")


getSpecialtiesR :: Specialties -> Handler Html
getSpecialtiesR ps@(Specialties sids) = do
    user <- maybeAuth
    specialties <- runDB $ select $ do
        x <- from $ table @Specialty
        unless (null sids) $ where_ $ x ^. SpecialtyGroup ==. just (val (last sids))
        when (null sids) $ where_ $ isNothing_ $ x ^. SpecialtyGroup
        orderBy [asc (x ^. SpecialtyName)]
        return x
    msgs <- getMessages
    defaultLayout $ do
        setTitleI MsgSpecialties
        idFabAdd <- newIdent
        setUltDestCurrent
        when (null sids) $ do
            addScript (StaticR js_specialties_specialties_min_js)
            $(widgetFile "data/specialties/specialties")
        unless (null sids) $ do
            setTitleI MsgSpecialties
            addScript (StaticR js_specialties_subspecialties_min_js)
            idPanelSubspecialties <- newIdent
            $(widgetFile "data/specialties/subspecialties")
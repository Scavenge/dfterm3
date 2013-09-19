-- | An administrator panel served through HTTP.
--

{-# LANGUAGE OverloadedStrings, DeriveDataTypeable #-}

module Dfterm3.AdminPanel
    ( runAdminPanel )
    where

import Dfterm3.Admin
import Dfterm3.Dfterm3State
import Dfterm3.GameSubscription
import Dfterm3.Logging
import Dfterm3.Util ( whenJust )

import Dfterm3.Game.DwarfFortress

import Control.Applicative
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class ( liftIO )
import Data.Typeable ( Typeable )
import Data.Word
import Data.Monoid
import Network

import qualified Data.ByteString as B
import qualified Data.ByteString.UTF8 as BU
import qualified Data.ByteString.Base64 as B64
import qualified Data.Text as T

import Text.Blaze ((!))
import qualified Happstack.Server.SimpleHTTP as H
import qualified Happstack.Server.FileServe as H
import qualified Text.Blaze.Html5 as L
import qualified Text.Blaze.Html5.Attributes as A

-- | Runs an administrator panel. It runs until the Haskell process ends. In
-- other words, this does not return.
runAdminPanel :: Word16        -- ^ Port where to run.
              -> Storage       -- ^ Handle to persistent storage.
              -> IO ()
runAdminPanel port storage = do
    -- We need to create the socket ourselves to listen on 127.0.0.1
    s <- H.bindIPv4 "127.0.0.1" $ fromIntegral port
    H.simpleHTTPWithSocket s
                           H.nullConf { H.port = fromIntegral port }
                           (adminPart storage)

adminPart :: Storage -> H.ServerPart H.Response
adminPart storage = msum [ H.dir "admin" $ adminPanelRoot storage
                         , do H.nullDir
                              H.movedPermanently ("admin/" :: T.Text) $
                                 H.toResponse ("Redirecting..." :: T.Text) ]

adminPanelRoot :: Storage -> H.ServerPart H.Response
adminPanelRoot storage = msum [ H.dir "resources" $
                                H.serveDirectory H.DisableBrowsing []
                                                 "./web-interface/resources"
                              , adminPanel storage ]

adminPanel :: Storage -> H.ServerPart H.Response
adminPanel ps =
    msum [ H.dir "admin_login" $ do
              H.method [ H.POST ]
              msum [ do H.decodeBody decodePolicy
                        password <- BU.fromString <$>
                                    H.body (H.look "password")
                        maybe_sid <- liftIO $
                            newSessionByPassword password 1800 ps
                        case maybe_sid of
                            Nothing -> do
                                host <- H.rqPeer <$> H.askRq
                                liftIO $ logNotice $
                                          "Failed administrator panel login \
                                          \from " ++ show host
                                loginScreen

                            Just sid -> do
                                host <- H.rqPeer <$> H.askRq
                                liftIO $ logNotice $
                                          "Administrator logged in from " ++
                                          show host
                                setSessionIDCookie sid
                                showAdminPanelAuthenticated sid

                            _ -> mzero
                   , loginScreen ]

         , do Right session_id' <-
                  B64.decode . BU.fromString <$>
                  H.readCookieValue "dfterm3_admin_session_id"
              let session_id = byteStringToSessionID session_id'

              mustHaveValidSessionID session_id ps
              showAdminPanelAuthenticated session_id

         , loginScreen ]
  where
    showAdminPanelAuthenticated = adminPanelAuthenticated ps

loginScreen :: H.ServerPart H.Response
loginScreen = H.serveFile (H.asContentType "text/html")
                   "./web-interface/admin-login.html"

decodePolicy :: H.BodyPolicy
decodePolicy = H.defaultBodyPolicy "/tmp/" 0 10000 1000

setSessionIDCookie :: SessionID -> H.ServerPart ()
setSessionIDCookie sid =
    H.addCookie H.Session (H.mkCookie "dfterm3_admin_session_id"
                                      (BU.toString . B64.encode $
                                       sessionIDToByteString sid))
                          { H.httpOnly = True }

mustHaveValidSessionID :: SessionID -> Storage -> H.ServerPart ()
mustHaveValidSessionID sid ps = do
    is_valid <- liftIO $ isValidSessionID sid ps
    unless is_valid mzero

data FlashMsg = Failure !T.Text
              | Success !T.Text
              | NoMsg
              deriving ( Eq, Ord, Show, Read, Typeable )

adminPanelAuthenticated :: Storage -> SessionID -> H.ServerPart H.Response
adminPanelAuthenticated ps sid = msum [
      -- These are parts that handle "POST" requests.
      -- The part that can change passwords
      do H.method [ H.POST ]
         msum [ H.dir "change_password" (changePasswordPostPart ps)
              , H.dir "logout" (logoutPostPart ps sid)
              , H.dir "register_game" (registerGamePart ps)
              , H.dir "modify_game" (modifyGamePart ps) ]

    , adminPanelContents ps NoMsg
    ]

modifyGamePart :: Storage -> H.ServerPart H.Response
modifyGamePart ps = do
    H.decodeBody decodePolicy
    key <- blook "key"
    do_unregister key
  where
    do_unregister key = do
        _ <- blook "unregister"
        liftIO $ runSubscriptionIO ps $ unPublishGame (BU.fromString key)
        success "Unregistered game."

    success = adminPanelContents ps . Success
    blook = H.body . H.look

registerGamePart :: Storage -> H.ServerPart H.Response
registerGamePart ps = do
    liftIO $ logInfo "hi"
    H.decodeBody decodePolicy
    df <- mkDwarfFortressPersistent <$>
                 blook "executable" <*>
                 blook "working_directory" <*>
                 return [] <*>
                 tlook "name"

    liftIO $ runSubscriptionIO ps $ publishGame df
    liftIO $ logInfo $ "Registered a Dwarf Fortress game: " ++ show df
    success "Game registered."
  where
    blook = H.body . H.look
    tlook x = fmap T.pack (H.body $ H.look x)
    success = adminPanelContents ps . Success

logoutPostPart :: Storage -> SessionID -> H.ServerPart H.Response
logoutPostPart ps sid = do
    H.addCookie H.Expired (H.mkCookie "dfterm3_admin_session_id" "")
                          { H.httpOnly = True }
    liftIO $ invalidateSessionID sid ps
    loginScreen

changePasswordPostPart :: Storage -> H.ServerPart H.Response
changePasswordPostPart ps = do
    H.decodeBody decodePolicy
    old_password <- BU.fromString <$> blook "old_password"
    password <- BU.fromString <$> blook "password"
    retype_password <- BU.fromString <$> blook "retype_password"

    if B.null password
      then failure "Password cannot be empty."
      else do

    if password /= retype_password
      then failure "Passwords do not match."
      else do

    results <- liftIO $ changePassword old_password password ps
    if results
      then success "Password changed."
      else failure "Incorrect old password."
  where
    blook = H.body . H.look
    failure = adminPanelContents ps . Failure
    success = adminPanelContents ps . Success

adminPanelContents :: Storage -> FlashMsg -> H.ServerPart H.Response
adminPanelContents ps flashmsg = do
    ( potential, published ) <- liftIO $ runSubscriptionIO ps $ liftM2 (,)
        (lookForPotentialGames :: SubscriptionIO [DwarfFortressPersistent])
        (lookForPublishedGames :: SubscriptionIO [DwarfFortressPersistent])

    H.ok . H.toResponse $ heading $ do
    L.div ! A.class_ "admin_content" $ do
        case flashmsg of
            Failure msg ->
                L.div ! A.class_ "admin_flash_failure" $ L.p (L.toHtml msg)
            Success msg ->
                L.div ! A.class_ "admin_flash_success" $ L.p (L.toHtml msg)
            NoMsg -> return ()
        logoutHtml
        changePasswordHtml
        listOfPotentialGames potential
        listOfPublishedGames published
  where
    heading rest =
        L.html $ do
            L.head $ do
                L.title (L.toHtml ("Dfterm3 Admin Panel" :: String))
                L.meta ! A.charset "utf-8"
                L.link ! A.href "resources/interface.css" ! A.rel "stylesheet" !
                         A.type_ "text/css" ! A.title "Interface style"
            L.body rest

logoutHtml :: L.Markup
logoutHtml =
    L.form ! A.action "logout" !
             A.method "post" $
        L.input ! A.type_ "submit" ! A.value "Logout"

changePasswordHtml :: L.Markup
changePasswordHtml =
    L.div ! A.class_ "admin_password_form" $
        L.form ! A.action "change_password" !
                 A.method "post" $ do

            L.h3 "Change administrator password:"

            L.label "Old password: "
            L.br
            L.input ! A.name "old_password" ! A.type_ "password"
            L.br
            L.label "Password: "
            L.br
            L.input ! A.name "password" ! A.type_ "password"
            L.br
            L.label "Retype password: "
            L.br
            L.input ! A.name "retype_password" ! A.type_ "password"
            L.br
            L.input ! A.type_ "submit" ! A.value "Change password"

instance L.ToValue BU.ByteString where
    toValue = L.toValue . BU.toString

instance L.ToMarkup BU.ByteString where
    toMarkup = L.toMarkup . BU.toString

listOfPotentialGames :: [DwarfFortressPersistent] -> L.Markup
listOfPotentialGames [] = return ()
listOfPotentialGames games = do
    L.div ! A.class_ "admin_title_unregistered" $ do
        L.h3 "Unregistered Dwarf Fortress games:"
    L.br
    L.ul $
        forM_ games $ \df ->
            L.li $
                L.form ! A.action "register_game" !
                         A.method "post" $ do
                    L.input ! A.type_ "hidden" !
                              A.name "executable" !
                              A.value (L.toValue (df^.executable))
                    L.input ! A.type_ "hidden" !
                              A.name "working_directory" !
                              A.value (L.toValue (df^.workingDirectory))
                    L.input ! A.type_ "submit" ! A.value "Add"
                    L.toHtml (uniqueKey df)
                    L.span ! A.class_ "game_name" $
                        L.input ! A.type_ "text" !
                                  A.name "name" !
                                  A.value (L.toValue (df^.customName))

listOfPublishedGames :: [DwarfFortressPersistent] -> L.Markup
listOfPublishedGames [] = return ()
listOfPublishedGames games = do
    L.div ! A.class_ "admin_title_registered" $ do
        L.h3 "Registered Dwarf Fortress games:"
    L.br
    L.ul $
        forM_ games $ \df ->
            L.li $
                L.form ! A.action "modify_game" !
                         A.method "post" $ do
                    L.input ! A.type_ "hidden" !
                              A.name "key" !
                              A.value (L.toValue (uniqueKey df))
                    L.input ! A.type_ "submit" ! A.name "unregister" !
                              A.value "Unregister"
                    L.toHtml (uniqueKey df)
                    L.span ! A.class_ "game_name" $
                        L.toHtml $ df^.customName


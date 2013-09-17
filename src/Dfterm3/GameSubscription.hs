-- | Game subscription system where game information is persistently stored.
--
-- You can /publish/ games to the system. A published game consists of:
--
--   * Information on how to launch the game off the computer. (given as any
--     serializable data value) and an IO action.
--
--   * Description on how to find currently running instances of the game
--     currently running on the computer (given as an IO action).
--
--   * Description on what data type is used to communicate changes in the
--     game.
--
-- Once you have published a game, you can /subscribe/ to a running instance of
-- a game. Moreover, if the game allows it, a new instance can be launched.
--
--   * Subscribers can chat with other subscribers over the game if the
--     permissions allow this.
--
--   * Subscribers can give input to the game if the permissions allow this.
--
-- This library is not in general asynchronous exception safe.
--

{-# LANGUAGE DeriveDataTypeable, Rank2Types, ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

module Dfterm3.GameSubscription
    (
      -- * Publishing games
      publishGame
    , unPublishGame
    , changesets
    , PublishableGame(..)
    , GameInstance()
    , rawInstance
    , receiveInput
    , tryReceiveInputSTM
      -- * Subscribing to games
    , subscribe
    , procureInstance
    , chat
    , input
    , stop
    , waitForEvent
    , stopFromSubscriber
    , Dfterm3.GameSubscription.gameKey
    , SubscribingFailure(..)
    , GameSubscriptionEvent(..)
    , ChatEvent(..)

      -- * Running subscription actions
    , SubscriptionIO()
    , runSubscriptionIO )
    where

import Dfterm3.Dfterm3State.Internal.Transactions
import Dfterm3.GameSubscription.Internal.Types
import Dfterm3.GameSubscription.Internal.SubscriptionIO
import Dfterm3.Util

import Data.SafeCopy ( safePut )
import Data.Typeable ( Typeable )
import Data.Acid
import Data.Serialize.Put
import Data.IORef
import Data.Foldable ( forM_ )
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import System.Random ( randomRIO )
import Control.Lens
import Control.Monad.Reader hiding ( forM_ )
import Control.Concurrent.STM
import Control.Concurrent.MVar
import Control.Concurrent ( forkIO )
import Control.Exception ( mask_ )

-- | Publishes a game.
--
-- If a game already exists with the same uniquely identifying key, then the
-- following happens:
--
-- * Any subscriber currently subscribed to instances of the old game are
--   booted out of the game. All instances of the said game are closed
--   immediately.
--
-- * Information about the old game is thrown away and is replaced by the new
--   game.
--
publishGame :: PublishableGame game
            => game                 -- ^ Game to publish.
            -> SubscriptionIO ()
publishGame game = do
    state <- useAcidState
    SubscriptionIO $ do
        replaced_something <- liftIO $
            update state $ TryPublishGame game_key
                                          (runPut $ safePut game)

        when replaced_something $ unwrap $ do
            stopInstancesByGameKey game_key >>= runStoppers
  where
    game_key = uniqueKey game
    unwrap (SubscriptionIO action) = action

-- | Send changesets to subscribers.
changesets :: PublishableGame game
           => GameInstance game
           -> GameChangesets game
           -> IO ()
changesets game_instance changesets =
    atomically $ writeTChan (_outputsInstanceChannel game_instance) $
        Just changesets

runStoppers :: [IO ()] -> SubscriptionIO ()
runStoppers stoppers = liftIO $ sequence_ $ fmap (void . forkIO) stoppers

stopInstancesByGameKey :: B.ByteString
                       -> SubscriptionIO [IO ()]
stopInstancesByGameKey game_key = SubscriptionIO $ do
    instances_by_game_key <- use (_1 . runningInstancesByGameKey)
    instances <- use (_1 . runningInstances)

    tmp_ref <- liftIO $ newIORef []

    forM_ (M.findWithDefault S.empty game_key instances_by_game_key) $
        \instance_key -> do

        case M.lookup instance_key instances of
            Nothing -> return ()
            Just (AnyGameInstance stopper channel_stop_informer) -> do
                liftIO $ do
                    channel_stop_informer
                    modifyIORef' tmp_ref ((:) stopper)

        _1 . runningInstances %= M.delete instance_key

    _1 . runningInstancesByGameKey %= M.delete game_key

    liftIO $ readIORef tmp_ref

-- | Unpublishes a game.
--
-- If the game has any running instances, they are stopped and subscribers are
-- thrown out.
--
-- If there is no such game with the given key, nothing happens.
unPublishGame :: B.ByteString     -- ^ Uniquely identifying key to the game.
              -> SubscriptionIO ()
unPublishGame game_key = do
    state <- useAcidState
    SubscriptionIO $ do
        removed_something <- liftIO $ update state $ TryRemoveGame game_key
        when removed_something $ unwrap $
            stopInstancesByGameKey game_key >>= runStoppers
  where
    unwrap (SubscriptionIO action) = action

-- | Failure conditions for `subscribe`.
data SubscribingFailure =
  InstanceIsDead           -- ^ The given instance is not active anymore.
  deriving ( Eq, Ord, Show, Read, Typeable )

-- | Procures an instance of some game.
procureInstance :: PublishableGame game
                => game
                -> SubscriptionIO
                   (Maybe (GameInstance game))
procureInstance game = SubscriptionIO $ do
    maybe_ginst_callback <- liftIO $ procureInstance_ game
    case maybe_ginst_callback of
        Nothing -> return Nothing
        Just ( ginst, callback ) -> do
            inputs_chan <- liftIO newTChanIO
            outputs_chan <- liftIO newBroadcastTChanIO
            chat_chan <- liftIO newBroadcastTChanIO
            subscribeLock <- liftIO $ newMVar True
            let stopper = stopInstance ginst
                stopper_informer = do
                    modifyMVar_ subscribeLock $ \old -> do
                        when old $
                            atomically $ writeTChan outputs_chan Nothing
                        return False

            _1 . runningInstances %= M.insert (uniqueInstanceKey ginst)
                                              (AnyGameInstance
                                                  stopper
                                                  stopper_informer)
            _1 . runningInstancesByGameKey %= M.insertWith S.union game_key
                                                           (S.singleton
                                                            (uniqueInstanceKey
                                                             ginst))

            let game_instance =
                 GameInstance { _gameInstance = ginst
                              , _gameKey = game_key
                              , _inputsInstanceChannel = inputs_chan
                              , _outputsInstanceChannel = outputs_chan
                              , _chatBroadcastChannel = chat_chan
                              , _subscribeLock = subscribeLock }

            liftIO $ void $ forkIO $ callback game_instance

            return $ Just game_instance
  where
    game_key = uniqueKey game

-- | Returns the raw instance from a `GameInstance`.
rawInstance :: GameInstance game -> GameRawInstance game
rawInstance = _gameInstance

-- | Subscribe to a game instance.
--
-- You will be automatically unsubscribed from the game if you lose all
-- references to the returned `GameSubscription`.
subscribe :: GameInstance game
          -> T.Text            -- ^ By what name are you subscribing. This name
                               --   is shown in the chat.
          -> IO (Either SubscribingFailure
                        (GameSubscription game))
subscribe inst name = mask_ $ do
    withMVar (_subscribeLock inst) $ \alive ->
        if alive
          then subscribe'
          else return $ Left InstanceIsDead
  where
    subscribe' = do
        dupped_chan <- atomically $ do
            writeTChan broadcast_chan (Joined name)
            dupTChan broadcast_chan

        dupped_output_chan <- atomically $ dupTChan outputs_chan

        ref <- newFinalizableIORef () $ do
            atomically $ writeTChan broadcast_chan (Parted name)

        return $ Right $
            GameSubscription { _inputsChannel = _inputsInstanceChannel inst
                             , _outputsChannel = dupped_output_chan
                             , _chatChannel = _chatBroadcastChannel inst
                             , _chatReceivingChannel = dupped_chan
                             , _name = name
                             , _subscriberGameInstance = inst
                             , _ref = ref }

    broadcast_chan = _chatBroadcastChannel inst
    outputs_chan = _outputsInstanceChannel inst

-- | Describes an event that happened in a game. This value is transmitted to
-- subscribers of a game.
data GameSubscriptionEvent game =
    InstanceClosed                 -- ^ The game was closed. It is not
                                   --   guaranteed any more messages will be
                                   --   received after this message.
  | ChatEvent ChatEvent            -- ^ Chat events.
  | GameChangesets (GameChangesets game) -- ^ Changesets from the game.

-- | Receive an event from a game subscription.
waitForEvent :: PublishableGame game
             => GameSubscription game
             -> IO (GameSubscriptionEvent game)
waitForEvent subscription = do
    event_index <- randomRIO (1 :: Int, 2)
    let tryings = case event_index of
                      1 -> [tryReadChangesets, tryReadChatEvents]
                      2 -> [tryReadChatEvents, tryReadChangesets]
                      _ -> error "Impossible!"

    atomically $ do
        result <- runTryings tryings
        case result of
            Nothing -> retry
            Just  x -> return x
  where
    runTryings :: [STM (Maybe (GameSubscriptionEvent game))]
               -> STM (Maybe (GameSubscriptionEvent game))
    runTryings [] = return Nothing
    runTryings (x:rest) = do
        result <- x
        case result of
            Nothing -> runTryings rest
            actual_result@(Just _) -> return actual_result

    tryReadChangesets = do
        result <- tryReadTChan (_outputsChannel subscription)
        return $ case result of
            Nothing -> Nothing
            Just  x -> Just $ case x of
                           Nothing -> InstanceClosed
                           Just  y -> GameChangesets y

    tryReadChatEvents =
        fmap (fmap ChatEvent) $
            tryReadTChan (_chatReceivingChannel subscription)

-- | Chat over a game subscription.
chat :: PublishableGame game
     => GameSubscription game
     -> T.Text
     -> IO ()
chat subscription message =
    atomically $ writeTChan (_chatChannel subscription)
                            (ChatMessage (_name subscription) message)

-- | Receive input from a game. Blocks until input comes.
receiveInput :: PublishableGame game
             => GameInstance game
             -> IO (GameInputs game)
receiveInput game_instance =
    atomically $ do
        results <- tryReceiveInputSTM game_instance
        case results of
            Nothing -> retry
            Just x -> return x

-- | Same as `receiveInput` but in `STM` and can fail.
tryReceiveInputSTM :: PublishableGame game
                   => GameInstance game
                   -> STM (Maybe (GameInputs game))
tryReceiveInputSTM game_instance =
    tryReadTChan (_inputsInstanceChannel game_instance)

-- | Give input to a game.
input :: PublishableGame game
      => GameSubscription game
      -> GameInputs game
      -> IO ()
input subscription inputs =
    atomically $ writeTChan (_inputsChannel subscription) inputs

-- | Returns the corresponding game key from an instance of a game.
gameKey :: PublishableGame game => GameInstance game -> B.ByteString
gameKey = _gameKey

-- | Stops a game from a subscriber.
stopFromSubscriber :: PublishableGame game
                   => GameSubscription game
                   -> SubscriptionIO ()
stopFromSubscriber subscription =
    stop (_subscriberGameInstance subscription)

-- | Stops a game. This throws out subscribers.
--
-- If the game is already stopped, does nothing.
stop :: PublishableGame game
     => GameInstance game
     -> SubscriptionIO ()
stop ginst = SubscriptionIO $ do
    old_instances <- use (_1 . runningInstances)

    let ( stopper, channel_stop_informer ) =
         case M.findWithDefault
                  (AnyGameInstance (return ()) (return ()))
                  instance_key
                  old_instances of
             AnyGameInstance stopper channel_stop_informer ->
                 ( stopper, channel_stop_informer )

    _1 . runningInstances %= M.delete instance_key
    _1 . runningInstancesByGameKey %= M.update (\old ->
        let new = S.delete instance_key old
         in if S.null new then Nothing else Just new) game_key

    liftIO $ do
        channel_stop_informer
        void $ forkIO $ stopper
  where
    game_key = _gameKey ginst
    instance_key = uniqueInstanceKey $ _gameInstance ginst


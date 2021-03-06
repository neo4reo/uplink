{-|

There are three different configurations that are avaiable on a node.

* Account settings ( private key, public key, metadata )
  - key.pem
  - key.pub
* Chain settings ( genesis block, concensus mechanism )
  - chain.config
* Node settings ( port, rpc settings, data directory, network settings )
  - node.config

-}

{-# LANGUAGE StrictData #-}

module Config (
  -- ** Types
  StorageBackend(..),
  Config(..),
  readConfig,
  handleConfig,
  verifyConfig,
  defaultConfig,
  getStorageBackend,

  -- ** Errors
  KeyError(..),
  errorHandler,

  -- ** Chain Settings
  ChainSettings(..),
  readChain,
  handleChain,
  defaultChain,

  -- ** Testing
  testChain,
  testConfig,
) where

import Protolude

import Data.List (elemIndex)
import Data.Configurator.Types (KeyError(..))
import qualified Data.Configurator.Types as C (Config)

import Address (Address)
import qualified Utils
import qualified Network.Utils as NU
import qualified Data.Configurator as C
import qualified Consensus.Authority.Params as CAP

import DB
import Database.PostgreSQL.Simple

import Network.URI (URIAuth, parseURI, uriScheme, uriPath, uriAuthority, uriUserInfo, uriPort, uriRegName)
import Network.BSD (getHostName)

import System.FilePath
import System.Directory
import System.Posix.Files

-- | Node configuration, all arguments are required and handled by override and
-- defaulting logic in `Main`.
data Config = Config
  { verbose      :: Bool          -- ^ Verbose logging
  , loggingLevel :: Text          -- ^ Logging level
  , logfile      :: FilePath      -- ^ Log file
  , bootnodes    :: [ByteString]  -- ^ Bootnodes
  , rpcPort      :: Int           -- ^ RPC port
  , rpcSsl       :: Bool          -- ^ Use TLS for RPC
  , rpcCrt       :: FilePath      -- ^ RPC TLS certificate
  , rpcKey       :: FilePath      -- ^ RPC TLS key
  , port         :: Int           -- ^ Port
  , hostname     :: [Char]        -- ^ Hostname
  , maxPeers     :: Int           -- ^ Maximum peer count
  , minPeers     :: Int           -- ^ Minimum peer count
  , closed       :: Bool          -- ^ Closed network
  , storageBackend :: StorageBackend
  , nonetwork    :: Bool          -- ^ Disable networking
  , configFile   :: FilePath      -- ^ Config file
  , chainConfigFile :: FilePath   -- ^ Chain configuration file
  , nodeDataDir  :: FilePath      -- ^ Directory where local files node data files (keys, etc) are stored
  , rpcReadOnly  :: Bool          -- ^ Can RPC cmds change state of ledger
  , preallocated :: FilePath      -- ^ Pre-allocated accounts directory
  , testMode     :: Bool          -- ^ Is node in "test" mode
  } deriving (Eq, Show)

data ChainSettings = ChainSettings
  { minTxs           :: Int        -- ^ Minimum number of transactions in a block
  , maxTxs           :: Int        -- ^ Maximum number of transactions in a block
  , maxAccts         :: Int        -- ^ Maximum number of accounts in system
  , presetAccts      :: Bool       -- ^ Account creation is not allowed.

  , genesisTimestamp :: Int64      -- ^ Genesis block timestamp
  , genesisHash      :: ByteString -- ^ Genesis block hash

  , consensus        :: Text       -- ^ Consensus algorithim
  , chainScoring     :: Text       -- ^ Chain scoring metric

  , contractSize     :: Int        -- ^ Contract size

  , genesisPoA       :: CAP.PoA    -- ^ PoA Cosensus Algorithm Parameters

  } deriving (Eq, Show)

-------------------------------------------------------------------------------
-- Serialization
-------------------------------------------------------------------------------

getDefault :: [Char] -> IO FilePath
getDefault "XDG_DATA_HOME"   = userRelative $ ".local" </> "share"
getDefault "XDG_CONFIG_HOME" = userRelative $ ".config"
getDefault "XDG_CACHE_HOME"  = userRelative $ ".cache"
getDefault "XDG_DATA_DIRS"   = return $ "/usr/local/share:/usr/share"
getDefault "XDG_CONFIG_DIRS" = return $ "/etc/xdg"
getDefault _                 = return $ ""

userRelative :: FilePath -> IO FilePath
userRelative p = getHomeDirectory >>= return . (</> p)

macOsPath :: FilePath -> IO FilePath
macOsPath cfg = userRelative $ "/Library/Application Support/" </> "uplink" </> "config" </> cfg

fallbacks :: FilePath -> IO [FilePath]
fallbacks cfg = sequence [
  -- Linux
    pure cfg                                    -- ./node.config
  , pure ("/etc/uplink" </> cfg)                -- /etc/uplink/node.config
  , (</> "uplink" </> cfg) <$> getDefault "XDG_CONFIG_HOME"  -- '$HOME/.config/uplink/node.config'

  -- MacOS
  , macOsPath cfg                               -- '$HOME/Library/Application Support/uplink/node.config'
  ]

-- | Fallback paths for finding configuration files
configFallback :: Bool -> [FilePath] -> IO (Maybe FilePath)
configFallback silent [] = pure Nothing
configFallback silent (x:xs) = do
  when (not silent) $
    putText $ "Searching for config at: " <> toS x
  cfgExists <- fileExist x
  if cfgExists
    then pure (Just x)
    else configFallback silent xs

-- | Find a configuration file somewhere in the users filesystem
handleConfig :: Bool -> FilePath -> IO Config
handleConfig silent cfgFile = do
  cfgs <- fallbacks (takeFileName cfgFile)
  cfg  <- configFallback silent (cfgFile : cfgs)
  case cfg of
    Nothing -> die $ "Cannot find configuration: " <> ((toS cfgFile) :: Text)
    Just fpath -> readConfig silent fpath

-- | Read configuration file from a directory
readConfig :: Bool -> FilePath -> IO Config
readConfig silent cfgFile = errorHandler $ do
  unless silent $
    Utils.putGreen ("Using configuration: " <> toS cfgFile)

  cfg          <- C.load [C.Required cfgFile]
  verbose      <- C.require cfg "logging.verbose"
  loglevel     <- C.require cfg "logging.loglevel"
  logfile      <- C.require cfg "logging.logfile"


  backend      <- getStorageBackend =<<
                    C.require cfg "storage.backend"
  nodeDataDir  <- C.require cfg "storage.directory"

  rpcPort      <- C.require cfg "rpc.port"
  rpcSsl       <- C.require cfg "rpc.ssl"
  rpcCrt       <- C.require cfg "rpc.crt"
  rpcKey       <- C.require cfg "rpc.key"

  port         <- C.require cfg "network.port"
  hostname     <- getHostname cfg
  nonetwork    <- C.require cfg "network.nonetwork"
  bootnodes    <- C.require cfg "network.bootnodes"
  closed       <- C.require cfg "network.closed"
  minPeers     <- C.require cfg "network.min-peers"
  maxPeers     <- C.require cfg "network.max-peers"

  preallocated <- C.require cfg "network.preallocated"

  return Config {
    verbose      = verbose
  , loggingLevel = loglevel
  , logfile      = logfile
  , bootnodes    = bootnodes
  , rpcPort      = rpcPort
  , rpcSsl       = rpcSsl
  , rpcCrt       = rpcCrt
  , rpcKey       = rpcKey
  , port         = port
  , hostname     = hostname
  , minPeers     = minPeers
  , maxPeers     = maxPeers
  , closed       = closed
  , storageBackend = backend
  , nonetwork    = nonetwork
  , configFile   = cfgFile
  , chainConfigFile = defaultChain
  , nodeDataDir  = nodeDataDir
  , rpcReadOnly  = False
  , preallocated = preallocated
  , testMode     = False
  }

getHostname :: C.Config -> IO [Char]
getHostname cfg = do
  mHostname <- C.lookup cfg "network.hostname"
  case mHostname of
    Nothing -> NU.resolveHostname =<< getHostName
    Just hn -> NU.resolveHostname hn

getStorageBackend :: [Char] -> IO StorageBackend
getStorageBackend cs =
  case parseURI cs of
    Nothing -> die $ "Invalid storage backend uri: " <> toS cs
    (Just uri) -> do
      let scheme   = uriScheme uri
          path = drop 1 $ uriPath uri

      case scheme of
        "leveldb:" -> return $ LevelDB $ if null path then ".uplink" else path
        "postgresql:" -> case uriAuthority uri of
            Nothing -> die $ "invalid uri auth given: " <> toS cs

            (Just as) -> do
              let host = if null (uriRegName as)
                            then Nothing
                            else Just $ uriRegName as

              let port = if null (uriPort as)
                            then Nothing
                            else (readMaybe (drop 1 $ uriPort as) :: Maybe Word16)

              let (user, password) = parseAuthInfo as

              return $ PostgreSQL ConnectInfo {
                connectHost = host `fallback` connectHost defaultConnectInfo
              , connectPort = port `fallback` connectPort defaultConnectInfo
              , connectUser = user `fallback` connectUser defaultConnectInfo
              , connectPassword = password `fallback` connectPassword defaultConnectInfo
              , connectDatabase = if null path then "uplink" else path
              }
        _ -> die $ "Invalid uri scheme given: " <> toS cs
  where
    parseAuthInfo :: URIAuth -> (Maybe [Char], Maybe [Char])
    parseAuthInfo as =
      case elemIndex ':' $ uriUserInfo as of
        Nothing ->
          let user = dropLast $ uriUserInfo as in
            if null user then (Nothing, Nothing) else (Just user, Nothing)
        (Just i) ->
          case splitAt i $ uriUserInfo as of
            (user, ':' : password) -> (Just user, Just $ dropLast password)
            _ -> (Nothing, Nothing)

    fallback = flip fromMaybe

    dropLast "" = ""
    dropLast [_] = ""
    dropLast (x : xs) = x : dropLast xs

-------------------------------------------------------------------------------
-- Chain Configuration
-------------------------------------------------------------------------------

-- | Find a configuration file somewhere in the users filesystem
handleChain :: Bool -> FilePath -> IO ChainSettings
handleChain silent cfgFile = do
  cfgs <- fallbacks (takeFileName cfgFile)
  cfg  <- configFallback silent (cfgFile : cfgs)
  case cfg of
    Nothing -> die $ "Cannot find chain configuration: " <> ((toS cfgFile) :: Text)
    Just fpath -> readChain silent fpath

readChain :: Bool -> FilePath -> IO ChainSettings
readChain silent cfgFile = do
  exists <- fileExist cfgFile
  if (not exists)
    then die $ "Chain configuration file does not exist at: " <> (show cfgFile)
    else pure ()

  cfg           <- C.load [C.Required cfgFile]
  consensus     <- C.require cfg "consensus.algorithm"

  -- PoA consensus params
  validators    <- C.require cfg "authority.validators"
  blockPeriod   <- C.require cfg "authority.block-period"
  blockGenLimit <- C.require cfg "authority.block-gen-limit"
  blockSignLimit <- C.require cfg "authority.block-sign-limit"
  threshold     <- C.require cfg "authority.threshold"
  minTxs        <- C.require cfg "authority.transactions"

  let eValidPoAParams =
        CAP.mkGenesisPoA
          validators
          blockPeriod
          blockGenLimit
          blockSignLimit
          threshold
          minTxs
  poaParams <- case eValidPoAParams of
    Left err -> die $ "PoA Consensus parameters invalid:\n  " <> show err
    Right poa -> pure poa

  -- Genesis block params
  timestamp     <- C.require cfg "genesis.timestamp"
  genesisHash   <- C.require cfg "genesis.hash"

  contractSize  <- C.require cfg "contracts.max-size"

  -- XXX: hardcoded
  return ChainSettings {
    minTxs            = 1
  , maxTxs            = 100
  , maxAccts          = 100
  , presetAccts       = False
  , genesisTimestamp  = timestamp
  , genesisHash       = genesisHash
  , genesisPoA        = poaParams
  , consensus         = consensus
  , chainScoring      = ""
  , contractSize      = contractSize
  }

-- | Verify the integrity of a configuration set.
verifyConfig :: Config -> IO Bool
verifyConfig Config {..} = do
  exists <- mapM doesFileExist [
      configFile
    ]
  let
    ports = [portValid rpcPort, portValid port]
    conds = [
        not (null bootnodes)
      , not (null hostname)
      , (>= 0) minPeers
      , (>= -1) maxPeers
      , minPeers < maxPeers
      ]
  {-doesDirectoryExist dbpath-}
  pure (and $ exists <> ports <> conds)

portValid :: Int -> Bool
portValid x = x > 1023 && x < 65535

nonZero :: Integral a => a -> Bool
nonZero = (>0)

-- | Default configuration file path.
defaultConfig :: FilePath
defaultConfig = "config/node.config"

-- | Default configuration for chain.
defaultChain :: FilePath
defaultChain = "config/chain.config"

errorHandler :: IO a -> IO a
errorHandler m = do
  res <- try m
  case res of
    Left (KeyError nm) -> Utils.dieRed $ "Configuration is missing value: " <> nm
    Right val          -> pure val

-------------------------------------------------------------------------------
-- Testing
-------------------------------------------------------------------------------

testConfig :: IO Config
testConfig = do
  cfg <- C.load [C.Required defaultConfig]
  C.display cfg
  readConfig False defaultConfig

testChain :: IO ChainSettings
testChain = do
  cfg <- C.load [C.Required defaultChain]
  chain <- readChain True defaultChain
  Utils.ppDump chain
  return chain

module TestConfig (test) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Diff as AesonDiff
import qualified Data.Aeson.Encode.Pretty as AesonPretty
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBSChar
import           Data.Proxy (Proxy(..), asProxyTypeOf)
import           Lamdu.Config (Config)
import           Lamdu.Config.Theme (Theme)
import qualified Lamdu.Paths as Paths
import qualified Lamdu.Themes as Themes
import           Test.Framework
import           Test.Framework.Providers.HUnit (testCase)
import           Test.HUnit (assertString)

import           Lamdu.Prelude

test :: Test
test =
    do
        verifyJson (Proxy :: Proxy Config) "config.json"
        Themes.getFiles >>= traverse_ (verifyJson (Proxy :: Proxy Theme))
    & testCase "config-parses"

verifyJson :: (Aeson.FromJSON t, Aeson.ToJSON t) => Proxy t -> FilePath -> IO ()
verifyJson proxy jsonPath =
    do
        configPath <- Paths.getDataFileName jsonPath
        json <-
            LBS.readFile configPath <&> Aeson.eitherDecode >>=
            \case
            Left err ->
                do
                    assertString ("Failed to load " <> configPath <> ": " <> err)
                    fail "Test failure"
            Right x -> pure x
        case Aeson.fromJSON json <&> (`asProxyTypeOf` proxy) of
            Aeson.Error msg -> assertString ("Failed decoding " <> configPath <> " from json: " <> msg)
            Aeson.Success val
                | rejson == json -> pure ()
                | otherwise ->
                    assertString ("json " <> configPath <> " contains unexpected data:\n" <>
                        LBSChar.unpack (AesonPretty.encodePretty (Aeson.toJSON (AesonDiff.diff rejson json))))
                where
                    rejson = Aeson.toJSON val

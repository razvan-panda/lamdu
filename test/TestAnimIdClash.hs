module TestAnimIdClash (test) where

import           Data.List (group, sort)
import qualified GUI.Momentu.Align as Align
import qualified GUI.Momentu.Animation as Anim
import qualified GUI.Momentu.View as View
import qualified Lamdu.GUI.TypeView as TypeView
import qualified Lamdu.Name as Name
import qualified Lamdu.Sugar.Types as Sugar
import           Test.Framework
import           Test.Framework.Providers.HUnit (testCase)
import           Test.HUnit (assertString)
import           Test.Lamdu.Instances ()
import qualified Test.Lamdu.GuiEnv as GuiEnv

import           Lamdu.Prelude

test :: Test
test =
    do
        env <- GuiEnv.make
        let animIds =
                TypeView.make typ env
                ^.. Align.tValue . View.animFrames . Anim.frameImages . traverse . Anim.iAnimId
        let clashingIds = sort animIds & group >>= tail
        case clashingIds of
            [] -> pure ()
            _ -> assertString ("Clashing anim ids: " <> show clashingIds)
    & testCase "typeview-animid-clash"
    where
        typ =
            recType "typ"
            [ (Sugar.TagInfo (Name.AutoGenerated "tag0") "tag0" "tag0", nullType "field0")
            , (Sugar.TagInfo (Name.AutoGenerated "tag1") "tag1" "tag1", nullType "field1")
            , (Sugar.TagInfo (Name.AutoGenerated "tag2") "tag2" "tag2", nullType "field2")
            ]
        nullType entityId = recType entityId []
        recType entityId fields =
            Sugar.CompositeFields
            { Sugar._compositeFields = fields
            , Sugar._compositeExtension = Nothing
            }
            & Sugar.TRecord
            & Sugar.Type entityId

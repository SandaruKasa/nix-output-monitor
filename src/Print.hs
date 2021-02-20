{-# LANGUAGE ViewPatterns #-}

module Print where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time
import Parser (Derivation (..), Host (..), StorePath (..))
import Relude
import Table
import Update
import Prelude ()

vertical, verticalSlim, lowerleft, upperleft, horizontal, down, up, clock, running, done, todo, leftT, cellBorder, tablePadding, emptyCell, skipCell :: Text
vertical = "┃"
verticalSlim = "│"
lowerleft = "┗"
upperleft = "┏"
leftT = "┣"
horizontal = "━"
down = "⬇"
up = "⬆"
clock = "⏲"
running = "▶"
done = "✔"
todo = "⏳"
cellBorder = " " <> verticalSlim <> " "
tablePadding = vertical <> "    "
emptyCell = "     "
skipCell = emptyCell <> cellBorder

showCond :: Monoid m => Bool -> m -> m
showCond = memptyIfFalse

stateToText :: UTCTime -> BuildState -> Text
stateToText now buildState@BuildState{outstandingBuilds, outstandingDownloads, plannedCopies, runningRemoteBuilds, runningLocalBuilds, completedLocalBuilds, completedDownloads, completedUploads, startTime, completedRemoteBuilds}
  | totalBuilds + plannedCopies == 0 = ""
  | otherwise = builds <> table
 where
  builds =
    showCond
      (runningBuilds > 0)
      $ prependLines
        (upperleft <> horizontal)
        (vertical <> " ")
        (vertical <> " ")
        (printBuilds now runningRemoteBuilds runningLocalBuilds)
        <> "\n"
  table =
    prependLines
      ((if runningBuilds > 0 then leftT else upperleft) <> stimes (3 :: Int) horizontal <> " ")
      (vertical <> "    ")
      (lowerleft <> horizontal <> " 𝚺 ")
      $ printAlignedSep innerTable
  innerTable = fromMaybe (one (text "")) (nonEmpty headers) :| tableRows
  headers =
    (cells 3 <$> optHeader showBuilds "Builds")
      <> (cells 2 <$> optHeader showDownloads "Downloads")
      <> optHeader showUploads "Uploads"
      <> optHeader showHosts "Host"
  optHeader cond = showCond cond . one . bold . header :: Text -> [Entry]
  tableRows =
    showCond
      showHosts
      (printHosts buildState showBuilds showDownloads showUploads)
      <> maybeToList (nonEmpty lastRow)
  lastRow =
    showCond
      showBuilds
      [ nonZeroBold runningBuilds (yellow (label running (disp runningBuilds)))
      , nonZeroBold numCompletedBuilds (green (label done (disp numCompletedBuilds)))
      , nonZeroBold numOutstandingBuilds (blue (label todo (disp numOutstandingBuilds)))
      ]
      <> showCond
        showDownloads
        [ nonZeroBold downloadsDone (green (label down (disp downloadsDone)))
        , nonZeroBold numOutstandingDownloads . blue . label todo . disp $ numOutstandingDownloads
        ]
      <> showCond showUploads [text ""]
      <> (one . bold . header $ clock <> " " <> timeDiff now startTime)
  showHosts = numHosts > 0
  showBuilds = totalBuilds > 0
  showDownloads = downloadsDone + length outstandingDownloads > 0
  showUploads = countPaths completedUploads > 0
  numOutstandingDownloads = Set.size outstandingDownloads
  numHosts =
    length (Map.keysSet runningRemoteBuilds)
      + length (Map.keysSet completedRemoteBuilds)
      + length (Map.keysSet completedUploads)
  runningBuilds = countPaths runningRemoteBuilds + length runningLocalBuilds
  numCompletedBuilds =
    countPaths completedRemoteBuilds + length completedLocalBuilds
  numOutstandingBuilds = length outstandingBuilds
  totalBuilds = numOutstandingBuilds + runningBuilds + numCompletedBuilds
  downloadsDone = countPaths completedDownloads

printHosts :: BuildState -> Bool -> Bool -> Bool -> [NonEmpty Entry]
printHosts BuildState{runningRemoteBuilds, runningLocalBuilds, completedLocalBuilds, completedDownloads, completedUploads, completedRemoteBuilds} showBuilds showDownloads showUploads =
  mapMaybe nonEmpty $
    ( showCond
        showBuilds
        [ nonZeroShowBold numRunningLocalBuilds (yellow (label running (disp numRunningLocalBuilds)))
        , nonZeroShowBold numCompletedLocalBuilds (green (label done (disp numCompletedLocalBuilds)))
        , dummy
        ]
        <> showCond showDownloads [dummy, dummy]
        <> showCond showUploads [dummy]
        <> one (header "local")
    ) :
    remoteLabels
 where
  numRunningLocalBuilds = Set.size runningLocalBuilds
  numCompletedLocalBuilds = Set.size completedLocalBuilds
  labelForHost h =
    showCond
      showBuilds
      [ nonZeroShowBold runningBuilds (yellow (label running (disp runningBuilds)))
      , nonZeroShowBold doneBuilds (green (label done (disp doneBuilds)))
      , dummy
      ]
      <> showCond
        showDownloads
        [nonZeroShowBold downloads (green (label down (disp downloads))), dummy]
      <> showCond
        showUploads
        [nonZeroShowBold uploads (green (label up (disp uploads)))]
      <> one (magenta (header (toText h)))
   where
    uploads = l h completedUploads
    downloads = l h completedDownloads
    runningBuilds = l h runningRemoteBuilds
    doneBuilds = l h completedRemoteBuilds
  remoteLabels = labelForHost <$> hosts
  hosts =
    sort
      . toList
      $ Map.keysSet runningRemoteBuilds
        <> Map.keysSet completedRemoteBuilds
        <> Map.keysSet completedUploads
        <> Map.keysSet completedDownloads
  l host = Set.size . Map.findWithDefault mempty host

nonZeroShowBold :: Int -> Entry -> Entry
nonZeroShowBold num = if num > 0 then bold else const dummy
nonZeroBold :: Int -> Entry -> Entry
nonZeroBold num = if num > 0 then bold else id

printBuilds ::
  UTCTime ->
  Map Host (Set (Derivation, UTCTime)) ->
  Set (Derivation, UTCTime) ->
  NonEmpty Text
printBuilds now remoteBuilds localBuilds =
  printAligned . (one (cells 3 (header " Currently building:")) :|)
    . fmap printBuild
    . reverse
    . sortOn snd
    $ remoteLabels
      <> localLabels
 where
  remoteLabels =
    Map.foldMapWithKey
      ( \host builds ->
          ( \(x, t) ->
              ((cyan . text . name . toStorePath $ x) :| [text "on", magenta . text . toText $ host], t)
          )
            <$> toList builds
      )
      remoteBuilds
  localLabels :: [(NonEmpty Entry, UTCTime)]
  localLabels = first (one . cyan . text . name . toStorePath) <$> toList localBuilds
  printBuild (toList -> p, t) = yellow (text running) :| (p <> [header (clock <> " " <> timeDiff now t)])

timeDiff :: UTCTime -> UTCTime -> Text
timeDiff larger smaller =
  toText $
    formatTime defaultTimeLocale "%02H:%02M:%02S" (diffUTCTime larger smaller)

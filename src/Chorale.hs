{-----------------------------------------------------------------------------
    David Cope's Chorale program
------------------------------------------------------------------------------}
module Chorale where

import           Data.Char         (ord)
import           Data.List         ( (\\), inits, intersperse
                                   , sort, sortBy, tails)
import           Data.Maybe
import           Data.Ord          (comparing)
import qualified Data.Set   as Set
import           Data.Set          (Set)
import qualified Data.Map   as Map
import           Data.Map          (Map)

import System.IO
import System.IO.Unsafe

import Types
import Internal.Utils
import IO.ReadCope
import IO.WriteMidi

{-----------------------------------------------------------------------------
    Examples
------------------------------------------------------------------------------}
example     = unsafePerformIO $ fmap (snd . readCope) $ readFile "data/chopin-33-3.lisp"
example2    = drop 10 $ take 20 $ example
exampleBach = [("b206b",b206b)]
    where
    b206b = unsafePerformIO $ fmap (readLispNotes . lines) $ readFile "data/b206b.lisp"

exampleDB = unsafePerformIO $ fmap readBach $ readFile "data/jsb1.lisp"
bach      = createCompleteDatabase exampleDB

mkPiece seed = runProb1 seed $ composeBach $ bach
-- mkPiece 3 needs to fix cadences

saveFile notes = exportFile "test.mid" $ toMidi (undefined, notes)

{-----------------------------------------------------------------------------
    Database
------------------------------------------------------------------------------}
data BeatIt = BeatIt
    { events           :: Notes
    , startNotes       :: [Pitch]
    , destinationNotes :: [Pitch]
    -- , startNote :: ??
    -- , startSet :: ??
    , voiceLeading     :: ([VoiceLeading], String, Time)
    -- , preDestinationNotes :: ??
    -- , texture :: ??
    , speac            :: ()
    -- , beat :: ??
    -- , lengthToCadence :: ??
    } deriving (Eq,Show,Read)


-- | Identifier for beats from the database.
type Name     = String
data Database = DB
    { composeBeats :: [Name]                 -- Every beat in the database.
    , startBeats   :: [Name]                 -- Beats at the beginnings of the pieces.
    , composeRules :: [([VoiceLeading],Name,Time)] -- Voice leading rules.
    , beatIts      :: Map Name BeatIt        -- Mapping from beat name to data.
    , lexicons     :: Map [Pitch] (Set Name) -- Beats that begin with these pitches.
    }

emptyDB :: Database
emptyDB = DB [] [] [] Map.empty Map.empty

makeName :: String -> Int -> String
makeName dbName counter = dbName ++ "-" ++ show counter

makeLexiconName :: String -> [Pitch] -> String
makeLexiconName name pitches = concat $ intersperse "-" $ name : map show pitches

-- | Create a complete database from a selection of pieces.
createCompleteDatabase :: [(String,Notes)] -> Database
createCompleteDatabase = foldl createBeatIts emptyDB

-- | Decompose a piece into individual beats
--   and decorate them with data about adjacent beats
createBeatIts :: Database -> (String,Notes) -> Database
createBeatIts db (dbName,notes) = db2
    where
    -- Question: What about the last beat in the measure?
    (db2,_,_) = foldl step (db,1,True) $ zip beats (drop 1 beats ++ [[]])

    beats = removeNils $ collectBeats $ setToZero $ sortByStart notes

    step (db, counter, isStart) (beat1, beat2) = (newdb, counter+1, False)
        where
        name  = makeName dbName counter

        newdb = db
            { composeBeats = name : composeBeats db
            , startBeats   = (if isStart then (name:) else id) (startBeats db)
            , composeRules = voiceLeading : composeRules db
            , beatIts      = Map.insert name beatit (beatIts db)
            , lexicons     = Map.alter putBeatIntoLexicon startNotes (lexicons db)
            }

        putBeatIntoLexicon Nothing    = Just (Set.singleton name)
        putBeatIntoLexicon (Just set)
            | name `Set.member` set   = Just set
            | otherwise               = Just (Set.insert name set)

        beatit = BeatIt
            { startNotes       = startNotes
            , destinationNotes = destinationNotes
            , events           = beat1
            , voiceLeading     = voiceLeading
            , speac            = ()
            }

        voiceLeading     = (getRules name startNotes destinationNotes
                           , name, start $ head $ sortByStart beat1)

        startNotes       = map pitch $ getOnsetNotes beat1
        destinationNotes = map pitch $ getOnsetNotes beat2

removeNils = filter (not . null)

-- | Decompose a piece of music into individual beats.
collectBeats :: Notes -> [Notes]
collectBeats []    = []
collectBeats notes = beat : collectBeats rest
    where
    beat = collectByTiming (firstPlaceWhereAllTogether notes) notes
    rest = drop (length beat) notes

-- | Return only those notes which end before the first argument
collectByTiming :: Time -> Notes -> Notes
collectByTiming time = filter ((<= time) . end)
    -- TODO: use a more clever data structure to turn this into a takeWhile


-- | A rule for voice leading
data VoiceLeading = VL
    { dyad     :: Interval -- ^ Begins with a two-note chord
    , moveLow  :: Interval -- ^ The low note moves this way
    , moveHigh :: Interval -- ^ And the high note moves that way
    , nameVL   :: String   -- ^ Work name from which this was taken
                           -- (This field is to be removed later.)
    } deriving (Eq,Ord,Show,Read)


-- | Extract voice leading rules from two given chords.
--
-- >>> getRules [57,60,69,76] [59,62,67,79] "B206B-1"
-- [VL {dyad = 3, moveLow = 2, moveHigh = 2, nameVL = "B206B-1"},VL {dyad = 12, moveLow = 2, moveHigh = -2, nameVL = "B206B-1"},VL {dyad = 7, moveLow = 2, moveHigh = 3, nameVL = "B206B-1"},VL {dyad = 9, moveLow = 2, moveHigh = -2, nameVL = "B206B-1"},VL {dyad = 4, moveLow = 2, moveHigh = 3, nameVL = "B206B-1"},VL {dyad = 7, moveLow = -2, moveHigh = 3, nameVL = "B206B-1"}]
getRules :: String -> [Pitch] -> [Pitch] -> [VoiceLeading]
getRules name xs ys = map mkVoiceLeading $ pairings $ zip xs ys
    where
    mkVoiceLeading ((a,c),(b,d)) = VL
        { dyad     = reduceInterval (b - a)
        , moveLow  = c - a
        , moveHigh = d - b
        , nameVL   = name
        }

{-----------------------------------------------------------------------------
    Pitch utilities
------------------------------------------------------------------------------}
-- | Reduce intervals that go beyond an octave.
--
-- Note that the information whether the interval is an upwards or downards
-- motion is preserved. The result is an interval from -12 to 12.
reduceInterval :: Interval -> Interval
reduceInterval x
    | abs x <= 12 = x
    | x < 0       = reduceInterval (x+12)
    | otherwise   = reduceInterval (x-12)

-- | Set of pitch classes in the given list of pitches.
--
-- A pitch class is the pitch modulo octaves. Middle C has pitch class 0.
createPitchClassSet :: [Pitch] -> Set Pitch
createPitchClassSet = Set.fromList . map (`mod` 12)

-- | Test whether a voicing forms a triad (major, minor, diminished, augmented),
-- in any inversion.
isTriad :: [Pitch] -> Bool
isTriad = any isRootTriad . inversions . Set.toAscList . createPitchClassSet
    where
    isRootTriad [x,y,z] = isThird (y-x) && isThird (z-y)
    isRootTriad _       = False

-- | List all distinct inversions of a chord,
-- obtained by successively transposing the root note up one octave.
--
-- >>> inversions [0,4,7]
-- [[0,4,7],[4,7,12],[7,12,16]]
inversions :: [Pitch] -> [[Pitch]]
inversions xs = init $ zipWith (\x y -> y ++ map (+12) x) (inits xs) (tails xs)

-- | Test whether an interval is a minor or major third.
isThird :: Interval -> Bool
isThird x = x == 3 || x == 4

-- | Check whether the pitch classes of the first argument
-- form a subset of the pitch classes in the second argument.
harmonicSubset :: [Pitch] -> [Pitch] -> Bool
harmonicSubset xs ys =
    createPitchClassSet xs `Set.isSubsetOf` createPitchClassSet ys


{-----------------------------------------------------------------------------
    Note Utilities
------------------------------------------------------------------------------}
-- | Get the pitches of the notes that start simultaneously
-- with the first note.
getOnsetNotes :: Notes -> Notes
getOnsetNotes xs = filter ((start (head xs) ==) . start) xs

-- | Collect all channel numbers that occur in the notes
getChannelNumbersFromEvents :: Notes -> [Int]
getChannelNumbersFromEvents = Set.toList . Set.fromList . map channel

-- | Return all Notes that are played on the indicated channel.
getChannel :: Channel -> Notes -> Notes
getChannel c = filter ((== c) . channel)

-- | Return all Notes that are *not* played on the indicated channel.
getOtherChannels :: Channel -> Notes -> Notes
getOtherChannels c = filter ((/= c) . channel)

-- | Transpose all pitches by the specified interval.
-- (Except for notes with pitch value @0@).
transpose :: Interval -> Notes -> Notes
transpose d = map f
    where
    f x = if pitch x /= 0 then x { pitch = d + pitch x } else x

-- | Remove all notes that start before or at an indicated time.
clearTo :: Time -> Notes -> Notes
clearTo t = filter (not . (<= t) . start)

-- | Get all notes that /start/ within a specified time interval.
-- The interval is half-open, i.e. @[t1,t2)@.
getRegion :: (Time,Time) -> Notes -> Notes
getRegion region = filter (`within` region)
    where within note (t1,t2) = t1 <= start note && start note < t2

-- | Remove all notes that /start/ within a specified time interval.
-- The interval is half-open, i.e. @[t1,t2)@.
removeRegion :: (Time,Time) -> Notes -> Notes
removeRegion region = filter $ not . (`within` region)
    where within note (t1,t2) = t1 <= start note && start note < t2

{-----------------------------------------------------------------------------
    Time utilities
------------------------------------------------------------------------------}
type Timing = (Channel, Time)

-- | "This looks ahead to get the first time they end together".
firstPlaceWhereAllTogether :: Notes -> Time
firstPlaceWhereAllTogether notes = allTogether orderedTimingsByChannel
    where
    endingTimes = plotTimings notes
    orderedTimingsByChannel =
        [ collectTimingsByChannel endingTimes c
        | c <- getChannelNumbersFromEvents notes]

-- | "Returns the appropriate channel timing."
allTogether :: [[Timing]] -> Time
allTogether (c:cs)
    | c == []   = snd $ last $ last cs -- here is our remaining problem!!!!!
    | Just x <- findAlignmentInAllChannels (snd $ head c) cs = x
    | otherwise = allTogether (tail c:cs)

findAlignmentInAllChannels :: Time -> [[Timing]] -> Maybe Time
findAlignmentInAllChannels point channels
    | null channels = Just point
    | findAlignment point (head channels) =
        findAlignmentInAllChannels point (tail channels)
    | otherwise     = Nothing


-- | Checks whether a given time appears in the channel.
-- findAlignment 1000 [(4,1000),(4,1000),(4,5000)] == True
findAlignment :: Time -> [Timing] -> Bool
findAlignment point channel
    | null channel = False
    | thousandp point
      && isJust (lookup point $ map swap channel)
                   = True
    | otherwise    = findAlignment point (tail channel)

swap (x,y) = (y,x)

-- | Checks whether the number is a multiple of thousand.
thousandp :: Time -> Bool
thousandp n = 0 == (round n `mod` 1000)

-- | Get the channels and ending times of the notes.
plotTimings :: Notes -> [Timing]
plotTimings xs = [(channel x, end x) | x <- xs]

-- | Collect the ending times by the indicated channel
collectTimingsByChannel :: [Timing] -> Channel -> [Timing]
collectTimingsByChannel xs c = [x | x@(c',_) <- xs, c == c' ]


-- | Adjust starting times so that the first note starts at zero.
setToZero :: Notes -> Notes
setToZero xs = [ x { start = start x - diff } | x <- xs ]
    where
    diff = start $ head xs

-- | Subtract a time interval from every starting time.
resetBeats :: Time -> [Notes] -> [Notes]
resetBeats dt = map $ map $ \note -> note { start = start note - dt }

-- | Total duration of a piece of music.
totalDuration :: Notes -> Time
totalDuration notes = last - first
    where
    last  = maximum . map end   $ notes
    first = minimum . map start $ notes

-- | Remove all notes that begin within a beat from the first note.
--
-- Note: This function adds up all durations and assumes that the
-- events are consecutive. In particular, it only makes sense when
-- applied to a single channel.
--
-- >>> removeFullBeat [note 77000 41 500 4, note 77500 43 500 4]
-- []
removeFullBeat :: Notes -> Notes
removeFullBeat xs = drop segment xs
    where
    segment = length $ takeWhile (< 1000) $ scanl (+) 0 $ map duration xs

-- | Take the last part of the note that lasts only a fraction of a beat.
--
-- >>> remainder $ note 76000 41 1500 4
-- [Note {pitch = 41, start = 77000 % 1, duration = 500 % 1, channel = 4}]
remainder :: Note -> [Note]
remainder note
        | 1000*beats == duration note = []
        | otherwise                   = [note
            { start    = start    note + 1000*beats
            , duration = duration note - 1000*beats
            }]
    where
    beats = fromIntegral $ floor $ duration note / 1000

-- | Given a time, return all events that start at this time and are on a full beat.
-- Returns an empty list if the time is not on the beat.
getOnBeat :: Time -> Notes -> Notes
getOnBeat t xs = if thousandp t then takeWhile ((t ==) . start) xs else []

-- | Check whether all events start at the indicated time
-- and whether this time is on a beat.
onBeat :: Time -> Notes -> Bool
onBeat t xs = thousandp t && all ((t==) . start) xs

-- | Break notes into beat-sized groupings.
-- Each note may be split into several parts with duration 1000 each.
--
-- >>> breakIntoBeats [note 20000 48 2000 4, note 20000 55 2000 3, note 20000 64 2000 2, note 20000 72 2000 1] 
-- [Note {pitch = 48, start = 20000 % 1, duration = 1000 % 1, channel = 4},Note {pitch = 55, start = 20000 % 1, duration = 1000 % 1, channel = 3},Note {pitch = 64, start = 20000 % 1, duration = 1000 % 1, channel = 2},Note {pitch = 72, start = 20000 % 1, duration = 1000 % 1, channel = 1},
--  Note {pitch = 48, start = 21000 % 1, duration = 1000 % 1, channel = 4},Note {pitch = 55, start = 21000 % 1, duration = 1000 % 1, channel = 3},Note {pitch = 64, start = 21000 % 1, duration = 1000 % 1, channel = 2},Note {pitch = 72, start = 21000 % 1, duration = 1000 % 1, channel = 1}]
breakIntoBeats :: Notes -> Notes
breakIntoBeats = sortByStart . concat . chopIntoBites . sortByStart

chopIntoBites :: Notes -> [Notes]
chopIntoBites [] = []
chopIntoBites (x:xs)
    | thousandp (start x) && duration x == 1000 = [x] : chopIntoBites xs
    | duration x > 1000  = chop x : chopIntoBites (remainder x ++ xs)
    | otherwise          = getFullBeat (getChannel c (x:xs))
                         : chopIntoBites (rest ++ getOtherChannels c xs)
    where
    c = channel x
    beat = getFullBeat $ getChannel c $ x:xs
    rest = remainders $ removeFullBeat $ getChannel c $ x:xs

-- | Chop a note into beat-sized pieces, discarding any remainders.
--
-- >>> chop $ note 20000 48 2000 4
-- [Note {pitch = 48, start = 20000 % 1, duration = 1000 % 1, channel = 4},Note {pitch = 48, start = 21000 % 1, duration = 1000 % 1, channel = 4}]
chop :: Note -> [Note]
chop note
    | duration note < 1000 = []
    | otherwise            =
        note { duration = 1000 }
            : chop (note { start = start note + 1000, duration = dur - 1000})
    where
    dur = duration note

-- | Get a full beat of the music.
--
-- Assumes that the notes are consecutive and the first note starts on the beat.
getFullBeat :: Notes -> Notes
getFullBeat xs = go 0 xs
    where
    go dur []     = []
    go dur (x:xs)
        | dur + duration x == 1000 = [x]
        | dur + duration x >  1000 = [x { duration = 1000 - dur }]
        | otherwise                = x : go (dur + duration x) xs
    -- dur keeps track of how far we are already into the beat

-- | Returns remainders of beats, i.e. what 'getFullBeat' leaves over.
--
-- Assumes that the notes are consecutive and the first note starts on the beat.
remainders :: Notes -> Notes
remainders xs = go (start $ head xs) 0 xs
    where
    go beginTime dur []     = []
    go beginTime dur (x:xs)
        | dur + duration x == 1000 = []
        | dur + duration x >  1000 = [x { start = beginTime + 1000 - dur, duration = duration x - (1000 - dur) }]
        | otherwise                = go (beginTime + duration x) (dur + duration x) xs  

{-----------------------------------------------------------------------------
    Composition
------------------------------------------------------------------------------}
-- | Increment beat number.
--
-- WARNING: This function increments only the last digit in the string.
-- I think this is a bug.
--
-- >>> incfBeat "b35300b-42"
-- "b35300b-3"
--
-- TODO: Beat names should probably be modeled as pairs @(String, Int)@.
incfBeat :: Name -> Name
incfBeat name = getDBName name ++ "-" ++ (show $ ord (last name) - ord '0' + 1)
    where
    getDBName = takeWhile (/= '-')

-- | Compose a chorale by stitching together beats from the database
-- and ensuring that the piece has a proper cadence.
composeBach :: Database -> Prob Notes
composeBach db = do
    mbeats <- composeMaybePiece db
    let
        Just names = mbeats
        notes = concat $ reTime $ map events
              $ catMaybes [Map.lookup name (beatIts db) | name <- names]
        lastNote = last notes

        continue
            = isNothing mbeats
            || end lastNote <  15000
            || end lastNote > 200000
            || not (waitForCadence notes)
            || checkForParallel notes

    if continue
        then composeBach db
        else return $ finish notes

    where
    finish = cadenceCollapse . transposeToBachRange
           . fixUpBeat . ensureNecessaryCadences

    fixUpBeat notes =
        if checkMT $ getOnBeat (start $ head notes) notes  -- starts on tonic
        then notes
        else delayForUpbeat notes   -- the piece actually begins with an upbeat

-- | Transpose a piece of music into a pitch range commonly used by Bach.
transposeToBachRange :: Notes -> Notes
transposeToBachRange notes = transpose middle notes
    where
    low  = minimum $ map pitch notes
    high = maximum $ map pitch notes
    middle = round $ fromIntegral ((83-high) + (40-low)) / 2

-- | Start piece of music at time 3000.
delayForUpbeat :: Notes -> Notes
delayForUpbeat = delay 3000 . setToZero
    where
    delay dt = map $ \note -> note { start = start note + dt }

-- | Retime a sequence of beats to fit together.
reTime :: [Notes] -> [Notes]
reTime = go 0
    where
    go currentTime []     = []
    go currentTime (x:xs) = map shift (setToZero x)
                          : go (currentTime + totalDuration x) xs
        where
        shift note = note { start = start note + currentTime }

-- | Check for parallel motion in the first two beats.
--
-- >>> checkForParallel $ concat [[note 0 (60+i) 1000 i, note 1000 (64+i) 1000 i] | i<-[1..4]]
-- True
checkForParallel :: Notes -> Bool
checkForParallel notes = case sortedPitchesByBeat notes of
    (x:y:_) -> let differences = zipWith (-) x y in
        length x == 4 && length y == 4
        && (all (>=0) differences || all (<0) differences)
    _       -> False

sortedPitchesByBeat
    = map (map pitch)
    . map (\beat -> getOnBeat (start $ head beat) beat)
    . collectBeats . take 30 . sortByStart

-- | Returns the major tonic.
checkMT :: Notes -> Bool
checkMT notes
        =  (harmonicSubset pitches [0,4,7] || harmonicSubset pitches [0,3,7])
        && (firstNote `mod` 12 == 0)
    where
    pitches    = map pitch notes
    firstNote  = head $ map pitch $ getChannel 4 $ sortByStart notes


data Mood = Major | Minor
    deriving (Eq,Ord,Show,Read)

-- | Try to compose a complete piece by stitching together beats from the database.
-- May fail.
composeMaybePiece :: Database -> Prob (Maybe [Name])
composeMaybePiece db = do
    mbeat <- pickTriadBeginning db
    case mbeat of
        Nothing   -> return Nothing
        Just (name, mood) -> do
            let
                findEventsDuration = totalDuration . getChannel 1
            
                loop :: Int -> Name -> Prob (Maybe [Name])
                loop counter name
                    | null (destinationNotes beatit)     = return Nothing
                    | counter > 36
                      && findEventsDuration notes > 1000
                      && (if mood == Minor
                            then matchTonicMinor notes
                            else matchBachTonic  notes)  = return $ Just [name]
                    | otherwise                          = do
                        case pickNextBeat db name of
                            Nothing     -> return Nothing
                            Just pname' -> do
                                name'   <- pname'
                                mresult <- loop (counter+1) name'
                                return $ fmap (name:) mresult

                    where
                    Just beatit = Map.lookup name (beatIts db)
                    notes       = events beatit

            loop 0 name

-- | Pick a suitable next beat from the database.
pickNextBeat :: Database -> Name -> Maybe (Prob Name)
pickNextBeat db name = do
    beatit  <- Map.lookup name                      (beatIts  db)
    choices <- Map.lookup (destinationNotes beatit) (lexicons db)
    return $ case Set.toList choices of
        [x] -> return x
        xs  -> choose $ xs \\ [name, incfBeat name]
            -- write an email concerning  incfBeat

-- | Pick a triad beginning. May fail.
pickTriadBeginning :: Database -> Prob (Maybe (Name,Mood))
pickTriadBeginning db = do
    name <- choose (startBeats db)
    let
        Just beatit = Map.lookup name (beatIts db)
        mood        = if matchTonicMinor $ take 4 $ events beatit
                      then Minor else Major
        
        notes   = events beatit
        pitches = map pitch $ getOnBeat (start $ head notes) notes
        isGood  =
            any (pitches `harmonicSubset`)            -- one of the good triads
                [[0,4,8], [0,4,7], [0,5,8], [2,7,11]]
            && (duration (head notes) <= 1000)
            && length notes == 4

    return $ if isGood then Just (name, mood) else Nothing


-- | Check whether the notes form a C minor tonic.
matchTonicMinor :: Notes -> Bool
matchTonicMinor notes = not (null chord) && harmonicSubset chord [60,63,67]
    where
    chord = map pitch $ getLastBeatEvents $ breakIntoBeats notes

-- | Check whether the notes form a C major tonic.
matchBachTonic :: Notes -> Bool
matchBachTonic notes = not (null chord) && harmonicSubset chord [60,64,67]
    where
    chord = map pitch $ getLastBeatEvents $ breakIntoBeats notes

    -- This is incorrect. The pitches need to match in order?

-- | Retrieve the last four events if the first of them has a duration
-- that is a multiple of 1000. Return an empty list otherwise.
getLastBeatEvents :: Notes -> Notes
getLastBeatEvents notes
    | length lastBeat == 4 && thousandp (duration $ head lastBeat) = lastBeat
    | otherwise                                                    = []
    where
    beginTime = start $ last $ sortByStart notes
    lastBeat  = filter ((beginTime ==) . start) notes

{-----------------------------------------------------------------------------
    Cadences
------------------------------------------------------------------------------}
-- | Ensure that the cadence has proper length.
--
-- TODO: Simplify
waitForCadence :: Notes -> Bool
waitForCadence xs = go (start $ head xs) xs
    where
    go _ []                  = False
    go t (x:xs)
        | start x > t + 4000 = True
        | duration x > 1000  = False
        | otherwise          = go t xs

-- | Ensures the final chord will not have offbeats.
--
-- TODO: I don't see how this is supposed to work.
-- Durations 2000 are simply made to 1000s?
cadenceCollapse :: Notes -> Notes
cadenceCollapse = concat . collapse . collectBeats . sortByStart
    where
    collapse [] = []
    collapse (x:xs) = if length x == 4 && duration (head x) == 2000
        then map fixDuration x : collapse (resetBeats 1000 xs)
        else                 x : collapse xs

    fixDuration note = note { duration = 1000 }


-- | Ensure that long phrases consisting of interleaving notes
-- are interrupted by full chords.
--
-- Assumes that the notes are ordered by starting times.
ensureNecessaryCadences :: Notes -> Notes
ensureNecessaryCadences notes =
    discoverCadences (getLongPhrases $ pad0 cadenceStartTimes) notes
    where
    cadenceStartTimes = findCadenceStartTimes notes
    pad0 xs = if head xs /= 0 then 0 : xs else xs

-- | Returns phrases of duration greater than 12000 (3 measures)
getLongPhrases :: [Time] -> [(Time,Time)]
getLongPhrases xs = filter p $ zip xs (drop 1 xs)
    where p (x,y) = y-x > 12000

-- | Find all times where the notes form a well-distinguished chord
-- of quarter or half note length. In other words,
-- the chord contains no held notes or passing notes.
findCadenceStartTimes :: Notes -> [Time]
findCadenceStartTimes []    = []
findCadenceStartTimes notes = case distanceToCadence notes of
    Nothing -> findCadenceStartTimes (tail notes)
    Just d  -> d : findCadenceStartTimes (clearTo d notes)

distanceToCadence :: Notes -> Maybe Time
distanceToCadence notes = with min quarterNoteDistance halfNoteDistance
    where
    quarterNoteDistance = find1000s notes
    halfNoteDistance    = find2000s notes
    
    with f Nothing  Nothing  = Nothing
    with f (Just x) Nothing  = Just x
    with f Nothing  (Just y) = Just y
    with f (Just x) (Just y) = Just $ f x y

-- | Returns the ontime if all events have duration 1000.
--
-- >>> find1000s [note 3000 61 1000 1, note 3000 69 1000 2, note 3000 69 1000 3, note 3000 69 1000 4]
-- Just (3000 % 1)
find1000s = findWithDuration 1000

-- | Returns the ontime if all events have duration 2000.
find2000s = findWithDuration 2000

findWithDuration :: Time -> Notes -> Maybe Time
findWithDuration dt []    = Nothing 
findWithDuration dt notes
    | all checkNote channels = Just startTime
    | otherwise              = findWithDuration dt (tail notes)
    where
    channels = [ head channel | c <- [1..4]
               , let channel = getChannel c notes
               , not (null channel)
               ]
    checkNote x = start x == startTime && duration x == dt
    startTime   = start $ head $ notes

-- | Discover and resolve cadences within the specified phrases.
discoverCadences :: [(Time,Time)] -> Notes -> Notes
discoverCadences []     ys = ys
discoverCadences (x:xs) ys = discoverCadences xs $ discoverCadence x ys

-- | Discover and resolve possible cadences.
discoverCadence (x,y) notes = case bestLocationForNewCadence of
        Nothing  -> notes   -- couldn't find a place to insert cadence
        Just pos -> sortByStart $ resolve (getRegion (pos, pos+1000) relevantNotes)
                                  ++ removeRegion (pos, pos+1000) notes
    where
    relevantNotes    = getRegion (x,y) notes
    placesForCadence = findCadencePlace relevantNotes
    bestLocationForNewCadence = if null placesForCadence
            then Nothing
            else Just $ findClosest ((x+y)/2) placesForCadence
                -- place the cadence somewhere in the middle.

-- | Find the best places for a first cadence.
findCadencePlace :: Notes -> [Time]
findCadencePlace = map (start . head) . filter p . collectBeats
    where
    p beat =  onBeat onTime (take 4 beat)       -- a chord on the beat
           && isTriad (map pitch $ take 4 beat) -- which forms a triad
           && all notBeyond1000 beat            -- no notes that end beyond onTime + 1000
        where
        onTime             = start $ head beat
        notBeyond1000 note = end note - onTime <= 1000

-- | Resolves the beat if necessary.
--
-- Keep all notes that start simultaneously with the first one
-- and elongate their durations to 1000 if necessary.
resolve :: Notes -> Notes
resolve = map fixDuration . getOnsetNotes
    where
    fixDuration note = if duration note < 1000 then note { duration = 1000 } else note 




# Lockstep

A macOS app (Swift 6, macOS 26.0, Apple silicon) for recording rap vocals on the beat of a song.
See README.md for what it does. This file is for whoever carries the code on, and for their AI
agent.

## Commands

Run from the repository root. All build output goes to `build/`, which git ignores.

- Build the app:
  `xcodebuild -project Lockstep.xcodeproj -scheme Lockstep -configuration Debug -derivedDataPath build/DerivedData build`
- Run the app (after building):
  `open build/DerivedData/Build/Products/Debug/Lockstep.app`
- Build the design lab app (Lockstep Design, which shows the interface with made-up content):
  `xcodebuild -project Lockstep.xcodeproj -scheme LockstepDesign -configuration Debug -derivedDataPath build/DerivedData build`
- Run the design lab app (after building):
  `open "build/DerivedData/Build/Products/Debug/Lockstep Design.app"`
- Run all tests (both LockstepKit test targets and the speech library's tests; the three that load the real speech models need both models installed and run only when `LOCKSTEP_SPEECH=1` reaches them, which with `xcodebuild` means `TEST_RUNNER_LOCKSTEP_SPEECH=1` in front of this command):
  `xcodebuild test -project Lockstep.xcodeproj -scheme Lockstep -derivedDataPath build/DerivedData`
- Run only the LockstepKit tests, without Xcode's app build: `swift test --package-path LockstepKit`
- Save a picture of the app's window (builds, starts the app behind the other windows, saves the picture, quits the app; extra launch arguments go after the file name):
  `Scripts/screenshot.sh /tmp/lockstep-window.png`
- The same for the design lab, where a launch argument picks what it shows:
  `Scripts/screenshot.sh --app LockstepDesign /tmp/lockstep-design.png -state Main`
- Install the beat model (once per Mac; downloads 81 MB, converts it with `uv`, and puts it at `~/Library/Application Support/Lockstep/Models/BeatThis.mlpackage`, outside the repository; `--force` makes it again):
  `Scripts/install-beat-model.sh`
- Install the speech models that write out the words of clips (once per Mac; KB-Whisper Small for Swedish, 488 MB, and Whisper large-v3-turbo q5_0 for any language, 574 MB, from Hugging Face, checked against their checksums, put in `~/Library/Application Support/Lockstep/Models/Speech/`; `swedish` or `multilingual` installs only that one, `--force` downloads again):
  `Scripts/install-speech-model.sh`
- Check the syntax of the DaVinci Resolve script: `luajit -bl Lockstep/Resources/Lockstep.lua`
- Show that a change that should change nothing changes nothing: keep a set of runs before the change with `Scripts/same-behaviour.sh --save build/same-behaviour/before`, then compare after it with `Scripts/same-behaviour.sh --compare build/same-behaviour/before` (see "Checking that behaviour is unchanged" below).
- Measure how fast edits are in a big test project: `Scripts/time-edits.sh build/time-edits/now` (see "Measuring speed" below).

The project file `Lockstep.xcodeproj` was generated from `project.yml` with XcodeGen and is committed, so building needs only Xcode. Run `xcodegen` after changing `project.yml`.

## Signing

Without `Config/Signing.local.xcconfig` both apps are signed to run locally, which any Mac can build. That file is git-ignored and may hold your own team (`DEVELOPMENT_TEAM = <team id>`, `CODE_SIGN_IDENTITY = Apple Development`). macOS keeps the microphone permission per signature, so a locally signed build asks again after each rebuild that changes the signature.

## Boundaries

- Build only what the current plan lists. Park other ideas and mention them.
- Keep it simple: only the interface each feature needs. A setting arrives with the feature it controls.
- Tests only where a task asks for them. They are written with the code. Run the whole suite at the end of a piece of work, not after every step.
- An agent starts Lockstep only with `-scratch <folder>` (a fresh folder of its own, inside `build/`) and `-silent`, in the background (`open -g`), and addresses its own run only by the process id it started, never by name: the person using the Mac may have their own copy of Lockstep open. `Scripts/screenshot.sh` does all of this.
- An agent never opens the microphone. Takes are fed from files (`-addTake`, `-recordTake`, `-loopTake`).
- Nothing an agent runs may make sound through the speakers.
- Agents never write to DaVinci Resolve's real folders, never start DaVinci Resolve and never run the script in it.
- Launch arguments that take no value (`-silent`, `-tighten`, `-stretch`, `-sendDry`, `-trackVoiceOff`, `-deleteClip`, `-pasteClip`, `-middleDrag`, `-bigProject`, `-timeEdits`) go last, after every argument that takes one. macOS pairs each `-name` with the word after it, so `-tighten -sendClip <path>` leaves the path standing alone, the system hands it to Lockstep as a file to open, and the song given with `-open` never opens.
- Leave a few seconds between quitting one scratch run and starting the next.

## The scratch folder

- With `-scratch <folder>`, settings go to `<folder>/Settings.plist` and projects to `<folder>/Projects/<Song name>.lockstep`, unless the scratch folder's own settings name a projects folder inside it, which then wins. A folder outside the scratch folder is never used. The memory of the last project and of recent projects is the scratch folder's own. Nothing is reopened at start.
- Settings can be written into `<folder>/Settings.plist` before the run: for example `inspectorShown` (whether the panel on the right is open), `speech.language` (`swedish` or `automatic`), `recording.speedPercent`, `davinci.sendWithSound`, `sound.ownPresets` and `voices.ownPresets`.
- A scratch run neither reads nor writes the memory of open windows that macOS keeps for Lockstep, so it always opens its window. Its first line on standard error is AppKit's own, starting with `ApplePersistenceIgnoreState:`.
- A scratch run prints one more line at Quit: how often what the window shows was written, how many orders the player was told, and how often the window was worked out (`Lockstep/App/RunCounts.swift`).
- `-open <path>` takes a song or a `.lockstep` project. A project's `project.json` is readable text, so what was saved can be checked from outside.

## Launch arguments for agents

Each argument below acts only in a run with `-scratch`, through the same code the menus, keys and controls use, and prints one line to standard error (starting with `Lockstep:`) saying what it did or why not. The full list, with the order in which they act, is at the top of `Lockstep/App/LaunchOptions.swift`. Song seconds are counted from the first sample of the song file, also when the song's start is cut away or the song is moved so that the timeline's 00:00 lies inside it.

Opening and adding takes:

- `-open <path>`: a song or a `.lockstep` project to open.
- `-silent`: nothing reaches the speakers; playback and positions work the same. A run with `-silent` never loads the speech model.
- `-clickFile <path>`: once the beats are found, writes the click file there (from the timeline's 00:00 to the end of what is kept of the song).
- `-addTake <wav file>` (48,000 Hz), with `-open`: adds the sound as if it had just been recorded with Record pressed at the very start of the song (a clip on the first track, one undo step, saved with the project). Give it several times to add several files in order: all aimed at the start, they become takes of one line. `-addTake <wav file>@<seconds>` aims the file at that place instead (its first sample is heard there). A file aimed within 50 ms of where a shown clip starts, or of where that clip was recorded from, becomes a new take of that line. A file aimed anywhere else is a clip of its own and wins: the clips it covers are shortened, divided or removed. No rest shorter than 100 ms is left of a clip cut this way.
- `-recordTake <wav file>` (48,000 Hz), with `-open`: once the song is open and the beats are found (or could not be), presses Record at the playhead with the count-in from the settings, records 3 s, restarts twice (the second time keeping the dropped attempt as a clip) and presses Stop. The recorder hears the file in the microphone's place. One line for the take's start, each restart and Stop, with how many samples each attempt held and what became of it. Places follow the clock and differ by some milliseconds between runs; compare sample counts, not places.
- `-recordSpeed <percent>` (90 or 85), with `-recordTake`: records against the slowed song and speeds the take up when it ends. In `project.json` the recording gets `recordedSpeed`; its file in `takes/` is the slow original, and `cache/sped-up/<recording id>.wav` holds the sped-up sound.
- `-loop <start>,<end>` (seconds): once the beats are known, Loop goes on for that stretch, made whole bars.
- `-loopTake <wav file>` (48,000 Hz), with `-loop`: treats the file as a finished loop recording that started at the loop's start with the count-in off.
- `-playhead <seconds>`: moves the playhead after the takes are in. Edit > Split at Playhead then acts on the clip under it.
- `-clipText <text>`: gives the first clip of the first track these words, as a finished transcription would. Use it to show words without the speech model.

Correction:

- `-tighten`: every clip of the first track gets Lines at 100 %, so each line slides until its first syllable stands on the nearest sub-beat. One line gives each line's start and shift in milliseconds. A line with too little room in its clip slides out of it; the clip in `project.json` stays as it is, and the clip is heard, shown and exported from where the line now starts. What stops a line is the clip before or after it on the same track, the ends of what is kept of the song, and the furthest slide in Settings > Timing.
- `-strength <percent>` (0 to 100): every clip of the first track gets All with that strength. One line gives each syllable that moved, with its place and move, how many are excluded and how many runs were stretched. The strength also scales the slide of the lines.
- `-stretch`, with `-tighten` or `-strength`: also switches Stretch on for those clips. Without it nothing is stretched.
- `-lockedDouble <wav file>` (48,000 Hz), with `-open`: adds a second track, puts the file on it as a take at the very start of the song and gives its clip All at 100 % aimed at the first track (with Stretch when `-stretch` is given). One line gives how many syllables are paired, how many note ends were matched, and for each syllable where its partner is and how far it moves. A syllable further from its partner than the furthest move in Settings > Timing (40 ms) once its line has slid gets no partner.

Sound and effects:

- `-trackVolume <dB>` (-24 to +12) and `-songVolume <dB>` (-24 to 0), with `-open`: the first track's or the song's volume, as the slider in the panel sets it. They are `gainDb` of the track and `songGainDb` in `project.json`, and only the player hears them: recordings, the click file and Send to DaVinci never have them.
- `-trackSound <preset name>`: the first track gets that Sound ("Rap lead", "Rap double", "Ad-lib", "Sung lead", "Sung hook", "Backing voice", or one of `sound.ownPresets` in the scratch settings, with `name`, `character`, the knobs `squeeze`, `tone`, `warmth`, `space` from 0 to 1, and optionally `effects`). Lockstep waits until the finished sounds of the track's clips are made. It is `sound` of the track in `project.json`. Finished sounds are kept in memory only.
- `-clipKnob <knob>=<percent>` (`squeeze`, `tone`, `warmth` or `space`, 0 to 100): after `-trackSound`, the first clip of the first track gets that knob for itself (`knobs` of the clip).
- `-trackEffect <kind>` (`thick`, `lowFourth`, `lowOctave`, `high`, `big`, `small`, `echoQuarter`, `echoEighth` or `phone`): the first track gets that effect. Give it several times for several. An echo first waits for the beats. They are `effects` of the track.
- `-clipTrackEffect <kind>=<dB>` (-24 to 6) or `<kind>=off`: the first clip of the first track gets its own level for the track's first effect of that kind, or is switched off for it (`effectChanges` of the clip).
- `-double <kind>` or `-double <kind>@<from>-<to>` (`thick`, `lowFourth`, `lowOctave`, `high`, `big`, `small`; song seconds): the first clip of the first track gets that double, on the whole clip or on that stretch, whose ends catch on syllables, pauses and the clip's edges within 60 ms. A double on a stretch first waits up to a minute for the clip's syllables.
- `-wordEffect <kind>` or `-wordEffect <kind>@<from>-<to>` (`echoQuarter`, `echoEighth`, `phone`, `stutter`, `tapeStop` or `swell`): the same for an effect on words. An echo, a stutter and a swell are placed by the beats, so they wait for them. An echo on a stretch that starts before the song's first beat has no repeats.
- `-pasteSound clips` or `-pasteSound track`: copies the sound of the first clip of the first track and pastes it on every other shown clip of that track, or on the track itself, as Edit > Copy Sound and Paste Sound do. Effects on words are never part of a copied sound.
- `-trackVoice <preset or knobs>`: a preset ("Darker", "Deeper", "Lighter", or one of `voices.ownPresets` with `name`, `depth`, `pitch`) or knobs written `depth=8,pitch=-1.5` (Depth -15 to 15 %, Pitch -4 to 4 semitones in half steps). The first track gets that Voice and Lockstep waits until the voices of its clips are made or read (ten minutes at most). `-trackVoiceOff` switches it off again after everything else. The track Voice is not in `FeatureSet.built`, so the window does not show it; these arguments still reach its code. Voices are files in `cache/voices/<way>/<setting>/<recording id>.wav` of the project folder.

Sending and editing:

- `-sendClip <path>` (inside the scratch folder): exports the first clip of the first track exactly as Send to DaVinci would, after everything above has acted, and writes the list for the Resolve script to `<folder>/DaVinci/clips.lua`. One line gives the timecode, the length in samples, the channels, the padding, the tail, and whether it was sent with its sound or dry. A clip with a finished sound (its track has a Sound or effects, or the clip has an effect) becomes a stereo file with its tail. A clip on a track whose Voice is heard waits for its voice.
- `-sendDry`: with `-sendClip`, switches "With sound" off first, so the clip is sent dry.
- `-pasteClip`: copies the first clip of the first track and pastes it at the playhead on that track.
- `-selectRect <start>,<end>,<tracks>`: drags a selection rectangle from the first track over that many tracks between two song seconds, through the function the window reports a real drag to, and says how many clips are selected on each track. With 1 for the tracks it marks a stretch instead.
- `-deleteClip`: selects, deletes and brings back the first clip of the first track three times (the last while the song plays), with the milliseconds to every step. Do not attach a profiler (`sample`) to such a run: it holds the app still the first time it meets a new call stack.
- `-bigProject`, with `-open`: once the beats are found, fills the project up to 20 tracks with 400 lines, about 285 waiting takes, words on every clip and a mix of corrections (`Lockstep/App/BigTestProject.swift`). It is the same project in every run.
- `-timeEdits`, after `-bigProject` or `-addTake`: makes a list of edits on up to 30 clips three times each and prints one timing line for each. A run takes about five minutes.
- `-middleDrag`, with `-open`: feeds six made-up middle-button drags through the timeline's own catcher and reports how many display frames were shown.

Menu commands without a pointer: `Scripts/same-behaviour/menu.swift` presses a menu item of a running app found by its process id, through the accessibility API (`menu <pid> press File "Send to DaVinci..."`). It never uses System Events, which finds an app by name and could reach another copy of Lockstep. The app that runs it needs Privacy & Security > Accessibility. Pictures of a run's own window: `screencapture -x -o -l <window id>`, with the window id looked up for the run's process id (as `Scripts/screenshot.sh` does).

## What is kept where

- A project is a `.lockstep` folder: `project.json` (the song, the beat grid, tracks, clips, recordings), `song.wav`, `takes/` (the original recordings, never changed), `cache/` (beats, syllable markers, envelopes, sped-up takes and voices, all of which can be deleted and are made again), `exports/` and `view.json`.
- `view.json` keeps how the project was last shown: `pointsPerSecond` (0 means "fit"), `scrollOffsetSeconds`, `rowsScrollPoints`, `trackHeight`, `playheadSeconds`, `selectedTrackID`, `selectedClipIDs`, and `loopInSeconds` and `loopOutSeconds`. It is written within a second of a change, is no undo step, and never changes `project.json`. Editing it before opening a project is a simple way to set the zoom and the selection for a picture.
- The cut and the place of 00:00 are `songPlace` in `project.json` (`cutStartSamples`, `cutEndSamples`, `zeroSample`). The time the window shows is the song seconds minus `zeroSample / 48000`.
- Every edit writes a line with its timing to the Mac's log (category `EditTiming`), and so does the player each time it takes changed clips over. Read them with `/usr/bin/log show --last 1h --info --predicate 'subsystem == "se.maxfahl.lockstep" AND category == "EditTiming"'`. Voices log under category `Voice`.

## Send to DaVinci

Send to DaVinci places clips through a script inside DaVinci Resolve (`Lockstep/Resources/Lockstep.lua`, built into the app). A normal run writes the list to `~/Library/Application Support/Lockstep/DaVinci/clips.lua`, and the Install button in Settings > DaVinci copies the script to `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/Lockstep.lua`. In a `-scratch` run the list goes to `<folder>/DaVinci/clips.lua` and the button writes `<folder>/DaVinci Resolve/Fusion/Scripts/Utility/Lockstep.lua`. The script reads `channels` of each clip in the list (a list without it means 1): a track it has to add for a stereo clip is added as stereo, and of two clips of one send that are heard at the same time on one track, the later one goes to a second track named like the first with " B" after it. No agent has run the script in Resolve.

## Words on clips

The words of clips are written out by whisper.cpp (`LockstepSpeechKit`), which Swift Package Manager downloads as the prebuilt XCFramework of build b5454 (v1.9.5), pinned by its checksum in `LockstepSpeechKit/Package.swift`. Settings > Recording > "Language of the words" (`speech.language`: `swedish` or `automatic`) picks the model. A fresh settings store starts with Swedish only when the Mac's first language is Swedish. When the chosen language's model is not installed, clips get no words, and the window and one line on standard error say once how to install it. The names, sizes and checksums of the models are in both `Scripts/install-speech-model.sh` and `LockstepSpeechKit/Sources/LockstepSpeech/SpeechModelFile.swift`; keep them the same. A run without `-silent` loads a model (about 1.3 GB while it works, freed after 30 s without clips).

## Checking that behaviour is unchanged

`Scripts/same-behaviour.sh` shows that a change meant to change nothing (a refactor) changes nothing. It makes eight runs of the built app, each with a fresh scratch folder under `build/same-behaviour/work/` and `-silent`, and quits each through the app's own Quit: `long`, `loop`, `take`, `looptake`, `menu` (about eighty menu commands pressed one by one by process id), `reopen`, `delete` and `drag`. What they printed and saved is written into a set with ids, dates and what follows the clock made the same. `--save <folder>` keeps a set, `--compare <folder>` makes a new one in `build/same-behaviour/now/` and lists what differs in `COMPARISON.txt`, and `--only <run>,<run>` makes some of the runs. Keep a set from the commit before your change and compare after it. On a busy Mac a project is now and then written later than the script waits after a menu command; make that run again (`--only menu`) before calling such a difference a fault. Nobody may click the windows it opens while it runs.

## Measuring speed

`Scripts/time-edits.sh [--app <Lockstep.app>] [--runs <n>] [--song <file>] <folder>` runs the built app with `-silent -bigProject -timeEdits` several times, each with a fresh scratch folder, keeps what each printed in `<folder>/run-<n>.txt` and writes the means as a table to `<folder>/TABLE.md`. Without `--song` it makes its own song (three and a half minutes, a drum beat at 120 beats a minute). Use a folder inside `build/`. A window that other windows cover completely is not drawn, so only runs with a visible window say what drawing costs, and the load of the Mac moves every number: compare two builds only from runs made in turn at the same time.

## Component rule

The look is written down in `docs/design/design.md`, with a picture of every component in every state in `docs/design/states/`. Follow it for every view.

A new or changed component is built in `LockstepUI`, added to the design lab with every state it can be in, checked in its pictures, and only then used in Lockstep and added to the catalogue in that document. The real app contains no view that is not made of components from `LockstepUI`.

## Audio callback rule

Every block handed to AVFoundation, Core Audio or NotificationCenter is created in a `nonisolated` function, is marked `@Sendable`, and touches only Sendable or lock-protected state. A block written inside a `@MainActor` type compiles without a warning and crashes when the system calls it on its own thread.

## The app's model

A feature is a part of its own: a `@MainActor final class <Feature>Model` in `Lockstep/Model/`, with its own state. A part never holds the `AppModel`. It is handed what it needs when it is made: the shared objects in `Lockstep/Model/Ground/`, `store`, `settings` and the parts it calls. What it asks of a part that is made after it is a closure, set in its own wire function at the end of its file. State that several parts share is ground. `AppModel` (`Lockstep/App/AppModel.swift` and `AppModel+RoutingWindow.swift`) only owns the ground and the parts, wires them, and routes commands and the window's actions to them: it keeps no state of a feature and no function of one.

Which features the app shows is `FeatureSet.built` in `LockstepKit/Sources/LockstepCore/FeatureSet.swift`. The design lab shows `FeatureSet.all`.

## Invariants

- Everything inside the app is 48,000 Hz.
- A position is song seconds as a `Double`, or whole samples at 48 kHz when audio is cut or rendered.
- Original recordings are never modified. Timing fixes are descriptions applied when playing or exporting.
- A recording with `recordedSpeed` in `project.json` (0.85 for a take recorded at 85 %) was recorded slower: its file in `takes/` is the slow original and is never changed, and everything else about it (`lengthSamples`, `rawStart`, `delay`, its clips) counts in the sped-up sound, which is made from the file by rule (`SpedUpTake`) and kept in `cache/sped-up/<recording id>.wav`, where it can be deleted and is made again to the same samples.
- A track's voice (the recording made again with the track's Voice) is a description too: it is made from the recording, kept in `cache/voices/`, where it can be deleted and is made again to the same samples, and it never changes a recording or `project.json`. When a project closes, voices of settings no track has, of recordings that are gone and half-written files are removed.
- A clip's finished sound (its track's Sound with the clip's own knobs, its track's effects as the clip changed them for itself, and the clip's own effects) is a description too: it is made from the recording when playing and when sending, kept in memory only, and never written into a recording or into `project.json`.
- Files written are WAV, 48 kHz, 24-bit.

## Licence

Lockstep is under the GNU General Public License, version 3 or later, because it builds in the Rubber Band Library (`LockstepKit/Sources/CRubberBand`, GPL version 2 or later). Keep the licence notices in `LICENSE` and `THIRD-PARTY-NOTICES.md` up to date when a dependency is added or changed. Distributing Lockstep under other terms needs Breakfast Quay's commercial licence for Rubber Band first.

## Where things are

- `Lockstep/`: the app (`App/` for start-up, launch options and `AppModel`, `Model/` for the parts and `Model/Ground/` for what they share, `Views/` for the window, `Settings/` for the settings window, `Resources/` for the Resolve script).
- `LockstepKit/`: a Swift package with the app's core (`LockstepCore`: the project, edits, settings), its audio (`LockstepAudio`: beats, syllables, correction, sound), its interface components (`LockstepUI`) and Rubber Band (`CRubberBand`), with their tests.
- `LockstepSpeechKit/`: the speech-to-text package around whisper.cpp.
- `LockstepDesign/`: the design lab app.
- `Scripts/`: the model installers and the scripts named above.
- `docs/design/design.md`: the design document, with its pictures in `docs/design/states/` and the app's messages in `docs/design/messages.md`.

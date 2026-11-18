# The messages of Lockstep

Every place where Lockstep has nothing to show, or says that something went wrong. Written on 13 November 2026 from the code, in phase 24. The wording rules are in section 6 of `design.md`: one or two plain sentences, what happened and what to do, no technical words.

**None of these has been seen in the running app yet.** The pass was made from the code. The column "How to produce it" says how each situation is made. "From outside" means an agent can make it with a scratch run and launch arguments, without a pointer. "By hand" means it needs a click, a microphone or a device.

There are 50 messages: 9 empty states, 4 banners, 18 alerts, 8 sentences in the calibrate sheet, 8 in Settings, 1 in the Send to DaVinci panel (50, added in phase 24.5) and 2 marks in the window. 15 were reworded in this pass. They are marked "(new wording)".

How the three kinds look is in `design.md` under "The empty window and messages". A banner is one line at the top of the timeline and is cut off when it is wider than the banner, so a banner is always one short sentence. An alert has a first line (what happened) and a second (what to do).

## 1. Empty states

| # | Where | When | Text | How to produce it |
| --- | --- | --- | --- | --- |
| 1 | The window | No song is open | "Drop a song here" | From outside: a scratch run without `-open`. |
| 2 | A track row | The track has no clips | Nothing. The row is empty, with no placeholder text. | From outside: a scratch run with `-open <song>`. |
| 3 | The ruler and the song row | The song has no beats (not found yet, or not found at all) | No beat lines. The ruler shows time instead of bar numbers. When the search failed, banner 10 or 11 says so. | From outside: see 10. |
| 4 | The panel on the right, top part | No track and no clip is selected | "Nothing selected" and under it "Click a track or a clip to see its settings here." | From outside: a scratch run with `-open <song>`, in a window wide enough for the panel. |
| 5 | The panel on the right, the delay | The headphones and microphone in use have no measured delay | "Not calibrated", with a warning triangle. Its help tag: "The delay of this microphone and these headphones has not been measured, so recordings may land late. Measure it with Transport > Calibrate Delay..." (new wording) | From outside: the same run as 4. A scratch run has no measured delays. The help tag needs a pointer: by hand. |
| 6 | Settings > Recording, "Measured delays" | No delay has been measured | "No delay has been measured yet. Choose Transport > Calibrate Delay... in the main window." | By hand: open Settings > Recording before calibrating. (An agent cannot open the settings window without a key press.) |
| 7 | A clip, and the clip part of the panel | The clip has no words (not written out, or nothing was heard) | Nothing. The clip shows its name only. | From outside: `-addTake <wav>` without `-clipText`, with `-silent`. |
| 8 | File > Open Recent | No project has been opened | The menu holds only "Clear Menu", greyed out. | By hand: open the menu in a fresh install. |
| 9 | The calibrate sheet, and a row of "Measured delays" | A device has no name | "Unknown" in place of the name | Cannot be made on purpose. |

The plan of phase 24 expected "No delays measured yet." for number 6. The text in the app is longer because it also says where to measure. It was left as it is.

## 2. Banners

| # | When | Text | How to produce it |
| --- | --- | --- | --- |
| 10 | The search for beats ended without beats, or failed, or a stricter setting left the song without beats | "No beats found. Try Loose in Settings > Beats and Click." (new wording, fix phase 24.5; shortened to fit the banner's one line of about 75 letters). | From outside: a scratch run with `-open` on a WAV file of hiss. The test `aSoundWithoutABeatGetsNoBeatsAtAnyLimit` proves that hiss gives no beats, and writes such a file as `no-beat.wav` when it is run with `LOCKSTEP_BEAT_SOUNDS` naming a folder. The run also prints "Lockstep: found no beats, with the limit at 0.00" on standard error. |
| 11 | The beat model is not installed on this Mac | "The beat model is not installed." | Not from outside: it would mean moving the installed model. It shows only on a Mac where `Scripts/install-beat-model.sh` was never run. |
| 12 | A take was stopped because headphones, a microphone or another sound device was connected or removed | "Recording stopped because a sound device was connected or removed." (new wording) | By hand: unplug the headphones while recording. |
| 13 | Restart Recording was to keep the dropped attempt as a clip and could not | "The attempt before this one could not be kept." | Cannot be made on purpose (a full disk while recording). |

## 3. Alerts

Each has an OK button. The first sentence is the alert's first line.

### Opening a song or a project

| # | When | Text | How to produce it |
| --- | --- | --- | --- |
| 14 | A file that is damaged, or is not sound, is opened as a song | "Lockstep could not read this file." "It is damaged, or it is not a sound file. Lockstep opens m4a, mp3, wav and aiff files, among others." (new wording) | From outside: `-open <a text file>`. |
| 15 | The file opens but has no sound track | "This file has no sound in it." "Drop a sound file, such as an m4a, mp3 or wav." (new wording) | From outside, with a video file that has no sound. One has to be made first. |
| 16 | The file's sound track is empty | "This file is empty." "Its sound is 0 seconds long. Drop another file." (new wording) | From outside: `-open` on a WAV file with a header and no samples. |
| 17 | The project is not where it was | "This project can no longer be found." "It was moved, renamed or deleted, so it was taken out of Open Recent." (new wording) | From outside: `-open <a path ending in .lockstep that does not exist>`. |
| 18 | The project cannot be read | "Lockstep could not read this project." "Something in the project folder is damaged or missing. Lockstep changed nothing in it, so your recordings are still there." (new wording) | From outside: make a project in one scratch run, write nonsense into its `project.json`, open it with `-open` in a second run. |
| 19 | The project's song is gone | "The song file of this project is missing." "Put the song back in the project folder as song.wav, then open the project again." (new wording) | From outside: as 18, but delete `song.wav` from the project instead. |
| 20 | The project was saved by a newer Lockstep | "This project was made by a newer Lockstep." "Open it with the newer Lockstep." (new wording) | From outside: as 18, but change `"version"` in `project.json` to 999. |
| 21 | A song was read, but its project folder could not be made | "Lockstep could not make a project for this song." "Check that the projects folder can be written to and that the disk has room. The projects folder is chosen in Settings, under General." (new wording) | From outside, probably: put an ordinary file named `Projects` in the scratch folder before the run, then `-open <song>`. With `Scripts/screenshot.sh` this is not possible, because it makes its own scratch folder. |

### Saving

| # | When | Text | How to produce it |
| --- | --- | --- | --- |
| 22 | The project could not be written to disk | "Lockstep could not save this project." "Check that the disk has room and that the project folder is still there. Your changes are kept while Lockstep stays open, and the next change tries to save again." (new wording) | From outside, probably: make a project with `-addTake` in one scratch run, take away the right to write to the project folder (`chmod -R a-w`), then open it with `-open <project> -clipText hej`. Give the right back afterwards. |
| 23 | Song > Create Click Track... could not write its file | "Lockstep could not save the click file." "Check that the disk has room and that the folder can be written to, then try again." | By hand: save the click file into a folder that cannot be written to. (`-clickFile` writes a line on standard error and shows no alert.) |

### Playing and recording

| # | When | Text | How to produce it |
| --- | --- | --- | --- |
| 24 | The song could not be played: at Play, at Record, or at Restart Recording | "Lockstep could not play the song." "Check that the Mac has a sound output, then try again." | Cannot be made on purpose on a Mac that has a sound output, which is nearly every Mac. |
| 25 | Record was pressed and the Mac has no microphone | "Lockstep could not start recording." "This Mac has no microphone to record from. Connect one, then try again." | By hand, and only on a Mac without any microphone. |
| 26 | Record was pressed and the microphone could not be opened | "Lockstep could not start recording." "The microphone could not be opened. Check the sound input in System Settings, then try again." | Cannot be made on purpose. |
| 27 | Record or Start (calibrating) was pressed and macOS does not let Lockstep use the microphone | "Lockstep is not allowed to use the microphone." "Allow Lockstep under Privacy & Security > Microphone in System Settings, then try again." (new wording: the second sentence is new). Buttons: Open System Settings, Cancel. | By hand: switch Lockstep off under Privacy & Security > Microphone, then press Record. An agent never asks for the microphone. |
| 28 | Restart Recording could not start the new attempt | "Lockstep could not restart the recording." "Check that the disk has room. What you had recorded so far was kept." | Cannot be made on purpose. |
| 29 | A take ended and could not be kept | "Lockstep could not keep this recording." "Check that the disk has room, then record again." | Cannot be made on purpose. |

### Send to DaVinci

| # | When | Text | How to produce it |
| --- | --- | --- | --- |
| 30 | The clip has no sound that can be exported | "Lockstep could not export this clip." "The clip has no sound to export." | Cannot be made on purpose: every clip has a recording. |
| 31 | The exported file could not be written | "Lockstep could not export this clip." "Check that the folder (its path) can be written to and that the disk has room. The export folder is chosen in Settings, under DaVinci." (new wording) | By hand: choose an export folder in Settings > DaVinci, take away the right to write to it in Finder, then Send to DaVinci. (`-sendClip` writes a line on standard error and shows no alert.) |

## 4. The calibrate sheet

The sheet's failure box holds one of these, with the Try Again button.

| # | When | Text | How to produce it |
| --- | --- | --- | --- |
| 32 | The ticks were not heard in the recording | "Could not hear the ticks. Try again closer or louder." | By hand: press Start with the headphone far from the microphone. |
| 33 | macOS does not let Lockstep use the microphone | "Lockstep is not allowed to use the microphone. Allow it in System Settings, then try again." | By hand: as 27. Alert 27 comes first. |
| 34 | The microphone could not be opened | "The microphone could not be opened. Check the sound input in System Settings, then try again." | Cannot be made on purpose. |
| 35 | A take is being recorded | "A recording is going on. Stop it, then try again." | Cannot be reached in the window: the sheet does not open during a take. |
| 36 | The ticks could not be played | "The ticks could not be played. Check that the Mac has a sound output, then try again." | Cannot be made on purpose. |
| 37 | The headphones or the microphone changed while measuring | "The headphones or the microphone changed while the ticks played. Try again." | By hand: unplug the headphones right after pressing Start. |
| 38 | Start was pressed in a run with `-silent` (agents only) | "Lockstep was started with its sound turned off (-silent), so nothing was measured." | Needs a click on Start. A user never sees it. |
| 39 | Start was pressed in a `-scratch` run before the microphone was ever allowed (agents only) | "Lockstep has not been allowed to use the microphone yet, so nothing was measured." | Needs a click on Start. A user never sees it. |

## 5. Settings

All of these need the settings window, which an agent cannot open without a key press: by hand.

| # | Where | When | Text | How to produce it |
| --- | --- | --- | --- | --- |
| 40 | General, under "Projects folder" | The chosen folder cannot be used | "Lockstep cannot use this folder. New projects are saved in (the usual folder)." | Choose a folder, then remove it in Finder and open Settings again. |
| 41 | DaVinci, under "Timeline start" | What was typed is not a timecode | "Write it as hours, minutes, seconds and frames, like 01:00:00:00, with the frames below 24. Lockstep keeps 01:00:00:00 until then." (new wording; the two numbers follow the settings) | Type "abc" in the field. |
| 42 | Recording, under "Write out the words of new recordings" | The speech model of the chosen language is not installed | "The Swedish speech model is not installed. Run Scripts/install-speech-model.sh swedish in Lockstep's folder." ("multilingual" and `multilingual` for "Any language") | From outside: a scratch run on a Mac without the model; the same sentence goes to standard error once. |
| 43 | The same place | The model's file may not be read | "Lockstep is not allowed to read the Swedish speech model in (the model's path)." | Not on purpose. |
| 44 | The same place | The model's file is not whole, or whisper.cpp could not load it | "The Swedish speech model is not complete. Run Scripts/install-speech-model.sh swedish --force in Lockstep's folder." | Not on purpose. |
| 45 | Recording, a row of "Measured delays" | The delay of wireless headphones is from an earlier connection | "Not in use until measured again" after the date | Measure with wireless headphones, disconnect and connect them, open Settings > Recording. |
| 46 | Shortcuts | The typed shortcut belongs to another command | "(Shortcut) is used by (command)." "Replace gives it to (this command) and leaves (the other) without a shortcut." Buttons: Replace, Cancel. | Give Play the shortcut of Record. |
| 47 | Shortcuts | The typed shortcut belongs to macOS | "(Shortcut) is used by macOS." "Choose another shortcut." | Type Command-Q in a shortcut field. |

The Send to DaVinci panel has one sentence of the same kind. It is not in Settings, but it is listed here beside 41, which it repeats.

| # | Where | When | Text | How to produce it |
| --- | --- | --- | --- | --- |
| 50 | The Send to DaVinci panel, a line under "Timeline start", "Frame rate" and "Song starts at" | What is being typed into Timeline start or Song starts at is not a timecode. The line goes when the text is one, or when the field is left and shows the kept value again. | "Write it as hours, minutes, seconds and frames, like 01:00:00:00, with the frames below 25. Lockstep keeps the timecode it had until then." (the number follows the project's frame rate) | By hand: open the panel on a clip and type "abc" in Timeline start. The panel needs a selected clip, which an agent cannot make. |

## 6. Marks in the window

| # | Where | When | Text | How to produce it |
| --- | --- | --- | --- | --- |
| 48 | The panel on the right, the arrow before the clip's volume | The clip is played more quietly than its slider says, to stay under the safe limit | Help tag: "Held back so the clip does not distort." | By hand: turn a loud clip far up and rest the pointer on the arrow. |
| 49 | The floating bar, the last piece of the microphone level | The microphone is too loud | Help tag: "The microphone is too loud" | By hand: shout while recording. |

## 7. What has no message

Looked for and not found. Nothing was added, because this phase adds no new state. Each is an open question.

1. **A dropped file that is not sound does nothing.** A text file dropped on the window is ignored without a word. Alert 14 is shown only when the file comes through File > Open or `-open`. The checklist of phase 24 says "dropping a text file", and nothing visible happens. A dropped `.lockstep` project is ignored in the same way.
2. **Words that could not be written out are not mentioned.** When the speech model is missing or fails, the clip simply stays without words. The only place that says the model is missing is Settings > Recording (42 to 44).
3. **Tighten lines, looping and the count-in have no messages.** None was found in the code, and none was added.
4. **Nudging syllables (phase 20) is not built**, so it has no messages.
5. **Send to DaVinci: a wrongly typed timecode in the panel changes nothing and says nothing.** Settings > DaVinci has a sentence for the same mistake (41). Done in phase 24.5: the panel now has sentence 50. A song start typed before the timeline start is still refused without a word.

## 8. Left as they are, still to be decided

1. **Banner 11, "The beat model is not installed."** It does not say what to do. What there is to do is run `Scripts/install-beat-model.sh`, and a script's name is a technical word in a window. "Beat model" is one too.
2. **Banner 10** says what to do since fix phase 24.5: move the slider "How sure Lockstep must be of a beat" in Settings > Beats and Click towards Loose, or choose Song > Find Beats Again. The text is longer than a banner shows, so it is cut off and the rest is in the help tag. A banner with two lines would be a changed component, which needs the design lab and the maintainer's approval first.
3. **Alert 30, "The clip has no sound to export."** It does not say what to do, and it should never appear.
4. **Number 6** differs from the text the plan expected (see under the first table).
5. **Sentences 38 and 39** contain `-silent`. Only an agent's run can show them.
6. **In debug builds only**, Debug > Add Test Clips can show "Lockstep could not add the test clips." with the system's own error text under it. It is in no release build.

## 9. Not messages

- Progress: "Opening song", "Listening", "Finding beats", "Lining up", "Writing out words…", "Recording". They say what is being done and are part of the components in `design.md`.
- The question before Restore Defaults in Settings > Shortcuts ("Restore all shortcuts to their defaults?") is a question, not an error.
- Lines that Lockstep writes on standard error in a `-scratch` run ("Lockstep: added the take ...") are for agents. A user never sees them.

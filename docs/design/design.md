# The Lockstep design

This is how Lockstep looks, as worked out in the design lab in phase 3 (12 November 2026). Every later phase follows it. It grew out of one of several early layouts that were tried. The details are not final, and the last section lists what is open.

How to read it:

- Every picture is the design lab (the app "Lockstep Design") in one named state. The small dark box above the window is the lab's own panel for stepping between states. It is not part of the design.
- The pictures show the window while another app is in front, so the three window buttons and the switches are grey. See the open points about the switch colour.
- All content in the pictures is made up.
- The code of every component is in `LockstepKit/Sources/LockstepUI/`. Paths below are inside that folder.
- To see a state yourself: `Scripts/screenshot.sh --app LockstepDesign /tmp/out.png -state "Clip selected"`. The state names are the headings of the pictures below, and the full list is in `LockstepDesign/LabState.swift`.

## 1. The rule for new components

A new or changed component goes through four steps, in this order:

1. It is built in `LockstepUI`.
2. It is added to the design lab with every state it can be in (see "How to add a state" in `LockstepDesign/LabState.swift`).
3. It is shown to the maintainer, who approves it.
4. Only then is it used in Lockstep, and added to the catalogue in this document with a picture of each state.

The real app contains no view that is not made of approved components. When a later phase needs something the catalogue lacks, that phase's plan gets a task for the lab first, so the maintainer sees it in the lab before seeing it working.

One exception: the settings window is not designed in the lab. It uses the system's standard settings forms.

## 2. The layout

Code: `MainLayout/MainLayout.swift`. This is the only place where the window is laid out. Sizes are in `DesignTokens.Sizes` and `DesignTokens.Spacing`.

![Main](states/main.png)

The window has three areas:

- **The timeline** fills the window, right under the window's title. From the top: the ruler with bar numbers, the song row (it stays in place while the tracks scroll), one row per vocal track, and a small "+" for a new track. Each row has a header on the left with its name.
- **The floating bar** is a glass capsule centred near the bottom edge, on top of the timeline. It holds the transport, the time, the tempo, the microphone level, the click, the snapping button and the button that shows or hides the panel.
- **The panel on the right** (the inspector) is a glass panel. Its top part follows the selection and shows a clip's things or a track's, never both: the selected clip with the controls that correct its timing, or, after a click on a track's header, that track with its name, Mute and Normalize Track. Its bottom part is always the same: the delay and Send to DaVinci.

Rules of the layout:

- A control whose feature is not built yet is left out completely. It is never greyed out.
- The panel can be hidden with the button at the right end of the floating bar. It starts open in a wide window and hidden in a narrow one.
- The smallest window is 900 x 560. At that size the panel is hidden:

![Main at the smallest size](states/main-900x560.png)

## 3. The design values

No view writes a colour or a size itself. Every value has a name, and the names live in three files. The values are not copied here, so this document cannot drift from the code. Open the file to see or change a value.

| File | What it holds |
| --- | --- |
| `DesignTokens.swift` | `Colors`, `Fonts`, `Spacing`, `Radius`, `Shapes`, `Sizes`, `Lines`, `Opacity`. Each value has a line saying where it is used. |
| `GlassSurfaces.swift` | What a bar, a panel, a row and a clip bar are made of (`DesignTokens.Surfaces` and the surface helpers). |
| `TimelinePalette.swift` | The colours of everything drawn inside a timeline: waveforms, beat lines, clips, the ruler, the playhead. Two sets, see "Glass". |

The rules the values follow:

- **Dark only.** The app looks the same whatever the Mac is set to. Every window, panel and popover gets `lockstepLook()`.
- **One accent.** `Colors.accent` is the one colour besides the neutrals. It marks the selected track, a switched-on control and the clip waveforms.
- **Record is the only red.** `Colors.record` is used for the Record button, the mark of a slower recording speed beside it, the recording in progress, the mark on the track being recorded to, and the last piece of the microphone level when it is too loud. Nothing else is red, not even warnings.
- **Timing has its own three colours.** See section 5. No other element may use them.
- **Numbers do not jump.** All text with numbers uses monospaced digits, so a changing number keeps its width. The large readouts and timecodes use a monospaced typeface.
- **Numbers are written with a point** (91.4 BPM, +4.0 dB) on every Mac.

## 4. Glass

Code: `GlassSurfaces.swift`. All glass is the system's own Liquid Glass. Nothing imitates glass with blur or gradients.

Where glass is used:

- The floating bar and the message banner (`glassCapsule()`), the panel on the right and popovers (`glassPanel()`).
- Every timeline row and its header (`laneSurface()`, `laneHeaderSurface()`).

Where glass is not used, and why:

- **Clip bars are plain fills** (`clipBarSurface()`), because the row under them is glass. Glass never lies on glass. It is also faster: 200 glass clip bars made zooming about twice as slow in the phase 2 measurements.
- **A timeline that lies on a glass panel has plain dark rows.** That is the takes list in the panel on the right. Such a timeline is marked with `timelineOnGlass()` and uses the `plainLanes` colours of `TimelinePalette`. Rows on the window use `glassLanes`.
- **Buttons inside a glass bar or panel are borderless.** Only a button that stands alone on a plain background uses the system's glass button style.
- **Readouts on a clip** (such as "23 ms late") have a plain dark backing, so they can be read on the waveform.

Readability of waveforms, beat lines and timing colours comes first. Where glass hurts it, glass stops.

## 5. The timing colours

Code: `DesignTokens.Colors.timingOnBeat`, `timingSlightlyOff`, `timingNeutral`. Drawn by `TimingMarkers/ClipTimingLayer.swift`.

| Colour | Meaning | Lightness |
| --- | --- | --- |
| Mint green (`timingOnBeat`) | The syllable is on the beat. | Brightest |
| Orange (`timingSlightlyOff`) | The syllable is slightly off. | Middle |
| Grey (`timingNeutral`) | The syllable is far from any sub-beat, so it is off on purpose and left alone. In a clip that aims at another track: the syllable has no partner there, and is left alone too. | Darkest |

Rules:

- The three differ in lightness as well as in hue, so they can be told apart with red-green colour blindness.
- No other element uses these colours. Colour in the timeline is kept for timing, which is why the microphone level is neutral.
- A marker has a dark edge, because the colours are close to the clip's waveform in lightness.
- Markers are shown only on a selected clip.
- In a clip that aims at another track (the row "Aim at" under Correction), the three colours say how far a syllable is from its partner in that track, in place of its sub-beat.

Pictures are under "Timing markers" in the catalogue.

## 6. Wording

- **Short and plain.** One sentence. Say what happened and, if there is something to do, what to do: "Could not hear the ticks. Try again closer or louder."
- **Labels are sentence case:** "Resolve start", "Click on", "Not calibrated".
- **Buttons and menu commands are title case, as macOS does it:** "Delete Other Takes", "Measure Again", "Split at Playhead". A command that opens a panel ends in three dots: "Send to DaVinci...".
- **The app speaks of itself by name:** "Lockstep could not read this file."
- **No blame and no jargon.** Words the app uses: song, track, clip, take, line, syllable, beat, sub-beat, delay. Not: region, buffer, latency, quantize, feel.
- **A finished voice sound is a "Sound"**, with a capital S, so it is not taken for sound in general: "This track has no Sound." Its four knobs are Squeeze, Tone, Warmth and Space, the six built-in ones are named in the menu (Rap lead, Rap double, Ad-lib, Sung lead, Sung hook, Backing voice), and a kept one is a "preset". Not: chain, compressor, EQ, saturation, reverb, wet, dry (the Send panel says "With sound" and nothing about dry).
- **An effect on a clip is an "effect"**, under the heading "Effects". A second voice made from the take is a "double", and its kinds are named by how they sound: Thick, Low, High, Big, Small. The kinds on words are Echo, Phone, Stutter, Tape stop and Swell. How loud one is beside the voice is its "Level". The mark on a clip reads "FX". Not: layer, pitch shift, formant, semitones, wet.
- **An effect of a whole track is still an "effect"**, in the same section "Effects". Where it is, is said in two words: "Every clip" in the track's list, and "Track" in the list of a clip that has it from its track. A clip is "switched off" from a track's effect, and "follows the track" again when its change is taken back, the words a knob has. What is copied from a clip or a track is its "sound", in lower case, in "Copy Sound" and "Paste Sound": the Sound and the effects together. Not: bus, send, insert, bypass, inherit, override.
- **Another voice for a track is its "Voice"**, with a capital V, as a Sound has its S: "the track's Voice". It has a switch and no word for it: on is on. Its two knobs are Depth and Pitch, and a kept setting is a "preset", as with a Sound: Darker, Deeper and Lighter are built in. A Voice whose knobs were turned reads "Custom". Depth is written in percent with its sign ("+6 %", "0 %") and Pitch in semitones as "st" ("-1.5 st", "0.0 st"); the knob's help tag spells "semitones" out. The second, slower way of making a voice is "Natural", and what it needs are "the voice engine" and "a sample of your voice". The user's recording is "your own voice". Not: character, formant, vocoder, model, convert, clone, render.
- **Few words for correcting timing** (13 November 2026: there had been far too many terms). The heading is "Correction", chosen that evening, and under it are "Off", "Lines" and "All", the sub-beats, "Strength" and "Stretch". None of the four rows has a label of its own. "Sub-beats" is the one word for how many parts a beat has, for a clip and for the click. The song has no sub-beats of its own (since 13 November 2026, the choice is made for each clip only). The interface says "correction" where it used to say "tighten". Since phase 36 there is a fifth row, "Aim at", which carries its name beside it as Strength does. Its box reads "The beat" or a track's name, written as a value and not as a command, so "The beat" is in sentence case. On a marker of a clip that aims at a track, a syllable on its partner reads "On the lead" and one without a partner "No match". Not: target, reference, guide, align, pair, partner.
- **A control that is not obvious explains itself** in one plain sentence when the pointer rests on it.
- **Numbers carry their unit, with a space:** "70 %", "12 ms", "91.4 BPM", "+4.0 dB".
- **A state that takes time says what is being done:** "Finding beats", "Writing out words...".
- **Something missing is said in words, not left blank:** "Not calibrated", "Nothing selected".

## 7. The component catalogue

Each entry says what the thing is, where its code is, the names of the values it uses, and its states with pictures. A picture usually shows the whole window. The entry says where to look.

### The timeline

**Timeline** (`Timeline/Timeline.swift`, `Timeline/MainTimeline.swift`). Rows of any kind on one shared scale, with beat lines and one playhead through all of them. The main timeline and the small timeline of the takes list are the same view with different rows. Values: `TimelinePalette`, `Sizes.headerWidth`, `Spacing.laneGap`, `Lines.beatWidth`, `Lines.barWidth`, `Lines.playheadWidth`.

- Normal: [Main](states/main.png). Bar lines are a little stronger than beat lines. Beats the app is unsure about are dashed (bars 15 to 16 in the picture).
- Zoomed in: [Clip selected](states/clip-selected.png).
- Many tracks and clips: [Stress](states/stress.png). 12 tracks and 200 clips. This state is a tool for measuring speed.

![Stress](states/stress.png)

Zooming and scrolling (since 13 November 2026, copied from the Fairlight page of DaVinci Resolve; `Timeline/TimelineScrollCatcher.swift`). Nothing is drawn for any of it, so it has no state of its own in the design lab:

- A pinch, or scrolling with Option held, zooms in time around the pointer. View > Zoom In and Zoom Out zoom around the playhead, and View > Zoom to Fit (Shift-Z) shows the whole song.
- Scrolling with Shift held makes all track rows taller or lower together. View > Taller Tracks and Lower Tracks do the same a step at a time. See "Track row and its header".
- Two fingers moved sideways, or scrolling with Command held, moves along the song. Scrolling up and down with no key held moves through the tracks.
- For a zoom and a height, up is more: fingers or a wheel moved up zoom in and make the rows taller.
- A drag with the middle mouse button held, started anywhere in the timeline, moves what it shows by as far as the pointer moves: along the song, and up and down through the tracks when they do not all fit (since 14 November 2026). The playhead and the selection stay, nothing under the pointer reacts, and a middle click without a drag does nothing.

**Ruler** (`Timeline/TimelineRuler.swift`). A short tick at every beat, a taller tick and the bar number at every bar. Without beats it shows time instead. A press in the ruler puts the playhead there, and a drag from that press takes the playhead along with the pointer (since 13 November 2026). Nothing in the ruler looks different while it is dragged, so it has no state of its own in the design lab. Values: `Sizes.rulerHeight`, `Fonts.rulerLabel`.

- With beats: [Main](states/main.png). Without beats: [Finding beats](states/finding-beats.png).

**Song row** (`Timeline/SongLane.swift`). The song's waveform in a neutral tone, with the song's name in the header. A click on the header selects the song (since 15 November 2026): the header then has the mark down its left edge that a selected track has (`Colors.selectedTrackMark`), and the panel on the right shows the song. See [The song selected](states/the-song-selected.png). A click in the row itself still moves the playhead. A faint band lies behind a stretch of unsure beats. Values: `Sizes.songLaneHeight`, `TimelinePalette.songWaveform`, `TimelinePalette.uncertainBand`.

- Normal: [Main](states/main.png).
- Beats being found: a small ring and "Finding beats" under the name, no beat lines yet (`Timeline/BeatFindingProgress.swift`).

![Finding beats](states/finding-beats.png)

- Pointer over a beat line: the line turns bright and three points wide, because beat lines are dragged in this row (`Timeline/BeatLineHover.swift`, `Colors.beatLineHovered`, `Lines.beatHoveredWidth`). The arrows in the picture stand in for the pointer.

![Beat hover](states/beat-hover.png)

- Cut at the start or at the end: the song has edges like a clip (`Timeline/SongEdges.swift`). Only what is left of it is drawn, and it ends in an edge three points wide in the waveform's tone where something is cut away (`Lines.songEdgeWidth`). The cut part of the row is empty in every row: no waveform, no beat lines, no ticks in the ruler. An uncut song has no edge drawn and looks as in Main.

![Song cut at the start](states/song-cut-at-the-start.png)

![Song cut at the end](states/song-cut-at-the-end.png)

- Moved to 00:00: with the beginning cut away and the song dragged left until what is left starts at 00:00, the timeline starts inside the song. Bar numbers stay the song's own. Every time on screen counts from the timeline's 00:00: the time readout, the ruler's time marks when the song has no beats, and the Resolve start time of a clip.

![Song at 00:00](states/song-at-00-00.png)

- Pointer over an edge: within `Sizes.songEdgeGrabDistance` of either end of the song the edge turns bright (`Colors.beatLineHovered`) and the pointer becomes a resize arrow, also on a song that is not cut. Dragging the edge cuts the song or brings it back, and the row follows while it is dragged. Dragging the song between its edges moves the song with its beats and every clip. Dragged left with its start at 00:00, also when nothing is cut, the song goes on: its beginning passes 00:00 and is cut away there, which looks like Moved to 00:00 above, and dragging it right brings the beginning back. The arrows in the picture stand in for the pointer.

![Song edge hover](states/song-edge-hover.png)

**Track row and its header** (`Timeline/TrackLane.swift`, `Timeline/TrackHeader.swift`, `Timeline/TrackNameField.swift`, `Timeline/TrackLaneNewTrackRow.swift`). The header has the track's name and its mute button. Values: `Sizes.trackLaneHeight`, `Fonts.laneName`, `Colors.selectedTrackMark`, `Opacity.muted`.

- Normal, selected (an accent mark down the left edge) and muted (button lit, name and clips dimmed): [Main](states/main.png), tracks Lead, Double and Lead 2.
- Being recorded to (a red mark and a red dot), being renamed (a field in place of the name), and the "+" for a new track:

![Track list](states/track-list.png)

- The height (since 13 November 2026; `Timeline/TrackHeight.swift`). All track rows have one height, which starts at `Sizes.trackLaneHeight` and can be changed between `Sizes.trackLaneMinimumHeight` (half of it) and `Sizes.trackLaneMaximumHeight` (four times it). The header and the clips fill the height they get: a clip's bar keeps its height and the waveform takes the rest. The song row, the "+" row and the takes timeline keep their own heights.
- As low as they get. The readout of a marker stands beside it, because there is no room under it:

![Tracks low](states/tracks-low.png)

- As tall as they get:

![Tracks tall](states/tracks-tall.png)

**Playhead** (`Timeline/PlayheadPosition.swift`, drawn by `Timeline/Timeline.swift`). A thin light line through all rows with a small head in the ruler. It looks the same while it is dragged in the ruler. Values: `Sizes.playheadHeadWidth`, `Lines.playheadWidth`.

### The clip

**Clip** (`Timeline/ClipView.swift`, `Timeline/ClipBar.swift`). A bar along the top with the clip's name, and under it the waveform in the accent tone. The bar is the handle the clip is dragged by. Near the left or the right edge of a clip, over its whole height, the pointer becomes the resize pointer and that edge shows as a thin bright bar: a drag from there trims the clip (`Timeline/ClipEdges.swift`). The edges are 6 points wide, and narrower on a clip under 24 points, so the middle half of a clip always moves it. In the bar, from the right: the take count ("3/5", a button that selects the clip, so its takes show in the panel on the right, and opens that panel if it is hidden), a ringed "3" for a clip in triplets, and the volume when it is not zero. A narrow clip drops these one by one and shortens its name. Values: `Surfaces.clipBarPlainFill`, `Surfaces.clipBarPlainFillSelected`, `Sizes.clipBarHeight`, `Fonts.clipName`, `Fonts.clipBadge`, `Radius.clip`, `Lines.clipOutlineWidth`, `Lines.clipOutlineSelectedWidth`, `Sizes.clipEdgeGrabWidth`, `Sizes.clipEdgeHandleWidth`.

Every state, each shown at three zooms:

![Clips](states/clips.png)

The states in that picture: normal, pointer over the clip, selected, several selected, muted, on a muted track, long name cut off, typed name, no name yet, with takes, pointer over the take count, triplets, turned up, turned down, very short, very long, joined with a gap, being renamed, overlapping a little, pointer over the bar, pointer at the start edge, pointer at the end edge of a selected clip.

- Words being written out: three dots and "Writing out words..." where the name will be, and the same in the panel (`ClipText/WritingOutWords.swift`).

![Writing out words](states/writing-out-words.png)

**Effects on a clip** (phase 34, approved by the coordinator from its pictures; `Effects/ClipEffectBands.swift`, `Effects/ClipEffects.swift`, the mark in `Timeline/ClipBar.swift`). A clip shows where its effects are (`ClipBox.effects`, each a `ClipEffectMark`).

- An effect on a stretch of the clip is a thin band along the clip's lower edge, over its stretch, with the kind's short name in it when all of the name fits ("Low octave", "Echo 1/4"). The band is neutral: dark and see-through with a thin light line around it, so it is none of the timing colours, the name reads on a waveform, and the waveform shows through. It lies at the bottom, where a waveform seldom reaches, and the syllable markers stand at the top, under the bar. It is drawn over the waveform and under the markers, and it never takes the pointer.
- Bands of effects that overlap in time lie over each other, the one that starts first lowest. Two that do not overlap share a row.
- Together the named bands may take 45 % of the height under the bar (`Sizes.effectBandsShareOfBody`). With more, in a low row or with three effects on one word, every band of the clip is a bright line 3 points high with a dark edge, without a name.
- The band of the effect whose row is lit in the panel has a brighter line around it, and its stretch is the marked stretch of the timeline.
- An effect on the whole clip has no band. It is the mark "FX" in the clip's bar, right of the volume and left of the triplet mark and the take count. Its help tag names the kinds ("On the whole clip: Thick"). A narrow clip drops it after the volume, the triplet mark and the mute mark, and before the name.

Values: `Colors.effectBandFill`, `Colors.effectBandEdge`, `Colors.effectBandEdgeSelected`, `Colors.effectBandText`, `Colors.effectBandLine`, `Colors.effectBandLineEdge`, `Fonts.effectBandName`, `Sizes.effectBandHeight`, `Sizes.effectBandLineHeight`, `Sizes.effectBandGap`, `Sizes.effectBandInset`, `Sizes.effectBandCorner`, `Lines.effectBandEdgeWidth`, `Fonts.clipBadge` for "FX".

- A Thick double on the whole clip: "FX" in the bar and no band.

![A clip with a Thick double](states/a-clip-with-a-thick-double.png)

- A Low double on two words, with its row in the panel clicked: the band has its name and a brighter line, and the stretch is marked.

![A Low double on two words](states/a-low-double-on-two-words.png)

- Three effects on stretches and one on the whole clip. Low octave and High overlap on one word, so High lies over Low octave. Phone and Echo 1/4 share the lower row.

![Three effects, two overlapping](states/three-effects-two-overlapping.png)

- An echo on quarter notes on the last word of the line: one band with its name under the word, and one row in the panel with its level.

![An echo on the last word](states/an-echo-on-the-last-word.png)

- The other effects on words, each on a word of its own. Phone, Stutter and Tape stop replace the voice, so they have no level and their rows are one line.

![Effects on words](states/effects-on-words.png)

- The same clip in a row as low as it gets: the bands are bright lines without names.

![Effects in a low row](states/effects-in-a-low-row.png)

- With the whole song in view the clip is narrow: the band on two words is a small box too short for its name, and the bar has room for the take count alone, so "FX" is left out.

![A narrow clip with an effect](states/a-narrow-clip-with-an-effect.png)

**Waveform** (`Timeline/WaveformShape.swift`). A filled waveform mirrored around its middle line. The song, clips and takes all use it. A clip that is turned up is drawn taller.

### Timing markers

**Timing markers on a selected clip** (`TimingMarkers/ClipTimingLayer.swift`, `TimingMarkers/TimingMarks.swift`). A marker at every syllable, coloured as in section 5, with the sub-beat lines to judge them against. Values: the three timing colours, `Colors.timingMarkerEdge`, `Colors.timingReadoutBackground`, `Sizes.markerDotDiameter`, `Sizes.markerTickHeight`.

- Zoomed in: a dot on a stem at each syllable. The marker under the pointer is larger and says how far off it is ("23 ms late").

![Clip selected](states/clip-selected.png)

- A clip in triplets, and a marker that is left out of tightening (hollow, "24 ms early, excluded"):

![Clip selected, triplets](states/clip-selected-triplets.png)

- Zoomed out: the dots become small coloured ticks, and further out they are not drawn.

![Clip selected, zoomed out](states/clip-selected-zoomed-out.png)

- In a low track row the markers are smaller, so they fit under the clip's bar: first the room above and under a marker is halved, then its stem gets shorter. The dot keeps its size. The readout stands to the right of its marker, at the clip's lower edge. In a tall row the markers keep their size and stay right under the bar. Pictures: [Tracks low](states/tracks-low.png), [Tracks tall](states/tracks-tall.png).

**Timing markers of a clip that aims at another track** (phase 36, for the coordinator to approve from its picture; the same two files). Such a clip is held against the syllables of the track it aims at, the lead, and not against the beat. What it is given is `ClipTimingMarks.leadSyllableTimes`, and a marker without a partner is `SyllableMarker.Timing.unpaired`.

- No sub-beat lines are drawn. In their place there is a line at every syllable of the lead, where it is heard. It runs from the clip's bar down to the clip's lower edge, as a sub-beat line does, so a marker that is on its partner stands exactly on it.
- The look that tells it from a sub-beat line: it is several times as strong (a light neutral, `TimelinePalette.leadSyllableLine`), it has a thin dark edge on both sides, as a marker has, so it can be followed across the light waveform, and it has a small bar across its top, right under the clip's bar, which makes it a "T". The small bar fits between the clip's bar and the dots of the markers. It is not dashed, because dashes mean beats the app is unsure about, and it has no colour, because colour on a clip means timing.
- A marker is coloured by its distance to its partner: mint green on it, orange slightly off. The readout says how far ("19 ms late"), and "On the lead" where the distance is nothing.
- A syllable without a partner, such as a word the lead does not have, has a neutral grey marker, and its readout says "No match".
- Zoomed out, where markers are ticks without dots, the lines of the lead are not drawn: they would run together with the ticks.

Values: `TimelinePalette.leadSyllableLine`, `Lines.leadSyllableWidth`, `Sizes.leadSyllableCapWidth`, `Sizes.leadSyllableCapHeight`, `Colors.timingMarkerEdge`.

The double on the track "Double", with its lead in the row above. The eighth syllable has no partner, and its readout is shown:

![A double against its lead](states/a-double-against-its-lead.png)

### The floating bar

**Floating bar** (`MainLayout/TransportCapsule.swift`). The glass capsule that holds the controls below. Values: `Sizes.floatingBarHeight`, `Spacing.barPadding`, `Spacing.groupGap`.

All the small controls side by side, each with its name under it:

![Controls](states/controls.png)

**Transport buttons** (`Controls/TransportControls.swift`). Play, Record, Loop. Active: Play becomes a pause symbol, Record fills, Loop lights up in the accent. There is no button for going back and none for starting a take over, since 13 November 2026: Return goes back to where the last take started, and Record pressed during a take starts it over. Values: `Sizes.transportButton`, `Fonts.symbolLarge`, `Colors.record`.

**Record speed mark** (`RecordSpeedMark` in `Controls/TransportControls.swift`). While takes are recorded slower than the song, the percent ("85 %") stands right after the Record button, as small text in the record red, closer to Record than the buttons stand to each other. It is there before Record is pressed, so a slow take never comes as a surprise. At 100 % nothing is shown and the bar is as it always was. The value comes in as `MainLayoutContent.recordSpeedPercent` (nil or 100 shows nothing). Its help tag reads "Takes are recorded at 85 % of the song's speed. Change it in the click settings." Values: `Fonts.readoutUnit`, `Colors.record`, `Spacing.tight`. Alone: "Transport, recording slower" in [Controls](states/controls.png). In the bar:

![Record slower](states/record-slower.png)

**Readouts** (`Controls/Readouts.swift`). Time ("0:20"), tempo ("91.4 BPM"), delay ("12 ms" or "Not calibrated") and Resolve start ("01:00:20:12"). Two sizes. Values: `Fonts.readout`, `Fonts.readoutLarge`, `Fonts.readoutUnit`.

**Microphone level** (`Controls/BarControls.swift`, `Recording/MeterClipMark.swift`). A microphone symbol and a thin neutral bar. When the microphone is too loud the last piece lights up red. Values: `Colors.meterFill`, `Colors.meterTrack`, `Colors.meterClipMark`, `Sizes.meterWidth`. Too loud: [Recording](states/recording.png).

**Click control** (`Controls/BarControls.swift`). A metronome button that switches the click on and off (lit when on) and a small arrow that opens the click popover.

**Snapping button** (`Controls/SnappingButton.swift`). Two arrows meeting at a line, lit in the accent while snapping is on. On: [Main](states/main.png). Off: [Snapping off](states/snapping-off.png). Its help tag reads "Snapping. Hold Command while dragging to turn it the other way." Holding Command during a drag or a click that snaps (moving or Option-dragging a clip, trimming an edge, marking a stretch, the playhead in the ruler, the edges of the song) turns snapping off when it is on and on when it is off, for as long as Command is held; pressing or letting go of it in the middle of a drag takes effect at once. The setting and the button stay as they are, so the button never flickers while Command is held. A Command-click on a clip still adds it to the selection or takes it out.

**Snap To arrow and menu** (`ContextMenus/SnapToMenu.swift`). A small arrow right beside the snapping button, like the one beside the click button. It opens the system's own menu of what snapping catches on: Grid, Clip Edges, Playhead and Recorded Place, each ticked while it is on, and under a line the grid's unit (Grid in Sub-beats, Half Beats, Beats or Bars) with the one in force ticked. Edit > Snap To in the menu bar holds the same lines. Values: `Sizes.popoverArrowWidth`, `Fonts.symbolSmall`. The arrow is in [Controls](states/controls.png) and [Main](states/main.png). What the menu holds, at the start and with some switched off:

![Menu snap to](states/menu-snap-to.png)

![Menu snap to, some off](states/menu-snap-to-some-off.png)

**Panel button.** The button at the right end of the bar that shows or hides the panel on the right.

### The panel on the right

**Inspector** (`MainLayout/Inspector.swift`, controls in `Controls/TrackAndClipControls.swift`, `Controls/TightenControls.swift`, `Controls/VoiceControls.swift`, `Controls/SoundControls.swift`, `Controls/EffectsControls.swift`, `Controls/ControlParts.swift` and `Controls/BarControls.swift`). Values: `Sizes.inspectorWidth`, `Spacing.panelPadding`, `Spacing.sectionGap`, `Fonts.panelTitle`, `Fonts.label`, `Fonts.value`.

Its parts:

- Track, shown after a click on a track's header, which selects the track and no clip (since 13 November 2026): its name in the heading's line, Volume, the switch "Mute" (`TrackMuteSwitch`) and the button "Normalize Track" (`NormalizeTrackButton`), which do what Track > Mute Track and Track > Normalize Track do. Volume is the track's own volume (since 15 November 2026, to balance vocal tracks against each other and the beat): the slider a clip's volume has (`ClipVolumeControl` with another range), from -24.0 to +12.0 dB, where 0.0 dB plays the track's clips as loud as their own volumes say. It is heard while the slider is dragged, also while the song plays, letting go is one undo step, "Change Track Volume", and a double-click puts it back at 0.0 dB. It is only for what is heard: Send to DaVinci sends the clips as if every track stood at 0.0 dB. The switch is on for a muted track, as the mute button in the track's header is lit. Normalize Track is dimmed for a track without clips. Under them stand the track's Voice, the track's Sound and the track's effects, all described below, in the order the sound is made in: the voice is changed first, and the Sound and the effects act on the changed voice.
- Song, shown after a click on the song's header, which selects the song and no clip (since 15 November 2026, because the beat could drown the voice): its name in the heading's line, and Volume, the slider a clip's volume has (`ClipVolumeControl` with another range), from -24.0 to 0.0 dB. The song can only be turned down: 0.0 dB plays it as its file is. The selected track keeps its mark in the timeline, because the next take still goes to it, as it does while a clip is selected. A click on a track's header or on a clip shows that track or clip again.
- Clip, shown while one or more clips are selected, without the track above it. The track of the selected clip is still the selected track in the timeline, for the commands of the Track menu and for where a take is recorded.
- Clip: Resolve start, the name, the words and Volume (a slider with "+4.0 dB").
- Correction, in the clip part, for the selected clip or clips (`Controls/TightenControls.swift`). Laid out on 13 November 2026: one heading and four rows under it, none with a label of its own. First a row of three buttons, Off, Lines and All. Then a row of three for the sub-beats, 16ths, Triplets and Auto, where Auto reads from the clip's own syllables whether it is rapped in triplets. A new clip is on 16ths. Both rows fill the width of the panel, each button as wide as the others (`SegmentedChoice` with `fillsWidth`). Then "Strength" with its slider and "70 %" in one line, and last the switch "Stretch" with its name beside it. Strength is dimmed while every selected clip is Off, and Stretch while none of them is All, because there they would change nothing (`Opacity.unavailable`). A change is applied at once. When several selected clips differ, a row of buttons has nothing chosen and Strength and Stretch read "Mixed", and using the control gives all of them the same. A small ring in the heading's line fills while the sound of the selected clips is made again. Each control says what it does when the pointer rests on it. There is no Hear original any more: choosing Off, or Clip > Correction On or Off (T), is how the recording is heard.
  - "Aim at" (phase 36, for the coordinator to approve from its pictures; `AimMenuButton` and `AimMenu` in `Controls/TightenControls.swift`), shown with the feature `lockToLead`: a fifth row, under the two rows of buttons and above Strength, kept to one line because the clip part is already long (open points 28 and 31). It says what the clip's timing is corrected toward. "Aim at" stands before a box that fills the rest of the line and reads "The beat", which is what every clip starts with, or the name of the track the clip aims at. The box is the one a track's Sound has (`MenuBoxLabel` in `Controls/ControlParts.swift`), and a press opens the system's own menu: "The beat", and under a line every other track by name, with the line of the aim ticked. With several clips selected the menu lists the tracks none of them is on, since a clip cannot aim at its own track. When the selected clips differ the box reads "Mixed", in the quieter text tone, and no line is ticked; choosing a line gives all of them the same. The row is dimmed while every selected clip is Off, as Strength is. While every selected clip aims at a track, the row of sub-beats is dimmed, because such a clip is held against that track's syllables and its sub-beats are not used. Its help tag reads "What the timing of the selected clips is corrected toward: the beat, or the syllables of another track, so that a double lands on its lead." A choice is reported with `TightenActions.aimChosen`, and what the row shows comes from `ClipBox.aimTrackID` and the track rows.
- Voice (phase 37, for the coordinator to approve from its pictures; `VoiceSection` in `Controls/VoiceControls.swift`, `ContextMenus/VoiceMenu.swift`), shown with the feature `trackVoice`, which the lab has and the app gets from the task that wires it. One heading, "Voice", in the track part between Normalize Track and Sound. A clip has nothing of it: the Voice belongs to the whole track.
  - In the heading's line, at the right, stands a small switch without a title of its own: the Voice on or off. Its help tag reads "Every clip on this track is heard, and sent to DaVinci, in your own voice made darker or lighter. Off, you hear your own voice, and the knobs are kept." Before the switch stands the small ring while voices are made (`MakingRing`), filled as far as the clips have theirs.
  - Under the heading, a box as wide as the panel that shows the name of the preset the Voice was chosen as, or "Custom" after a knob was turned (`VoiceMenuButton`, the box "Aim at" has, `MenuBoxLabel`). A press opens the system's own menu (`VoiceMenu`): Darker, Deeper and Lighter, under a line the user's own presets, and under another line "Save as Preset..." and "Delete Preset", a submenu of the user's own, as the Sound menu has them. The line of the track's preset is ticked, and none is for "Custom". There is no line "None": the switch turns the Voice off and keeps its knobs.
  - Under the box, two rows, Depth and Pitch, each the slider a knob of the Sound has, at the compact width, with its value (`VoiceKnobSlider`). Depth goes from -15 % to +15 % in whole percent, and to the right is deeper. Pitch goes from -4.0 st to +4.0 st in half steps, and to the left is lower. The slider stops only on those steps. Both values keep the same room, so the two sliders stand in one line. Nothing is made while a knob is dragged: letting go is the change, one undo step. A double-click puts a knob in the middle, as it puts a volume at 0.0 dB. Each help tag says which way is which and that the voice is made when the knob is let go.
  - With the feature `naturalVoice` as well: under the knobs the switch "Natural" with its name beside it, as Stretch has. Its help tag reads "Makes the voice a second time with the voice engine, which can sound more natural and takes longer. You hear the quick voice until the natural one is made." The lab shows it only in the four states about Natural (`FeatureSet.lab` in `LockstepDesign/LabMainLayout.swift` leaves the feature out everywhere else), because Natural is built only if the measurements of phase 37 justify it.
  - Last, only when there is something to say, one quiet line (`Fonts.caption`), and under it a button where there is something to do (`PanelButton` in `Controls/ControlParts.swift`, the button Normalize Track is). "Making the voice: 3 of 12 clips". "The voice could not be made for 2 clips." with Try Again. With Natural: "Making the natural voice: 3 of 12 clips", "Install the voice engine in Settings > Voices to use Natural." with Open Settings, and "Natural needs a sample of your voice. Choose one in Settings > Voices." with the same button. The sentences are made by `VoiceState`, so the app and the lab cannot word them differently.
  - While the Voice is off, the box, the knobs and "Natural" are dimmed and deaf (`Opacity.unavailable`) and still show the setting the track keeps. A track that never had a Voice looks the same with "Custom" and both knobs in the middle, so the section is as tall on every track. While a take is going or counting in the whole section is dimmed and deaf, heading and switch too (`MainLayoutContent.canChangeVoice`): no voice is made meanwhile.
  - Nothing is drawn on the clips for a Voice. A clip whose voice is not made yet looks like any other.
  - What the section tells its owner is `VoiceActions`: `switched`, `menuCommand` (a preset chosen, Save as Preset, a preset removed, and from a track's right-click menu "Voice On or Off"), `knobChanged` with whether the knob was let go, `naturalSwitched`, `tryAgainPressed` and `openSettingsPressed`, each with the track's id except the last. What it shows comes from `TrackRow.voice` (the project's own `TrackVoice`: the switch, the name, the two knobs and Natural), `TrackRow.voiceState` (`VoiceState`: `ready`, `making(done:of:)`, `failed(clips:)`, `makingNatural(done:of:)`, `noEngine`, `noSample`), `MainLayoutContent.ownVoicePresets` and `MainLayoutContent.canChangeVoice`. Without an owner, as in the lab, the section keeps what it shows itself: the switch dims the rest, a chosen preset moves the knobs, and a moved knob makes the box read "Custom".
- Sound (phase 33, approved by the coordinator from its pictures; `Controls/SoundControls.swift`, `ContextMenus/SoundMenu.swift`), shown with the feature `voiceSound`. One heading, "Sound", in the track part under Normalize Track and in the clip part between Volume and Correction.
  - For a track: a box as wide as the panel that shows the Sound's name, or "None", with two small arrows at its right end (`SoundMenuButton`; the fill and shape of the clip's name box). A press opens the system's own menu (`SoundMenu`): None, the six built-in presets, under a line the user's own presets, and under another line "Save as Preset..." and "Delete Preset", a submenu of the user's own. The line of the track's Sound is ticked. Save as Preset is greyed for a track without a Sound, and Delete Preset is a greyed line while there are none. Save as Preset asks for the name with the system's own prompt (an alert with a text field, "Save" and "Cancel"), which is no component of ours. Under the box are four rows, Squeeze, Tone, Warmth and Space, each the slider Strength has with its value in percent (`SoundKnobSlider`). A track without a Sound has the box alone: no rows.
  - For clips: the same four rows and no box, because a clip cannot have another Sound than its track. A row shows the track's value until the clip turns the knob for itself. Then it shows the clip's value, and a small arrow that turns back stands before the number, where the held-back volume has its arrow (`arrow.uturn.backward`, `Fonts.symbolSmall`). The arrow is a button: a press puts the knob back to the track's value, and its help tag reads "Turned for this clip only. Click to follow the track again." The arrow's place is kept in all four rows of a clip while there is no arrow, so the four sliders stand in one line (`Sizes.sliderMarkButton`). Several clips that differ in a knob read "Mixed" there, as Strength does, with the knob at their average, and have the arrow when at least one of them turned it. Moving the slider gives all of them the same.
  - Clips on a track without a Sound: one line under the heading, "This track has no Sound." ("These tracks have no Sound." for clips on several), in `Fonts.caption`, and the four rows dimmed and deaf (`Opacity.unavailable`), with the knobs at the left end and no number. A knob such a clip turned earlier keeps its number and its arrow. When some of the selected clips are on a track with a Sound, the rows are about those and there is no line.
  - A small ring in the heading's line fills while the finished sounds of what is shown are being made, as the ring of Correction does (`SoundProgressRing`; both are `MakingRing` in `Controls/ControlParts.swift`).
  - A knob is heard while it is dragged and is one undo step when let go, as the volume sliders are. What the section tells its owner is `SoundActions`, and what it shows comes from `TrackRow.sound`, `ClipBox.ownKnobs`, `MainLayoutContent.ownSoundPresets` and `MainLayoutContent.soundRemakeProgress`.
- Effects (phase 34, approved by the coordinator from its pictures; `Controls/EffectsControls.swift`, `ContextMenus/EffectsMenu.swift`, `Effects/ClipEffects.swift`), shown with the feature `doubles` or `wordEffects`. One heading, "Effects", in the clip part between Correction and Takes.
  - In the heading's line, at the right, stands a small "+" on the fill of a control (`AddEffectButton`; `Sizes.smallButton` wide and `Sizes.headingButtonHeight` high, so the heading is no taller than the others). A press opens the system's own menu (`EffectsMenu`) with two submenus: "Double" with Thick, "Low, a fourth down", "Low, an octave down", High, Big and Small (with `doubles`), and "On Words" with "Echo, quarter notes", "Echo, eighth notes", Phone, Stutter, Tape stop and Swell (with `wordEffects`, built in phase 35). Clip > Effects in the menu bar has the same two submenus under the same names. The effect goes on the words that are marked in a clip, or else on the whole of every selected clip. The button's help tag says so.
  - Under the heading, one row for each effect of the clip (`EffectsList`), kept short because the clip part is already long (open point 28). A row has two lines. First the kind's short name ("Low octave"), after it in small text where the effect is ("Whole clip", or the time of its stretch on the timeline to a tenth of a second, "0:17.0–0:17.8", `EffectPlace`), and at the right a small cross that removes the effect. Under it "Level" and the slider a clip's volume has, at the compact width, from -24.0 to +6.0 dB, with its value. A kind without a level (Phone, Stutter, Tape stop) has the first line alone.
  - A click on a row tells the owner, who marks the effect's stretch in the timeline. In the app the clip stays selected while that stretch is marked, and a second click on the lit row takes the mark away. The row of the effect whose stretch is marked is lit (`Colors.controlFillOn`, `ClipEffectMark.isSelected`); the backing reaches 4 points past the row on both sides, so the row's text and slider stay in line with Volume and Strength.
  - A clip without effects has one line under the heading: "Mark words in the clip, or select the clip, and add an effect." (`Fonts.caption`).
  - Several selected clips have the heading and its "+" alone, and nothing listed: an effect that is added goes on all of them.
  - While words are marked in a clip no clip is selected, and the panel is about the track. The track part then ends with the same heading "Effects" and its "+", and one line under it: "An effect you add goes on the marked words." (`Fonts.caption`; phase 35, approved by the coordinator from its picture). It is there only while the marked stretch crosses a clip of the selected track, so the line of a clip without effects above is true: marking words leaves the "+" in reach.
  - The level is heard while it is dragged and is one undo step when let go; a double-click puts it at 0.0 dB, as on every volume slider. What the section tells its owner is `EffectsActions`, also for a kind chosen in a clip's right-click menu, and what it shows comes from `ClipBox.effects`.
- Effects of a track, a clip's changes to them, and the effects several clips share (phase 36.5, for the coordinator to approve from its pictures; the same files as Effects), shown with the feature `trackEffects`, which the lab has and the app gets from the task that wires it. Without the feature the panel is as described above.
  - For a track: the heading "Effects" under the track's Sound, always there, with the same "+" (`AddEffectButton` with the target `.track`). Its menu is the track's (`EffectsMenu` with the target `.track`): the submenu "Double" with the six doubles, and under it "Echo, quarter notes", "Echo, eighth notes" and "Phone" as three lines of their own (`ClipEffect.Kind.forTracks`). Stutter, Tape stop and Swell are not offered: they are for single words. The help tag reads "Add an effect to this track. Every clip of the track gets it." Under the heading, one row for each effect of the track (`EffectsList` with the subject `.track`), as a clip's rows are, with "Every clip" where a clip's row reads "Whole clip", and a cross that removes the effect from the track. A track without effects has one line: "An effect you add here is heard on every clip of this track." (`Fonts.caption`).
  - While words are marked in a clip of the track, the "+" still puts the effect on those words: its menu is the clips' menu, with "On Words", and under the track's rows stands the line "An effect you add goes on the marked words.", which takes the place of the heading that was only there while words were marked.
  - For one clip: the list shows the effects of its track first, then its own (`ClipBox.effects`, the track's ones marked with `ClipEffectMark.ofTrack`). The row of a track's effect has the kind, "Track" as its place, and at the right, in place of the cross, a small power symbol that switches the effect off for this clip and on again (`power`, `Fonts.symbolSmall`, `Sizes.sliderMarkButton`, as big as the cross). The symbol is in the accent colour while the effect is on, as a switched-on control is, and in the cross's grey while it is off. Its help tags read "Switch this effect off for this clip only." and "Switched off for this clip. Click to hear it again." Under it "Level", which is the clip's own level for the effect once it is moved.
  - The mark of a clip's knob, the small arrow that turns back, stands before the level's value while the clip changed anything of the effect: its level, or that it is off. One press puts the effect back to the track's, on and at the track's level. Its help tag reads "Changed for this clip only. Click to follow the track again." A kind without a level (Phone) has no second line, so there the arrow stands in the first line, right before the power symbol. While a list holds a track's effect, every row of it keeps the arrow's place before its value, the clip's own rows too, so all sliders of the list stand in one line (and a little further left than Volume, as the knobs do, open point 29).
  - Switched off, the row is dimmed (`Opacity.unavailable`): the name, the place, "Level", the slider, which is deaf, and the value. The power symbol and the arrow are not dimmed: they are the way back.
  - A row of a track's effect is not clicked and never lit, in the track's list or in a clip's: a track's effect has no stretch to mark. Nothing is drawn on the clips for it either: the bands and "FX" are about a clip's own effects (`ClipBox.ownEffects`).
  - For several clips: under the heading, one row for each effect they share (`MainLayoutContent.selectedClipsEffects`, `EffectsList` with the subject `.clips`). A row reads "Whole clip" and has the cross, which removes the effect from all of them. When the effect is the track's on every one of them (`ofTrack` set on the row), it is the row of a track's effect instead: "Track", the power symbol for all of them, and the arrow when at least one changed it. The level reads "Mixed" while the clips differ, with the knob at their average, as the volume and the knobs do, and moving it gives all the same (`ClipEffectMark.isMixed`). Clips that share nothing have the heading and the "+" alone, as before.
  - What the section tells its owner: `EffectsActions.trackAddChosen`, `trackLevelChanged` and `trackRemovePressed` for a track's list, each with the track's id, and for the clip part `offPressed` and `resetPressed`, beside `levelChanged` and `removePressed`, which now also serve a track's effect in a clip's list and the shared rows, each named by the id of its row. What it shows comes from `TrackRow.effects`, `ClipBox.effects` and `MainLayoutContent.selectedClipsEffects`.
- Takes, in the clip part under Effects, when the selected clip's line has more than one take: the takes list, described below.
- The bottom part, always there under a thin line: the delay, and the Send to DaVinci button. The song's own sub-beats stood here until 13 November 2026, when the choice was moved to each clip only.

States:

- Nothing selected:

![Nothing selected](states/nothing-selected.png)

- A track selected and no clip. The track's name, its volume at 0.0 dB, where a new track starts, Mute and Normalize Track. The track has no Sound, which is what every track starts with: the box reads "None" and there are no knobs. It has no effect either, so "Effects" has its "+" and the line that says how one is added:

![A track selected](states/a-track-selected.png)

- The same with the track muted. The switch is on:

![A muted track selected](states/a-muted-track-selected.png)

- The same with the track turned up to +4.5 dB. The knob stands to the right of 0, which the song's cannot:

![A track turned up](states/a-track-turned-up.png)

- The song selected and no clip. The song's name and its volume, turned down to -6 dB. The song's header and the selected track both have the mark:

![The song selected](states/the-song-selected.png)

- A track with the Sound "Rap lead". The box shows its name and the four knobs stand where that preset starts them:

![A track with a Sound](states/a-track-with-a-sound.png)

- The same while the sounds of its clips are being made again, after a knob was turned (the ring after "Sound"):

![Sounds being made](states/sounds-being-made.png)

- What the Sound menu holds for that track, when the user has saved two presets of their own. As with the right-click menus, the picture is a plain list of the lines, and the real menu is the system's:

![Menu sound](states/menu-sound.png)

- One clip selected. Here the volume is held back (the arrow before "+9.0 dB"): the clip is played more quietly than the slider says, because it would otherwise go over the safe limit. Its track has no Sound, so the four knobs are dimmed under the line that says so:

![One clip selected](states/one-clip-selected.png)

- One clip selected with Lines chosen, while its sound is being made again (the ring after "Correction"). Stretch is dimmed, because only All moves single syllables:

![One clip selected, lines](states/one-clip-selected-lines.png)

- One clip selected with Off chosen. Strength and Stretch are both dimmed, and the clip keeps its strength:

![One clip selected, correction off](states/one-clip-selected-correction-off.png)

- One clip on a track with the Sound "Rap lead". The four knobs show the track's values and none has the arrow: the clip follows its track:

![One clip with a Sound](states/one-clip-with-a-sound.png)

- The same clip with Space turned for itself, to 60 % where its track has 8 %. The arrow that turns back stands before "60 %":

![One clip with its own Space](states/one-clip-with-its-own-space.png)

- Three clips on two tracks that both have "Rap lead", one of them with its own Space. Space reads "Mixed" and has the arrow, and the three other knobs show the value all three share:

![Several clips with a Sound](states/several-clips-with-a-sound.png)

- Several clips selected. The clip part becomes "Clips, 3 selected" with one volume that says "Mixed". One of the three is corrected differently, so neither row of buttons has anything chosen, and Strength and Stretch say "Mixed":

![Several clips selected](states/several-clips-selected.png)

- The row "Aim at". The five states that follow show one made-up window: a track "Lead" with a line, and under it a track "Double" with the same line recorded again, selected. Here the double aims at the beat, as every clip starts:

![A clip aimed at the beat](states/a-clip-aimed-at-the-beat.png)

- The double aims at the track "Lead". The box reads "Lead", and the row of sub-beats is dimmed:

![A clip aimed at Lead](states/a-clip-aimed-at-lead.png)

- What the menu of the box holds for that clip, as a plain list of its lines. The stretch of timeline beside the list is the one every menu state shows, with the sample's own track names:

![Menu aim at](states/menu-aim-at.png)

- The same clip with Off chosen. "Aim at", Strength and Stretch are dimmed. The clip keeps its aim, so the sub-beats stay dimmed:

![A clip aimed at Lead, correction off](states/a-clip-aimed-at-lead-correction-off.png)

- Three clips selected, one aimed at "Lead" and two at the beat. The box reads "Mixed". The sub-beats can be used, because some of the three aim at the beat:

![Several clips, aim mixed](states/several-clips-aim-mixed.png)

- The timing marks of a clip that aims at a track are under "Timing markers": [A double against its lead](states/a-double-against-its-lead.png).

Since the row "Aim at" (16 November 2026), the only pictures that show it are these six. Every other picture with one clip or several in the panel still shows Correction with four rows, without "Aim at" between the sub-beats and Strength. They were left as they are because other phases were making new pictures of the same states that night.

The pictures of the two new states and of "A muted track selected", and new pictures of "A track selected", "One clip selected", "Several clips selected" and "Controls", are made in the check of phase 27. Until then those four show the panel as it was.

Since the Sound section (15 November 2026), new pictures were made of "Main", "A track selected", "One clip selected", "Controls" and the Sound states above. Every other picture that shows the panel with a track or a clip in it still shows the panel without the heading "Sound": among them "A muted track selected", "A track turned up", "One clip selected, lines" and "One clip selected, correction off". There the track part ends at Normalize Track and Correction follows right after Volume.

- One clip without effects, zoomed in. Under "Effects" stands the "+" and the line that says how one is added:

![A clip with no effect](states/a-clip-with-no-effect.png)

- The rows of the list are in the pictures of "Effects on a clip" under "The clip": one row for an effect on the whole clip ([A clip with a Thick double](states/a-clip-with-a-thick-double.png)), a lit row ([A Low double on two words](states/a-low-double-on-two-words.png)), and five rows, one of them without a level, where the list and the takes under it need scrolling ([Three effects, two overlapping](states/three-effects-two-overlapping.png)).

- Words are marked in a clip and no clip is selected, so the panel is about the track. Under the track's own things stands the heading "Effects" with the same "+", and one quiet line: "An effect you add goes on the marked words." The line is there only while the marked stretch crosses a clip of the track; since phase 36.5 the heading stays, with another line (see "A track with no effect" below). When an effect has been added the clip is selected and the panel shows the clip with its new row.

![Words marked in a clip](states/words-marked-in-a-clip.png)

- What the menu that adds an effect holds, as a plain list of its lines:

![Menu effects](states/menu-effects.png)

- Three clips selected, each with a Thick double on the whole of it, at three levels, and a Low double on some of its words. Under "Effects" there is one row, for the Thick double they share: its level reads "Mixed" and its cross removes it from all three. The doubles on words are not listed. In the timeline each clip has "FX" in its bar where there is room, and a small box for its band:

![Several clips with effects](states/several-clips-with-effects.png)

Since the Effects section (15 November 2026), new pictures were made of "Main", "One clip selected", "Several clips selected" and "Menu clip", besides the states of the effects. Every other picture with one clip or several in the panel still shows it without the heading "Effects": there Takes follows right after Correction.

The states of phase 36.5 follow: the effects of a track, what a clip changed of them, and the effects several clips share. The made-up track "Double" has the Sound "Rap lead" in most of them.

- A track selected, with a Sound and no effect. Under "Effects" stands the "+" and the line that says every clip of the track gets what is added:

![A track with no effect](states/a-track-with-no-effect.png)

- The same track with a Thick double and an echo on quarter notes. Each row reads "Every clip" and has the cross:

![A track with two effects](states/a-track-with-two-effects.png)

- What the "+" of a track's Effects holds, and the submenu "Effects" of the track's right-click menu, as a plain list of its lines:

![Menu track effects](states/menu-track-effects.png)

- The track has its two effects and words are marked in one of its clips. The rows stay, and the line under them says the effect goes on the marked words:

![A track with effects, words marked](states/a-track-with-effects-words-marked.png)

- One clip of that track, which has changed nothing. Its list shows the track's two effects, each marked "Track", at the track's levels, with the power symbol in the accent colour. The clip has no band and no "FX":

![A clip with effects from its track](states/a-clip-with-effects-from-its-track.png)

- The same clip with its own level for the Thick double, -3.0 dB where the track has -9.0 dB, and the echo switched off. Both rows have the arrow. The echo's row is dimmed, its arrow and its power symbol are not:

![A clip with its own level and an effect off](states/a-clip-with-its-own-level-and-an-effect-off.png)

- A track with Phone, which has no level, and a Thick double. The clip switched Phone off: the row has one line, and the arrow stands in it before the power symbol:

![A clip with Phone from its track, off](states/a-clip-with-phone-from-its-track-off.png)

- A clip with the track's Thick double and two effects of its own, a High double on the whole clip and an echo on its last word. The track's row comes first, the three sliders stand in one line, and the clip is drawn with "FX" and one band, for its own two:

![An effect from the track and two own](states/an-effect-from-the-track-and-two-own.png)

- Two clips of a track with a Thick double, each with a High double of its own. They share both rows. The track's reads "Mixed" and has the arrow, because one of the two has its own level for it. The High double's cross removes it from both:

![Several clips, one from the track and one own](states/several-clips-one-from-the-track-and-one-own.png)

- Three clips that share no effect: one has a Thick double, one a High double, one an echo on some words. The heading and the "+" alone:

![Several clips that share no effect](states/several-clips-that-share-no-effect.png)

Since the track's Effects section (16 November 2026), new pictures were made of every state with a track in the panel ("A track selected", "A muted track selected", "A track turned up", "A track with a Sound", "Sounds being made", "Words marked in a clip"), of "Several clips with effects", and of "Menu clip" and "Menu track". In these pictures the lab's own stepping panel lies under the window, where older pictures have it above. No other picture changed: a clip on a track without effects, and several clips that share none, are shown as before.

The states of phase 37 follow: the Voice of a track. A track is selected and no clip in all of them, and the track has no Sound and no effect. The first seven show the section without Natural, which is how the app has it unless Natural is built.

- A track that never had a Voice, which is what every track starts as. The switch is off, the box reads "Custom" and both knobs stand in the middle, dimmed:

![A track that never had a Voice](states/a-track-that-never-had-a-voice.png)

- The Voice is on with the preset "Darker", and every voice is made. Nothing more is said:

![A track with a Voice](states/a-track-with-a-voice.png)

- A knob was turned after a preset was chosen. The box reads "Custom":

![A track with a custom Voice](states/a-track-with-a-custom-voice.png)

- The Voice is switched off and keeps its setting. The box and the knobs show "Deeper", dimmed:

![A track with its Voice off](states/a-track-with-its-voice-off.png)

- Voices are being made after a knob was let go: the ring before the switch, a quarter full, and the line that says how many clips have theirs:

![Voices being made](states/voices-being-made.png)

- The voice of two clips could not be made. The line says so, with Try Again under it:

![Voices that could not be made](states/voices-that-could-not-be-made.png)

- A take is going on the track. The whole section is dimmed, its heading and its switch too:

![A Voice while a take is going](states/a-voice-while-a-take-is-going.png)

- With Natural: the switch "Natural" is on and every voice is made:

![A natural Voice](states/a-natural-voice.png)

- With Natural: the quick voices are heard while the natural ones are made:

![Natural voices being made](states/natural-voices-being-made.png)

- With Natural: the voice engine is not installed. The line says so, with a button that opens Settings > Voices:

![Natural without the voice engine](states/natural-without-the-voice-engine.png)

- With Natural: no sample of the user's voice is chosen. The same button:

![Natural without a voice sample](states/natural-without-a-voice-sample.png)

- What the Voice menu holds for a track with "Darker", when the user has saved two presets of their own, as a plain list of its lines:

![Menu voice](states/menu-voice.png)

Since the Voice section (16 November 2026), new pictures were made of every state with a track in the panel: "A track selected", "A muted track selected", "A track turned up", "A track with a Sound", "Sounds being made", "Words marked in a clip", "A track with no effect", "A track with two effects" and "A track with effects, words marked", and of "Menu track". In them the track never had a Voice, so the section stands dimmed between Normalize Track and Sound. No picture with a clip in the panel changed.

- Delay not measured. "Not calibrated" with a warning triangle, as bright as a number:

![Not calibrated](states/not-calibrated.png)

### The takes list

**Takes list** (`Takes/TakesList.swift`, `Timeline/TakeLane.swift`, `Controls/TakeControls.swift`). The takes of the selected clip's line, in the clip part of the panel on the right, under Correction and Effects. Since 13 November 2026 it takes the place of the takes panel, a popover that opened from the take count, which was easy to miss, so the takes moved into the panel.

From the top: the heading "Takes" with which take is chosen at the right ("3 of 5"), a small timeline with one row per take, and Delete Other Takes. Each row has, in its header, the take's Play button, its number and a tick on the chosen take, and beside it the take's words on one line above its waveform. The chosen take is in the accent tone, the others are neutral. The rows show the same beat lines and the same playhead as the main timeline. A line that is cut off shows whole when the pointer rests on it.

A click on a row chooses that take. A take's Play button plays the line with the song and everything else, with that take in the place of the chosen one, from the start of the line's takes to half a second after it. While it plays the button shows Stop on a light backing. Nothing is chosen by listening.

The list is as tall as its rows and never scrolls by itself. With more takes than fit, the top part of the panel scrolls.

Values: `Sizes.headerWidthNarrow`, `Sizes.takeLaneHeightWithText`, `Sizes.takeTextLineHeight`, `Sizes.smallButton`, `Fonts.symbolSmall`, `Colors.rowHover`, `Colors.controlFillOn`, `Opacity.aboutToBeDeleted`, `TimelinePalette.plainLanes`.

Its states, side by side in one picture: the pointer on a take (the row a click would choose is lit), a take being played, the pointer on Delete Other Takes (the takes that would go are dimmed and get a bin), and twelve takes:

![Takes list](states/takes-list.png)

Where it lives in the window: [One clip selected](states/one-clip-selected.png).

### Popover and sheets

**Click popover** (`Panels/ClickPopover.swift`). Opens upwards from the click control. The five sounds with a tick at the chosen one, the volume, how often it clicks, and the count-in before recording: Off, 1 bar, 2 bars or 4 bars, in the same segmented row as how often it clicks. Under how often it clicks stands a second row, 16ths or Triplets, with no heading of its own: the click's own sub-beats, four or six clicks to a beat, since the song has none (`ClickSettings.subBeats`, reported with `ClickActions.subBeatsChosen`). It is dimmed while the click is on beats or half-beats, where it would change nothing (`Opacity.unavailable`). The Count-in row shows only when a count-in is handed in (`ClickSettings.countInBars`), and a choice is reported with `ClickActions.countInChosen`. Under Count-in stands "Record speed", the speed the song plays at while a take is recorded: 100 %, 90 % or 85 % (`RecordSpeed.choices`), in the same segmented row. Its help tag reads "How fast the song plays while you record. Below 100 % it is slower at the same pitch, and the take is sped up to full tempo afterwards." The row shows only when a speed is handed in (`ClickSettings.recordSpeedPercent`), and a choice is reported with `ClickActions.recordSpeedChosen`. Values: `Sizes.clickPopoverWidth`.

![Click](states/click.png)

With the click on sub-beats, and those on Triplets:

![Click, on sub-beats](states/click-on-sub-beats.png)

With 85 % chosen as the record speed. The bar under the popover then has the record speed mark:

![Click, record slower](states/click-record-slower.png)

**Calibrate sheet** (`Panels/CalibrateSheet.swift`, `Panels/SheetParts.swift`). Measures the delay of the headphones and microphone. The title, one instruction, the two devices, a note about wireless headphones, and the buttons. Values: `Sizes.sheetWidth`, `Fonts.sheetTitle`.

- Before measuring:

![Calibrate](states/calibrate.png)

- Done: the measured delay as a large number, with Measure Again and Done.

![Calibrate done](states/calibrate-done.png)

- Failed: one sentence saying what to try, with Try Again.

![Calibrate failed](states/calibrate-failed.png)

**Send to DaVinci panel** (`Panels/SendSheet.swift`). It is about every selected clip. Values: `Fonts.timecodeLarge`, `Sizes.timecodeFieldWidth`, `Sizes.sendClipRowHeight`, `Sizes.sendClipRowsShown`. At the bottom left, in Done's line, stands the switch "With sound" (phase 33; shown when `SendContent.withSound` is set, reported with `SendActions.withSoundChanged`). On, which is how it starts, each clip is sent as it sounds in Lockstep, with its Sound and effects, in stereo and a little longer so reverb and echo ring out. Off, each clip is sent without its Sound and effects, as before there were Sounds. Its help tag says so. A clip that was sent with its sound says "stereo, with sound" (`SendContent.Clip.isSentWithSound`): on a line of its own under the file's name for one clip, and after the track's name, behind a raised dot, in a row of the list. A clip that has no Sound and no effect is sent as before also while the switch is on, and says nothing more. "Song starts at" shows where the song's own first sample lies on the Resolve timeline, which is the song's place on Lockstep's timeline written as a timecode: it follows a cut or a move of the song made by dragging, and a timecode typed there that lies before the timeline start cuts that much of the song's beginning away and puts what is left at 00:00.

- One clip: the timecode to place the clip at, as the largest text in the app, with Copy. Under it the step to take in DaVinci Resolve, in a box: choose Workspace > Scripts > Lockstep there, and the script puts the clip on the audio track with the name of its track. Then the file to drag into DaVinci Resolve by hand, with Show in Finder. At the bottom the three settings of the Resolve project, and under them "With sound" beside Done. Here it is on, and the file says "Stereo, with sound":

![Send](states/send.png)

- The same with "With sound" switched off. The file says nothing about sound:

![Send without sound](states/send-without-sound.png)

- Several clips: the title says how many. The step in Resolve comes first, then the clips as a list. Each row has the clip's name over its track, its timecode and a small Copy, and is dragged out as its file. Show in Finder is under the list. Here every clip was sent with its sound, and says so after its track.

![Send several clips](states/send-several-clips.png)

- More than six clips: the list scrolls, so the panel keeps its height. The fourth clip has no Sound, so its row has the track's name alone.

![Send many clips](states/send-many-clips.png)

- Since a track can have a Voice (phase 37, for the coordinator to approve from its pictures), a clip's row says what became of it (`SendContent.Clip.voice`: `none`, `making(progress:)`, `sent`, `failed`), where it says "stereo, with sound". A clip sent in its track's Voice says "with the track's Voice", or, when it has its Sound or an effect too, "stereo, with sound and Voice", kept that short because it is what most clips of such a track say and a row has one line for it. A clip whose voice could not be made says "sent in your own voice: its voice could not be made", after "stereo, with sound" and a raised dot when it has that; the row's line may then wrap once, and the row is a line taller (`Sizes.sendClipRowHeight` is its least height). A clip whose voice is still being made has no file yet: the small ring stands where the file's symbol is, filling when the owner says how far it has come and turning by itself when not, the row reads "Making the voice…", and it cannot be dragged. Its timecode and Copy are there already, because a clip's place is the same with and without a Voice. While any clip waits, the step for Resolve is a notice, "Wait until the voice is made" (`SendContent.ScriptStep.waitingForVoices`): the script gets the clips when every one of them has its file. With "With sound" switched off no row says any of this: every clip is then sent in the user's own voice. Here the first of four clips waits for its voice, the second has Sound and Voice, the third the Voice alone, and the voice of the fourth could not be made:

![Send with voices](states/send-with-voices.png)

- One clip whose voice is still being made, a little under half done. The file's box has the ring and "Making the voice…", under it "The file is here when the voice is made.", and Show in Finder is dimmed:

![Send while the voice is made](states/send-while-the-voice-is-made.png)

- One clip sent in its track's Voice, with its Sound. The file says "Stereo, with sound and Voice":

![Send with the track's Voice](states/send-with-the-tracks-voice.png)

- One clip whose voice could not be made. The file says so under its name, on two lines:

![Send, the voice could not be made](states/send-the-voice-could-not-be-made.png)

- The script is not in Resolve: the box is a notice with a warning sign and says where to install it. The clip is placed by hand until then. (This picture and the next were made before the switch "With sound" and do not show it.)

![Send without the script](states/send-without-the-script.png)

- The script in Resolve is an older one: the same notice with other words. A list that could not be written for the script looks the same.

![Send with an old script](states/send-with-an-old-script.png)

### Right-click menus

**Menus** (`ContextMenus/`). Four menus: the clip's, the track's, a beat line's and the song's. Each is the system's own menu. A real menu is a separate window that opens only on a right-click, so the lab shows what each menu holds as a plain list beside a small timeline (`ContextMenus/MenuListing.swift`). The list is for the lab only. The real app shows the system's menu.

The clip's menu has the submenu "Effects" under Sub-beats (phase 34): the menu that adds an effect, with the same lines as the "+" in the panel ("Menu effects" under "The panel on the right"). A kind chosen there is reported with the id of the clip that was right-clicked (`EffectsActions.addChosenInClipMenu`).

The clip's menu has the submenu "Aim at" between Sub-beats and Effects (phase 36, shown with the feature `lockToLead`): the lines of the row "Aim at" in the panel, "The beat" and under a line every other track by name, with the clip's aim ticked (`AimMenu.entries`, `ClipMenu.Values.aimTrackID` and `aimTracks`). A line chosen there is reported as `ClipMenu.Command.aim`.

The track's menu has the submenu "Effects" under Mute Track (phase 36.5, shown with the feature `trackEffects`): the lines of the "+" in the track's part of the panel ("Menu track effects" under "The panel on the right"). A kind chosen there is reported with the id of the track whose header was right-clicked (`EffectsActions.trackAddChosen`), told apart from the menu's commands as in the clip's menu.

The track's menu has the submenu "Voice" between Mute Track and Effects (phase 37, shown with the feature `trackVoice`): "Voice On or Off", ticked while the track's Voice is on, and under a line the presets of the box in the panel, Darker, Deeper and Lighter and under another line the user's own, with the track's preset ticked (`VoiceMenu.trackEntries`, `TrackMenu.Values.voice` and `ownVoicePresets`). The knobs have no lines, as the Sound's knobs have none. A line chosen there is reported with the id of the track whose header was right-clicked (`VoiceActions.menuCommand`, as `VoiceMenu.Command.onOrOff` or `chosen`), told apart from the menu's commands as an effect's kind is. Every line is greyed out while a take is going (`TrackMenu.Values.canChangeVoice`). In the picture the track has "Darker", switched on.

Both menus have "Copy Sound" (Option-Command-C) and "Paste Sound" (Option-Command-V) in a group of their own, under the group that ends with "Effects" (phase 36.5, shown with the feature `soundCopy`). They are reported as `ClipMenu.Command.copySound` and `pasteSound`, and `TrackMenu.Command.copySound` and `pasteSound`. Each is greyed out by a value the window gives (`MainLayoutContent.canCopySound` and `canPasteSound`, which reach the menus as `ClipMenu.Values` and `TrackMenu.Values` of the same names): Paste Sound while no sound was copied.

A menu with more lines than the lab's window shows is listed in two lists side by side that read as one, the second going on where the first stops, divided between two of the menu's own lines and never inside a submenu (`MenuStateSheet.columns` in the lab). The clip's menu is the only one that long.

![Menu clip](states/menu-clip.png)

![Menu track](states/menu-track.png)

![Menu beat](states/menu-beat.png)

![Menu song](states/menu-song.png)

### Dragging

**What is drawn while something is dragged** (`Dragging/TimelineDragging.swift`, `Dragging/TimelineDragPicture.swift`). Values: `Colors.recordedPlaceFill`, `Colors.recordedPlaceOutline`, `Colors.snapLine`, `Colors.markedStretchFill`, `Colors.loopRegionFill`, `Colors.trackLandingLine`, `Sizes.clipLift`, `Colors.liftShadow`.

- Moving a clip: the clip is lifted with a shadow, and a dashed outline stays where it was recorded.
- Copying a clip (Option held when the drag starts): drawn the same way, except that the clip also stays in its row, and the pointer is the system's copy pointer. No other look.

![Dragging clip](states/dragging-clip.png)

- Snapped to the edge of another clip: a thin accent line at the point it snapped to. With Grid on in the Snap To menu, a moved clip that has not caught on anything goes in steps of the grid and has no line.

![Snapped](states/snapped.png)

- Snapped to the playhead: the line is thicker, on the playhead.

![Snapped to playhead](states/snapped-to-playhead.png)

- Snapped back to where it was recorded:

![Snapped to recorded position](states/snapped-to-recorded-position.png)

- Snapping off: the snapping button in the bar is not lit, and no line is drawn. A drag with snapping on and Command held looks the same, with the button still lit.

![Snapping off](states/snapping-off.png)

- Trimming a clip by an edge: the clip stays in its row and gets shorter or longer from that side, the sound that is left does not move, and the held edge is a thin bright bar for as long as it is dragged.

![Trimming clip](states/trimming-clip.png)

- A trimmed edge that has snapped: the same accent line as for a moved clip, from the row of what it snapped to. On a line of the grid, the accent line crosses the clip's own row only.

![Trimming, snapped](states/trimming-snapped.png)

- A marked stretch on one track: a tinted band with an edge. Since 15 November 2026 the loop's in and out are no marked stretch: with Loop off they have their own look in the ruler, below.

![Marked stretch](states/marked-stretch.png)

- A rectangle that selects clips on several tracks (`TimelineDragging.selectionRectangle`, since 15 November 2026): a drag that marks a stretch and leaves the row it started in. It is the band of the marked stretch, with the same fill and the same thin edge, as one piece from the top of the first row to the bottom of the last, over the gaps between the rows and never over the headers, and with the edge on all four sides. Every clip it touches is drawn selected, also one that is only partly inside. The track the drag started on is the selected track. It is there only while the button is down, and never together with a marked stretch. Its sides do not snap. Where the rows are scrolled under the song row it stops at the song row and has no edge there.

![Selection rectangle](states/selection-rectangle.png)

- The same over all tracks:

![Selection rectangle over all tracks](states/selection-rectangle-over-all-tracks.png)

- Started on the lowest track and dragged upwards. It looks the same, and only the selected track tells where it started:

![Selection rectangle, upwards](states/selection-rectangle-upwards.png)

- Loop: the stretch is also marked in the ruler, and Loop is lit in the bar.

![Loop](states/loop.png)

- The loop's in and out with Loop off (phase 28.7, approved by the coordinator on 15 November 2026): drawn in the ruler only, as a faint band with a bracket "[" at the in and "]" at the out, and nothing over the rows, so it never looks like a selection. Values: `Colors.loopInOutFill`, `Colors.loopInOutMark`, `Lines.loopInOutMarkWidth`, `Lines.loopInOutMarkArm`.

![Loop in and out, Loop off](states/loop-in-and-out.png)

- Only the in set: the band reaches to the end of the song, with the bracket at the in only.

![Loop in only, Loop off](states/loop-in-only.png)

- Only the out set: the band reaches from the start of the song, with the bracket at the out only.

![Loop out only, Loop off](states/loop-out-only.png)

- Moving a track up or down: its header is lifted, its own row is dimmed, and an accent line shows where it will land.

![Reordering](states/reordering.png)

### Recording

**Recording in progress** (`Recording/RecordingClip.swift`, `Recording/TrackRecording.swift`). The only red thing in the timeline. Values: `Colors.record`, `Colors.recordingClipFill`, `Colors.recordingClipBar`, `Colors.recordingClipOutline`, `Lines.recordOriginWidth`.

- Running up: the song plays the bars before the recording starts. A red line stands where it will start. The track has a red mark and a red dot, and Record is lit in the bar.

![Running up](states/running-up.png)

- Recording: a red clip grows from the red line to the playhead, with "Recording" in its bar.

![Recording](states/recording.png)

### The empty window and messages

**Empty window** (`MainLayout/EmptyWindow.swift`). Before a song is dropped the window holds only the words "Drop a song here". Values: `Fonts.emptyWindowTitle`.

![Empty](states/empty.png)

**Messages** (`Messages/MessageBanner.swift`). Two kinds. A banner is for something the user should know that does not stop them: a glass bar at the top of the timeline with a triangle, one sentence and a close button. An alert is for something that stops the work: the system's own alert with a title, one or two sentences and OK. The picture shows both at once, so the banner is dimmed behind the alert. Values: `Sizes.messageBannerHeight`, `Sizes.messageBannerMaximumWidth`.

![Message](states/message.png)

### Under everything

**Window background and the look** (`WindowBackground.swift`, `lockstepLook()` in `GlassSurfaces.swift`). The dark window colour edge to edge, and the setting that keeps every window dark with the accent on the system's controls. Values: `Colors.windowBackground`.

**App icon** (`Lockstep/Resources/Assets.xcassets/AppIcon.appiconset`, drawn by `docs/design/icon/make-icons.swift`). "In step", chosen on 13 November 2026: four accent syllables, each over a grey beat dot, on the dark rounded tile. Only the Lockstep app has it, not the design lab. `swift docs/design/icon/make-icons.swift` draws all ten sizes again.

## 8. Open points

These were seen in the first pictures of the states. None is changed. Each is a matter of taste or an idea, and each names the picture where it shows.

1. Switches are pink in the front window. Tighten lines turned pink, the accent colour this Mac is set to, in a picture taken while the lab window was in front, and the chosen feel got a pink ring. The app's own accent is purple. The saved pictures show a window in the background, where switches are grey. (Seen in a first take of `main.png`, since retaken.)
2. The song's waveform is almost white and is the brightest thing in the window. (`main.png`)
3. Zoomed out, beat lines are dense and as bright as the clips, so the rows look striped. (`main.png`, `stress.png`)
4. Zoomed out, clip names are cut to nothing or to one word, and some clips show only their take count. (`main.png`, `dragging-clip.png`)
5. The floating bar lies over the lowest rows when there are many tracks. (`stress.png`)
6. The panel on the right has a large empty stretch in the middle when few things are shown. (`a-track-selected.png`, `several-clips-selected.png`)
7. In the panel on the right, "Track" and "Clip" follow each other without a line between them, while "Song" has one. (`one-clip-selected.png`)
8. The ring that shows a track's clips being made again is small and has no words. (`a-track-selected.png`)
9. The takes panel opened on top of its own clip and the rows under it, so the clip it belonged to was hidden. The takes panel is gone since 13 November 2026: the takes are listed in the panel on the right.
10. In the takes list, the take's words lie on the beat lines and are small. (`takes-list.png`)
11. With many takes the takes list in the panel on the right is cut off at the Song part, without a sign that it scrolls. In a window 720 points high that already happens with five takes. (`one-clip-selected.png`)
12. The sheets have no highlighted main button: Start, Done and Try Again look like Close. This may be because the window was in the background when the picture was taken. (`calibrate.png`, `send.png`)
13. The calibrate sheet still says "press Start" after it is done or has failed, where the buttons are Measure Again and Try Again. (`calibrate-done.png`, `calibrate-failed.png`)
14. In the Send panel the file name is cut in the middle ("Night Shift tak...3 01.00.16.00.wav"). (`send.png`)
15. The marked stretch is faint: a thin edge and a light tint. (`marked-stretch.png`)
16. The snap line at a beat is hard to tell from the beat lines around it. (`snapped.png`)
17. While a track is moved, its lifted header covers the name of the track it passes over, and its clips do not travel with it. (`reordering.png`)
18. The place a moved clip was recorded at is a faint dashed box. (`dragging-clip.png`)
19. The empty window has only the words "Drop a song here": no symbol, no button to choose a file. (`empty.png`)
20. The banner lies over the song's waveform. There is no picture of the banner alone, undimmed. (`message.png`)
21. The mute shortcut differs between the two menus: Shift-M for a clip, M for a track. (`menu-clip.png`, `menu-track.png`)
22. The beat line's menu has one command. (`menu-beat.png`)
23. The large "Not calibrated" readout has a long dash before the words where the number would be. (`controls.png`)
24. In the Clips sheet the last row runs below the window's edge, and "Being renamed" looks odd at the two narrow zooms, where the name field is wider than the clip. (`clips.png`)
25. In the Stress state the selected clip's name and its words do not match. Made-up content only. (`stress.png`)
26. At the smallest window size, the lab's stepping panel lies over the bottom of the floating bar. This is the lab's own panel, not the design. (`main-900x560.png`)
27. Still open from phase 2: with 200 clips, zooming and scrolling are two to four times too slow.
28. With the heading "Sound" and its four rows, the clip part of the panel is longer than a window 720 points high: the takes list is cut off after its first rows and the rest needs scrolling. On a track without a Sound the four dimmed rows take that room and do nothing. (`one-clip-with-a-sound.png`, `one-clip-selected.png`)
29. The knobs of a clip stand a little further left than its Volume and Strength sliders, because room is kept before the number for the arrow of a turned knob. (`one-clip-with-its-own-space.png`)
30. In the Send panel "With sound" stands at the bottom left, beside Done, away from the file it changes. (`send.png`)
31. With effects, the clip part of the panel is longer still: a clip with five effects fills the panel down to the delay in a window 720 points high, and its takes are reached only by scrolling. Each effect takes two lines. (`three-effects-two-overlapping.png`)
32. The band of an effect is neutral, dark with a light line, so it keeps clear of the timing colours and the accent. It may read as a label more than as a part of the sound. Zoomed out it is a small dark box. (`a-low-double-on-two-words.png`, `several-clips-with-effects.png`)
33. An effect on the whole clip shows as the letters "FX" in the clip's bar, which a narrow clip has no room for. (`a-clip-with-a-thick-double.png`, `a-narrow-clip-with-an-effect.png`)
34. A double-click on an effect's Level puts it at 0.0 dB, as on the volume sliders, and not at the level the kind starts with.
35. With "Aim at" the clip part of the panel is one line longer still. In a window 720 points high, one clip with five takes shows two of them before the rest needs scrolling. (`a-clip-aimed-at-lead.png`)
36. The lines at the lead's syllables are strong, with a dark edge, and cut the double's waveform into pieces where the syllables are dense. A lead syllable that no syllable of the double is paired with looks the same as one that is. (`a-double-against-its-lead.png`)
37. The words on a double's markers are "On the lead" and "No match", whatever the aimed track is called. (`a-double-against-its-lead.png`)
38. The box of "Aim at" and the box of a track's Sound look the same but are two pieces of code: the Sound box was not changed to use the shared part, because other phases worked in its file that night.
39. A track's effect has a power symbol where an own effect has a cross, in the accent colour while the effect is on. A clip on a track with three effects then has three accent-coloured symbols under each other, and the symbol is small. (`a-clip-with-effects-from-its-track.png`)
40. In a list that holds a track's effect, the clip's own rows keep an empty place before their value, so that all sliders stand in one line. (`an-effect-from-the-track-and-two-own.png`)
41. A row that several clips share says "Whole clip" or "Track", and nothing says how many of the clips have it as their own and how many from their track. (`several-clips-one-from-the-track-and-one-own.png`)
42. With a track's effects the clip part of the panel is longer again: two effects of the track and five takes leave room for one take before the rest needs scrolling, in a window 720 points high. (`a-clip-with-its-own-level-and-an-effect-off.png`)

import LockstepCore
import SwiftUI

/// The glass panel on the right of `MainLayout`. It has two parts with a thin
/// line between them:
///
/// - The top part follows the selection, and shows a clip's things, a
///   track's or the song's, never two of them. With a clip selected: its Resolve start time, name,
///   words, volume, the controls that correct its timing, its effects and,
///   when its line has more than one take, the takes (`TakesList`). With
///   several clips selected it shows only what can be set for all of them
///   at once: the volume, the four knobs of their Sound, the correction,
///   the button that adds an effect and the effects they share. With a
///   track selected and no clip: the track's name, its volume, the switch
///   Mute, the button Normalize Track, its Voice, its Sound and its
///   effects, which every clip of the track gets. While words are marked in one of its
///   clips, the button that adds an effect puts it on those words. With
///   the song selected (a click on its header) and no clip: the song's name
///   and its volume. With nothing selected it says so.
/// - The bottom part is always the same and always in view: the delay and
///   Send to DaVinci.
///
/// The top part scrolls when the panel is too short for it, which happens
/// with many takes, and in the smallest window with any takes at all. In a
/// taller window the room that is left over lies between the two parts.
///
/// Give it its width from outside (`DesignTokens.Sizes.inspectorWidth`). It
/// fills the height it is given.
///
/// A part is shown only when its feature is in `features`:
/// - Track: its name and Mute with `tracks`, its volume and Normalize Track
///   with `volume` as well, its Voice with `trackVoice` as well (and in it
///   the switch "Natural" with `naturalVoice`), its Sound with `voiceSound`
///   as well.
/// - Song: its name and its volume, with `volume`.
/// - Clip: the words with `clipText`, the volume with `volume`, the takes
///   with `takes`, the Resolve start time with `sendToDaVinci` or `resolveStart`. The name is
///   there with any of these and with `clipEditing`. Under "Correction":
///   the choice of Off, Lines or All and Strength with `tightenLines` or
///   `quantize`, the sub-beats with `feel`, the row "Aim at" with
///   `lockToLead`, and Stretch with `quantize`.
///   Under "Sound", the four knobs with `voiceSound`. Under "Effects",
///   the clip's effects and the button that adds one, with `doubles` or
///   `wordEffects`.
///   Several clips at once are shown with `volume` or with any of those.
/// - With `trackEffects` (and `doubles` or `wordEffects`): the section
///   "Effects" of a track, the rows of a track's effects in a clip's list,
///   and the rows several clips share. Without it a track has the heading
///   "Effects" only while words are marked in one of its clips, a clip
///   lists its own effects alone, and several clips list none.
/// - The bottom part: the delay with `calibration`, Send to DaVinci with
///   `sendToDaVinci`.
public struct Inspector: View {
    /// The features that put something in the inspector.
    private static let trackFeatures: FeatureSet = [.tracks]
    /// What puts something under "Correction" for the selected clips.
    private static let tightenFeatures: FeatureSet = [.tightenLines, .quantize, .feel]
    private static let clipFeatures: FeatureSet = [
        .clipEditing, .clipText, .volume, .takes, .sendToDaVinci, .resolveStart,
        .tightenLines, .quantize, .feel, .voiceSound, .doubles, .wordEffects,
    ]
    private static let songFeatures: FeatureSet = [.calibration, .sendToDaVinci]

    /// Whether the inspector has anything to show with these features. When
    /// it has not, `MainLayout` leaves out the inspector and its button.
    public static func hasContent(for features: FeatureSet) -> Bool {
        !features.isDisjoint(with: trackFeatures.union(clipFeatures).union(songFeatures))
    }

    private let window: MainLayoutContent
    private let features: FeatureSet
    /// The same playhead the main timeline shows.
    private let playhead: PlayheadPosition
    /// What a press on the delay readout does. Nil leaves it a text.
    private let onDelayPressed: (@MainActor () -> Void)?
    /// What a press on Send to DaVinci does. Nil leaves it doing nothing.
    private let onSendPressed: (@MainActor () -> Void)?
    /// Told when the volume control of the selected clips is moved. Nil
    /// leaves the control changing only what it shows.
    private let onClipVolumeChanged: (@MainActor (_ volumeDB: Double, _ isFinal: Bool) -> Void)?
    /// Told when the volume control of the selected song is moved. Nil
    /// leaves the control changing only what it shows.
    private let onSongVolumeChanged: (@MainActor (_ volumeDB: Double, _ isFinal: Bool) -> Void)?
    /// Told when a control under "Correction" is used, for the selected clips.
    /// Nil leaves those controls changing only what they show.
    private let tighten: TightenActions?
    /// Told when a take in the takes list is clicked, when a take's Play
    /// button is pressed and when Delete Other Takes is pressed. Nil leaves
    /// the list a picture.
    private let takes: TakesActions?
    /// Told when the selected track's volume control is moved
    /// (`TrackActions.volumeChanged`), when its Mute switch is switched
    /// (`TrackActions.mutePressed`) and when Normalize Track is pressed
    /// (`TrackActions.menuCommand`, as the same command in the track's menu).
    /// Nil leaves the three changing only what they show.
    private let tracks: TrackActions?
    /// Told when the switch, the menu or a knob under "Voice" is used for
    /// the selected track. Nil leaves the section changing only what it
    /// shows.
    private let voice: VoiceActions?
    /// Told when the Sound menu of the selected track or a knob under
    /// "Sound" is used. Nil leaves them changing only what they show.
    private let sound: SoundActions?
    /// Told when an effect is added from the menu under "Effects", when a
    /// level is moved, an effect removed or a row clicked. Nil leaves them
    /// changing only what they show.
    private let effects: EffectsActions?

    private var content: TimelineContent { window.timeline }

    private var selectedTrack: TrackRow? {
        content.trackRows.first(where: \.isSelected)
    }

    private var selectedClips: [ClipBox] {
        content.trackRows.flatMap(\.clips).filter(\.isSelected)
    }

    /// Whether the song's settings are shown: the song is selected, no clip
    /// is, and the features have its volume.
    private var showsSong: Bool {
        content.songIsSelected && selectedClips.isEmpty && features.contains(.volume)
    }

    /// The track whose settings are shown, when the features have any. A
    /// selected clip takes the track's place: the track it is on is still
    /// marked in the timeline, but the panel is then about the clip alone.
    /// The selected song takes it in the same way.
    private var shownTrack: TrackRow? {
        guard selectedClips.isEmpty, !showsSong, !features.isDisjoint(with: Self.trackFeatures) else { return nil }
        return selectedTrack
    }

    /// The clips the clip section is about: one, several or none. Several
    /// clips have only the volume, the knobs of their Sound, the tightening
    /// and the adding of an effect in common, so without those they show
    /// nothing.
    private var shownClips: [ClipBox] {
        let clips = selectedClips
        let needed: FeatureSet = clips.count > 1
            ? Self.tightenFeatures.union([.volume, .voiceSound]).union(EffectsMenu.features)
            : Self.clipFeatures
        return features.isDisjoint(with: needed) ? [] : clips
    }

    /// Whether to say "Nothing selected": only when the top part could show
    /// something with these features and there is no track and no clip for it.
    private var saysNothingSelected: Bool {
        selectedTrack == nil
            && !showsSong
            && selectedClips.isEmpty
            && !features.isDisjoint(with: Self.trackFeatures.union(Self.clipFeatures))
    }

    public init(
        content: MainLayoutContent,
        features: FeatureSet,
        playhead: PlayheadPosition,
        onDelayPressed: (@MainActor () -> Void)? = nil,
        onSendPressed: (@MainActor () -> Void)? = nil,
        onClipVolumeChanged: (@MainActor (_ volumeDB: Double, _ isFinal: Bool) -> Void)? = nil,
        onSongVolumeChanged: (@MainActor (_ volumeDB: Double, _ isFinal: Bool) -> Void)? = nil,
        tighten: TightenActions? = nil,
        takes: TakesActions? = nil,
        tracks: TrackActions? = nil,
        voice: VoiceActions? = nil,
        sound: SoundActions? = nil,
        effects: EffectsActions? = nil
    ) {
        self.window = content
        self.features = features
        self.playhead = playhead
        self.onDelayPressed = onDelayPressed
        self.onSendPressed = onSendPressed
        self.onClipVolumeChanged = onClipVolumeChanged
        self.onSongVolumeChanged = onSongVolumeChanged
        self.tighten = tighten
        self.takes = takes
        self.tracks = tracks
        self.voice = voice
        self.sound = sound
        self.effects = effects
    }

    public var body: some View {
        VStack(spacing: 0) {
            if saysNothingSelected {
                nothingSelected
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sectionGap) {
                        if showsSong {
                            songSection
                        }
                        if let shownTrack {
                            trackSection(shownTrack)
                        }
                        if let clip = shownClips.first {
                            if shownClips.count == 1 {
                                clipSection(clip)
                            } else {
                                severalClipsSection(shownClips)
                            }
                        }
                    }
                    .padding([.horizontal, .top], DesignTokens.Spacing.panelPadding)
                    .padding(.bottom, DesignTokens.Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            if !features.isDisjoint(with: Self.songFeatures) {
                Rectangle()
                    .fill(DesignTokens.Colors.separator)
                    .frame(height: DesignTokens.Lines.separatorWidth)
                songAndSendSection
                    .padding([.horizontal, .bottom], DesignTokens.Spacing.panelPadding)
                    .padding(.top, DesignTokens.Spacing.medium)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(DesignTokens.Shapes.panel)
        .glassPanel()
    }

    // MARK: Nothing selected

    /// What the top part says when there is no track and no clip to show,
    /// in the middle of the room it has.
    private var nothingSelected: some View {
        VStack(spacing: DesignTokens.Spacing.small) {
            Text("Nothing selected")
                .font(DesignTokens.Fonts.label)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Text("Click a track or a clip to see its settings here.")
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Spacing.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: The selected track

    /// The selected track, shown while no clip is selected: its name, its
    /// volume, the switch Mute, the button Normalize Track, its Voice, its
    /// Sound and its effects, which are the things a track has. They stand
    /// in the order the sound is made in: the voice is changed first, then
    /// the Sound and the effects act on it. The volume is the slider a clip and the song
    /// have, from -24 to +12 dB: a track can be turned down like the song
    /// and lifted like a clip. Normalize Track is dimmed for a track without
    /// clips, where it has nothing to act on.
    private func trackSection(_ track: TrackRow) -> some View {
        let id = track.id
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            heading("Track") {
                headingDetail(track.name)
            }
            if features.contains(.volume) {
                row("Volume") {
                    ClipVolumeControl(
                        volumeDB: track.volumeDB,
                        range: Track.gainRange,
                        name: "Track volume",
                        width: .compact,
                        onChange: tracks?.volumeChanged.map { changed in { volumeDB, isFinal in changed(id, volumeDB, isFinal) } }
                    )
                    // Another track's slider is another slider: nothing one holds while it is
                    // moved is carried over to the next track that is selected.
                    .id(id)
                }
            }
            TrackMuteSwitch(isMuted: track.muted, onChange: tracks?.mutePressed.map { pressed in { pressed(id) } })
            if features.contains(.volume) {
                available(!track.clips.isEmpty) {
                    NormalizeTrackButton(action: tracks?.menuCommand.map { command in { command(.normalize, id) } })
                }
            }
            if features.contains(.trackVoice) {
                VoiceSection(
                    trackID: id,
                    voice: track.voice,
                    state: track.voiceState,
                    ownPresets: window.ownVoicePresets,
                    showsNatural: features.contains(.naturalVoice),
                    isAvailable: window.canChangeVoice,
                    actions: voice
                )
                // Another track's section is another section: nothing it
                // keeps is carried over to the next track that is selected.
                .id(id)
            }
            if features.contains(.voiceSound) {
                trackSoundSection(track)
            }
            if !features.isDisjoint(with: EffectsMenu.features) {
                if features.contains(.trackEffects) {
                    trackEffectsSection(track)
                } else if wordsAreMarked(on: track) {
                    markedWordsEffects
                }
            }
        }
    }

    /// Whether words are marked in a clip of this track: a stretch is marked on the track, and it crosses
    /// one of the track's clips. An effect that is added then goes on those words.
    private func wordsAreMarked(on track: TrackRow) -> Bool {
        guard let stretch = content.dragging.markedStretch, stretch.trackID == track.id
        else { return false }
        return track.clips.contains { clip in
            guard let range = clip.timeRange else { return false }
            return range.lowerBound < stretch.range.upperBound && range.upperBound > stretch.range.lowerBound
        }
    }

    /// The heading "Effects" with its "+", under the track's own things, while words are marked in one of
    /// the track's clips. Marking words takes the selection from the clips, so the panel is about the track
    /// then, and without this the button that puts an effect on the marked words would be out of reach
    /// just when it is wanted. One quiet line says where the effect goes. Once one is added the clip is
    /// selected, and the panel shows the clip with its new effect.
    private var markedWordsEffects: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            heading("Effects") {
                AddEffectButton(features: features, onChosen: effects?.addChosen)
            }
            quietLine("An effect you add goes on the marked words.")
        }
    }

    /// The effects of the selected track, under its Sound: the heading "Effects" with its "+", and one row
    /// for each effect of the track (`EffectsList`), which every clip of the track gets. A track without
    /// effects has one quiet line that says so.
    ///
    /// While words are marked in one of the track's clips, the "+" puts the effect on those words, as it
    /// did before a track could have effects: its menu is the clips' menu, and the line under the rows says
    /// where the effect goes. The track's rows stay listed above that line.
    private func trackEffectsSection(_ track: TrackRow) -> some View {
        let id = track.id
        let wordsAreMarked = wordsAreMarked(on: track)
        var onTrackChosen: (@MainActor (ClipEffect.Kind) -> Void)?
        if let chosen = effects?.trackAddChosen {
            onTrackChosen = { kind in chosen(kind, id) }
        }
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            heading("Effects") {
                AddEffectButton(
                    features: features,
                    target: wordsAreMarked ? .clips : .track,
                    onChosen: wordsAreMarked ? effects?.addChosen : onTrackChosen
                )
            }
            if !track.effects.isEmpty {
                EffectsList(effects: track.effects, subject: .track(id), actions: effects)
                    // Another track's list is another list: nothing a row keeps while its slider
                    // is moved is carried over to the next track that is selected.
                    .id(id)
            }
            if wordsAreMarked {
                quietLine("An effect you add goes on the marked words.")
            } else if track.effects.isEmpty {
                quietLine("An effect you add here is heard on every clip of this track.")
            }
        }
    }

    // MARK: Sound

    /// The Sound of the selected track: the box that opens the menu it is
    /// chosen from, and under it the four knobs. A track without a Sound has
    /// the box alone, which reads "None": there is nothing for a knob to turn.
    @ViewBuilder private func trackSoundSection(_ track: TrackRow) -> some View {
        let id = track.id
        soundHeading
        SoundMenuButton(
            soundName: track.sound?.name,
            ownPresets: window.ownSoundPresets,
            onCommand: sound?.menuCommand.map { chosen in { command in chosen(command, id) } }
        )
        // Another track's box and sliders are other controls: nothing one
        // keeps is carried over to the next track that is selected.
        .id(id)
        if let knobs = track.sound?.knobs {
            ForEach(SoundKnob.allCases, id: \.self) { knob in
                row(knob.title) {
                    SoundKnobSlider(
                        knob: knob,
                        value: knobs[knob],
                        width: .compact,
                        onChange: sound?.trackKnobChanged.map { changed in
                            { value, isFinal in changed(id, knob, value, isFinal) }
                        }
                    )
                    .id(id)
                }
            }
        }
    }

    /// The four knobs of the selected clips, one or several, under the
    /// heading "Sound". A clip shows the knobs of its track's Sound. A knob it
    /// has turned for itself shows the clip's value and a mark before it, and
    /// a press on the mark puts the knob back to the track's value. Clips
    /// that differ read "Mixed", and using the slider gives all of them the
    /// same.
    ///
    /// Clips on a track without a Sound have the four rows dimmed, with a
    /// line that says so: there is nothing for a knob to turn. A knob such a
    /// clip turned earlier keeps its value and its mark. When only some of
    /// the selected clips are on a track with a Sound, the rows are about those.
    @ViewBuilder private func clipSoundSection(_ clips: [ClipBox]) -> some View {
        if features.contains(.voiceSound) {
            let ids = Set(clips.map(\.id))
            // Each selected clip with the Sound of the track it is on.
            let onTracks = content.trackRows.flatMap { track in
                track.clips.filter { ids.contains($0.id) }.map { (clip: $0, track: track) }
            }
            let withSound = onTracks.filter { $0.track.sound != nil }
            let shown = withSound.isEmpty ? onTracks : withSound
            soundHeading
            if withSound.isEmpty {
                Text(Set(onTracks.map(\.track.id)).count > 1 ? "These tracks have no Sound." : "This track has no Sound.")
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            available(!withSound.isEmpty) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                    ForEach(SoundKnob.allCases, id: \.self) { knob in
                        // What each clip is heard with: its own value, or else its track's.
                        let values = shown.map { $0.clip.ownKnobs[knob] ?? $0.track.sound?.knobs[knob] }
                        let known = values.compactMap { $0 }
                        let ofTracks = withSound.compactMap { $0.track.sound?.knobs[knob] }
                        row(knob.title) {
                            SoundKnobSlider(
                                knob: knob,
                                value: known.reduce(0, +) / Double(max(known.count, 1)),
                                width: .compact,
                                isMixed: Set(values).count > 1,
                                showsValue: !withSound.isEmpty,
                                ofClip: SoundKnobSlider.OfClip(
                                    isTurned: shown.contains { $0.clip.ownKnobs[knob] != nil },
                                    trackValue: ofTracks.reduce(0, +) / Double(max(ofTracks.count, 1))
                                ),
                                onChange: sound?.clipKnobChanged.map { changed in
                                    { value, isFinal in changed(knob, value, isFinal) }
                                },
                                onReset: sound?.clipKnobReset.map { reset in { reset(knob) } }
                            )
                        }
                    }
                }
            }
        }
    }

    /// The heading "Sound", with the small ring in its line while the sounds
    /// of what the panel shows are being made.
    private var soundHeading: some View {
        heading("Sound") {
            if let progress = window.soundRemakeProgress {
                SoundProgressRing(progress: progress)
            }
        }
    }

    // MARK: The selected song

    /// The selected song, shown while no clip is selected: its name and its
    /// volume. The song can only be turned down, so the slider ends at 0 dB,
    /// which plays the song as its file is.
    private var songSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            heading("Song") {
                headingDetail(content.songName)
            }
            row("Volume") {
                ClipVolumeControl(
                    volumeDB: window.songVolumeDB,
                    range: Project.songGainRange,
                    name: "Song volume",
                    width: .compact,
                    onChange: onSongVolumeChanged
                )
            }
        }
    }

    // MARK: Correction

    /// The controls that correct the timing of the selected clips, one or
    /// several, as five rows under one heading: Off, Lines or All, the
    /// sub-beats, "Aim at", Strength and Stretch. No row has a heading of its
    /// own. A control shows the value the clips share, or says that they
    /// differ, and using it sets all of them. The small ring in the heading's
    /// line shows their sound being made.
    ///
    /// "Aim at" and Strength are dimmed while every selected clip is Off, and
    /// Stretch while none of them is All: there they would change nothing
    /// that is heard. The sub-beats are dimmed while every selected clip aims
    /// at a track, because such a clip is held against that track's
    /// syllables and its sub-beats are not used.
    @ViewBuilder private func tightenSection(_ clips: [ClipBox]) -> some View {
        if !features.isDisjoint(with: Self.tightenFeatures) {
            let corrections = clips.map(\.correction)
            let strengths = clips.map(\.strength)
            let stretches = Set(clips.map(\.stretches))
            // Where the content does not say a clip's choice, it is what the clip is drawn in.
            let subBeats = clips.map { $0.menuFeel ?? ($0.isTriplet ? .triplets : .sixteenths) }
            let aimTracks = tracksToAimAt(for: clips)
            // An aim at a track the clips cannot aim at counts as the beat.
            let aims = clips.map { clip in aimTracks.first { $0.id == clip.aimTrackID }?.id }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                heading("Correction") {
                    if let progress = window.clipRemakeProgress {
                        TightenProgressRing(progress: progress)
                    }
                }
                if !features.isDisjoint(with: [.tightenLines, .quantize]) {
                    CorrectionChoice(
                        correction: Set(corrections).count == 1 ? corrections.first : nil,
                        fillsWidth: true,
                        onChange: tighten?.correctionChosen
                    )
                }
                if features.contains(.feel) {
                    available(aims.contains(nil)) {
                        ClipSubBeatsChoice(
                            subBeats: Set(subBeats).count == 1 ? subBeats.first : nil,
                            fillsWidth: true,
                            onChange: tighten?.subBeatsChosen
                        )
                    }
                }
                if features.contains(.lockToLead) {
                    available(corrections.contains { $0 != .off }) {
                        HStack(spacing: DesignTokens.Spacing.medium) {
                            label("Aim at")
                            AimMenuButton(
                                aimTrackID: aims.first ?? nil,
                                isMixed: Set(aims).count > 1,
                                tracks: aimTracks,
                                onChange: tighten?.aimChosen
                            )
                            // Other clips have another box: what one box keeps in the design lab
                            // is not carried over to the next clips that are selected.
                            .id(clips.map(\.id))
                        }
                    }
                }
                if !features.isDisjoint(with: [.tightenLines, .quantize]) {
                    available(corrections.contains { $0 != .off }) {
                        row("Strength") {
                            StrengthSlider(
                                strength: strengths.reduce(0, +) / Double(max(strengths.count, 1)),
                                width: .compact,
                                isMixed: Set(strengths).count > 1,
                                onChange: tighten?.strengthChanged
                            )
                        }
                    }
                }
                if features.contains(.quantize) {
                    available(corrections.contains(.all)) {
                        StretchSwitch(isOn: stretches.count == 1 ? stretches.first : nil, onChange: tighten?.stretchChanged)
                    }
                }
            }
        }
    }

    /// The tracks these clips can aim at, in the order of the timeline:
    /// every track that none of them is on. A clip cannot aim at its own
    /// track.
    private func tracksToAimAt(for clips: [ClipBox]) -> [AimTrack] {
        let ids = Set(clips.map(\.id))
        return content.trackRows
            .filter { track in !track.clips.contains { ids.contains($0.id) } }
            .map { AimTrack(id: $0.id, name: $0.name) }
    }

    // MARK: Effects

    /// The effects of the selected clips, under the heading "Effects". The
    /// small "+" in the heading's line opens the menu an effect is added
    /// from: it goes on the words that are marked in a clip, or else on the
    /// whole of every selected clip.
    ///
    /// One clip lists its effects under the heading, one row each
    /// (`EffectsList`): the effects of its track first, each with what the
    /// clip changed of it, then its own. A clip without any says in one
    /// quiet line how an effect is added.
    ///
    /// Several clips list the effects they share
    /// (`MainLayoutContent.selectedClipsEffects`), one row each, whose level
    /// and button act on all of them. When they share none, the heading
    /// with its button is all there is.
    @ViewBuilder private func effectsSection(_ clips: [ClipBox]) -> some View {
        if !features.isDisjoint(with: EffectsMenu.features) {
            let showsTrackEffects = features.contains(.trackEffects)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                heading("Effects") {
                    AddEffectButton(features: features, onChosen: effects?.addChosen)
                }
                if clips.count == 1, let clip = clips.first {
                    let listed = showsTrackEffects ? clip.effects : clip.ownEffects
                    if listed.isEmpty {
                        quietLine("Mark words in the clip, or select the clip, and add an effect.")
                    } else {
                        EffectsList(
                            effects: listed,
                            zeroSeconds: Double(content.songPlace.zeroSample) / Lockstep.sampleRate,
                            actions: effects
                        )
                        // Another clip's list is another list: the row a list lit by itself is
                        // not carried over to the next clip that is selected.
                        .id(clip.id)
                    }
                } else if showsTrackEffects, !window.selectedClipsEffects.isEmpty {
                    EffectsList(effects: window.selectedClipsEffects, subject: .clips, actions: effects)
                        // Other clips share other rows: nothing a row keeps is carried over.
                        .id(clips.map(\.id))
                }
            }
        }
    }

    /// One quiet line of small text under a heading, which says what there is to do.
    private func quietLine(_ text: String) -> some View {
        PanelQuietLine(text)
    }

    /// A row that can only be used at times: dimmed, and deaf to the pointer
    /// and the keys, while it cannot.
    private func available(_ isAvailable: Bool, @ViewBuilder row: () -> some View) -> some View {
        row()
            .disabled(!isAvailable)
            .opacity(isAvailable ? 1 : DesignTokens.Opacity.unavailable)
    }

    // MARK: The selected clip

    /// Everything about one clip. Its Resolve start time stands in the
    /// heading's line, which saves the line it had at the bottom.
    private func clipSection(_ clip: ClipBox) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            heading("Clip") {
                if !features.isDisjoint(with: [.sendToDaVinci, .resolveStart]), !window.selectedClipResolveStart.isEmpty {
                    ResolveStartReadout(window.selectedClipResolveStart)
                }
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                clipName(clip.displayName)
                if features.contains(.clipText), !window.selectedClipText.isEmpty {
                    Text(window.selectedClipText)
                        .font(DesignTokens.Fonts.label)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("The words of the clip")
                } else if features.contains(.clipText), clip.isWritingOutWords {
                    WritingOutWordsLabel()
                }
            }
            if features.contains(.volume) {
                row("Volume") {
                    ClipVolumeControl(
                        volumeDB: clip.volumeDB,
                        width: .compact,
                        isHeldBack: window.selectedClipVolumeIsHeldBack,
                        onChange: onClipVolumeChanged
                    )
                }
            }
            clipSoundSection([clip])
            tightenSection([clip])
            effectsSection([clip])
            if features.contains(.takes), let range = clip.timeRange, !content.takeRows.isEmpty {
                TakesList(
                    takes: content.takeRows,
                    clipRange: range,
                    songLength: content.songLength,
                    beats: content.beats,
                    playhead: playhead,
                    pointer: window.takesPointer,
                    actions: takes
                )
                // A little more air than between two controls: the takes
                // are a list of their own under the clip's settings.
                .padding(.top, DesignTokens.Spacing.medium)
            }
        }
    }

    /// Several clips at once: how many, and what can be set for all of them,
    /// the volume, the knobs of their Sound, the tightening, the adding of an effect and the effects they share. The volume's knob stands at their
    /// average. When they differ the value reads "Mixed".
    private func severalClipsSection(_ clips: [ClipBox]) -> some View {
        let volumes = clips.map(\.volumeDB)
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            heading("Clips") {
                headingDetail("\(clips.count) selected")
            }
            if features.contains(.volume) {
                row("Volume") {
                    ClipVolumeControl(
                        volumeDB: volumes.reduce(0, +) / Double(volumes.count),
                        width: .compact,
                        isHeldBack: window.selectedClipVolumeIsHeldBack,
                        isMixed: Set(volumes).count > 1,
                        onChange: onClipVolumeChanged
                    )
                }
            }
            clipSoundSection(clips)
            tightenSection(clips)
            effectsSection(clips)
        }
    }

    /// The clip's name in a box, the way a field for typing a name looks.
    /// A name that is too long ends in an ellipsis.
    private func clipName(_ name: String) -> some View {
        Text(name)
            .font(DesignTokens.Fonts.label)
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, DesignTokens.Spacing.medium)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.Sizes.smallButton, alignment: .leading)
            .background(DesignTokens.Colors.controlFill, in: DesignTokens.Shapes.control)
            .help("Clip name")
            .accessibilityLabel("Clip name")
            .accessibilityValue(name)
    }

    // MARK: The delay and Send to DaVinci

    /// The part that never changes with the selection: the delay and Send
    /// to DaVinci. Nothing here is about one song only. The sub-beats were
    /// here until each clip got its own (see `tightenSection`).
    private var songAndSendSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            if features.contains(.calibration) {
                row("Delay") {
                    // In the window a delay that was never measured is
                    // always a warning: recordings may land late.
                    let readout = DelayReadout(milliseconds: window.delayMilliseconds, warns: true)
                    if let onDelayPressed {
                        // The same readout, drawn the same, as a button that
                        // opens the calibrate sheet.
                        Button(action: onDelayPressed) { readout }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens Calibrate Delay")
                    } else {
                        readout
                    }
                }
            }
            if features.contains(.sendToDaVinci) {
                SendToDaVinciButton(action: onSendPressed)
                    .disabled(!window.canSendToDaVinci)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Parts

    /// The heading of a section, with what belongs in its line at the right:
    /// the name of what the section is about, a readout or a small control.
    private func heading(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        PanelHeading(title, trailing: trailing)
    }

    /// The name of what a section is about, at the right of its heading. A
    /// long name ends in an ellipsis.
    private func headingDetail(_ detail: String) -> some View {
        Text(detail)
            .font(DesignTokens.Fonts.label)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// One line of the panel: what the control is on the left, the control on
    /// the right.
    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        PanelRow(label, control: control)
    }

    /// What a control is, before it or above it.
    private func label(_ label: String) -> some View {
        PanelLabel(label)
    }
}

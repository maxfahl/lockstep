import SwiftUI

// The controls that correct the timing of the selected clips, under the heading "Correction" in the panel on
// the right: the choice of Off, Lines or All, the sub-beats, what the clips aim at, Strength and Stretch, and
// the small ring that shows a sound being made. None of them has a label row of its own: the two choices say
// what they are in their words, and "Aim at", Strength and Stretch carry their names beside them.
//
// Each is about every selected clip at once. When the selected clips differ in a value, its control says so:
// a choice has nothing chosen, and the slider and the switch read "Mixed". Using the control then gives every
// selected clip the same value.
//
// Each control explains itself in one sentence when the pointer rests on it.

/// How much of a clip's timing is corrected: the three buttons of `CorrectionChoice`.
public enum ClipCorrection: CaseIterable, Sendable {
    /// The clip is heard as it was recorded.
    case off
    /// Each whole line slides toward the sub-beat nearest to its first syllable.
    case lines
    /// The lines slide, and then each syllable moves toward its nearest sub-beat.
    case all

    /// The word on its button.
    public var title: String {
        switch self {
        case .off: "Off"
        case .lines: "Lines"
        case .all: "All"
        }
    }
}

/// The choice of Off, Lines or All for the selected clips: how much of their timing is corrected.
///
/// Without `onChange`, as in the design lab, it keeps what it shows itself. With it, the choice shows
/// `correction` as it is given and tells its owner which one was pressed. The owner then changes the clips
/// and hands in the new value.
public struct CorrectionChoice: View {
    @State private var keptCorrection: ClipCorrection?
    private let givenCorrection: ClipCorrection?
    private let fillsWidth: Bool
    private let onChange: (@MainActor (ClipCorrection) -> Void)?

    /// - Parameters:
    ///   - correction: The one that is chosen. Nil when the selected clips differ: nothing is chosen then.
    ///   - fillsWidth: The three buttons share the width the choice is given, as in the panel. Left out,
    ///     the choice is as wide as its words.
    ///   - onChange: Told which one was pressed. Left out, the choice only changes what it shows.
    public init(
        correction: ClipCorrection?,
        fillsWidth: Bool = false,
        onChange: (@MainActor (ClipCorrection) -> Void)? = nil
    ) {
        _keptCorrection = State(initialValue: correction)
        givenCorrection = correction
        self.fillsWidth = fillsWidth
        self.onChange = onChange
    }

    private var correction: Binding<ClipCorrection?> {
        guard let onChange else { return $keptCorrection }
        return Binding(
            get: { givenCorrection },
            set: { chosen in
                if let chosen { onChange(chosen) }
            }
        )
    }

    public var body: some View {
        SegmentedChoice(
            name: "Correction",
            options: ClipCorrection.allCases.map { (value: Optional($0), title: $0.title) },
            selection: correction,
            help: "How much of the timing of the selected clips is corrected: nothing (Off), whole lines "
                + "so that their first syllable lands on a sub-beat (Lines), or lines and every syllable (All).",
            fillsWidth: fillsWidth
        )
    }
}

/// The slider "Strength": how much of the correction is applied to the selected clips, with the value after
/// it, such as "70 %". It is how much of the way lines slide and, with All, syllables move.
///
/// Without `onChange`, as in the design lab, moving the slider changes only what it shows. With it, the slider
/// shows the value it is given and tells its owner where it stands when it is let go, so one drag is one
/// change:
///
///     StrengthSlider(strength: 0.7) { strength in
///         model.setSelectedClipsStrength(strength)
///     }
///
/// It has no name of its own: the panel writes "Strength" before it, in the same line.
public struct StrengthSlider: View {
    @State private var strength: Double
    @State private var isMixed: Bool
    private let width: SliderWidth
    /// What the owner says the value is, and whether the selected clips differ.
    private let given: (strength: Double, isMixed: Bool)
    private let onChange: (@MainActor (Double) -> Void)?
    /// Where the slider stands while it is being moved. Kept here so the slider follows the pointer, and the
    /// owner hears nothing until it is let go.
    @State private var heldStrength: Double?

    /// - Parameters:
    ///   - strength: From 0 (0 %) to 1 (100 %). For clips that differ, where the knob should stand (their
    ///     average).
    ///   - isMixed: Shows "Mixed" in place of the number: the selected clips differ.
    ///   - onChange: Told the value the slider stands at, from 0 to 1, once it is let go. Nil lets the slider
    ///     change what it shows by itself.
    public init(
        strength: Double,
        width: SliderWidth = .normal,
        isMixed: Bool = false,
        onChange: (@MainActor (Double) -> Void)? = nil
    ) {
        let strength = min(max(strength, 0), 1)
        _strength = State(initialValue: strength)
        _isMixed = State(initialValue: isMixed)
        self.width = width
        self.given = (strength, isMixed)
        self.onChange = onChange
    }

    /// The value to draw: the owner's when it listens, unless the slider is being moved right now. The
    /// slider's own otherwise.
    private var shownStrength: Double {
        onChange == nil ? strength : heldStrength ?? given.strength
    }

    private var shownIsMixed: Bool {
        onChange == nil ? isMixed : heldStrength == nil && given.isMixed
    }

    private var value: Binding<Double> {
        guard onChange != nil else { return $strength }
        return Binding(get: { shownStrength }, set: { heldStrength = $0 })
    }

    /// The slider was let go: the value it stands at is the one that counts.
    private func settle() {
        guard let final = heldStrength else { return }
        onChange?(final)
        heldStrength = nil
    }

    public var body: some View {
        ValueSlider(
            name: "Strength",
            value: value,
            range: 0...1,
            width: width.points,
            valueText: shownIsMixed ? "Mixed" : "\(Int((shownStrength * 100).rounded())) %",
            widestValueText: "100 %",
            onHoldChange: { isHeld in
                if !isHeld { settle() }
            },
            help: "How much of the correction is applied: 0 % changes nothing, and 100 % moves lines and "
                + "syllables all the way to their sub-beats."
        )
        // Moving the slider gives every selected clip the value it shows, so the value is no longer mixed.
        .onChange(of: strength) {
            isMixed = false
        }
        .onDisappear { settle() }
    }
}

/// The choice "Sub-beats" of the selected clips: how many parts each beat has when their timing is measured
/// and corrected: 16ths, Triplets, or Auto, which reads it from each clip's own syllables.
///
/// Without `onChange`, as in the design lab, it keeps what it shows itself. With it, the choice shows
/// `subBeats` as it is given and tells its owner which one was pressed.
public struct ClipSubBeatsChoice: View {
    @State private var keptSubBeats: ClipMenu.Feel?
    private let givenSubBeats: ClipMenu.Feel?
    private let fillsWidth: Bool
    private let onChange: (@MainActor (ClipMenu.Feel) -> Void)?

    /// - Parameters:
    ///   - subBeats: The one that is chosen. Nil when the selected clips differ: nothing is chosen then.
    ///   - fillsWidth: The three buttons share the width the choice is given, as in the panel. Left out,
    ///     the choice is as wide as its words.
    ///   - onChange: Told which one was pressed. Left out, the choice only changes what it shows.
    public init(
        subBeats: ClipMenu.Feel?,
        fillsWidth: Bool = false,
        onChange: (@MainActor (ClipMenu.Feel) -> Void)? = nil
    ) {
        _keptSubBeats = State(initialValue: subBeats)
        givenSubBeats = subBeats
        self.fillsWidth = fillsWidth
        self.onChange = onChange
    }

    private var subBeats: Binding<ClipMenu.Feel?> {
        guard let onChange else { return $keptSubBeats }
        return Binding(
            get: { givenSubBeats },
            set: { chosen in
                if let chosen { onChange(chosen) }
            }
        )
    }

    public var body: some View {
        SegmentedChoice(
            name: "Sub-beats",
            options: ClipMenu.Feel.allCases.map { (value: Optional($0), title: $0.title) },
            selection: subBeats,
            help: "How many parts each beat has when the selected clips are measured and corrected: "
                + "four (16ths), three (Triplets) or what each clip's own syllables fit (Auto).",
            fillsWidth: fillsWidth
        )
    }
}

/// A track the selected clips can aim at: a line of the menu of the row "Aim at".
public struct AimTrack: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// The menu of the row "Aim at": "The beat", and under a line every track the selected clips can aim at, by
/// name. The line of what they aim at is ticked, and none is when they differ.
///
///     Menu { AimMenu(aimTrackID: lead.id, tracks: others) { trackID in ... } } label: { ... }
public struct AimMenu: View {
    /// What the line of the beat reads, in the menu and in the box.
    public static let beatTitle = "The beat"

    private let aimTrackID: UUID?
    private let isMixed: Bool
    private let tracks: [AimTrack]
    private let onChosen: (@MainActor (_ trackID: UUID?) -> Void)?

    /// - Parameters:
    ///   - aimTrackID: The track the selected clips aim at, whose line is ticked. Nil is the beat.
    ///   - isMixed: The selected clips differ: no line is ticked.
    ///   - tracks: The tracks they can aim at, in the order of the timeline.
    ///   - onChosen: Told which line was chosen: a track's id, or nil for the beat. Left out, choosing a
    ///     line does nothing.
    public init(
        aimTrackID: UUID?,
        isMixed: Bool = false,
        tracks: [AimTrack],
        onChosen: (@MainActor (_ trackID: UUID?) -> Void)? = nil
    ) {
        self.aimTrackID = aimTrackID
        self.isMixed = isMixed
        self.tracks = tracks
        self.onChosen = onChosen
    }

    /// The lines of the menu, for `MenuListing` and for a submenu of another menu.
    public var entries: [MenuEntry] {
        var entries: [MenuEntry] = [
            .command(Self.beatTitle, isChecked: !isMixed && aimTrackID == nil, action: action(nil)),
        ]
        if !tracks.isEmpty {
            entries.append(.divider)
            entries += tracks.map { track in
                .command(track.name, isChecked: !isMixed && aimTrackID == track.id, action: action(track.id))
            }
        }
        return entries
    }

    private func action(_ trackID: UUID?) -> (@MainActor () -> Void)? {
        guard let onChosen else { return nil }
        return { onChosen(trackID) }
    }

    public var body: some View {
        MenuEntries(entries)
    }
}

/// The box of the row "Aim at": what the correction of the selected clips is held against. It reads "The
/// beat", or the name of the track they aim at, or "Mixed" when they differ, and a press opens the menu the
/// aim is chosen from (`AimMenu`). It fills the width it is given.
///
/// Without `onChange`, as in the design lab, it keeps what it shows itself. With it, the box shows the aim
/// as it is given and tells its owner which line was chosen. The owner then changes the clips and hands in
/// the new value.
///
/// It has no name of its own: the panel writes "Aim at" before it, in the same line.
public struct AimMenuButton: View {
    @State private var keptAim: UUID?
    @State private var keptIsMixed: Bool
    private let given: (aimTrackID: UUID?, isMixed: Bool)
    private let tracks: [AimTrack]
    private let onChange: (@MainActor (_ trackID: UUID?) -> Void)?

    /// - Parameters:
    ///   - aimTrackID: The track the selected clips aim at. Nil is the beat. A track that is not among
    ///     `tracks` reads as the beat too.
    ///   - isMixed: Shows "Mixed" in place of a name: the selected clips differ.
    ///   - tracks: The tracks they can aim at, in the order of the timeline.
    ///   - onChange: Told which line was chosen: a track's id, or nil for the beat. Left out, the box only
    ///     changes what it shows.
    public init(
        aimTrackID: UUID?,
        isMixed: Bool = false,
        tracks: [AimTrack],
        onChange: (@MainActor (_ trackID: UUID?) -> Void)? = nil
    ) {
        _keptAim = State(initialValue: aimTrackID)
        _keptIsMixed = State(initialValue: isMixed)
        given = (aimTrackID, isMixed)
        self.tracks = tracks
        self.onChange = onChange
    }

    private var shownIsMixed: Bool {
        onChange == nil ? keptIsMixed : given.isMixed
    }

    /// The track the box names. Nil is the beat.
    private var shownTrack: AimTrack? {
        let id = onChange == nil ? keptAim : given.aimTrackID
        return tracks.first { $0.id == id }
    }

    private var shownText: String {
        shownIsMixed ? "Mixed" : shownTrack?.name ?? AimMenu.beatTitle
    }

    public var body: some View {
        Menu {
            AimMenu(aimTrackID: shownTrack?.id, isMixed: shownIsMixed, tracks: tracks) { trackID in
                if let onChange {
                    onChange(trackID)
                } else {
                    // Choosing a line gives every selected clip that aim, so they no longer differ.
                    keptAim = trackID
                    keptIsMixed = false
                }
            }
        } label: {
            MenuBoxLabel(text: shownText, isQuiet: shownIsMixed)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("What the timing of the selected clips is corrected toward: the beat, or the syllables of "
            + "another track, so that a double lands on its lead.")
        .accessibilityLabel("Aim at")
        .accessibilityValue(shownText)
    }
}

/// The switch "Stretch": whether the voice of the selected clips may be stretched and squeezed to move
/// syllables that run together. Off, such syllables move only together, and only pauses change.
///
/// Without `onChange`, as in the design lab, it keeps what it shows itself. With it, the switch shows `isOn`
/// as it is given and tells its owner what it was switched to. The owner then changes the clips and hands in
/// the new value.
public struct StretchSwitch: View {
    @State private var keptIsOn: Bool?
    private let givenIsOn: Bool?
    private let onChange: (@MainActor (Bool) -> Void)?

    /// - Parameters:
    ///   - isOn: Whether Stretch is on. Nil when the selected clips differ: the switch then stands off and
    ///     reads "Mixed".
    ///   - onChange: Told what the switch was switched to. Left out, the switch only changes how it looks.
    public init(isOn: Bool?, onChange: (@MainActor (Bool) -> Void)? = nil) {
        _keptIsOn = State(initialValue: isOn)
        givenIsOn = isOn
        self.onChange = onChange
    }

    private var shown: Bool? {
        onChange == nil ? keptIsOn : givenIsOn
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { shown ?? false },
            set: { isOn in
                if let onChange { onChange(isOn) } else { keptIsOn = isOn }
            }
        )
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            LabelledSwitch(
                title: "Stretch",
                isOn: isOn,
                help: "Lets the correction stretch and squeeze your voice to move syllables that run "
                    + "together; off, your voice is never stretched."
            )
            if shown == nil {
                MixedLabel()
            }
        }
    }
}

/// The small ring that fills while the sound of the selected clips is made again after a timing change. It
/// stands in the line of the heading "Correction" and is gone when the clips are ready.
public struct TightenProgressRing: View {
    private let progress: Double

    /// - Parameter progress: How far the making has come, from 0 to 1.
    public init(progress: Double) {
        self.progress = min(max(progress, 0), 1)
    }

    public var body: some View {
        MakingRing(progress: progress, name: "Making the sound of the selected clips again with the new timing")
    }
}

/// The word a switch reads when the selected clips differ in what it shows.
private struct MixedLabel: View {
    var body: some View {
        Text("Mixed")
            .font(DesignTokens.Fonts.value)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .help("The selected clips differ. Switching gives all of them the same.")
    }
}

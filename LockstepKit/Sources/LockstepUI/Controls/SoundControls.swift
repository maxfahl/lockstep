import LockstepCore
import SwiftUI

// The controls under the heading "Sound" in the panel on the right: the box that opens the menu a track's
// Sound is chosen from, the four knobs Squeeze, Tone, Warmth and Space, and the small ring that shows sounds
// being made. A track has the menu and its four knobs. A clip has the four knobs of its track, and can turn
// each of them for itself.
//
// Each explains itself in one sentence when the pointer rests on it.

/// What the panel shows of a track's Sound: its name and where its four knobs stand.
public struct SoundValues: Sendable, Equatable {
    /// The name of the preset it was chosen from, which the menu's box shows.
    public var name: String
    /// The four knobs, each from 0 to 1.
    public var knobs: SoundKnobs

    public init(name: String, knobs: SoundKnobs) {
        self.name = name
        self.knobs = knobs
    }

    /// The Sound a track has right after the built-in preset with this name was chosen for it. Nil when there
    /// is no such preset.
    public static func builtIn(_ name: String) -> SoundValues? {
        SoundPreset.builtIn(named: name).map { SoundValues(name: $0.name, knobs: $0.knobs) }
    }
}

extension SoundKnob {
    /// The knob's name in the panel.
    public var title: String {
        switch self {
        case .squeeze: "Squeeze"
        case .tone: "Tone"
        case .warmth: "Warmth"
        case .space: "Space"
        }
    }

    /// What the knob does, in one sentence, for its help tag.
    var help: String {
        switch self {
        case .squeeze: "How much loud and quiet words are evened out."
        case .tone: "How much of the Sound's tone is applied: less mud and more clarity."
        case .warmth: "How much grit the voice gets."
        case .space: "How much reverb and echo the voice gets."
        }
    }
}

/// What the Sound section of the panel on the right tells its owner. The owner then changes the track or the
/// selected clips, so the window shows the new values:
///
///     var sound = SoundActions()
///     sound.menuCommand = { command, trackID in model.soundMenu(command, on: trackID) }
///     sound.trackKnobChanged = { trackID, knob, value, isFinal in ... }
///     sound.clipKnobChanged = { knob, value, isFinal in ... }
///     sound.clipKnobReset = { knob in ... }
///     actions.sound = sound
///
/// Every action left nil leaves its control changing only what it shows, as in the design lab.
public struct SoundActions {
    /// A line was chosen in the Sound menu of the track with this id.
    public var menuCommand: (@MainActor (SoundMenu.Command, UUID) -> Void)?

    /// A knob of the track with this id was moved: where it stands, from 0 to 1. `isFinal` is false while
    /// the slider is still being moved and true once it is let go, so one drag can be one change.
    public var trackKnobChanged: (@MainActor (UUID, SoundKnob, _ value: Double, _ isFinal: Bool) -> Void)?

    /// A knob of the selected clips was moved: where it stands, from 0 to 1, which every selected clip then
    /// has as its own value. `isFinal` as for a track's knob.
    public var clipKnobChanged: (@MainActor (SoundKnob, _ value: Double, _ isFinal: Bool) -> Void)?

    /// The mark of a knob the selected clips turned for themselves was pressed: they follow their track with
    /// that knob again.
    public var clipKnobReset: (@MainActor (SoundKnob) -> Void)?

    public init() {}
}

/// The box that shows a track's Sound and opens the menu it is chosen from (`SoundMenu`): the Sound's name,
/// or "None" for a track without one. It fills the width it is given.
///
/// Without `onCommand`, as in the design lab, it keeps what it shows itself: choosing a preset or None
/// changes the name in the box, and the two commands about Max's own presets do nothing. With it, the box
/// shows `soundName` as it is given and tells its owner which line was chosen.
public struct SoundMenuButton: View {
    @State private var keptName: String?
    private let givenName: String?
    private let ownPresets: [String]
    private let onCommand: (@MainActor (SoundMenu.Command) -> Void)?

    /// - Parameters:
    ///   - soundName: The name of the track's Sound. Nil for a track without one: the box reads "None".
    ///   - ownPresets: The names of Max's own presets, in the order he saved them.
    ///   - onCommand: Told which line of the menu was chosen. Left out, the box only changes what it shows.
    public init(
        soundName: String?,
        ownPresets: [String] = [],
        onCommand: (@MainActor (SoundMenu.Command) -> Void)? = nil
    ) {
        _keptName = State(initialValue: soundName)
        givenName = soundName
        self.ownPresets = ownPresets
        self.onCommand = onCommand
    }

    private var shownName: String? {
        onCommand == nil ? keptName : givenName
    }

    public var body: some View {
        Menu {
            SoundMenu(soundName: shownName, ownPresets: ownPresets) { command in
                if let onCommand {
                    onCommand(command)
                } else if case .chosen(let name) = command {
                    keptName = name
                }
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.medium) {
                Text(shownName ?? "None")
                    .font(DesignTokens.Fonts.label)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(DesignTokens.Fonts.symbolSmall)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.medium)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.Sizes.smallButton, alignment: .leading)
            .background(DesignTokens.Colors.controlFill, in: DesignTokens.Shapes.control)
            .contentShape(DesignTokens.Shapes.control)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("The Sound of this track: a finished voice sound that every clip on it gets. None leaves the voice as it is.")
        .accessibilityLabel("Sound")
        .accessibilityValue(shownName ?? "None")
    }
}

/// One knob of a Sound: a slider with its value after it, such as "70 %". It is the slider "Strength" has,
/// with another name. The panel writes the knob's name before it, in the same line.
///
/// A track's knob is the slider and the value. A clip's knob (`ofClip`) also has a place before the value for
/// a mark, a small arrow that turns back: it is shown while the clip has turned the knob for itself, and a
/// press on it puts the knob back to the track's value. The place is kept while there is no mark, so the
/// four sliders of a clip stand in one line.
///
/// Without `onChange`, as in the design lab, it keeps what it shows itself: moving a clip's slider brings the
/// mark, and a press on the mark puts the slider at the track's value and takes the mark away. With it, the
/// slider shows what it is given and reports every move, so a knob can be heard while it is dragged:
///
///     SoundKnobSlider(knob: .space, value: 0.6, ofClip: .init(isTurned: true, trackValue: 0.08)) { value, isFinal in
///         model.setSelectedClipsKnob(.space, to: value, isFinal: isFinal)
///     } onReset: {
///         model.resetSelectedClipsKnob(.space)
///     }
public struct SoundKnobSlider: View {
    /// What a clip's knob has that a track's has not.
    public struct OfClip: Sendable, Equatable {
        /// The clip turned this knob for itself, or, of several selected clips, at least one did.
        public var isTurned: Bool
        /// Where the track's knob stands, from 0 to 1, which is where the knob goes when its mark is pressed.
        /// For clips on tracks that differ, the average.
        public var trackValue: Double

        public init(isTurned: Bool, trackValue: Double) {
            self.isTurned = isTurned
            self.trackValue = trackValue
        }
    }

    private let knob: SoundKnob
    private let width: SliderWidth
    private let showsValue: Bool
    /// What the owner says: the value, whether the selected clips differ, and what a clip's knob has.
    private let given: (value: Double, isMixed: Bool, ofClip: OfClip?)
    private let onChange: (@MainActor (_ value: Double, _ isFinal: Bool) -> Void)?
    private let onReset: (@MainActor () -> Void)?

    // What the slider keeps while it has no owner.
    @State private var keptValue: Double
    @State private var keptIsMixed: Bool
    @State private var keptIsTurned: Bool
    /// Where the slider stands while it is being moved, so it follows the pointer without waiting for the
    /// owner.
    @State private var heldValue: Double?

    /// - Parameters:
    ///   - knob: Which of the four it is.
    ///   - value: From 0 (0 %) to 1 (100 %). For clips that differ, where the knob should stand (their average).
    ///   - isMixed: Shows "Mixed" in place of the number: the selected clips differ.
    ///   - showsValue: False leaves the number out. For a clip on a track without a Sound, where the knob
    ///     has no value to show.
    ///   - ofClip: Set for a clip's knob, nil for a track's. See `OfClip`.
    ///   - onChange: Told where the slider stands, from 0 to 1. `isFinal` is false while it is still being
    ///     moved and true once it is let go. Nil lets the slider change what it shows by itself.
    ///   - onReset: Told that the mark was pressed. Nil lets the slider go back to the track's value by itself.
    public init(
        knob: SoundKnob,
        value: Double,
        width: SliderWidth = .normal,
        isMixed: Bool = false,
        showsValue: Bool = true,
        ofClip: OfClip? = nil,
        onChange: (@MainActor (_ value: Double, _ isFinal: Bool) -> Void)? = nil,
        onReset: (@MainActor () -> Void)? = nil
    ) {
        let value = min(max(value, 0), 1)
        self.knob = knob
        self.width = width
        self.showsValue = showsValue
        given = (value, isMixed, ofClip)
        self.onChange = onChange
        self.onReset = onReset
        _keptValue = State(initialValue: value)
        _keptIsMixed = State(initialValue: isMixed)
        _keptIsTurned = State(initialValue: ofClip?.isTurned ?? false)
    }

    private var hasOwner: Bool { onChange != nil }

    private var shownValue: Double {
        hasOwner ? heldValue ?? given.value : keptValue
    }

    private var shownIsMixed: Bool {
        hasOwner ? heldValue == nil && given.isMixed : keptIsMixed
    }

    private var shownIsTurned: Bool {
        hasOwner ? heldValue != nil || given.ofClip?.isTurned ?? false : keptIsTurned
    }

    private var value: Binding<Double> {
        Binding(
            get: { shownValue },
            set: { value in
                if let onChange {
                    heldValue = value
                    onChange(value, false)
                } else {
                    // Moving the slider gives every selected clip the value it shows, as its own.
                    keptValue = value
                    keptIsMixed = false
                    keptIsTurned = true
                }
            }
        )
    }

    /// The slider was let go: the value it stands at is the one that counts.
    private func settle() {
        guard let final = heldValue else { return }
        onChange?(final, true)
        heldValue = nil
    }

    /// The mark was pressed: the clip follows its track with this knob again.
    private func reset() {
        if let onReset {
            onReset()
        } else if let trackValue = given.ofClip?.trackValue {
            keptValue = min(max(trackValue, 0), 1)
            keptIsMixed = false
            keptIsTurned = false
        }
    }

    private var valueText: String {
        if shownIsMixed { return "Mixed" }
        return showsValue || shownIsTurned ? "\(Int((shownValue * 100).rounded())) %" : ""
    }

    public var body: some View {
        ValueSlider(
            name: knob.title,
            value: value,
            range: 0...1,
            width: width.points,
            valueText: valueText,
            widestValueText: "100 %",
            mark: given.ofClip == nil ? nil : "arrow.uturn.backward",
            markName: "Turned for this clip only. Click to follow the track again.",
            showsMark: shownIsTurned,
            onMarkPressed: reset,
            onHoldChange: { isHeld in
                if !isHeld { settle() }
            },
            help: knob.help
        )
        .onDisappear { settle() }
    }
}

/// The small ring that fills while finished sounds are being made, after a Sound was chosen or a knob was
/// turned. It stands in the line of the heading "Sound" and is gone when the sounds are ready. It is the
/// ring "Correction" has.
public struct SoundProgressRing: View {
    private let progress: Double

    /// - Parameter progress: How far the making has come, from 0 to 1.
    public init(progress: Double) {
        self.progress = progress
    }

    public var body: some View {
        MakingRing(progress: progress, name: "Making the sound of the voice again with the new settings")
    }
}

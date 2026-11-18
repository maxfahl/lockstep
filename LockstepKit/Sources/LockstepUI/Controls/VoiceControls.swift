import LockstepCore
import SwiftUI

// The section "Voice" of a track in the panel on the right: a switch in the heading's line, the box that
// opens the menu of presets, the two knobs Depth and Pitch, with the Natural quality a switch "Natural", and
// one quiet line with a small ring while voices are made or when something is in the way.
//
// What it shows of a track is the track's Voice itself (`TrackVoice`, on `TrackRow.voice`) and how far its
// voices have come (`VoiceState`, on `TrackRow.voiceState`). What it tells its owner is `VoiceActions`.
//
// Each control explains itself in one sentence when the pointer rests on it.

/// How far the voices of a track's clips have come, which the section "Voice" says in its quiet line.
public enum VoiceState: Sendable, Equatable {
    /// Every voice the track needs is made, or the track needs none. Nothing is said.
    case ready
    /// Voices are being made: how many of the track's clips have theirs, of how many.
    case making(done: Int, of: Int)
    /// The voice of this many clips could not be made. They are heard as before, and the line has a button
    /// that tries again.
    case failed(clips: Int)
    /// Only with Natural: every clip has its Fast voice and is heard with it, and the natural ones are being
    /// made: how many clips have theirs, of how many.
    case makingNatural(done: Int, of: Int)
    /// Only with Natural: Natural is on and the voice engine is not installed.
    case noEngine
    /// Only with Natural: Natural is on and Max has not chosen a sample of his voice.
    case noSample

    /// How far the making has come, from 0 to 1, for the ring. Nil while nothing is being made.
    var progress: Double? {
        switch self {
        case .making(let done, let all), .makingNatural(let done, let all):
            Double(done) / Double(max(all, 1))
        case .ready, .failed, .noEngine, .noSample:
            nil
        }
    }

    /// What the quiet line says. Nil says nothing.
    var line: String? {
        switch self {
        case .ready:
            nil
        case .making(let done, let all):
            "Making the voice: \(done) of \(all) \(all == 1 ? "clip" : "clips")"
        case .failed(let clips):
            "The voice could not be made for \(clips) \(clips == 1 ? "clip" : "clips")."
        case .makingNatural(let done, let all):
            "Making the natural voice: \(done) of \(all) \(all == 1 ? "clip" : "clips")"
        case .noEngine:
            "Install the voice engine in Settings > Voices to use Natural."
        case .noSample:
            "Natural needs a sample of your voice. Choose one in Settings > Voices."
        }
    }

    /// Whether the state is about the Natural quality, and so is shown only where Natural is.
    var isAboutNatural: Bool {
        switch self {
        case .makingNatural, .noEngine, .noSample: true
        case .ready, .making, .failed: false
        }
    }
}

/// One of the two knobs of a Voice.
public enum VoiceKnob: CaseIterable, Sendable {
    /// How deep the voice sounds, in whole percent from -15 to +15. Positive is deeper.
    case depth
    /// How high the voice is, in semitones from -4 to +4, in half steps.
    case pitch

    /// The knob's name in the panel.
    public var title: String {
        switch self {
        case .depth: "Depth"
        case .pitch: "Pitch"
        }
    }

    /// What the knob does, in one sentence, for its help tag.
    var help: String {
        switch self {
        case .depth:
            "How deep the voice sounds: to the right darker, as from a bigger chest, to the left lighter. "
                + "How high it is stays the same. The voice is made when you let go."
        case .pitch:
            "How high the voice is, in semitones (st): to the left lower, to the right higher. "
                + "The voice is made when you let go."
        }
    }

    /// How far the knob goes.
    var range: ClosedRange<Double> {
        switch self {
        case .depth: Double(VoiceKnobs.depthRange.lowerBound)...Double(VoiceKnobs.depthRange.upperBound)
        case .pitch: VoiceKnobs.pitchRange
        }
    }

    /// The step of the knob nearest to a value.
    func snapped(_ value: Double) -> Double {
        switch self {
        case .depth: Double(VoiceKnobs.depth(clamped: value))
        case .pitch: VoiceKnobs.pitch(clamped: value)
        }
    }

    /// Where this knob stands in a pair of knobs.
    public func value(in knobs: VoiceKnobs) -> Double {
        switch self {
        case .depth: Double(knobs.depth)
        case .pitch: knobs.pitch
        }
    }

    /// The pair of knobs with this one moved to a value, which is brought onto a step inside its range.
    public func setting(_ value: Double, in knobs: VoiceKnobs) -> VoiceKnobs {
        var knobs = knobs
        switch self {
        case .depth: knobs.depth = VoiceKnobs.depth(clamped: value)
        case .pitch: knobs.pitch = VoiceKnobs.pitch(clamped: value)
        }
        return knobs
    }

    /// The value as the panel writes it: "+6 %" and "-1.5 st", and the middle without a sign, "0 %" and
    /// "0.0 st". Written with a point on every Mac, as the volumes are.
    public func text(for value: Double) -> String {
        let value = snapped(value)
        let sign = value == 0 ? "" : (value > 0 ? "+" : "-")
        switch self {
        case .depth: return "\(sign)\(Int(abs(value))) %"
        case .pitch: return "\(sign)\(String(format: "%.1f", abs(value))) st"
        }
    }

    /// The widest text a value of either knob can become. Both knobs keep this much room for their value,
    /// so the two sliders stand in one line under each other.
    static let widestText = VoiceKnob.pitch.text(for: VoiceKnobs.pitchRange.lowerBound)
}

/// What the section "Voice" of the panel on the right, and the submenu "Voice" of a track's right-click
/// menu, tell their owner. The owner then changes the track, so the window shows the new values:
///
///     var voice = VoiceActions()
///     voice.switched = { trackID, isOn in model.setVoice(of: trackID, on: isOn) }
///     voice.menuCommand = { command, trackID in model.voiceMenu(command, on: trackID) }
///     voice.knobChanged = { trackID, knob, value, isFinal in ... }
///     actions.voice = voice
///
/// Left out as a whole, as in the design lab, the section keeps what it shows itself: the switch dims the
/// rest, a chosen preset moves the knobs, and a moved knob makes the box read "Custom".
public struct VoiceActions {
    /// The switch in the heading's line of the track with this id was switched: what it was switched to.
    /// Switching on a track that never had a Voice gives it one.
    public var switched: (@MainActor (UUID, _ isOn: Bool) -> Void)?

    /// A line was chosen in the Voice menu of the track with this id: in the box in the panel (a preset,
    /// "Save as Preset..." or a preset under "Delete Preset"), or in the submenu "Voice" of the track's
    /// right-click menu (a preset, or "Voice On or Off").
    public var menuCommand: (@MainActor (VoiceMenu.Command, UUID) -> Void)?

    /// A knob of the track with this id was moved: where it stands, in the knob's own unit (percent for
    /// Depth, semitones for Pitch), on a step. `isFinal` is false while the slider is still being moved and
    /// true once it is let go. Nothing is made while a knob is dragged: letting go is the edit. The value
    /// told last may be the one the knob had before: a click that moves nothing is told too.
    public var knobChanged: (@MainActor (UUID, VoiceKnob, _ value: Double, _ isFinal: Bool) -> Void)?

    /// The switch "Natural" of the track with this id was switched: what it was switched to.
    public var naturalSwitched: (@MainActor (UUID, _ isOn: Bool) -> Void)?

    /// "Try Again" was pressed for the track with this id, after voices could not be made.
    public var tryAgainPressed: (@MainActor (UUID) -> Void)?

    /// "Open Settings" was pressed: the owner opens the pane Voices of the settings window.
    public var openSettingsPressed: (@MainActor () -> Void)?

    public init() {}
}

/// The section "Voice" of one track, as tall as it needs and as wide as it is given.
///
/// From the top: the heading "Voice" with the switch at the right of its line, and before the switch a small
/// ring while voices are made. The box that shows the preset's name, or "Custom", and opens the menu of
/// presets (`VoiceMenu`). The knobs Depth and Pitch, each a slider with its value. With `showsNatural`, the
/// switch "Natural". Last, when the state has something to say, one quiet line, with a button under it where
/// there is something to do.
///
/// While the Voice is off, the box, the knobs and "Natural" are dimmed and deaf, and still show the setting
/// the track keeps. A track that never had a Voice shows the switch off, "Custom" and both knobs in the
/// middle. While `isAvailable` is false, as while a take is going, the whole section is dimmed and deaf.
///
///     VoiceSection(trackID: track.id, voice: track.voice, state: track.voiceState, actions: actions.voice)
public struct VoiceSection: View {
    private let trackID: UUID
    private let given: TrackVoice?
    private let state: VoiceState
    private let ownPresets: [VoicePreset]
    private let showsNatural: Bool
    private let isAvailable: Bool
    private let actions: VoiceActions?

    /// What the section shows while it has no owner.
    @State private var kept: TrackVoice?

    /// - Parameters:
    ///   - trackID: The track the section is about, by which everything is reported.
    ///   - voice: The track's Voice. Nil for a track that never had one.
    ///   - state: How far the voices of the track's clips have come.
    ///   - ownPresets: Max's own presets, in the order he saved them.
    ///   - showsNatural: Whether the switch "Natural" and what the state says about Natural are shown.
    ///   - isAvailable: False dims the whole section and makes it deaf, as while a take is going.
    ///   - actions: Who is told. Left out, the section only changes what it shows.
    public init(
        trackID: UUID,
        voice: TrackVoice?,
        state: VoiceState = .ready,
        ownPresets: [VoicePreset] = [],
        showsNatural: Bool = false,
        isAvailable: Bool = true,
        actions: VoiceActions? = nil
    ) {
        self.trackID = trackID
        given = voice
        self.state = state
        self.ownPresets = ownPresets
        self.showsNatural = showsNatural
        self.isAvailable = isAvailable
        self.actions = actions
        _kept = State(initialValue: voice)
    }

    /// The track's Voice as it is shown. Nil for a track that never had one.
    private var shown: TrackVoice? {
        actions == nil ? kept : given
    }

    /// What the controls show: the track's Voice, or for a track that never had one what switching on
    /// starts from, switched off.
    private var voice: TrackVoice {
        shown ?? TrackVoice(isOn: false, knobs: .neutral)
    }

    /// What the state says here: nothing about Natural where Natural is not shown.
    private var shownState: VoiceState {
        state.isAboutNatural && !showsNatural ? .ready : state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            PanelHeading("Voice") {
                if let progress = shownState.progress {
                    MakingRing(progress: progress, name: "Making the voice of this track's clips with the new setting")
                }
                onSwitch
            }
            Group {
                VoiceMenuButton(voice: shown, ownPresets: ownPresets.map(\.name), onCommand: menuChose)
                ForEach(VoiceKnob.allCases, id: \.self) { knob in
                    PanelRow(knob.title) {
                        VoiceKnobSlider(knob: knob, value: knob.value(in: voice.knobs)) { value, isFinal in
                            knobMoved(knob, to: value, isFinal: isFinal)
                        }
                    }
                }
                if showsNatural {
                    LabelledSwitch(
                        title: "Natural",
                        isOn: isNatural,
                        help: "Makes the voice a second time with the voice engine, which can sound more "
                            + "natural and takes longer. You hear the quick voice until the natural one is made."
                    )
                }
            }
            // Dimmed once, also when the whole section is: two dimmings on top of each other would
            // nearly hide the setting the track keeps.
            .disabled(!voice.isOn)
            .opacity(voice.isOn || !isAvailable ? 1 : DesignTokens.Opacity.unavailable)
            if let line = shownState.line {
                PanelQuietLine(line)
                stateButton
            }
        }
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : DesignTokens.Opacity.unavailable)
    }

    // MARK: The switch

    /// The switch of the Voice, at the right of the heading's line. It has no title of its own: the heading
    /// beside it is its name.
    private var onSwitch: some View {
        Toggle("Voice", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(DesignTokens.Colors.accent)
            .fixedSize()
            .help("Every clip on this track is heard, and sent to DaVinci, in your own voice made darker or "
                + "lighter. Off, you hear your own voice, and the knobs are kept.")
            .accessibilityLabel("Voice")
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { voice.isOn },
            set: { isOn in
                if let actions {
                    actions.switched?(trackID, isOn)
                } else {
                    var voice = voice
                    voice.isOn = isOn
                    kept = voice
                }
            }
        )
    }

    private var isNatural: Binding<Bool> {
        Binding(
            get: { voice.natural },
            set: { isOn in
                if let actions {
                    actions.naturalSwitched?(trackID, isOn)
                } else {
                    var voice = voice
                    voice.natural = isOn
                    kept = voice
                }
            }
        )
    }

    // MARK: The menu and the knobs

    /// A line of the box's menu was chosen. Without an owner a preset moves the knobs and names the box,
    /// as it will in the app, and the two commands about Max's own presets do nothing.
    private func menuChose(_ command: VoiceMenu.Command) {
        if let actions {
            actions.menuCommand?(command, trackID)
        } else if case .chosen(let name) = command,
                  let preset = VoicePresets(presets: ownPresets).preset(named: name) {
            var voice = preset.voice
            voice.natural = self.voice.natural
            kept = voice
        }
    }

    /// A knob was moved. Without an owner the knob stays where it was put, and the Voice is no preset's
    /// any more.
    private func knobMoved(_ knob: VoiceKnob, to value: Double, isFinal: Bool) {
        if let actions {
            actions.knobChanged?(trackID, knob, value, isFinal)
        } else {
            var voice = voice
            let knobs = knob.setting(value, in: voice.knobs)
            if knobs != voice.knobs {
                voice.knobs = knobs
                voice.name = TrackVoice.customName
            }
            kept = voice
        }
    }

    // MARK: What there is to do

    /// The button under the quiet line, for a state Max can do something about.
    @ViewBuilder private var stateButton: some View {
        switch shownState {
        case .failed:
            PanelButton(title: "Try Again", help: "Try once more to make the voices that could not be made.") {
                actions?.tryAgainPressed?(trackID)
            }
        case .noEngine, .noSample:
            PanelButton(title: "Open Settings", help: "Open Settings > Voices.") {
                actions?.openSettingsPressed?()
            }
        case .ready, .making, .makingNatural:
            EmptyView()
        }
    }
}

/// The box that shows a track's Voice and opens the menu it is chosen from (`VoiceMenu`): the name of the
/// preset it was chosen as, or "Custom" after a knob was turned, and for a track that never had a Voice. It
/// fills the width it is given.
struct VoiceMenuButton: View {
    /// The track's Voice. Nil for a track that never had one.
    let voice: TrackVoice?
    /// The names of Max's own presets, in the order he saved them.
    let ownPresets: [String]
    /// Told which line of the menu was chosen.
    let onCommand: @MainActor (VoiceMenu.Command) -> Void

    private var name: String {
        voice?.name ?? TrackVoice.customName
    }

    var body: some View {
        Menu {
            VoiceMenu(voice: voice, ownPresets: ownPresets, onCommand: onCommand)
        } label: {
            MenuBoxLabel(text: name)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("The presets of a Voice: where its two knobs stand. Save your own with Save as Preset.")
        .accessibilityLabel("Voice preset")
        .accessibilityValue(name)
    }
}

/// One knob of a Voice: a slider that goes in the knob's steps, with its value after it, such as "+6 %" or
/// "-1.5 st". The panel writes the knob's name before it, in the same line.
///
/// It follows the pointer by itself while it is moved and tells `onChange` every step it comes to, with
/// `isFinal` false, and once more with `isFinal` true when it is let go. A double-click puts it in the
/// middle, where the knob changes nothing, as a double-click puts a volume at 0.0 dB.
struct VoiceKnobSlider: View {
    let knob: VoiceKnob
    /// Where the knob stands, in its own unit.
    let value: Double
    let onChange: @MainActor (_ value: Double, _ isFinal: Bool) -> Void

    /// Where the slider stands while it is being moved.
    @State private var heldValue: Double?

    private var shownValue: Double {
        heldValue ?? knob.snapped(value)
    }

    private var binding: Binding<Double> {
        Binding(
            get: { shownValue },
            set: { moved in
                // The slider itself moves without steps. Only a new step is a move of the knob.
                let step = knob.snapped(moved)
                guard step != shownValue || heldValue == nil else { return }
                heldValue = step
                onChange(step, false)
            }
        )
    }

    /// The slider was let go: the step it stands at is the one that counts.
    private func settle() {
        guard let final = heldValue else { return }
        onChange(final, true)
        heldValue = nil
    }

    var body: some View {
        ValueSlider(
            name: knob.title,
            value: binding,
            range: knob.range,
            width: DesignTokens.Sizes.sliderWidthCompact,
            valueText: knob.text(for: shownValue),
            widestValueText: VoiceKnob.widestText,
            onHoldChange: { isHeld in
                if !isHeld { settle() }
            },
            help: knob.help
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                heldValue = nil
                onChange(0, true)
            }
        )
        .onDisappear { settle() }
    }
}

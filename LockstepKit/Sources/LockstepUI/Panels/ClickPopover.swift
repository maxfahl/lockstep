import SwiftUI

// The popover that opens from the small arrow beside the click toggle: the
// click's sound, its volume, how often it clicks and, for a click on
// sub-beats, whether those are 16ths or triplets. These are changed while
// working and are saved with the project, so they are here and not in the
// settings window.
//
// It can also hold how many bars are counted in before recording. That one is
// kept with the app's settings, not the project, but Max wants it within reach
// while recording rather than in the settings window. The speed a take is
// recorded at is there for the same reason, in the row under it.

/// The five sounds the click can have.
public enum ClickSound: String, CaseIterable, Identifiable, Sendable {
    case woodblock
    case rimshot
    case hiHat
    case cowbell
    case beep

    public var id: String { rawValue }

    /// The name shown in the list.
    public var title: String {
        switch self {
        case .woodblock: "Woodblock"
        case .rimshot: "Rimshot"
        case .hiHat: "Hi-hat"
        case .cowbell: "Cowbell"
        case .beep: "Beep"
        }
    }
}

/// How often the click sounds.
public enum ClickDivision: String, CaseIterable, Identifiable, Sendable {
    case beats
    case halfBeats
    case subBeats

    public var id: String { rawValue }

    /// The word shown in the choice.
    public var title: String {
        switch self {
        case .beats: "Beats"
        case .halfBeats: "Half-beats"
        case .subBeats: "Sub-beats"
        }
    }
}

/// How a beat is divided for a click that sounds on sub-beats. It is the
/// click's own choice: a clip's sub-beats are chosen for the clip, in the
/// panel on the right.
public enum ClickSubBeats: String, CaseIterable, Identifiable, Sendable {
    /// Four clicks to a beat.
    case sixteenths
    /// Six clicks to a beat, the parts a clip in triplets is drawn in.
    case triplets

    public var id: String { rawValue }

    /// The word shown in the choice.
    public var title: String {
        switch self {
        case .sixteenths: "16ths"
        case .triplets: "Triplets"
        }
    }
}

/// How many bars are counted in before recording starts.
public enum CountInBars {
    /// The choices in the order they are shown: 0 is Off.
    public static let choices = [0, 1, 2, 4]

    /// The word shown for a choice: "Off", "1 bar", "2 bars".
    public static func title(_ bars: Int) -> String {
        switch bars {
        case 0: "Off"
        case 1: "1 bar"
        default: "\(bars) bars"
        }
    }
}

/// How fast the song plays while a take is recorded, in percent of its own
/// speed. Below 100 the song is slower at the same pitch, so a fast passage
/// can be rapped cleanly, and the take is sped up to full tempo afterwards.
public enum RecordSpeed {
    /// The choices in the order they are shown: 100 is the song as it is.
    public static let choices = [100, 90, 85]

    /// The words shown for a choice: "100 %", "85 %".
    public static func title(_ percent: Int) -> String {
        "\(percent) %"
    }

    /// The percent to mark beside the Record button, or nil when nothing is
    /// marked: no speed is known, or the take is recorded at full speed.
    public static func marked(_ percent: Int?) -> Int? {
        guard let percent, percent < 100 else { return nil }
        return percent
    }
}

/// What the click popover shows. The defaults are the ones a new song gets.
public struct ClickSettings: Sendable, Equatable {
    public var sound: ClickSound
    /// From 0 (silent) to 1 (full).
    public var volume: Double
    public var division: ClickDivision
    /// Whether a click on sub-beats sounds on 16ths or on triplets. It is
    /// kept while the click is on beats or half-beats, where it is not heard.
    public var subBeats: ClickSubBeats
    /// How many bars are counted in before recording: 0 (Off), 1, 2 or 4.
    /// Nil leaves the Count-in row out of the popover.
    public var countInBars: Int?
    /// The speed a take is recorded at, in percent: 100, 90 or 85. Nil
    /// leaves the Record speed row out of the popover.
    public var recordSpeedPercent: Int?

    public init(
        sound: ClickSound = .woodblock,
        volume: Double = 0.7,
        division: ClickDivision = .beats,
        subBeats: ClickSubBeats = .sixteenths,
        countInBars: Int? = nil,
        recordSpeedPercent: Int? = nil
    ) {
        self.sound = sound
        self.volume = min(max(volume, 0), 1)
        self.division = division
        self.subBeats = subBeats
        self.countInBars = countInBars
        self.recordSpeedPercent = recordSpeedPercent
    }
}

/// What the click control and its popover tell their owner when they are
/// used. The design lab hands in none: there the control only changes what it
/// shows. The real app fills these in, and the control then shows what it is
/// given (`isOn`, `settings`) and changes nothing by itself:
///
///     var click = ClickActions()
///     click.toggled = { model.perform(.clickOnOff) }
///     click.soundChosen = { sound in model.chooseClickSound(sound) }
public struct ClickActions {
    /// The metronome button was pressed.
    public var toggled: (@MainActor () -> Void)?
    /// A sound was pressed in the list, also when it was the chosen one.
    public var soundChosen: (@MainActor (ClickSound) -> Void)?
    /// The volume slider stands at this value, from 0 to 1. `isFinal` is
    /// false while the slider is still being moved and true once it is let
    /// go, so one drag can be one change.
    public var volumeChanged: (@MainActor (_ volume: Double, _ isFinal: Bool) -> Void)?
    /// Beats, Half-beats or Sub-beats was chosen.
    public var divisionChosen: (@MainActor (ClickDivision) -> Void)?
    /// 16ths or Triplets was chosen for a click on sub-beats.
    public var subBeatsChosen: (@MainActor (ClickSubBeats) -> Void)?
    /// A count-in was chosen in the Count-in row: 0 (Off), 1, 2 or 4 bars.
    public var countInChosen: (@MainActor (_ bars: Int) -> Void)?
    /// A speed was chosen in the Record speed row: 100, 90 or 85 percent.
    public var recordSpeedChosen: (@MainActor (_ percent: Int) -> Void)?

    public init() {}
}

/// The content of the click popover. Show it with the system's `popover`,
/// which gives it its glass and its arrow:
///
///     .popover(isPresented: $showsSettings, arrowEdge: .top) {
///         ClickPopover(settings: settings)
///     }
///
/// From the top: the five sounds as a list with a tick at the chosen one, the
/// volume, how often it clicks, with 16ths or Triplets under it for a click
/// on sub-beats, and, when `settings.countInBars` is given, how many bars are
/// counted in before recording, and, when `settings.recordSpeedPercent` is
/// given, the speed a take is recorded at. 16ths or Triplets is dimmed while the click is
/// on beats or half-beats, where it would change nothing that is heard. Without `actions`, choosing changes only
/// what is shown. With them, the popover shows `settings` as they are handed
/// in and reports every choice (`ClickActions`).
public struct ClickPopover: View {
    /// What is shown when nobody is told of a choice: the popover keeps it.
    @State private var settings: ClickSettings
    /// What the owner says the settings are.
    private let given: ClickSettings
    private let actions: ClickActions?
    /// Where the volume slider stands while it is being moved. Kept here so
    /// the slider follows the pointer without waiting for the owner.
    @State private var heldVolume: Double?

    /// - Parameters:
    ///   - settings: What the popover shows.
    ///   - actions: Told when a sound, a volume or a division is chosen. Nil
    ///     lets the popover change what it shows by itself.
    public init(settings: ClickSettings = ClickSettings(), actions: ClickActions? = nil) {
        _settings = State(initialValue: settings)
        self.given = settings
        self.actions = actions
    }

    /// The settings to draw: the owner's when it is told of choices, the
    /// popover's own otherwise.
    private var shown: ClickSettings {
        var shown = actions == nil ? settings : given
        if let heldVolume {
            shown.volume = heldVolume
        }
        return shown
    }

    private var volume: Binding<Double> {
        guard let actions else { return $settings.volume }
        return Binding(
            get: { shown.volume },
            set: { value in
                heldVolume = value
                actions.volumeChanged?(value, false)
            }
        )
    }

    private var division: Binding<ClickDivision> {
        guard let actions else { return $settings.division }
        return Binding(
            get: { given.division },
            set: { actions.divisionChosen?($0) }
        )
    }

    private var subBeats: Binding<ClickSubBeats> {
        guard let actions else { return $settings.subBeats }
        return Binding(
            get: { given.subBeats },
            set: { actions.subBeatsChosen?($0) }
        )
    }

    private var countIn: Binding<Int> {
        guard let actions else {
            return Binding(
                get: { settings.countInBars ?? 0 },
                set: { settings.countInBars = $0 }
            )
        }
        return Binding(
            get: { given.countInBars ?? 0 },
            set: { actions.countInChosen?($0) }
        )
    }

    private var recordSpeed: Binding<Int> {
        guard let actions else {
            return Binding(
                get: { settings.recordSpeedPercent ?? 100 },
                set: { settings.recordSpeedPercent = $0 }
            )
        }
        return Binding(
            get: { given.recordSpeedPercent ?? 100 },
            set: { actions.recordSpeedChosen?($0) }
        )
    }

    /// The slider was let go, or the popover closed with the slider moved:
    /// the value it stands at is the one that counts.
    private func settleVolume() {
        guard let final = heldVolume else { return }
        heldVolume = nil
        actions?.volumeChanged?(final, true)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sectionGap) {
            part("Sound") {
                VStack(spacing: DesignTokens.Spacing.tight) {
                    ForEach(ClickSound.allCases) { sound in
                        soundRow(sound)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Click sound")
            }
            part("Volume") {
                ValueSlider(
                    name: "Click volume",
                    value: volume,
                    range: 0...1,
                    width: DesignTokens.Sizes.sliderWidth,
                    valueText: "\(Int((shown.volume * 100).rounded())) %",
                    widestValueText: "100 %",
                    onHoldChange: { isHeld in
                        if !isHeld { settleVolume() }
                    }
                )
            }
            part("Click on") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                    SegmentedChoice(
                        name: "How often it clicks",
                        options: ClickDivision.allCases.map { (value: $0, title: $0.title) },
                        selection: division
                    )
                    let clicksOnSubBeats = shown.division == .subBeats
                    SegmentedChoice(
                        name: "Sub-beats of the click",
                        options: ClickSubBeats.allCases.map { (value: $0, title: $0.title) },
                        selection: subBeats,
                        help: "How many times a click on sub-beats sounds in each beat: four (16ths) or "
                            + "six (Triplets)."
                    )
                    .disabled(!clicksOnSubBeats)
                    .opacity(clicksOnSubBeats ? 1 : DesignTokens.Opacity.unavailable)
                }
            }
            if shown.countInBars != nil {
                part("Count-in") {
                    SegmentedChoice(
                        name: "Bars counted in before recording",
                        options: CountInBars.choices.map { (value: $0, title: CountInBars.title($0)) },
                        selection: countIn
                    )
                }
            }
            if shown.recordSpeedPercent != nil {
                part("Record speed") {
                    SegmentedChoice(
                        name: "Speed of the song while recording",
                        options: RecordSpeed.choices.map { (value: $0, title: RecordSpeed.title($0)) },
                        selection: recordSpeed,
                        help: "How fast the song plays while you record. Below 100 % it is slower at "
                            + "the same pitch, and the take is sped up to full tempo afterwards."
                    )
                }
            }
        }
        .padding(DesignTokens.Spacing.panelPadding)
        .frame(width: DesignTokens.Sizes.clickPopoverWidth, alignment: .leading)
        .lockstepLook()
        .onDisappear { settleVolume() }
    }

    /// One part of the popover: a small heading and the control under it.
    private func part(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.controlGap) {
            Text(title)
                .font(DesignTokens.Fonts.panelTitle)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            control()
        }
    }

    /// One sound in the list. The chosen one has a lighter backing and a tick.
    private func soundRow(_ sound: ClickSound) -> some View {
        let isChosen = sound == shown.sound
        return Button {
            if let actions {
                actions.soundChosen?(sound)
            } else {
                settings.sound = sound
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.medium) {
                Text(sound.title)
                    .font(DesignTokens.Fonts.label)
                    .foregroundStyle(
                        isChosen ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary
                    )
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(DesignTokens.Fonts.symbolSmall)
                        .foregroundStyle(DesignTokens.Colors.accent)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.medium)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.Sizes.smallButton, alignment: .leading)
            .background(
                isChosen ? DesignTokens.Colors.controlFillOn : Color.clear,
                in: DesignTokens.Shapes.control
            )
            .contentShape(DesignTokens.Shapes.control)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

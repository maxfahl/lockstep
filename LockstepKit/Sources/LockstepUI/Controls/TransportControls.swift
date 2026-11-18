import SwiftUI

/// One of the three transport buttons.
public enum TransportButtonKind: String, CaseIterable, Identifiable, Sendable {
    case play
    case record
    case loop

    public var id: String { rawValue }

    /// The name shown as the help tag.
    public var name: String {
        switch self {
        case .play: "Play"
        case .record: "Record"
        case .loop: "Loop"
        }
    }
}

/// One transport button: Play, Record or Loop. `isOn` shows the button as
/// active: Play becomes a pause symbol, Record fills, Loop lights up in the
/// accent colour. Pressing the button calls `action`; without one it does
/// nothing.
public struct TransportButton: View {
    private let kind: TransportButtonKind
    private let isOn: Bool
    private let action: () -> Void

    public init(_ kind: TransportButtonKind, isOn: Bool = false, action: @escaping () -> Void = {}) {
        self.kind = kind
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        SymbolButton(
            symbol: symbol,
            name: kind.name,
            font: DesignTokens.Fonts.symbolLarge,
            width: DesignTokens.Sizes.transportButton,
            height: DesignTokens.Sizes.transportButton,
            color: color,
            showsOnFill: kind == .loop && isOn,
            action: action
        )
    }

    private var symbol: String {
        switch kind {
        case .play: isOn ? "pause.fill" : "play.fill"
        case .record: isOn ? "record.circle.fill" : "record.circle"
        case .loop: "repeat"
        }
    }

    private var color: Color {
        switch kind {
        case .play: DesignTokens.Colors.textPrimary
        case .record: DesignTokens.Colors.record
        case .loop: isOn ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary
        }
    }
}

/// The small mark beside the Record button while takes are recorded slower
/// than the song: the percent of the song's speed, "85 %", in the record red,
/// because it says something about what Record will do. It is not shown at
/// full speed, so it has no state of its own.
public struct RecordSpeedMark: View {
    private let percent: Int

    /// - Parameter percent: The speed takes are recorded at, such as 85.
    public init(percent: Int) {
        self.percent = percent
    }

    public var body: some View {
        Text(RecordSpeed.title(percent))
            .font(DesignTokens.Fonts.readoutUnit)
            .foregroundStyle(DesignTokens.Colors.record)
            .lineLimit(1)
            .fixedSize()
            .help("Takes are recorded at \(percent) % of the song's speed. Change it in the click settings.")
            .accessibilityLabel("Record speed")
            .accessibilityValue("\(percent) percent")
    }
}

/// The transport buttons in a row: Play, Record, Loop. The three values say
/// which of them are shown as active. `kinds` leaves buttons out: the real app
/// shows Record and Loop only once recording and looping work. `onPress` is
/// told which button was pressed; without it the buttons do nothing.
/// `recordSpeedPercent` below 100 puts the percent right after the Record
/// button (`RecordSpeedMark`); nil or 100 shows the row as it always was.
///
/// There is no button for going back to the start and none for starting a take
/// over: Return goes back, and Record pressed during a take starts it over.
public struct TransportControls: View {
    private let isPlaying: Bool
    private let isRecording: Bool
    private let isLooping: Bool
    private let kinds: [TransportButtonKind]
    private let recordSpeedPercent: Int?
    private let onPress: ((TransportButtonKind) -> Void)?

    public init(
        isPlaying: Bool = false,
        isRecording: Bool = false,
        isLooping: Bool = false,
        kinds: [TransportButtonKind] = TransportButtonKind.allCases,
        recordSpeedPercent: Int? = nil,
        onPress: ((TransportButtonKind) -> Void)? = nil
    ) {
        self.isPlaying = isPlaying
        self.isRecording = isRecording
        self.isLooping = isLooping
        self.kinds = kinds
        self.recordSpeedPercent = recordSpeedPercent
        self.onPress = onPress
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Spacing.controlGap) {
            ForEach(kinds) { kind in
                if kind == .record, let percent = RecordSpeed.marked(recordSpeedPercent) {
                    // The mark stands closer to Record than the buttons
                    // stand to each other, so it is read as Record's own.
                    HStack(spacing: DesignTokens.Spacing.tight) {
                        TransportButton(kind, isOn: isOn(kind)) { onPress?(kind) }
                        RecordSpeedMark(percent: percent)
                    }
                } else {
                    TransportButton(kind, isOn: isOn(kind)) { onPress?(kind) }
                }
            }
        }
    }

    private func isOn(_ kind: TransportButtonKind) -> Bool {
        switch kind {
        case .play: isPlaying
        case .record: isRecording
        case .loop: isLooping
        }
    }
}

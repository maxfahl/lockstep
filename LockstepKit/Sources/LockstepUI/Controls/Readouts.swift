import LockstepCore
import Observation
import SwiftUI

/// The two sizes of a readout. Layout C uses the large one.
public enum ReadoutSize: Sendable {
    case normal
    case large
}

/// A number with an optional caption before it and an optional unit after it,
/// such as "91.4 BPM". The other readouts in this file are built from it. Use
/// it directly only for a readout that has no view of its own.
public struct Readout: View {
    private let value: String
    private let caption: String?
    private let unit: String?
    private let size: ReadoutSize
    private let isDimmed: Bool
    private let name: String

    /// - Parameters:
    ///   - value: The text of the number, ready to show.
    ///   - caption: Small text before the number.
    ///   - unit: Small text after the number.
    ///   - isDimmed: Shows the number in the secondary tone, for a value that is not known.
    ///   - name: The help tag.
    public init(
        _ value: String,
        caption: String? = nil,
        unit: String? = nil,
        size: ReadoutSize = .normal,
        isDimmed: Bool = false,
        name: String
    ) {
        self.value = value
        self.caption = caption
        self.unit = unit
        self.size = size
        self.isDimmed = isDimmed
        self.name = name
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.small) {
            if let caption {
                Text(caption)
                    .font(unitFont)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            Text(value)
                .font(size == .large ? DesignTokens.Fonts.readoutLarge : DesignTokens.Fonts.readout)
                .foregroundStyle(
                    isDimmed ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textPrimary
                )
            if let unit {
                Text(unit)
                    .font(unitFont)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue([value, unit].compactMap { $0 }.joined(separator: " "))
    }

    private var unitFont: Font {
        size == .large ? DesignTokens.Fonts.readoutUnitLarge : DesignTokens.Fonts.readoutUnit
    }
}

/// The time at the playhead, such as "0:20".
public struct TimeReadout: View {
    private let text: String
    private let size: ReadoutSize

    public init(_ text: String, size: ReadoutSize = .normal) {
        self.text = text
        self.size = size
    }

    public var body: some View {
        Readout(text, size: size, name: "Time")
    }

    /// A place in the song as the readout writes it: minutes and seconds,
    /// such as "0:20" for 20.7 seconds. The second shown is the one that has begun.
    public static func text(forSeconds seconds: Double) -> String {
        let whole = seconds.isFinite ? Int(max(seconds, 0)) : 0
        let remainder = whole % 60
        return remainder < 10 ? "\(whole / 60):0\(remainder)" : "\(whole / 60):\(remainder)"
    }

    /// A time before the song starts as the readout writes it, while the click counts in
    /// before the song: a minus sign and the seconds that are left, such as "−0:02" with
    /// 1.3 seconds to go. The second shown is the one that has begun, as in
    /// `text(forSeconds:)`, so the readout reaches "0:00" as the song starts.
    public static func text(forSecondsBeforeSong seconds: Double) -> String {
        let left = seconds.isFinite ? max(seconds, 0) : 0
        return left > 0 ? "−" + text(forSeconds: left.rounded(.up)) : text(forSeconds: 0)
    }
}

/// The time readout when it follows the playhead by itself: it shows where
/// `playhead` is, and it is the only view of the bar that is worked out again
/// while the song plays. It looks exactly like `TimeReadout`. The time is counted
/// from the timeline's 00:00 (`PlayheadPosition.place`), which lies inside the song
/// when its beginning is cut away. While a count-in is played before the start of
/// the song (`PlayheadPosition.secondsBeforeSong`), it shows the time the count-in
/// has reached, and before 00:00 the time left until then, with a minus sign.
public struct PlayheadTimeReadout: View {
    /// How far below zero a time may lie and still be shown as 0:00: less than a sample.
    private static let zeroMargin = 0.000_01

    private let playhead: PlayheadPosition
    private let size: ReadoutSize

    public init(playhead: PlayheadPosition, size: ReadoutSize = .normal) {
        self.playhead = playhead
        self.size = size
    }

    public var body: some View {
        let shown = playhead.place.timelineSeconds(forSong: playhead.seconds - playhead.secondsBeforeSong)
        TimeReadout(
            // A hair below zero is 00:00 itself, not a second before it.
            shown < -Self.zeroMargin
                ? TimeReadout.text(forSecondsBeforeSong: -shown)
                : TimeReadout.text(forSeconds: max(shown, 0)),
            size: size
        )
    }
}

/// The tempo at the playhead, such as "91.4 BPM". Pass the number only ("91.4").
public struct TempoReadout: View {
    private let text: String
    private let size: ReadoutSize

    public init(_ text: String, size: ReadoutSize = .normal) {
        self.text = text
        self.size = size
    }

    public var body: some View {
        Readout(text, unit: "BPM", size: size, name: "Tempo")
    }
}

/// The tempo at the playhead, for a tempo readout that changes while the song
/// plays. Whoever owns playback changes `text`, a few times a second at most,
/// and `PlayheadTempoReadout` shows it.
///
/// Only that readout reads `text`. Do not read it in a view that holds the
/// bar or the timeline: that view would then be worked out again with every
/// change of the tempo.
@MainActor
@Observable
public final class TempoReading {
    /// The number only, ready to show, such as "91.4", or a dash where the
    /// song has no beats. Empty shows no readout at all, as before the beats
    /// are found.
    public var text: String

    public init(text: String = "") {
        self.text = text
    }
}

/// The tempo readout when it follows the playhead by itself: it shows what
/// `reading` says, and it is the only view of the bar that is worked out
/// again when the tempo changes. It looks exactly like `TempoReadout`, and
/// it is not there at all while the reading is empty.
public struct PlayheadTempoReadout: View {
    private let reading: TempoReading
    private let size: ReadoutSize

    public init(reading: TempoReading, size: ReadoutSize = .normal) {
        self.reading = reading
        self.size = size
    }

    public var body: some View {
        if !reading.text.isEmpty {
            TempoReadout(reading.text, size: size)
        }
    }
}

/// The measured delay of the audio equipment, such as "12 ms". Without a
/// value it says "Not calibrated".
///
/// With `warns`, a missing value is shown as a warning: a warning triangle
/// stands before the words, and the words are as bright as a number. The
/// warning has no colour of its own, because colour is kept for timing.
public struct DelayReadout: View {
    private let milliseconds: Int?
    private let size: ReadoutSize
    private let warns: Bool

    /// - Parameters:
    ///   - milliseconds: The delay, or `nil` to show "Not calibrated".
    ///   - warns: Shows "Not calibrated" as a warning. It changes nothing
    ///     when there is a delay.
    public init(milliseconds: Int?, size: ReadoutSize = .normal, warns: Bool = false) {
        self.milliseconds = milliseconds
        self.size = size
        self.warns = warns
    }

    public var body: some View {
        if let milliseconds {
            Readout("\(milliseconds)", unit: "ms", size: size, name: "Delay")
        } else if warns {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(size == .large ? DesignTokens.Fonts.symbolLarge : DesignTokens.Fonts.symbolSmall)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .accessibilityHidden(true)
                if size == .large {
                    Readout("–", unit: "Not calibrated", size: size, name: "Delay")
                } else {
                    Readout("Not calibrated", size: size, name: "Delay")
                }
            }
            .help("The delay of this microphone and these headphones has not been measured, so recordings may land late. Measure it with Transport > Calibrate Delay...")
        } else if size == .large {
            // The words would be far too wide at the large size, so a dash
            // takes the number's place and the words go where the unit is.
            Readout("–", unit: "Not calibrated", size: size, isDimmed: true, name: "Delay")
        } else {
            Readout("Not calibrated", size: size, isDimmed: true, name: "Delay")
        }
    }
}

/// Where the selected clip starts on the DaVinci Resolve timeline, as a
/// timecode such as "01:00:20:12", with the caption "Resolve start" before it.
public struct ResolveStartReadout: View {
    private let timecode: String
    private let size: ReadoutSize

    public init(_ timecode: String, size: ReadoutSize = .normal) {
        self.timecode = timecode
        self.size = size
    }

    public var body: some View {
        Readout(timecode, caption: "Resolve start", size: size, name: "Resolve start time")
    }
}

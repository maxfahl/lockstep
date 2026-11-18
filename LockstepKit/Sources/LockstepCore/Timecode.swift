import Foundation

/// The frame rates a Resolve timeline can have in Lockstep.
///
/// At 48 kHz each of them is a whole number of samples per frame, so every
/// frame boundary falls exactly on a sample. 29.97 and 59.94 are left out
/// because their drop-frame timecode adds risk for no benefit.
public enum ResolveFrameRate: String, Codable, CaseIterable, Sendable {
    case fps23_976 = "23.976"
    case fps24 = "24"
    case fps25 = "25"
    case fps30 = "30"
    case fps50 = "50"
    case fps60 = "60"

    /// How many samples at 48 kHz one frame lasts.
    public var samplesPerFrame: Int {
        switch self {
        case .fps23_976: 2002
        case .fps24: 2000
        case .fps25: 1920
        case .fps30: 1600
        case .fps50: 960
        case .fps60: 800
        }
    }

    /// How many frames the timecode counts to one second. At 23.976 it counts
    /// 24, without drop-frame, as Resolve does.
    public var timecodeFramesPerSecond: Int {
        switch self {
        case .fps23_976: 24
        case .fps24: 24
        case .fps25: 25
        case .fps30: 30
        case .fps50: 50
        case .fps60: 60
        }
    }

    /// The rate as it is written for Max, for example "23.976" or "25".
    public var label: String { rawValue }
}

/// A Resolve timecode, hours, minutes, seconds and frames, written HH:MM:SS:FF.
///
/// It is saved as that text, so a project file stays readable.
public struct Timecode: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    /// The timecode that lies a number of frames after 00:00:00:00, counted at
    /// a frame rate. It wraps at 24 hours, as a timecode does.
    public init(frameCount: Int, frameRate: ResolveFrameRate) {
        let perSecond = frameRate.timecodeFramesPerSecond
        let perDay = 24 * 60 * 60 * perSecond
        let count = ((frameCount % perDay) + perDay) % perDay
        let totalSeconds = count / perSecond
        self.init(
            hours: totalSeconds / 3600,
            minutes: totalSeconds / 60 % 60,
            seconds: totalSeconds % 60,
            frames: count % perSecond
        )
    }

    /// How many frames this timecode lies after 00:00:00:00 at a frame rate.
    public func frameCount(at frameRate: ResolveFrameRate) -> Int {
        ((hours * 60 + minutes) * 60 + seconds) * frameRate.timecodeFramesPerSecond + frames
    }

    /// This timecode moved on by a number of frames.
    public func adding(frames count: Int, at frameRate: ResolveFrameRate) -> Timecode {
        Timecode(frameCount: frameCount(at: frameRate) + count, frameRate: frameRate)
    }

    /// The form Resolve shows: "01:00:00:00".
    public var text: String { joined(by: ":") }

    /// The form used in a file name, where a colon is not allowed: "01.00.00.00".
    public var fileNameText: String { joined(by: ".") }

    public var description: String { text }

    private func joined(by separator: String) -> String {
        [hours, minutes, seconds, frames].map(Self.twoDigits).joined(separator: separator)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// Reads a timecode Max typed, "HH:MM:SS:FF". Nil when it is not one:
    /// anything but four groups of one or two digits, hours from 24 on,
    /// minutes or seconds from 60 on, or frames from the frame rate on.
    public static func parse(_ text: String, frameRate: ResolveFrameRate) -> Timecode? {
        guard let timecode = parseParts(text), timecode.frames < frameRate.timecodeFramesPerSecond else {
            return nil
        }
        return timecode
    }

    /// The four groups of a timecode, checked for everything but the frames,
    /// which need a frame rate.
    private static func parseParts(_ text: String) -> Timecode? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard (1...2).contains(part.count), part.allSatisfy(\.isASCIIDigit), let value = Int(part) else {
                return nil
            }
            values.append(value)
        }
        guard values[0] < 24, values[1] < 60, values[2] < 60 else { return nil }
        return Timecode(hours: values[0], minutes: values[1], seconds: values[2], frames: values[3])
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let timecode = Self.parseParts(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a timecode: \(text)")
        }
        self = timecode
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

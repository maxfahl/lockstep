import Foundation

// The song's own volume. Max turns the song down with it when the beat drowns his voice. The number is kept
// in the project (`Project.songGainDb`), and the player multiplies the song by `songGain` while it plays.

extension Project {
    /// The lowest and highest volume the song can have, in dB. The song can only be turned down: its file
    /// is already as loud as it can be without distorting, so there is nothing above 0.
    public static let songGainRange: ClosedRange<Double> = -24...0

    /// A volume for the song brought into `songGainRange`. Something that is no number becomes 0.
    public static func songGain(clamped gainDb: Double) -> Double {
        guard gainDb.isFinite else { return 0 }
        return min(max(gainDb, songGainRange.lowerBound), songGainRange.upperBound)
    }

    /// What the song's samples are multiplied by while it plays: 1 at 0 dB, about 0.5 at -6 dB.
    public var songGain: Float {
        Float(pow(10, songGainDb / 20))
    }
}

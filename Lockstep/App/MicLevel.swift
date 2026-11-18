import Foundation

/// Turns the microphone's peaks into the level the meter in the bar shows.
///
/// The meter jumps up to a loud sound at once and falls back slowly, so a short peak can
/// be seen and the bar does not flicker. Ask it once per display frame while a take is going:
///
///     var level = MicLevel()
///     meter.level = level.follow(peak: recorder.snapshot().peak, at: CACurrentMediaTime())
///
/// A peak is the loudest sample of the latest block from the microphone, where 1 is the
/// loudest a file can hold. The meter is in decibels: the quietest sound it shows is
/// `floorDecibels` below that, and each step to the right is equally much louder to the ear.
struct MicLevel {
    /// How long the meter takes to fall from full to empty, in seconds.
    static let fallSeconds = 0.3
    /// The level in decibels at which the meter is empty. A starting value.
    static let floorDecibels = -48.0
    /// A peak this high means the microphone was too loud: the sound was cut off at the top.
    static let clippingPeak: Float = 0.999

    /// What the meter shows, from 0 (empty) to 1 (full).
    private(set) var level = 0.0
    /// When the level was last worked out, on the clock of `CACurrentMediaTime()`.
    private var lastTime: Double?

    /// The level to show now.
    ///
    /// - Parameters:
    ///   - peak: the microphone's latest peak, from 0 to 1.
    ///   - time: now, on the clock of `CACurrentMediaTime()`.
    mutating func follow(peak: Float, at time: Double) -> Double {
        let heard = Self.meterLevel(forPeak: peak)
        let elapsed = lastTime.map { max(time - $0, 0) } ?? 0
        lastTime = time
        let fallen = level - elapsed / Self.fallSeconds
        level = max(heard, fallen, 0)
        return level
    }

    /// Where a peak stands on the meter, from 0 to 1.
    static func meterLevel(forPeak peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(Double(peak))
        return min(max(1 - decibels / floorDecibels, 0), 1)
    }
}

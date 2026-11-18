import Accelerate
import Foundation
import LockstepCore

/// Finds where each syllable of a recording starts: the moment its vowel arrives, which is
/// what the ear hears as the beat of the syllable. A consonant before the vowel is not it.
///
/// It reads the recording's `VoiceEnvelope` (how loud the voice band is, once per
/// millisecond) and works out nothing about the sound a second time:
///
///     let envelope = VoiceEnvelope.envelope(of: recordingSamples)   // or read from the cache
///     let markers = SyllableDetector.markers(in: envelope)
///     // markers[0].sample is a sample of the recording, markers[0].strength is in decibels
///
/// How a start is found:
/// 1. Everything quieter than the noise floor plus a margin is treated as that level, so
///    a rise that stays down in the noise is no rise at all.
/// 2. The rise is how much the loudness, in decibels, climbs over 15 ms. Decibels make a
///    quiet syllable count like a loud one.
/// 3. A syllable is a peak of the rise that stands clearly above the average rise of the
///    200 ms around it.
/// 4. The marker is put where the loudness climbs fastest as plain amplitude, shortly
///    after that peak. In decibels a rise is steepest at its first sign; as amplitude it
///    is steepest where the vowel actually arrives.
/// 5. Two markers closer than 70 ms cannot be two syllables. The stronger one stays.
///
/// All numbers are starting values, to be tuned on Max's own voice.
public enum SyllableDetector {
    /// Counts the changes to the method or its numbers. Markers kept in a project's cache
    /// say which version found them, and markers of an older version are found again.
    public static let version = 1

    /// How far to each side the climb is measured, in values of the envelope: 7 ms before
    /// to 7 ms after, 15 values in all.
    public static let riseReach = 7
    /// How far above the noise floor a rise must reach to count, in decibels: the same
    /// distance that `VoiceEnvelope` calls sound.
    public static let marginAboveNoise: Float = VoiceEnvelope.clearlyAboveDecibels
    /// How far to each side the average rise around a peak is taken, in milliseconds.
    public static let localAverageReachMs = 100
    /// How far a peak must stand above the average rise around it, in decibels.
    public static let aboveLocalAverage: Float = 4
    /// The closest two markers may be, in milliseconds. Fast rap reaches about ten
    /// syllables a second.
    public static let minimumSpacingMs: Double = 70
    /// How far around a peak of the rise the steepest climb of the amplitude is looked
    /// for, in milliseconds: a little before it, and the length of a slow rise after it.
    public static let placementBeforeMs = 5
    public static let placementAfterMs = 25

    /// The syllable starts of a recording, in the order of the recording.
    public static func markers(in envelope: VoiceEnvelope) -> [SyllableMarker] {
        let count = envelope.values.count
        guard count > 2 * riseReach else { return [] }

        // The loudness with everything under the gate lifted to the gate.
        let gate = envelope.noiseFloor + marginAboveNoise
        let level = vDSP.threshold(envelope.values, to: gate, with: .clampToThreshold)
        // The same as plain amplitude, for placing the marker.
        let amplitude = vForce.exp(vDSP.multiply(Float(log(10.0) / 20), level))

        let rise = climb(of: level)
        let steepness = climb(of: amplitude)
        let localAverage = average(of: rise, reach: localAverageReachMs)

        var found: [SyllableMarker] = []
        var index = 1
        while index < count - 1 {
            guard rise[index] > rise[index - 1], rise[index] > localAverage[index] + aboveLocalAverage else {
                index += 1
                continue
            }
            // The top of a peak can be flat. Its middle is taken.
            var flatEnd = index
            while flatEnd + 1 < count, rise[flatEnd + 1] == rise[index] { flatEnd += 1 }
            if flatEnd + 1 == count || rise[flatEnd + 1] < rise[index] {
                let peak = (index + flatEnd) / 2
                let place = steepestClimb(of: steepness, around: peak, whileRising: rise)
                found.append(SyllableMarker(
                    sample: place * VoiceEnvelope.hopSamples + VoiceEnvelope.hopSamples / 2,
                    strength: (Double(rise[peak]) * 10).rounded() / 10
                ))
            }
            index = flatEnd + 1
        }
        return spaced(found)
    }

    /// The syllable starts of a recording, mono at 48,000 Hz, for when its envelope is
    /// not at hand.
    public static func markers(of samples: [Float]) -> [SyllableMarker] {
        markers(in: VoiceEnvelope.envelope(of: samples))
    }

    // MARK: The parts

    /// How much a curve climbs around each of its values, from `riseReach` values before to
    /// `riseReach` after. Never negative: a fall is no climb. At the two ends the climb is
    /// measured as far as the curve goes.
    private static func climb(of curve: [Float]) -> [Float] {
        let count = curve.count
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let difference = curve[min(index + riseReach, count - 1)] - curve[max(index - riseReach, 0)]
            result[index] = max(difference, 0)
        }
        return result
    }

    /// The mean of a curve around each of its values, `reach` values to each side.
    private static func average(of curve: [Float], reach: Int) -> [Float] {
        let count = curve.count
        var runningSum = [Double](repeating: 0, count: count + 1)
        for index in 0..<count { runningSum[index + 1] = runningSum[index] + Double(curve[index]) }
        return (0..<count).map { index in
            let from = max(index - reach, 0), to = min(index + reach + 1, count)
            return Float((runningSum[to] - runningSum[from]) / Double(to - from))
        }
    }

    /// Where the amplitude climbs fastest near a peak of the rise: from a little before
    /// the peak to a slow rise's length after it, and only as far as the loudness is
    /// still rising, so the place never jumps over a dip into the next syllable.
    private static func steepestClimb(of steepness: [Float], around peak: Int, whileRising rise: [Float]) -> Int {
        var best = peak
        var index = peak - 1
        while index >= max(peak - placementBeforeMs, 0), rise[index] > 0 {
            if steepness[index] > steepness[best] { best = index }
            index -= 1
        }
        index = peak + 1
        while index <= min(peak + placementAfterMs, rise.count - 1), rise[index] > 0 {
            if steepness[index] > steepness[best] { best = index }
            index += 1
        }
        return best
    }

    /// Keeps markers at least `minimumSpacingMs` apart. Where two are closer, the stronger
    /// stays, and of two equally strong ones the earlier.
    private static func spaced(_ markers: [SyllableMarker]) -> [SyllableMarker] {
        let minimum = Int((minimumSpacingMs / 1000 * Lockstep.sampleRate).rounded())
        var kept: [SyllableMarker] = []
        for marker in markers.sorted(by: { ($0.strength, -$0.sample) > ($1.strength, -$1.sample) }) {
            if kept.allSatisfy({ abs($0.sample - marker.sample) >= minimum }) {
                kept.append(marker)
            }
        }
        return kept.sorted { $0.sample < $1.sample }
    }
}

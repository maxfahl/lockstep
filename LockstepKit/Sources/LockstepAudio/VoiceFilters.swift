import Accelerate
import Foundation
import LockstepCore

/// One small filter of our own, for the parts of the voice chain that are our own code: the band the
/// de-esser listens to and turns down, and the darkening of an echo's repeats. The low cut and the tone are
/// Apple's EQ unit and do not use this.
///
/// The numbers are the usual ones for such a filter (the "Audio EQ Cookbook" formulas), at 48,000 Hz. The
/// filtering itself is Accelerate's, which is as fast in a debug build as in a release build. Max's copy of
/// the app is a debug build, so the chain's own loops are written with Accelerate throughout.
struct VoiceFilter {
    /// b0, b1, b2, a1, a2, as Accelerate wants them.
    private var coefficients: [Double]

    /// Lets through what lies below `hz`. With the `q` it starts with it is as flat as such a filter can be.
    /// Two of them in a row with the q values of `steepQs` are a steeper filter that is as flat.
    static func lowPass(hz: Double, q: Double = 0.5.squareRoot()) -> VoiceFilter {
        let (cosine, alpha) = terms(hz: hz, q: q)
        let a0 = 1 + alpha
        return VoiceFilter(coefficients: [
            (1 - cosine) / 2 / a0, (1 - cosine) / a0, (1 - cosine) / 2 / a0, -2 * cosine / a0, (1 - alpha) / a0,
        ])
    }

    /// Lets through what lies above `hz`: the mirror of `lowPass`.
    static func highPass(hz: Double, q: Double = 0.5.squareRoot()) -> VoiceFilter {
        let (cosine, alpha) = terms(hz: hz, q: q)
        let a0 = 1 + alpha
        return VoiceFilter(coefficients: [
            (1 + cosine) / 2 / a0, -(1 + cosine) / a0, (1 + cosine) / 2 / a0, -2 * cosine / a0, (1 - alpha) / a0,
        ])
    }

    /// The q values of two filters of the same kind and pitch that, one after the other, cut twice as steeply
    /// as one and are as flat up to the edge (a Butterworth filter of the fourth order).
    static let steepQs = [0.541_196_1, 1.306_563]

    /// Lets through the band around `hz`: a tone at `hz` comes out as loud as it went in and not shifted,
    /// and the further from it the quieter. A higher `q` is a narrower band.
    static func bandPass(hz: Double, q: Double) -> VoiceFilter {
        let (cosine, alpha) = terms(hz: hz, q: q)
        let a0 = 1 + alpha
        return VoiceFilter(coefficients: [alpha / a0, 0, -alpha / a0, -2 * cosine / a0, (1 - alpha) / a0])
    }

    /// Evens a row of numbers out over about `milliseconds`: each answer goes a small step from the one
    /// before towards the number that came in.
    static func smoothing(milliseconds: Double) -> VoiceFilter {
        let step = 1 - exp(-1 / (max(milliseconds, 0.02) / 1000 * Lockstep.sampleRate))
        return VoiceFilter(coefficients: [step, 0, 0, -(1 - step), 0])
    }

    private static func terms(hz: Double, q: Double) -> (cosine: Double, alpha: Double) {
        let angle = 2 * Double.pi * min(max(hz, 10), Lockstep.sampleRate * 0.45) / Lockstep.sampleRate
        return (cos(angle), sin(angle) / (2 * q))
    }

    /// The samples through the filter, which starts at rest.
    func filtered(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty,
              var filter = vDSP.Biquad(
                  coefficients: coefficients, channelCount: 1, sectionCount: 1, ofType: Float.self)
        else { return samples }
        return filter.apply(input: samples)
    }

    /// The samples through the filter forwards and then backwards, so that nothing is moved in time: what
    /// the first pass delays, the second brings back.
    func filteredBothWays(_ samples: [Float]) -> [Float] {
        var result = filtered(samples)
        vDSP.reverse(&result)
        result = filtered(result)
        vDSP.reverse(&result)
        return result
    }
}

/// Following how loud a sound is, for the parts of the chain that work out a gain from a level: the
/// de-esser and the level rider.
enum LevelFollower {
    /// The power of the sound (its samples squared), evened out over about `milliseconds`, at every sample.
    ///
    /// It is evened out forwards and then backwards, which only a sound that is all there allows: the
    /// answer at a sample knows what comes after it as well as what came before, so it is not late. A gain
    /// worked out from it turns on the sample the level changes, not a few milliseconds after.
    static func power(of samples: [Float], milliseconds: Double) -> [Float] {
        VoiceFilter.smoothing(milliseconds: milliseconds).filteredBothWays(vDSP.square(samples))
    }

    /// Left and right as one sound to measure: their middle. A gain worked out from it is given to both
    /// sides, so nothing moves between them.
    static func middle(of sound: StereoSound) -> [Float] {
        vDSP.multiply(0.5, vDSP.add(sound.left, sound.right))
    }
}

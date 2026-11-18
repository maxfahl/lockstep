import Accelerate
import Foundation
import LockstepCore

/// Evens out loud and quiet words: the levelling of the voice chain's squeeze.
///
/// What is louder than the threshold is turned down so that, of every `ratio` dB it goes over, 1 dB is left.
/// The gain follows the voice down within about `attackMs` and lets go within about `releaseMs`, and
/// `makeupDb` is added to everything afterwards. Left and right get the same gain.
///
///     let even = Squeezer.render(voice, parameters: .init(
///         thresholdDb: -20, ratio: 4, attackMs: 3, releaseMs: 60, makeupDb: 6))
///
/// It is our own code and not Apple's dynamics unit, which was the first plan. That unit was
/// tried offline on 15 November 2026 and does not fit: it has no ratio (its curve bends ever harder up to a
/// fixed ceiling, set as "headroom"), so neither "up to 6:1" nor "no levelling at 1:1" can be given to it,
/// and it answers 256 samples (5.8 ms) late. This one has the numbers `ChainParameters.Squeeze` holds, moves
/// nothing in time, and at a ratio of 1 with no make-up hands back the samples that went in.
enum Squeezer {
    /// How wide the bend of the curve around the threshold is, in dB: the levelling sets in softly.
    static let kneeDb: Float = 6

    static func render(_ sound: StereoSound, parameters: ChainParameters.Squeeze) -> StereoSound {
        guard !sound.left.isEmpty else { return sound }
        let makeup = Float(pow(10, parameters.makeupDb / 20))
        guard parameters.ratio > 1 else {
            guard parameters.makeupDb != 0 else { return sound }
            return StereoSound(left: vDSP.multiply(makeup, sound.left), right: vDSP.multiply(makeup, sound.right))
        }
        // How loud each sample is, in dB: the larger of left and right.
        let size = vDSP.threshold(
            vDSP.maximum(vDSP.absolute(sound.left), vDSP.absolute(sound.right)), to: 1e-10, with: .clampToThreshold)
        var down = vDSP.multiply(20, vForce.log10(size))

        let threshold = Float(parameters.thresholdDb)
        // Of what goes over the threshold, this share is taken away.
        let share = Float(1 - 1 / parameters.ratio)
        let attack = step(milliseconds: parameters.attackMs)
        let release = step(milliseconds: parameters.releaseMs)
        // From each sample's level to how far the voice is turned down there, in dB.
        down.withUnsafeMutableBufferPointer { down in
            var now: Float = 0
            for index in down.indices {
                let over = down[index] - threshold
                let wanted: Float
                if over <= -kneeDb / 2 {
                    wanted = 0
                } else if over >= kneeDb / 2 {
                    wanted = share * over
                } else {
                    let into = over + kneeDb / 2
                    wanted = share * into * into / (2 * kneeDb)
                }
                now += (wanted > now ? attack : release) * (wanted - now)
                down[index] = now
            }
        }
        // The gain: the make-up, less what the voice is turned down.
        let gain = vDSP.multiply(makeup, vForce.exp(vDSP.multiply(-Float(log(10.0)) / 20, down)))
        return StereoSound(left: vDSP.multiply(sound.left, gain), right: vDSP.multiply(sound.right, gain))
    }

    /// How much of the way the gain goes at each sample, to be there in about `milliseconds`.
    private static func step(milliseconds: Double) -> Float {
        Float(1 - exp(-1 / (max(milliseconds, 0.02) / 1000 * Lockstep.sampleRate)))
    }
}

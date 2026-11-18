import Accelerate
import Foundation
import LockstepCore

/// Rides the level of a voice slowly, so that quiet words and quiet endings are heard: the first half of the
/// squeeze in the sung characters, before the levelling.
///
/// It is the hand on the fader. The level of the voice is followed over about `speedMs`, and where the voice
/// is quieter than its own loud level it is turned up by what it lacks, at most by `maxGainDb`. It never
/// turns anything down: that is the levelling's work.
///
///     let even = LevelRider.render(voice, parameters: .init(maxGainDb: 6, speedMs: 300))
///
/// A pause is not a quiet word. The slow level is followed only where there is voice and waits through a
/// pause, so the end of a word is not read as getting quieter and quieter. And what lies more than `pauseDb`
/// under the loud level is turned up less and less, and from `silenceDb` under it not at all, so breath and
/// room noise between the lines stay where they were.
///
/// Nothing is moved in time: only a gain is applied, the same to left and right, and it is worked out from
/// the level before and after each sample, so it is not late.
enum LevelRider {
    /// Down to this far under the loud level, in dB, a sound is voice and gets all it lacks.
    static let pauseDb: Float = 36
    /// From this far under the loud level, in dB, a sound is a pause and is left alone.
    static let silenceDb: Float = 48
    /// Over how long the level is followed to tell voice from a pause, in milliseconds.
    static let voiceMs = 10.0
    /// The loud level is the level the loudest tenth of the voice lies above.
    private static let loudShare = 0.9

    static func render(_ sound: StereoSound, parameters: ChainParameters.Ride) -> StereoSound {
        guard parameters.maxGainDb > 0, !sound.left.isEmpty else { return sound }
        let quick = LevelFollower.power(of: LevelFollower.middle(of: sound), milliseconds: voiceMs)
        let highest = vDSP.maximum(quick)
        guard highest > 0 else { return sound }

        // The loud level, from every sixteenth sample of what is voice.
        let voiceFloor = highest * pow(10, -pauseDb / 10)
        let voiced = stride(from: 0, to: quick.count, by: 16).map { quick[$0] }.filter { $0 > voiceFloor }.sorted()
        guard !voiced.isEmpty else { return sound }
        let loud = voiced[min(Int(Double(voiced.count) * loudShare), voiced.count - 1)]

        // The slow level: followed forwards and then backwards, only where there is voice.
        let step = Float(1 - exp(-1 / (max(parameters.speedMs, voiceMs) / 1000 * Lockstep.sampleRate)))
        var slow = quick
        let most = Float(parameters.maxGainDb)
        var gain = [Float](repeating: 1, count: quick.count)
        var any = false
        // Plain loops over the samples' memory: each answer needs the one before it, and that is quick
        // enough in a debug build only without the checks an array makes at every sample.
        quick.withUnsafeBufferPointer { quick in
            slow.withUnsafeMutableBufferPointer { slow in
                var level = loud
                for index in 0..<quick.count {
                    if quick[index] > voiceFloor { level += step * (quick[index] - level) }
                    slow[index] = level
                }
                for index in (0..<quick.count).reversed() {
                    if quick[index] > voiceFloor { level += step * (slow[index] - level) }
                    slow[index] = level
                }
                gain.withUnsafeMutableBufferPointer { gain in
                    for index in 0..<quick.count where quick[index] > 0 && slow[index] < loud {
                        // How far under the loud level this sample is. All it lacks while it is voice,
                        // then less and less down to silence.
                        let under = 10 * log10(loud / quick[index])
                        guard under < silenceDb else { continue }
                        let share = under <= pauseDb ? 1 : (silenceDb - under) / (silenceDb - pauseDb)
                        gain[index] = pow(10, min(10 * log10(loud / slow[index]), most) * share / 20)
                        any = true
                    }
                }
            }
        }
        guard any else { return sound }
        return StereoSound(left: vDSP.multiply(sound.left, gain), right: vDSP.multiply(sound.right, gain))
    }
}

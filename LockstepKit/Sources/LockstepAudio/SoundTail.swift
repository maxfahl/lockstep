import Foundation
import LockstepCore

/// What rings after a sound: where it is cut and how it ends.
///
/// A finished sound is longer than its clip by its tail: the reverb, the last repeats of an echo, or a
/// layer that reaches past the end. The tail is cut where it has fallen below -60 dB, is never longer than
/// 6 seconds, and its last 50 ms are faded out, so it ends in silence wherever it was cut.
enum SoundTail {
    /// The longest a tail may be, in samples: 6 seconds.
    static let longest = Int(6 * Lockstep.sampleRate)
    /// The fade at its end, in samples: 50 ms.
    static let fade = Int(0.05 * Lockstep.sampleRate)
    /// A tail is over where no sample after is larger than this: -60 dBFS.
    static let quiet: Float = 0.001

    /// The sound with its tail cut and faded.
    ///
    /// - Parameters:
    ///   - kept: how many samples at the start are the sound itself. They are never cut or faded.
    ///   - longest: the longest the tail may be, in samples. Left out, 6 seconds. The echo on a word is
    ///     kept to its last repeat, which at a slow tempo lies later than that.
    static func cut(_ sound: StereoSound, after kept: Int, longest: Int = SoundTail.longest) -> StereoSound {
        let count = sound.left.count
        guard kept >= 0, count > kept else { return sound }
        var end = min(count, kept + max(longest, 0))
        while end > kept, abs(sound.left[end - 1]) < quiet, abs(sound.right[end - 1]) < quiet {
            end -= 1
        }
        var left = Array(sound.left[..<end])
        var right = Array(sound.right[..<end])
        let faded = min(fade, end - kept)
        for index in 0..<faded {
            // Down to nothing on the sample after the last.
            let gain = Float(faded - index) / Float(faded + 1)
            left[end - faded + index] *= gain
            right[end - faded + index] *= gain
        }
        return StereoSound(left: left, right: right)
    }
}

import Accelerate
import Foundation
import LockstepCore

/// Turns sharp s sounds down: the second part of the voice chain, after the low cut.
///
/// It follows how loud the band of the s sounds (about 5 to 9 kHz) is against the whole voice. In a vowel
/// that band holds little of the sound, in an s nearly all of it. While the band is stronger against the
/// whole than the threshold says, the band alone is turned down, by as much as it is over and at most by the
/// limit. Left and right get the same gain.
///
///     let softer = DeEsser.render(voice, parameters: .init(thresholdDb: -14, maxCutDb: 8))
///
/// What the two numbers mean:
/// - `thresholdDb` is the level of the band against the level of the whole voice, in dB, so it is below 0. A
///   vowel lies around -25 to -35, an s around -3 to -8. About -14 catches the s sounds and leaves the vowels.
/// - `maxCutDb` is the most the band is turned down, in dB. That much is taken from the middle of the band
///   and less towards its edges.
///
/// Nothing is moved in time, and where nothing is sharp the samples that went in come out: the band is taken
/// out of the voice by subtracting it, and where its gain is 1 nothing is subtracted.
enum DeEsser {
    /// The middle of the band, in Hz, and how narrow it is: it reaches from about 5 to 9 kHz.
    static let bandHz = 6_700.0
    static let bandQ = 1.7
    /// Over how long the two levels are followed, in milliseconds.
    static let followMs = 4.0
    /// A voice quieter than this, as power (-80 dBFS), counts as this loud, so that silence has no level to
    /// be sharp against.
    private static let silentPower: Float = 1e-8

    static func render(_ sound: StereoSound, parameters: ChainParameters.DeEss) -> StereoSound {
        guard parameters.maxCutDb > 0, !sound.left.isEmpty else { return sound }
        let band = VoiceFilter.bandPass(hz: bandHz, q: bandQ)
        let middle = LevelFollower.middle(of: sound)
        let whole = vDSP.threshold(
            LevelFollower.power(of: middle, milliseconds: followMs), to: silentPower, with: .clampToThreshold)
        let sharp = vDSP.threshold(
            LevelFollower.power(of: band.filtered(middle), milliseconds: followMs), to: 1e-30, with: .clampToThreshold)

        // How far the band is over the threshold at each sample, in dB, held between nothing and the limit.
        var over = vForce.log10(vDSP.divide(sharp, whole))
        over = vDSP.add(Float(-parameters.thresholdDb), vDSP.multiply(10, over))
        over = vDSP.clip(over, to: 0...Float(parameters.maxCutDb))
        guard vDSP.maximum(over) > 0 else { return sound }
        // How much of the band is taken away: 1 minus the gain that many dB down. 0 where nothing is sharp.
        let taken = vDSP.add(1, vDSP.multiply(-1, vForce.exp(vDSP.multiply(-Float(log(10.0)) / 20, over))))

        func softened(_ side: [Float]) -> [Float] {
            vDSP.subtract(side, vDSP.multiply(taken, band.filtered(side)))
        }
        let left = softened(sound.left)
        return StereoSound(left: left, right: sound.left == sound.right ? left : softened(sound.right))
    }
}

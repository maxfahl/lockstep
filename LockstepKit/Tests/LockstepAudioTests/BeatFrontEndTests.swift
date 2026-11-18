import Foundation
import Testing
import LockstepCore
@testable import LockstepAudio

@Suite struct BeatFrontEndTests {
    /// The real thing: the original Python code's spectrogram for the same 70 seconds of sound.
    @Test func matchesTheOriginalSpectrogram() throws {
        let samples = try BeatFixture.reference.samples()
        let expected = try BeatFixture.reference.spectrogram()

        let spectrogram = BeatFrontEnd.spectrogram(of: samples, sampleRate: 22_050)

        #expect(spectrogram.frameCount == 3_501)
        #expect(spectrogram.values.count == expected.count)
        #expect((expected.max() ?? 0) > 3)
        var furthestOff: Float = 0
        var sum = 0.0
        for (ours, theirs) in zip(spectrogram.values, expected) {
            let difference = abs(ours - theirs)
            furthestOff = max(furthestOff, difference)
            sum += Double(difference)
        }
        let mean = sum / Double(expected.count)
        print("Spectrogram against the original: furthest off \(furthestOff), mean \(mean), on values up to \(expected.max() ?? 0)")
        #expect(furthestOff < 1e-3)
        #expect(mean < 1e-4)
    }

    @Test func aShortSoundHasOneFrameMoreThanItsLengthDividedByTheHop() throws {
        let samples = try BeatFixture.short.samples()
        let expected = try BeatFixture.short.spectrogram()

        let spectrogram = BeatFrontEnd.spectrogram(of: samples, sampleRate: 22_050)

        #expect(spectrogram.frameCount == 601)
        let furthestOff = zip(spectrogram.values, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(furthestOff < 1e-3)
    }

    @Test func silenceIsExactlyZeroAndNoSoundGivesNoFrames() {
        let silence = BeatFrontEnd.spectrogram(of: [Float](repeating: 0, count: 4_410), sampleRate: 22_050)
        #expect(silence.frameCount == 11)
        #expect(silence.values.allSatisfy { $0 == 0 })

        #expect(BeatFrontEnd.spectrogram(of: [], sampleRate: 22_050).frameCount == 0)
        // Too short to mirror at its ends: still one frame, and no crash.
        #expect(BeatFrontEnd.spectrogram(of: [0.5, -0.5, 0.25], sampleRate: 22_050).frameCount == 1)
    }

    /// The resampler on its own: a tone the model can hear comes out as the same tone, in place.
    @Test func resamplingKeepsAToneInPlace() {
        let seconds = 2
        let tone = { (rate: Double) -> [Float] in
            (0..<(seconds * Int(rate))).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double($0) / rate)) }
        }

        let resampled = BeatFrontEnd.resample(tone(48_000), from: 48_000)

        let expected = tone(22_050)
        #expect(resampled.count == expected.count)
        // Away from the two ends, where the silence beyond the sound is mixed in.
        let inside = 500..<(expected.count - 500)
        let furthestOff = inside.map { abs(resampled[$0] - expected[$0]) }.max() ?? 1
        print("Resampled 1 kHz tone: furthest off \(furthestOff)")
        #expect(furthestOff < 1e-4)
    }

    /// A tone above what 22,050 Hz can carry must be removed, or it would come back as a false
    /// tone lower down.
    @Test func resamplingRemovesWhatIsTooHigh() {
        let high = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 15_000 * Double($0) / 48_000)) }

        let resampled = BeatFrontEnd.resample(high, from: 48_000)

        #expect(resampled.count == 22_050)
        let loudest = resampled[500..<21_550].map(abs).max() ?? 1
        print("Resampled 15 kHz tone: loudest \(loudest)")
        #expect(loudest < 1e-5)
    }

    @Test func resamplingKeepsLengthAndLevel() {
        #expect(BeatFrontEnd.resample([], from: 48_000).isEmpty)
        let steady = BeatFrontEnd.resample([Float](repeating: 0.25, count: 9_600), from: 48_000)
        #expect(steady.count == 4_410)
        #expect(steady[500..<3_900].allSatisfy { abs($0 - 0.25) < 1e-6 })
        // Already at the model's rate: handed back untouched.
        #expect(BeatFrontEnd.resample([0.1, 0.2, 0.3], from: 22_050) == [0.1, 0.2, 0.3])
        // A rate with twice as many samples.
        #expect(BeatFrontEnd.resample([Float](repeating: 0, count: 44_100), from: 44_100).count == 22_050)
    }

    /// The app's songs are at 48,000 Hz. The same sound made at 48,000 Hz and at 22,050 Hz must
    /// give nearly the same picture.
    @Test func aSoundAtTheAppsRateGivesNearlyTheSamePicture() {
        // A low note that swells twice a second, with a steady tone in the middle and one high up.
        // It has no sudden jumps: a jump holds pitches above what 22,050 Hz can carry, and those
        // would be folded into the sound made at 22,050 Hz but rightly removed from the other.
        let sound = { (rate: Double) -> [Float] in
            (0..<Int(4 * rate)).map { index -> Float in
                let t = Double(index) / rate
                let swell = 0.5 - 0.5 * cos(2 * Double.pi * 2 * t)
                return Float(
                    0.4 * swell * sin(2 * Double.pi * 220 * t)
                        + 0.2 * sin(2 * Double.pi * 3_000 * t)
                        + 0.1 * sin(2 * Double.pi * 7_000 * t)
                )
            }
        }

        let resampled = BeatFrontEnd.spectrogram(of: sound(48_000), sampleRate: 48_000)
        let direct = BeatFrontEnd.spectrogram(of: sound(22_050), sampleRate: 22_050)

        #expect(resampled.frameCount == direct.frameCount)
        // Bands under about 8 kHz (the first 110), away from the ends of the sound.
        var furthestOff: Float = 0
        for frame in 5..<(direct.frameCount - 5) {
            for band in 0..<110 {
                let index = frame * 128 + band
                furthestOff = max(furthestOff, abs(resampled.values[index] - direct.values[index]))
            }
        }
        print("Spectrogram of a resampled sound against the same sound made at 22,050 Hz: furthest off \(furthestOff)")
        #expect(furthestOff < 0.001)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCKSTEP_SONG"] != nil))
    func wholeSongTakesUnderTwoSeconds() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCKSTEP_SONG"]!)
        let song = try await SongImporter.importSong(from: url)
        let clock = ContinuousClock()
        var spectrogram = BeatSpectrogram(values: [], frameCount: 0)
        let taken = clock.measure { spectrogram = BeatFrontEnd.spectrogram(of: song) }
        print("Spectrogram of \(song.duration) s of song: \(spectrogram.frameCount) frames in \(taken)")
        #expect(spectrogram.frameCount == 1 + Int((Double(song.lengthSamples) * 22_050 / 48_000).rounded()) / 441)
        #expect(taken < .seconds(2) * (song.duration / 210))
    }
}

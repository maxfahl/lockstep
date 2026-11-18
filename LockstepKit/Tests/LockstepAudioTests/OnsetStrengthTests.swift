import Foundation
import Testing
import LockstepCore
@testable import LockstepAudio

@Suite struct OnsetStrengthTests {
    @Test func clicksInSilencePeakWithinOneMillisecond() {
        // Positions on a hop boundary, just before one, just after one, and anywhere.
        let clicks = [4_800, 14_431, 24_033, 33_616, 43_215, 52_847, 62_400]
        var samples = [Float](repeating: 0, count: 72_000)
        for click in clicks { samples[click] = 0.8 }

        let curve = OnsetStrength.curve(of: samples)

        #expect(curve.values.count == 1 + 72_000 / 32)
        let highest = curve.values.max() ?? 0
        #expect(highest > 1)
        for click in clicks {
            let clickTime = Double(click) / 48_000
            // The strongest value within 35 ms of the click, the width the beat search uses.
            let near = curve.values.indices.filter { abs(curve.time(at: $0) - clickTime) <= 0.035 }
            let peak = near.max { curve.values[$0] < curve.values[$1] }!
            #expect(abs(curve.time(at: peak) - clickTime) < 0.001, "click at sample \(click)")
            #expect(curve.values[peak] > highest / 2)
        }
        // Between the clicks nothing new happens. A click stays inside the window for 21 ms.
        for index in curve.values.indices where clicks.allSatisfy({ abs(index * 32 - $0) > 1_100 }) {
            #expect(curve.values[index] == 0)
        }
    }

    @Test func steadyToneIsFlatAfterItsStart() {
        let start = 9_600
        let samples = (0..<48_000).map { index -> Float in
            index < start ? 0 : Float(0.5 * sin(2 * Double.pi * 440 * Double(index - start) / 48_000))
        }

        let curve = OnsetStrength.curve(of: samples)

        let startIndex = start / 32
        let onset = curve.values[(startIndex - 2)...(startIndex + 40)].max() ?? 0
        #expect(onset > 1)
        // Once the whole window is inside the tone (1,024 samples, 32 hops), nothing new arrives.
        // What is left is a small steady ripple, about 0.2 against an onset of 6: the faint edges of
        // the tone in neighbouring bands flicker as the window slides along the wave. librosa has it too.
        let after = curve.values[(startIndex + 40)...].max() ?? 1
        #expect(after < onset / 20)
        #expect(curve.values[..<(startIndex - 2)].allSatisfy { $0 == 0 })
    }

    @Test func timesAreHopsOfThirtyTwoSamples() {
        let curve = OnsetStrength.curve(of: [Float](repeating: 0, count: 100))
        #expect(curve.values == [0, 0, 0, 0])
        #expect(curve.times == [0, 32.0 / 48_000, 64.0 / 48_000, 96.0 / 48_000])
        #expect(OnsetStrength.curve(of: [Float]()).values.isEmpty)
    }

    @Test func monoMixIsTheMeanOfLeftAndRight() {
        let song = ImportedSong(samples: [0.5, 0.25, -1, 1, 0.2, 0.2], lengthSamples: 3)
        #expect(OnsetStrength.monoMix(of: song) == [0.375, 0, 0.2])
    }

    /// The real thing: librosa's own curve for one second of thumps over hiss, made by
    /// `Fixtures/make-onset-reference.py`. The prototype that reached 5.8 ms used librosa.
    @Test func matchesLibrosa() throws {
        let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
        let samples = try floats(at: fixtures.appending(path: "onsetref.f32"))
        let expected = try floats(at: fixtures.appending(path: "onsetref-curve.f32"))

        let curve = OnsetStrength.curve(of: samples).values

        #expect(samples.count == 48_000)
        #expect(curve.count == expected.count)
        #expect((expected.max() ?? 0) > 5)
        let furthestOff = zip(curve, expected).map { abs($0 - $1) }.max() ?? 1
        print("Furthest from librosa: \(furthestOff) on a curve that peaks at \(expected.max() ?? 0)")
        #expect(furthestOff < 0.001)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCKSTEP_SONG"] != nil))
    func wholeSongTakesUnderFiveSeconds() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCKSTEP_SONG"]!)
        let song = try await SongImporter.importSong(from: url)
        let clock = ContinuousClock()
        var curve = OnsetCurve(values: [])
        let taken = clock.measure { curve = OnsetStrength.curve(of: song) }
        print("Onset curve of \(song.duration) s of song: \(curve.values.count) values in \(taken)")
        #expect(curve.values.count == 1 + song.lengthSamples / 32)
        #expect(taken < .seconds(5) * (song.duration / 210))
    }
}

/// A file of 32-bit floats, as numpy's `tofile` writes them.
private func floats(at url: URL) throws -> [Float] {
    try Data(contentsOf: url).withUnsafeBytes { bytes in
        (0..<(bytes.count / 4)).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
    }
}

import Foundation
import Testing
@testable import LockstepCore

/// How loud audio sounds, checked against figures that are known beforehand.
@Suite("Loudness")
struct LoudnessTests {
    /// A sine tone at 48 kHz.
    private func sine(_ frequency: Double, amplitude: Double, seconds: Double) -> [Float] {
        (0..<Int(seconds * 48_000)).map { index in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(index) / 48_000))
        }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 48_000))
    }

    /// The amplitude of a level in dBFS.
    private func amplitude(db: Double) -> Double {
        pow(10, db / 20)
    }

    // MARK: Known figures

    @Test func aFullScaleSineReadsMinusThree() throws {
        // The standard's own reference: 997 Hz at full scale is -3.01 LUFS.
        let loudness = try #require(Loudness.integrated(sine(997, amplitude: 1, seconds: 5)))
        #expect(abs(loudness - -3.01) < 0.1)
    }

    @Test func aSineTwentyDecibelsLowerReadsTwentyLower() throws {
        let loudness = try #require(Loudness.integrated(sine(997, amplitude: amplitude(db: -20), seconds: 5)))
        #expect(abs(loudness - -23.01) < 0.1)
    }

    @Test func lowAndHighTonesAreWeighedAsTheEarHearsThem() throws {
        // 100 Hz is heard weaker and 5 kHz stronger than their size says.
        // Reference from ffmpeg 8's `ebur128` filter on the same signal, 20 s
        // long (`aevalsrc=0.25*sin(2*PI*100*t)+0.05*sin(2*PI*5000*t)`): I = -16.4 LUFS.
        let low = sine(100, amplitude: 0.25, seconds: 20)
        let high = sine(5_000, amplitude: 0.05, seconds: 20)
        let loudness = try #require(Loudness.integrated(zip(low, high).map { $0 + $1 }))
        #expect(abs(loudness - -16.4) < 0.1)
    }

    // MARK: Gating

    @Test func silenceAtBothEndsDoesNotChangeTheFigure() throws {
        let tone = sine(997, amplitude: amplitude(db: -20), seconds: 30)
        let alone = try #require(Loudness.integrated(tone))
        let padded = try #require(Loudness.integrated(silence(seconds: 2) + tone + silence(seconds: 2)))
        #expect(abs(padded - alone) < 0.1)
        #expect(abs(padded - -23.01) < 0.1)
    }

    @Test func aFarQuieterStretchIsLeftOut() throws {
        // Ten seconds at -20 dBFS, then ten at -54 dBFS: louder than silence,
        // but more than 10 LU below the rest, so it does not count.
        // Reference from ffmpeg 8's `ebur128` filter on the same signal
        // (`aevalsrc=if(lt(t\,10)\,0.1\,0.002)*sin(2*PI*997*t)`): I = -23.1 LUFS.
        // Without the second gate it would read about -26.
        let signal = (0..<960_000).map { index in
            Float((index < 480_000 ? 0.1 : 0.002) * sin(2 * Double.pi * 997 * Double(index) / 48_000))
        }
        let loudness = try #require(Loudness.integrated(signal))
        #expect(abs(loudness - -23.1) < 0.1)
    }

    @Test func silenceHasNoLoudness() {
        #expect(Loudness.integrated(silence(seconds: 3)) == nil)
        #expect(Loudness.integrated(silence(seconds: 0.1)) == nil)
        #expect(Loudness.integrated([]) == nil)
    }

    // MARK: Short audio

    @Test func aShortBurstIsMeasuredAsOneBlock() throws {
        // 200 ms is shorter than one block, and still gets a figure.
        let loudness = try #require(Loudness.integrated(sine(997, amplitude: amplitude(db: -20), seconds: 0.2)))
        #expect(abs(loudness - -23.01) < 0.5)
    }

    // MARK: Peak

    @Test func thePeakOfAHalfScaleSineIsMinusSix() {
        // 1 kHz, so that samples land exactly on the top of the wave.
        let peak = Loudness.peakDb(sine(1_000, amplitude: 0.5, seconds: 1))
        #expect(abs(peak - -6.02) < 0.01)
    }

    @Test func thePeakCountsNegativeSamplesAndSilenceHasNone() {
        #expect(abs(Loudness.peakDb([0.1, -0.5, 0.25]) - -6.02) < 0.01)
        #expect(Loudness.peakDb(silence(seconds: 0.1)) == -.infinity)
        #expect(Loudness.peakDb([]) == -.infinity)
    }

    // MARK: Clips

    @Test func aClipIsItsSegmentsInOrderWithTheirGainsAndNoGaps() {
        let first = UUID()
        let second = UUID()
        let recordings: [UUID: [Float]] = [
            first: [0.1, 0.2, 0.3, 0.4, 0.5],
            second: [0.5, 0.25],
        ]
        let clip = Clip(
            segments: [
                Segment(recordingID: first, inSample: 1, outSample: 3),
                // Far away in time, and 6.02 dB down: half as large.
                Segment(recordingID: second, inSample: 0, outSample: 2, offsetSamples: 96_000, gainDb: -6.0206),
                // A recording whose samples are missing adds nothing.
                Segment(recordingID: UUID(), inSample: 0, outSample: 10),
                // Reaching past the end of the recording stops at its end.
                Segment(recordingID: first, inSample: 4, outSample: 9),
            ],
            // The clip's own volume and normalisation are not part of the measurement.
            gainDb: 6,
            normalizeGainDb: 12
        )
        let samples = Loudness.samples(of: clip) { recordings[$0] }
        let expected: [Float] = [0.2, 0.3, 0.25, 0.125, 0.5]
        #expect(samples.count == expected.count)
        for (sample, wanted) in zip(samples, expected) {
            #expect(abs(sample - wanted) < 0.0001)
        }
    }

    @Test func aClipIsMeasuredOverWhatItPlays() throws {
        // Two seconds at -20 dBFS and two at -26 dBFS, the second raised 6 dB
        // by its segment: together the same as four seconds at -20 dBFS.
        let loud = UUID()
        let quiet = UUID()
        let recordings: [UUID: [Float]] = [
            loud: sine(997, amplitude: amplitude(db: -20), seconds: 2),
            quiet: sine(997, amplitude: amplitude(db: -26), seconds: 2),
        ]
        let clip = Clip(segments: [
            Segment(recordingID: loud, inSample: 0, outSample: 96_000),
            Segment(recordingID: quiet, inSample: 0, outSample: 96_000, offsetSamples: 48_000, gainDb: 6),
        ])
        let loudness = try #require(Loudness.integrated(of: clip) { recordings[$0] })
        #expect(abs(loudness - -23.01) < 0.1)

        let empty = Clip(segments: [])
        #expect(Loudness.integrated(of: empty) { recordings[$0] } == nil)
    }
}

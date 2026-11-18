import Foundation
import Testing
import LockstepCore
@testable import LockstepAudio

@Suite struct SyllableDetectorTests {
    /// One made-up syllable. `rise` is where its vowel starts to rise, in seconds: a noise
    /// burst ("consonant") fills the 10 ms before it, the vowel rises for 15 ms, holds for
    /// `hold` and dies away over `fall`.
    private struct Syllable {
        var rise: Double
        var hold = 0.080
        var fall = 0.030

        /// The middle of the vowel's rise: where the marker belongs.
        var middle: Double { rise + 0.0075 }
        /// How loud the vowel is at a moment, 0 to 1.
        func vowel(at time: Double) -> Double {
            let since = time - rise
            if since < 0 { return 0 }
            if since < 0.015 { return since / 0.015 }
            if since < 0.015 + hold { return 1 }
            return max(0, 1 - (since - 0.015 - hold) / fall)
        }
        func isConsonant(at time: Double) -> Bool { time >= rise - 0.010 && time < rise }
    }

    /// Low room noise with syllables on top: each a 200 Hz tone with its harmonics up to
    /// 2 kHz, after a short burst of noise. The same every time it is made.
    private func recording(seconds: Double, syllables: [Syllable], gain: Float = 1) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func noise() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 40) / Double(1 << 24) * 2 - 1
        }
        return (0..<Int(seconds * 48_000)).map { index in
            let time = Double(index) / 48_000
            var value = noise() * 0.003
            for syllable in syllables {
                if syllable.isConsonant(at: time) { value += noise() * 0.03 }
                let loudness = syllable.vowel(at: time)
                guard loudness > 0 else { continue }
                var tone = 0.0
                for harmonic in 1...10 {
                    tone += sin(2 * Double.pi * 200 * Double(harmonic) * time) / Double(harmonic)
                }
                value += 0.1 * loudness * tone
            }
            return Float(value) * gain
        }
    }

    private func seconds(_ marker: SyllableMarker) -> Double { Double(marker.sample) / 48_000 }

    @Test func eightSyllablesGiveEightMarkersOnTheVowelRises() {
        let syllables = (0..<8).map { Syllable(rise: 0.5 + 0.25 * Double($0)) }
        let markers = SyllableDetector.markers(of: recording(seconds: 3, syllables: syllables))

        #expect(markers.count == 8)
        for (marker, syllable) in zip(markers, syllables) {
            // Within 5 ms of the middle of the rise, which also means not on the consonant.
            #expect(abs(seconds(marker) - syllable.middle) < 0.005)
            #expect(!syllable.isConsonant(at: seconds(marker)))
            #expect(marker.strength > 6)
        }
        #expect(markers == markers.sorted { $0.sample < $1.sample })
    }

    @Test func syllablesNinetyMillisecondsApartAreAllFound() {
        let syllables = (0..<10).map { Syllable(rise: 0.5 + 0.09 * Double($0), hold: 0.030, fall: 0.015) }
        let markers = SyllableDetector.markers(of: recording(seconds: 2, syllables: syllables))

        #expect(markers.count == 10)
        for (marker, syllable) in zip(markers, syllables) {
            #expect(abs(seconds(marker) - syllable.middle) < 0.005)
        }
    }

    @Test func aDoubleHitFortyMillisecondsApartGivesOneMarker() throws {
        let first = Syllable(rise: 0.5, hold: 0.005, fall: 0.008)
        let second = Syllable(rise: 0.54, hold: 0.005, fall: 0.008)
        let markers = SyllableDetector.markers(of: recording(seconds: 1.5, syllables: [first, second]))

        #expect(markers.count == 1)
        let marker = try #require(markers.first)
        #expect(min(abs(seconds(marker) - first.middle), abs(seconds(marker) - second.middle)) < 0.005)
    }

    @Test func noiseOnlyGivesNoMarkers() {
        #expect(SyllableDetector.markers(of: recording(seconds: 3, syllables: [])).isEmpty)
        #expect(SyllableDetector.markers(of: [Float](repeating: 0, count: 48_000)).isEmpty)
        #expect(SyllableDetector.markers(of: []).isEmpty)
    }

    @Test func aRecordingTwelveDecibelsQuieterGivesTheSameMarkers() {
        let syllables = (0..<8).map { Syllable(rise: 0.5 + 0.25 * Double($0)) }
        let loud = SyllableDetector.markers(of: recording(seconds: 3, syllables: syllables))
        let quiet = SyllableDetector.markers(of: recording(seconds: 3, syllables: syllables, gain: 0.25))

        #expect(loud.count == 8)
        #expect(quiet.map(\.sample) == loud.map(\.sample))
        for (quietMarker, loudMarker) in zip(quiet, loud) {
            #expect(abs(quietMarker.strength - loudMarker.strength) <= 0.1)
        }
    }

    @Test func theEnvelopeFromTheCacheGivesTheSameMarkersAsTheSound() {
        let syllables = (0..<4).map { Syllable(rise: 0.5 + 0.25 * Double($0)) }
        let samples = recording(seconds: 2, syllables: syllables)
        let envelope = VoiceEnvelope.envelope(of: samples)
        // What is read back from the cache: the values and the length, nothing else.
        let reread = VoiceEnvelope(values: envelope.values, lengthSamples: envelope.lengthSamples)

        #expect(SyllableDetector.markers(in: reread) == SyllableDetector.markers(of: samples))
    }
}

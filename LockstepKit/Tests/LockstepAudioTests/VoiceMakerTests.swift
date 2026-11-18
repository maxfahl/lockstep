import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// What a track's Fast voice promises: the knobs do what they say, the voice is as long as the recording and
/// the same every time, neutral knobs and silence change nothing, and a cancelled task gives up.
@Suite struct VoiceMakerTests {
    /// A voice of 100 Hz whose throat rings at three places, as a vowel's does. The upper two lie 1,000 Hz
    /// apart: Rubber Band moves an outline of the spectrum smoothed over about 650 Hz, and a resonance at
    /// 1,700 Hz, between 700 and 2,700, was merged with its neighbours and went 8 % off at Pitch -2 (tried on
    /// 16 November 2026). The resonances are looked for within 15 % of where they should be, so that the
    /// measure does not find a neighbour.
    private static let period = 480
    private static let resonances: [Double] = [700, 2400, 3400]

    private static func vowel(count: Int = 48_000) -> [Float] {
        VowelFixtures.vowel(count: count, period: period, peaks: resonances)
    }

    // MARK: The knobs

    @Test func pitchMinusTwoMakesTheVoiceTwoSemitonesLowerAndKeepsTheUpperResonances() async throws {
        let vowel = Self.vowel()

        let voice = try await VoiceMaker.fast(vowel, knobs: VoiceKnobs(pitch: -2))

        let wanted = Double(Self.period) * pow(2, 2.0 / 12)
        let period = VowelFixtures.period(of: voice, near: Int(wanted.rounded()))
        // Measured on 16 November 2026: 538.71 samples, where 538.78 are two semitones lower.
        #expect(abs(period / wanted - 1) < 0.002, "one wave is \(period) samples, not \(wanted)")
        // The upper two stay where they were: measured 2,411 and 3,390 Hz. The lowest is not asked about: a
        // sharp peak this near the bottom goes partly with the pitch, because of the smoothed outline (see
        // `VoiceShifterTests.aLowerOrHigherVoiceKeepsItsUpperPeak`).
        for resonance in Self.resonances.dropFirst() {
            let found = VowelFixtures.peak(of: voice, period: period, near: resonance, within: 0.15)
            #expect(abs(found / resonance - 1) < 0.05, "the resonance of \(resonance) Hz is at \(found) Hz")
        }
    }

    @Test func depthTenMovesTheResonancesDownAndKeepsThePitch() async throws {
        let vowel = Self.vowel()
        let before = Self.resonances.map {
            VowelFixtures.peak(of: vowel, period: Double(Self.period), near: $0, within: 0.15)
        }

        let voice = try await VoiceMaker.fast(vowel, knobs: VoiceKnobs(depth: 10))

        let period = VowelFixtures.period(of: voice, near: Self.period)
        // Measured: 479.999 samples.
        #expect(abs(period - Double(Self.period)) < 0.05, "one wave is \(period) samples")
        // The upper two move by about what Depth asks, 10 % down: measured 0.869 of their place (2,393 to
        // 2,080 Hz) and 0.900 (3,406 to 3,064 Hz), so each is allowed 5 percentage points either way. The
        // lowest only has to move down, measured 685 to 660 Hz: phase 34 found Rubber Band's move of a made
        // vowel's lowest peak weak, while on speech it moved the first three formants by at least what Depth
        // asks (task d0bdaf13).
        for (resonance, was) in zip(Self.resonances, before).dropFirst() {
            let found = VowelFixtures.peak(of: voice, period: period, near: resonance * 0.9, within: 0.15)
            #expect(abs(found / was - 0.9) < 0.05, "the resonance of \(resonance) Hz went from \(was) to \(found) Hz")
        }
        let lowest = VowelFixtures.peak(of: voice, period: period, near: Self.resonances[0], within: 0.15)
        #expect(lowest < 0.99 * before[0], "the lowest resonance went from \(before[0]) to \(lowest) Hz")
    }

    // MARK: Length and sameness

    @Test(arguments: [1, 100, 480_000])
    func theVoiceIsExactlyAsLongAsTheRecording(count: Int) async throws {
        let recording = StretchFixtures.voice(period: 320, count: count)

        let voice = try await VoiceMaker.fast(recording, knobs: VoiceKnobs(depth: 6, pitch: -1))

        #expect(voice.count == count)
        #expect(voice.allSatisfy { $0.isFinite })
    }

    @Test func theSameRecordingGivesTheSameSamplesTwice() async throws {
        let recording = Self.vowel()
        let knobs = VoiceKnobs(depth: 10, pitch: -2)

        let first = try await VoiceMaker.fast(recording, knobs: knobs)
        let second = try await VoiceMaker.fast(recording, knobs: knobs)

        #expect(first == second)
        #expect(first != recording)
    }

    @Test func neutralKnobsGiveTheRecordingBackAsItWas() async throws {
        let recording = Self.vowel()

        let voice = try await VoiceMaker.fast(recording, knobs: .neutral)

        #expect(voice == recording)
    }

    @Test func silenceGivesSilence() async throws {
        let silence = [Float](repeating: 0, count: 48_000)

        let voice = try await VoiceMaker.fast(silence, knobs: VoiceKnobs(depth: 6, pitch: -1))

        #expect(voice.count == silence.count)
        #expect(voice.allSatisfy { $0 == 0 })
    }

    @Test func theDepthOfAKnobIsAFormantScale() {
        #expect(VoiceMaker.formantScale(of: VoiceKnobs(depth: 6, pitch: -1)) == 0.94)
        #expect(VoiceMaker.formantScale(of: VoiceKnobs(depth: -15)) == 1.15)
        #expect(VoiceMaker.formantScale(of: VoiceKnobs(pitch: 3)) == 1)
    }

    // MARK: Cancelled

    @Test func aTaskThatIsCancelledBeforeItStartsGivesUp() async {
        let recording = Self.vowel()

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VoiceMaker.fast(recording, knobs: VoiceKnobs(depth: 6, pitch: -1))
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aTaskThatIsCancelledWhileTheEngineWorksGivesUpAfterIt() async {
        // Ten seconds take the engine about 0.4 s, so the task is cancelled while it works, or before.
        let recording = StretchFixtures.voice(period: 320, count: 480_000)

        let task = Task { try await VoiceMaker.fast(recording, knobs: VoiceKnobs(depth: 6, pitch: -1)) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

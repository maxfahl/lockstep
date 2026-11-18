import Foundation
import Testing
@testable import LockstepAudio

/// What a double relies on: a shifted voice is as long as its source, starts where its source starts, is about as
/// loud, and is the same every time it is made.
@Suite struct VoiceShifterTests {
    /// The stretch tolerance in samples. A shift has to keep a place as well as a stretch does.
    private let tolerance = RubberBandStretcher.toleranceSeconds * 48_000

    /// The shifts the doubles use: an octave and a fourth down, an octave up, and the 9 cents of Thick both ways.
    private let shifts: [Double] = [-12, -5, 12, 0.09, -0.09]

    private func tone(_ frequency: Double, count: Int) -> [Float] {
        (0..<count).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
    }

    // MARK: Pitch

    @Test func aToneAnOctaveDownAndAFifthUpComesOutAtTheRightPitch() {
        let tone = tone(220, count: 48_000)

        let octaveDown = VoiceShifter.shift(tone, semitones: -12, formantScale: 1)
        let fifthUp = VoiceShifter.shift(tone, semitones: 7, formantScale: 1)

        // Measured by the period, away from the two ends: 109.998 Hz, and 329.6277 Hz for 329.6276.
        #expect(abs(StretchFixtures.frequency(of: octaveDown[4800..<43_200]) - 110) < 0.1)
        #expect(abs(StretchFixtures.frequency(of: fifthUp[4800..<43_200]) - 220 * pow(2, 7.0 / 12)) < 0.1)
    }

    @Test func nineCentsAreNineCents() {
        // Thick lives on a shift this small, so it has to be told apart from no shift at all: 9 cents up from
        // 220 Hz is 221.147 Hz, and down 218.859 Hz.
        let tone = tone(220, count: 48_000)

        let up = VoiceShifter.shift(tone, semitones: 0.09, formantScale: 1)
        let down = VoiceShifter.shift(tone, semitones: -0.09, formantScale: 1)

        // Measured: 221.14668 and 218.85926 Hz, each within 0.00002 Hz.
        #expect(abs(StretchFixtures.frequency(of: up[4800..<43_200]) - 220 * pow(2, 0.09 / 12)) < 0.05)
        #expect(abs(StretchFixtures.frequency(of: down[4800..<43_200]) - 220 * pow(2, -0.09 / 12)) < 0.05)
    }

    // MARK: Length and place

    @Test func theLengthIsTheSameForFiveMillisecondsAndForTenSeconds() {
        let voice = StretchFixtures.voice(period: 320, count: 481_000)
        for count in [240, 2400, 48_000, 480_000] {
            let piece = Array(voice[700..<(700 + count)])
            // The long one is made once: it takes the longest, and its length does not depend on the shift.
            for semitones in count == 480_000 ? [-5.0] : shifts {
                let result = VoiceShifter.shift(piece, semitones: semitones, formantScale: 1)

                #expect(result.count == count)
                #expect(result.allSatisfy { $0.isFinite })
            }
        }
    }

    @Test func aPieceOfAFewSamplesStillComesBack() {
        let voice = StretchFixtures.voice(period: 320, count: 6000)
        for count in [1, 2, 3, 48, 240] {
            let piece = Array(voice[700..<(700 + count)])
            let highest = piece.map { abs($0) }.max() ?? 0

            let result = VoiceShifter.shift(piece, semitones: -12, formantScale: 1)

            #expect(result.count == count)
            // Nothing runs away.
            #expect(result.allSatisfy { $0.isFinite && abs($0) <= 2 * highest + 0.01 })
        }
        #expect(VoiceShifter.shift([], semitones: -12, formantScale: 1).isEmpty)
    }

    @Test func aClickKeepsItsPlace() {
        // Faint noise with one click in it, as in the stretcher's own measurement.
        var noise = StretchFixtures.Random(state: 99)
        var sound = (0..<48_000).map { _ in Float((noise.next() * 2 - 1) * 0.001) }
        sound[24_000] = 0.8

        for semitones in shifts {
            let result = VoiceShifter.shift(sound, semitones: semitones, formantScale: 1)

            // Measured: 2.5 ms late at an octave down, 2.3 ms early at an octave up, 0.2 ms early at a fourth
            // down and 0.1 ms off at 9 cents. The tolerance is 8.6 ms.
            let found = StretchFixtures.peak(in: result, near: 24_000, search: 20_000)
            #expect(abs(Double(found - 24_000)) <= tolerance, "\(semitones) semitones: \(found - 24_000) samples off")
        }
    }

    @Test func theStartOfASyllableKeepsItsPlace() {
        // Three syllables of 200 ms that run together, at 120, 160 and 100 Hz. The second and the third start
        // inside the sound, where the engine has sound on both sides.
        let periods = [400, 300, 480]
        let run = periods.flatMap { StretchFixtures.syllable(period: $0, count: 9600) }

        for semitones in shifts {
            let result = VoiceShifter.shift(run, semitones: semitones, formantScale: 1)

            for (index, period) in periods.enumerated().dropFirst() {
                let place = index * 9600
                // One wave of the shifted voice is shorter or longer than one of the voice that went in.
                let shifted = Int((Double(period) / pow(2, semitones / 12)).rounded())
                // The measure is a little late on any sound, so it is taken on the sound that went in as well.
                // Measured: at most 2.9 ms late (the third syllable at a fourth down), 1.9 ms at 9 cents.
                let before = StretchFixtures.onset(in: run, near: place, period: period) - Double(place)
                let after = StretchFixtures.onset(in: result, near: place, period: shifted) - Double(place)
                #expect(
                    abs(after - before) <= tolerance,
                    "\(semitones) semitones, syllable \(index): \((after - before) / 48) ms off")
            }
        }
    }

    @Test func aBiggerAndASmallerVoiceKeepTheirPlaceToo() {
        let periods = [400, 300, 480]
        let run = periods.flatMap { StretchFixtures.syllable(period: $0, count: 9600) }

        for formantScale in [0.88, 1.12] {
            let result = VoiceShifter.shift(run, semitones: 0, formantScale: formantScale)

            #expect(result.count == run.count)
            for (index, period) in periods.enumerated().dropFirst() {
                let place = index * 9600
                let before = StretchFixtures.onset(in: run, near: place, period: period) - Double(place)
                let after = StretchFixtures.onset(in: result, near: place, period: period) - Double(place)
                // Measured: within 0.07 ms.
                #expect(abs(after - before) <= tolerance, "formants \(formantScale): \((after - before) / 48) ms off")
            }
        }
    }

    // MARK: Loudness

    @Test func theShiftedVoiceIsAboutAsLoudAsItWas() {
        for period in [533, 350, 218] {
            let voice = StretchFixtures.voice(period: period, count: 48_000)
            let loud = StretchFixtures.loudness(voice)
            let calls: [(semitones: Double, formantScale: Double)] = shifts.map { ($0, 1) } + [(0, 0.88), (0, 1.12)]
            for call in calls {
                let result = VoiceShifter.shift(voice, semitones: call.semitones, formantScale: call.formantScale)

                // The whole is turned to the loudness of what went in, so this measured 0.0000004 dB at most.
                // Before that was done an octave down came out 1.8 dB louder and an octave up 2.1 dB quieter.
                let change = 20 * log10(StretchFixtures.loudness(result) / loud)
                #expect(abs(change) < 1, "\(call), one wave of \(period) samples: \(change) dB")
                // The two ends are neither faded nor missing: their outer 20 ms measured between 0.61 and 1.18
                // of the same 20 ms of the voice.
                let start = StretchFixtures.loudness(result[..<960]) / StretchFixtures.loudness(voice[..<960])
                let end = StretchFixtures.loudness(result[47_040...]) / StretchFixtures.loudness(voice[47_040...])
                #expect((0.5...1.5).contains(start), "\(call), \(period): the start is \(start) of what it was")
                #expect((0.5...1.5).contains(end), "\(call), \(period): the end is \(end) of what it was")
            }
        }
    }

    // MARK: The same every time

    @Test func noShiftGivesBackWhatWentIn() {
        var random = StretchFixtures.Random(state: 5)
        let run = StretchFixtures.run(&random)

        #expect(VoiceShifter.shift(run.voiced, semitones: 0, formantScale: 1) == run.voiced)
    }

    @Test func twoCallsGiveTheSameSamples() {
        var random = StretchFixtures.Random(state: 7)
        let run = StretchFixtures.run(&random)

        let first = VoiceShifter.shift(run.voiced, semitones: -5, formantScale: 1)
        let second = VoiceShifter.shift(run.voiced, semitones: -5, formantScale: 1)

        #expect(first == second)
        #expect(first != run.voiced)
    }

    @Test func theSameCallGivesTheSameAnswerFromManyTasksAtOnce() async {
        var random = StretchFixtures.Random(state: 11)
        let voiced = StretchFixtures.run(&random).voiced
        let expected = VoiceShifter.shift(voiced, semitones: 12, formantScale: 0.88)

        let results = await withTaskGroup(of: [Float].self) { group in
            for _ in 0..<8 {
                group.addTask { VoiceShifter.shift(voiced, semitones: 12, formantScale: 0.88) }
            }
            var all: [[Float]] = []
            for await result in group { all.append(result) }
            return all
        }

        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == expected })
    }

    // MARK: The size of the voice

    /// A made-up vowel: a voice of 100 Hz whose throat rings at 700 Hz and at 2,400 Hz.
    private static let vowelPeriod = 480
    private static let vowelPeaks: [Double] = [700, 2400]

    private static func vowel(count: Int) -> [Float] {
        VowelFixtures.vowel(count: count, period: vowelPeriod, peaks: vowelPeaks)
    }

    private static func peak(of sound: [Float], period: Double, near expected: Double) -> Double {
        VowelFixtures.peak(of: sound, period: period, near: expected)
    }

    private static func period(of sound: [Float], near expected: Int) -> Double {
        VowelFixtures.period(of: sound, near: expected)
    }

    @Test func theMadeUpVowelRingsWhereItWasMadeToRing() {
        // The measure itself, on the vowel as it is made: measured 689 and 2,400 Hz. The lower peak leans on the
        // slope of the sound below it, so it is found a little under its 700 Hz.
        let vowel = Self.vowel(count: 48_000)

        for expected in Self.vowelPeaks {
            let found = Self.peak(of: vowel, period: Double(Self.vowelPeriod), near: expected)
            #expect(abs(found / expected - 1) < 0.02)
        }
        #expect(abs(Self.period(of: vowel, near: Self.vowelPeriod) - Double(Self.vowelPeriod)) < 0.01)
    }

    @Test func aLargerThroatMovesThePeaksOfAVowelDownAndASmallerOneUpWhileThePitchStays() {
        let vowel = Self.vowel(count: 48_000)
        let lowerBefore = Self.peak(of: vowel, period: Double(Self.vowelPeriod), near: 700)

        for formantScale in [0.88, 1.12] {
            let result = VoiceShifter.shift(vowel, semitones: 0, formantScale: formantScale)

            // The pitch: one wave is as long as it was. Measured within 0.0004 samples of 480.
            let period = Self.period(of: result, near: Self.vowelPeriod)
            #expect(abs(period - Double(Self.vowelPeriod)) < 0.01, "formants \(formantScale): one wave is \(period) samples")
            // The upper peak has moved by what was asked for: measured 0.867 and 1.144 of its 2,400 Hz.
            let upper = Self.peak(of: result, period: period, near: 2400 * formantScale)
            #expect(abs(upper / 2400 - formantScale) < 0.035, "formants \(formantScale): the upper peak is at \(upper) Hz")
            // The lower peak has moved the same way, and less far: measured 664 and 705 Hz, from 689. The
            // library moves an outline of the spectrum that is smoothed over about 650 Hz, and a peak this
            // sharp and this near the bottom mostly stays where the overtones are.
            let lower = Self.peak(of: result, period: period, near: 700)
            #expect(
                formantScale < 1 ? lower < 0.98 * lowerBefore : lower > 1.01 * lowerBefore,
                "formants \(formantScale): the lower peak is at \(lower) Hz, from \(lowerBefore) Hz")
        }
    }

    @Test func aLowerOrHigherVoiceKeepsItsUpperPeak() {
        // The formants kept: the pitch moves and the peak at 2,400 Hz stays. With the pitch alone it would be at
        // 1,798 Hz a fourth down and at 4,800 Hz an octave up. Measured: 2,417 and 2,321 Hz.
        // The lower peak is not kept as well, for the reason given in the test above: a fourth down it was
        // found at 532 Hz, near the 516 Hz the pitch alone would give.
        let vowel = Self.vowel(count: 48_000)

        for semitones in [-5.0, 12] {
            let result = VoiceShifter.shift(vowel, semitones: semitones, formantScale: 1)

            let wanted = Double(Self.vowelPeriod) / pow(2, semitones / 12)
            let period = Self.period(of: result, near: Int(wanted.rounded()))
            #expect(abs(period / wanted - 1) < 0.002, "\(semitones) semitones: one wave is \(period) samples, not \(wanted)")
            let upper = Self.peak(of: result, period: period, near: 2400)
            #expect(abs(upper / 2400 - 1) < 0.05, "\(semitones) semitones: the upper peak is at \(upper) Hz")
        }
    }
}

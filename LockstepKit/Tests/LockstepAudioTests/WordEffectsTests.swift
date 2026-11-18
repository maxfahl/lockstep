import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// The five effects on a word, each alone, on made-up sound. Nothing is played: every one is a function
/// from samples to samples.
@Suite struct WordEffectsTests {
    private typealias Fixtures = ChainFixtures

    /// One millisecond, in samples.
    private static let millisecond = 48

    // MARK: Made-up sound and measuring

    /// The beats of a song that speeds up, as samples of a clip's dry sound: the first lies before the
    /// sound, and each beat is 2 % shorter than the one before, from half a second.
    private static func driftingBeats(count: Int = 30) -> [Double] {
        var beats: [Double] = []
        var place = -4_000.0
        var length = 24_000.0
        for _ in 0..<count {
            beats.append(place)
            place += length
            length *= 0.98
        }
        return beats
    }

    /// Where a position counted in beats lies: 2.25 is a quarter of the way from the third beat to the fourth.
    private static func place(ofBeatPosition position: Double, in beats: [Double]) -> Int {
        let index = Int(position.rounded(.down))
        return Int((beats[index] + (position - Double(index)) * (beats[index + 1] - beats[index])).rounded())
    }

    /// Silence with a word in it: a 400 Hz tone of 100 ms that starts on `start`.
    private static func word(at start: Int, in count: Int) -> [Float] {
        var dry = [Float](repeating: 0, count: count)
        dry.replaceSubrange(start..<(start + 4_800), with: Fixtures.tone(hz: 400, db: -6, count: 4_800))
        return dry
    }

    /// `count` samples of a layer from sample `start` of the dry sound, silent where the layer is not.
    private static func part(of layer: WordEffects.Layer, from start: Int, count: Int) -> [Float] {
        (start..<(start + count)).map { index in
            layer.samples.indices.contains(index - layer.start) ? layer.samples[index - layer.start] : 0
        }
    }

    /// The first sample that is louder than a fiftieth of the loudest: where a sound that fades in starts.
    private static func onset(of samples: [Float]) -> Int? {
        let highest = samples.map(abs).max() ?? 0
        return samples.firstIndex { abs($0) > highest / 50 }
    }

    /// How loud a pure tone of `hz` is in a sound, in dB: only what swings at that pitch counts.
    private static func levelDb(of hz: Double, in samples: [Float]) -> Double {
        var sine = 0.0
        var cosine = 0.0
        for (index, sample) in samples.enumerated() {
            let angle = 2 * Double.pi * hz * Double(index) / Double(Fixtures.rate)
            sine += Double(sample) * sin(angle)
            cosine += Double(sample) * cos(angle)
        }
        let size = 2 * (sine * sine + cosine * cosine).squareRoot() / Double(samples.count)
        return 20 * log10(max(size, 1e-10))
    }

    /// The pitch of a tone in a stretch of samples, in Hz, from how often it passes zero.
    private static func pitch(of samples: ArraySlice<Float>) -> Double {
        let crossings = zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        return Double(crossings) / 2 / (Double(samples.count) / Double(Fixtures.rate))
    }

    // MARK: Echo

    @Test func everyQuarterNoteRepeatStartsOnItsBeatOfASongThatDriftsAndIsSixDecibelsQuieterThanTheOneBefore() {
        let beats = Self.driftingBeats()
        // The word starts on the third beat and is the last thing in the clip.
        let start = Self.place(ofBeatPosition: 2, in: beats)
        let dry = Self.word(at: start, in: start + 5_000)

        let layer = WordEffects.echo(
            of: dry, stretch: start..<(start + 4_800), note: .quarter, levelDb: -6, beats: beats)

        // -6, -12, … -36 dB: six repeats, one on each of the six beats after the word's.
        var loudness: [Double] = []
        for number in 1...6 {
            let onBeat = Self.place(ofBeatPosition: Double(2 + number), in: beats)
            let around = Self.part(of: layer, from: onBeat - 2_400, count: 9_600)
            let onset = try! #require(Self.onset(of: around))
            #expect(abs(onset - 2_400) <= Self.millisecond)
            loudness.append(Fixtures.loudnessDb(Self.part(of: layer, from: onBeat, count: 4_800)))
        }
        // The first is 6 dB under the word (which lost a little to its fades), and each one after it 6 dB
        // under the one before.
        var faded = Array(dry[start..<(start + 4_800)])
        EdgeFade.apply(480, to: &faded)
        #expect(abs(loudness[0] - (Fixtures.loudnessDb(faded) - 6)) < 0.3)
        for (one, next) in zip(loudness, loudness.dropFirst()) {
            #expect(abs(one - next - 6) < 0.3)
        }

        // It says how long it is: from the first repeat to the end of the last, far past the dry sound.
        #expect(abs(layer.start - Self.place(ofBeatPosition: 3, in: beats)) <= 1)
        #expect(abs(layer.end - (Self.place(ofBeatPosition: 8, in: beats) + 4_800)) <= 1)
        #expect(layer.end > dry.count + 100_000)
        // Nothing sounds between two repeats.
        let between = Self.place(ofBeatPosition: 3, in: beats) + 4_800 + 480
        #expect(Self.part(of: layer, from: between, count: 9_600).allSatisfy { abs($0) < 1e-4 })
    }

    @Test func eighthNoteRepeatsOfAWordBetweenTwoBeatsKeepItsPlaceBetweenTheBeats() {
        let beats = Self.driftingBeats()
        // A quarter of the way from the third beat to the fourth.
        let start = Self.place(ofBeatPosition: 2.25, in: beats)
        let dry = Self.word(at: start, in: start + 30_000)

        let layer = WordEffects.echo(
            of: dry, stretch: start..<(start + 4_800), note: .eighth, levelDb: -6, beats: beats)

        for number in 1...6 {
            let wanted = Self.place(ofBeatPosition: 2.25 + 0.5 * Double(number), in: beats)
            let around = Self.part(of: layer, from: wanted - 2_400, count: 9_600)
            let onset = try! #require(Self.onset(of: around))
            #expect(abs(onset - 2_400) <= Self.millisecond)
        }
        // The song speeds up, so the repeats come closer: one fixed delay time would walk off the beats.
        let first = Self.place(ofBeatPosition: 2.75, in: beats) - start
        let last = Self.place(ofBeatPosition: 5.25, in: beats) - Self.place(ofBeatPosition: 4.75, in: beats)
        #expect(first - last > 4 * Self.millisecond)
    }

    @Test func anEchoWhereTheSongHasNoBeatsIsNothing() {
        let dry = Self.word(at: 10_000, in: 30_000)

        let layer = WordEffects.echo(of: dry, stretch: 10_000..<14_800, note: .quarter, levelDb: -6, beats: [])

        #expect(layer.samples.isEmpty)
    }

    // MARK: Phone

    @Test func thePhoneLetsAlmostNothingThroughBelow200HertzAndAbove5Kilohertz() {
        // Five tones, all as loud: two below the phone's band, two inside it, one above.
        let pitches = [100.0, 200, 1_000, 2_000, 5_000]
        var dry = [Float](repeating: 0, count: 48_000)
        for hz in pitches {
            let tone = Fixtures.tone(hz: hz, db: -20, count: dry.count)
            for index in dry.indices { dry[index] += tone[index] }
        }

        let phone = WordEffects.phone(dry, stretch: 9_600..<38_400)

        #expect(phone.count == 28_800)
        // Measured over half a second from its middle, which holds every tone a whole number of times.
        let middle = Array(phone[2_400..<26_400])
        let inside = Self.levelDb(of: 1_000, in: middle)
        #expect(abs(Self.levelDb(of: 2_000, in: middle) - inside) < 2)
        #expect(Self.levelDb(of: 100, in: middle) < inside - 30)
        #expect(Self.levelDb(of: 200, in: middle) < inside - 30)
        #expect(Self.levelDb(of: 5_000, in: middle) < inside - 20)
    }

    @Test func thePhoneIsAsLoudAsTheStretchWas() {
        let dry = Fixtures.voice(count: 96_000)
        let stretch = 19_200..<52_800

        let phone = WordEffects.phone(dry, stretch: stretch)

        #expect(abs(Fixtures.loudnessDb(phone) - Fixtures.loudnessDb(dry[stretch])) < 0.1)
    }

    @Test func thePhoneHasALittleGrit() {
        // One tone in the middle of the band. What the phone adds to it are overtones.
        let dry = Fixtures.tone(hz: 800, db: -12, count: 48_000)

        let phone = WordEffects.phone(dry, stretch: 9_600..<38_400)

        let middle = Array(phone[2_400..<26_400])
        let overtone = Self.levelDb(of: 2_400, in: middle) - Self.levelDb(of: 800, in: middle)
        // A little: heard, and far from a fuzz. Measured: -24 dB, on a pure tone, which is bent the most:
        // every wave of it reaches the highest sample.
        #expect(overtone > -40)
        #expect(overtone < -20)
    }

    @Test func thePhoneDoesNotMoveTheVoice() {
        let dry = Fixtures.click(at: 20_000, count: 48_000)

        let phone = WordEffects.phone(dry, stretch: 9_600..<38_400)

        #expect(abs(Fixtures.peak(of: phone) - (20_000 - 9_600)) <= 1)
    }

    // MARK: Stutter

    @Test func stutterRepeatsStartOnTheSubBeatsAndTheResultIsAsLongAsTheStretch() {
        let beats = Self.driftingBeats()
        // Noise, so that every sample of the stretch can be told from every other.
        let dry = Fixtures.noise(count: 120_000, size: 0.5)
        // From the third beat to the fifth: eight sixteenths.
        let start = Self.place(ofBeatPosition: 2, in: beats)
        let stretch = start..<Self.place(ofBeatPosition: 4, in: beats)

        let stutter = WordEffects.stutter(dry, stretch: stretch, beats: beats, perBeat: 4)

        #expect(stutter.count == stretch.count)
        // On every sixteenth the start of the stretch is heard again. A repeat lies within a sample of the
        // sub-beat's own whole sample.
        for number in 0..<8 {
            let subBeat = Self.place(ofBeatPosition: 2 + Double(number) / 4, in: beats) - start
            let heard = (-1...1).contains { shift in
                (300..<3_000).allSatisfy { stutter[subBeat + shift + $0] == dry[start + $0] }
            }
            #expect(heard)
            // It fades in from next to nothing over 3 ms, so no repeat starts with a click.
            #expect(abs(stutter[subBeat + 1]) < 0.02)
            #expect((-1...1).contains { stutter[subBeat + $0 + 143] != dry[start + 143] })
        }
        // What was in the stretch after its first sixteenth is gone.
        let second = Self.place(ofBeatPosition: 2.25, in: beats) - start
        #expect(stutter[second + 300] != dry[start + second + 300])
    }

    @Test func aStutterInTripletsHasSixRepeatsToABeat() {
        let beats = Self.driftingBeats()
        let dry = Fixtures.noise(count: 120_000, size: 0.5)
        let start = Self.place(ofBeatPosition: 3, in: beats)
        let stretch = start..<Self.place(ofBeatPosition: 4, in: beats)

        let stutter = WordEffects.stutter(dry, stretch: stretch, beats: beats, perBeat: 6)

        for number in 0..<6 {
            let subBeat = Self.place(ofBeatPosition: 3 + Double(number) / 6, in: beats) - start
            let heard = (-1...1).contains { shift in
                (300..<2_000).allSatisfy { stutter[subBeat + shift + $0] == dry[start + $0] }
            }
            #expect(heard)
        }
    }

    @Test func aStutterWithoutBeatsRepeatsEvery125Milliseconds() {
        let dry = Fixtures.noise(count: 60_000, size: 0.5)

        let stutter = WordEffects.stutter(dry, stretch: 10_000..<30_000, beats: [], perBeat: 4)

        #expect(stutter.count == 20_000)
        for start in [0, 6_000, 12_000] {
            #expect((300..<5_700).allSatisfy { stutter[start + $0] == dry[10_000 + $0] })
        }
        // The last repeat is cut where the stretch ends.
        #expect((300..<1_700).allSatisfy { stutter[18_000 + $0] == dry[10_000 + $0] })
    }

    // MARK: Tape stop

    @Test func aTapeStopOfASteadyToneFallsInPitchEndsSilentAndIsAsLongAsTheStretch() {
        let dry = Fixtures.tone(hz: 440, db: -6, count: 72_000)
        let stretch = 12_000..<60_000

        let stopped = WordEffects.tapeStop(dry, stretch: stretch)

        #expect(stopped.count == 48_000)
        // It starts at full speed, on the very sample the stretch starts with.
        #expect(stopped[0] == dry[12_000])
        // The speed falls evenly, so a tenth of a second around each place holds the tone at that share of
        // its pitch: 95 %, 50 % and 25 %.
        #expect(abs(Self.pitch(of: stopped[0..<4_800]) - 440 * 0.95) < 12)
        #expect(abs(Self.pitch(of: stopped[21_600..<26_400]) - 440 * 0.5) < 12)
        #expect(abs(Self.pitch(of: stopped[33_600..<38_400]) - 440 * 0.25) < 12)
        // As loud as it was while it is heard as a tone, and silent where it stands still.
        #expect(abs(Fixtures.loudnessDb(stopped[21_600..<26_400]) - Fixtures.loudnessDb(dry[12_000..<16_800])) < 0.5)
        #expect(abs(stopped[47_999]) < 1e-4)
        #expect(stopped[47_520...].allSatisfy { abs($0) < 0.03 })
        #expect(Fixtures.loudnessDb(stopped[45_600...]) < Fixtures.loudnessDb(stopped[..<2_400]) - 15)
    }

    // MARK: Swell

    /// Silence with a made-up syllable that starts on `start`.
    private static func syllable(at start: Int, in count: Int) -> [Float] {
        var dry = [Float](repeating: 0, count: count)
        dry.replaceSubrange(start..<(start + 9_600), with: StretchFixtures.syllable(period: 218, count: 9_600))
        return dry
    }

    @Test func aSwellRisesAndEndsWhereTheStretchStartsOneBeatLong() {
        // Beats 400 ms apart, so one beat is not the 500 ms of a swell without beats.
        let beats = Fixtures.beats(every: 19_200)
        let dry = Self.syllable(at: 50_000, in: 72_000)
        let stretch = 50_000..<59_600

        let swell = WordEffects.swell(into: dry, stretch: stretch, levelDb: -8, beats: beats)

        #expect(swell.end == 50_000)
        #expect(swell.samples.count == 19_200)
        // It rises: from next to nothing, each quarter louder than the one before.
        #expect(abs(swell.samples[0]) < 0.001)
        let quarters = (0..<4).map { Fixtures.loudnessDb(swell.samples[($0 * 4_800)..<(($0 + 1) * 4_800)]) }
        for (one, next) in zip(quarters, quarters.dropFirst()) {
            #expect(next > one + 1)
        }
        #expect(quarters[3] > quarters[0] + 12)
        // Its loudest sample is as far under the word's loudest as its level says.
        let highest = Double(swell.samples.map(abs).max() ?? 0)
        let words = Double(dry[stretch].map(abs).max() ?? 0)
        #expect(abs(20 * log10(highest / words) + 8) < 0.1)
        // And it ends without a click: the last sample is next to nothing again.
        #expect(abs(swell.samples[19_199]) < 0.01)
    }

    @Test func aSwellWithoutBeatsIsHalfASecond() {
        let dry = Self.syllable(at: 50_000, in: 72_000)

        let swell = WordEffects.swell(into: dry, stretch: 50_000..<59_600, levelDb: -8, beats: [])

        #expect(swell.end == 50_000)
        #expect(swell.samples.count == 24_000)
    }

    @Test func aSwellNeverStartsBeforeTheDrySoundsFirstSample() {
        let beats = Fixtures.beats(every: 19_200)

        // A word a tenth of a second into the clip: the swell is only that long.
        let near = WordEffects.swell(
            into: Self.syllable(at: 4_800, in: 30_000), stretch: 4_800..<14_400, levelDb: -8, beats: beats)
        #expect(near.start == 0)
        #expect(near.end == 4_800)
        #expect(abs(near.samples[0]) < 0.001)

        // The clip's first word has no room for one.
        let first = WordEffects.swell(
            into: Self.syllable(at: 0, in: 30_000), stretch: 0..<9_600, levelDb: -8, beats: beats)
        #expect(first.samples.isEmpty)
        #expect(first.start == 0)
    }

    // MARK: All of them

    @Test func aReplacementIsExactlyAsLongAsItsStretch() {
        let beats = Self.driftingBeats()
        let dry = Fixtures.voice(count: 60_000)
        for stretch in [0..<60_000, 0..<1, 59_990..<60_000, 20_000..<20_333, 30_000..<30_000] {
            #expect(WordEffects.phone(dry, stretch: stretch).count == stretch.count)
            #expect(WordEffects.stutter(dry, stretch: stretch, beats: beats, perBeat: 4).count == stretch.count)
            #expect(WordEffects.tapeStop(dry, stretch: stretch).count == stretch.count)
        }
    }

    @Test func everyEffectGivesTheSameAnswerForTheSameInput() {
        let beats = Self.driftingBeats()
        let dry = Fixtures.voice(count: 96_000)
        let stretch = 36_000..<50_400

        #expect(WordEffects.phone(dry, stretch: stretch) == WordEffects.phone(dry, stretch: stretch))
        #expect(
            WordEffects.stutter(dry, stretch: stretch, beats: beats, perBeat: 6)
                == WordEffects.stutter(dry, stretch: stretch, beats: beats, perBeat: 6))
        #expect(WordEffects.tapeStop(dry, stretch: stretch) == WordEffects.tapeStop(dry, stretch: stretch))
        #expect(
            WordEffects.echo(of: dry, stretch: stretch, note: .eighth, levelDb: -6, beats: beats)
                == WordEffects.echo(of: dry, stretch: stretch, note: .eighth, levelDb: -6, beats: beats))
        #expect(
            WordEffects.swell(into: dry, stretch: stretch, levelDb: -8, beats: beats)
                == WordEffects.swell(into: dry, stretch: stretch, levelDb: -8, beats: beats))
    }
}

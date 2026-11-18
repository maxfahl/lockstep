import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// The parts of the voice chain that are our own code, each alone.
@Suite struct VoiceChainPartsTests {
    private typealias Fixtures = ChainFixtures

    // MARK: De-esser

    @Test func deEsserTurnsABurstOfNoiseAroundSevenKilohertzDown() {
        let hiss = Fixtures.stereo(Fixtures.hiss(count: 24_000, size: 0.3))

        let softer = DeEsser.render(hiss, parameters: .init(thresholdDb: -14, maxCutDb: 8))

        // Measured: 5.4 dB quieter. The band is turned down by 8 dB at its middle and by less at its edges.
        let change = Fixtures.loudnessDb(softer.left[2_400..<21_600]) - Fixtures.loudnessDb(hiss.left[2_400..<21_600])
        #expect(change < -4.5)
        #expect(change > -8.5)
    }

    @Test func deEsserLeavesALowToneAsLoudAsItWas() {
        let tone = Fixtures.stereo(Fixtures.tone(hz: 200, db: -6, count: 24_000))

        let same = DeEsser.render(tone, parameters: .init(thresholdDb: -14, maxCutDb: 8))

        // Not only as loud: the samples that went in.
        #expect(same == tone)
    }

    @Test func deEsserTurnsOnlyTheSharpPartOfAVoiceDown() {
        // A vowel, then an s straight after it.
        let vowel = StretchFixtures.voice(period: 218, count: 14_400)
        let sound = Fixtures.stereo(vowel + Fixtures.hiss(count: 9_600, size: 0.2))

        let softer = DeEsser.render(sound, parameters: .init(thresholdDb: -14, maxCutDb: 8))

        #expect(Array(softer.left[..<12_000]) == Array(sound.left[..<12_000]))
        let change = Fixtures.loudnessDb(softer.left[16_800..<21_600]) - Fixtures.loudnessDb(sound.left[16_800..<21_600])
        // Measured: 5.3 dB quieter.
        #expect(change < -4.5)
    }

    @Test func deEsserGivesLeftAndRightTheSameGain() {
        // The same s on both sides, twice as loud on the left.
        let hiss = Fixtures.hiss(count: 24_000, size: 0.2)
        let sound = StereoSound(left: hiss.map { $0 * 2 }, right: hiss)

        let softer = DeEsser.render(sound, parameters: .init(thresholdDb: -14, maxCutDb: 8))

        #expect(softer.left != sound.left)
        #expect(zip(softer.left, softer.right).allSatisfy { abs($0 - 2 * $1) < 1e-5 })
    }

    // MARK: Level rider

    @Test func riderTurnsAQuietEndingUpAndLeavesTheLoudPartAndThePause() {
        // A loud second, a second 12 dB quieter, a second of faint room noise.
        let loud = Fixtures.tone(hz: 300, db: -10, count: 48_000)
        let quiet = Fixtures.tone(hz: 300, db: -22, count: 48_000)
        let room = Fixtures.tone(hz: 300, db: -70, count: 48_000)
        let sound = Fixtures.stereo(loud + quiet + room)

        let ridden = LevelRider.render(sound, parameters: .init(maxGainDb: 6, speedMs: 100))

        func change(_ range: Range<Int>) -> Double {
            Fixtures.loudnessDb(ridden.left[range]) - Fixtures.loudnessDb(sound.left[range])
        }
        // Measured: 0.0, +6.0 and 0.0 dB.
        #expect(abs(change(12_000..<36_000)) < 0.3)
        #expect(abs(change(60_000..<84_000) - 6) < 0.3)
        #expect(abs(change(108_000..<132_000)) < 0.3)
        #expect(ridden.left == ridden.right)
    }

    @Test func riderGivesAWordThatLacksLittleOnlyWhatItLacks() {
        let sound = Fixtures.stereo(
            Fixtures.tone(hz: 300, db: -10, count: 48_000) + Fixtures.tone(hz: 300, db: -13, count: 48_000))

        let ridden = LevelRider.render(sound, parameters: .init(maxGainDb: 6, speedMs: 100))

        let change = Fixtures.loudnessDb(ridden.left[60_000..<84_000]) - Fixtures.loudnessDb(sound.left[60_000..<84_000])
        #expect(abs(change - 3) < 0.3)
    }

    @Test func riderWithNoReachChangesNothing() {
        let voice = Fixtures.stereo(Fixtures.voice(count: 48_000))

        #expect(LevelRider.render(voice, parameters: .init(maxGainDb: 0, speedMs: 300)) == voice)
    }

    // MARK: Squeezer

    @Test func squeezerLeavesOneDbOfEveryRatioDbOverTheThreshold() {
        let quiet = Fixtures.stereo(Fixtures.tone(hz: 300, db: -40, count: 48_000))
        let loud = Fixtures.stereo(Fixtures.tone(hz: 300, db: -4, count: 48_000))
        let parameters = ChainParameters.Squeeze(thresholdDb: -24, ratio: 4, attackMs: 3, releaseMs: 60, makeupDb: 0)

        let quietAfter = Squeezer.render(quiet, parameters: parameters)
        let loudAfter = Squeezer.render(loud, parameters: parameters)

        // Under the threshold nothing happens. 20 dB over it, 5 dB are left: the tone's highest sample comes
        // out near -19 dBFS (measured -18.2: the gain lets go a little between two waves).
        #expect(quietAfter == quiet)
        let highest = 20 * log10(Double(loudAfter.left[24_000...].map(abs).max() ?? 0))
        #expect(abs(highest + 19) < 1)
    }

    @Test func squeezerAtARatioOfOneOnlyAddsItsMakeUp() {
        let voice = Fixtures.stereo(Fixtures.voice(count: 48_000))
        let flat = ChainParameters.Squeeze(thresholdDb: -24, ratio: 1, attackMs: 3, releaseMs: 60, makeupDb: 0)
        var louder = flat
        louder.makeupDb = 6

        #expect(Squeezer.render(voice, parameters: flat) == voice)
        let after = Squeezer.render(voice, parameters: louder)
        #expect(abs(Fixtures.loudnessDb(after.left) - Fixtures.loudnessDb(voice.left) - 6) < 0.01)
    }

    @Test func squeezerLetsTheFirstSampleOfAClickThroughAndGivesBothSidesTheSameGain() {
        var left = [Float](repeating: 0, count: 4_800)
        left[1_000] = 0.9
        let right = left.map { $0 / 3 }
        let parameters = ChainParameters.Squeeze(thresholdDb: -30, ratio: 8, attackMs: 3, releaseMs: 60, makeupDb: 0)

        let after = Squeezer.render(StereoSound(left: left, right: right), parameters: parameters)

        #expect(Fixtures.peak(of: after.left) == 1_000)
        #expect(abs(after.left[1_000] - 3 * after.right[1_000]) < 1e-6)
    }

    // MARK: Echo

    @Test func repeatsOfAClickLandOnTheSamplesTheBeatsGive() {
        // A song that speeds up: every beat 300 samples shorter than the one before.
        var beats: [Double] = []
        var time = -30_000.0
        var length = 24_000.0
        for _ in 0..<30 {
            beats.append(time)
            time += length
            length -= 300
        }
        var click = [Float](repeating: 0, count: 2_400)
        click[0] = 0.5
        let source = Fixtures.stereo(click)
        var sound = Fixtures.stereo([Float](repeating: 0, count: 6 * 48_000))

        BeatEcho.add(repeatsOf: source, startingAt: 5_000, note: .quarter, levelDb: -6, beats: beats, to: &sound)

        let expected = EchoRepeats.repeats(ofSoundAt: 5_000, note: .quarter, levelDb: -6, beats: beats)
        #expect(expected.count == 6)
        for one in expected {
            let place = Int(one.position.rounded())
            let around = Array(sound.left[(place - 200)..<(place + 200)])
            #expect(Fixtures.peak(of: around) == 200, "repeat \(one.number)")
        }
        // Nothing where the source itself is: only its repeats are added.
        #expect(sound.left[5_000] == 0)
    }

    @Test func eachRepeatIsSixDbQuieterAndALittleDarkerThanTheOneBefore() {
        let low = Fixtures.stereo(Fixtures.tone(hz: 300, db: -12, count: 12_000))
        let high = Fixtures.stereo(Fixtures.tone(hz: 6_000, db: -12, count: 12_000))
        let beats = Fixtures.beats(every: 24_000)
        func levels(_ source: StereoSound) -> [Double] {
            var sound = Fixtures.stereo([Float](repeating: 0, count: 4 * 48_000))
            BeatEcho.add(repeatsOf: source, startingAt: 0, note: .quarter, levelDb: -6, beats: beats, to: &sound)
            return (1...6).map {
                Fixtures.loudnessDb(sound.left[($0 * 24_000 + 2_400)..<($0 * 24_000 + 9_600)])
                    - Fixtures.loudnessDb(source.left[2_400..<9_600])
            }
        }

        // A low tone keeps the level the repeats are given: -6, -12, … -36 dB.
        for (index, level) in levels(low).enumerated() {
            #expect(abs(level - (-6 - 6 * Double(index))) < 0.5, "repeat \(index + 1)")
        }
        // A high tone loses more with every repeat than those 6 dB.
        let highLevels = levels(high)
        #expect(zip(highLevels, highLevels.dropFirst()).allSatisfy { $1 < $0 - 8 })
    }

    @Test func whatWouldLieAfterTheEndOfTheSoundIsLeftOut() {
        let source = Fixtures.stereo(Fixtures.tone(hz: 300, db: -12, count: 12_000))
        var sound = Fixtures.stereo([Float](repeating: 0, count: 30_000))

        BeatEcho.add(
            repeatsOf: source, startingAt: 0, note: .quarter, levelDb: -6, beats: Fixtures.beats(every: 24_000),
            to: &sound)

        #expect(sound.left.count == 30_000)
        #expect(sound.left[24_100] != 0)
        #expect(BeatEcho.reach(startingAt: 0, note: .quarter, levelDb: -6, beats: Fixtures.beats(every: 24_000)) == 144_000)
    }

    // MARK: The tail's cut

    @Test func aTailIsCutWhereItHasFallenBelowMinusSixtyDbAndFaded() {
        // A second of sound, then a tail that falls by 60 dB a second from -20 dB.
        let kept = Fixtures.tone(hz: 300, db: -6, count: 48_000)
        let tail = (0..<144_000).map { Float(pow(10, (-20 - 60 * Double($0) / 48_000) / 20)) }
        let sound = Fixtures.stereo(kept + tail)

        let cut = SoundTail.cut(sound, after: 48_000)

        // -60 dB is reached two thirds of a second into the tail.
        #expect(abs(cut.left.count - (48_000 + 32_000)) <= 2)
        #expect(Array(cut.left[..<48_000]) == kept)
        // Before the fade it is the tail as it was, and the last sample is next to nothing.
        #expect(cut.left[48_000 + 20_000] == tail[20_000])
        #expect(abs(cut.left.last ?? 1) < 0.0001)
    }

    @Test func aSoundWithNothingAfterItIsNotTouched() {
        let voice = Fixtures.stereo(Fixtures.voice(count: 48_000))

        #expect(SoundTail.cut(voice, after: 48_000) == voice)
        // Silence after it is cut away altogether, and the sound itself is not faded.
        let padded = Fixtures.stereo(voice.left + [Float](repeating: 0, count: 9_600))
        #expect(SoundTail.cut(padded, after: 48_000) == voice)
    }
}

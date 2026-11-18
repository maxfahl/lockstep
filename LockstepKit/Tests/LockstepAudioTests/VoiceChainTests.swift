import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// The two promises of the steps that make a finished sound, and what the chain's parts do.
/// Everything is rendered offline: no test here opens a sound device.
@Suite struct VoiceChainTests {
    private typealias Fixtures = ChainFixtures

    /// Every built-in preset at its starting knobs, with every knob at 0 and with every knob at 100 %.
    private static let everySetting: [(name: String, parameters: ChainParameters)] =
        Fixtures.startingKnobs.flatMap { preset in
            [
                ("\(preset.character) at its start", Fixtures.parameters(preset.character, preset.knobs)),
                ("\(preset.character) at 0", Fixtures.parameters(preset.character, Fixtures.allAtZero)),
                ("\(preset.character) at 100", Fixtures.parameters(preset.character, Fixtures.allAtFull)),
            ]
        }

    // MARK: Nothing moves the voice

    @Test func clickKeepsItsSampleThroughEveryPresetAndEveryKnobPosition() {
        let click = Fixtures.stereo(Fixtures.click(at: 20_000, count: 48_000))
        let beats = Fixtures.beats(every: 22_000, first: -9_000)

        for setting in Self.everySetting {
            let finished = VoiceChain.render(click, parameters: setting.parameters, beats: beats)

            #expect(abs(Fixtures.peak(of: finished.left) - 20_000) <= 1, "\(setting.name), left")
            #expect(abs(Fixtures.peak(of: finished.right) - 20_000) <= 1, "\(setting.name), right")
        }
    }

    @Test func aToneThatLetsOnlyTheLowPartThroughIsMeasuredToDelayAndTheDelayIsTakenOut() {
        let phone = [ChainParameters.ToneBand(kind: .lowPass, hz: 3_400, gainDb: 0, q: 0.7)]
        var click = [Float](repeating: 0, count: 4_800)
        click[2_000] = 0.5

        // What the delay is, so that the next line is known to check something.
        #expect(VoiceChain.delayInSamples(of: phone) == 3)
        let toned = VoiceChain.tone(Fixtures.stereo(click), bands: phone)

        #expect(toned.left.count == click.count)
        #expect(Fixtures.peak(of: toned.left) == 2_000)
    }

    // MARK: The same answer every time

    @Test func theSameCallTwiceGivesTheSameSound() {
        let voice = Fixtures.stereo(Fixtures.voice(count: 96_000))
        let beats = Fixtures.beats(every: 22_000, first: -9_000)

        for setting in Self.everySetting {
            let first = VoiceChain.render(voice, parameters: setting.parameters, beats: beats)
            let second = VoiceChain.render(voice, parameters: setting.parameters, beats: beats)

            // Measured on 15 November 2026: the very same samples, for every setting.
            #expect(first.left.count == second.left.count, "\(setting.name)")
            #expect(Fixtures.differenceDb(first, second) < -60, "\(setting.name)")
        }
    }

    @Test func callsAtTheSameTimeOnManyThreadsGiveTheAnswerOfOneCall() async {
        let voice = Fixtures.stereo(Fixtures.voice(count: 96_000))
        let beats = Fixtures.beats(every: 22_000, first: -9_000)
        let parameters = Fixtures.parameters(.sungHook, Fixtures.allAtFull)
        let alone = VoiceChain.render(voice, parameters: parameters, beats: beats)

        let together = await withTaskGroup(of: StereoSound.self) { group in
            for _ in 0..<12 {
                group.addTask { VoiceChain.render(voice, parameters: parameters, beats: beats) }
            }
            var answers: [StereoSound] = []
            for await answer in group { answers.append(answer) }
            return answers
        }

        #expect(together.count == 12)
        #expect(together.allSatisfy { Fixtures.differenceDb($0, alone) < -60 })
    }

    @Test func silenceInGivesSilenceOutAndNoTail() {
        let silence = Fixtures.stereo([Float](repeating: 0, count: 48_000))
        let beats = Fixtures.beats(every: 22_000, first: -9_000)

        for setting in Self.everySetting {
            let finished = VoiceChain.render(silence, parameters: setting.parameters, beats: beats)

            #expect(finished.left.count == 48_000, "\(setting.name)")
            #expect(Fixtures.highest(finished) == 0, "\(setting.name)")
        }
    }

    // MARK: The parts

    @Test func withAllKnobsAtZeroOnlyTheLowCutAndTheDeEsserChangeTheVoice() {
        let voice = Fixtures.stereo(Fixtures.voice(count: 96_000))

        for preset in Fixtures.startingKnobs {
            let parameters = Fixtures.parameters(preset.character, Fixtures.allAtZero)
            let finished = VoiceChain.render(voice, parameters: parameters, beats: Fixtures.beats(every: 22_000))
            let expected = DeEsser.render(
                VoiceChain.lowCut(voice, hz: parameters.lowCutHz), parameters: parameters.deEss)

            #expect(finished == expected, "\(preset.character)")
            // And those two did something: it is not the voice that went in.
            #expect(finished != voice, "\(preset.character)")
        }
    }

    @Test func lowCutTakesRumbleAwayAndLeavesTheVoice() {
        let rumble = Fixtures.stereo(Fixtures.tone(hz: 30, db: -12, count: 48_000))
        let voice = Fixtures.stereo(Fixtures.tone(hz: 400, db: -12, count: 48_000))

        let cutRumble = VoiceChain.lowCut(rumble, hz: 90)
        let cutVoice = VoiceChain.lowCut(voice, hz: 90)

        // Measured: 30 Hz comes out 19 dB quieter, 400 Hz as loud as it was.
        #expect(Fixtures.loudnessDb(cutRumble.left[24_000...]) < Fixtures.loudnessDb(rumble.left[24_000...]) - 15)
        #expect(abs(Fixtures.loudnessDb(cutVoice.left[24_000...]) - Fixtures.loudnessDb(voice.left[24_000...])) < 0.2)
    }

    @Test func squeezeAtFullBringsAQuietAndALoudToneCloserThanAtZero() {
        let sound = Fixtures.stereo(
            Fixtures.tone(hz: 300, db: -30, count: 48_000) + Fixtures.tone(hz: 300, db: -6, count: 48_000))
        func apart(_ squeeze: Double) -> Double {
            let knobs = SoundKnobs(squeeze: squeeze, tone: 0, warmth: 0, space: 0)
            let finished = VoiceChain.render(sound, parameters: Fixtures.parameters(.rapLead, knobs), beats: [])
            return Fixtures.loudnessDb(finished.left[72_000..<96_000]) - Fixtures.loudnessDb(finished.left[24_000..<48_000])
        }

        // Measured: 24 dB apart as they went in, 8.5 dB apart at full Squeeze.
        #expect(abs(apart(0) - 24) < 0.5)
        #expect(apart(1) < 12)
        #expect(apart(0.5) < apart(0))
        #expect(apart(1) < apart(0.5))
    }

    @Test func toneLiftsAndCutsWhereItsBandsSay() {
        let bands = [
            ChainParameters.ToneBand(kind: .bell, hz: 300, gainDb: -3, q: 1),
            ChainParameters.ToneBand(kind: .bell, hz: 3_000, gainDb: 4, q: 1),
        ]
        func change(at hz: Double) -> Double {
            let tone = Fixtures.stereo(Fixtures.tone(hz: hz, db: -12, count: 48_000))
            let toned = VoiceChain.tone(tone, bands: bands)
            return Fixtures.loudnessDb(toned.left[24_000...]) - Fixtures.loudnessDb(tone.left[24_000...])
        }

        #expect(abs(change(at: 300) + 3) < 0.3)
        #expect(abs(change(at: 3_000) - 4) < 0.3)
        #expect(abs(change(at: 1_000)) < 0.8)
    }

    @Test func warmthAddsOvertonesAndHardlyChangesTheLoudness() {
        let tone = Fixtures.stereo(Fixtures.tone(hz: 500, db: -14, count: 48_000))

        let clean = VoiceChain.warmth(tone, amount: 0)
        let warm = VoiceChain.warmth(tone, amount: 1)

        #expect(clean == tone)
        // The clean tone has no overtones. The warm one has them, well under the tone itself: a soft kind.
        // Measured: the overtones are 14.8 dB under the tone, and the warm tone is 0.6 dB louder.
        let overtones = Fixtures.overtonesDb(of: warm.left[24_000...], beside: tone.left[24_000...])
        #expect(Fixtures.overtonesDb(of: clean.left[24_000...], beside: tone.left[24_000...]) < -100)
        #expect(overtones > -30)
        #expect(overtones < -10)
        #expect(abs(Fixtures.loudnessDb(warm.left[24_000...]) - Fixtures.loudnessDb(tone.left[24_000...])) < 1.5)
    }

    // MARK: The tail

    @Test func withoutReverbAndEchoThereIsNoTail() {
        let voice = Fixtures.stereo(Fixtures.voice(count: 48_000))
        let knobs = SoundKnobs(squeeze: 1, tone: 1, warmth: 1, space: 0)

        for preset in Fixtures.startingKnobs {
            let finished = VoiceChain.render(
                voice, parameters: Fixtures.parameters(preset.character, knobs), beats: Fixtures.beats(every: 22_000))

            #expect(finished.left.count == 48_000, "\(preset.character)")
            #expect(finished.left == finished.right, "\(preset.character)")
        }
    }

    @Test func theTailOfARoomIsAsLongAsTheRoomRingsAndEndsFaded() {
        // Loud to its last sample, so that every room still rings when the sound is over.
        let burst = Fixtures.stereo(Fixtures.noise(count: 24_000, size: 0.5))

        for (room, seconds) in [(ChainParameters.Reverb.Room.smallRoom, 0.6), (.plate, 2.0), (.largeHall, 3.0)] {
            let finished = VoiceChain.space(burst, reverb: .init(room: room, mix: 1), echo: nil, beats: [])
            let tail = finished.left.count - 24_000

            // Never longer than the room is given, and cut earlier only where it has fallen below -60 dB.
            #expect(tail > 9_600, "\(room)")
            #expect(tail <= Int(seconds * 48_000), "\(room)")
            if tail < Int(seconds * 48_000) {
                let justBeforeTheFade = finished.left[(finished.left.count - 2_400)...].first ?? 0
                #expect(abs(justBeforeTheFade) < 0.01, "\(room)")
            }
            // It ends in silence, and the voice is where it was.
            #expect(abs(finished.left.last ?? 1) < 0.0001, "\(room)")
            #expect(abs(finished.right.last ?? 1) < 0.0001, "\(room)")
            // The room is wide: left and right differ.
            #expect(finished.left != finished.right, "\(room)")
        }
    }

    @Test func aLargeHallRingsLongerThanASmallRoom() {
        let burst = Fixtures.stereo(Fixtures.noise(count: 24_000, size: 0.5))
        func tail(_ room: ChainParameters.Reverb.Room) -> Int {
            VoiceChain.space(burst, reverb: .init(room: room, mix: 1), echo: nil, beats: []).left.count - 24_000
        }

        // Measured: 0.6 s for the small room (all it is given), 3 s for the hall.
        #expect(tail(.smallRoom) < tail(.largeHall) - 48_000)
    }

    @Test func theVoiceItselfGoesThroughNeitherReverbNorEcho() {
        // Where the room and the echo have not answered yet, the samples are the voice's own.
        var click = [Float](repeating: 0, count: 48_000)
        click[100] = 0.5
        let sound = Fixtures.stereo(click)

        let finished = VoiceChain.space(
            sound, reverb: .init(room: .largeHall, mix: 1), echo: .init(note: .quarter, levelDb: -6),
            beats: Fixtures.beats(every: 24_000))

        #expect(Array(finished.left[..<300]) == Array(click[..<300]))
        #expect(Array(finished.right[..<300]) == Array(click[..<300]))
    }

    @Test func theTailOfAnEchoReachesItsLastRepeat() {
        // A quarter of a second of noise at the start of half a second, with a beat every half second.
        let burst = Fixtures.noise(count: 12_000, size: 0.5) + [Float](repeating: 0, count: 12_000)
        let beats = Fixtures.beats(every: 24_000)

        let finished = VoiceChain.space(
            Fixtures.stereo(burst), reverb: nil, echo: .init(note: .quarter, levelDb: -6), beats: beats)

        // Six repeats, the last one 3 s after the sound and a quarter of a second long.
        let tail = finished.left.count - 24_000
        #expect(tail > 6 * 24_000 - 12_000 - 480)
        #expect(tail <= 6 * 24_000 - 12_000)
        #expect(abs(finished.left.last ?? 1) < 0.0001)
        // Each repeat is there, quieter than the one before.
        let levels = (1...6).map { Fixtures.loudnessDb(finished.left[($0 * 24_000)..<($0 * 24_000 + 9_600)]) }
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $1 < $0 - 3 })
        // An echo alone is in the middle.
        #expect(finished.left == finished.right)
    }

    @Test func aTailIsNeverLongerThanSixSeconds() {
        // A slow song, a beat a second: the seventh repeat of a loud echo would start 7 s after the sound.
        let burst = Fixtures.noise(count: 48_000, size: 0.5)

        let finished = VoiceChain.space(
            Fixtures.stereo(burst), reverb: nil, echo: .init(note: .quarter, levelDb: 0),
            beats: Fixtures.beats(every: 48_000))

        // Six seconds, less the few last samples that happen to be below -60 dB.
        #expect(finished.left.count <= 48_000 + 6 * 48_000)
        #expect(finished.left.count > 48_000 + 6 * 48_000 - 480)
        #expect(abs(finished.left.last ?? 1) < 0.0001)
    }

    @Test func thereIsNoEchoWhereThereAreNoBeats() {
        let voice = Fixtures.stereo(Fixtures.voice(count: 48_000))

        let finished = VoiceChain.space(voice, reverb: nil, echo: .init(note: .eighth, levelDb: -6), beats: [])

        #expect(finished == voice)
    }
}

import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// Steps 2 to 6 of making a clip's finished sound. Everything is rendered offline.
@Suite struct FinishedSoundRendererTests {
    private typealias Fixtures = ChainFixtures

    private static func recipe(
        chain: ChainParameters? = nil,
        clipGainDb: Double = 0,
        effects: [ClipSoundRecipe.HeardEffect] = [],
        beats: [Double] = []
    ) -> ClipSoundRecipe {
        ClipSoundRecipe(
            dry: .init(segments: [], tightenedIDs: [], fadeSamples: 240, gainDb: 0),
            chain: chain, clipGainDb: clipGainDb, effects: effects, beats: beats)
    }

    @Test func withoutAChainTheFinishedSoundIsTheDrySoundInTheMiddle() {
        let dry = Fixtures.voice(count: 48_000)

        let finished = FinishedSoundRenderer.render(Self.recipe(), dry: dry)

        #expect(finished.left == dry)
        #expect(finished.right == dry)
    }

    @Test func withAChainItIsTheChainsAnswerForTheDrySoundAndTheRecipesBeats() {
        // Quiet enough to stay under the ceiling, so that step 6 changes nothing.
        let dry = Fixtures.voice(count: 48_000).map { $0 * 0.1 }
        let parameters = Fixtures.parameters(.sungLead, SoundKnobs(squeeze: 0.5, tone: 0.55, warmth: 0.15, space: 0.35))
        let beats = Fixtures.beats(every: 22_000, first: -9_000)

        let finished = FinishedSoundRenderer.render(Self.recipe(chain: parameters, beats: beats), dry: dry)

        let chained = VoiceChain.render(Fixtures.stereo(dry), parameters: parameters, beats: beats)
        #expect(Fixtures.highest(chained) < FinishedSoundRenderer.ceiling)
        #expect(finished == chained)
        // It has a tail, and the tail is what the answer is longer by.
        #expect(finished.left.count > dry.count)
    }

    @Test func theClipsOwnVolumeComesAfterTheChain() {
        let dry = Fixtures.voice(count: 48_000).map { $0 * 0.1 }
        let parameters = Fixtures.parameters(.rapLead, SoundKnobs(squeeze: 0.7, tone: 0.55, warmth: 0.35, space: 0.08))

        let plain = FinishedSoundRenderer.render(Self.recipe(chain: parameters), dry: dry)
        let quieter = FinishedSoundRenderer.render(Self.recipe(chain: parameters, clipGainDb: -6), dry: dry)

        // The same sound, 6 dB down: had the volume come before the chain, the squeeze would have answered
        // differently to it.
        #expect(quieter.left.count == plain.left.count)
        let gain = Float(pow(10, -6.0 / 20))
        #expect(zip(quieter.left, plain.left).allSatisfy { abs($0 - gain * $1) < 1e-6 })
        #expect(zip(quieter.right, plain.right).allSatisfy { abs($0 - gain * $1) < 1e-6 })
    }

    @Test func theCeilingHolds() {
        let dry = Fixtures.voice(count: 48_000)
        let ceiling = FinishedSoundRenderer.ceiling

        for setting in Fixtures.startingKnobs {
            let parameters = Fixtures.parameters(setting.character, Fixtures.allAtFull)
            let finished = FinishedSoundRenderer.render(
                Self.recipe(chain: parameters, clipGainDb: 12, beats: Fixtures.beats(every: 22_000)), dry: dry)

            #expect(Fixtures.highest(finished) <= ceiling + 1e-6, "\(setting.character)")
        }
        // Without a chain too, and then the highest sample is exactly on it.
        let loud = FinishedSoundRenderer.render(Self.recipe(clipGainDb: 12), dry: dry)
        #expect(abs(Fixtures.highest(loud) - ceiling) < 1e-6)
    }

    @Test func aSoundUnderTheCeilingIsOnlyAsLoudAsItsVolumeSays() {
        let dry = Fixtures.voice(count: 48_000).map { $0 * 0.2 }

        let louder = FinishedSoundRenderer.render(Self.recipe(clipGainDb: 6), dry: dry)

        let gain = Float(pow(10, 6.0 / 20))
        #expect(zip(louder.left, dry).allSatisfy { abs($0 - gain * $1) < 1e-6 })
        #expect(Fixtures.highest(louder) < FinishedSoundRenderer.ceiling)
    }

    @Test func aSoundOverTheCeilingIsTurnedDownAsAWholeAndNotShaped() {
        let dry = Fixtures.voice(count: 48_000)

        let loud = FinishedSoundRenderer.render(Self.recipe(clipGainDb: 12), dry: dry)

        // Every sample by the same amount: it is still the dry sound, only quieter than asked for.
        let gain = FinishedSoundRenderer.ceiling / (dry.map(abs).max() ?? 1)
        #expect(zip(loud.left, dry).allSatisfy { abs($0 - gain * $1) < 1e-6 })
    }

    @Test func everyKindOfEffectIsHeard() {
        let dry = Fixtures.voice(count: 48_000).map { $0 * 0.1 }
        let beats = Fixtures.beats(every: 22_000, first: -9_000)

        for kind in ClipEffect.Kind.allCases {
            let effect = ClipSoundRecipe.HeardEffect(id: UUID(), kind: kind, levelDb: -6, span: 19_200..<28_800)
            let finished = FinishedSoundRenderer.render(
                Self.recipe(effects: [effect], beats: beats), dry: dry, layers: DoubleLayerStore())

            // No kind is skipped: each changes the sound, and none shortens it.
            #expect(finished.left.count >= dry.count, "\(kind)")
            #expect(finished.left.prefix(dry.count) != dry[...], "\(kind)")
        }
    }

    /// How strong one pitch is in a stretch of a sound: the size of a sine of that pitch in it, by Goertzel.
    private static func size(ofHz hz: Double, in sound: ArraySlice<Float>) -> Double {
        let step = 2 * Double.pi * hz / Lockstep.sampleRate
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in sound.enumerated() {
            real += Double(sample) * cos(step * Double(index))
            imaginary += Double(sample) * sin(step * Double(index))
        }
        return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(max(sound.count, 1))
    }

    @Test func aLowDoubleOnAStretchIsHeardThereAndTheLibraryRunsOnce() {
        // A held note at 220 Hz with overtones, two seconds long. It has nothing at 110 Hz.
        let dry = (0..<96_000).map { index -> Float in
            let time = Double(index) / Lockstep.sampleRate
            return Float((1...6).reduce(0.0) { $0 + sin(2 * .pi * 220 * Double($1) * time) / Double($1) } * 0.15)
        }
        let span = 24_000..<60_000
        let store = DoubleLayerStore()
        func recipe(levelDb: Double) -> ClipSoundRecipe {
            Self.recipe(effects: [.init(id: UUID(), kind: .lowOctave, levelDb: levelDb, span: span)])
        }

        let finished = FinishedSoundRenderer.render(recipe(levelDb: -10), dry: dry, layers: store)

        // Inside the stretch there is a voice an octave below, which the note alone does not have. It is
        // measured over half a second in the middle of the stretch, a whole number of its periods, away from
        // where the layer fades in and out. The layer is as loud as the note less 10 dB as a whole, and its
        // lowest pitch is a part of that.
        let inside = 28_800..<52_800
        let low = Self.size(ofHz: 110, in: finished.left[inside])
        #expect(low > 0.15 * pow(10, -24.0 / 20))
        #expect(low < 0.15 * pow(10, -10.0 / 20))
        #expect(Self.size(ofHz: 110, in: dry[inside]) < low / 100)
        // In the middle, so the same on both sides.
        #expect(finished.left == finished.right)
        // Outside the stretch nothing was added: the very samples of the dry sound, and no tail.
        #expect(finished.left.count == dry.count)
        #expect(Array(finished.left[..<span.lowerBound]) == Array(dry[..<span.lowerBound]))
        #expect(Array(finished.left[span.upperBound...]) == Array(dry[span.upperBound...]))
        // The layer comes in from nothing and goes out to nothing.
        #expect(finished.left[span.lowerBound] == dry[span.lowerBound])
        #expect(finished.left[span.upperBound - 1] == dry[span.upperBound - 1])
        // The voice itself is where it was: what was added is the layer alone, so taking the dry sound away
        // leaves nothing of the note's own pitch that the layer would not have by itself, and the finished
        // sound still follows the dry one sample for sample.
        let added = zip(finished.left[inside], dry[inside]).map { $0 - $1 }
        let together = zip(finished.left[inside], dry[inside]).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let dryEnergy = dry[inside].reduce(0.0) { $0 + Double($1) * Double($1) }
        let finishedEnergy = finished.left[inside].reduce(0.0) { $0 + Double($1) * Double($1) }
        #expect(together / (dryEnergy * finishedEnergy).squareRoot() > 0.9)
        #expect(Self.size(ofHz: 110, in: added[...]) > 0.9 * low)

        // Made again, and made at another level: the stretching library is not run again.
        #expect(store.madeCount == 1)
        let again = FinishedSoundRenderer.render(recipe(levelDb: -10), dry: dry, layers: store)
        let louder = FinishedSoundRenderer.render(recipe(levelDb: -4), dry: dry, layers: store)
        #expect(store.madeCount == 1)
        #expect(again == finished)
        let lowLouder = Self.size(ofHz: 110, in: louder.left[inside])
        #expect(abs(20 * log10(lowLouder / low) - 6) < 0.1)
        // Another stretch is another layer.
        _ = FinishedSoundRenderer.render(
            Self.recipe(effects: [.init(id: UUID(), kind: .lowOctave, levelDb: -10, span: 24_000..<48_000)]),
            dry: dry, layers: store)
        #expect(store.madeCount == 2)
    }

    @Test func anEchoOnAClipsLastWordRingsAfterTheClipOnTheGridAndTheTailHoldsItsLastRepeat() {
        // A clip of one second that ends with a word: a 220 Hz tone over its last 200 ms. The song speeds
        // up by 2 % a beat, and its first beat lies before the clip, as the recipe hands the beats over.
        let count = 48_000
        let word = 38_400..<count
        var dry = [Float](repeating: 0, count: count)
        dry.replaceSubrange(word, with: Fixtures.tone(hz: 220, db: -6, count: word.count))
        var beats: [Double] = []
        var beat = -9_000.0
        var length = 20_000.0
        for _ in 0..<30 {
            beats.append(beat)
            beat += length
            length *= 0.98
        }
        let recipe = Self.recipe(
            effects: [.init(id: UUID(), kind: .echoQuarter, levelDb: -6, span: word)], beats: beats)

        let finished = FinishedSoundRenderer.render(recipe, dry: dry)

        // Where the grid puts each repeat, by plain arithmetic: the word lies a share of the way from one
        // beat to the next, and repeat k lies that share of the way from the beat k later to the one after.
        let before = beats.lastIndex { $0 <= Double(word.lowerBound) } ?? 0
        let share = (Double(word.lowerBound) - beats[before]) / (beats[before + 1] - beats[before])
        let places = (1...6).map { number in
            Int((beats[before + number] + share * (beats[before + number + 1] - beats[before + number])).rounded())
        }
        // The voice itself is the dry sound's own samples, in the middle: every repeat lies after the clip.
        #expect(Array(finished.left[..<count]) == dry)
        #expect(finished.left == finished.right)
        #expect(places.allSatisfy { $0 >= count })
        var loudness: [Double] = []
        for (index, place) in places.enumerated() {
            // Silence from the end of what came before to this repeat, and the repeat starts on its place
            // within a millisecond: the first sample that is heard at all.
            let quietFrom = index == 0 ? count : places[index - 1] + word.count
            let started = finished.left[quietFrom...].firstIndex { abs($0) > 1e-5 }
            #expect(started.map { abs($0 - place) <= 48 } == true)
            loudness.append(Fixtures.loudnessDb(finished.left[place..<(place + word.count - 2_400)]))
        }
        // Each repeat is 6 dB under the one before, and the first 6 dB under the word.
        #expect(abs(loudness[0] - (Fixtures.loudnessDb(dry[word.lowerBound..<(word.upperBound - 2_400)]) - 6)) < 0.5)
        #expect(zip(loudness, loudness.dropFirst()).allSatisfy { abs($0 - $1 - 6) < 0.5 })
        // The tail holds the last repeat, which starts more than two seconds after the clip's end: the sound
        // ends where that repeat has faded out, not sooner and not a repeat later.
        let lastEnd = places[5] + word.count
        #expect(finished.left.count <= lastEnd)
        #expect(finished.left.count > lastEnd - 480)
    }

    @Test func aPhoneOnAStretchLeavesTheVoiceOutsideTheStretchAsItWas() {
        let dry = Fixtures.voice(count: 48_000).map { $0 * 0.1 }
        let span = 12_000..<30_000
        let recipe = Self.recipe(effects: [.init(id: UUID(), kind: .phone, levelDb: 0, span: span)])

        let finished = FinishedSoundRenderer.render(recipe, dry: dry)

        // As long as the dry sound, in the middle, and outside the stretch the very samples it had.
        #expect(finished.left.count == dry.count)
        #expect(finished.left == finished.right)
        #expect(Array(finished.left[..<span.lowerBound]) == Array(dry[..<span.lowerBound]))
        #expect(Array(finished.left[span.upperBound...]) == Array(dry[span.upperBound...]))
        // Inside it, past the 5 ms crossfade at each end, the phone's own answer.
        let phone = WordEffects.phone(dry, stretch: span)
        let inside = (span.lowerBound + 240)..<(span.upperBound - 240)
        #expect(Array(finished.left[inside]) == Array(phone[240..<(span.count - 240)]))
        #expect(Array(finished.left[inside]) != Array(dry[inside]))
        // The crossfade: at the stretch's first and last sample the voice is still almost all there.
        #expect(abs(finished.left[span.lowerBound] - dry[span.lowerBound]) < 0.01 * Fixtures.highest(Fixtures.stereo(dry)))
        #expect(abs(finished.left[span.upperBound - 1] - dry[span.upperBound - 1]) < 0.01 * Fixtures.highest(Fixtures.stereo(dry)))
    }

    @Test func anEmptyDrySoundGivesAnEmptySound() {
        let parameters = Fixtures.parameters(.sungHook, Fixtures.allAtFull)

        let finished = FinishedSoundRenderer.render(Self.recipe(chain: parameters), dry: [])

        #expect(finished.left.isEmpty)
        #expect(finished.right.isEmpty)
    }
}

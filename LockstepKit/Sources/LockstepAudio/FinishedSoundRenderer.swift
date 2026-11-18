import Accelerate
import Foundation
import LockstepCore

/// Makes a clip's finished sound from its dry sound: the one function playing and sending both get their
/// samples from, so what is played and what is sent cannot differ.
///
/// Making a finished sound takes six steps. The dry sound is step 1 (`ClipDry.render`). This is
/// steps 2 to 6:
///
/// 2. Effects that change the voice itself, on their stretch of it (phone, stutter, tape stop: phase 35).
/// 3. Layers added beside the voice (the doubles of phase 34, the echo and the swell on a word of phase 35).
/// 4. The mix to stereo, the voice in the middle.
/// 5. The voice chain of the track's Sound, where the track has one.
/// 6. The clip's own volume, then the ceiling.
///
///     let finished = FinishedSoundRenderer.render(recipe, dry: dry)
///     // finished.left.count - dry.count is the tail: what rings after the clip
///
/// It may be called from any thread, several calls at a time. The one thing kept between calls is the
/// copies of the voice that doubles are made of (`DoubleLayerStore`), so the stretching library is not run
/// again when only a knob or a level changed. The same recipe and the same dry sound give the same samples.
public enum FinishedSoundRenderer {
    /// No sample of a finished sound is larger than this: -1 dBFS.
    public static let ceiling = Float(pow(10, -1.0 / 20))
    /// The crossfade at both ends of a stretch whose voice was replaced, in samples: 5 ms.
    static let replacementFade = EdgeFade.samples(milliseconds: 5)

    /// - Parameter layers: where the copies of the voice that doubles are made of are kept. Left out, the
    ///   one store the app shares.
    public static func render(
        _ recipe: ClipSoundRecipe,
        dry: [Float],
        layers: DoubleLayerStore = .shared
    ) -> StereoSound {
        // Steps 2 to 4.
        let voice = voiceWithReplacements(dry, recipe: recipe)
        var sound = StereoSound(left: voice, right: voice)
        addLayers(to: &sound, from: dry, recipe: recipe, store: layers)

        // Step 5.
        if let chain = recipe.chain {
            // The chain takes the voice with its layers as the sound, and adds what its room rings after
            // the last of them.
            sound = VoiceChain.render(sound, parameters: chain, beats: recipe.beats)
        } else {
            // Without a chain, a layer that reaches past the clip's end is the only tail there can be. It
            // is kept to its end however long it is: an echo's last repeat was asked for.
            sound = SoundTail.cut(sound, after: dry.count, longest: sound.left.count)
        }

        // Step 6.
        return underCeiling(sound, gainDb: recipe.clipGainDb)
    }

    /// Step 2: the dry sound with every effect that changes the voice itself applied to its stretch, in the
    /// order of the recipe's list: phone, stutter and tape stop (`WordEffects`).
    ///
    /// Each is made from the voice as the effects before it left it, so a phone over a stutter is a
    /// stuttering phone. What comes back from `WordEffects` is as long as the stretch and is laid over it
    /// with a 5 ms crossfade at both ends, inside the stretch, so no sample outside the stretch changes. An
    /// effect on the whole clip has the whole dry sound as its stretch.
    static func voiceWithReplacements(_ dry: [Float], recipe: ClipSoundRecipe) -> [Float] {
        recipe.effects.reduce(dry) { voice, effect in
            let stretch = (effect.span ?? 0..<voice.count).clamped(to: 0..<voice.count)
            guard !stretch.isEmpty else { return voice }
            let replacement: [Float]
            switch effect.kind {
            case .phone:
                replacement = WordEffects.phone(voice, stretch: stretch)
            case .stutter:
                replacement = WordEffects.stutter(voice, stretch: stretch, beats: recipe.beats, perBeat: recipe.perBeat)
            case .tapeStop:
                replacement = WordEffects.tapeStop(voice, stretch: stretch)
            case .thick, .lowFourth, .lowOctave, .high, .big, .small, .echoQuarter, .echoEighth, .swell:
                // A layer: step 3.
                return voice
            }
            return laying(replacement, over: stretch, of: voice)
        }
    }

    /// The voice with a stretch of it replaced: the replacement comes in over the stretch's first 5 ms and
    /// the voice comes back over its last 5 ms. A stretch shorter than the two fades is faded over half of
    /// itself each way. A replacement that is not as long as its stretch changes nothing.
    static func laying(_ replacement: [Float], over stretch: Range<Int>, of voice: [Float]) -> [Float] {
        guard replacement.count == stretch.count else { return voice }
        var voice = voice
        let fade = min(replacementFade, stretch.count / 2)
        for index in replacement.indices {
            let place = stretch.lowerBound + index
            // How much of the replacement is heard here: all of it between the two fades.
            var share: Float = 1
            if index < fade {
                share = Float(index + 1) / Float(fade + 1)
            } else if index >= replacement.count - fade {
                share = Float(replacement.count - index) / Float(fade + 1)
            }
            voice[place] = replacement[index] * share + voice[place] * (1 - share)
        }
        return voice
    }

    /// Steps 3 and 4: adds every layer of the recipe's effects to the sound, each made from its stretch of the
    /// dry sound of step 1 and put where its kind says: in the middle, or out to one side. A layer may make
    /// the sound longer than the dry sound, never start before it.
    ///
    /// The doubles are copies of the voice (`addDouble`). The echo and the swell on a word are made by
    /// `WordEffects`, which hands each over as loud as its level says, with the sample it starts on.
    static func addLayers(
        to sound: inout StereoSound,
        from dry: [Float],
        recipe: ClipSoundRecipe,
        store: DoubleLayerStore
    ) {
        for effect in recipe.effects {
            let stretch = (effect.span ?? 0..<dry.count).clamped(to: 0..<dry.count)
            let levelDb = ClipEffect.level(clamped: effect.levelDb)
            switch effect.kind {
            case .thick, .lowFourth, .lowOctave, .high, .big, .small:
                addDouble(effect, to: &sound, from: dry, recipe: recipe, store: store)
            case .echoQuarter, .echoEighth:
                let note: ChainParameters.Echo.Note = effect.kind == .echoQuarter ? .quarter : .eighth
                add(
                    WordEffects.echo(of: dry, stretch: stretch, note: note, levelDb: levelDb, beats: recipe.beats),
                    to: &sound)
            case .swell:
                add(WordEffects.swell(into: dry, stretch: stretch, levelDb: levelDb, beats: recipe.beats), to: &sound)
            case .phone, .stutter, .tapeStop:
                // Changes the voice itself: step 2.
                continue
            }
        }
    }

    /// Adds a layer of an effect on a word in the middle, where it says it starts. The sound is made longer
    /// where the layer reaches past its end, which an echo's repeats do: that is the tail.
    static func add(_ layer: WordEffects.Layer, to sound: inout StereoSound) {
        guard !layer.samples.isEmpty, layer.start >= 0 else { return }
        if layer.end > sound.left.count {
            sound.left.append(contentsOf: repeatElement(0, count: layer.end - sound.left.count))
            sound.right.append(contentsOf: repeatElement(0, count: layer.end - sound.right.count))
        }
        let place = layer.start..<layer.end
        sound.left.replaceSubrange(place, with: vDSP.add(layer.samples, sound.left[place]))
        sound.right.replaceSubrange(place, with: vDSP.add(layer.samples, sound.right[place]))
    }

    /// Adds one double: for each layer of its kind, the effect's stretch of the dry sound made higher, lower,
    /// bigger or smaller (`VoiceShifter`, through the store), faded at both ends when it is on a stretch,
    /// moved later by the layer's delay and added on the layer's side at the effect's level.
    ///
    /// The fade is `DoubleLayers.fadeMs` at each end, so a double on a word comes in and goes out without a
    /// click. A double on the whole clip is not faded: the dry sound it is made from already is, at the
    /// clip's own edges. A stretch shorter than two fades is faded over half of itself each way.
    static func addDouble(
        _ effect: ClipSoundRecipe.HeardEffect,
        to sound: inout StereoSound,
        from dry: [Float],
        recipe: ClipSoundRecipe,
        store: DoubleLayerStore
    ) {
        let plan = DoubleLayers.plan(for: effect.kind)
        let span = (effect.span ?? 0..<dry.count).clamped(to: 0..<dry.count)
        guard !plan.isEmpty, !span.isEmpty else { return }
        let copies = store.copies(of: effect.kind, on: span, ofDry: recipe.dry, samples: dry.count) {
            let source = Array(dry[span])
            return plan.map { VoiceShifter.shift(source, semitones: $0.pitchSemitones, formantScale: $0.formantScale) }
        }
        let level = Float(pow(10, ClipEffect.level(clamped: effect.levelDb) / 20))
        let fade = effect.span == nil
            ? 0
            : min(Int((DoubleLayers.fadeMs * Lockstep.sampleRate / 1_000).rounded()), span.count / 2)
        for (layer, copy) in zip(plan, copies) {
            let start = span.lowerBound + max(layer.delaySamples, 0)
            let end = start + copy.count
            if end > sound.left.count {
                // A delayed layer rings a little past the clip's end: the tail.
                sound.left.append(contentsOf: repeatElement(0, count: end - sound.left.count))
                sound.right.append(contentsOf: repeatElement(0, count: end - sound.right.count))
            }
            for index in copy.indices {
                var sample = copy[index] * level
                if index < fade {
                    sample *= Float(index) / Float(fade)
                } else if index >= copy.count - fade {
                    sample *= Float(copy.count - 1 - index) / Float(fade)
                }
                // Step 4: the voice is in the middle, and so is every layer but the two of Thick.
                if layer.side != .right { sound.left[start + index] += sample }
                if layer.side != .left { sound.right[start + index] += sample }
            }
        }
    }

    /// Step 6: the sound with the clip's own volume, turned down as a whole where its highest sample would
    /// pass the ceiling. There is no limiter: nothing is shaped, the whole sound is only made quieter.
    static func underCeiling(_ sound: StereoSound, gainDb: Double) -> StereoSound {
        var gain = Float(pow(10, gainDb / 20))
        let highest = max(vDSP.maximumMagnitude(sound.left), vDSP.maximumMagnitude(sound.right))
        if highest * gain > ceiling {
            gain = ceiling / highest
        }
        guard gain != 1 else { return sound }
        return StereoSound(left: vDSP.multiply(gain, sound.left), right: vDSP.multiply(gain, sound.right))
    }
}

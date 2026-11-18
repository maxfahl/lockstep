import Accelerate
import AVFoundation
import Foundation
import LockstepCore

/// The five effects on a word, as sound: echo, phone, stutter, tape stop and swell.
///
/// Each is a function from samples to samples. It is handed a clip's dry sound and a stretch of it (a range
/// of its samples: the word), and the ones that follow the song also get the beats as samples of the dry
/// sound. `FinishedSoundRenderer` calls them in steps 2 and 3 of making a clip's finished sound.
///
/// Two of them are layers, sounds added beside the voice. They answer with a `Layer`: its samples and the
/// sample of the dry sound it starts on, already as loud as its level says.
///
///     let echo = WordEffects.echo(of: dry, stretch: word, note: .eighth, levelDb: -6, beats: recipe.beats)
///     // echo.end is where its last repeat ends, past the end of the dry sound: the tail has to cover it
///     let swell = WordEffects.swell(into: dry, stretch: word, levelDb: -8, beats: recipe.beats)
///     // swell.end == word.lowerBound, and swell.start is never below 0
///
/// Three replace the voice on the stretch. They answer with exactly as many samples as the stretch has, to
/// be laid over it (the renderer crossfades 5 ms at both ends):
///
///     let phone = WordEffects.phone(dry, stretch: word)
///     let stutter = WordEffects.stutter(dry, stretch: word, beats: recipe.beats, perBeat: recipe.perBeat)
///     let stopped = WordEffects.tapeStop(dry, stretch: word)
///
/// A stretch that reaches outside the dry sound counts only as far as the dry sound goes. None of them moves
/// the voice: what a replacement keeps of the word stays on its sample. Every one gives the same samples for
/// the same input, keeps nothing between calls and may be called from any thread. Only the swell uses a
/// unit of the system (the reverb), in an engine that has no sound device, as the voice chain does. Nothing
/// here can be heard.
enum WordEffects {
    /// A sound added beside the voice.
    struct Layer: Sendable, Equatable {
        /// The sample of the dry sound its first sample lies on. Never below 0.
        var start: Int
        /// Its samples, in the middle (the same on both sides), as loud as they are to be added.
        var samples: [Float]

        /// The sample of the dry sound after its last. Past the end of the dry sound for an echo that rings
        /// on after the clip.
        var end: Int { start + samples.count }
    }

    // MARK: Echo

    /// The fade at both ends of the word an echo repeats, in samples: 10 ms.
    static let echoFade = EdgeFade.samples(milliseconds: 10)

    /// The echo of a word: the stretch repeated on quarter or eighth notes of the song's own beats.
    ///
    /// The word is not in the layer, only its repeats: the first as loud as `levelDb` says against the word,
    /// each one after it 6 dB quieter and a little darker, each placed by the beats (`EchoRepeats`), so they
    /// stay on the grid where the tempo drifts. A word between two beats keeps its place between them.
    ///
    /// The layer starts where the first repeat starts and ends where the last one ends, which is after the
    /// end of the stretch and may be far after the end of the dry sound. Where the song has no beats there
    /// are no repeats, and the layer is empty.
    static func echo(
        of dry: [Float],
        stretch: Range<Int>,
        note: ChainParameters.Echo.Note,
        levelDb: Double,
        beats: [Double]
    ) -> Layer {
        let stretch = stretch.clamped(to: 0..<dry.count)
        let repeats = BeatEcho.repeats(startingAt: stretch.lowerBound, note: note, levelDb: levelDb, beats: beats)
        guard !stretch.isEmpty, let first = repeats.first, let last = repeats.last else {
            return Layer(start: stretch.upperBound, samples: [])
        }
        var word = Array(dry[stretch])
        EdgeFade.apply(echoFade, to: &word)

        // `BeatEcho` lays the repeats into a sound that has room for them, at their places in the dry sound.
        let silence = [Float](repeating: 0, count: last.sample + word.count)
        var sound = StereoSound(left: silence, right: silence)
        BeatEcho.add(
            repeatsOf: StereoSound(left: word, right: word), startingAt: stretch.lowerBound,
            note: note, levelDb: levelDb, beats: beats, to: &sound)
        return Layer(start: first.sample, samples: Array(sound.left[first.sample...]))
    }

    // MARK: Phone

    /// What a phone lets through, in Hz.
    static let phoneBand = 350.0...3_400.0
    /// How hard the voice is pushed into the soft clip that gives the grit: its highest sample is put at
    /// this on the clip's curve, where it is bent down by about 2.4 dB. The usual sample of a voice is a
    /// quarter as large and is hardly bent at all, so the grit is on the loud moments only. A starting
    /// value for Max's ear.
    static let phoneGritPush: Float = 1
    /// How much of the dry sound before and after the stretch the filters are run over, in samples: 100 ms.
    /// They start at rest, and this way they have settled where the stretch starts and ends.
    static let phoneMargin = Int(0.1 * Lockstep.sampleRate)
    /// The most the phone is turned up to be as loud as the stretch was: 12 dB. A stretch that holds almost
    /// nothing a phone lets through stays quiet.
    static let phoneMostGain: Float = 4

    /// The stretch as through a phone: only 350 Hz to 3.4 kHz gets through, with a little soft grit, as loud
    /// as the stretch was.
    ///
    /// The band's edges are steep (48 dB an octave) and flat between them, and the filters are run forwards
    /// and backwards, so nothing in the voice is moved in time. The grit is a soft clip between cutting the
    /// low and cutting the high, so the overtones it makes stay inside the band.
    ///
    /// - Returns: as many samples as the stretch has.
    static func phone(_ dry: [Float], stretch: Range<Int>) -> [Float] {
        let stretch = stretch.clamped(to: 0..<dry.count)
        guard !stretch.isEmpty else { return [] }
        let around = max(stretch.lowerBound - phoneMargin, 0)..<min(stretch.upperBound + phoneMargin, dry.count)
        let inside = (stretch.lowerBound - around.lowerBound)..<(stretch.upperBound - around.lowerBound)

        var sound = Array(dry[around])
        for q in VoiceFilter.steepQs {
            sound = VoiceFilter.highPass(hz: phoneBand.lowerBound, q: q).filteredBothWays(sound)
        }
        sound = softClipped(sound, highest: vDSP.maximumMagnitude(sound[inside]))
        for q in VoiceFilter.steepQs {
            sound = VoiceFilter.lowPass(hz: phoneBand.upperBound, q: q).filteredBothWays(sound)
        }

        let phone = Array(sound[inside])
        let was = vDSP.rootMeanSquare(dry[stretch])
        let now = vDSP.rootMeanSquare(phone)
        guard was > 0, now > 0 else { return phone }
        return vDSP.multiply(min(was / now, phoneMostGain), phone)
    }

    /// The sound through a soft clip (the tanh curve): small samples stay as they are, large ones are bent
    /// towards a ceiling. `highest` is the size of the largest sample that counts, so that a quiet word and
    /// a loud one get the same grit.
    ///
    /// It is measured against the highest sample and not the usual one, because a stretch may be mostly
    /// silence with one short sound in it. Measured against the usual size, that sound would be pushed far
    /// over the ceiling, and a click came out 9 samples from its place (measured on 16 November 2026).
    private static func softClipped(_ sound: [Float], highest: Float) -> [Float] {
        guard highest > 0 else { return sound }
        let push = phoneGritPush / highest
        return vDSP.multiply(1 / push, vForce.tanh(vDSP.multiply(push, sound)))
    }

    // MARK: Stutter

    /// The fade at both ends of the piece a stutter repeats, in samples: 3 ms.
    static let stutterFade = EdgeFade.samples(milliseconds: 3)

    /// The stretch as a stutter: its first sub-beat's length, repeated on every sub-beat until the stretch
    /// ends. Which piece and where each repeat starts is `StutterPlan`'s answer, read from the beats; without
    /// beats the pieces are 125 ms. Every repeat is the same piece with a 3 ms fade at both ends, cut short
    /// where the next repeat or the end of the stretch comes first.
    ///
    /// - Parameter perBeat: the clip's sub-beats per beat: 4 in sixteenths, 6 in triplets.
    /// - Returns: as many samples as the stretch has.
    static func stutter(_ dry: [Float], stretch: Range<Int>, beats: [Double], perBeat: Int) -> [Float] {
        let stretch = stretch.clamped(to: 0..<dry.count)
        var answer = [Float](repeating: 0, count: stretch.count)
        for one in StutterPlan(stretch: stretch, beats: beats, perBeat: perBeat).repeats where one.length > 0 {
            var piece = Array(dry[stretch.lowerBound..<(stretch.lowerBound + one.length)])
            EdgeFade.apply(stutterFade, to: &piece)
            let place = one.start - stretch.lowerBound
            answer.replaceSubrange(place..<(place + one.length), with: piece)
        }
        return answer
    }

    // MARK: Tape stop

    /// Below this share of full speed the level falls with the speed, down to nothing at a standstill, as
    /// the sound of a real tape does. Above it the stretch is as loud as it was.
    static let tapeQuietSpeed = 0.2

    /// The stretch as a tape that is stopped: read slower and slower, evenly from full speed on its first
    /// sample to a standstill on its last, so the pitch falls with the speed. It ends in silence where the
    /// stretch ends.
    ///
    /// At an even slowing the tape gets through half of the stretch before it stands still: the second half
    /// of the word is never heard. Sample t of the answer is read at t − t²/2N of the stretch (N its length),
    /// from between the samples around that place.
    ///
    /// - Returns: as many samples as the stretch has.
    static func tapeStop(_ dry: [Float], stretch: Range<Int>) -> [Float] {
        let stretch = stretch.clamped(to: 0..<dry.count)
        let count = stretch.count
        guard count > 1 else { return Array(dry[stretch]) }

        // What is read: the first half of the stretch, with one sample before it and two after it for
        // reading between samples. Outside the dry sound that is silence.
        let read = (stretch.lowerBound - 1)..<(stretch.lowerBound + count / 2 + 3)
        var tape = [Double](repeating: 0, count: read.count)
        let there = read.clamped(to: 0..<dry.count)
        tape.replaceSubrange(
            (there.lowerBound - read.lowerBound)..<(there.upperBound - read.lowerBound),
            with: vDSP.floatToDouble(dry[there]))

        // Where each sample of the answer is read on that tape, and how fast the tape runs there.
        let time = vDSP.ramp(withInitialValue: 0.0, increment: 1.0, count: count)
        let slowing = 1 / (2 * Double(count))
        let places = vDSP.add(1, vDSP.subtract(time, vDSP.multiply(slowing, vDSP.square(time))))
        var answer = [Double](repeating: 0, count: count)
        vDSP_vqintD(tape, places, 1, &answer, 1, vDSP_Length(count), vDSP_Length(tape.count))

        // The level: full down to the quiet speed, then falling with the speed.
        let fall = -1 / (Double(count) * tapeQuietSpeed)
        let level = vDSP.clip(
            vDSP.ramp(withInitialValue: 1 / tapeQuietSpeed, increment: fall, count: count), to: 0...1)
        return vDSP.doubleToFloat(vDSP.multiply(answer, level))
    }

    // MARK: Swell

    /// How long a swell is where the song has no beats, in samples: 500 ms.
    static let swellWithoutBeats = Int(0.5 * Lockstep.sampleRate)
    /// A swell is brought up from silence over this share of its length: its first quarter.
    static let swellFadeInShare = 4
    /// The fade at the end of a swell, in samples: 5 ms, so that it does not end with a click on the word.
    static let swellEndFade = EdgeFade.samples(milliseconds: 5)
    /// The most of a stretch a swell is made from, in samples: its first 3 seconds. The room rings 2 seconds,
    /// so what lies later in the stretch is not heard before the stretch starts.
    static let swellMostSource = Int(3 * Lockstep.sampleRate)

    /// A rise into a word: a layer that ends where the stretch starts.
    ///
    /// The stretch is turned round, sent through the plate of the voice chain (the room's answer alone), and
    /// what the room rings after it is turned round again: the room's answer to the word's start, heard
    /// before the word and growing into it. It is one beat long by the beats around the stretch's start
    /// (500 ms where the song has no beats there), shorter where the stretch starts sooner than that after
    /// the dry sound's first sample, and nothing when the stretch starts on it. It comes up from silence over
    /// its first quarter, rises as the room's ring does and ends with a 5 ms fade. The plate's ring falls
    /// fast: a half-second swell of a made-up voice rose by about 30 dB over its last 400 ms (measured on
    /// 16 November 2026), so most of what is heard of it is its last quarter of a second.
    ///
    /// - Parameter levelDb: how loud the swell's loudest sample is against the stretch's loudest sample.
    static func swell(into dry: [Float], stretch: Range<Int>, levelDb: Double, beats: [Double]) -> Layer {
        let stretch = stretch.clamped(to: 0..<dry.count)
        let nothing = Layer(start: stretch.lowerBound, samples: [])
        let beat = EchoRepeats.beatLength(at: Double(stretch.lowerBound), in: beats).map { Int($0.rounded()) }
        let length = min(beat ?? swellWithoutBeats, stretch.lowerBound)
        guard length > 0, !stretch.isEmpty else { return nothing }

        var word = Array(dry[stretch].prefix(swellMostSource))
        let loudest = vDSP.maximumMagnitude(word)
        vDSP.reverse(&word)
        let unit = AVAudioUnitReverb()
        let rung = OfflineUnits.render(StereoSound(left: word, right: word), through: [unit], extra: length) {
            unit.loadFactoryPreset(VoiceChain.preset(of: .plate))
            unit.wetDryMix = 100
        }
        guard let rung, rung.left.count == word.count + length else { return nothing }

        // What the room rings after the turned word has ended, turned round: it ends where the word starts.
        var rise = Array(LevelFollower.middle(of: rung)[word.count...])
        vDSP.reverse(&rise)
        // The room has not rung out after one beat, so the swell would start in the middle of its ring: it
        // is brought up from silence over its first quarter. After that the rise is the room's own ring.
        let fadeIn = max(length / swellFadeInShare, 1)
        let up = vDSP.ramp(withInitialValue: Float(0), increment: 1 / Float(fadeIn), count: fadeIn)
        rise.replaceSubrange(..<fadeIn, with: vDSP.multiply(rise[..<fadeIn], up))
        // Only the fade at the end: the swell is handed over as the second half of a piece twice as long.
        EdgeFade.apply(swellEndFade, to: &rise, at: length, ofSegmentWithLength: 2 * length)

        let highest = vDSP.maximumMagnitude(rise)
        guard highest > 0, loudest > 0 else { return nothing }
        let gain = loudest * Float(pow(10, levelDb / 20)) / highest
        return Layer(start: stretch.lowerBound - length, samples: vDSP.multiply(gain, rise))
    }
}

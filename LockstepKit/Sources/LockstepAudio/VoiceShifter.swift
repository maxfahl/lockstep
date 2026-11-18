import CRubberBand
import Foundation

/// Makes a voice higher or lower, and its throat larger or smaller, without changing its length or its timing,
/// with Rubber Band. The doubles of a clip are made with it.
///
/// It uses the library's finer engine ("R3") in its offline mode, as `RubberBandStretcher` does: mono,
/// 48,000 Hz, the whole piece in and the whole result out, with no stretch at all.
///
///     let low = VoiceShifter.shift(word, semitones: -12, formantScale: 1)     // an octave down, the same person
///     let big = VoiceShifter.shift(word, semitones: 0, formantScale: 0.88)    // the same note, a larger throat
///
/// Nothing is held between calls. Every call makes an engine of its own and frees it, so calls can run on
/// several threads at once, and the same call always gives the same answer.
public enum VoiceShifter {
    /// The sound of `samples`, `semitones` higher (lower when negative), exactly as long as it was.
    ///
    /// `formantScale` is the size of the voice. At 1 the peaks of the voice's spectrum (the formants, which the
    /// throat and the mouth make) stay where they are whatever the pitch does, so it is still the same person.
    /// Below 1 they are moved down by that factor, which sounds like a larger throat, and above 1 up.
    ///
    /// What comes back, as measured on 15 November 2026:
    /// - As many samples as went in, and not delayed: the engine throws its own start delay away, and the
    ///   piece is cut out of what it wrote by where it lay in what the engine was given. The start of a
    ///   syllable was found at most 2.9 ms from where it was, and a click at most 2.5 ms, at an octave and a
    ///   fourth down, an octave up and 9 cents either way. That is inside `RubberBandStretcher.toleranceSeconds`.
    /// - The pitch asked for: a tone of 220 Hz came out within 0.002 Hz of it, also for a shift of 9 cents.
    /// - As loud as what went in, as a whole (see `asLoud`). The outer 20 ms of a piece came out between 0.61
    ///   and 1.18 of their loudness.
    /// - Any length from one sample up. Ten seconds take about 0.4 s to make.
    /// - With `semitones` 0 and `formantScale` 1, the very samples that went in. No engine is made.
    /// - An empty piece gives an empty piece. Values that are not numbers, or a `formantScale` that is not
    ///   above 0, give the piece back as it was.
    ///
    /// How well the formants are placed is the library's own doing. It moves an outline of the spectrum that
    /// is smoothed over about 650 Hz. A peak of a made-up vowel at 2,400 Hz was kept within 4 percent through
    /// an octave up, and moved to 0.87 and 1.14 of its place for a `formantScale` of 0.88 and 1.12. A sharp
    /// peak at 700 Hz is too near the bottom for that outline: it went most of the way down with the pitch,
    /// and moved only 4 percent down and 2 percent up for 0.88 and 1.12.
    public static func shift(_ samples: [Float], semitones: Double, formantScale: Double) -> [Float] {
        guard !samples.isEmpty, semitones.isFinite, formantScale.isFinite, formantScale > 0,
            semitones != 0 || formantScale != 1, RubberBandStretcher.engineIsSetUp
        else { return samples }
        let pitchScale = pow(2, semitones / 12)

        // The sound as the engine gets it: the piece, with itself mirrored before its start and after its end,
        // as for a stretch. So the engine's first and last windows are full of sound like the piece itself, the
        // two ends come out about as loud as the rest, and a piece of a few milliseconds is still a voice.
        let leadIn = StretchPlan.leadIn
        var sound = [Float](repeating: 0, count: leadIn + samples.count + tail)
        for index in sound.indices {
            sound[index] = samples[RubberBandStretcher.mirrored(index - leadIn, in: samples.count)]
        }

        guard let engine = rubberband_new(UInt32(StretchPlan.rate), 1, options, 1.0, pitchScale) else { return samples }
        defer { rubberband_delete(engine) }
        // The library counts the formants' move from where the new pitch alone would put them: at 1 they go
        // along with the pitch. So keeping them where they were is one over the pitch scale, and the size of
        // the voice comes on top of that.
        rubberband_set_formant_scale(engine, formantScale / pitchScale)
        rubberband_set_max_process_size(engine, UInt32(block))

        let wanted = leadIn + samples.count
        var collected = [Float](repeating: 0, count: wanted + StretchPlan.window)
        var have = 0
        sound.withUnsafeBufferPointer { input in
            collected.withUnsafeMutableBufferPointer { output in
                guard let inputBase = input.baseAddress, let outputBase = output.baseAddress else { return }
                // The offline mode takes two passes. The first only tells the engine how long the sound is.
                var whole: UnsafePointer<Float>? = inputBase
                rubberband_study(engine, &whole, UInt32(input.count), 1)

                var handed = 0
                while have < wanted, handed < input.count {
                    let count = min(block, input.count - handed)
                    var channel: UnsafePointer<Float>? = inputBase + handed
                    handed += count
                    rubberband_process(engine, &channel, UInt32(count), handed == input.count ? 1 : 0)
                    var available = Int(rubberband_available(engine))
                    while available > 0, have < output.count {
                        var target: UnsafeMutablePointer<Float>? = outputBase + have
                        let got = Int(rubberband_retrieve(engine, &target, UInt32(min(available, output.count - have))))
                        guard got > 0 else { break }
                        have += got
                        available = Int(rubberband_available(engine))
                    }
                }
            }
        }
        // The engine writes as much as it was given, so the piece lies in what it wrote where it lay in what it
        // was given: right after the mirrored start. Should the engine ever write less, the rest is silence.
        assert(have >= wanted, "Rubber Band wrote \(wanted - have) samples too few")
        return asLoud(Array(collected[leadIn..<wanted]), as: samples)
    }

    /// `result` turned up or down as a whole until it is as loud as `samples`.
    ///
    /// The engine keeps the peaks of the voice's spectrum as high as they were. A lower voice has its overtones
    /// closer together, so more of them lie under the same peaks and it comes out louder, and a higher voice
    /// quieter: measured 1.8 dB up at an octave down and 2.1 dB down at an octave up. A double has a level of
    /// its own that is counted from the voice it was made from, so that is taken out here. The gain is one
    /// number for the whole piece, and never more than 6 dB either way, so a piece the engine wrote next to
    /// nothing for is not blown up.
    private static func asLoud(_ result: [Float], as samples: [Float]) -> [Float] {
        func energy(_ sound: [Float]) -> Double { sound.reduce(0) { $0 + Double($1) * Double($1) } }
        let (before, after) = (energy(samples), energy(result))
        guard before > 0, after > 0 else { return result }
        let gain = Float(min(max((before / after).squareRoot(), 0.5), 2))
        return result.map { $0 * gain }
    }

    /// The finer engine, not live, with the formants worked out and put back where they are told to be.
    /// Without this option the library ignores the formant scale.
    private static let options = RubberBandOptions(
        RubberBandOptionProcessOffline.rawValue | RubberBandOptionEngineFiner.rawValue
            | RubberBandOptionFormantPreserved.rawValue)

    /// How much mirrored sound the engine gets after the piece: enough for its last windows over the piece to
    /// be full, and for it to have written the whole piece before the sound runs out.
    private static let tail = 2 * StretchPlan.window

    /// How much sound the engine is handed at a time, in samples.
    private static let block = 1024
}

import Foundation
import LockstepCore

/// Why a voice could not be made.
public enum VoiceMakerError: Error, Equatable, Sendable {
    /// Rubber Band could not be started on this Mac, so the recording would come back unchanged.
    case engineMissing
}

/// Makes a recording again with a track's two knobs: the same recording with a deeper or lighter
/// voice.
///
///     let darker = try await VoiceMaker.fast(recording, knobs: VoiceKnobs(depth: 6, pitch: -1))
///     let kept = try await VoiceFile.takeIn(MadeVoice(darker), for: job)   // checked, then kept on disk
///
/// The Fast way is Rubber Band, the engine of the doubles, through `VoiceShifter.shift(_:semitones:formantScale:)`:
/// Pitch is the semitones, and Depth moves the formants by `1 - depth / 100`. The first gate of phase 37 chose
/// it over WORLD on 16 November 2026 (task d0bdaf13): it kept every syllable where it was on every made-up
/// line and every setting, came closest to the recording, and took 0.04 s of work for a second of voice.
///
/// What comes back:
/// - As many samples as went in, with each sample where the recording's is.
/// - The same samples every time, on any thread, several calls at once: nothing is held between calls.
/// - Neutral knobs give the very samples that went in, without running the engine.
///
/// It never runs on the caller's actor, so the main actor is never held up. Rubber Band makes the whole voice
/// in one call, which cannot be stopped halfway: a task that is cancelled gives up before that call and right
/// after it, and a minute of voice takes about 2.5 seconds in that call.
public enum VoiceMaker {
    /// The Fast voice of `samples` (a recording, mono at 48,000 Hz) with these knobs.
    ///
    /// - Throws: `CancellationError` when its task is cancelled, and `VoiceMakerError.engineMissing` when
    ///   Rubber Band cannot be started, so a recording is never handed back as if it were its voice.
    @concurrent
    public static func fast(_ samples: [Float], knobs: VoiceKnobs) async throws -> [Float] {
        if knobs.isNeutral { return samples }
        try Task.checkCancellation()
        guard RubberBandStretcher.engineIsSetUp else { throw VoiceMakerError.engineMissing }

        let voice = VoiceShifter.shift(samples, semitones: knobs.pitch, formantScale: formantScale(of: knobs))

        try Task.checkCancellation()
        return voice
    }

    /// How far Depth moves the formants: at Depth 8 every one sits 8 % lower, so the factor is 0.92. Negative
    /// Depth moves them up. Whoever changes this changes the sound of every Fast voice, and raises
    /// `VoiceWay.fast`'s revision.
    public static func formantScale(of knobs: VoiceKnobs) -> Double {
        1 - Double(knobs.depth) / 100
    }
}

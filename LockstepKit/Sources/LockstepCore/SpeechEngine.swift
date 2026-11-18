/// Something that writes out the words spoken in a stretch of sound.
///
/// The real one is in `LockstepSpeech` (the package `LockstepSpeechKit`) and runs whisper.cpp with
/// the speech model of the chosen language. Everything in LockstepCore that needs words goes through
/// this protocol, so its tests can use a stand-in and never need a model or whisper.cpp.
/// Phase 17.
public protocol SpeechEngine: Sendable {
    /// The words spoken in `samples16k`, which is one channel of sound at exactly 16,000 samples
    /// a second (not Lockstep's usual 48,000: the model was trained on 16,000).
    ///
    /// Loads the model first when it is not loaded. Silence and no samples give empty text.
    /// One call at a time: the real engine throws when a second one arrives while it is busy.
    func text(for samples16k: [Float]) async throws -> String

    /// Frees the model's memory. The next `text(for:)` loads it again.
    ///
    /// Call it when there is nothing left to write out, and before the app quits.
    func unload() async throws
}

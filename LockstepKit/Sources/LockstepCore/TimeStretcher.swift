/// Something that makes a piece of sound longer or shorter without changing how high it sounds.
///
/// Moving a single syllable inside a line means stretching or squeezing the sound next to it, wherever the
/// syllables run together with no pause between them. `LineRenderer.quantized` hands exactly those pieces to a
/// stretcher and builds everything else itself. The real stretcher lives in `LockstepAudio`, because it needs
/// a library. This file only says what it has to do, so the code here never depends on the library.
///
///     let stretched = stretcher.stretch(run, keyFrames: [(source: 4_800, target: 5_280)], outputLength: run.count)
///     // sample 4,800 of `run` is now heard on sample 5,280, and the piece is as long as it was
///
/// What a stretcher promises:
/// - It returns exactly `outputLength` samples. `LineRenderer.quantized` gives the line up, and leaves it as it
///   was recorded, when that is not so.
/// - The first sample of `samples` is heard at the start of the answer and the last at its end, and the sample
///   at each key frame's `source` is heard at its `target`. Between two of those points the sound is made
///   evenly longer or shorter. How close a real stretcher gets is its tolerance, a few milliseconds.
/// - The answer is not delayed. Where the sound between two points keeps its length, it lies where the map
///   says, sample on sample, and sounds like the original. The first and last 10 ms of every answer are faded
///   into the original sound, which only works when the two lie on each other.
/// - The voice is as high and as loud as it was. Nothing is faded in or out and nothing is made louder.
/// - Any length from one sample up works, for the sound and for the answer. A piece can be a few
///   milliseconds long.
/// - The same call gives the same answer, and it may be made from any thread, several at a time.
///
/// What a stretcher is promised:
/// - `samples` is mono sound at 48,000 Hz and is not empty, and `outputLength` is at least 1.
/// - Every key frame has `0 < source < samples.count` and `0 < target < outputLength`. From one key frame to
///   the next both numbers rise. The start and the end of the piece are not listed, because they always hold.
///   There may be no key frame at all: the whole piece is then stretched evenly.
/// - Between two neighbouring points the answer is never more than `1 + p` times as long as the sound nor
///   shorter than `1 / (1 + p)` times it, where `p` is the stretch limit of the settings, 40 % at most.
public protocol TimeStretcher: Sendable {
    /// The same sound, `outputLength` samples long, with each key frame's `source` sample on its `target`.
    func stretch(_ samples: [Float], keyFrames: [(source: Int, target: Int)], outputLength: Int) -> [Float]
}

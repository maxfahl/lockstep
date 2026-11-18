import Foundation
import LockstepCore

/// What the beat model says about a whole song.
///
/// This is the raw answer, before one beat level is kept and before the beats are moved onto
/// the drum hits. It is kept with the open song (and saved in the project's cache folder from
/// phase 7), so the grid can be fitted again without running the model.
public struct BeatModelOutput: Sendable, Equatable, Codable {
    /// For every 20 ms frame of the song: the beat logit, then the bar-start logit. A logit
    /// above 0 means "more likely than not".
    public var logits: [Float]
    /// The beats picked from the logits, in song seconds, ascending.
    public var beats: [Double]
    /// The bar starts picked from the logits, each moved onto the nearest beat, ascending.
    public var barStarts: [Double]

    public var frameCount: Int { logits.count / BeatModel.valuesPerFrame }

    public init(logits: [Float], beats: [Double], barStarts: [Double]) {
        self.logits = logits
        self.beats = beats
        self.barStarts = barStarts
    }

    /// Picks the beats and bar starts from the logits of a whole song.
    public init(logits: [Float]) {
        let frames = logits.count / BeatModel.valuesPerFrame
        let beats = BeatModelRunner.peaks(in: (0..<frames).map { logits[$0 * 2] })
        var barStarts = BeatModelRunner.peaks(in: (0..<frames).map { logits[$0 * 2 + 1] })
        if !beats.isEmpty {
            // Each bar start is moved onto the nearest beat. Two that land on one beat become one.
            var moved: [Double] = []
            for time in barStarts {
                guard let nearest = beats.min(by: { abs($0 - time) < abs($1 - time) }) else { continue }
                if !moved.contains(nearest) { moved.append(nearest) }
            }
            barStarts = moved.sorted()
        }
        self.init(logits: logits, beats: beats, barStarts: barStarts)
    }
}

/// Runs the beat model over a whole song.
///
/// The model reads 30 seconds at a time. The song's spectrogram is cut into chunks, the model
/// is run on each, and the answers are joined, the way the model's own code does it
/// (`chunk_size=1500`, `border_size=6`, `overlap_mode="keep_first"` in the Beat This! source).
/// Then the beats are picked the way its code does without the DBN.
public enum BeatModelRunner {
    static let chunkFrames = BeatModel.frameCount
    /// Frames at each end of a chunk's answer that are thrown away: the model sees no
    /// surroundings there, so its answer is poor.
    static let borderFrames = 6

    /// Runs the installed model over a spectrogram.
    ///
    /// `progress` is called after each chunk with the share of chunks done, rising to 1.
    /// Cancelling the surrounding task stops the work between two chunks and throws
    /// `CancellationError`. A failing model throws `BeatModelError`.
    @concurrent
    public static func run(
        _ spectrogram: BeatSpectrogram,
        model: BeatModel,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> BeatModelOutput {
        try await run(spectrogram, progress: progress) { try await model.logits(for: $0) }
    }

    /// The same, with the model given as a function from one chunk to its logits.
    @concurrent
    static func run(
        _ spectrogram: BeatSpectrogram,
        progress: @Sendable (Double) -> Void = { _ in },
        chunkLogits: @Sendable ([Float]) async throws -> [Float]
    ) async throws -> BeatModelOutput {
        let frameCount = spectrogram.frameCount
        let bands = BeatModel.bandCount
        let starts = chunkStarts(frameCount: frameCount)
        var logits = [Float](repeating: 0, count: frameCount * BeatModel.valuesPerFrame)
        // Frames before this one already have their answer. Where two chunks overlap, the
        // earlier chunk's answer is the one kept.
        var filled = 0

        for (index, start) in starts.enumerated() {
            try Task.checkCancellation()
            // The chunk's part of the song, with silence where the chunk reaches beyond the
            // song: 6 frames before the start, and whatever is missing after the end.
            var chunk = [Float](repeating: 0, count: chunkFrames * bands)
            let from = max(start, 0), to = min(start + chunkFrames, frameCount)
            chunk.replaceSubrange(
                ((from - start) * bands)..<((to - start) * bands),
                with: spectrogram.values[(from * bands)..<(to * bands)]
            )
            let answer = try await chunkLogits(chunk)
            guard answer.count == chunkFrames * BeatModel.valuesPerFrame else { throw BeatModelError.unusable }

            let keptFrom = max(start + borderFrames, filled)
            let keptTo = min(start + chunkFrames - borderFrames, frameCount)
            if keptFrom < keptTo {
                logits.replaceSubrange(
                    (keptFrom * 2)..<(keptTo * 2),
                    with: answer[((keptFrom - start) * 2)..<((keptTo - start) * 2)]
                )
                filled = keptTo
            }
            progress(Double(index + 1) / Double(starts.count))
        }
        try Task.checkCancellation()
        return BeatModelOutput(logits: logits)
    }

    /// The frame each chunk starts at, for a song of `frameCount` frames.
    ///
    /// The first chunk starts 6 frames before the song, and the chunks are 1,488 frames apart,
    /// so that what is kept of each (all but 6 frames at each end) fits end to end. The last
    /// chunk of a song longer than 1,488 frames is moved back so that it ends 6 frames after the
    /// song, instead of being mostly silence.
    static func chunkStarts(frameCount: Int) -> [Int] {
        guard frameCount > 0 else { return [] }
        let step = chunkFrames - 2 * borderFrames
        var starts = Array(stride(from: -borderFrames, to: frameCount - borderFrames, by: step))
        if frameCount > step {
            starts[starts.count - 1] = frameCount - (chunkFrames - borderFrames)
        }
        return starts
    }

    /// The times, in seconds, of the peaks in one row of logits (one value per 20 ms frame).
    ///
    /// A frame is a peak when its logit is above 0 and is the largest within 3 frames either
    /// side. Peaks on neighbouring frames become one at their mean position, so a time can fall
    /// on half a frame.
    ///
    /// The picking itself is `BeatPicker.peaks`, which also picks at other limits than 0.
    static func peaks(in logits: [Float]) -> [Double] {
        BeatPicker.peaks(in: logits).map { $0.position / BeatFrontEnd.framesPerSecond }
    }
}

extension BeatModelOutput {
    /// The beats at one beat level, picked with a limit other than "more sure than not", and
    /// picked again less strictly where that left a stretch without beats (`BeatPicker.pick`).
    ///
    /// An answer that was kept without its values can only give the beats it holds.
    func picked(limit: Double, maxGapBeats: Int) -> BeatPicker.Picked {
        guard frameCount > 0 else {
            return BeatPicker.Picked(beats: BeatLevel.force(beats, maxGapBeats: maxGapBeats))
        }
        return BeatPicker.pick(
            values: (0..<frameCount).map { logits[$0 * BeatModel.valuesPerFrame] },
            framesPerSecond: BeatFrontEnd.framesPerSecond,
            limit: Float(limit),
            maxGapBeats: maxGapBeats
        )
    }
}

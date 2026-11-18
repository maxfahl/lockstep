/// What counts as a pause between two syllables of a line, and how much of a move such a pause can take up.
///
/// The rule is written here once, and the two places that need it both ask here:
/// - `SyllableMoves.plan` decides how far each syllable goes. Where a pause lies between two syllables, the
///   pause limits the move. Where they run together, the stretch limit does.
/// - `LineRenderer.quantized` builds the sound. Where a pause lies between two syllables, the pause is made
///   longer or shorter and the syllables are untouched. Where they run together, the sound is stretched.
///
/// Because both ask the same question of the same numbers, the planner never asks for a move that the
/// renderer would have to stretch a pause for.
///
///     let points = [line.startSample] + markers + [line.endSample]
///     let pauses = SyllablePauses.between(points, levels: levels)
///     pauses[1]                                    // the pause between the first and the second syllable, or nil
///
/// The rule:
/// - A pause is at least 30 ms in a row at or below the level that counts as sound, between two neighbouring
///   points of a line (its start, each syllable marker, its end). Of several between the same two points, the
///   longest is the one that counts.
/// - A pause can get as long as it has to. The room that opens is filled with its own room sound.
/// - A pause can get shorter until 20 ms of it are left, and no shorter.
/// - A plan leaves it 21 ms, one more. Syllables whose moves differ by no more than half a millisecond are
///   laid down as one block, which can sit up to half a millisecond from where the plan put a syllable, on
///   either side of the pause. The extra millisecond covers both.
public enum SyllablePauses {
    /// How long a pause between two syllables must be to take up a change, in milliseconds. Shorter ones are
    /// part of the sound around them.
    public static let atLeastMs: Double = 30
    /// How much of a pause is always kept when it is made shorter, in milliseconds: room for the crossfade
    /// and 5 ms of untouched room sound on either side of it.
    public static let shortestMs: Double = 20
    /// Syllables with no pause between them whose moves differ by no more than this, in milliseconds, move as
    /// one block.
    public static let sameMoveMs: Double = 0.5
    /// How much of a pause a plan leaves, in milliseconds: what is always kept, plus the half millisecond a
    /// block of syllables may be off on either side.
    public static let plannedShortestMs: Double = shortestMs + 2 * sameMoveMs

    /// The pause between each point of a line and the next one, in samples of the recording, or nil where
    /// there is none. The answer has one entry for every point but the last.
    ///
    /// - Parameters:
    ///   - points: the line's start, its syllable markers and its end, as rising samples of the recording.
    ///   - levels: how loud the recording is.
    public static func between(_ points: [Int], levels: VoiceLevels) -> [Range<Int>?] {
        zip(points, points.dropFirst()).map { earlier, later in
            earlier < later ? longest(in: earlier..<later, levels: levels) : nil
        }
    }

    /// The length of the pause between each point of a line and the next one, in samples, or nil where there
    /// is none: what `SyllableMoves.plan` needs of `between`.
    public static func lengths(between points: [Int], levels: VoiceLevels) -> [Int?] {
        between(points, levels: levels).map { $0?.count }
    }

    /// The longest pause in a stretch of a recording: sound at or below the threshold for at least 30 ms. Nil
    /// when there is none. Where the loudness is not known, there is no pause.
    public static func longest(in range: Range<Int>, levels: VoiceLevels) -> Range<Int>? {
        let hop = levels.hopSamples
        guard hop > 0, !range.isEmpty, range.lowerBound >= 0 else { return nil }
        let atLeast = max(samples(milliseconds: atLeastMs), 1)
        var longest: Range<Int>?
        let lastHop = min((range.upperBound - 1) / hop, levels.values.count - 1)
        var index = range.lowerBound / hop
        while index <= lastHop {
            guard levels.values[index] <= levels.threshold else {
                index += 1
                continue
            }
            var end = index + 1
            while end <= lastHop, levels.values[end] <= levels.threshold { end += 1 }
            let quiet = max(index * hop, range.lowerBound)..<min(end * hop, range.upperBound)
            if quiet.count >= atLeast, quiet.count > longest?.count ?? 0 {
                longest = quiet
            }
            index = end
        }
        return longest
    }

    /// How many samples a plan may take out of a pause that is `length` samples long: all but the 21 ms it
    /// leaves. A plan may add any number.
    public static func mostAPlanTakes(from length: Int) -> Int {
        max(length - samples(milliseconds: plannedShortestMs), 0)
    }

    /// Whether a pause of `length` samples can be built `change` samples longer (or shorter, when negative):
    /// at least 20 ms of it must be left. When it cannot, the renderer stretches the sound around it instead.
    public static func canTake(_ change: Int, length: Int) -> Bool {
        length + change >= min(samples(milliseconds: shortestMs), length)
    }

    /// The largest difference between two moves that still counts as the same move, in samples.
    public static var sameMoveSamples: Int {
        samples(milliseconds: sameMoveMs)
    }

    /// So many milliseconds as whole samples, rounded to the nearest. Nothing for a number that is no length.
    private static func samples(milliseconds: Double) -> Int {
        let samples = (milliseconds * Lockstep.sampleRate / 1_000).rounded()
        guard samples.isFinite, samples > 0, samples < 1e9 else { return 0 }
        return Int(samples)
    }
}

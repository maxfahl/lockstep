/// Where the sound of one line goes when its clip is tightened: a list of pairs, each saying that a sample of
/// the recording lands on another place.
///
/// Both numbers of a pair count samples of the recording at 48,000 Hz, so `result - source` is how far that
/// moment moved, and a map does not change when its clip is moved or cut.
///
/// A line that only slides has two pairs, its start and its end, both moved by the same amount:
///
///     let map = TimeMap(line: line, shiftSeconds: LineShift.toFirstSyllable(markerTimes: times, grid: grid))
///     map.shiftSamples                              // how far the line slides
///     map.result(ofSource: marker) - marker         // how far a syllable inside it moves
///
/// Later phases add pairs inside the line, one for each syllable that moves by itself.
public struct TimeMap: Sendable, Equatable {
    /// One moment of the line, before and after.
    public struct Pair: Sendable, Equatable {
        /// A sample of the recording.
        public var source: Int
        /// Where that sample lands in the tightened version, counted the same way.
        public var result: Int

        public init(source: Int, result: Int) {
            self.source = source
            self.result = result
        }
    }

    /// In the order of the recording.
    public var pairs: [Pair]

    public init(pairs: [Pair]) {
        self.pairs = pairs
    }

    /// The map of a line that slides as a whole by so many samples. Negative is earlier.
    public init(line: VoiceLine, shiftSamples: Int) {
        pairs = [
            Pair(source: line.startSample, result: line.startSample + shiftSamples),
            Pair(source: line.endSample, result: line.endSample + shiftSamples),
        ]
    }

    /// The map of a line that slides as a whole by so many seconds, as `LineShift.toFirstSyllable` gives them.
    public init(line: VoiceLine, shiftSeconds: Double) {
        self.init(line: line, shiftSamples: Self.samples(ofShift: shiftSeconds))
    }

    /// A slide in seconds as whole samples. Sound can only be moved by whole samples.
    public static func samples(ofShift seconds: Double) -> Int {
        let samples = (seconds * Lockstep.sampleRate).rounded()
        guard samples.isFinite, abs(samples) < 1e12 else { return 0 }
        return Int(samples)
    }

    /// How far the line slides as a whole, in samples: how far its start moves.
    public var shiftSamples: Int {
        pairs.first.map { $0.result - $0.source } ?? 0
    }

    /// Where a sample of the recording lands. Between two pairs the move changes evenly from one to the
    /// other. Before the first pair and after the last, the sample moves as that pair does.
    public func result(ofSource sample: Int) -> Int {
        guard let first = pairs.first, let last = pairs.last else { return sample }
        if sample <= first.source { return sample + first.result - first.source }
        if sample >= last.source { return sample + last.result - last.source }
        for (earlier, later) in zip(pairs, pairs.dropFirst()) where sample < later.source {
            let length = later.source - earlier.source
            guard length > 0 else { return earlier.result }
            let share = Double(sample - earlier.source) / Double(length)
            return earlier.result + Int((share * Double(later.result - earlier.result)).rounded())
        }
        return sample + last.result - last.source
    }
}

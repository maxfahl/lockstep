/// The song's waveform worked out once at several levels of detail, so a view
/// at any zoom draws only a screen's worth of blocks.
///
/// Level 0 holds the lowest and highest sample of every 256 samples, over both
/// channels. Each next level joins pairs of blocks of the one before (512,
/// 1024, ...), and the last level is the first with fewer than 512 blocks.
/// Samples are counted per channel, at 48 kHz.
public struct WaveformPyramid: Sendable {
    /// The samples in one block of level 0.
    public static let baseBlockSize = 256
    /// The pyramid stops at the first level with fewer blocks than this.
    public static let smallestLevelBlockCount = 512

    /// One level of detail: the lowest and highest sample of each block, from
    /// -1 to 1. The last block of a level may cover fewer samples than the rest.
    public struct Level: Sendable {
        /// Samples per channel in one block.
        public let samplesPerBlock: Int
        public let minimums: [Float]
        public let maximums: [Float]

        public var blockCount: Int { minimums.count }
    }

    /// The blocks of one level that cover a stretch of the song, ready to be
    /// spread evenly from `startSample` to `endSample`.
    public struct Slice: Sendable {
        /// The level the blocks come from, counted from 0.
        public let level: Int
        public let samplesPerBlock: Int
        /// Where the first block starts, in samples.
        public let startSample: Int
        /// Where the last block would end if it were full, in samples. Only
        /// the song's very last block can be shorter.
        public let endSample: Int
        public let minimums: ArraySlice<Float>
        public let maximums: ArraySlice<Float>

        public var startSeconds: Double { Double(startSample) / Lockstep.sampleRate }
        public var endSeconds: Double { Double(endSample) / Lockstep.sampleRate }
    }

    /// The song's length in samples per channel.
    public let sampleCount: Int
    /// Level 0 first, the coarsest last. Never empty.
    public let levels: [Level]

    /// Builds the pyramid from interleaved samples with `channelCount`
    /// channels. Call it off the main thread, or use `build`.
    public init(interleaved samples: UnsafeBufferPointer<Float>, channelCount: Int) {
        let channels = max(channelCount, 1)
        let frames = samples.count / channels
        sampleCount = frames

        var levels = [Self.baseLevel(samples, channels: channels, frames: frames)]
        while let last = levels.last, last.blockCount >= Self.smallestLevelBlockCount {
            levels.append(Self.joiningPairs(of: last))
        }
        self.levels = levels
    }

    public init(interleaved samples: [Float], channelCount: Int) {
        self = samples.withUnsafeBufferPointer {
            WaveformPyramid(interleaved: $0, channelCount: channelCount)
        }
    }

    /// Builds the pyramid on a background thread, never on the caller's actor.
    @concurrent
    public static func build(interleaved samples: [Float], channelCount: Int) async -> WaveformPyramid {
        WaveformPyramid(interleaved: samples, channelCount: channelCount)
    }

    /// The level to draw from when one screen point covers `samplesPerPoint`
    /// samples: the one with the largest blocks that are still no larger than
    /// that. Closer than 256 samples per point, it is level 0.
    public func levels(forSamplesPerPoint samplesPerPoint: Double) -> Int {
        guard samplesPerPoint.isFinite else {
            return samplesPerPoint == .infinity ? levels.count - 1 : 0
        }
        var chosen = 0
        for index in levels.indices where Double(levels[index].samplesPerBlock) <= samplesPerPoint {
            chosen = index
        }
        return chosen
    }

    /// The blocks of `level` that cover the samples from `fromSample` up to
    /// `toSample`, so only what is on screen needs to be drawn. The range is
    /// clamped to the song; an empty or outside range gives no blocks.
    public func slice(level: Int, fromSample: Int, toSample: Int) -> Slice {
        let index = min(max(level, 0), levels.count - 1)
        let chosen = levels[index]
        let size = chosen.samplesPerBlock
        let start = min(max(fromSample, 0), sampleCount)
        let end = min(max(toSample, start), sampleCount)

        let firstBlock = min(start / size, chosen.blockCount)
        let endBlock = end > start ? min((end + size - 1) / size, chosen.blockCount) : firstBlock
        return Slice(
            level: index,
            samplesPerBlock: size,
            startSample: firstBlock * size,
            endSample: endBlock * size,
            minimums: chosen.minimums[firstBlock..<endBlock],
            maximums: chosen.maximums[firstBlock..<endBlock]
        )
    }

    /// Level 0. One block's samples sit next to each other in interleaved
    /// audio, so both channels are read in one run without telling them apart.
    private static func baseLevel(_ samples: UnsafeBufferPointer<Float>, channels: Int, frames: Int) -> Level {
        let blockCount = (frames + baseBlockSize - 1) / baseBlockSize
        var minimums = [Float](repeating: 0, count: blockCount)
        var maximums = [Float](repeating: 0, count: blockCount)
        guard blockCount > 0, let base = samples.baseAddress else {
            return Level(samplesPerBlock: baseBlockSize, minimums: [], maximums: [])
        }
        let valuesPerBlock = baseBlockSize * channels
        let valueCount = frames * channels
        minimums.withUnsafeMutableBufferPointer { lows in
            maximums.withUnsafeMutableBufferPointer { highs in
                for block in 0..<blockCount {
                    var index = block * valuesPerBlock
                    let end = min(index + valuesPerBlock, valueCount)
                    var low = base[index]
                    var high = low
                    while index < end {
                        let value = base[index]
                        if value < low { low = value }
                        if value > high { high = value }
                        index += 1
                    }
                    lows[block] = low
                    highs[block] = high
                }
            }
        }
        return Level(samplesPerBlock: baseBlockSize, minimums: minimums, maximums: maximums)
    }

    /// The next coarser level: each block joins two of `level`, and an odd
    /// last block stands alone.
    private static func joiningPairs(of level: Level) -> Level {
        let count = (level.blockCount + 1) / 2
        var minimums = [Float](repeating: 0, count: count)
        var maximums = [Float](repeating: 0, count: count)
        level.minimums.withUnsafeBufferPointer { fineLows in
            level.maximums.withUnsafeBufferPointer { fineHighs in
                minimums.withUnsafeMutableBufferPointer { lows in
                    maximums.withUnsafeMutableBufferPointer { highs in
                        for block in 0..<count {
                            let left = block * 2
                            let right = min(left + 1, fineLows.count - 1)
                            lows[block] = fineLows[left] < fineLows[right] ? fineLows[left] : fineLows[right]
                            highs[block] = fineHighs[left] > fineHighs[right] ? fineHighs[left] : fineHighs[right]
                        }
                    }
                }
            }
        }
        return Level(samplesPerBlock: level.samplesPerBlock * 2, minimums: minimums, maximums: maximums)
    }
}

import Foundation

/// How loud audio sounds, measured the way streaming services do it:
/// the integrated loudness of ITU-R BS.1770-4, for mono audio at 48,000 Hz.
///
/// The figure follows the ear, not the highest peak, so two clips with the
/// same figure sound equally loud. Normalize uses it. Phase 16.
public enum Loudness {
    /// A block is 400 ms long.
    static let blockSamples = 19_200
    /// Blocks overlap by 75 %, so a new one starts every 100 ms.
    static let stepSamples = 4_800
    /// Blocks quieter than this count as silence and are left out.
    public static let absoluteGateLufs = -70.0
    /// Blocks this far below the mean of the others are left out too.
    public static let relativeGateLu = 10.0

    // MARK: Samples

    /// The integrated loudness of mono samples at 48 kHz, in LUFS.
    ///
    /// Nil when there is nothing to measure: no samples, or nothing louder
    /// than -70 LUFS. Audio shorter than 400 ms is measured as one block.
    public static func integrated(_ samples: [Float]) -> Double? {
        integrated(of: blocks(samples))
    }

    /// The integrated loudness of a sound whose blocks were measured already (`blocks(_:)`), in LUFS. Nil
    /// when no block counts.
    public static func integrated(of blocks: [Block]) -> Double? {
        let counted = blocks.filter(\.counts)
        guard !counted.isEmpty else { return nil }
        return lufs(meanSquare: mean(counted.map(\.meanSquare)))
    }

    /// One block of 400 ms, as the integrated loudness measures it.
    public struct Block: Sendable, Equatable {
        /// The block's first sample.
        public var start: Int
        /// The mean of the K-weighted samples squared.
        public var meanSquare: Double
        /// Whether the block counts in the integrated loudness: it is above both gates.
        public var counts: Bool

        /// How loud the block is, in LUFS. Silence is minus infinity.
        public var lufs: Double { Loudness.lufs(meanSquare: meanSquare) }
    }

    /// The blocks the integrated loudness is made of: 400 ms each, a new one every 100 ms, and whether each
    /// one counts or is left out as silence or as a pause far below the rest. A sound shorter than one block
    /// is one block, the whole sound. No samples give no blocks.
    ///
    /// A made voice is checked with them for stretches that lost their sound (`VoiceFile.takeIn`), by the very
    /// measure Normalize uses.
    public static func blocks(_ samples: [Float]) -> [Block] {
        guard !samples.isEmpty else { return [] }
        let energies = stepEnergies(samples)

        // Too short for one whole block: the whole sound is the block.
        guard samples.count >= blockSamples else {
            let meanSquare = energies.reduce(0, +) / Double(samples.count)
            return [Block(start: 0, meanSquare: meanSquare, counts: lufs(meanSquare: meanSquare) > absoluteGateLufs)]
        }

        // Each block is four steps in a row. A last part shorter than a step is not measured.
        let wholeSteps = samples.count / stepSamples
        var blocks: [Block] = []
        blocks.reserveCapacity(wholeSteps - 3)
        for first in 0...(wholeSteps - 4) {
            let sum = energies[first] + energies[first + 1] + energies[first + 2] + energies[first + 3]
            blocks.append(Block(start: first * stepSamples, meanSquare: sum / Double(blockSamples), counts: false))
        }

        // First gate: silence is left out.
        let audible = blocks.filter { $0.lufs > absoluteGateLufs }
        guard !audible.isEmpty else { return blocks }

        // Second gate: pauses and breaths, far below the rest, are left out.
        let threshold = lufs(meanSquare: mean(audible.map(\.meanSquare))) - relativeGateLu
        for index in blocks.indices where blocks[index].lufs > absoluteGateLufs && blocks[index].lufs > threshold {
            blocks[index].counts = true
        }
        return blocks
    }

    /// The highest absolute sample in dBFS. Full scale is 0.
    /// Silence, or no samples at all, gives minus infinity.
    public static func peakDb(_ samples: [Float]) -> Double {
        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        return peak > 0 ? 20 * log10(Double(peak)) : -.infinity
    }

    // MARK: Clips

    /// What a clip plays, as one run of samples: its segments in their order
    /// (which is time order), each multiplied by the segment's own gain, with
    /// the gaps between them left out. The clip's own volume and its
    /// normalisation are not applied.
    ///
    /// `recording` gives the samples of a recording, or nil when it has none;
    /// such a segment adds nothing.
    public static func samples(of clip: Clip, recording: (UUID) -> [Float]?) -> [Float] {
        var result: [Float] = []
        for segment in clip.segments {
            guard let source = recording(segment.recordingID) else { continue }
            let start = min(max(0, segment.inSample), source.count)
            let end = min(max(start, segment.outSample), source.count)
            guard end > start else { continue }
            let gain = Float(pow(10, segment.gainDb / 20))
            if gain == 1 {
                result.append(contentsOf: source[start..<end])
            } else {
                result.append(contentsOf: source[start..<end].lazy.map { $0 * gain })
            }
        }
        return result
    }

    /// The integrated loudness of what a clip plays, in LUFS, measured over
    /// `samples(of:recording:)`. Nil for a clip that is silent or empty.
    public static func integrated(of clip: Clip, recording: (UUID) -> [Float]?) -> Double? {
        integrated(samples(of: clip, recording: recording))
    }

    // MARK: The parts

    /// The loudness of a mean square of K-weighted samples.
    static func lufs(meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    /// The samples after K-weighting, squared and summed over each 100 ms
    /// step. The last step may be shorter.
    ///
    /// K-weighting is two filters in a row with the standard's coefficients
    /// for 48 kHz: a shelf that lifts the highs as the head does, then a
    /// high-pass that takes away the lows the ear hardly hears.
    private static func stepEnergies(_ samples: [Float]) -> [Double] {
        // Stage 1, the shelf.
        let b10 = 1.53512485958697, b11 = -2.69169618940638, b12 = 1.19839281085285
        let a11 = -1.69065929318241, a12 = 0.73248077421585
        // Stage 2, the high-pass.
        let b20 = 1.0, b21 = -2.0, b22 = 1.0
        let a21 = -1.99004745483398, a22 = 0.99007225036621

        // What each filter remembers (transposed direct form II).
        var s11 = 0.0, s12 = 0.0, s21 = 0.0, s22 = 0.0

        var energies = [Double](repeating: 0, count: (samples.count + stepSamples - 1) / stepSamples)
        samples.withUnsafeBufferPointer { input in
            for index in 0..<input.count {
                let x = Double(input[index])
                let shelved = b10 * x + s11
                s11 = b11 * x - a11 * shelved + s12
                s12 = b12 * x - a12 * shelved
                let y = b20 * shelved + s21
                s21 = b21 * shelved - a21 * y + s22
                s22 = b22 * shelved - a22 * y
                energies[index / stepSamples] += y * y
            }
        }
        return energies
    }
}

import SwiftUI

/// A filled waveform, mirrored around its middle line, placed in the song by a
/// timeline viewport. The song row draws the song with it; any row that shows
/// audio (a clip, a take) can use it the same way.
///
/// It fills the view it is given, with x = 0 at the left edge of the lane
/// body, like a lane's content. So lay it over the whole row (or over a part
/// that starts at the row's left edge) and pad it only from above and below:
///
///     WaveformShape(levels: song.levels, range: 0...song.length, viewport: viewport)
///         .fill(palette.songWaveform)
///         .padding(.vertical, DesignTokens.Spacing.small)
///
/// It is a `Shape`, so the caller picks the colour with `fill`. Only the part
/// inside `viewport.visibleRange` is built, and never more than one point per
/// point of width, however many blocks the levels hold.
public struct WaveformShape: Shape {
    /// The loudness blocks, spread evenly over `range`.
    public var levels: WaveformLevels
    /// The stretch of the song the levels cover, in song seconds.
    public var range: ClosedRange<Double>
    /// The part of the timeline that is on screen.
    public var viewport: TimelineViewport
    /// How many times taller than recorded the waveform is drawn: 2 for a
    /// clip that is turned up 6 dB. It never grows out of its view.
    public var gain: Double

    public init(
        levels: WaveformLevels,
        range: ClosedRange<Double>,
        viewport: TimelineViewport,
        gain: Double = 1
    ) {
        self.levels = levels
        self.range = range
        self.viewport = viewport
        self.gain = gain
    }

    public func path(in rect: CGRect) -> Path {
        let blockCount = min(levels.minimums.count, levels.maximums.count)
        let duration = range.upperBound - range.lowerBound
        let visibleStart = max(range.lowerBound, viewport.visibleRange.lowerBound)
        let visibleEnd = min(range.upperBound, viewport.visibleRange.upperBound)
        guard blockCount > 0, duration > 0, visibleEnd > visibleStart, rect.width > 0 else {
            return Path()
        }

        let blocksPerSecond = Double(blockCount) / duration
        let left = viewport.x(for: visibleStart)
        let right = viewport.x(for: visibleEnd)
        let firstBlock = block(at: visibleStart, blocksPerSecond: blocksPerSecond, count: blockCount)
        let lastBlock = block(at: visibleEnd, blocksPerSecond: blocksPerSecond, count: blockCount)

        // The outline's upper edge, from left to right: an x and how loud the
        // audio is there, from 0 to 1.
        var edge: [(x: CGFloat, loudness: CGFloat)] = []
        let visibleBlocks = lastBlock - firstBlock + 1
        let width = right - left
        guard width > 0 else { return Path() }

        edge.append((left, loudness(ofBlocks: firstBlock...firstBlock)))
        if CGFloat(visibleBlocks) <= width {
            // Zoomed in: every block is at least a point wide, so each gets
            // its own corner, at the middle of its time.
            edge.reserveCapacity(visibleBlocks + 2)
            for index in firstBlock...lastBlock {
                let middle = range.lowerBound + (Double(index) + 0.5) / blocksPerSecond
                let x = viewport.x(for: middle)
                if x > left, x < right {
                    edge.append((x, loudness(ofBlocks: index...index)))
                }
            }
        } else {
            // Zoomed out: many blocks share one point of width. Each point
            // shows the loudest of its blocks, so short peaks stay visible.
            let columns = Int(width.rounded(.up))
            edge.reserveCapacity(columns + 2)
            let secondsPerColumn = (visibleEnd - visibleStart) / Double(columns)
            for column in 0..<columns {
                let start = visibleStart + Double(column) * secondsPerColumn
                let first = block(at: start, blocksPerSecond: blocksPerSecond, count: blockCount)
                let last = block(at: start + secondsPerColumn, blocksPerSecond: blocksPerSecond, count: blockCount)
                let x = min(left + CGFloat(column) + 0.5, right)
                edge.append((x, loudness(ofBlocks: first...max(first, last))))
            }
        }
        edge.append((right, loudness(ofBlocks: lastBlock...lastBlock)))

        // The upper edge, then the same edge mirrored back along the bottom.
        let middleY = rect.midY
        let fullHalfHeight = rect.height / 2
        let leastHalfHeight = DesignTokens.Lines.waveformSilenceHeight / 2
        func halfHeight(_ loudness: CGFloat) -> CGFloat {
            max(loudness * fullHalfHeight, leastHalfHeight)
        }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + edge[0].x, y: middleY - halfHeight(edge[0].loudness)))
        for point in edge.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + point.x, y: middleY - halfHeight(point.loudness)))
        }
        for point in edge.reversed() {
            path.addLine(to: CGPoint(x: rect.minX + point.x, y: middleY + halfHeight(point.loudness)))
        }
        path.closeSubpath()
        return path
    }

    /// The block that holds a moment in the song.
    private func block(at seconds: Double, blocksPerSecond: Double, count: Int) -> Int {
        let index = Int(((seconds - range.lowerBound) * blocksPerSecond).rounded(.down))
        return min(max(index, 0), count - 1)
    }

    /// How loud the loudest of some blocks is after `gain`, from 0 to 1,
    /// whichever way the sound swings.
    ///
    /// This runs for every block on screen each time a waveform is drawn, so
    /// it reads the two lists directly and compares by hand. Asking the lists
    /// for one value at a time was the slowest part of drawing a waveform.
    private func loudness(ofBlocks blocks: ClosedRange<Int>) -> CGFloat {
        var loudest: Float = 0
        levels.minimums.withUnsafeBufferPointer { minimums in
            levels.maximums.withUnsafeBufferPointer { maximums in
                var index = blocks.lowerBound
                let last = blocks.upperBound
                while index <= last {
                    let low = minimums[index].magnitude
                    let high = maximums[index].magnitude
                    if low > loudest { loudest = low }
                    if high > loudest { loudest = high }
                    index += 1
                }
            }
        }
        return CGFloat(min(max(Double(loudest) * gain, 0), 1))
    }
}

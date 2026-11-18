import LockstepCore
import SwiftUI

/// The beat grid a timeline draws through its rows and hands to its ruler.
/// The big timeline and the small takes timeline are given the same one.
public struct TimelineBeats: Equatable, Sendable {
    /// Every beat, in time order.
    public var lines: [BeatLine]
    /// Stretches of the grid the app is unsure about, in song seconds. Beats
    /// inside them are drawn dashed, like estimated beats.
    public var uncertainRanges: [ClosedRange<Double>]
    /// Stretches where no beats were placed, in song seconds. They have no
    /// lines and no ruler ticks; the timeline lays a faint band over them.
    public var unfilledGaps: [ClosedRange<Double>]
    /// When set, and the zoom puts the beat lines closer together than this
    /// many points, only the bar lines are drawn, in the rows and in the
    /// ruler. Nil draws every line at every zoom.
    public var closestLineSpacing: CGFloat?

    public init(
        lines: [BeatLine] = [],
        uncertainRanges: [ClosedRange<Double>] = [],
        unfilledGaps: [ClosedRange<Double>] = [],
        closestLineSpacing: CGFloat? = nil
    ) {
        self.lines = lines
        self.uncertainRanges = uncertainRanges
        self.unfilledGaps = unfilledGaps
        self.closestLineSpacing = closestLineSpacing
    }

    /// A timeline without a beat grid, such as before the beats are found.
    public static let none = TimelineBeats()

    /// The beats inside a time range, found without walking the whole list.
    /// Pass `viewport.visibleRange` to get only the beats on screen.
    public func lines(in range: ClosedRange<Double>) -> ArraySlice<BeatLine> {
        let first = firstIndex { $0.time >= range.lowerBound }
        let end = firstIndex { $0.time > range.upperBound }
        return lines[first..<max(first, end)]
    }

    /// Whether only the bar lines are drawn at a zoom, because the beat lines
    /// would stand closer together than `closestLineSpacing`. Always false
    /// without that value.
    ///
    /// It is judged on the usual distance between two beats of the whole
    /// song, so the choice does not change while the timeline scrolls.
    public func showsBarLinesOnly(atPointsPerSecond pointsPerSecond: Double) -> Bool {
        guard let closestLineSpacing, lines.count > 1 else { return false }
        // The stretches without beats are left out, or a long one would make
        // the beats look further apart than they are.
        let gapsLength = unfilledGaps.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        let steps = lines.count - 1 - unfilledGaps.count
        guard steps > 0 else { return false }
        let usualSpacing = (lines[lines.count - 1].time - lines[0].time - gapsLength) / Double(steps)
        return usualSpacing * pointsPerSecond < Double(closestLineSpacing)
    }

    /// How far the beat line at `time` may be dragged, in song seconds: half
    /// the way to the beat line before it and half the way to the one after.
    /// Nil when no line stands exactly there, or it has no neighbour.
    ///
    /// A line on the other side of a stretch without beats is not a
    /// neighbour. Towards such a stretch, and at the first and last line, the
    /// line may go as far as it may go the other way.
    func dragRange(forLineAt time: Double) -> ClosedRange<Double>? {
        let index = firstIndex { $0.time >= time }
        guard index < lines.count, lines[index].time == time else { return nil }
        func reach(to other: Int) -> Double? {
            guard lines.indices.contains(other) else { return nil }
            let earlier = min(time, lines[other].time)
            let later = max(time, lines[other].time)
            guard !unfilledGaps.contains(where: { $0.lowerBound < later && $0.upperBound > earlier }) else {
                return nil
            }
            return (later - earlier) / 2
        }
        let back = reach(to: index - 1)
        let forward = reach(to: index + 1)
        guard let either = back ?? forward else { return nil }
        return (time - (back ?? either))...(time + (forward ?? either))
    }

    /// Whether a beat is drawn dashed: it is estimated, or it lies in a
    /// stretch the app is unsure about.
    public func isUncertain(_ line: BeatLine) -> Bool {
        line.isEstimated || uncertainRanges.contains { $0.contains(line.time) }
    }

    /// The first position in the time-ordered list where `isAtOrPast` holds,
    /// found by halving.
    private func firstIndex(where isAtOrPast: (BeatLine) -> Bool) -> Int {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if isAtOrPast(lines[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}

extension TimelineContent {
    /// The beat grid of this content, ready to hand to a `Timeline`.
    public var beats: TimelineBeats {
        // Where the song is cut away there are no beat lines.
        let kept = keptRange
        return TimelineBeats(
            lines: songPlace == SongPlace() ? beatLines : beatLines.filter { kept.contains($0.time) },
            uncertainRanges: uncertainRanges,
            unfilledGaps: unfilledGaps,
            closestLineSpacing: closestBeatLineSpacing
        )
    }
}

/// The beat lines, the bar lines and the gap bands of one row. The timeline
/// lays it on top of every row's content, inside the row's rounded outline.
struct TimelineBeatLines: View {
    @Environment(\.timelinePalette) private var palette

    let beats: TimelineBeats
    let viewport: TimelineViewport

    var body: some View {
        Canvas { context, size in
            for gap in beats.unfilledGaps where gap.overlaps(viewport.visibleRange) {
                let left = viewport.x(for: gap.lowerBound)
                let right = viewport.x(for: gap.upperBound)
                context.fill(
                    Path(CGRect(x: left, y: 0, width: right - left, height: size.height)),
                    with: .color(palette.unfilledGapBand)
                )
            }

            var beatLines = Path()
            var barLines = Path()
            var uncertainBeatLines = Path()
            var uncertainBarLines = Path()
            let barLinesOnly = beats.showsBarLinesOnly(atPointsPerSecond: viewport.scale.pointsPerSecond)
            for line in beats.lines(in: viewport.visibleRange) where line.isBarStart || !barLinesOnly {
                let x = viewport.lineX(for: line.time)
                let isUncertain = beats.isUncertain(line)
                func add(to path: inout Path) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                switch (line.isBarStart, isUncertain) {
                case (false, false): add(to: &beatLines)
                case (true, false): add(to: &barLines)
                case (false, true): add(to: &uncertainBeatLines)
                case (true, true): add(to: &uncertainBarLines)
                }
            }

            let solidBeat = StrokeStyle(lineWidth: DesignTokens.Lines.beatWidth)
            let solidBar = StrokeStyle(lineWidth: DesignTokens.Lines.barWidth)
            let dashedBeat = StrokeStyle(
                lineWidth: DesignTokens.Lines.beatWidth,
                dash: DesignTokens.Lines.estimatedBeatDash
            )
            let dashedBar = StrokeStyle(
                lineWidth: DesignTokens.Lines.barWidth,
                dash: DesignTokens.Lines.estimatedBeatDash
            )
            context.stroke(beatLines, with: .color(palette.beatLine), style: solidBeat)
            context.stroke(uncertainBeatLines, with: .color(palette.estimatedBeatLine), style: dashedBeat)
            context.stroke(barLines, with: .color(palette.barLine), style: solidBar)
            context.stroke(uncertainBarLines, with: .color(palette.barLine), style: dashedBar)
        }
        .allowsHitTesting(false)
    }
}

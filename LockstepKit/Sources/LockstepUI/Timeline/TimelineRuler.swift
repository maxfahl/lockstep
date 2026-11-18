import LockstepCore
import SwiftUI

/// The strip above the rows: a short tick at every beat, a taller tick and the
/// bar number at every bar start. Without any beats it shows time marks
/// instead, counted from the timeline's 00:00 (`place`). Zoomed so far out that the rows draw only their bar lines
/// (`TimelineBeats.closestLineSpacing`), it leaves out the beat ticks too.
/// The timeline shows it when `showsRuler` is on:
///
///     Timeline(...) { viewport, beats in
///         TimelineRuler(viewport: viewport, beats: beats)
///     }
///
/// The ticks stand on the bottom edge, next to the rows, and sit at
/// `viewport.lineX(for:)`, the same place as the beat lines, so each tick
/// continues its beat line upwards.
public struct TimelineRuler: View {
    @Environment(\.timelinePalette) private var palette

    private let viewport: TimelineViewport
    private let beats: TimelineBeats
    private let place: SongPlace

    /// - Parameter place: Which moment of the song stands at 00:00
    ///   (`TimelineContent.songPlace`). The time marks count from there. Left
    ///   out, they count from the song's first sample. Bar numbers are the
    ///   song's own and do not change with it.
    public init(viewport: TimelineViewport, beats: TimelineBeats, place: SongPlace = SongPlace()) {
        self.viewport = viewport
        self.beats = beats
        self.place = place
    }

    public var body: some View {
        Canvas { context, size in
            guard viewport.scale.pointsPerSecond > 0 else { return }
            if beats.lines.isEmpty {
                drawTimeMarks(in: &context, size: size)
            } else {
                drawBars(in: &context, size: size)
            }
        }
    }

    // MARK: - Bars and beats

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        let pointsPerSecond = viewport.scale.pointsPerSecond
        let step = Self.barLabelStep(lines: beats.lines, pointsPerSecond: pointsPerSecond)

        // A bar that starts a little left of the strip still has its number
        // reaching into it, so the search starts one label spacing earlier.
        let margin = Double(DesignTokens.Sizes.rulerMinimumLabelSpacing) / pointsPerSecond
        let shown = beats.lines(
            in: (viewport.visibleRange.lowerBound - margin)...viewport.visibleRange.upperBound
        )
        var countedBars = beats.lines[..<shown.startIndex].count(where: \.isBarStart)
        let barTicksOnly = beats.showsBarLinesOnly(atPointsPerSecond: pointsPerSecond)

        var beatTicks = Path()
        var barTicks = Path()
        var labels: [(number: Int, x: CGFloat)] = []
        for line in shown {
            var barNumber = countedBars
            if line.isBarStart {
                countedBars += 1
                // The number the line brings is right also after a stretch
                // without beats, where bar starts have no line to count.
                barNumber = line.barNumber ?? countedBars
            } else if barTicksOnly {
                continue
            }
            guard !isInsideUnfilledGap(line.time) else { continue }
            let x = viewport.lineX(for: line.time)
            if line.isBarStart {
                addTick(to: &barTicks, x: x, height: DesignTokens.Sizes.rulerBarTickHeight, size: size)
                if (barNumber - 1) % step == 0 {
                    labels.append((barNumber, x))
                }
            } else {
                addTick(to: &beatTicks, x: x, height: DesignTokens.Sizes.rulerBeatTickHeight, size: size)
            }
        }

        let tickStyle = StrokeStyle(lineWidth: DesignTokens.Lines.rulerTickWidth)
        context.stroke(beatTicks, with: .color(palette.rulerTick), style: tickStyle)
        context.stroke(barTicks, with: .color(palette.rulerBarTick), style: tickStyle)
        for label in labels {
            drawLabel("\(label.number)", tickX: label.x, in: &context, size: size)
        }
    }

    /// How many bars apart the numbers are: every bar, every 2nd, 4th, 8th
    /// and so on, the first that keeps them `rulerMinimumLabelSpacing` apart.
    /// It is measured on the shortest bar of the whole song, so the numbers
    /// never crowd where the tempo is fastest, and the choice does not change
    /// while the timeline scrolls.
    private static func barLabelStep(lines: [BeatLine], pointsPerSecond: Double) -> Int {
        var shortestBar = Double.infinity
        var previousBarStart: Double?
        for line in lines where line.isBarStart {
            if let previousBarStart {
                shortestBar = min(shortestBar, line.time - previousBarStart)
            }
            previousBarStart = line.time
        }
        guard shortestBar.isFinite, shortestBar > 0 else { return 1 }
        let barWidth = shortestBar * pointsPerSecond
        let spacing = Double(DesignTokens.Sizes.rulerMinimumLabelSpacing)
        var step = 1
        while Double(step) * barWidth < spacing {
            step *= 2
        }
        return step
    }

    /// Whether a beat lies strictly inside a stretch where no beats were
    /// placed. The beats at the two edges of the gap are real and keep their ticks.
    private func isInsideUnfilledGap(_ time: Double) -> Bool {
        beats.unfilledGaps.contains { $0.lowerBound < time && time < $0.upperBound }
    }

    // MARK: - Time marks

    /// The steps between time marks, in seconds: seconds first, then minutes.
    private static let timeMarkSteps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600]

    /// Without a beat grid: a tall tick and a time ("1:30") at every mark,
    /// with the marks as close as `rulerMinimumLabelSpacing` allows.
    private func drawTimeMarks(in context: inout GraphicsContext, size: CGSize) {
        let pointsPerSecond = viewport.scale.pointsPerSecond
        let spacing = Double(DesignTokens.Sizes.rulerMinimumLabelSpacing)
        let interval = Self.timeMarkSteps.first { $0 * pointsPerSecond >= spacing }
            ?? Self.timeMarkSteps[Self.timeMarkSteps.count - 1]

        // The marks stand on whole steps of timeline time, which starts at 00:00.
        let margin = spacing / pointsPerSecond
        let shownFrom = place.timelineSeconds(forSong: viewport.visibleRange.lowerBound)
        let shownTo = place.timelineSeconds(forSong: viewport.visibleRange.upperBound)
        let first = Int(((shownFrom - margin) / interval).rounded(.down))
        let last = Int((shownTo / interval).rounded(.down))
        guard first <= last else { return }

        var ticks = Path()
        var labels: [(seconds: Int, x: CGFloat)] = []
        for index in max(first, 0)...max(last, 0) {
            let seconds = Double(index) * interval
            let x = viewport.lineX(for: place.songSeconds(forTimeline: seconds))
            addTick(to: &ticks, x: x, height: DesignTokens.Sizes.rulerBarTickHeight, size: size)
            labels.append((Int(seconds), x))
        }

        context.stroke(
            ticks,
            with: .color(palette.rulerBarTick),
            style: StrokeStyle(lineWidth: DesignTokens.Lines.rulerTickWidth)
        )
        for label in labels {
            let minutes = label.seconds / 60
            let remainder = label.seconds % 60
            let text = remainder < 10 ? "\(minutes):0\(remainder)" : "\(minutes):\(remainder)"
            drawLabel(text, tickX: label.x, in: &context, size: size)
        }
    }

    // MARK: - Drawing

    /// A tick standing on the bottom edge of the strip.
    private func addTick(to path: inout Path, x: CGFloat, height: CGFloat, size: CGSize) {
        path.move(to: CGPoint(x: x, y: size.height))
        path.addLine(to: CGPoint(x: x, y: size.height - height))
    }

    /// A bar number or time, just right of its tick, in the space above the
    /// tall ticks.
    private func drawLabel(_ text: String, tickX: CGFloat, in context: inout GraphicsContext, size: CGSize) {
        let label = Text(text)
            .font(DesignTokens.Fonts.rulerLabel)
            .foregroundStyle(palette.rulerLabel)
        let centerY = (size.height - DesignTokens.Sizes.rulerBarTickHeight) / 2
        context.draw(
            label,
            at: CGPoint(x: tickX + DesignTokens.Spacing.tight, y: centerY),
            anchor: .leading
        )
    }
}

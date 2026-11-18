import LockstepCore
import SwiftUI

/// Everything the main timeline draws while something is dragged: a clip
/// that is moved, with the mark at its recorded place and the snap line; the
/// snap line of a clip that is trimmed by an edge; the
/// band over a marked stretch; the rectangle of a drag that selects clips on
/// several tracks; a track header that is moved, with the line where the
/// track will land.
///
/// It goes in the timeline's drag layer, which lies on top of all rows and
/// under the playhead. `MainTimeline` puts it there:
///
///     Timeline(...)
///         .dragLayer { context in
///             TimelineDragPicture(dragging: content.dragging, context: context)
///         }
///
/// It only draws. Nothing here listens for a drag.
///
/// The loop region is not drawn here, because the drag layer does not reach
/// the ruler. `LoopRegionMark` draws it, inside the ruler.
struct TimelineDragPicture: View {
    let dragging: TimelineDragging
    let context: TimelineDragLayerContext

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let stretch = dragging.markedStretch, let row = context.rowFrame(of: stretch.trackID) {
                markedStretch(stretch, row: row)
            }
            if let rectangle = dragging.selectionRectangle,
               let first = context.rowFrame(of: rectangle.firstTrackID),
               let last = context.rowFrame(of: rectangle.lastTrackID) {
                selectionRectangle(rectangle, rows: first.union(last))
            }
            if let moved = dragging.movedClip {
                MovedClipPicture(moved: moved, context: context)
            }
            if let trimmed = dragging.trimmedClip {
                TrimmedClipPicture(trimmed: trimmed, context: context)
            }
            if let moved = dragging.movedTrack, let row = context.rowFrame(of: moved.track.id) {
                MovedTrackPicture(moved: moved, row: row, context: context)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The band over the marked stretch, over the whole height of its row
    /// and never over the row's header.
    @ViewBuilder
    private func markedStretch(_ stretch: MarkedStretch, row: CGRect) -> some View {
        let left = max(context.x(for: stretch.range.lowerBound).rounded(), context.bodyMinX)
        let right = min(context.x(for: stretch.range.upperBound).rounded(), row.maxX)
        if right > left {
            StretchBand(
                fill: DesignTokens.Colors.markedStretchFill,
                showsLeadingEdge: context.viewport.visibleRange.contains(stretch.range.lowerBound),
                showsTrailingEdge: context.viewport.visibleRange.contains(stretch.range.upperBound)
            )
            .frame(width: right - left, height: row.height)
            .offset(x: left, y: row.minY)
        }
    }

    /// The rectangle of a drag that selects clips: one band with the look of
    /// the marked stretch, from the top of its first row to the bottom of its
    /// last, over the gaps between them, and never over the headers.
    ///
    /// The track rows scroll under the song row, which stays where it is. So
    /// the band stops at the song row, as the rows do, and has no edge on a
    /// side that is out of sight.
    ///
    /// - Parameter rows: The frame around both end rows, where they are now.
    @ViewBuilder
    private func selectionRectangle(_ rectangle: SelectionRectangle, rows: CGRect) -> some View {
        let left = max(context.x(for: rectangle.range.lowerBound).rounded(), context.bodyMinX)
        let right = min(context.x(for: rectangle.range.upperBound).rounded(), rows.maxX)
        let top = max(rows.minY, context.scrollAreaMinY)
        // A drag straight down has no width yet. It is drawn as wide as an
        // edge, so the rectangle is there from the moment the row is left.
        let width = max(right - left, DesignTokens.Lines.markedStretchEdgeWidth)
        if right >= left, rows.maxY > top {
            StretchBand(
                fill: DesignTokens.Colors.markedStretchFill,
                showsLeadingEdge: context.viewport.visibleRange.contains(rectangle.range.lowerBound),
                showsTrailingEdge: context.viewport.visibleRange.contains(rectangle.range.upperBound),
                showsTopEdge: rows.minY >= context.scrollAreaMinY,
                showsBottomEdge: true
            )
            .frame(width: width, height: rows.maxY - top)
            .offset(x: left, y: top)
        }
    }
}

extension TimelineDragLayerContext {
    /// Where the row of a track is, or nil when the timeline has no such row.
    func rowFrame(of trackID: UUID) -> CGRect? {
        laneFrames.first { $0.laneID == AnyHashable(trackID) }?.frame
    }
}

// MARK: - A band over a stretch of time

/// A see-through band with a thin line at each end: the marked stretch on a
/// track, and the loop region in the ruler. It fills the frame it is given.
/// An end that lies beyond the screen has no line.
///
/// The rectangle that selects clips on several tracks is the same band with a
/// line along its top and its bottom too, so it reads as a rectangle and not
/// as a tall stretch.
struct StretchBand: View {
    let fill: Color
    var showsLeadingEdge = true
    var showsTrailingEdge = true
    var showsTopEdge = false
    var showsBottomEdge = false

    var body: some View {
        Rectangle()
            .fill(fill)
            .overlay(alignment: .leading) {
                if showsLeadingEdge {
                    edge
                }
            }
            .overlay(alignment: .trailing) {
                if showsTrailingEdge {
                    edge
                }
            }
            .overlay(alignment: .top) {
                if showsTopEdge {
                    levelEdge
                }
            }
            .overlay(alignment: .bottom) {
                if showsBottomEdge {
                    levelEdge
                }
            }
    }

    private var edge: some View {
        Rectangle()
            .fill(DesignTokens.Colors.markedStretchEdge)
            .frame(width: DesignTokens.Lines.markedStretchEdgeWidth)
    }

    /// The same line lying down, along the top or the bottom.
    private var levelEdge: some View {
        Rectangle()
            .fill(DesignTokens.Colors.markedStretchEdge)
            .frame(height: DesignTokens.Lines.markedStretchEdgeWidth)
    }
}

/// The loop region, drawn in the ruler behind the ticks and the bar numbers:
/// a band from where the loop starts to where it ends. Put it in the ruler's
/// strip, under `TimelineRuler`, at the strip's left edge.
struct LoopRegionMark: View {
    let range: ClosedRange<Double>
    let viewport: TimelineViewport

    var body: some View {
        let left = viewport.x(for: max(range.lowerBound, viewport.visibleRange.lowerBound)).rounded()
        let right = viewport.x(for: min(range.upperBound, viewport.visibleRange.upperBound)).rounded()
        if range.overlaps(viewport.visibleRange), right > left {
            StretchBand(
                fill: DesignTokens.Colors.loopRegionFill,
                showsLeadingEdge: viewport.visibleRange.contains(range.lowerBound),
                showsTrailingEdge: viewport.visibleRange.contains(range.upperBound)
            )
            .frame(width: right - left)
            .frame(maxHeight: .infinity)
            .offset(x: left)
            .accessibilityHidden(true)
        }
    }
}

/// The loop's in and out while Loop is off, drawn in the ruler behind the
/// ticks and the bar numbers: a faint band with a bracket at each end that is
/// set, "[" at the in and "]" at the out. It is quieter than the band of a
/// loop that plays and has no column over the rows, so it never reads as a
/// selection. A missing end reaches to the start or end of the kept song and
/// has no bracket. Put it where `LoopRegionMark` goes, when Loop is off.
struct LoopInOutMark: View {
    let inOut: LoopInOut
    /// The part of the song that is kept, for an end that is not set.
    let song: ClosedRange<Double>
    let viewport: TimelineViewport

    var body: some View {
        if let range = inOut.range(in: song), range.overlaps(viewport.visibleRange) {
            let left = viewport.x(for: max(range.lowerBound, viewport.visibleRange.lowerBound)).rounded()
            let right = viewport.x(for: min(range.upperBound, viewport.visibleRange.upperBound)).rounded()
            if right > left {
                Rectangle()
                    .fill(DesignTokens.Colors.loopInOutFill)
                    .overlay(alignment: .leading) {
                        if inOut.inTime != nil, viewport.visibleRange.contains(range.lowerBound) {
                            Bracket(opensTo: .trailing)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if inOut.outTime != nil, viewport.visibleRange.contains(range.upperBound) {
                            Bracket(opensTo: .leading)
                        }
                    }
                    .frame(width: right - left)
                    .frame(maxHeight: .infinity)
                    .offset(x: left)
                    .accessibilityHidden(true)
            }
        }
    }

    /// An upright the height of the ruler with a short arm at its top and
    /// its bottom, both reaching into the stretch.
    private struct Bracket: View {
        let opensTo: HorizontalEdge

        var body: some View {
            let line = DesignTokens.Lines.loopInOutMarkWidth
            let arm = DesignTokens.Lines.loopInOutMarkArm
            let alignment: Alignment = opensTo == .trailing ? .leading : .trailing
            ZStack(alignment: alignment) {
                Rectangle().frame(width: line)
                VStack(spacing: 0) {
                    Rectangle().frame(width: arm, height: line)
                    Spacer(minLength: 0)
                    Rectangle().frame(width: arm, height: line)
                }
            }
            .frame(width: arm, alignment: alignment)
            .foregroundStyle(DesignTokens.Colors.loopInOutMark)
        }
    }
}

// MARK: - A clip that is moved

/// A clip on its way to another place: a faint dashed mark where it was
/// recorded, the clip itself drawn a little raised over the row it is over,
/// with its bar lit because the bar is what holds it, and the snap line when
/// it has snapped.
private struct MovedClipPicture: View {
    let moved: MovedClip
    let context: TimelineDragLayerContext

    var body: some View {
        let inset = DesignTokens.Spacing.clipInset
        ZStack(alignment: .topLeading) {
            if let from = context.rowFrame(of: moved.fromTrackID) {
                recordedPlace(in: from.insetBy(dx: 0, dy: inset))
            }
            if let over = context.rowFrame(of: moved.overTrackID) {
                liftedClip(height: over.height - 2 * inset)
                    .offset(x: context.bodyMinX, y: over.minY + inset - DesignTokens.Sizes.clipLift)
            }
            if let snap = moved.snap, let span = snapLineSpan(for: snap) {
                snapLine(snap, from: span.lowerBound, to: span.upperBound)
            }
        }
    }

    /// The mark left where the clip was recorded: the outline of the clip,
    /// dashed, with a faint fill. A clip always snaps to this place.
    @ViewBuilder
    private func recordedPlace(in box: CGRect) -> some View {
        let left = context.x(for: moved.recordedRange.lowerBound).rounded(.down)
        let width = CGFloat(
            (moved.recordedRange.upperBound - moved.recordedRange.lowerBound) * context.viewport.scale.pointsPerSecond
        )
        if width > 0, moved.recordedRange.overlaps(context.viewport.visibleRange) {
            DesignTokens.Shapes.clip
                .fill(DesignTokens.Colors.recordedPlaceFill)
                .overlay {
                    DesignTokens.Shapes.clip.strokeBorder(
                        DesignTokens.Colors.recordedPlaceOutline,
                        style: StrokeStyle(
                            lineWidth: DesignTokens.Lines.recordedPlaceOutlineWidth,
                            dash: DesignTokens.Lines.recordedPlaceDash
                        )
                    )
                }
                .frame(width: width, height: box.height)
                .offset(x: left, y: box.minY)
        }
    }

    /// The clip itself, placed as in a lane body, on a dark backing with a
    /// shadow so it reads as lying above the row.
    private func liftedClip(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let placement = ClipPlacement(clip: moved.clip, viewport: context.viewport) {
                DesignTokens.Shapes.clip
                    .fill(DesignTokens.Colors.liftedClipBacking)
                    .shadow(
                        color: DesignTokens.Colors.liftShadow,
                        radius: DesignTokens.Sizes.liftShadowRadius,
                        y: DesignTokens.Sizes.liftShadowOffset
                    )
                    .frame(width: placement.span.width)
                    .offset(x: placement.minX)
            }
            ClipView(clip: moved.clip, viewport: context.viewport, shownPointer: .bar)
        }
        .frame(height: height, alignment: .topLeading)
    }

    /// From where to where the snap line runs, as y in the drag layer: from
    /// the row of what the clip snapped to, to the row the clip is over. For
    /// the playhead it starts at the top, where the playhead comes from.
    private func snapLineSpan(for snap: SnapMark) -> ClosedRange<CGFloat>? {
        guard let over = context.rowFrame(of: moved.overTrackID) else { return nil }
        let other: CGRect?
        switch snap.kind {
        case .clipEdge(let trackID): other = context.rowFrame(of: trackID)
        case .recordedPlace: other = context.rowFrame(of: moved.fromTrackID)
        case .playhead: other = CGRect(x: 0, y: 0, width: 0, height: 0)
        case .gridLine: other = nil
        }
        let top = min(over.minY, other?.minY ?? over.minY)
        let bottom = max(over.maxY, other?.maxY ?? over.maxY)
        return top...bottom
    }

    /// The snap line, at the same place a beat line at that moment would be.
    /// It also crosses the gaps between rows, which no other line does.
    @ViewBuilder
    private func snapLine(_ snap: SnapMark, from top: CGFloat, to bottom: CGFloat) -> some View {
        if context.viewport.visibleRange.contains(snap.time) {
            let width = snap.kind == .playhead
                ? DesignTokens.Lines.snapLineOnPlayheadWidth
                : DesignTokens.Lines.snapLineWidth
            Rectangle()
                .fill(DesignTokens.Colors.snapLine)
                .frame(width: width, height: bottom - top)
                .offset(
                    x: context.bodyMinX + context.viewport.lineX(for: snap.time) - width / 2,
                    y: top
                )
        }
    }
}

// MARK: - A clip that is trimmed

/// What is drawn over the rows while an edge of a clip is dragged: the snap
/// line, when the edge has snapped. The clip itself is drawn in its row, with
/// the dragged edge lit.
private struct TrimmedClipPicture: View {
    let trimmed: TrimmedClip
    let context: TimelineDragLayerContext

    var body: some View {
        if let snap = trimmed.snap,
           let row = context.rowFrame(of: trimmed.trackID),
           context.viewport.visibleRange.contains(snap.time) {
            // From the row of what the edge snapped to, to the row of the
            // clip. For the playhead from the top, where the playhead comes from.
            let other: CGRect? = switch snap.kind {
            case .clipEdge(let trackID): context.rowFrame(of: trackID)
            case .playhead: .zero
            // A grid line is marked across the clip's own row.
            case .recordedPlace, .gridLine: nil
            }
            let top = min(row.minY, other?.minY ?? row.minY)
            let bottom = max(row.maxY, other?.maxY ?? row.maxY)
            let width = snap.kind == .playhead
                ? DesignTokens.Lines.snapLineOnPlayheadWidth
                : DesignTokens.Lines.snapLineWidth
            Rectangle()
                .fill(DesignTokens.Colors.snapLine)
                .frame(width: width, height: bottom - top)
                .offset(
                    x: context.bodyMinX + context.viewport.lineX(for: snap.time) - width / 2,
                    y: top
                )
        }
    }
}

// MARK: - A track that is moved

/// A track on its way to a new place: its own row dimmed, a line across the
/// timeline where it will land, and its header drawn lifted where the pointer
/// has taken it.
private struct MovedTrackPicture: View {
    let moved: MovedTrack
    /// The row of the moved track, where it still is.
    let row: CGRect
    let context: TimelineDragLayerContext

    var body: some View {
        let headerWidth = context.bodyMinX - DesignTokens.Spacing.laneGap
        ZStack(alignment: .topLeading) {
            if headerWidth > 0 {
                veil(width: headerWidth)
                    .offset(y: row.minY)
            }
            veil(width: row.width - context.bodyMinX)
                .offset(x: context.bodyMinX, y: row.minY)
            if let y = landingY {
                Capsule()
                    .fill(DesignTokens.Colors.trackLandingLine)
                    .frame(width: row.width, height: DesignTokens.Lines.trackLandingLineWidth)
                    .offset(y: y - DesignTokens.Lines.trackLandingLineWidth / 2)
            }
            if headerWidth > 0 {
                liftedHeader(width: headerWidth)
                    .offset(y: row.minY + moved.draggedBy)
            }
        }
    }

    private func veil(width: CGFloat) -> some View {
        DesignTokens.Shapes.lane
            .fill(DesignTokens.Colors.movedTrackVeil)
            .frame(width: max(width, 0), height: row.height)
    }

    /// The middle of the gap between the two rows the track will land between.
    private var landingY: CGFloat? {
        let halfGap = DesignTokens.Spacing.laneGap / 2
        switch moved.landing {
        case .before(let trackID): return context.rowFrame(of: trackID).map { $0.minY - halfGap }
        case .after(let trackID): return context.rowFrame(of: trackID).map { $0.maxY + halfGap }
        }
    }

    /// The track's header on a plain backing with a shadow. Plain, because
    /// it lies over the glass rows.
    private func liftedHeader(width: CGFloat) -> some View {
        TrackHeader(track: moved.track)
            .frame(width: width, height: row.height)
            .background(DesignTokens.Colors.liftedHeaderFill)
            .clipShape(DesignTokens.Shapes.lane)
            .shadow(
                color: DesignTokens.Colors.liftShadow,
                radius: DesignTokens.Sizes.liftShadowRadius,
                y: DesignTokens.Sizes.liftShadowOffset
            )
    }
}

import SwiftUI

/// A drag in the song row that is about the song itself: one of its edges,
/// or the whole song. The row reports it on every move and when it is let go.
///
///     lane.onDrag = { drag in model.songDragged(drag) }
///
/// The row changes nothing itself. The owner works out the new cut, or the
/// new place of the song, from how far the pointer has gone since the press
/// (`x - startX`, in points) and the zoom it had when the drag began, and
/// hands the row what is left of the song (`SongLane.kept`).
public struct SongDrag: Sendable, Equatable {
    public enum Part: Sendable, Equatable {
        /// The left edge: dragging it cuts the beginning of the song away, or brings it back.
        case start
        /// The right edge: the same for the end of the song.
        case end
        /// The song between its edges: dragging it moves the song along the timeline.
        case song
    }

    public var part: Part
    /// Where the button went down, in points from the left edge of the rows.
    public var startX: CGFloat
    /// Where the pointer is now, in the same points.
    public var x: CGFloat
    /// True for the last report of a drag, when the button is let go.
    public var isFinished: Bool

    public init(part: Part, startX: CGFloat, x: CGFloat, isFinished: Bool) {
        self.part = part
        self.startX = startX
        self.x = x
        self.isFinished = isFinished
    }
}

extension View {
    /// Lets the edges of the song, and the song itself, be dragged in the
    /// song row. The edge under the pointer lights up and the pointer
    /// becomes a resize arrow.
    ///
    /// - Parameters:
    ///   - kept: The part of the song that is left, in song seconds. Its two
    ///     ends are the edges.
    ///   - shownEdge: Draws this edge as if the pointer were over it, for
    ///     pictures. Nil follows the real pointer.
    ///   - onDrag: Told about every drag. Nil lights the edges up and
    ///     reports nothing.
    func songEdgeHover(
        kept: ClosedRange<Double>,
        viewport: TimelineViewport,
        shownEdge: SongDrag.Part? = nil,
        onDrag: (@MainActor (SongDrag) -> Void)? = nil
    ) -> some View {
        modifier(SongEdgeHover(kept: kept, viewport: viewport, shownEdge: shownEdge, onDrag: onDrag))
    }
}

private struct SongEdgeHover: ViewModifier {
    /// How far the pointer has to move before a press on an edge is a drag.
    /// Short, as for a beat line: an edge is a thin thing that was aimed at.
    private static let edgeDragStartDistance: CGFloat = 3
    /// How far it has to move before a press on the song moves the song: as
    /// far as SwiftUI itself starts a drag at, so a click in the row, which
    /// puts the playhead there, is never taken for a move.
    private static let songDragStartDistance: CGFloat = 10

    let kept: ClosedRange<Double>
    let viewport: TimelineViewport
    let shownEdge: SongDrag.Part?
    let onDrag: (@MainActor (SongDrag) -> Void)?

    @State private var edgeUnderPointer: SongDrag.Part?
    /// What the drag in progress is about. It is decided where the button
    /// went down and stays the same until it is let go.
    @State private var dragged: SongDrag.Part?

    func body(content: Content) -> some View {
        let lit = shownEdge ?? (dragged == .song ? nil : dragged) ?? edgeUnderPointer
        content
            .overlay(alignment: .topLeading) {
                if let lit, lit != .song {
                    highlight(of: lit)
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                // The edge that is dragged stays the one that is lit.
                guard dragged == nil else { return }
                var edge: SongDrag.Part?
                if case .active(let location) = phase {
                    edge = self.edge(atX: location.x)
                }
                if edge != edgeUnderPointer {
                    edgeUnderPointer = edge
                }
            }
            .pointerStyle(lit == nil ? nil : .columnResize)
            // An edge comes before everything else in the row, also before a
            // beat line that stands on it, which a cut on the beat always does.
            .highPriorityGesture(
                dragGesture(startingAfter: Self.edgeDragStartDistance),
                isEnabled: onDrag != nil && (edgeUnderPointer != nil || (dragged != nil && dragged != .song))
            )
            // The song itself comes after the beat lines, which are dragged in
            // this row too: a press on a beat line moves that line.
            .gesture(
                dragGesture(startingAfter: Self.songDragStartDistance),
                isEnabled: onDrag != nil && (edgeUnderPointer == nil || dragged == .song)
            )
    }

    private func dragGesture(startingAfter distance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: distance, coordinateSpace: .local)
            .onChanged { value in
                if dragged == nil {
                    dragged = part(atX: value.startLocation.x)
                }
                report(value, isFinished: false)
            }
            .onEnded { value in
                report(value, isFinished: true)
                dragged = nil
            }
    }

    private func report(_ value: DragGesture.Value, isFinished: Bool) {
        guard let dragged else { return }
        onDrag?(SongDrag(part: dragged, startX: value.startLocation.x, x: value.location.x, isFinished: isFinished))
    }

    /// The edge of the song near a place in the row, or nil when neither is.
    /// Where the song is so narrow that both are near, it is the nearer one.
    private func edge(atX x: CGFloat) -> SongDrag.Part? {
        let reach = DesignTokens.Sizes.songEdgeGrabDistance
        let toStart = abs(x - viewport.x(for: kept.lowerBound))
        let toEnd = abs(x - viewport.x(for: kept.upperBound))
        guard min(toStart, toEnd) <= reach else { return nil }
        return toStart <= toEnd ? .start : .end
    }

    /// What a press at a place in the row takes hold of: an edge, the song
    /// between its edges, or nothing where the song is cut away.
    private func part(atX x: CGFloat) -> SongDrag.Part? {
        if let edge = edge(atX: x) {
            return edge
        }
        let isOnSong = x >= viewport.x(for: kept.lowerBound) && x <= viewport.x(for: kept.upperBound)
        return isOnSong ? .song : nil
    }

    /// The edge lit up: a bar on the inside of the song's end, where the edge
    /// of a cut song is drawn too.
    private func highlight(of edge: SongDrag.Part) -> some View {
        let width = DesignTokens.Lines.songEdgeWidth
        let x = edge == .start
            ? viewport.x(for: kept.lowerBound)
            : viewport.x(for: kept.upperBound) - width
        return Rectangle()
            .fill(DesignTokens.Colors.beatLineHovered)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .overlay(alignment: edge == .start ? .leading : .trailing) {
                if shownEdge != nil {
                    // Stands in for the pointer in a picture.
                    Image(systemName: "arrow.left.and.right")
                        .font(DesignTokens.Fonts.symbol)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .fixedSize()
                        .offset(x: edge == .start ? DesignTokens.Spacing.medium : -DesignTokens.Spacing.medium)
                }
            }
            .offset(x: x)
            .allowsHitTesting(false)
    }
}

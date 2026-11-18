import SwiftUI

/// A beat line that was dragged to another place in the song.
public struct BeatLineMove: Sendable, Equatable {
    /// Where the beat line stood, in song seconds.
    public var from: Double
    /// Where it was let go, in song seconds.
    public var to: Double

    public init(from: Double, to: Double) {
        self.from = from
        self.to = to
    }
}

extension View {
    /// Lights up the beat line the pointer is over, in a row whose beat lines
    /// can be dragged: the song row. The line under the pointer is drawn
    /// brighter and wider, and the pointer becomes the arrows that point left
    /// and right.
    ///
    /// With `onMove`, the line can be dragged: the bright line follows the
    /// pointer, half the way to the next beat line at most to either side,
    /// and `onMove` is told once, when the line is let go somewhere else. A
    /// click that does not move is not a drag and is left to the row. Without
    /// `onMove` nothing happens on a drag. Zoomed so far out that only the bar
    /// lines are drawn (`TimelineBeats.closestLineSpacing`), no line lights up
    /// and none can be dragged.
    ///
    /// Put it on the row's content, which starts at the left edge of the row:
    ///
    ///     SongLaneBody(...).beatLineHover(beats: beats, viewport: viewport)
    ///
    /// - Parameters:
    ///   - beats: The beat lines that can be dragged. With none, nothing happens.
    ///   - shownBeat: Draws the beat at these song seconds as if the pointer
    ///     were over it, with a picture of the pointer beside it, because a
    ///     picture of the window does not show the real pointer. The design
    ///     lab uses it. Nil follows the real pointer.
    ///   - onMove: Told where a beat line was dragged from and to.
    func beatLineHover(
        beats: TimelineBeats,
        viewport: TimelineViewport,
        shownBeat: Double? = nil,
        onMove: (@MainActor (BeatLineMove) -> Void)? = nil
    ) -> some View {
        modifier(BeatLineHover(beats: beats, viewport: viewport, shownBeat: shownBeat, onMove: onMove))
    }
}

private struct BeatLineHover: ViewModifier {
    /// A beat line on its way: where it stood, how far it may go, and where it is now.
    private struct Drag: Equatable {
        /// Where the line stood when it was grabbed, in song seconds.
        var from: Double
        /// The song seconds the line may be dragged between.
        var range: ClosedRange<Double>
        /// How far from the line the pointer was when it grabbed it, in song
        /// seconds, so the line does not jump to the pointer.
        var grabOffset: Double
        /// Where the line is now.
        var position: Double
    }

    /// How far the pointer must move, in points, before a press on a beat
    /// line is a drag. Less than that is a click, which the row gets.
    private static let dragStartDistance: CGFloat = 3

    let beats: TimelineBeats
    let viewport: TimelineViewport
    let shownBeat: Double?
    let onMove: (@MainActor (BeatLineMove) -> Void)?

    /// The song seconds of the beat line the real pointer is over.
    @State private var beatUnderPointer: Double?
    /// The beat line that is being dragged. It is kept here, so a drag works
    /// out only this highlight again and not the row or the window.
    @State private var drag: Drag?

    func body(content: Content) -> some View {
        let hovered = hoveredBeat
        let beat = shownBeat ?? drag?.position ?? hovered
        content
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                if let beat {
                    highlight(at: viewport.lineX(for: beat))
                }
            }
            // One hover for the whole row, and not one view per beat line: a
            // long song has hundreds of beats on screen.
            .onContinuousHover(coordinateSpace: .local) { phase in
                // The line that is dragged stays the one that is lit.
                guard drag == nil else { return }
                var beat: Double?
                if case .active(let location) = phase {
                    beat = nearestBeat(atX: location.x)
                }
                if beat != beatUnderPointer {
                    beatUnderPointer = beat
                }
            }
            .pointerStyle(drag == nil && hovered == nil ? nil : .columnResize)
            // Only with the pointer on a beat line, so a press anywhere else
            // in the row is the row's own, as before.
            .gesture(dragGesture, isEnabled: onMove != nil && (hovered != nil || drag != nil))
    }

    /// The beat line the pointer is over, as long as a line still stands
    /// there. The lines can change under a pointer that lies still, as when a
    /// dragged line is let go or a change is undone.
    private var hoveredBeat: Double? {
        beatUnderPointer.flatMap { beats.lines(in: $0...$0).isEmpty ? nil : $0 }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: Self.dragStartDistance, coordinateSpace: .local)
            .onChanged { value in
                let scale = viewport.scale
                if drag == nil {
                    // The line that was grabbed is the one near the place
                    // where the button went down.
                    guard let grabbed = nearestBeat(atX: value.startLocation.x),
                        let range = beats.dragRange(forLineAt: grabbed)
                    else { return }
                    drag = Drag(
                        from: grabbed,
                        range: range,
                        grabOffset: scale.seconds(forX: Double(value.startLocation.x)) - grabbed,
                        position: grabbed
                    )
                }
                guard var moved = drag else { return }
                let seconds = scale.seconds(forX: Double(value.location.x)) - moved.grabOffset
                moved.position = min(max(seconds, moved.range.lowerBound), moved.range.upperBound)
                if moved != drag {
                    drag = moved
                }
            }
            .onEnded { _ in
                guard let ended = drag else { return }
                drag = nil
                // The pointer is still on the line, at its new place.
                beatUnderPointer = ended.position
                if ended.position != ended.from {
                    onMove?(BeatLineMove(from: ended.from, to: ended.position))
                }
            }
    }

    private func highlight(at x: CGFloat) -> some View {
        Rectangle()
            .fill(DesignTokens.Colors.beatLineHovered)
            .frame(width: DesignTokens.Lines.beatHoveredWidth)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                if shownBeat != nil {
                    // Stands in for the pointer in a picture.
                    Image(systemName: "arrow.left.and.right")
                        .font(DesignTokens.Fonts.symbol)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .fixedSize()
                        .offset(x: DesignTokens.Spacing.medium)
                }
            }
            .offset(x: x - DesignTokens.Lines.beatHoveredWidth / 2)
            .allowsHitTesting(false)
    }

    /// The beat line nearest to an x in the row, when one is near enough.
    private func nearestBeat(atX x: CGFloat) -> Double? {
        let pointsPerSecond = viewport.scale.pointsPerSecond
        guard pointsPerSecond > 0, !beats.lines.isEmpty else { return nil }
        let seconds = viewport.scale.seconds(forX: Double(x))
        let reach = Double(DesignTokens.Sizes.beatLineGrabDistance) / pointsPerSecond
        // Zoomed so far out that only the bar lines are drawn, no line can
        // be grabbed. A point is then a large part of a beat, so a drag could
        // only throw a line to its limit, and nearly every click in the row
        // would land on a line.
        guard !beats.showsBarLinesOnly(atPointsPerSecond: pointsPerSecond) else { return nil }
        return beats.lines(in: (seconds - reach)...(seconds + reach))
            .min { abs($0.time - seconds) < abs($1.time - seconds) }?
            .time
    }
}

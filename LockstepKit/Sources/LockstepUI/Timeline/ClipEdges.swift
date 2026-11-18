import LockstepCore
import SwiftUI

// The edges of a clip, which the clip is trimmed by: near its left or its
// right edge the pointer becomes the resize pointer, and a drag from there
// moves that edge and nothing else. `ClipView` draws the handles, and
// `TrackRowPart` tells a drag that starts on one from a drag by the bar.

/// Where the edges of a clip can be taken hold of. This is the one place
/// that says how wide that is, so the pointer changes exactly where a drag
/// would trim.
enum ClipEdgeZone {
    /// How far in from an edge of a clip the pointer takes hold of that
    /// edge, for a clip this many points wide. A narrow clip has narrower
    /// edges, so the middle half of it always moves the clip.
    static func width(ofClipWidth clipWidth: CGFloat) -> CGFloat {
        max(0, min(DesignTokens.Sizes.clipEdgeGrabWidth, clipWidth / 4))
    }

    /// The edge of a clip a moment in the song is on, or nil when it is in
    /// the middle of the clip.
    ///
    /// - Parameters:
    ///   - seconds: The moment, in song seconds, inside `range`.
    ///   - range: From the start of the clip to its end, in song seconds.
    ///   - pointsPerSecond: The zoom the clip is drawn at.
    static func edge(atSeconds seconds: Double, in range: ClosedRange<Double>, pointsPerSecond: Double) -> ClipEdge? {
        guard pointsPerSecond > 0 else { return nil }
        let clipWidth = (range.upperBound - range.lowerBound) * pointsPerSecond
        let zone = Double(width(ofClipWidth: CGFloat(clipWidth)))
        let fromStart = (seconds - range.lowerBound) * pointsPerSecond
        if fromStart < zone { return .start }
        if clipWidth - fromStart <= zone { return .end }
        return nil
    }
}

/// An edge of a clip on its way to another place, as it is dragged.
public struct ClipEdgeDrag: Sendable, Equatable {
    /// The clip whose edge was grabbed.
    public var clipID: UUID
    /// The track the clip is on.
    public var trackID: UUID
    /// Which edge it is.
    public var edge: ClipEdge
    /// The moment in the song that was under the pointer when the edge was
    /// grabbed, in song seconds. It stays the same for the whole drag.
    public var startSeconds: Double
    /// Where the pointer is now, in points from the left edge of the rows
    /// (the header column not counted). It is below zero or beyond the width
    /// of the rows when the pointer has left them sideways. The owner turns
    /// it into song seconds with the scale as it is at that moment, so the
    /// edge stays under the pointer while the timeline scrolls.
    public var x: CGFloat
    /// True for the last report, when the button was let go.
    public var isFinished: Bool

    public init(clipID: UUID, trackID: UUID, edge: ClipEdge, startSeconds: Double, x: CGFloat, isFinished: Bool) {
        self.clipID = clipID
        self.trackID = trackID
        self.edge = edge
        self.startSeconds = startSeconds
        self.x = x
        self.isFinished = isFinished
    }

    /// True when both reports come from the same press of the button: the
    /// same edge of the same clip, grabbed at the same moment in the song.
    public func isSameDrag(as other: ClipEdgeDrag) -> Bool {
        clipID == other.clipID && trackID == other.trackID && edge == other.edge
            && startSeconds == other.startSeconds
    }
}

/// The two edges of a clip as the pointer meets them: a strip along each
/// edge, over the whole height of the clip, where the pointer is the resize
/// pointer. The edge the pointer is over, or that is being dragged, is drawn
/// as a thin bright bar. `ClipView` lays it over the clip.
struct ClipEdgeHandles: View {
    @Environment(\.timelinePalette) private var palette

    /// The width of the part of the clip that is drawn.
    let width: CGFloat
    /// The drawn part begins where the clip begins, so its start can be
    /// taken hold of.
    let hasStart: Bool
    /// The drawn part ends where the clip ends, and no other clip lies over
    /// that end.
    let hasEnd: Bool
    /// The edge that is drawn lit, or nil.
    let lit: ClipEdge?

    var body: some View {
        let zone = ClipEdgeZone.width(ofClipWidth: width)
        HStack(spacing: 0) {
            if hasStart {
                strip(.start, width: zone)
            }
            Spacer(minLength: 0)
            if hasEnd {
                strip(.end, width: zone)
            }
        }
    }

    private func strip(_ edge: ClipEdge, width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .overlay(alignment: edge == .start ? .leading : .trailing) {
                if lit == edge {
                    handle(edge, width: min(DesignTokens.Sizes.clipEdgeHandleWidth, width))
                }
            }
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
    }

    /// The bright bar along an edge. Its outer corners are the clip's own.
    private func handle(_ edge: ClipEdge, width: CGFloat) -> some View {
        let outer = DesignTokens.Radius.clip
        return UnevenRoundedRectangle(
            topLeadingRadius: edge == .start ? outer : 0,
            bottomLeadingRadius: edge == .start ? outer : 0,
            bottomTrailingRadius: edge == .end ? outer : 0,
            topTrailingRadius: edge == .end ? outer : 0,
            style: .continuous
        )
        .fill(palette.clipOutlineSelected)
        .frame(width: width)
        .accessibilityHidden(true)
    }
}

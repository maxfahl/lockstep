import LockstepCore
import SwiftUI

/// The part of a timeline that is on screen right now. A lane body, the ruler
/// and the drag layer are each given one and draw from it.
public struct TimelineViewport: Equatable, Sendable {
    /// Converts song seconds to x. x = 0 is the left edge of the lane bodies,
    /// which is also the left edge of every lane body's own view and of the ruler.
    public var scale: TimelineScale
    /// The song seconds that are on screen, cut to the range the timeline
    /// covers. A lane draws only what falls inside it.
    public var visibleRange: ClosedRange<Double>

    public init(scale: TimelineScale, visibleRange: ClosedRange<Double>) {
        self.scale = scale
        self.visibleRange = visibleRange
    }

    /// Where a moment in the song sits, counted in points from the left edge
    /// of a lane body. Use it for everything that has a width: waveforms,
    /// clips, bands.
    public func x(for seconds: Double) -> CGFloat {
        CGFloat(scale.x(for: seconds))
    }

    /// Where a thin vertical line for a moment in the song is drawn. It is
    /// `x(for:)` moved onto the middle of a whole point, so a line of one
    /// point comes out sharp. The beat lines use it; the ruler uses it for its
    /// ticks so they meet the beat lines exactly.
    public func lineX(for seconds: Double) -> CGFloat {
        x(for: seconds).rounded(.down) + DesignTokens.Lines.beatWidth / 2
    }
}

/// One kind of row in a timeline: the song, a vocal track, a take, or anything
/// added later. `Timeline` knows nothing about what a lane shows.
///
/// A new kind of lane is a struct that conforms to this protocol:
///
///     struct MarkerLane: TimelineLane {
///         let id: String
///         let markers: [Double]
///         var height: CGFloat { DesignTokens.Sizes.takeLaneHeight }
///
///         func header() -> some View { Text("Markers") }
///
///         func content(in viewport: TimelineViewport) -> some View {
///             MarkerLaneBody(markers: markers, viewport: viewport)
///         }
///     }
///
/// and is handed to the timeline wrapped in `AnyTimelineLane`, so different
/// kinds can be mixed in one list:
///
///     Timeline(lanes: [AnyTimelineLane(MarkerLane(...)), AnyTimelineLane(SongLane(...))], ...)
///
/// What the timeline does for every lane, so a lane must not do it itself:
/// the row background and its rounded outline (body and header), the beat and
/// bar lines on top of the body, the playhead, and the space between rows.
///
/// A lane is never told where the playhead is. If a lane needs it some day, it
/// must read it in a small view of its own, the way the timeline's playhead
/// does, so that playing does not draw every row again on each frame.
public protocol TimelineLane: Identifiable {
    /// The view in the header column, to the left of the row.
    associatedtype Header: View = EmptyView
    /// The view of the row itself.
    associatedtype Content: View

    /// Tells this row from the others. It comes back in every report about
    /// the row (a tap, a drag), wrapped in `AnyHashable`. No two rows of one
    /// timeline may share an id, and it must stay the same while the row is on
    /// screen, so use the id of what the row shows.
    var id: ID { get }

    /// The height of the row in points. Take it from `DesignTokens.Sizes`.
    var height: CGFloat { get }

    /// A pinned row stays under the ruler while the other rows scroll up and
    /// down beneath it. Pinned rows are shown first, in the order they have in
    /// the list. Starting value: false.
    var isPinned: Bool { get }

    /// Whether the timeline gives the row its background and draws the beat
    /// lines through it. False for a row that is not really a row, such as the
    /// one that only holds the "New Track" button: it is drawn straight on the
    /// window, with no beat lines. Starting value: true.
    var hasRowSurface: Bool { get }

    /// The header of the row. It is given the whole header cell (the
    /// timeline's header width by the row's height) and sits at its left edge,
    /// centred vertically. Leave it out for an empty header. It is not shown
    /// at all when the timeline has no header column.
    @MainActor @ViewBuilder func header() -> Header

    /// The row itself. It is given the whole row (the width of the lane bodies
    /// by the row's height) with x = 0 at its left edge, and draws its own
    /// content for `viewport.visibleRange`, placed with `viewport.x(for:)`.
    /// It draws no background, no beat lines and no playhead.
    @MainActor @ViewBuilder func content(in viewport: TimelineViewport) -> Content

    /// Whether this lane shows exactly what another lane of its kind shows:
    /// the same header and the same content for every viewport, and the same
    /// `height`, `isPinned` and `hasRowSurface`.
    ///
    /// The timeline asks it when its owner has made the lanes again, as after
    /// every edit. A lane that says yes is left as it is: its header and its
    /// content are not worked out again. That is what keeps an edit of one
    /// track from working out every row of a big project.
    ///
    /// A lane that says yes keeps the closures it was handed first. So say
    /// yes only when the closures of both do the same: closures that tell an
    /// owner, and read what they need when they are called. A lane that
    /// cannot tell leaves this out, which says no, and is worked out again
    /// every time, as every lane was.
    func showsSame(as other: Self) -> Bool
}

extension TimelineLane {
    public var isPinned: Bool { false }
    public var hasRowSurface: Bool { true }
    public func showsSame(as other: Self) -> Bool { false }
}

extension TimelineLane where Header == EmptyView {
    @MainActor public func header() -> EmptyView { EmptyView() }
}

/// A lane of any kind. A timeline takes a list of these, so rows of different
/// kinds can sit in the same timeline.
public struct AnyTimelineLane: Identifiable {
    private let base: any TimelineLane

    /// The lane's own id, wrapped. Compare it with `AnyHashable(track.id)`, or
    /// get the value back with `id.base as? UUID`.
    public let id: AnyHashable

    public init(_ lane: some TimelineLane) {
        base = lane
        id = AnyHashable(lane.id)
    }

    public var height: CGFloat { base.height }
    public var isPinned: Bool { base.isPinned }
    public var hasRowSurface: Bool { base.hasRowSurface }

    @MainActor func header() -> AnyView {
        Self.header(of: base)
    }

    @MainActor func content(in viewport: TimelineViewport) -> AnyView {
        Self.content(of: base, in: viewport)
    }

    /// Whether this lane shows what another shows: they are of the same kind
    /// and say so themselves (`TimelineLane.showsSame(as:)`).
    func showsSame(as other: AnyTimelineLane) -> Bool {
        Self.showsSame(base, as: other.base)
    }

    private static func showsSame<Lane: TimelineLane>(_ lane: Lane, as other: any TimelineLane) -> Bool {
        guard let other = other as? Lane else { return false }
        return lane.showsSame(as: other)
    }

    @MainActor private static func header(of lane: some TimelineLane) -> AnyView {
        AnyView(lane.header())
    }

    @MainActor private static func content(of lane: some TimelineLane, in viewport: TimelineViewport) -> AnyView {
        AnyView(lane.content(in: viewport))
    }
}

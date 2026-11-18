import SwiftUI

// What a timeline reports back, and what it hands to its drag layer.
//
// A timeline does nothing itself when a row is clicked or dragged. It only
// says which row and which moment in the song, and whoever shows the timeline
// decides what that means (moving the playhead, selecting, reordering tracks).
// A gesture is listened for only when its report is asked for:
//
//     Timeline(...)
//         .onLaneTap { tap in ... }
//         .onLaneDoubleTap { tap in ... }
//         .onRulerTap { seconds in ... }
//         .onRulerDrag { drag in ... }
//         .onLaneDrag { drag in ... }
//         .onHeaderDrag { drag in ... }
//         .onHeaderTap { laneID in ... }
//         .dragLayer { context in ... }
//
// A lane's own controls (a clip, a mute button) keep their own gestures. They
// win over the timeline's, which only get what the lane's content leaves.

extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    /// The coordinates of a timeline's rows, shared by its reports and its
    /// drag layer. The origin is the top left corner of the first row,
    /// headers included, right under the ruler. y grows downwards and does not
    /// move when the rows scroll. A lane can measure its own gestures in it:
    /// `DragGesture(coordinateSpace: .timelineLanes)`.
    public static var timelineLanes: NamedCoordinateSpace {
        .named("Lockstep.Timeline.lanes")
    }
}

/// A click in the body of a row.
public struct TimelineLaneTap {
    /// The row that was clicked.
    public var laneID: AnyHashable
    /// The moment in the song under the pointer, in song seconds.
    public var seconds: Double
    /// Where the pointer is inside the row's body, in points: x from the
    /// body's left edge, y from the row's top. With it the owner can tell
    /// which part of the row was clicked.
    public var location: CGPoint
}

/// A drag that started in the body of a row. Reported on every move and once
/// more when the button is let go.
public struct TimelineLaneDrag {
    /// The row the drag started in.
    public var laneID: AnyHashable
    /// The moment in the song where the drag started, in song seconds.
    public var startSeconds: Double
    /// The moment in the song under the pointer now, in song seconds.
    public var seconds: Double
    /// Where the drag started, in `.timelineLanes` coordinates.
    public var startLocation: CGPoint
    /// Where the pointer is now, in `.timelineLanes` coordinates.
    public var location: CGPoint
    /// Where the drag started inside the row's body, in points: x from the
    /// body's left edge, y from the row's top. With it the owner can tell
    /// which part of the row the drag started on.
    public var startInBody: CGPoint
    /// Where the pointer is now, counted the same way from the same row. It
    /// lies outside the row once the pointer has left it: y is negative
    /// above the row and larger than the row's height below it.
    public var inBody: CGPoint
    /// True for the last report, when the button was let go.
    public var isFinished: Bool
}

/// A press in the ruler and the drag that follows it, as when the playhead is
/// dragged. Reported when the button goes down, on every move and once more
/// when the button is let go. A click is a press and a release at one place:
/// two reports with the same `x`.
///
/// The drag goes on wherever the pointer is taken, also above and below the
/// ruler and out of the timeline sideways.
public struct TimelineRulerDrag: Sendable, Equatable {
    /// Where the button went down, in points from the left edge of the rows
    /// (the header column not counted). It stays the same for the whole drag.
    public var startX: CGFloat
    /// Where the pointer is now, counted the same way. It is below zero or
    /// beyond the width of the rows when the pointer has left them sideways.
    /// The owner turns it into song seconds with the scale as it is at that
    /// moment, so what is dragged stays under the pointer while the timeline
    /// scrolls.
    public var x: CGFloat
    /// True for the last report, when the button was let go.
    public var isFinished: Bool

    public init(startX: CGFloat, x: CGFloat, isFinished: Bool) {
        self.startX = startX
        self.x = x
        self.isFinished = isFinished
    }
}

/// A drag that started on the header of a row, as when a track is moved up or
/// down. Reported on every move and once more when the button is let go.
public struct TimelineHeaderDrag {
    /// The row whose header was grabbed.
    public var laneID: AnyHashable
    /// Where the drag started, as y in `.timelineLanes` coordinates.
    public var startY: CGFloat
    /// Where the pointer is now, as y in `.timelineLanes` coordinates.
    public var y: CGFloat
    /// True for the last report, when the button was let go.
    public var isFinished: Bool
}

/// Where one row is right now, for the drag layer.
public struct TimelineLaneFrame {
    public var laneID: AnyHashable
    /// The whole row, header included, in `.timelineLanes` coordinates. A row
    /// that has scrolled away has a frame outside the timeline.
    public var frame: CGRect
    public var isPinned: Bool
}

/// What the drag layer is given to draw from. The drag layer lies on top of
/// all rows and their headers, under the playhead, and uses `.timelineLanes`
/// coordinates. It is drawn again when the rows scroll up or down.
public struct TimelineDragLayerContext {
    public var viewport: TimelineViewport
    /// The x of the left edge of the lane bodies. Zero without a header column.
    public var bodyMinX: CGFloat
    /// Every row, pinned rows first, in the order they are shown.
    public var laneFrames: [TimelineLaneFrame]
    /// The y where the rows that scroll begin. Above it only pinned rows show.
    public var scrollAreaMinY: CGFloat

    /// Where a moment in the song sits in the drag layer.
    public func x(for seconds: Double) -> CGFloat {
        bodyMinX + viewport.x(for: seconds)
    }

    /// The moment in the song at an x in the drag layer.
    public func seconds(forX x: CGFloat) -> Double {
        viewport.scale.seconds(forX: Double(x - bodyMinX))
    }

    /// The row that is shown at a y in the drag layer, or nil between and
    /// below the rows.
    public func laneID(atY y: CGFloat) -> AnyHashable? {
        laneFrames.first { lane in
            (lane.isPinned || y >= scrollAreaMinY) && lane.frame.minY <= y && y < lane.frame.maxY
        }?.laneID
    }
}

/// The reports a timeline was asked for. Empty until one of the `on...`
/// methods of `Timeline` is used.
struct TimelineReports {
    var laneTap: ((TimelineLaneTap) -> Void)?
    /// A double-click in the body of a row.
    var laneDoubleTap: ((TimelineLaneTap) -> Void)?
    /// A click in the ruler: the moment in the song under the pointer.
    var rulerTap: ((Double) -> Void)?
    /// A press in the ruler and the drag that follows. When it is asked for,
    /// `rulerTap` is not reported: the press is the first report of the drag.
    var rulerDrag: ((TimelineRulerDrag) -> Void)?
    /// The width of the lane bodies, when the timeline appears and whenever it changes.
    var bodyWidth: ((CGFloat) -> Void)?
    var laneDrag: ((TimelineLaneDrag) -> Void)?
    /// How far the pointer must have moved before a press in the body of a
    /// row counts as a drag, in points. 10 is where SwiftUI itself starts a
    /// drag when it is told nothing else.
    var laneDragStartDistance: CGFloat = 10
    var headerDrag: ((TimelineHeaderDrag) -> Void)?
    /// A click on the header of a row: the id of that row.
    var headerTap: ((AnyHashable) -> Void)?
    /// Scrolling with Shift held: how far, in points, positive for taller rows.
    var rowHeightScroll: ((CGFloat) -> Void)?
}

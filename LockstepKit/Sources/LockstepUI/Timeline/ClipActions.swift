import LockstepCore
import SwiftUI

/// What the clips of the main timeline tell their owner when one of them is
/// used with the pointer.
///
/// The design lab leaves it out, so its clips are pictures. The real app fills
/// in what works and hands it to `MainLayout`:
///
///     var clips = ClipActions()
///     clips.barDragged = { drag in model.clipBarDragged(drag) }
///     clips.nameDoubleClicked = { clipID in model.startRenamingClip(clipID) }
///     clips.renameEnded = { clipID, name in model.endRenamingClip(clipID, as: name) }
///     clips.stretchDragged = { drag in model.stretchDragged(drag) }
///     actions.clips = clips
///
/// Every action left nil leaves its part of a clip doing nothing.
public struct ClipActions {
    /// A clip is being dragged by its bar. Told on every move and once more
    /// when it is let go. The owner shows the drag with
    /// `TimelineDragging.movedClip` and moves the clip when it ends.
    public var barDragged: (@MainActor (ClipBarDrag) -> Void)?

    /// A clip is being dragged by its left or its right edge: the clip is
    /// trimmed. Told on every move and once more when the edge is let go.
    /// The owner shows the trim by handing in the clip with its edge where
    /// the drag has taken it, with `ClipBox.trimmedEdge` set, and shows a
    /// snap with `TimelineDragging.trimmedClip`. Nil leaves the edges
    /// alone: a drag from one is then a drag from the bar or the body it
    /// started on.
    public var edgeDragged: (@MainActor (ClipEdgeDrag) -> Void)?

    /// The bar of the clip with this id was double-clicked. The owner then
    /// sets `ClipBox.isBeingRenamed`, which puts a text field in the bar.
    public var nameDoubleClicked: (@MainActor (UUID) -> Void)?

    /// The typing of a clip's name is over: the id of the clip and the name
    /// as it was typed, or nil when it was given up with Escape. The owner
    /// then takes `ClipBox.isBeingRenamed` away.
    ///
    /// With this set, the bar of a clip that is being renamed holds a real
    /// text field: it takes the keyboard when it appears, with the whole name
    /// selected. Return, a click anywhere else and the field going away all
    /// end the typing with the name. Without it the field is a picture.
    public var renameEnded: (@MainActor (UUID, String?) -> Void)?

    /// The pointer is being dragged sideways across a track's row, from a
    /// place that is not a clip's bar: a stretch of that track is being
    /// marked. Told on every move and once more when the button is let go.
    /// The owner shows the stretch with `TimelineDragging.markedStretch`.
    ///
    /// The report also says how many rows away the pointer is
    /// (`StretchDrag.rowsDown`). In another track's row the drag is a
    /// rectangle that selects clips (`SelectionDrag` in `LockstepCore` says
    /// which it is), and the owner shows it with
    /// `TimelineDragging.selectionRectangle`.
    public var stretchDragged: (@MainActor (StretchDrag) -> Void)?

    /// A syllable marker of a clip was clicked: the id of the clip and the
    /// id of the marker (`SyllableMarker.id`). The owner then leaves that
    /// syllable out of the timing fixes, or takes it back in, and changes
    /// `SyllableMarker.isExcluded`. With this set, such a click is told here
    /// and not as a click in the track's row. Nil leaves the markers to be
    /// looked at only.
    public var markerClicked: (@MainActor (_ clipID: UUID, _ markerID: SyllableMarker.ID) -> Void)?

    public init() {}
}

/// A stretch of one track that is being marked, as the pointer is dragged
/// across the track's row. With the pointer in another track's row, the same
/// drag is a rectangle over the rows between, which selects clips.
public struct StretchDrag: Sendable, Equatable {
    /// The track whose row the drag started in. A stretch is on this track,
    /// and a rectangle starts in its row.
    public var trackID: UUID
    /// The moment in the song that was under the pointer when the drag
    /// started, in song seconds. It stays the same for the whole drag and is
    /// one end of the stretch.
    public var startSeconds: Double
    /// Where the pointer is now, in points from the left edge of the rows
    /// (the header column not counted). It is below zero or beyond the width
    /// of the rows when the pointer has left them sideways. The owner turns
    /// it into song seconds with the scale as it is at that moment, which is
    /// the other end of the stretch, so the end stays under the pointer
    /// while the timeline scrolls.
    public var x: CGFloat
    /// How many whole rows below the row it started in the pointer is now.
    /// Negative is above. Zero while the pointer is in the row the drag
    /// started in. It can point past the first or the last track.
    public var rowsDown: Int
    /// True for the last report, when the button was let go.
    public var isFinished: Bool

    public init(trackID: UUID, startSeconds: Double, x: CGFloat, rowsDown: Int, isFinished: Bool) {
        self.trackID = trackID
        self.startSeconds = startSeconds
        self.x = x
        self.rowsDown = rowsDown
        self.isFinished = isFinished
    }

    /// True when both reports come from the same press of the button: the
    /// same track, from the same moment in the song. Where the pointer is
    /// now, sideways or in rows, does not count.
    public func isSameDrag(as other: StretchDrag) -> Bool {
        trackID == other.trackID && startSeconds == other.startSeconds
    }
}

/// A clip on its way to another place, as its bar is dragged.
public struct ClipBarDrag: Sendable, Equatable {
    /// The clip whose bar was grabbed.
    public var clipID: UUID
    /// The track the clip was on when it was grabbed.
    public var trackID: UUID
    /// The moment in the song that was under the pointer when the bar was
    /// grabbed, in song seconds. It stays the same for the whole drag.
    public var startSeconds: Double
    /// Where the pointer is now, in points from the left edge of the rows
    /// (the header column not counted). It is below zero or beyond the width
    /// of the rows when the pointer has left them sideways. The owner turns
    /// it into song seconds with the scale as it is at that moment, so the
    /// clip stays under the pointer while the timeline scrolls.
    public var x: CGFloat
    /// How many rows below the row it was grabbed in the pointer is now.
    /// Negative is above. It can point past the first or the last track.
    public var rowsDown: Int
    /// True for the last report, when the button was let go.
    public var isFinished: Bool

    public init(
        clipID: UUID,
        trackID: UUID,
        startSeconds: Double,
        x: CGFloat,
        rowsDown: Int,
        isFinished: Bool
    ) {
        self.clipID = clipID
        self.trackID = trackID
        self.startSeconds = startSeconds
        self.x = x
        self.rowsDown = rowsDown
        self.isFinished = isFinished
    }

    /// True when both reports come from the same press of the button: the
    /// same clip, grabbed at the same moment in the song.
    public func isSameDrag(as other: ClipBarDrag) -> Bool {
        clipID == other.clipID && trackID == other.trackID && startSeconds == other.startSeconds
    }
}

/// What a place in a track's row is on. A click and a drag mean different
/// things on each: a drag that starts on a clip's bar moves the clip, and one
/// that starts anywhere else does not.
///
/// This is the one place that says which part of a row is which. `MainTimeline`
/// asks it where a drag started and decides from the answer who is told.
public enum TrackRowPart: Sendable, Equatable {
    /// The bar along the top of the clip with this id.
    case clipBar(UUID)
    /// The waveform of the clip with this id, under its bar.
    case clipBody(UUID)
    /// The left or the right edge of the clip with this id, over the clip's
    /// whole height. A drag from it trims the clip. It is only told apart
    /// from the bar and the body when the zoom is handed in.
    case clipEdge(UUID, ClipEdge)
    /// No clip: the row itself.
    case emptyLane

    /// - Parameters:
    ///   - track: The row.
    ///   - seconds: The moment in the song, in song seconds.
    ///   - y: The distance from the top of the row, in points.
    ///   - rowHeight: The height the row is drawn with. Left out, it is
    ///     `DesignTokens.Sizes.trackLaneHeight`.
    ///   - pointsPerSecond: The zoom the row is drawn at. With it, the
    ///     edges of a clip are told apart from its bar and its body. Left
    ///     out, a place on an edge is on the bar or the body.
    ///
    /// Where clips lie over each other it is the one that starts last,
    /// because that one is drawn in front.
    public init(
        in track: TrackRow,
        atSeconds seconds: Double,
        y: CGFloat,
        rowHeight: CGFloat = DesignTokens.Sizes.trackLaneHeight,
        pointsPerSecond: Double? = nil
    ) {
        let top = DesignTokens.Spacing.clipInset
        let bottom = rowHeight - DesignTokens.Spacing.clipInset
        var front: (id: UUID, start: Double, range: ClosedRange<Double>)?
        for clip in track.clips {
            guard let range = clip.timeRange, range.lowerBound <= seconds, seconds < range.upperBound
            else { continue }
            if front.map({ range.lowerBound >= $0.start }) ?? true {
                front = (clip.id, range.lowerBound, range)
            }
        }
        guard let front, y >= top, y < bottom else {
            self = .emptyLane
            return
        }
        if let pointsPerSecond,
           let edge = ClipEdgeZone.edge(atSeconds: seconds, in: front.range, pointsPerSecond: pointsPerSecond) {
            self = .clipEdge(front.id, edge)
            return
        }
        self = y < top + DesignTokens.Sizes.clipBarHeight ? .clipBar(front.id) : .clipBody(front.id)
    }
}

extension TrackRow {
    /// The syllable marker at a place in this row, with its clip, or nil
    /// when there is none there.
    ///
    /// A marker is there when the place is in the strip under its clip's bar
    /// where the markers are drawn, and within reach of it sideways: the same
    /// strip and the same reach in which the pointer brings up a marker's
    /// readout. Where two are within reach it is the nearer one. Zoomed out
    /// so far that markers have no dots, there is none: an excluded syllable
    /// could not be told from the others there.
    ///
    /// - Parameters:
    ///   - seconds: The moment in the song, in song seconds.
    ///   - y: The distance from the top of the row, in points.
    ///   - pointsPerSecond: The zoom the row is drawn at.
    ///   - rowHeight: The height the row is drawn with.
    func marker(
        atSeconds seconds: Double,
        y: CGFloat,
        pointsPerSecond: Double,
        rowHeight: CGFloat
    ) -> (clipID: UUID, markerID: SyllableMarker.ID)? {
        let reach = DesignTokens.Sizes.markerHoverReach
        let clipY = y - DesignTokens.Spacing.clipInset
        // The markers of a low row are smaller, so the strip is too.
        let size = MarkerSize(clipHeight: rowHeight - 2 * DesignTokens.Spacing.clipInset)
        guard MarkerDetail(pointsPerSecond: pointsPerSecond) == .dots,
              clipY >= DesignTokens.Sizes.clipBarHeight,
              clipY <= size.tickBottom + reach,
              case .clipBody(let clipID) = TrackRowPart(in: self, atSeconds: seconds, y: y, rowHeight: rowHeight),
              let marks = clips.first(where: { $0.id == clipID })?.timingMarks
        else { return nil }

        var nearest: SyllableMarker.ID?
        var nearestDistance = reach
        for marker in marks.markers where marker.hasDistance {
            let distance = CGFloat(abs(marker.time - seconds) * pointsPerSecond)
            // A marker that lies under the next clip on the track is not drawn.
            guard distance <= nearestDistance,
                  case .clipBody(clipID) = TrackRowPart(in: self, atSeconds: marker.time, y: y, rowHeight: rowHeight)
            else { continue }
            nearest = marker.id
            nearestDistance = distance
        }
        return nearest.map { (clipID, $0) }
    }
}

/// Remembers what the drag in progress in a track's row started on, and
/// whether it has gone far enough to count. The rows change while a clip is
/// dragged (the clip is lifted out of its row), so the question is asked once,
/// at the first report of a drag, and the answer kept until the button is let
/// go.
///
/// How far is far enough depends on what the drag started on. A clip is moved
/// by its bar once the pointer has gone 10 points in any direction. A stretch
/// is marked, and an edge of a clip is trimmed, once the pointer has gone
/// more than 3 points sideways. A press that moves less is a click and no
/// drag at all.
///
/// It is an object that no view watches, so remembering makes nothing draw.
@MainActor
final class TrackRowDragMemory {
    /// How far the pointer must go, in any direction, before a clip is moved
    /// by its bar, in points.
    static let barStartDistance: CGFloat = 10
    /// How far the pointer must go sideways before a stretch is marked, in
    /// points. The stretch starts when it has gone further than this.
    static let stretchStartDistance: CGFloat = 3

    /// Where the drag in progress started, what on, and whether it has gone
    /// far enough to count. Nil between drags.
    private var drag: (start: CGPoint, part: TrackRowPart, isUnderWay: Bool)?

    /// What the drag of this report started on, or nil while the pointer has
    /// not gone far enough for the press to be a drag. Once a drag counts,
    /// every later report of it does, the last one included. `rowHeight` is
    /// the height the track's row is drawn with.
    ///
    /// - Parameter pointsPerSecond: The zoom the row is drawn at, when a drag
    ///   from the edge of a clip trims it. Nil when nothing listens for that:
    ///   an edge is then part of the bar or the body.
    func part(
        of report: TimelineLaneDrag,
        in track: TrackRow,
        rowHeight: CGFloat,
        pointsPerSecond: Double? = nil
    ) -> TrackRowPart? {
        let part: TrackRowPart
        var isUnderWay = false
        // A drag whose end was never reported is told from the next one by
        // where it started.
        if let drag, drag.start == report.startLocation {
            part = drag.part
            isUnderWay = drag.isUnderWay
        } else {
            part = TrackRowPart(
                in: track,
                atSeconds: report.startSeconds,
                y: report.startInBody.y,
                rowHeight: rowHeight,
                pointsPerSecond: pointsPerSecond
            )
        }
        if !isUnderWay {
            let sideways = report.location.x - report.startLocation.x
            let down = report.location.y - report.startLocation.y
            switch part {
            case .clipBar:
                isUnderWay = hypot(sideways, down) >= Self.barStartDistance
            case .clipBody, .emptyLane, .clipEdge:
                isUnderWay = abs(sideways) > Self.stretchStartDistance
            }
        }
        drag = report.isFinished ? nil : (report.startLocation, part, isUnderWay)
        return isUnderWay ? part : nil
    }
}

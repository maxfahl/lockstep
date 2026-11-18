import Foundation
import LockstepCore

/// What the main timeline draws on top of its rows while something is
/// dragged, and the loop region. It is part of `TimelineContent`:
///
///     content.timeline.dragging.markedStretch = MarkedStretch(trackID: track.id, range: 21...24)
///
/// Everything is nil most of the time, and then nothing is drawn. The design
/// lab fills it by hand to show a drag frozen at one moment. The real app
/// fills it from the drag that is going on.
public struct TimelineDragging: Sendable, Equatable {
    /// A clip that is being moved by its bar.
    public var movedClip: MovedClip?
    /// The stretch of one track that is marked.
    public var markedStretch: MarkedStretch?
    /// The rectangle of a drag that has left the row it started in and
    /// selects clips on several tracks. It is there only while the button is
    /// down, and never together with a marked stretch. The clips it selects
    /// are drawn selected in their rows (`ClipBox.isSelected`). Set it after
    /// making the value.
    public var selectionRectangle: SelectionRectangle?
    /// The loop region, in song seconds, drawn in the ruler. It is there as
    /// long as Loop is on, with or without a marked stretch.
    public var loopRange: ClosedRange<Double>?
    /// The loop's in and out, set with I and O, while Loop is off. They are
    /// drawn in the ruler only, quieter than a loop that plays, and never
    /// over the rows, so they do not read as a selection. While `loopRange`
    /// is set it is drawn instead. They draw nothing over the rows, so they
    /// do not count in `isEmpty`.
    public var loopInOut: LoopInOut?
    /// A track that is being moved up or down by its header.
    public var movedTrack: MovedTrack?
    /// A clip that is being trimmed by one of its edges. Set it after
    /// making the value.
    public var trimmedClip: TrimmedClip?

    public init(
        movedClip: MovedClip? = nil,
        markedStretch: MarkedStretch? = nil,
        loopRange: ClosedRange<Double>? = nil,
        movedTrack: MovedTrack? = nil
    ) {
        self.movedClip = movedClip
        self.markedStretch = markedStretch
        self.loopRange = loopRange
        self.movedTrack = movedTrack
    }

    /// Nothing is dragged and there is no loop region.
    public var isEmpty: Bool {
        movedClip == nil && markedStretch == nil && selectionRectangle == nil && loopRange == nil
            && movedTrack == nil && trimmedClip == nil
    }
}

/// A clip whose left or right edge is being dragged. The clip stays in its
/// row: hand it in among the track's clips with the edge where the drag has
/// taken it and with `ClipBox.trimmedEdge` set, which draws that edge lit.
/// This holds what is drawn on top of the rows meanwhile.
public struct TrimmedClip: Sendable, Equatable {
    /// The track the clip is on.
    public var trackID: UUID
    /// The point the dragged edge has snapped to, or nil when it has not
    /// snapped. The snap line is drawn there.
    public var snap: SnapMark?

    public init(trackID: UUID, snap: SnapMark? = nil) {
        self.trackID = trackID
        self.snap = snap
    }
}

/// A clip on its way to a new place. While it is moved it is drawn lifted,
/// above the rows, and it is not among the clips of any track.
public struct MovedClip: Sendable, Equatable {
    /// The clip, with its pieces at the place it is over right now.
    public var clip: ClipBox
    /// The track the clip was taken from. The mark at its recorded place is
    /// drawn in this track's row.
    public var fromTrackID: UUID
    /// The track the clip is over, where it lands if it is let go.
    public var overTrackID: UUID
    /// Where the clip was recorded, in song seconds. A faint mark stays there.
    public var recordedRange: ClosedRange<Double>
    /// The point the clip has snapped to, or nil when it has not snapped.
    public var snap: SnapMark?

    public init(
        clip: ClipBox,
        fromTrackID: UUID,
        overTrackID: UUID,
        recordedRange: ClosedRange<Double>,
        snap: SnapMark? = nil
    ) {
        self.clip = clip
        self.fromTrackID = fromTrackID
        self.overTrackID = overTrackID
        self.recordedRange = recordedRange
        self.snap = snap
    }
}

/// The point a moved clip has snapped to. A thin line is drawn there.
public struct SnapMark: Sendable, Equatable {
    /// What a clip can snap to.
    public enum Kind: Sendable, Equatable {
        /// The start or the end of another clip, on the track with this id.
        case clipEdge(trackID: UUID)
        case playhead
        /// The place the moved clip itself was recorded.
        case recordedPlace
        /// A line of the snapping grid. An edge that is trimmed catches on
        /// these. A clip that is moved goes in steps of the grid and has no
        /// snap line for it.
        case gridLine
    }

    /// Song seconds.
    public var time: Double
    public var kind: Kind

    public init(time: Double, kind: Kind) {
        self.time = time
        self.kind = kind
    }
}

/// A marked stretch of time on one track.
public struct MarkedStretch: Sendable, Equatable {
    public var trackID: UUID
    /// Song seconds.
    public var range: ClosedRange<Double>

    public init(trackID: UUID, range: ClosedRange<Double>) {
        self.trackID = trackID
        self.range = range
    }
}

/// A rectangle over the rows of several tracks, drawn while a drag selects
/// the clips it touches. It looks like the marked stretch, as one band over
/// all its rows and the gaps between them, with a thin edge on every side.
public struct SelectionRectangle: Sendable, Equatable {
    /// The track at one end of the rows it covers.
    public var firstTrackID: UUID
    /// The track at the other end. Either of the two may be the upper one.
    public var lastTrackID: UUID
    /// Song seconds. It need not lie inside the song or inside what is on
    /// screen: only the part over the rows is drawn.
    public var range: ClosedRange<Double>

    public init(firstTrackID: UUID, lastTrackID: UUID, range: ClosedRange<Double>) {
        self.firstTrackID = firstTrackID
        self.lastTrackID = lastTrackID
        self.range = range
    }
}

/// A track on its way to a new place in the order of tracks. Its header is
/// drawn lifted, its own row is dimmed, and a line shows where it will land.
public struct MovedTrack: Sendable, Equatable {
    /// Where the track lands if it is let go.
    public enum Landing: Sendable, Equatable {
        /// Right above the track with this id.
        case before(UUID)
        /// Right below the track with this id.
        case after(UUID)
    }

    /// The track that is moved. It is still among the tracks, at its old place.
    public var track: TrackRow
    /// How far the header has been dragged from its row, in points. Negative
    /// is upwards.
    public var draggedBy: CGFloat
    public var landing: Landing

    public init(track: TrackRow, draggedBy: CGFloat, landing: Landing) {
        self.track = track
        self.draggedBy = draggedBy
        self.landing = landing
    }
}

import SwiftUI

/// What the track list tells its owner when something in it is used: the
/// track headers and the "New Track" button.
///
/// The design lab leaves it out, so nothing in its track list does anything.
/// The real app fills in what works and hands it to `MainLayout`:
///
///     var tracks = TrackActions()
///     tracks.newTrackPressed = { model.addTrack() }
///     tracks.headerPressed = { trackID in model.selectTrack(trackID) }
///     tracks.mutePressed = { trackID in model.toggleMute(of: trackID) }
///     actions.tracks = tracks
///
/// Every action left nil leaves its control doing nothing.
public struct TrackActions {
    /// The "New Track" button under the last track was pressed.
    public var newTrackPressed: (@MainActor () -> Void)?

    /// The header of the track with this id was clicked. A click on the mute
    /// button may be reported here as well as to `mutePressed`.
    public var headerPressed: (@MainActor (UUID) -> Void)?

    /// The mute button of the track with this id was pressed.
    public var mutePressed: (@MainActor (UUID) -> Void)?

    /// The name of the track with this id was double-clicked. The owner then
    /// sets `TrackRow.isBeingRenamed`, which puts a text field in its place.
    public var nameDoubleClicked: (@MainActor (UUID) -> Void)?

    /// The typing of a track's name is over: the id of the track and the
    /// name as it was typed, or nil when it was given up with Escape. The
    /// owner then takes `TrackRow.isBeingRenamed` away.
    ///
    /// With this set, the header of a track that is being renamed holds a
    /// real text field: it takes the keyboard when it appears, with the whole
    /// name selected. Return, a click anywhere else and the field going away
    /// all end the typing with the name. Without it the field is a picture.
    public var renameEnded: (@MainActor (UUID, String?) -> Void)?

    /// The volume control of the track with this id, in the panel on the
    /// right, was moved: the volume it stands at, in dB. `isFinal` is false
    /// while the slider is still being moved and true once it is let go, so
    /// one drag can be one change. The owner then changes
    /// `TrackRow.volumeDB`.
    public var volumeChanged: (@MainActor (UUID, _ volumeDB: Double, _ isFinal: Bool) -> Void)?

    /// A command was chosen in the right-click menu of the header of the
    /// track with this id.
    public var menuCommand: (@MainActor (TrackMenu.Command, UUID) -> Void)?

    /// A track is being dragged up or down by its header. Told on every move
    /// and once more when it is let go. The owner shows the drag with
    /// `TimelineDragging.movedTrack` and changes the order when it ends.
    public var dragged: (@MainActor (TrackMove) -> Void)?

    public init() {}

    /// Whether two of these listen for the same things: each closure is there in both or in neither.
    /// A track's row asks it to know whether it shows the same as before (`TrackLane.showsSame(as:)`):
    /// what a header draws depends on what is listened for, not on the closures themselves.
    static func listensForTheSame(_ one: TrackActions?, _ other: TrackActions?) -> Bool {
        guard let one, let other else { return one == nil && other == nil }
        return (one.newTrackPressed == nil) == (other.newTrackPressed == nil)
            && (one.headerPressed == nil) == (other.headerPressed == nil)
            && (one.mutePressed == nil) == (other.mutePressed == nil)
            && (one.nameDoubleClicked == nil) == (other.nameDoubleClicked == nil)
            && (one.renameEnded == nil) == (other.renameEnded == nil)
            && (one.volumeChanged == nil) == (other.volumeChanged == nil)
            && (one.menuCommand == nil) == (other.menuCommand == nil)
            && (one.dragged == nil) == (other.dragged == nil)
    }
}

/// A track on its way to another place in the order, as its header is dragged.
public struct TrackMove: Sendable, Equatable {
    /// The track whose header is dragged.
    public var trackID: UUID
    /// How far the header has been dragged from its row, in points. Negative
    /// is upwards.
    public var draggedBy: CGFloat
    /// The place the track has in the order if it is let go now, counted
    /// from 0 at the top. Its own place when it has not been dragged far
    /// enough to pass another track.
    public var toIndex: Int
    /// True for the last report, when the button was let go.
    public var isFinished: Bool

    public init(trackID: UUID, draggedBy: CGFloat, toIndex: Int, isFinished: Bool) {
        self.trackID = trackID
        self.draggedBy = draggedBy
        self.toIndex = toIndex
        self.isFinished = isFinished
    }

    /// The move a drag of a header means, among tracks whose rows all have
    /// the height `rowHeight`: every whole row the header has passed moves
    /// the track one place. Nil when the track is not among `trackIDs`.
    init?(trackID: UUID, among trackIDs: [UUID], rowHeight: CGFloat, draggedBy: CGFloat, isFinished: Bool) {
        guard let from = trackIDs.firstIndex(of: trackID) else { return nil }
        let rowPitch = rowHeight + DesignTokens.Spacing.laneGap
        let passed = Int((draggedBy / rowPitch).rounded())
        self.init(
            trackID: trackID,
            draggedBy: draggedBy,
            toIndex: min(max(from + passed, 0), trackIDs.count - 1),
            isFinished: isFinished
        )
    }
}

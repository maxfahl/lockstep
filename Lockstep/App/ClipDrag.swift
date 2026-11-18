import Foundation
import LockstepCore
import LockstepUI

/// One drag of a clip by its bar: what was grabbed, where the pointer has taken it, and
/// what the window draws meanwhile. Nothing in the project changes until the clip is let
/// go. The model then makes the move this holds (`move`) as one edit.
///
/// It follows the recipe at the top of `ProjectMoves.swift` and `Snapping.swift`:
///
///     // When the bar is grabbed.
///     var drag = ClipDrag(grabbing: clipID, selected: selected, grabbedAt: seconds, in: project, playhead: time)
///     // At every movement of the pointer.
///     drag.follow(pointerSeconds: seconds, rowsDown: rows, locksTime: shiftIsDown, snapTolerance: tolerance)
///     rows = drag.rows(showing: rows)             // the dragged clips taken out of their rows
///     dragging.movedClip = drag.picture(of: box)  // the grabbed clip, lifted
///     // When it is let go.
///     store.edit("Move Clip") { $0.moveClips(drag.selected, bySamples: drag.move.samples, ...) }
///
/// The rules of a move are in `ProjectMoves.swift` and `Snapping.swift` in LockstepCore, and
/// what the clip catches on is chosen in `SnapChoices`: with the grid on, the clip moves in
/// steps of it and keeps its distance to the grid lines.
///
/// With Option held when the drag starts (`copies`), the clips stay where they are and
/// copies of their shown takes go where the move takes them, with the same snapping and
/// limits. The window draws the clips in their rows and the copies as moved clips are
/// drawn. When it is let go the model makes the copies as one edit, with the ids drawn
/// (`copyIDs`): `duplicateClips(drag.selected, by: drag.move, newIDs: drag.copyIDs)`.
struct ClipDrag {
    /// The clip whose bar is held. It is the one drawn lifted, and the one that snaps.
    let grabbedID: UUID
    /// The clips the move is made for: the selected clips, of which the grabbed one is one.
    let selected: Set<UUID>
    /// Where the clips would land if they were let go now, after the limits of the song
    /// and of the list of tracks.
    private(set) var move = ClipMove()
    /// The point the grabbed clip has caught on, or nil when it has not snapped.
    private(set) var snap: SnapMark?
    /// True when the drag makes copies and leaves the clips where they are.
    let copies: Bool
    /// The id each copy gets, by the id of the selected clip it is a copy of. Empty when
    /// the drag moves the clips.
    let copyIDs: [UUID: UUID]

    /// The project as it was when the bar was grabbed. The limits are asked of it.
    private let project: Project
    /// Every clip that moves: the selected clips and all the takes of their lines.
    private let moving: Set<UUID>
    /// The track the grabbed clip was on, counted from 0 at the top.
    private let fromTrackIndex: Int
    /// The moment in the song that was under the pointer when the bar was grabbed.
    private let grabbedAt: Double
    /// Where the grabbed clip started and ended before the drag, in song seconds.
    private let start: Double
    private let end: Double
    /// Where the grabbed clip was recorded, in song seconds. The faint mark is drawn there.
    private let recordedRange: ClosedRange<Double>
    /// How far the grabbed clip was from its recorded place before the drag, in samples.
    private let recordedOffset: Int
    private let engine: SnapEngine
    /// The grid the clip moves in steps of, when the grid is one of the things to snap
    /// to. Without lines it does nothing.
    private let stepGrid: SnapGrid
    /// The start and the end of every clip that is drawn and does not move, with its
    /// track, so the snap line can be drawn from the right row.
    private let edges: [(time: Double, trackID: UUID)]

    /// Nil when the clip cannot be dragged: it is not in the project, it is a take that
    /// waits behind another, or it has no place in the song.
    ///
    /// - Parameters:
    ///   - selected: the selected clips. When the grabbed clip is one of them they all
    ///     move together. Otherwise only the grabbed clip moves.
    ///   - grabbedAt: the song seconds under the pointer when the bar was grabbed.
    ///   - playhead: where the playhead is, in song seconds. It is a snap point.
    ///   - snapTo: what the clip catches on while snapping is on. Left out, everything.
    ///   - copying: the drag makes copies and leaves the clips (Option was held).
    init?(
        grabbing clipID: UUID,
        selected: Set<UUID>,
        grabbedAt: Double,
        in project: Project,
        playhead: Double,
        snapTo: SnapChoices = SnapChoices(),
        copying: Bool = false
    ) {
        guard let trackIndex = project.tracks.firstIndex(where: { track in track.clips.contains { $0.id == clipID } }),
              let clip = project.clip(clipID), clip.isActiveTake,
              let start = project.start(of: clip), let end = project.end(of: clip), end > start,
              let recordedStart = project.recordedStart(of: clip)
        else { return nil }
        let selected = selected.contains(clipID) ? selected : [clipID]
        let moving = project.clipsMovingTogether(with: selected)

        grabbedID = clipID
        self.selected = selected
        copies = copying
        copyIDs = copying ? Dictionary(uniqueKeysWithValues: selected.map { ($0, UUID()) }) : [:]
        self.project = project
        self.moving = moving
        fromTrackIndex = trackIndex
        self.grabbedAt = grabbedAt
        self.start = start
        self.end = end
        recordedRange = recordedStart...(recordedStart + (end - start))
        recordedOffset = project.recordedOffset(of: clip)

        engine = SnapEngine(
            sources: snapTo.sources(forMoving: clip, in: project, playheadAt: playhead),
            moving: moving
        )
        stepGrid = snapTo.grid
            ? SnapGrid(grid: project.grid, unit: snapTo.gridUnit)
            : SnapGrid()

        var edges: [(time: Double, trackID: UUID)] = []
        for track in project.tracks {
            for other in track.clips where other.isActiveTake && !moving.contains(other.id) {
                guard let otherStart = project.start(of: other), let otherEnd = project.end(of: other) else { continue }
                edges.append((otherStart, track.id))
                edges.append((otherEnd, track.id))
            }
        }
        self.edges = edges
    }

    /// The pointer has moved, or the timeline has moved under it.
    ///
    /// - Parameters:
    ///   - pointerSeconds: the song seconds under the pointer now.
    ///   - rowsDown: how many rows below the row the clip was grabbed in the pointer is.
    ///   - locksTime: Shift is held. The clip keeps its time and only changes track.
    ///   - snapTolerance: how near a snap point must be to catch the clip, in seconds.
    ///     Nil when snapping is off.
    mutating func follow(pointerSeconds: Double, rowsDown: Int, locksTime: Bool, snapTolerance: Double?) {
        // The track nearest the pointer that every moving clip can go to. A pointer far
        // below the last track still means the last track.
        var steps = rowsDown
        while steps != 0, project.allowedMove(of: selected, bySamples: 0, trackSteps: steps).trackSteps != steps {
            steps -= steps.signum()
        }

        var seconds = locksTime ? 0 : pointerSeconds - grabbedAt
        var caught: SnapPoint?
        if !locksTime, let snapTolerance {
            // A point within the snap distance wins, so the clip can go back to exactly its
            // recorded place. Otherwise the clip goes in steps of the grid.
            if let hit = engine.snap(start: start + seconds, end: end + seconds, tolerance: snapTolerance) {
                seconds += hit.delta
                caught = hit.point
            } else if let stepped = stepGrid.steppedStart(start + seconds, grabbedStart: start) {
                seconds = stepped - start
            }
        }
        var samples = Int((seconds * Lockstep.sampleRate).rounded())
        // Back at the recorded place means exactly there, to the sample, whatever the
        // rounding of a time in seconds would give.
        if caught?.kind == .recordedPosition {
            samples = -recordedOffset
        }

        let allowed = project.allowedMove(of: selected, bySamples: samples, trackSteps: steps)
        // Held back by the start or the end of the song, the clip is not on the point.
        if allowed.samples != samples {
            caught = nil
        }
        move = allowed
        snap = caught.flatMap { mark(for: $0) }
    }

    /// The track the grabbed clip is over, where it lands if it is let go.
    private var overTrackID: UUID {
        project.tracks[fromTrackIndex + move.trackSteps].id
    }

    /// How far along the song the clips have been taken, in seconds.
    private var movedSeconds: Double {
        Double(move.samples) / Lockstep.sampleRate
    }

    /// The snap line for a point the clip has caught on. Nil for a kind of point the
    /// window has no line for.
    private func mark(for point: SnapPoint) -> SnapMark? {
        if point.kind == .recordedPosition {
            return SnapMark(time: point.time, kind: .recordedPlace)
        }
        if point.kind == .playhead {
            return SnapMark(time: point.time, kind: .playhead)
        }
        if point.kind == .clipEdge {
            // The line runs from the row of the clip whose edge it is. When clips on
            // several tracks have an edge there, the nearest is the track the clip is over.
            let over = overTrackID
            let there = edges.filter { abs($0.time - point.time) <= SnapEngine.tieWindow }
            let trackID = there.first { $0.trackID == over }?.trackID ?? there.first?.trackID ?? over
            return SnapMark(time: point.time, kind: .clipEdge(trackID: trackID))
        }
        return nil
    }

    /// A clip as it is drawn at the place the drag has taken it to. A copy is drawn with its
    /// own id, as a clip with no other takes.
    private func shifted(_ box: ClipBox) -> ClipBox {
        let seconds = movedSeconds
        var shifted = box
        if copies {
            shifted.id = copyIDs[box.id] ?? box.id
            shifted.takeCount = 1
            shifted.activeTakeNumber = 1
        }
        shifted.segments = box.segments.map { segment in
            ClipSegment(
                range: (segment.range.lowerBound + seconds)...(segment.range.upperBound + seconds),
                levels: segment.levels
            )
        }
        return shifted
    }

    /// The grabbed clip as the window draws it while it is dragged: lifted over the row it
    /// is over, with the mark at its recorded place and the snap line.
    ///
    /// - Parameter box: the grabbed clip as its row shows it when nothing is dragged.
    func picture(of box: ClipBox) -> MovedClip {
        MovedClip(
            clip: shifted(box),
            fromTrackID: project.tracks[fromTrackIndex].id,
            overTrackID: overTrackID,
            recordedRange: recordedRange,
            snap: snap
        )
    }

    /// The rows as they are drawn during the drag: the grabbed clip is in none of them,
    /// because it is drawn lifted, and the other selected clips are where the drag has
    /// taken them.
    ///
    /// - Parameter rows: the rows as they are when nothing is dragged, one per track in
    ///   the order of the project's tracks.
    ///
    /// When the drag makes copies, the clips stay in their rows and the copies of the other
    /// selected clips are added where the drag has taken them.
    func rows(showing rows: [TrackRow]) -> [TrackRow] {
        var shown = rows
        var landing: [(row: Int, box: ClipBox)] = []
        for index in shown.indices {
            let going = shown[index].clips.filter { copies ? selected.contains($0.id) : moving.contains($0.id) }
            guard !going.isEmpty else { continue }
            if !copies {
                shown[index].clips.removeAll { moving.contains($0.id) }
            }
            for box in going where box.id != grabbedID {
                landing.append((index + move.trackSteps, shifted(box)))
            }
        }
        for (row, box) in landing where shown.indices.contains(row) {
            shown[row].clips.append(box)
        }
        return shown
    }
}

import Foundation
import LockstepCore
import LockstepUI

/// One drag of a clip by its left or its right edge: which edge was grabbed, and where
/// the pointer has taken it. Nothing in the project changes until the edge is let go. The
/// model then makes the trim this holds as one edit, "Trim Clip".
///
///     // When the edge is grabbed.
///     var trim = ClipTrim(grabbing: clipID, edge: .start, grabbedAt: seconds, in: project, playhead: time)
///     // At every movement of the pointer.
///     trim.follow(pointerSeconds: seconds, snapTolerance: tolerance)
///     showClips(of: trim.shown(in: project))      // the clip drawn with its edge there
///     // When it is let go.
///     changed.trimClip(trim.clipID, edge: trim.edge, toSongSample: trim.sample, peaks: peaks)
///
/// The rules of a trim are at the top of `ProjectTrims.swift` in LockstepCore.
struct ClipTrim {
    /// The clip whose edge is held.
    let clipID: UUID
    /// The track that clip is on.
    let trackID: UUID
    let edge: ClipEdge
    /// The sample of the song the edge would be on if it were let go now, inside the limits.
    private(set) var sample: Int
    /// The point the edge has caught on, or nil when it has not snapped.
    private(set) var snap: SnapMark?

    /// The samples of the song the edge may be dragged to.
    private let allowed: ClosedRange<Int>
    /// How far the edge was from the pointer when it was grabbed, in seconds. The edge keeps
    /// that distance, so it does not jump to the pointer when the drag starts.
    private let aheadOfPointer: Double
    private let engine: SnapEngine
    /// The start and the end of every other clip that is drawn, with its track, so the snap
    /// line can be drawn from the right row.
    private let edges: [(time: Double, trackID: UUID)]

    /// Nil when the clip cannot be trimmed: it is not in the project, it is a take that
    /// waits behind another, or it has no place in the song.
    ///
    /// - Parameters:
    ///   - grabbedAt: the song seconds under the pointer when the edge was grabbed.
    ///   - playhead: where the playhead is, in song seconds. It is a snap point.
    ///   - snapTo: what the edge catches on while snapping is on. Left out, everything.
    init?(
        grabbing clipID: UUID,
        edge: ClipEdge,
        grabbedAt: Double,
        in project: Project,
        playhead: Double,
        snapTo: SnapChoices = SnapChoices()
    ) {
        guard let track = project.tracks.first(where: { track in track.clips.contains { $0.id == clipID } }),
              let allowed = project.trimRange(of: clipID, edge: edge),
              let sample = project.edgeSample(of: clipID, edge: edge)
        else { return nil }
        self.clipID = clipID
        trackID = track.id
        self.edge = edge
        self.sample = sample
        self.allowed = allowed
        aheadOfPointer = Double(sample) / Lockstep.sampleRate - grabbedAt

        // The edge never catches on the clip it belongs to, nor on a take behind it.
        let line = project.clipsMovingTogether(with: [clipID])
        engine = SnapEngine(
            sources: snapTo.sources(
                forTrimmingIn: project,
                playheadAt: playhead,
                grid: SnapGrid(grid: project.grid, unit: snapTo.gridUnit)
            ),
            moving: line
        )
        var edges: [(time: Double, trackID: UUID)] = []
        for track in project.tracks {
            for other in track.clips where other.isActiveTake && !line.contains(other.id) {
                guard let start = project.start(of: other), let end = project.end(of: other) else { continue }
                edges.append((start, track.id))
                edges.append((end, track.id))
            }
        }
        self.edges = edges
    }

    /// The pointer has moved, or the timeline has moved under it.
    ///
    /// - Parameters:
    ///   - pointerSeconds: the song seconds under the pointer now.
    ///   - snapTolerance: how near a snap point must be to catch the edge, in seconds. Nil
    ///     when snapping is off.
    mutating func follow(pointerSeconds: Double, snapTolerance: Double?) {
        var seconds = pointerSeconds + aheadOfPointer
        var caught: SnapPoint?
        // One edge is all that moves, so it is the start and the end of what is held against the points.
        if let snapTolerance, let hit = engine.snap(start: seconds, end: seconds, tolerance: snapTolerance) {
            seconds += hit.delta
            caught = hit.point
        }
        let asked = (seconds * Lockstep.sampleRate).rounded()
        let wanted = asked.isFinite && abs(asked) < 1e15 ? Int(asked) : sample
        sample = min(max(wanted, allowed.lowerBound), allowed.upperBound)
        // Held back by a limit, the edge is not on the point.
        if sample != wanted {
            caught = nil
        }
        snap = caught.flatMap { mark(for: $0) }
    }

    /// The project as the window draws it during the drag: this clip with its edge where
    /// the drag has taken it. Nil when the clip is gone from that project or can no longer
    /// be trimmed, which ends the drag.
    func shown(in project: Project) -> Project? {
        guard project.trimRange(of: clipID, edge: edge) != nil else { return nil }
        var shown = project
        shown.trimClip(clipID, edge: edge, toSongSample: sample, voices: .none)
        return shown
    }

    /// The snap line for a point the edge has caught on. Nil for a kind of point the window
    /// has no line for.
    private func mark(for point: SnapPoint) -> SnapMark? {
        if point.kind == .playhead {
            return SnapMark(time: point.time, kind: .playhead)
        }
        if point.kind == .clipEdge {
            // The line runs from the row of the clip whose edge it is. When clips on several
            // tracks have an edge there, the nearest is the clip's own track.
            let there = edges.filter { abs($0.time - point.time) <= SnapEngine.tieWindow }
            let from = there.first { $0.trackID == trackID }?.trackID ?? there.first?.trackID ?? trackID
            return SnapMark(time: point.time, kind: .clipEdge(trackID: from))
        }
        if point.kind == .gridLine {
            return SnapMark(time: point.time, kind: .gridLine)
        }
        return nil
    }
}

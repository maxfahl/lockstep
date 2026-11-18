import Foundation

// Snapping: while a clip is dragged, it catches on places in the song that are near its start or its end.
//
// The places come from a list of sources. `SnapEngine` knows nothing about what a source is, so a new kind of place (seconds, half
// seconds, beats, bars) is a new `SnapSource` with a `SnapKind` of its own, and nothing here changes.
//
//     // When the drag starts. `grabbed` is the clip under the pointer, `selected` everything that moves.
//     let moving = project.clipsMovingTogether(with: selected)
//     var sources: [any SnapSource] = [ClipEdgeSource(project: project), PlayheadSource(time: playhead)]
//     if let recorded = RecordedPositionSource(clip: grabbed, in: project) { sources.append(recorded) }
//     let engine = SnapEngine(sources: sources, moving: moving)
//
//     // At every movement. `start` and `end` are where the grabbed clip would be without snapping.
//     let tolerance = snapDistancePoints / pointsPerSecond
//     if let snap = engine.snap(start: start, end: end, tolerance: tolerance) {
//         // Move by `snap.delta` seconds more, and draw the snap line at `snap.point.time`.
//     }

/// What kind of place a snap point is. The interface can tell the kinds apart by it, and it decides which
/// point wins when two are equally near.
///
/// It is a value and not a fixed list, so a source added later brings its own kind.
public struct SnapKind: Sendable, Hashable {
    /// What the kind is called, for telling kinds apart.
    public var name: String
    /// Which kind wins when two points are equally near: the one with the lower rank.
    public var rank: Int

    public init(name: String, rank: Int) {
        self.name = name
        self.rank = rank
    }

    /// Where the dragged clip was recorded. It wins every tie, so a clip goes back to exactly its own place.
    public static let recordedPosition = SnapKind(name: "recordedPosition", rank: 0)
    /// The playhead.
    public static let playhead = SnapKind(name: "playhead", rank: 100)
    /// The start or the end of another clip.
    public static let clipEdge = SnapKind(name: "clipEdge", rank: 200)
}

/// Which edge of the dragged clip may be put on a snap point.
public enum SnapEdges: Sendable, Hashable {
    /// Only the start of the clip.
    case start
    /// Only the end of the clip.
    case end
    /// Either one.
    case both

    /// Whether the start of the clip may be put on the point.
    public var takesStart: Bool { self != .end }
    /// Whether the end of the clip may be put on the point.
    public var takesEnd: Bool { self != .start }
}

/// One place in the song that a dragged clip can catch on.
public struct SnapPoint: Sendable, Equatable {
    /// Song seconds.
    public var time: Double
    public var kind: SnapKind
    /// Which edge of the dragged clip may be put here. Either one, unless the source says otherwise.
    public var edges: SnapEdges

    public init(time: Double, kind: SnapKind, edges: SnapEdges = .both) {
        self.time = time
        self.kind = kind
        self.edges = edges
    }
}

/// Something that knows places in the song a dragged clip can catch on.
public protocol SnapSource: Sendable {
    /// The snap points inside a stretch of the song.
    ///
    /// - Parameters:
    ///   - range: the stretch, in song seconds. Points outside it are of no use and may be left out.
    ///   - moving: the clips that are being dragged. A source made of clips leaves these out, so a clip never
    ///     catches on itself.
    func points(in range: ClosedRange<Double>, excluding moving: Set<Clip.ID>) -> [SnapPoint]
}

/// Finds the snap point a dragged clip catches on, among the points of all its sources.
public struct SnapEngine: Sendable {
    public var sources: [any SnapSource]
    /// The clips that are being dragged, handed to every source so that none of them is a snap point.
    public var moving: Set<Clip.ID>

    public init(sources: [any SnapSource], moving: Set<Clip.ID> = []) {
        self.sources = sources
        self.moving = moving
    }

    /// Two corrections closer to each other than this count as equally near: half a sample. Clips move by
    /// whole samples, so such corrections put the clip on the same sample, and which point is named should
    /// then not hang on the last digits of a time.
    public static let tieWindow = 0.5 / Lockstep.sampleRate

    /// Where a dragged clip catches, when its start and its end would be at these song times without snapping.
    ///
    /// Both the start and the end are held against every point. The point that needs the smallest correction
    /// wins, if that correction is within the tolerance. Among points that are equally near, the kind with the
    /// lowest rank wins: the recorded position, then the playhead, then clip edges.
    ///
    /// - Parameter tolerance: how near a point must be, in seconds. The caller turns the snap distance on
    ///   screen into time at the current zoom (points divided by points per second), so snapping feels the
    ///   same at every zoom.
    /// - Returns: `delta`, the seconds to add to the clip's place so that one of its edges is on `point`, or
    ///   nil when no point is within the tolerance.
    public func snap(start: Double, end: Double, tolerance: Double) -> (delta: Double, point: SnapPoint)? {
        guard start.isFinite, end.isFinite, tolerance.isFinite, tolerance >= 0 else { return nil }

        var found: [(delta: Double, point: SnapPoint)] = []
        for (edge, time) in [(SnapEdges.start, start), (SnapEdges.end, end)] {
            let near = (time - tolerance)...(time + tolerance)
            for source in sources {
                for point in source.points(in: near, excluding: moving) {
                    guard edge == .start ? point.edges.takesStart : point.edges.takesEnd else { continue }
                    let delta = point.time - time
                    // A source may hand back more than was asked for.
                    guard abs(delta) <= tolerance else { continue }
                    found.append((delta, point))
                }
            }
        }

        guard let nearest = found.map({ abs($0.delta) }).min() else { return nil }
        var best: (delta: Double, point: SnapPoint)?
        for candidate in found where abs(candidate.delta) <= nearest + SnapEngine.tieWindow {
            guard let current = best else {
                best = candidate
                continue
            }
            let rank = candidate.point.kind.rank
            let currentRank = current.point.kind.rank
            if rank < currentRank || (rank == currentRank && abs(candidate.delta) < abs(current.delta)) {
                best = candidate
            }
        }
        return best
    }
}

/// The start and the end of every clip that is drawn: on every track, of each line only the take that is
/// shown. A clip that is being dragged gives no points, and neither does any take of its line.
public struct ClipEdgeSource: SnapSource {
    /// One clip that is drawn: the clips of its line (itself and its takes) and where it starts and ends.
    private struct Shown: Sendable {
        var line: Set<Clip.ID>
        var start: Double
        var end: Double
    }

    private var shown: [Shown] = []

    /// Reads the clips of a project as it is now. The source is made once, when a drag starts: the clips that
    /// do not move stay where they are for as long as the drag lasts.
    public init(project: Project) {
        for track in project.tracks {
            var lines: [Clip.ID: Set<Clip.ID>] = [:]
            for group in project.takeGroups(on: track.id) {
                let line = Set(group.map(\.id))
                for id in line { lines[id] = line }
            }
            for clip in track.clips where clip.isActiveTake {
                guard let start = project.start(of: clip), let end = project.end(of: clip) else { continue }
                shown.append(Shown(line: lines[clip.id] ?? [clip.id], start: start, end: end))
            }
        }
    }

    public func points(in range: ClosedRange<Double>, excluding moving: Set<Clip.ID>) -> [SnapPoint] {
        var points: [SnapPoint] = []
        for clip in shown where clip.line.isDisjoint(with: moving) {
            if range.contains(clip.start) { points.append(SnapPoint(time: clip.start, kind: .clipEdge)) }
            if range.contains(clip.end) { points.append(SnapPoint(time: clip.end, kind: .clipEdge)) }
        }
        return points
    }
}

/// The playhead, as one snap point.
public struct PlayheadSource: SnapSource {
    /// Where the playhead is, in song seconds.
    public var time: Double

    public init(time: Double) {
        self.time = time
    }

    public func points(in range: ClosedRange<Double>, excluding moving: Set<Clip.ID>) -> [SnapPoint] {
        range.contains(time) ? [SnapPoint(time: time, kind: .playhead)] : []
    }
}

/// The place the dragged clip was recorded, as one snap point: the song time at which the clip's start has to
/// be for the clip to be back where it was performed. Only the start of the clip catches on it, because the
/// clip is back at its recorded place only when its start is there.
public struct RecordedPositionSource: SnapSource {
    /// Where the clip started when it was recorded, in song seconds.
    public var time: Double

    public init(time: Double) {
        self.time = time
    }

    /// The recorded place of a clip of a project. Nil for a clip with no place in the song (no segments, or a
    /// recording the project does not have).
    public init?(clip: Clip, in project: Project) {
        guard let time = project.recordedStart(of: clip) else { return nil }
        self.time = time
    }

    public func points(in range: ClosedRange<Double>, excluding moving: Set<Clip.ID>) -> [SnapPoint] {
        range.contains(time) ? [SnapPoint(time: time, kind: .recordedPosition, edges: .start)] : []
    }
}

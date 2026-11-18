import Foundation
import Testing
@testable import LockstepCore

/// A twenty-second song with two empty tracks, "Track 1" and "Track 2".
private func song() -> Project {
    var project = Project(songLengthSamples: 960_000)
    project.addTrack()
    return project
}

/// Records a clip the way the app does: a new recording that begins `start` seconds into the song and is
/// `seconds` long, with all of it as the clip, on the track at `track`. Returns the id of the clip.
@discardableResult
private func record(_ start: Double, _ seconds: Double = 1, in project: inout Project, track: Int = 0, aimedAt aim: Double? = nil) -> UUID {
    let recording = Recording(lengthSamples: Int((seconds * Lockstep.sampleRate).rounded()), rawStart: start)
    return project.addRecording(
        recording,
        samples: 0..<recording.lengthSamples,
        asClipOn: project.tracks[track].id,
        aim: aim.map { RecordAim(place: $0) }, voices: .none
    )!
}

private func close(_ a: Double?, _ b: Double, within tolerance: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

/// A source the engine has never heard of: every whole second of the song, with a kind of its own.
private struct WholeSeconds: SnapSource {
    static let kind = SnapKind(name: "second", rank: 300)

    func points(in range: ClosedRange<Double>, excluding moving: Set<Clip.ID>) -> [SnapPoint] {
        let first = Int(range.lowerBound.rounded(.up))
        let last = Int(range.upperBound.rounded(.down))
        guard first <= last else { return [] }
        return (first...last).map { SnapPoint(time: Double($0), kind: WholeSeconds.kind) }
    }
}

/// A careless source: it hands back all its points, whatever stretch was asked for.
private struct Everywhere: SnapSource {
    var times: [Double]

    func points(in range: ClosedRange<Double>, excluding moving: Set<Clip.ID>) -> [SnapPoint] {
        times.map { SnapPoint(time: $0, kind: WholeSeconds.kind) }
    }
}

/// Where a dragged clip catches, worked out with numbers alone.
@Suite("Snapping")
struct SnappingTests {
    // MARK: Near and far

    @Test func aStartThreeMillisecondsFromAClipEdgeSnapsByThreeMilliseconds() {
        // Another clip lies at 5 to 6 s. The dragged clip would start 3 ms after its end.
        var project = song()
        record(5, in: &project)
        let dragged = record(12, in: &project, track: 1)
        let engine = SnapEngine(sources: [ClipEdgeSource(project: project)], moving: [dragged])

        let snap = engine.snap(start: 6.003, end: 7.003, tolerance: 0.005)

        #expect(close(snap?.delta, -0.003))
        #expect(snap?.point == SnapPoint(time: 6, kind: .clipEdge))
    }

    @Test func theEndSnapsWhenTheStartDoesNot() {
        // The dragged clip would end 2 ms before the other clip starts. Its start is near nothing.
        var project = song()
        record(5, in: &project)
        let dragged = record(12, in: &project, track: 1)
        let engine = SnapEngine(sources: [ClipEdgeSource(project: project)], moving: [dragged])

        let snap = engine.snap(start: 3.998, end: 4.998, tolerance: 0.005)

        #expect(close(snap?.delta, 0.002))
        #expect(snap?.point == SnapPoint(time: 5, kind: .clipEdge))
    }

    @Test func nothingWithinTheToleranceGivesNoSnap() {
        var project = song()
        record(5, in: &project)
        let dragged = record(12, in: &project, track: 1)
        let engine = SnapEngine(
            sources: [ClipEdgeSource(project: project), PlayheadSource(time: 9)],
            moving: [dragged]
        )

        #expect(engine.snap(start: 6.006, end: 7.006, tolerance: 0.005) == nil)
        #expect(engine.snap(start: 6.003, end: 7.003, tolerance: 0) == nil)
        #expect(SnapEngine(sources: []).snap(start: 6, end: 7, tolerance: 1) == nil)
        #expect(engine.snap(start: .nan, end: 7, tolerance: 0.005) == nil)
        #expect(engine.snap(start: 6, end: 7, tolerance: -1) == nil)
    }

    @Test func theNearestPointWinsWhateverItsKind() {
        // The playhead is 3 ms from the start, a clip edge 2 ms from the end.
        var project = song()
        record(11.002, in: &project)
        let dragged = record(15, in: &project, track: 1)
        let engine = SnapEngine(
            sources: [PlayheadSource(time: 10.003), ClipEdgeSource(project: project)],
            moving: [dragged]
        )

        let snap = engine.snap(start: 10, end: 11, tolerance: 0.005)

        #expect(close(snap?.delta, 0.002))
        #expect(snap?.point.kind == .clipEdge)
    }

    @Test func aClipAlreadyOnAPointSnapsByNothing() {
        let engine = SnapEngine(sources: [PlayheadSource(time: 8)])

        let snap = engine.snap(start: 8, end: 9, tolerance: 0.005)

        #expect(snap?.delta == 0)
        #expect(snap?.point == SnapPoint(time: 8, kind: .playhead))
    }

    // MARK: Equally near

    @Test func onATieTheRecordedPositionWinsThenThePlayheadThenClipEdges() {
        // Three points, each 3 ms from an edge of the dragged clip (10 to 11 s): the recorded position after
        // its start, the playhead before its start, and another clip's start after its end.
        var project = song()
        record(11.003, in: &project)
        let dragged = record(15, in: &project, track: 1)
        let edges = ClipEdgeSource(project: project)
        let playhead = PlayheadSource(time: 9.997)
        let recorded = RecordedPositionSource(time: 10.003)
        func snap(_ sources: [any SnapSource]) -> (delta: Double, point: SnapPoint)? {
            SnapEngine(sources: sources, moving: [dragged]).snap(start: 10, end: 11, tolerance: 0.005)
        }

        // Whatever order the sources are listed in.
        for sources in [[edges, playhead, recorded], [recorded, playhead, edges], [playhead, edges, recorded]]
            as [[any SnapSource]] {
            let all = snap(sources)
            #expect(all?.point.kind == .recordedPosition)
            #expect(close(all?.delta, 0.003))
        }

        let withoutRecorded = snap([edges, playhead])
        #expect(withoutRecorded?.point.kind == .playhead)
        #expect(close(withoutRecorded?.delta, -0.003))

        let edgesOnly = snap([edges])
        #expect(edgesOnly?.point.kind == .clipEdge)
        #expect(close(edgesOnly?.delta, 0.003))
    }

    @Test func pointsLessThanHalfASampleApartCountAsEquallyNear() {
        // The clip edge is a few millionths of a second nearer than the playhead. Both put the clip on the
        // same sample, so the playhead is named.
        var project = song()
        record(9, in: &project)
        let dragged = record(15, in: &project, track: 1)
        let engine = SnapEngine(
            sources: [ClipEdgeSource(project: project), PlayheadSource(time: 9.999_996)],
            moving: [dragged]
        )

        let snap = engine.snap(start: 10.002, end: 11.002, tolerance: 0.005)

        #expect(snap?.point.kind == .playhead)

        // A point further off than that is simply further off.
        let apart = SnapEngine(
            sources: [ClipEdgeSource(project: project), PlayheadSource(time: 9.999_9)],
            moving: [dragged]
        )
        #expect(apart.snap(start: 10.002, end: 11.002, tolerance: 0.005)?.point.kind == .clipEdge)
    }

    // MARK: Clips as snap points

    @Test func aClipNeverSnapsToItselfOrToItsOwnTakes() {
        // One line with three takes at slightly different places, and nothing else in the song.
        var project = song()
        record(5.00, in: &project)
        record(5.05, in: &project)
        let third = record(5.10, in: &project)
        project.normalizeTakes()
        let shown = project.clip(third)!
        let start = project.start(of: shown)!
        let end = project.end(of: shown)!

        // Dragged 2 ms: its own old edges and those of its takes are all within reach, and none is a point.
        let engine = SnapEngine(sources: [ClipEdgeSource(project: project)], moving: [third])
        #expect(engine.snap(start: start + 0.002, end: end + 0.002, tolerance: 0.2) == nil)

        // Also when the flags are wrong and every take says it is the one that is shown.
        var stale = project
        for index in stale.tracks[0].clips.indices { stale.tracks[0].clips[index].isActiveTake = true }
        let staleEngine = SnapEngine(sources: [ClipEdgeSource(project: stale)], moving: [third])
        #expect(staleEngine.snap(start: start + 0.002, end: end + 0.002, tolerance: 0.2) == nil)

        // Without being told what moves, the same source does give the clip's own edges.
        let unaware = SnapEngine(sources: [ClipEdgeSource(project: project)])
        #expect(unaware.snap(start: start + 0.002, end: end + 0.002, tolerance: 0.2) != nil)
    }

    @Test func onlyTheTakeThatIsShownIsASnapPoint() {
        // A line on track 1: the take behind starts at 5.0 s, the one that is shown at 5.1 s.
        var project = song()
        record(5.0, in: &project)
        record(5.1, in: &project, aimedAt: 5.0)
        let dragged = record(15, in: &project, track: 1)
        project.normalizeTakes()
        let engine = SnapEngine(sources: [ClipEdgeSource(project: project)], moving: [dragged])

        #expect(engine.snap(start: 5.001, end: 5.5, tolerance: 0.005) == nil)
        let snap = engine.snap(start: 5.101, end: 5.5, tolerance: 0.005)
        #expect(close(snap?.delta, -0.001))
    }

    @Test func clipsOnEveryTrackAreSnapPointsAlsoMutedOnes() {
        var project = song()
        let muted = record(5, in: &project, track: 1)
        project.setClips([muted], muted: true)
        let dragged = record(15, in: &project, track: 0)
        let engine = SnapEngine(sources: [ClipEdgeSource(project: project)], moving: [dragged])

        let snap = engine.snap(start: 4.999, end: 5.999, tolerance: 0.005)

        #expect(close(snap?.delta, 0.001))
    }

    // MARK: The recorded position

    @Test func theRecordedPositionBringsAMovedClipBackToExactlyItsPlace() {
        // Moved 1,200 samples later and to the other track, then dragged to within 4 ms of where it was.
        var project = song()
        let id = record(5, in: &project)
        project.moveClips([id], bySamples: 1_200, trackSteps: 1, voices: .none)
        let clip = project.clip(id)!
        let source = RecordedPositionSource(clip: clip, in: project)!
        let engine = SnapEngine(sources: [source], moving: [id])
        let dragged = -0.021
        let start = project.start(of: clip)! + dragged
        let end = project.end(of: clip)! + dragged

        let snap = engine.snap(start: start, end: end, tolerance: 0.005)

        #expect(snap?.point == SnapPoint(time: 5, kind: .recordedPosition, edges: .start))
        // The whole drag, in samples, is exactly the way back.
        let samples = Int(((dragged + (snap?.delta ?? 0)) * Lockstep.sampleRate).rounded())
        #expect(samples == -1_200)
        project.moveClips([id], bySamples: samples, trackSteps: 0, voices: .none)
        #expect(project.recordedOffset(of: project.clip(id)!) == 0)
    }

    @Test func onlyTheStartOfTheClipCatchesOnTheRecordedPosition() {
        // The end of the clip passes the place its start was recorded at. That is not being back.
        let engine = SnapEngine(sources: [RecordedPositionSource(time: 5)])

        #expect(engine.snap(start: 4.001, end: 5.001, tolerance: 0.005) == nil)
        #expect(engine.snap(start: 5.001, end: 6.001, tolerance: 0.005) != nil)
        #expect(RecordedPositionSource(clip: Clip(), in: song()) == nil)
    }

    // MARK: More sources later

    @Test func aMadeUpFourthSourceWorksWithoutTouchingTheEngine() {
        var project = song()
        record(5, in: &project)
        let dragged = record(15, in: &project, track: 1)
        let engine = SnapEngine(
            sources: [
                ClipEdgeSource(project: project),
                PlayheadSource(time: 9.5),
                RecordedPositionSource(time: 15),
                WholeSeconds(),
            ],
            moving: [dragged]
        )

        // Near the whole second at 8 s and near nothing else.
        let snap = engine.snap(start: 7.2, end: 8.004, tolerance: 0.005)
        #expect(close(snap?.delta, -0.004))
        #expect(snap?.point == SnapPoint(time: 8, kind: WholeSeconds.kind))

        // At 6 s a clip ends on the whole second. Its kind has the lower rank, so the clip edge is named.
        let tie = engine.snap(start: 6.002, end: 6.7, tolerance: 0.005)
        #expect(tie?.point.kind == .clipEdge)
    }

    @Test func pointsASourceGivesOutsideTheToleranceAreNotUsed() {
        let engine = SnapEngine(sources: [Everywhere(times: [2, 7.5, 30])])

        #expect(engine.snap(start: 10, end: 11, tolerance: 0.005) == nil)
        let snap = engine.snap(start: 7.499, end: 9, tolerance: 0.005)
        #expect(close(snap?.delta, 0.001))
    }
}

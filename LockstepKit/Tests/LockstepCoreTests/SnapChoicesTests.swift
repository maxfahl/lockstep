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
private func record(_ start: Double, _ seconds: Double = 1, in project: inout Project, track: Int = 0) -> UUID {
    let recording = Recording(lengthSamples: Int((seconds * Lockstep.sampleRate).rounded()), rawStart: start)
    return project.addRecording(recording, samples: 0..<recording.lengthSamples, asClipOn: project.tracks[track].id, voices: .none)!
}

private func close(_ a: Double?, _ b: Double, within tolerance: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

private func close(_ a: [Double], _ b: [Double]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= 1e-9 }
}

/// Beats a second apart from second 2 to second 10. Beat 0 is the first of a bar, so bars start at 2, 6, 10.
private func steadyBeats() -> Grid {
    Grid(beats: (0...8).map { Beat(number: $0, time: 2 + Double($0)) }, barStartNumber: 0)
}

/// A song that slows down: beats at 2, 3, 4, then 5.2, 6.4, 7.6.
private func slowingBeats() -> Grid {
    Grid(beats: [2, 3, 4, 5.2, 6.4, 7.6].enumerated().map { Beat(number: $0.offset, time: $0.element) })
}

@Suite("The snapping grid")
struct SnapGridTests {
    @Test("Each unit has its own lines")
    func linesOfEachUnit() {
        let beats = SnapGrid(grid: steadyBeats(), unit: .beats)
        #expect(close(beats.lines, [2, 3, 4, 5, 6, 7, 8, 9, 10]))

        let halves = SnapGrid(grid: steadyBeats(), unit: .halfBeats)
        #expect(close(Array(halves.lines.prefix(4)), [2, 2.5, 3, 3.5]))
        #expect(halves.lines.count == 17)

        let bars = SnapGrid(grid: steadyBeats(), unit: .bars)
        #expect(close(bars.lines, [2, 6, 10]))
    }

    @Test("Sub-beats are sixteenths")
    func subBeatsAreSixteenths() {
        let sixteenths = SnapGrid(grid: steadyBeats(), unit: .subBeats)
        #expect(close(Array(sixteenths.lines.prefix(5)), [2, 2.25, 2.5, 2.75, 3]))
        #expect(sixteenths.lines.count == 33)
    }

    @Test("The lines follow the tempo")
    func linesFollowTheTempo() {
        let halves = SnapGrid(grid: slowingBeats(), unit: .halfBeats)
        #expect(close(halves.lines, [2, 2.5, 3, 3.5, 4, 4.6, 5.2, 5.8, 6.4, 7.0, 7.6]))
    }

    @Test("A song without beats has a grid that does nothing")
    func noBeatsNoGrid() {
        for grid in [nil, Grid()] {
            let none = SnapGrid(grid: grid, unit: .beats)
            #expect(none.lines.isEmpty)
            #expect(none.nearestLine(to: 3) == nil)
            #expect(none.steppedStart(3.4, grabbedStart: 3) == nil)
        }
        #expect(SnapGrid().steppedStart(3.4, grabbedStart: 3) == nil)
    }

    @Test("The nearest line, also beyond the ends")
    func nearestLine() {
        let beats = SnapGrid(grid: steadyBeats(), unit: .beats)
        #expect(beats.nearestLine(to: 4.4) == 4)
        #expect(beats.nearestLine(to: 4.6) == 5)
        #expect(beats.nearestLine(to: 5) == 5)
        #expect(beats.nearestLine(to: 0) == 2)
        #expect(beats.nearestLine(to: 30) == 10)
    }

    @Test("A moved clip goes in steps and keeps its distance to the grid")
    func stepsKeepTheDistance() {
        let beats = SnapGrid(grid: steadyBeats(), unit: .beats)
        // Grabbed 0.13 seconds after the beat at second 4.
        let grabbed = 4.13
        // Hardly moved: it stays.
        #expect(close(beats.steppedStart(4.3, grabbedStart: grabbed), 4.13))
        // Past the middle between two beats it takes the step.
        #expect(close(beats.steppedStart(4.7, grabbedStart: grabbed), 5.13))
        #expect(close(beats.steppedStart(7.2, grabbedStart: grabbed), 7.13))
        // And backwards.
        #expect(close(beats.steppedStart(2.4, grabbedStart: grabbed), 2.13))

        // A clip that was before its nearest line stays before the lines.
        #expect(close(beats.steppedStart(6.4, grabbedStart: 3.9), 5.9))

        // A clip that was on a line stays on lines.
        #expect(close(beats.steppedStart(6.4, grabbedStart: 3), 6))
    }

    @Test("The steps are as long as the beats are there")
    func stepsFollowTheTempo() {
        let beats = SnapGrid(grid: slowingBeats(), unit: .beats)
        // On the beat at 3, taken to where the beats are 1.2 seconds apart.
        #expect(close(beats.steppedStart(5.0, grabbedStart: 3), 5.2))
        #expect(close(beats.steppedStart(6.1, grabbedStart: 3), 6.4))
        #expect(close(beats.steppedStart(7.1, grabbedStart: 3), 7.6))
    }

    @Test("In bars a clip moves a whole bar at a time")
    func barSteps() {
        let bars = SnapGrid(grid: steadyBeats(), unit: .bars)
        // A clip one beat into the first bar is nearer the bar line at 2 than the one at 6.
        #expect(close(bars.steppedStart(4.5, grabbedStart: 3), 3))
        #expect(close(bars.steppedStart(5.5, grabbedStart: 3), 7))
    }

    @Test("Where the song has no beats the clip moves freely")
    func noStepsOutsideTheBeats() {
        let beats = SnapGrid(grid: steadyBeats(), unit: .beats)
        #expect(beats.steppedStart(1.2, grabbedStart: 4.13) == nil)
        #expect(beats.steppedStart(12, grabbedStart: 4.13) == nil)
        // Its place on the grid is what counts, not its own start: 0.13 after the first line is on the grid.
        #expect(close(beats.steppedStart(2.2, grabbedStart: 4.13), 2.13))
    }
}

@Suite("What snapping catches on")
struct SnapChoicesTests {
    /// A clip on each track, and the moved clip on the first track: it was recorded at second 10 and has
    /// been moved to second 12 since.
    private func project() -> (project: Project, moved: Clip) {
        var project = song()
        record(2, in: &project)                 // second 2 to 3
        record(5, in: &project, track: 1)       // second 5 to 6
        let id = record(10, in: &project)       // second 10 to 11
        project.moveClips([id], bySamples: 96_000, trackSteps: 0, voices: .none)
        return (project, project.clip(id)!)
    }

    /// What the moved clip catches on when its start is taken near a place, with these choices.
    private func caught(_ choices: SnapChoices, near start: Double) -> SnapKind? {
        let (project, moved) = project()
        let engine = SnapEngine(
            sources: choices.sources(forMoving: moved, in: project, playheadAt: 8),
            moving: [moved.id]
        )
        return engine.snap(start: start, end: start + 1, tolerance: 0.1)?.point.kind
    }

    @Test("Everything starts switched on, with beats as the unit")
    func startsSwitchedOn() {
        let choices = SnapChoices()
        #expect(choices.grid && choices.clipEdges && choices.playhead && choices.recordedPlace)
        #expect(choices.gridUnit == .beats)
    }

    @Test("Each kind of point catches only while it is switched on")
    func eachKindByItself() {
        #expect(caught(SnapChoices(), near: 3.05) == .clipEdge)
        #expect(caught(SnapChoices(clipEdges: false), near: 3.05) == nil)

        #expect(caught(SnapChoices(), near: 8.05) == .playhead)
        #expect(caught(SnapChoices(playhead: false), near: 8.05) == nil)

        #expect(caught(SnapChoices(), near: 10.05) == .recordedPosition)
        #expect(caught(SnapChoices(recordedPlace: false), near: 10.05) == nil)

        // Switching one off leaves the others.
        #expect(caught(SnapChoices(clipEdges: false, recordedPlace: false), near: 8.05) == .playhead)
        #expect(caught(SnapChoices(grid: false, clipEdges: false, playhead: false), near: 10.05) == .recordedPosition)
    }

    @Test("A moved clip never catches on grid lines: it goes in steps instead")
    func noGridLinesForAMove() {
        let (project, moved) = project()
        let sources = SnapChoices().sources(forMoving: moved, in: project, playheadAt: 8)
        #expect(sources.count == 3)
        #expect(!sources.contains { $0 is GridLineSource })
        #expect(SnapChoices(clipEdges: false, playhead: false, recordedPlace: false)
            .sources(forMoving: moved, in: project, playheadAt: 8).isEmpty)
    }

    @Test("A trimmed edge catches on the grid's lines, and on nothing of its own clip")
    func trimSources() {
        let (project, moved) = project()
        let grid = SnapGrid(grid: steadyBeats(), unit: .beats)
        func caught(_ choices: SnapChoices, at edge: Double) -> SnapPoint? {
            let engine = SnapEngine(
                sources: choices.sources(forTrimmingIn: project, playheadAt: 8.5, grid: grid),
                moving: [moved.id]
            )
            return engine.snap(start: edge, end: edge, tolerance: 0.1)?.point
        }

        #expect(caught(SnapChoices(), at: 7.05) == SnapPoint(time: 7, kind: .gridLine))
        #expect(caught(SnapChoices(grid: false), at: 7.05) == nil)
        #expect(caught(SnapChoices(), at: 8.45)?.kind == .playhead)
        // A clip edge on a grid line is the point that is named.
        #expect(caught(SnapChoices(), at: 3.02)?.kind == .clipEdge)
        #expect(caught(SnapChoices(clipEdges: false), at: 3.02)?.kind == .gridLine)
        // The recorded place is for moves only.
        let sources = SnapChoices().sources(forTrimmingIn: project, playheadAt: 8.5, grid: grid)
        #expect(!sources.contains { $0 is RecordedPositionSource })
        // A grid without lines adds nothing.
        #expect(SnapChoices().sources(forTrimmingIn: project, playheadAt: 8.5, grid: SnapGrid()).count == 2)
    }

    @Test("The choices are kept in the settings")
    @MainActor
    func keptInTheSettings() throws {
        let name = "SnapChoicesTests-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        let settings = AppSettings(store: store)
        #expect(settings.snapChoices == SnapChoices())

        settings.snapChoices = SnapChoices(grid: false, playhead: false, gridUnit: .bars)

        let again = AppSettings(store: store)
        #expect(again.snapChoices == SnapChoices(grid: false, playhead: false, gridUnit: .bars))
        #expect(again[.snapGridUnit] == .bars)
    }
}

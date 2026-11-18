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

/// Moves clips the way the app does, inside an edit: the move, then the takes put right.
@discardableResult
private func move(_ ids: Set<UUID>, bySamples delta: Int = 0, trackSteps: Int = 0, in project: inout Project) -> ClipMove {
    let made = project.moveClips(ids, bySamples: delta, trackSteps: trackSteps, voices: .none)
    project.normalizeTakes()
    return made
}

private func close(_ a: Double?, _ b: Double, within tolerance: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

/// Moving clips in time and between tracks, and naming them, worked out with numbers alone.
@Suite("Moving and naming clips")
struct ProjectMovesTests {
    // MARK: Moving in time

    @Test func aMoveOf480SamplesShiftsTheStartAndEveryMarkerByTenMilliseconds() {
        // A clip of two parts of one recording, as after a cut, with the places of four syllables in the
        // recording. Markers belong to the recording and get their song time from the position rule.
        var project = song()
        let recording = Recording(lengthSamples: 96_000, rawStart: 4, delay: 0.25)
        let id = project.addRecording(recording, samples: 0..<96_000, asClipOn: project.tracks[0].id, voices: .none)!
        project.tracks[0].clips[0].segments = [
            Segment(recordingID: recording.id, inSample: 4_800, outSample: 43_200),
            Segment(recordingID: recording.id, inSample: 52_800, outSample: 91_200),
        ]
        let markers: [(sample: Int, segment: Int)] = [(6_000, 0), (20_000, 0), (60_000, 1), (88_000, 1)]
        func markerTimes() -> [Double] {
            let clip = project.clip(id)!
            return markers.map {
                recording.songTime(ofSample: $0.sample, offsetSamples: clip.segments[$0.segment].offsetSamples)
            }
        }
        let startBefore = project.start(of: project.clip(id)!)!
        let endBefore = project.end(of: project.clip(id)!)!
        let markersBefore = markerTimes()

        let made = move([id], bySamples: 480, in: &project)

        #expect(made == ClipMove(samples: 480, trackSteps: 0))
        let clip = project.clip(id)!
        #expect(clip.segments.map(\.offsetSamples) == [480, 480])
        #expect(close(project.start(of: clip), startBefore + 0.010))
        #expect(close(project.end(of: clip), endBefore + 0.010))
        for (before, after) in zip(markersBefore, markerTimes()) {
            #expect(close(after, before + 0.010))
        }
        // Nothing else about the clip changed, and the recording was not touched.
        #expect(clip.segments.map(\.inSample) == [4_800, 52_800])
        #expect(clip.segments.map(\.outSample) == [43_200, 91_200])
        #expect(project.recordings == [recording])
    }

    @Test func aMovePastTheEndOfTheSongIsReduced() {
        var project = song()
        let id = record(18, in: &project)

        let made = move([id], bySamples: 96_000, in: &project)

        #expect(made == ClipMove(samples: 48_000, trackSteps: 0))
        #expect(close(project.end(of: project.clip(id)!), 20))
    }

    @Test func aMoveBeforeTheStartOfTheSongIsReduced() {
        var project = song()
        let id = record(0.5, in: &project)

        let made = move([id], bySamples: -96_000, in: &project)

        #expect(made == ClipMove(samples: -24_000, trackSteps: 0))
        #expect(close(project.start(of: project.clip(id)!), 0))
    }

    @Test func aReducedMoveKeepsSeveralClipsAtTheirDistances() {
        // The later clip can go one second further, the earlier one four. Both go one.
        var project = song()
        let early = record(15, in: &project)
        let late = record(18, in: &project, track: 1)

        let made = move([early, late], bySamples: 480_000, in: &project)

        #expect(made.samples == 48_000)
        #expect(close(project.start(of: project.clip(early)!), 16))
        #expect(close(project.start(of: project.clip(late)!), 19))
        #expect(project.allowedMove(of: [early, late], bySamples: 1, trackSteps: 0).isNothing)
    }

    @Test func aClipAlreadyOutsideTheSongCanOnlyMoveInward() {
        // Recorded with the count-in: it starts half a second before the song.
        var project = song()
        let id = record(-0.5, in: &project)

        #expect(project.allowedMove(of: [id], bySamples: -4_800, trackSteps: 0).isNothing)
        #expect(project.allowedMove(of: [id], bySamples: 4_800, trackSteps: 0) == ClipMove(samples: 4_800))
    }

    @Test func aMoveStopsWhereTheSongIsCutAway() {
        // Two seconds are cut away at each end: seconds 2 to 18 are left.
        var project = song()
        project.songPlace = SongPlace(cutStartSamples: 96_000, cutEndSamples: 96_000)
        let early = record(3, in: &project)
        let late = record(16, in: &project, track: 1)

        #expect(move([early], bySamples: -480_000, in: &project) == ClipMove(samples: -48_000))
        #expect(close(project.start(of: project.clip(early)!), 2))
        #expect(move([late], bySamples: 480_000, in: &project) == ClipMove(samples: 48_000))
        #expect(close(project.end(of: project.clip(late)!), 18))
        // Standing on the cut, a clip goes no further out and still goes in.
        #expect(project.allowedMove(of: [early], bySamples: -1, trackSteps: 0).isNothing)
        #expect(project.allowedMove(of: [late], bySamples: 1, trackSteps: 0).isNothing)
        #expect(project.allowedMove(of: [early], bySamples: 4_800, trackSteps: 0) == ClipMove(samples: 4_800))
    }

    @Test func aMoveStopsAtZeroOfASongMovedSoThatZeroLiesInsideIt() {
        // The song is dragged five seconds to the left: what lies before 00:00 is not played.
        var project = song()
        project.songPlace = SongPlace().moved(bySamples: -240_000, ofLength: project.songLengthSamples)
        let id = record(6, in: &project)

        #expect(move([id], bySamples: -480_000, in: &project) == ClipMove(samples: -48_000))
        #expect(close(project.start(of: project.clip(id)!), 5))
        #expect(project.songPlace.timelineSeconds(forSong: project.start(of: project.clip(id)!)!) == 0)
    }

    @Test func aClipInAPartThatIsThenCutAwayStaysAndCanOnlyMoveInward() {
        var project = song()
        let inside = record(0.5, in: &project)
        let across = record(1.5, in: &project, track: 1)
        let before = project.tracks
        // Two seconds are cut away at the start: one clip lies wholly in the cut, one across its edge.
        project.songPlace = SongPlace(cutStartSamples: 96_000)

        #expect(project.tracks == before)
        for id in [inside, across] {
            #expect(project.allowedMove(of: [id], bySamples: -4_800, trackSteps: 0).isNothing)
            #expect(project.allowedMove(of: [id], bySamples: 4_800, trackSteps: 0) == ClipMove(samples: 4_800))
        }
    }

    @Test func allowedMoveSaysWhatMoveClipsThenDoes() {
        var project = song()
        let id = record(18, in: &project)

        let asked = project.allowedMove(of: [id], bySamples: 96_000, trackSteps: 1)
        let made = project.moveClips([id], bySamples: 96_000, trackSteps: 1, voices: .none)

        #expect(asked == ClipMove(samples: 48_000, trackSteps: 1))
        #expect(made == asked)
    }

    @Test func aMoveOfNothingOrOfAnUnknownClipChangesNothing() {
        var project = song()
        let id = record(5, in: &project)
        let before = project

        let byNothing = project.moveClips([id], bySamples: 0, trackSteps: 0, voices: .none)
        let unknownClip = project.moveClips([UUID()], bySamples: 480, trackSteps: 1, voices: .none)
        let noClips = project.moveClips([], bySamples: 480, trackSteps: 1, voices: .none)

        #expect(byNothing.isNothing)
        #expect(unknownClip.isNothing)
        #expect(noClips.isNothing)
        #expect(project == before)
    }

    // MARK: Moving to another track

    @Test func movingToAnotherTrackKeepsTheTime() {
        var project = song()
        let id = record(5, in: &project)
        project.renameClip(id, to: "Hook")
        let before = project.clip(id)!

        let made = move([id], trackSteps: 1, in: &project)

        #expect(made == ClipMove(samples: 0, trackSteps: 1))
        #expect(project.tracks[0].clips.isEmpty)
        #expect(project.tracks[1].clips == [before])
        #expect(close(project.start(of: project.clip(id)!), 5))

        move([id], trackSteps: -1, in: &project)
        #expect(project.tracks[0].clips == [before])
        #expect(project.tracks[1].clips.isEmpty)
    }

    @Test func aTrackStepOutsideTheTracksIsRefusedForAllClips() {
        // One clip on each of the two tracks. A step down has no track for the lower one, a step up none for
        // the upper one, so neither changes track. The move in time is still made.
        var project = song()
        let upper = record(5, in: &project, track: 0)
        let lower = record(8, in: &project, track: 1)

        let down = move([upper, lower], bySamples: 480, trackSteps: 1, in: &project)
        #expect(down == ClipMove(samples: 480, trackSteps: 0))
        #expect(project.tracks[0].clips.map(\.id) == [upper])
        #expect(project.tracks[1].clips.map(\.id) == [lower])
        #expect(project.recordedOffset(of: project.clip(upper)!) == 480)
        #expect(project.recordedOffset(of: project.clip(lower)!) == 480)

        let up = move([upper, lower], trackSteps: -1, in: &project)
        let twoDown = move([lower], trackSteps: 2, in: &project)
        #expect(up.isNothing)
        #expect(twoDown.isNothing)
        #expect(project.tracks[1].clips.map(\.id) == [lower])
    }

    @Test func clipsOnDifferentTracksStepTogether() {
        var project = song()
        project.addTrack()
        let upper = record(5, in: &project, track: 0)
        let lower = record(8, in: &project, track: 1)

        let made = move([upper, lower], trackSteps: 1, in: &project)

        #expect(made.trackSteps == 1)
        #expect(project.tracks.map { $0.clips.map(\.id) } == [[], [upper], [lower]])
    }

    // MARK: Takes

    @Test func aClipWithThreeTakesMovesAllThree() {
        var project = song()
        // Three takes of one line: each was recorded from the same place, and the voice started a little
        // later every time.
        let first = record(2.0, in: &project)
        let second = record(2.1, in: &project, aimedAt: 2.0)
        let third = record(2.2, in: &project, aimedAt: 2.0)
        let other = record(10, in: &project)
        project.normalizeTakes()
        project.setActiveTake(second)

        // Only the take that is shown is handed over. One second later and one track down.
        let made = move([second], bySamples: 48_000, trackSteps: 1, in: &project)

        #expect(made == ClipMove(samples: 48_000, trackSteps: 1))
        #expect(project.tracks[0].clips.map(\.id) == [other])
        #expect(project.tracks[1].clips.map(\.id) == [first, second, third])
        #expect(close(project.start(of: project.clip(first)!), 3.0))
        #expect(close(project.start(of: project.clip(second)!), 3.1))
        #expect(close(project.start(of: project.clip(third)!), 3.2))
        #expect(project.takes(of: second).map(\.id) == [first, second, third])
        #expect(project.tracks[1].clips.filter(\.isActiveTake).map(\.id) == [second])
        #expect(close(project.start(of: project.clip(other)!), 10))
        #expect(project.clipsMovingTogether(with: [second]) == [first, second, third])
    }

    @Test func aWaitingTakeAlsoKeepsTheLineInsideTheSong() {
        // The take that is shown ends at 19.5 s, the one behind it at 19.8 s. The line can go 0.2 s further.
        var project = song()
        let waiting = record(18.8, in: &project)
        let shown = record(18.5, in: &project, aimedAt: 18.8)
        project.normalizeTakes()

        let made = move([shown], bySamples: 48_000, in: &project)

        #expect(made.samples == 9_600)
        #expect(close(project.end(of: project.clip(waiting)!), 20))
    }

    @Test func movingAClipOntoTheStartOfAnotherMakesItATakeOfThatLine() {
        var project = song()
        let resting = record(5, in: &project, track: 0)
        let dropped = record(9, in: &project, track: 1)
        project.normalizeTakes()
        #expect(project.takeCount(of: resting) == 1)

        // Up one track and onto the other clip, 40 ms after its start: within the 50 ms that make a take.
        move([dropped], bySamples: -190_080, trackSteps: -1, in: &project)

        #expect(project.takes(of: resting).map(\.id) == [resting, dropped])
        #expect(project.takeCount(of: dropped) == 2)
        // The clip that was moved is the one shown, and nothing was cut.
        #expect(project.tracks[0].clips.filter(\.isActiveTake).map(\.id) == [dropped])
        #expect(project.clip(resting)!.segments[0].lengthSamples == 48_000)
        // From now on the two move as one line.
        move([dropped], bySamples: 48_000, in: &project)
        #expect(close(project.start(of: project.clip(resting)!), 6))
        #expect(close(project.start(of: project.clip(dropped)!), 6.04))
    }

    @Test func movingAClipOntoAnotherAwayFromItsStartMakesTheOtherGiveWay() {
        var project = song()
        let resting = record(5, 2, in: &project, track: 0)
        let dropped = record(9, in: &project, track: 1)
        project.normalizeTakes()

        // Up one track and onto the last second of the other clip.
        move([dropped], bySamples: -144_000, trackSteps: -1, in: &project)

        #expect(project.takeCount(of: resting) == 1)
        #expect(project.takeCount(of: dropped) == 1)
        #expect(project.tracks[0].clips.filter(\.isActiveTake).map(\.id) == [resting, dropped])
        // The clip that stood still ends where the moved one starts, and can be dragged out again.
        #expect(close(project.start(of: project.clip(resting)!), 5))
        #expect(close(project.end(of: project.clip(resting)!), 6))
        #expect(close(project.start(of: project.clip(dropped)!), 6))
        #expect(project.trimRange(of: resting, edge: .end)?.upperBound == 7 * 48_000)
    }

    // MARK: The recorded place

    @Test func recordedOffsetAfterAMoveAndAfterMovingBack() {
        var project = song()
        let id = record(5, in: &project)
        #expect(project.recordedOffset(of: project.clip(id)!) == 0)
        #expect(close(project.recordedStart(of: project.clip(id)!), 5))

        move([id], bySamples: -1_200, trackSteps: 1, in: &project)
        #expect(project.recordedOffset(of: project.clip(id)!) == -1_200)
        #expect(close(project.start(of: project.clip(id)!), 4.975))
        #expect(close(project.recordedStart(of: project.clip(id)!), 5))

        move([id], bySamples: 1_200, in: &project)
        #expect(project.recordedOffset(of: project.clip(id)!) == 0)
        #expect(close(project.start(of: project.clip(id)!), 5))
    }

    @Test func recordedStartOfAClipCutAtItsFrontIsWhereThatPartWasRecorded() {
        // A clip that plays its recording from half a second in was recorded half a second after the
        // recording began, and stays "at its recorded place" there.
        var project = song()
        let recording = Recording(lengthSamples: 96_000, rawStart: 4)
        let id = project.addRecording(recording, samples: 24_000..<96_000, asClipOn: project.tracks[0].id, voices: .none)!

        #expect(close(project.recordedStart(of: project.clip(id)!), 4.5))
        #expect(project.recordedOffset(of: Clip()) == 0)
        #expect(project.recordedStart(of: Clip()) == nil)
    }

    // MARK: Naming

    @Test func renameTrimsSpacesAndAnEmptyNameClearsIt() {
        var project = song()
        let id = record(5, in: &project)
        project.tracks[0].clips[0].text = "I stay behind when all the others leave"

        let named = project.renameClip(id, to: "  Hook 1 \n")
        #expect(named)
        #expect(project.clip(id)!.name == "Hook 1")
        #expect(project.clip(id)!.displayName == "Hook 1")

        // The same name again changes nothing.
        let namedTheSame = project.renameClip(id, to: "Hook 1")
        #expect(!namedTheSame)

        let cleared = project.renameClip(id, to: "   ")
        #expect(cleared)
        #expect(project.clip(id)!.name == nil)
        #expect(project.clip(id)!.displayName == "I stay behind when all the…")

        let clearedAgain = project.renameClip(id, to: "")
        let unknownClip = project.renameClip(UUID(), to: "Hook")
        #expect(!clearedAgain)
        #expect(!unknownClip)
    }

    @Test func renameNamesOnlyTheOneTake() {
        var project = song()
        let first = record(2.0, in: &project)
        let second = record(2.1, in: &project, aimedAt: 2.0)
        project.normalizeTakes()

        project.renameClip(second, to: "Best one")

        #expect(project.clip(first)!.name == nil)
        #expect(project.clip(second)!.name == "Best one")
    }
}

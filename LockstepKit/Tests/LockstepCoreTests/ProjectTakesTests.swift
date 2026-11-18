import Foundation
import Testing
@testable import LockstepCore

/// A twenty-second song with one empty track, "Track 1".
private func emptySong() -> Project {
    Project(songLengthSamples: 960_000)
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

/// A saved project as it was written before each clip kept its line: the same, with no `line` on any clip.
func withoutLines(_ saved: Data) throws -> Data {
    var project = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    var tracks = try #require(project["tracks"] as? [[String: Any]])
    for track in tracks.indices {
        var clips = tracks[track]["clips"] as? [[String: Any]] ?? []
        for clip in clips.indices {
            clips[clip]["line"] = nil
        }
        tracks[track]["clips"] = clips
    }
    project["tracks"] = tracks
    return try JSONSerialization.data(withJSONObject: project)
}

/// The ids of the clips that are active takes, in the order the tracks hold them.
private func activeClips(of project: Project) -> [UUID] {
    project.tracks.flatMap(\.clips).filter(\.isActiveTake).map(\.id)
}

/// Which clips are takes of each other, and which one of them is heard, worked out with numbers alone.
@Suite("Takes")
struct ProjectTakesTests {
    // MARK: What is a group

    @Test func threeTakesRecordedFromOnePlaceAreOneLineWithTheLastRecordedActive() {
        // The same one-second line three times, recorded from the same place. The voice started later each
        // time, so the first and the third overlap by only a fifth, and still all three are one line.
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(2.4, in: &project, aimedAt: 2.0)
        let third = record(2.8, in: &project, aimedAt: 2.0)
        project.normalizeTakes()

        let track = project.tracks[0].id
        #expect(project.takeGroups(on: track).map { $0.map(\.id) } == [[first, second, third]])
        #expect(activeClips(of: project) == [third])
        for clip in [first, second, third] {
            #expect(project.takes(of: clip).map(\.id) == [first, second, third])
            #expect(project.takeCount(of: clip) == 3)
        }
        #expect(project.takeNumber(of: first) == 1)
        #expect(project.takeNumber(of: second) == 2)
        #expect(project.takeNumber(of: third) == 3)
        // No take was cut by the others.
        #expect(project.tracks[0].clips.map { $0.segments[0].lengthSamples } == [48_000, 48_000, 48_000])
    }

    @Test func takesAreNumberedInTheOrderRecordedNotByWhereTheySit() {
        var project = emptySong()
        let first = record(2.6, in: &project)
        let second = record(2.0, in: &project, aimedAt: 2.6)
        let third = record(2.3, in: &project, aimedAt: 2.6)
        project.normalizeTakes()

        #expect(project.takes(of: second).map(\.id) == [first, second, third])
        #expect(project.takeNumber(of: second) == 2)
        #expect(activeClips(of: project) == [third])
    }

    @Test func twoClipsTouchingAtTheirEdgesAreNotAGroup() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(3.0, in: &project)
        project.normalizeTakes()

        #expect(project.takeGroups(on: project.tracks[0].id).isEmpty)
        #expect(activeClips(of: project) == [first, second])
        #expect(project.takes(of: first).map(\.id) == [first])
        #expect(project.takeNumber(of: second) == 1)
        #expect(project.takeCount(of: second) == 1)
        #expect(project.clip(first)!.segments[0].lengthSamples == 48_000)
    }

    @Test func aStartWithinFiftyMillisecondsIsATakeAndOneSampleMoreIsNot() {
        // Exactly 50 ms after the start of the clip that is there: 2,400 samples.
        var within = emptySong()
        let line = record(2.0, in: &within)
        let take = record(2.05, in: &within)
        #expect(within.takes(of: line).map(\.id) == [line, take])
        #expect(within.clip(line)!.segments[0].lengthSamples == 48_000)

        // One sample later it is a clip of its own. It covers all of the clip that was there but its first
        // 50 ms, and a rest that short is not kept, so that clip is gone.
        var beyond = emptySong()
        let other = record(2.0, in: &beyond)
        let later = Recording(lengthSamples: 48_001, rawStart: 2.05)
        let new = beyond.addRecording(later, samples: 1..<48_001, asClipOn: beyond.tracks[0].id, voices: .none)!
        #expect(beyond.takeGroups(on: beyond.tracks[0].id).isEmpty)
        #expect(beyond.takeCount(of: new) == 1)
        #expect(beyond.clip(other) == nil)
        #expect(beyond.tracks[0].clips.map(\.id) == [new])
    }

    @Test func clipsAtTheSamePlaceOnDifferentTracksAreNotTakes() {
        var project = emptySong()
        project.tracks.append(Track(name: "Track 2"))
        let one = record(2.0, in: &project, track: 0)
        let two = record(2.0, in: &project, track: 1)
        project.normalizeTakes()

        #expect(project.takeGroups(on: project.tracks[0].id).isEmpty)
        #expect(project.takeGroups(on: project.tracks[1].id).isEmpty)
        #expect(activeClips(of: project) == [one, two])
    }

    @Test func aClipMovedOntoTheStartOfAnotherBecomesItsTake() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(6.0, in: &project)
        project.normalizeTakes()
        #expect(activeClips(of: project) == [first, second])

        // Moved four seconds earlier, onto the first.
        project.moveClips([second], bySamples: -192_000, trackSteps: 0, voices: .none)
        project.normalizeTakes()
        #expect(project.takes(of: first).map(\.id) == [first, second])
        #expect(activeClips(of: project) == [second])
    }

    @Test func twoClipsOfTheSameRecordingKeepTheOrderOfTheTrack() {
        // A clip and a copy of it at the same place, both playing the same recording.
        var project = emptySong()
        let original = record(2.0, in: &project)
        var copy = project.tracks[0].clips[0]
        copy.id = UUID()
        project.tracks[0].clips.append(copy)
        project.normalizeTakes()

        #expect(project.takes(of: original).map(\.id) == [original, copy.id])
        #expect(activeClips(of: project) == [copy.id])
    }

    @Test func aClipWithNoPlaceIsInNoGroupAndAlwaysActive() {
        var project = emptySong()
        let placed = record(2.0, in: &project)
        // One with no segments, and one whose recording the project does not have, both marked as waiting.
        let empty = Clip(isActiveTake: false)
        let lost = Clip(segments: [Segment(recordingID: UUID(), inSample: 0, outSample: 48_000)], isActiveTake: false)
        project.tracks[0].clips += [empty, lost]
        project.normalizeTakes()

        #expect(project.takeGroups(on: project.tracks[0].id).isEmpty)
        #expect(activeClips(of: project) == [placed, empty.id, lost.id])
        #expect(project.takes(of: empty.id).map(\.id) == [empty.id])
    }

    @Test func aClipTheProjectDoesNotHaveHasNoTakes() {
        var project = emptySong()
        record(2.0, in: &project)
        record(2.1, in: &project, aimedAt: 2.0)
        project.normalizeTakes()
        let before = project

        #expect(project.takes(of: UUID()).isEmpty)
        #expect(project.takeNumber(of: UUID()) == nil)
        #expect(project.takeCount(of: UUID()) == 0)
        #expect(project.nextTake(of: UUID()) == nil)
        #expect(project.previousTake(of: UUID()) == nil)
        #expect(project.takeGroups(on: UUID()).isEmpty)
        project.setActiveTake(UUID())
        project.deleteOtherTakes(of: UUID())
        #expect(project == before)
    }

    // MARK: Recording lines

    /// A recording as the app makes one for a one-bar line: Record was pressed with the playhead at `origin`,
    /// the song started one two-second bar earlier, and Max stopped half a second after the bar. The voice is
    /// heard from `voiceStart` to `voiceEnd` seconds of the song. Only that stretch becomes the clip.
    @discardableResult
    private func recordLine(origin: Double, voiceStart: Double, voiceEnd: Double, in project: inout Project) throws -> UUID {
        let recording = Recording(lengthSamples: 216_000, rawStart: origin - 2)
        let voiced = Int(((voiceStart - recording.rawStart) * Lockstep.sampleRate).rounded())
            ..< Int(((voiceEnd - recording.rawStart) * Lockstep.sampleRate).rounded())
        let samples = try #require(RecordingPlacement.clipSamples(of: recording, voiced: voiced, origin: origin))
        let added = project.addRecording(
            recording, samples: samples, asClipOn: project.tracks[0].id, aim: RecordAim(place: origin), voices: .none
        )
        let clip = try #require(added)
        project.normalizeTakes()
        return clip
    }

    @Test func twoOneBarLinesRecordedOneAfterTheOtherAreNotTakesOfEachOther() throws {
        // The first line is on the bar from 4 s to 6 s, the second on the bar after it. The two recordings lie
        // on top of each other for 2.5 s of their 4.5 s, because each begins a bar early and runs a little late.
        // But each clip covers only its voice, and the voices do not meet.
        var project = emptySong()
        let first = try recordLine(origin: 4, voiceStart: 4.1, voiceEnd: 5.8, in: &project)
        let second = try recordLine(origin: 6, voiceStart: 6.1, voiceEnd: 7.8, in: &project)

        #expect(project.takeGroups(on: project.tracks[0].id).isEmpty)
        #expect(activeClips(of: project) == [first, second])
        #expect(project.clipPlaybackPlan(from: 0, voices: .none).count == 2)
    }

    @Test func theSameLineRecordedTwiceIsTwoTakes() throws {
        var project = emptySong()
        let first = try recordLine(origin: 4, voiceStart: 4.1, voiceEnd: 5.8, in: &project)
        let next = try recordLine(origin: 6, voiceStart: 6.1, voiceEnd: 7.8, in: &project)
        let again = try recordLine(origin: 4, voiceStart: 4.15, voiceEnd: 5.9, in: &project)

        #expect(project.takeGroups(on: project.tracks[0].id).map { $0.map(\.id) } == [[first, again]])
        // The new recording is the one heard. The line after it is untouched.
        #expect(activeClips(of: project) == [next, again])
        #expect(project.takeNumber(of: again) == 2)
        #expect(project.takeCount(of: again) == 2)
        #expect(project.takeCount(of: next) == 1)
    }

    @Test func aNewRecordingBecomesTheActiveTakeAlsoWhenAnOlderOneWasChosen() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        record(2.1, in: &project, aimedAt: 2.0)
        project.normalizeTakes()
        project.setActiveTake(first)

        let third = record(2.2, in: &project, aimedAt: 2.0)
        project.normalizeTakes()
        #expect(activeClips(of: project) == [third])
    }

    // MARK: Choosing

    @Test func choosingAnotherTakeDeactivatesTheFirst() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(2.1, in: &project, aimedAt: 2.0)
        let third = record(2.2, in: &project, aimedAt: 2.0)
        let other = record(8.0, in: &project)
        project.normalizeTakes()
        #expect(activeClips(of: project) == [third, other])

        project.setActiveTake(first)
        #expect(activeClips(of: project) == [first, other])
        // The choice is kept: a group with one active take is left alone.
        project.normalizeTakes()
        #expect(activeClips(of: project) == [first, other])

        project.setActiveTake(second)
        #expect(activeClips(of: project) == [second, other])
        // The numbers do not change with the choice.
        #expect(project.takeNumber(of: second) == 2)
    }

    @Test func nextAndPreviousWrap() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(2.1, in: &project, aimedAt: 2.0)
        let third = record(2.2, in: &project, aimedAt: 2.0)
        let alone = record(8.0, in: &project)
        project.normalizeTakes()

        #expect(project.nextTake(of: first) == second)
        #expect(project.nextTake(of: second) == third)
        #expect(project.nextTake(of: third) == first)
        #expect(project.previousTake(of: third) == second)
        #expect(project.previousTake(of: second) == first)
        #expect(project.previousTake(of: first) == third)
        // A clip with no other takes has nowhere to step to.
        #expect(project.nextTake(of: alone) == nil)
        #expect(project.previousTake(of: alone) == nil)

        // Asking changes nothing. Stepping is asking, then choosing.
        #expect(activeClips(of: project) == [third, alone])
        project.setActiveTake(project.nextTake(of: third)!)
        #expect(activeClips(of: project) == [first, alone])
    }

    // MARK: Deleting

    @Test func deletingTheActiveTakeMakesTheLatestRemainingOneActive() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(2.1, in: &project, aimedAt: 2.0)
        let third = record(2.2, in: &project, aimedAt: 2.0)
        project.normalizeTakes()

        // The newest is active. Without it, the second is the latest.
        var withoutNewest = project
        withoutNewest.removeClips([third])
        withoutNewest.normalizeTakes()
        #expect(activeClips(of: withoutNewest) == [second])

        // The first was chosen. Without it, the third is the latest.
        var withoutChosen = project
        withoutChosen.setActiveTake(first)
        withoutChosen.removeClips([first])
        withoutChosen.normalizeTakes()
        #expect(activeClips(of: withoutChosen) == [third])
        #expect(withoutChosen.takeNumber(of: third) == 2)

        // Deleting a take that waits leaves the choice alone.
        var withoutWaiting = project
        withoutWaiting.setActiveTake(first)
        withoutWaiting.removeClips([third])
        withoutWaiting.normalizeTakes()
        #expect(activeClips(of: withoutWaiting) == [first])
    }

    @Test func theLastTakeLeftIsActiveAgain() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(2.1, in: &project, aimedAt: 2.0)
        project.normalizeTakes()

        project.removeClips([second])
        #expect(activeClips(of: project).isEmpty)
        project.normalizeTakes()
        #expect(activeClips(of: project) == [first])
    }

    @Test func deleteOtherTakesKeepsOnlyTheGivenClip() {
        var project = emptySong()
        record(2.0, in: &project)
        let second = record(2.1, in: &project, aimedAt: 2.0)
        record(2.2, in: &project, aimedAt: 2.0)
        let otherLine = record(8.0, in: &project)
        let otherTake = record(8.1, in: &project, aimedAt: 8.0)
        project.normalizeTakes()

        // The second waits. Asked for by name, it is the one that stays, and it is heard.
        project.deleteOtherTakes(of: second)
        #expect(project.tracks[0].clips.map(\.id) == [second, otherLine, otherTake])
        #expect(activeClips(of: project) == [second, otherTake])
        #expect(project.takeCount(of: second) == 1)
        // The recordings stay, so an undo can bring the takes back with their sound.
        #expect(project.recordings.count == 5)

        // A clip with no other takes loses nothing.
        let before = project
        project.deleteOtherTakes(of: second)
        #expect(project == before)
    }

    // MARK: What is heard

    @Test func theSchedulingPlanPlaysOneClipPerGroup() {
        // One line recorded three times, another recorded twice, and a line with one recording.
        var project = emptySong()
        let first = record(2.0, in: &project)
        record(2.1, in: &project, aimedAt: 2.0)
        record(2.2, in: &project, aimedAt: 2.0)
        record(8.0, in: &project)
        record(8.1, in: &project, aimedAt: 8.0)
        record(12.0, in: &project)
        project.normalizeTakes()
        let recordings = project.recordings.map(\.id)

        // The latest of each line, in the order the track holds them.
        #expect(project.clipPlaybackPlan(from: 0, voices: .none).map(\.recordingID) == [recordings[2], recordings[4], recordings[5]])

        // Another take is chosen for the first line, and that one is heard instead.
        project.setActiveTake(first)
        #expect(project.clipPlaybackPlan(from: 0, voices: .none).map(\.recordingID) == [recordings[0], recordings[4], recordings[5]])

        // A muted active take is silent. The takes behind it do not come forward.
        project.setClips([first], muted: true)
        project.normalizeTakes()
        #expect(project.clipPlaybackPlan(from: 0, voices: .none).map(\.recordingID) == [recordings[4], recordings[5]])
    }
}

/// The takes rule in the place that holds the open project: after every edit, on undo, and when a project opens.
@Suite("Takes, in the store")
@MainActor
struct ProjectStoreTakesTests {
    /// Records a one-second clip beginning `start` seconds into the song, as one edit. Returns the clip's id.
    private func recordEdit(_ start: Double, in store: ProjectStore, aimedAt aim: Double? = nil) -> UUID {
        var clip: UUID?
        store.edit("Record Clip") { clip = record(start, in: &$0, aimedAt: aim) }
        return clip!
    }

    @Test func recordingTheSameLineAgainLeavesOneActiveTakeAndUndoBringsTheOldOneBack() {
        let store = ProjectStore(project: emptySong())
        let first = recordEdit(2.0, in: store)
        #expect(activeClips(of: store.project) == [first])
        let second = recordEdit(2.1, in: store, aimedAt: 2.0)
        #expect(activeClips(of: store.project) == [second])
        let third = recordEdit(2.2, in: store, aimedAt: 2.0)
        #expect(activeClips(of: store.project) == [third])
        #expect(store.project.takeCount(of: third) == 3)
        #expect(store.project.clipPlaybackPlan(from: 0, voices: .none).count == 1)

        store.undo()
        #expect(store.project.tracks[0].clips.map(\.id) == [first, second])
        #expect(activeClips(of: store.project) == [second])
        store.redo()
        #expect(activeClips(of: store.project) == [third])
    }

    @Test func deletingTheActiveTakeBringsTheLatestRemainingForwardAndUndoPutsItBack() {
        let store = ProjectStore(project: emptySong())
        let first = recordEdit(2.0, in: store)
        let second = recordEdit(2.1, in: store, aimedAt: 2.0)
        let third = recordEdit(2.2, in: store, aimedAt: 2.0)

        store.edit("Delete Clip") { $0.removeClips([third]) }
        #expect(activeClips(of: store.project) == [second])
        store.edit("Delete Clip") { $0.removeClips([second]) }
        #expect(activeClips(of: store.project) == [first])

        store.undo()
        #expect(activeClips(of: store.project) == [second])
        store.undo()
        #expect(activeClips(of: store.project) == [third])
    }

    @Test func aChosenTakeStaysChosenAndUndoBringsThePreviousChoiceBack() {
        let store = ProjectStore(project: emptySong())
        let first = recordEdit(2.0, in: store)
        _ = recordEdit(2.1, in: store, aimedAt: 2.0)
        let third = recordEdit(2.2, in: store, aimedAt: 2.0)

        store.edit("Choose Take") { $0.setActiveTake(first) }
        #expect(activeClips(of: store.project) == [first])
        // An edit of something else leaves the choice alone.
        store.edit("Rename") { $0.songName = "Another name" }
        #expect(activeClips(of: store.project) == [first])

        store.undo()
        store.undo()
        #expect(activeClips(of: store.project) == [third])
    }

    /// A project as phases 9 and 10 saved it: one line recorded three times and one recorded once, with every
    /// clip marked active because the takes rule did not exist yet.
    private func savedBeforeTakes() throws -> (project: Project, clips: [UUID]) {
        let recordings = [2.0, 2.1, 2.2, 8.0].map { Recording(lengthSamples: 48_000, rawStart: $0) }
        let clips = recordings.map { Clip(segments: [Segment(recordingID: $0.id, inSample: 0, outSample: 48_000)]) }
        let project = Project(
            songLengthSamples: 960_000,
            tracks: [Track(name: "Track 1", clips: clips)],
            recordings: recordings
        )
        // Through the saved form, as when it is read from disk. A project of that time has no lines saved.
        let read = try JSONDecoder().decode(Project.self, from: withoutLines(JSONEncoder().encode(project)))
        #expect(read.tracks[0].clips.map(\.isActiveTake) == [true, true, true, true])
        return (read, clips.map(\.id))
    }

    @Test func aProjectWithOverlappingClipsThatAreAllActiveIsPutRightWhenOpened() throws {
        let saved = try savedBeforeTakes()
        #expect(saved.project.clipPlaybackPlan(from: 0, voices: .none).count == 4)

        let store = ProjectStore()
        store.open(saved.project)
        #expect(activeClips(of: store.project) == [saved.clips[2], saved.clips[3]])
        #expect(store.project.takeCount(of: saved.clips[2]) == 3)
        #expect(store.project.clipPlaybackPlan(from: 0, voices: .none).count == 2)
        // Opening is not an edit: there is nothing to undo.
        #expect(store.undoTitle == nil)
    }

    @Test func aStoreMadeWithAProjectHoldsItWithTheTakesPutRight() throws {
        let saved = try savedBeforeTakes()
        let store = ProjectStore(project: saved.project)
        #expect(activeClips(of: store.project) == [saved.clips[2], saved.clips[3]])
    }
}

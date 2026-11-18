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

/// The names of the tracks, top to bottom.
private func names(of project: Project) -> [String] {
    project.tracks.map(\.name)
}

/// Every clip id in the project, in no order.
private func clipIDs(of project: Project) -> Set<UUID> {
    Set(project.tracks.flatMap(\.clips).map(\.id))
}

/// What each track command does to a project, worked out with numbers alone.
@Suite("Track commands")
struct ProjectTracksTests {
    // MARK: New Track

    @Test func aNewTrackIsEmptyAtTheBottomWithTheNextNumber() {
        var project = emptySong()
        let second = project.addTrack()
        let third = project.addTrack()

        #expect(names(of: project) == ["Track 1", "Track 2", "Track 3"])
        #expect(project.tracks.map(\.id).suffix(2) == [second, third])
        #expect(project.tracks[2] == Track(id: third, name: "Track 3"))
    }

    @Test func theFourthTrackAfterDeletingTrack2IsTrack2() {
        var project = emptySong()
        let second = project.addTrack()
        project.addTrack()
        project.deleteTrack(second)
        #expect(names(of: project) == ["Track 1", "Track 3"])

        let fourth = project.addTrack()
        #expect(names(of: project) == ["Track 1", "Track 3", "Track 2"])
        #expect(project.tracks.last?.id == fourth)
    }

    @Test func aRenamedTrackGivesItsNumberBack() {
        var project = emptySong()
        project.renameTrack(project.tracks[0].id, to: "Lead")
        #expect(project.nextTrackName() == "Track 1")
        project.addTrack()
        project.addTrack()
        #expect(names(of: project) == ["Lead", "Track 1", "Track 2"])
    }

    // MARK: Rename

    @Test func aNameIsTrimmedAndAnEmptyOneIsRefused() {
        var project = emptySong()
        let track = project.tracks[0].id

        let trimmed = project.renameTrack(track, to: "  Double \n")
        #expect(trimmed)
        #expect(project.tracks[0].name == "Double")

        let empty = project.renameTrack(track, to: "")
        #expect(!empty)
        let onlySpaces = project.renameTrack(track, to: "   \t ")
        #expect(!onlySpaces)
        #expect(project.tracks[0].name == "Double")

        // The name it already has, and a track the project does not have, change nothing.
        let before = project
        let sameName = project.renameTrack(track, to: " Double")
        #expect(!sameName)
        let unknownTrack = project.renameTrack(UUID(), to: "Ad-libs")
        #expect(!unknownTrack)
        #expect(project == before)
    }

    // MARK: Mute

    @Test func aMutedTrackIsLeftOutOfWhatIsHeard() {
        var project = emptySong()
        project.addTrack()
        record(1, in: &project, track: 0)
        record(1, in: &project, track: 1)
        let second = project.tracks[1].id
        #expect(project.clipPlaybackPlan(from: 0, voices: .none).count == 2)

        let muted = project.setTrackMuted(second, true)
        #expect(muted)
        #expect(project.tracks.map(\.muted) == [false, true])
        #expect(project.clipPlaybackPlan(from: 0, voices: .none).map(\.recordingID) == [project.recordings[0].id])

        // Muting it again changes nothing, and neither does a track the project does not have.
        let mutedAgain = project.setTrackMuted(second, true)
        #expect(!mutedAgain)
        let unknownTrack = project.setTrackMuted(UUID(), true)
        #expect(!unknownTrack)

        let unmuted = project.setTrackMuted(second, false)
        #expect(unmuted)
        #expect(project.clipPlaybackPlan(from: 0, voices: .none).count == 2)
    }

    // MARK: Duplicate

    @Test func aDuplicateSitsRightBelowWithTheSameSettingsAndNoClips() throws {
        var project = emptySong()
        project.addTrack()
        project.tracks[0].name = "Lead"
        project.tracks[0].muted = true
        record(2, in: &project, track: 0)
        let original = project.tracks[0]

        let made = project.duplicateTrack(original.id, withClips: false)
        let copy = try #require(made)

        #expect(names(of: project) == ["Lead", "Lead copy", "Track 2"])
        #expect(project.tracks[0] == original)
        #expect(project.tracks[1] == Track(id: copy, name: "Lead copy", muted: true))
        #expect(copy != original.id)
    }

    @Test func aDuplicateWithClipsHasNewClipsThatPlayTheSameSamples() throws {
        var project = emptySong()
        project.tracks[0].name = "Double"
        record(2, 1.5, in: &project)
        record(6, in: &project)
        // A clip cut in two parts, moved, renamed, turned down and muted: all of that is copied too.
        project.tracks[0].clips[1].segments = [
            Segment(recordingID: project.recordings[1].id, inSample: 0, outSample: 12_000, offsetSamples: 480),
            Segment(recordingID: project.recordings[1].id, inSample: 24_000, outSample: 48_000, offsetSamples: 480),
        ]
        project.tracks[0].clips[1].name = "Hook"
        project.tracks[0].clips[1].gainDb = -3
        let original = project.tracks[0]
        let recordings = project.recordings

        let made = project.duplicateTrack(original.id, withClips: true)
        let copy = try #require(made)

        let copied = try #require(project.track(copy))
        #expect(project.tracks.map(\.id) == [original.id, copy])
        #expect(copied.name == "Double copy")
        #expect(project.tracks[0] == original)
        #expect(project.recordings == recordings)

        // New ids, none shared with the originals or with each other.
        #expect(copied.clips.count == 2)
        #expect(clipIDs(of: project).count == 4)
        // Everything else about each clip is the same, except that the copies are lines of their own.
        for (old, new) in zip(original.clips, copied.clips) {
            var expected = old
            expected.id = new.id
            expected.line = new.line
            #expect(new == expected)
            #expect(new.line != old.line)
        }

        // Heard alone, the copy plays exactly the samples the original plays alone.
        var onlyOriginal = project
        onlyOriginal.setTrackMuted(copy, true)
        var onlyCopy = project
        onlyCopy.setTrackMuted(original.id, true)
        let plan = onlyOriginal.clipPlaybackPlan(from: 0, voices: .none)
        #expect(plan.count == 3)
        #expect(onlyCopy.clipPlaybackPlan(from: 0, voices: .none) == plan)
    }

    @Test func duplicatingATrackTheProjectDoesNotHaveChangesNothing() {
        var project = emptySong()
        let before = project
        let copy = project.duplicateTrack(UUID(), withClips: true)
        #expect(copy == nil)
        #expect(project == before)
    }

    // MARK: Merge Into

    @Test func aMergeMovesEveryClipInSongOrderAndRemovesTheSource() {
        var project = emptySong()
        project.addTrack()
        project.addTrack()
        project.tracks[1].name = "Lead 2"
        project.tracks[1].muted = true
        // Recorded out of order, on both tracks.
        let c8 = record(8, in: &project, track: 1)
        let c2 = record(2, in: &project, track: 0)
        let c5 = record(5, in: &project, track: 0)
        let c0 = record(0.5, in: &project, track: 1)
        let c11 = record(11, in: &project, track: 0)
        let source = project.tracks[0].id
        let target = project.tracks[1].id
        let third = project.tracks[2]

        let merged = project.mergeTrack(source, into: target, voices: .none)
        #expect(merged)

        #expect(project.tracks.map(\.id) == [target, third.id])
        #expect(project.tracks[0].clips.map(\.id) == [c0, c2, c5, c8, c11])
        // The target keeps its own name and settings.
        #expect(project.tracks[0].name == "Lead 2")
        #expect(project.tracks[0].muted)
        #expect(project.tracks[1] == third)
        #expect(project.unusedRecordingIDs().isEmpty)
    }

    @Test func aMergeIsRefusedIntoTheSameTrackOrWithATrackTheProjectDoesNotHave() {
        var project = emptySong()
        project.addTrack()
        record(1, in: &project, track: 0)
        record(1, in: &project, track: 1)
        let first = project.tracks[0].id
        let before = project

        let intoItself = project.mergeTrack(first, into: first, voices: .none)
        #expect(!intoItself)
        let unknownSource = project.mergeTrack(UUID(), into: first, voices: .none)
        #expect(!unknownSource)
        let unknownTarget = project.mergeTrack(first, into: UUID(), voices: .none)
        #expect(!unknownTarget)
        #expect(project == before)
    }

    @Test @MainActor func clipsThatStartAtTheSamePlaceAfterAMergeBecomeTakesAndUndoPutsBothTracksBack() {
        var project = emptySong()
        project.addTrack()
        // The same line on both tracks, starting 20 ms apart, and one clip elsewhere on each.
        let line1 = record(4.0, 2, in: &project, track: 0)
        let alone1 = record(10, in: &project, track: 0)
        let line2 = record(4.02, 2, in: &project, track: 1)
        let alone2 = record(14, in: &project, track: 1)
        let source = project.tracks[1].id
        let target = project.tracks[0].id
        let store = ProjectStore(project: project)
        store.undoManager.groupsByEvent = false
        let before = store.project

        store.edit("Merge Track") { $0.mergeTrack(source, into: target, voices: .none) }

        let merged = store.project
        #expect(merged.tracks.count == 1)
        #expect(merged.tracks[0].clips.map(\.id) == [line1, line2, alone1, alone2])
        // Both clips of the line are kept, as takes of each other, and only the one that came is heard.
        #expect(merged.takes(of: line1).map(\.id) == [line1, line2])
        #expect(merged.tracks[0].clips.filter(\.isActiveTake).map(\.id) == [line2, alone1, alone2])
        #expect(merged.clipPlaybackPlan(from: 0, voices: .none).count == 3)

        store.undo()
        #expect(store.project == before)
        #expect(store.project.clipPlaybackPlan(from: 0, voices: .none).count == 4)
    }

    // MARK: Delete

    @Test func deletingATrackRemovesItsClipsAndLeavesTheirRecordingsUnused() {
        var project = emptySong()
        project.addTrack()
        project.addTrack()
        record(1, in: &project, track: 0)
        record(2, in: &project, track: 1)
        record(3, in: &project, track: 1)
        record(4, in: &project, track: 2)
        // A clip on the first track that plays a recording of the second track too: that recording stays in use.
        let shared = project.recordings[1]
        project.tracks[0].clips.append(
            Clip(segments: [Segment(recordingID: shared.id, inSample: 0, outSample: 24_000, offsetSamples: 480_000)])
        )
        let ids = project.tracks.map(\.id)
        let onlyOnSecond = project.recordings[2].id
        #expect(project.unusedRecordingIDs().isEmpty)

        // The track that was below is the one to select next.
        let afterMiddle = project.deleteTrack(ids[1])
        #expect(afterMiddle == ids[2])

        #expect(project.tracks.map(\.id) == [ids[0], ids[2]])
        #expect(project.tracks.flatMap(\.clips).count == 3)
        #expect(project.recordings.count == 4)
        #expect(project.unusedRecordingIDs() == [onlyOnSecond])

        // Deleting the bottom track leaves the one above it to select.
        let afterBottom = project.deleteTrack(ids[2])
        #expect(afterBottom == ids[0])
        #expect(project.tracks.map(\.id) == [ids[0]])
    }

    @Test func deletingTheLastTrackIsRefused() {
        var project = emptySong()
        record(1, in: &project)
        let before = project

        let onlyTrack = project.deleteTrack(project.tracks[0].id)
        #expect(onlyTrack == nil)
        #expect(project == before)

        // And so is a track the project does not have.
        project.addTrack()
        let two = project
        let unknownTrack = project.deleteTrack(UUID())
        #expect(unknownTrack == nil)
        #expect(project == two)
    }

    // MARK: Reorder

    @Test func movingTheThirdTrackToTheTopKeepsEveryClip() {
        var project = emptySong()
        project.addTrack()
        project.addTrack()
        project.addTrack()
        record(1, in: &project, track: 0)
        record(2, in: &project, track: 1)
        record(3, in: &project, track: 2)
        record(4, in: &project, track: 2)
        record(5, in: &project, track: 3)
        let before = project.tracks

        let moved = project.moveTrack(before[2].id, toIndex: 0)
        #expect(moved)

        #expect(names(of: project) == ["Track 3", "Track 1", "Track 2", "Track 4"])
        // Every track is as it was, clips included. Only the order changed.
        #expect(project.tracks == [before[2], before[0], before[1], before[3]])
        #expect(project.tracks[0].clips.count == 2)
    }

    @Test func aTrackCanBeMovedDownAndAPlacePastTheEndIsTheEnd() {
        var project = emptySong()
        project.addTrack()
        project.addTrack()
        let ids = project.tracks.map(\.id)

        let movedDown = project.moveTrack(ids[0], toIndex: 1)
        #expect(movedDown)
        #expect(project.tracks.map(\.id) == [ids[1], ids[0], ids[2]])

        let pastTheEnd = project.moveTrack(ids[1], toIndex: 99)
        #expect(pastTheEnd)
        #expect(project.tracks.map(\.id) == [ids[0], ids[2], ids[1]])

        let beforeTheStart = project.moveTrack(ids[1], toIndex: -5)
        #expect(beforeTheStart)
        #expect(project.tracks.map(\.id) == [ids[1], ids[0], ids[2]])
    }

    @Test func movingATrackToWhereItIsChangesNothing() {
        var project = emptySong()
        project.addTrack()
        let ids = project.tracks.map(\.id)
        let before = project

        let samePlace = project.moveTrack(ids[1], toIndex: 1)
        #expect(!samePlace)
        let samePlacePastTheEnd = project.moveTrack(ids[1], toIndex: 7)
        #expect(!samePlacePastTheEnd)
        let unknownTrack = project.moveTrack(UUID(), toIndex: 0)
        #expect(!unknownTrack)
        #expect(project == before)
    }
}

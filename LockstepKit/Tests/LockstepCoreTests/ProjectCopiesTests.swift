import Foundation
import Testing
@testable import LockstepCore

/// A twenty-second song with three empty tracks.
private func song() -> Project {
    var project = Project(songLengthSamples: 960_000)
    project.addTrack()
    project.addTrack()
    return project
}

/// Records a clip the way the app does: a new recording whose clip begins `start` seconds into the song and is
/// `seconds` long. Returns the id of the clip.
@discardableResult
private func record(_ start: Double, _ seconds: Double = 1, in project: inout Project, track: Int = 0) -> UUID {
    let recording = Recording(lengthSamples: Int((seconds * Lockstep.sampleRate).rounded()), rawStart: start)
    return project.addRecording(recording, samples: 0..<recording.lengthSamples, asClipOn: project.tracks[track].id, voices: .none)!
}

/// The samples of the song every clip of a track covers, in the order the track holds them.
private func spans(in project: Project, track: Int = 0) -> [Range<Int>] {
    project.tracks[track].clips.compactMap { project.songSpan(of: $0) }
}

/// A number of seconds as a sample of the song.
private func s(_ seconds: Double) -> Int {
    Int((seconds * Lockstep.sampleRate).rounded())
}

/// Max's rules of 14 November 2026 for Copy, Paste and a drag with Option held.
@Suite("Copies of clips")
@MainActor
struct ProjectCopiesTests {
    /// Makes a change as one edit, checks that one Undo puts the project back exactly as it was, and gives back
    /// the project after the change.
    private func edited(_ project: Project, _ change: (inout Project) -> Void) -> Project {
        let store = ProjectStore(project: project)
        let before = store.project
        store.edit("Paste") { change(&$0) }
        let changed = store.project
        #expect(changed != before)
        store.undo()
        #expect(store.project == before)
        return changed
    }

    @Test func onlyTheShownTakeIsCopiedWithEverythingItHas() throws {
        var project = song()
        let first = record(2, in: &project)
        let second = record(2, in: &project)
        #expect(project.takes(of: first).map(\.id) == [first, second])
        project.setActiveTake(first)
        project.renameClip(first, to: "Verse")
        for index in project.tracks[0].clips.indices where project.tracks[0].clips[index].id == first {
            project.tracks[0].clips[index].gainDb = 3
            project.tracks[0].clips[index].tighten = .all
            project.tracks[0].clips[index].strength = 0.5
            project.tracks[0].clips[index].stretch = true
        }

        let copies = project.copyClips([second])
        #expect(copies.items.count == 1)
        let copied = try #require(copies.items.first?.clip)
        #expect(copied.id == first)
        #expect(copied.name == "Verse")
        #expect(copied.gainDb == 3)
        #expect(copied.tighten == .all)
        #expect(copied.strength == 0.5)
        #expect(copied.stretch)
    }

    @Test func pasteIsANewLineAtThePlayheadThatPlaysTheSameRecording() throws {
        var project = song()
        let clip = record(2, in: &project)
        project.renameClip(clip, to: "Hook")
        let copies = project.copyClips([clip])
        var made: [Clip] = []
        let changed = edited(project) {
            made = $0.paste(copies, onTrack: $0.tracks[1].id, atSample: s(5), voices: .none)
        }

        let copy = try #require(made.first)
        #expect(made.count == 1)
        #expect(copy.id != clip)
        #expect(changed.clip(copy.id)?.line != changed.clip(clip)?.line)
        #expect(changed.clip(copy.id)?.isActiveTake == true)
        #expect(changed.clip(copy.id)?.name == "Hook")
        #expect(changed.clip(copy.id)?.recordPlace == nil)
        #expect(spans(in: changed, track: 1) == [s(5)..<s(6)])
        // The clip it was copied from is where it was, and no recording was added or changed.
        #expect(spans(in: changed, track: 0) == [s(2)..<s(3)])
        #expect(changed.recordings == project.recordings)
        #expect(changed.clip(copy.id)?.segments.map(\.recordingID) == changed.clip(clip)?.segments.map(\.recordingID))
    }

    @Test func pastedClipsKeepTheirDistancesInTimeAndInTracks() {
        var project = song()
        let a = record(2, in: &project, track: 1)
        let b = record(4, 0.5, in: &project, track: 1)
        let c = record(3, in: &project, track: 2)
        let copies = project.copyClips([a, b, c])
        #expect(copies.items.map(\.trackStep) == [0, 0, 1])

        // On the first track: the copies from the second and third track land on the first and second.
        let changed = edited(project) { $0.paste(copies, onTrack: $0.tracks[0].id, atSample: s(10), voices: .none) }
        #expect(spans(in: changed, track: 0) == [s(10)..<s(11), s(12)..<s(12.5)])
        #expect(spans(in: changed, track: 1) == [s(2)..<s(3), s(4)..<s(4.5), s(11)..<s(12)])

        // On the last track: the copy from the third track would land below it, and lands on it.
        let atBottom = edited(project) { $0.paste(copies, onTrack: $0.tracks[2].id, atSample: s(10), voices: .none) }
        #expect(spans(in: atBottom, track: 2) == [s(3)..<s(4), s(10)..<s(11), s(12)..<s(12.5), s(11)..<s(12)])
    }

    @Test func aPastedClipWinsOverWhatItCovers() {
        var project = song()
        let long = record(4, 4, in: &project)
        let nearlyCovered = record(9, 1, in: &project)
        let source = record(14, 1, in: &project)
        let copies = project.copyClips([source])

        // In the middle of the long clip, which becomes two clips.
        let middle = edited(project) { $0.paste(copies, onTrack: $0.tracks[0].id, atSample: s(5), voices: .none) }
        #expect(spans(in: middle) == [s(4)..<s(5), s(6)..<s(8), s(9)..<s(10), s(14)..<s(15), s(5)..<s(6)])
        #expect(middle.clip(long) != nil)

        // Over all but 50 ms of the next clip, which leaves no rest shorter than 100 ms.
        let over = edited(project) { $0.paste(copies, onTrack: $0.tracks[0].id, atSample: s(8.95), voices: .none) }
        #expect(over.clip(nearlyCovered) == nil)
        #expect(spans(in: over) == [s(4)..<s(8), s(14)..<s(15), s(8.95)..<s(9.95)])
    }

    @Test func aClipPastedOnTheStartOfAnotherIsNoTakeOfIt() throws {
        var project = song()
        let first = record(2, 2, in: &project)
        let source = record(10, 1, in: &project)
        let copies = project.copyClips([source])
        var made: [Clip] = []
        let changed = edited(project) { made = $0.paste(copies, onTrack: $0.tracks[0].id, atSample: s(2), voices: .none) }
        let copy = try #require(made.first)
        #expect(changed.takeCount(of: copy.id) == 1)
        #expect(changed.clip(first) != nil)
        #expect(spans(in: changed) == [s(3)..<s(4), s(10)..<s(11), s(2)..<s(3)])
    }

    @Test func nothingIsPastedOutsideWhatIsLeftOfTheSong() {
        var project = song()
        project.songPlace.cutEndSamples = s(2)
        let a = record(2, in: &project)
        let b = record(4, in: &project)
        let copies = project.copyClips([a, b])

        // From 16.5 s the copies would end at 19.5 s, past the cut at 18 s, so both move back together.
        let late = edited(project) { $0.paste(copies, onTrack: $0.tracks[1].id, atSample: s(16.5), voices: .none) }
        #expect(spans(in: late, track: 1) == [s(15)..<s(16), s(17)..<s(18)])
    }

    @Test func copiesOfRecordingsTheProjectDoesNotHaveAreNotPasted() {
        var project = song()
        let clip = record(2, in: &project)
        let copies = project.copyClips([clip])
        var other = song()
        #expect(project.canPaste(copies))
        #expect(!other.canPaste(copies))
        #expect(other.paste(copies, onTrack: other.tracks[0].id, atSample: s(5), voices: .none).isEmpty)
        #expect(!project.canPaste(CopiedClips()))
    }

    @Test func aDragWithOptionLeavesTheClipsAndPutsCopiesWhereTheyWouldHaveGone() throws {
        var project = song()
        let first = record(2, 2, in: &project)
        let second = record(2, 2, in: &project)
        project.setActiveTake(first)
        let other = record(6, in: &project, track: 1)
        let copyID = UUID()
        var made: [Clip] = []
        let changed = edited(project) {
            made = $0.duplicateClips([first, other], by: ClipMove(samples: s(10), trackSteps: 1), newIDs: [first: copyID], voices: .none)
        }

        #expect(made.map(\.id).first == copyID)
        // The originals, with the take that waits, are where they were.
        #expect(changed.takes(of: first).map(\.id) == [first, second])
        #expect(spans(in: changed, track: 0) == [s(2)..<s(4), s(2)..<s(4)])
        // Only the shown take was copied, ten seconds on and one track down.
        #expect(spans(in: changed, track: 1) == [s(6)..<s(7), s(12)..<s(14)])
        #expect(spans(in: changed, track: 2) == [s(16)..<s(17)])
        #expect(changed.takeCount(of: copyID) == 1)
    }

    @Test func aCopyDraggedOverItsOwnClipWinsOverIt() {
        var project = song()
        let clip = record(2, 2, in: &project)
        let changed = edited(project) { $0.duplicateClips([clip], by: ClipMove(samples: s(1)), voices: .none) }
        #expect(spans(in: changed) == [s(2)..<s(3), s(3)..<s(5)])
        #expect(project.duplicateClips([clip], by: ClipMove(), voices: .none).isEmpty)
    }
}

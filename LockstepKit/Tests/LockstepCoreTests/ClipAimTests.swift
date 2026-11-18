import Foundation
import Testing
@testable import LockstepCore

/// What a clip's correction aims at: the beat, or another track. How the choice is saved and set, and when
/// an aim at a track counts as the beat after all.
@Suite("A clip's aim")
struct ClipAimTests {
    /// A twenty-second song with two tracks, "Lead" and "Double".
    private func song() -> Project {
        Project(songLengthSamples: 960_000, tracks: [Track(name: "Lead"), Track(name: "Double")])
    }

    /// Records a clip the way the app does: a new recording that begins `start` seconds into the song and
    /// is `seconds` long, all of it as the clip, on the track at `track`. Returns the id of the clip.
    @discardableResult
    private func record(_ start: Double, _ seconds: Double = 1, on track: Int, in project: inout Project) -> UUID {
        let recording = Recording(lengthSamples: Int((seconds * Lockstep.sampleRate).rounded()), rawStart: start)
        return project.addRecording(
            recording,
            samples: 0..<recording.lengthSamples,
            asClipOn: project.tracks[track].id,
            aim: RecordAim(place: start), voices: .none
        )!
    }

    // MARK: Saved

    @Test func aClipThatAimsAtTheBeatIsWrittenAsItAlwaysWas() throws {
        var project = song()
        record(2, on: 1, in: &project)
        let text = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        #expect(!text.contains("aimTrack"))
        let read = try JSONDecoder().decode(Project.self, from: Data(text.utf8))
        #expect(read.tracks[1].clips[0].aimTrack == nil)
    }

    @Test func anAimAtATrackIsSavedWithTheClip() throws {
        var project = song()
        let double = record(2, on: 1, in: &project)
        let lead = project.tracks[0].id
        project.setClips([double], aimTrack: lead)
        let saved = try JSONEncoder().encode(project)
        #expect(String(decoding: saved, as: UTF8.self).contains("aimTrack"))
        let read = try JSONDecoder().decode(Project.self, from: saved)
        #expect(read == project)
        #expect(read.clip(double)?.aimTrack == lead)
    }

    // MARK: Set

    @Test func theAimIsSetForTheClipsAndTheTakesThatWaitBehindThem() throws {
        var project = song()
        let first = record(2, on: 1, in: &project)
        let second = record(2, on: 1, in: &project)
        let other = record(6, on: 1, in: &project)
        #expect(project.takes(of: second).count == 2)
        let lead = project.tracks[0].id

        let changed = project.setClips([second], aimTrack: lead)
        #expect(changed)
        #expect(project.clip(first)?.aimTrack == lead)
        #expect(project.clip(second)?.aimTrack == lead)
        #expect(project.clip(other)?.aimTrack == nil)
        // Nothing changes the second time, and the answer says so.
        let again = project.setClips([second], aimTrack: lead)
        #expect(!again)
        // Back to the beat.
        let back = project.setClips([first], aimTrack: nil)
        #expect(back)
        #expect(project.clip(second)?.aimTrack == nil)
    }

    @Test func aNewTakeAimsWhereItsLineAims() throws {
        var project = song()
        let first = record(2, on: 1, in: &project)
        let lead = project.tracks[0].id
        project.setClips([first], aimTrack: lead)
        let second = record(2, on: 1, in: &project)
        #expect(project.clip(second)?.aimTrack == lead)
        // A clip on a line of its own aims at the beat.
        let other = record(6, on: 1, in: &project)
        #expect(project.clip(other)?.aimTrack == nil)
    }

    // MARK: What an aim counts as

    @Test func anAimAtAnotherTrackCounts() throws {
        var project = song()
        let double = record(2, on: 1, in: &project)
        let lead = project.tracks[0].id
        project.setClips([double], aimTrack: lead)
        #expect(project.aim(of: try #require(project.clip(double))) == lead)
        // A clip that aims at the beat aims at the beat.
        let plain = record(6, on: 1, in: &project)
        #expect(project.aim(of: try #require(project.clip(plain))) == nil)
    }

    @Test func anAimAtATrackThatIsGoneIsTheBeatAndComesBackWithTheTrack() throws {
        var project = song()
        let double = record(2, on: 1, in: &project)
        let lead = project.tracks[0]
        project.setClips([double], aimTrack: lead.id)
        let whole = project
        project.tracks.removeFirst()
        let clip = try #require(project.clip(double))
        #expect(project.aim(of: clip) == nil)
        // The clip still says where it aimed, so an undo that brings the track back brings the aim back.
        #expect(clip.aimTrack == lead.id)
        #expect(whole.aim(of: clip) == lead.id)
    }

    @Test func anAimAtTheClipsOwnTrackIsTheBeat() throws {
        var project = song()
        let double = record(2, on: 1, in: &project)
        project.setClips([double], aimTrack: project.tracks[1].id)
        #expect(project.aim(of: try #require(project.clip(double))) == nil)
    }

    @Test func twoClipsThatAimAtEachOtherBothAimAtTheBeat() throws {
        var project = song()
        let lead = record(2, 2, on: 0, in: &project)
        let double = record(2.5, on: 1, in: &project)
        project.setClips([double], aimTrack: project.tracks[0].id)
        project.setClips([lead], aimTrack: project.tracks[1].id)
        #expect(project.aim(of: try #require(project.clip(double))) == nil)
        #expect(project.aim(of: try #require(project.clip(lead))) == nil)
    }

    @Test func aClipElsewhereOnTheLeadsTrackThatAimsBackIsNotInTheWay() throws {
        var project = song()
        let lead = record(2, 2, on: 0, in: &project)
        let later = record(10, on: 0, in: &project)
        let double = record(2.5, on: 1, in: &project)
        project.setClips([double], aimTrack: project.tracks[0].id)
        // A clip of the lead's track that plays eight seconds later aims at the double's track.
        project.setClips([later], aimTrack: project.tracks[1].id)
        #expect(project.aim(of: try #require(project.clip(double))) == project.tracks[0].id)
        #expect(project.clip(lead)?.aimTrack == nil)
        // That clip has nothing over it on the double's track, so its own aim counts too.
        #expect(project.aim(of: try #require(project.clip(later))) == project.tracks[1].id)
    }

    @Test func aClipWithinReachCountsAsOverIt() throws {
        var project = song()
        // The lead's clip ends at 3 s, and the double's starts 50 ms after that.
        let lead = record(2, on: 0, in: &project)
        let double = record(3.05, on: 1, in: &project)
        project.setClips([double], aimTrack: project.tracks[0].id)
        project.setClips([lead], aimTrack: project.tracks[1].id)
        let clip = try #require(project.clip(double))
        #expect(project.aim(of: clip) == project.tracks[0].id)
        // With the reach of the correction, which looks 120 ms past a clip's edges, they aim at each other.
        #expect(project.aim(of: clip, reach: 0.12) == nil)
        #expect(project.aimedClips(of: clip, reach: 0.12).map(\.id) == [lead])
        #expect(project.aimedClips(of: clip).isEmpty)
    }

    @Test func aRingOfThreeTracksIsTheBeatAllRound() throws {
        var project = song()
        project.tracks.append(Track(name: "Third"))
        let first = record(2, on: 0, in: &project)
        let second = record(2, on: 1, in: &project)
        let third = record(2, on: 2, in: &project)
        project.setClips([first], aimTrack: project.tracks[1].id)
        project.setClips([second], aimTrack: project.tracks[2].id)
        project.setClips([third], aimTrack: project.tracks[0].id)
        for id in [first, second, third] {
            #expect(project.aim(of: try #require(project.clip(id))) == nil)
        }
        // A chain that ends is fine: a harmony on the double, the double on the lead.
        project.setClips([third], aimTrack: nil)
        #expect(project.aim(of: try #require(project.clip(first))) == project.tracks[1].id)
        #expect(project.aim(of: try #require(project.clip(second))) == project.tracks[2].id)
    }

    @Test func aWaitingTakeOfTheLeadDoesNotCount() throws {
        var project = song()
        let old = record(2, on: 0, in: &project)
        let double = record(2, on: 1, in: &project)
        project.setClips([double], aimTrack: project.tracks[0].id)
        // The lead's line gets a new take, and only the take that waits is made to aim back.
        let shown = record(2, on: 0, in: &project)
        project.setActiveTake(shown)
        project.tracks[0].clips[project.tracks[0].clips.firstIndex { $0.id == old }!].aimTrack = project.tracks[1].id
        #expect(project.clip(old)?.isActiveTake == false)
        let clip = try #require(project.clip(double))
        #expect(project.aimedClips(of: clip).map(\.id) == [shown])
        #expect(project.aim(of: clip) == project.tracks[0].id)
    }
}

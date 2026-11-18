import Foundation
import Testing
@testable import LockstepCore

/// Records a clip the way the app does: a new recording that begins `start` seconds into the song and is
/// `seconds` long, with all of it as the clip, on the track at `track`. Returns the id of the clip.
@discardableResult
private func record(_ start: Double, _ seconds: Double = 1, in project: inout Project, track: Int = 0) -> UUID {
    let recording = Recording(lengthSamples: Int((seconds * Lockstep.sampleRate).rounded()), rawStart: start)
    return project.addRecording(recording, samples: 0..<recording.lengthSamples, asClipOn: project.tracks[track].id, voices: .none)!
}

/// Which clip W, A, S and D take the playhead to.
@Suite("ClipJumps")
struct ClipJumpsTests {
    /// A twenty-second song with three tracks. The top track has clips at 2 to 3, 5 to 6 and 9 to 10 seconds,
    /// the middle one at 4 to 7 and 12 to 13 seconds, and the bottom one is empty.
    struct Song {
        var project = Project(songLengthSamples: 960_000)
        var top: [UUID] = []
        var middle: [UUID] = []

        init() {
            project.addTrack()
            project.addTrack()
            top = [record(2, in: &project), record(5, in: &project), record(9, in: &project)]
            middle = [record(4, 3, in: &project, track: 1), record(12, in: &project, track: 1)]
        }

        func jump(_ jump: ClipJump, from seconds: Double, track: Int = 0, reach: Double? = nil) -> ClipJumpLanding? {
            let selected = project.tracks[track].id
            guard let reach else { return project.clipJump(jump, from: seconds, selectedTrack: selected) }
            return project.clipJump(jump, from: seconds, selectedTrack: selected, reach: reach)
        }

        func landing(_ clip: UUID, at place: Double, track: Int) -> ClipJumpLanding {
            ClipJumpLanding(trackID: project.tracks[track].id, clip: .init(id: clip, place: place))
        }
    }

    // MARK: - Before and after

    @Test func previousGoesToTheLatestClipStartBeforeThePlayhead() {
        let song = Song()
        // Between two clips: the start of the one before.
        #expect(song.jump(.previous, from: 4) == song.landing(song.top[0], at: 2, track: 0))
        #expect(song.jump(.previous, from: 15) == song.landing(song.top[2], at: 9, track: 0))
    }

    @Test func previousInsideAClipGoesToTheStartOfThatClip() {
        let song = Song()
        #expect(song.jump(.previous, from: 5.5) == song.landing(song.top[1], at: 5, track: 0))
    }

    @Test func previousOnAClipsStartGoesToTheClipBefore() {
        let song = Song()
        #expect(song.jump(.previous, from: 5) == song.landing(song.top[0], at: 2, track: 0))
        // The player reports the place to the nearest sample, a hair before or after it.
        #expect(song.jump(.previous, from: 5 + 0.5 / 48_000) == song.landing(song.top[0], at: 2, track: 0))
        #expect(song.jump(.previous, from: 5 - 0.5 / 48_000) == song.landing(song.top[0], at: 2, track: 0))
    }

    @Test func previousWithALongerReachCountsAPlayheadJustPastAStartAsStandingOnIt() {
        let song = Song()
        // While the song plays, the playhead has left the start it was sent to.
        #expect(song.jump(.previous, from: 5.3, reach: 1) == song.landing(song.top[0], at: 2, track: 0))
        #expect(song.jump(.previous, from: 6.5, reach: 1) == song.landing(song.top[1], at: 5, track: 0))
    }

    @Test func nextGoesToTheEarliestClipStartAfterThePlayhead() {
        let song = Song()
        #expect(song.jump(.next, from: 0) == song.landing(song.top[0], at: 2, track: 0))
        // Inside a clip, and on a clip's start: the clip after.
        #expect(song.jump(.next, from: 2.5) == song.landing(song.top[1], at: 5, track: 0))
        #expect(song.jump(.next, from: 5) == song.landing(song.top[2], at: 9, track: 0))
        #expect(song.jump(.next, from: 5 - 0.5 / 48_000) == song.landing(song.top[2], at: 9, track: 0))
    }

    @Test func withNoClipInThatDirectionNothingHappens() {
        let song = Song()
        #expect(song.jump(.previous, from: 1) == nil)
        #expect(song.jump(.previous, from: 2) == nil)
        #expect(song.jump(.next, from: 9) == nil)
        #expect(song.jump(.next, from: 15) == nil)
        // A track without clips.
        #expect(song.jump(.previous, from: 10, track: 2) == nil)
        #expect(song.jump(.next, from: 10, track: 2) == nil)
        // A track the project does not have.
        #expect(song.project.clipJump(.next, from: 0, selectedTrack: UUID()) == nil)
    }

    // MARK: - Above and below

    @Test func belowGoesToTheClipThePlayheadStandsInside() {
        let song = Song()
        // 6.5 is inside the middle track's clip from 4 to 7. Its start is 2.5 away, further than anything
        // nearest would need, and it still wins.
        #expect(song.jump(.below, from: 6.5) == song.landing(song.middle[0], at: 4, track: 1))
    }

    @Test func belowGoesToTheClipWhoseStartIsNearestWhenThePlayheadIsInsideNone() {
        let song = Song()
        #expect(song.jump(.below, from: 1) == song.landing(song.middle[0], at: 4, track: 1))
        // 9 is two seconds past the end of the first clip: its start is 5 away, the next one's 3.
        #expect(song.jump(.below, from: 9) == song.landing(song.middle[1], at: 12, track: 1))
        #expect(song.jump(.below, from: 19) == song.landing(song.middle[1], at: 12, track: 1))
    }

    @Test func aboveDoesTheSameOnTheTrackAbove() {
        let song = Song()
        #expect(song.jump(.above, from: 5.5, track: 1) == song.landing(song.top[1], at: 5, track: 0))
        #expect(song.jump(.above, from: 8, track: 1) == song.landing(song.top[2], at: 9, track: 0))
        #expect(song.jump(.above, from: 0, track: 1) == song.landing(song.top[0], at: 2, track: 0))
    }

    @Test func aTrackWithoutClipsIsStillSelectedAndThePlayheadStays() {
        let song = Song()
        let landing = song.jump(.below, from: 6, track: 1)
        #expect(landing == ClipJumpLanding(trackID: song.project.tracks[2].id, clip: nil))
    }

    @Test func atTheTopAndBottomTrackNothingHappens() {
        let song = Song()
        #expect(song.jump(.above, from: 6, track: 0) == nil)
        #expect(song.jump(.below, from: 6, track: 2) == nil)
    }

    // MARK: - Which clips count

    @Test func onlyTheTakeThatIsShownCounts() {
        var project = Project(songLengthSamples: 960_000)
        project.addTrack()
        // Two takes of one line: the second, whose voice started a little later, is the one shown.
        let waiting = record(2.0, in: &project)
        let shown = record(2.2, in: &project)
        project.tracks[0].clips[1].line = project.clip(waiting)!.line
        let later = record(6, in: &project)
        project.normalizeTakes()
        let top = project.tracks[0].id
        let bottom = project.tracks[1].id

        #expect(project.clipJump(.next, from: 0, selectedTrack: top)?.clip == .init(id: shown, place: 2.2))
        // From the shown take's start there is no waiting take to land on at 2.0.
        #expect(project.clipJump(.previous, from: 2.2, selectedTrack: top) == nil)
        #expect(project.clipJump(.previous, from: 6, selectedTrack: top)?.clip == .init(id: shown, place: 2.2))
        #expect(project.clipJump(.above, from: 2.05, selectedTrack: bottom)?.clip == .init(id: shown, place: 2.2))
        #expect(project.clipJump(.above, from: 5, selectedTrack: bottom)?.clip == .init(id: later, place: 6))
    }

    @Test func aClipWhollyInACutAwayPartOfTheSongDoesNotCount() {
        var song = Song()
        // The song is cut to 5.5 ... 11 seconds: the clip at 2 to 3 is gone, the one at 5 to 6 reaches in, and
        // the middle track's clip at 12 to 13 is gone.
        let length = song.project.songLengthSamples
        song.project.songPlace = song.project.songPlace
            .cuttingStart(at: Int(5.5 * Lockstep.sampleRate), ofLength: length)
            .cuttingEnd(at: Int(11 * Lockstep.sampleRate), ofLength: length)

        // A clip that begins in the cut-away beginning counts from where the kept song begins.
        #expect(song.jump(.previous, from: 8) == song.landing(song.top[1], at: 5.5, track: 0))
        #expect(song.jump(.previous, from: 5.5) == nil)
        #expect(song.jump(.next, from: 5.5) == song.landing(song.top[2], at: 9, track: 0))
        // On the middle track only the clip from 4 to 7 is left.
        #expect(song.jump(.below, from: 10.5) == song.landing(song.middle[0], at: 5.5, track: 1))
        #expect(song.jump(.next, from: 6, track: 1) == nil)
    }
}

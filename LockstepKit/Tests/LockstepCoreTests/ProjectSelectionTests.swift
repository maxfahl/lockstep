import Foundation
import Testing
@testable import LockstepCore

@Suite("Selecting with a rectangle")
struct ProjectSelectionTests {
    /// Four tracks, with their clips given as the song seconds they run from and to:
    ///
    ///     Track 1   a 2–4      b 6–8
    ///     Track 2   c 3–5      d 10–12   (and e 3–5, a take of c's line that waits behind it)
    ///     Track 3   f 7–9
    ///     Track 4   g 1–2
    private struct Song {
        var project = Project(tracks: [])
        var tracks: [UUID] = []
        var clips: [String: UUID] = [:]

        init() {
            addTrack(["a": 2...4, "b": 6...8])
            addTrack(["c": 3...5, "d": 10...12])
            addTrack(["f": 7...9])
            addTrack(["g": 1...2])
            // A second take of the line of c. It is not drawn, because c is the one that is heard.
            let line = project.tracks[1].clips.first { $0.id == clips["c"] }!.line
            var waiting = clip(3...5)
            waiting.isActiveTake = false
            waiting.line = line
            project.tracks[1].clips.append(waiting)
            clips["e"] = waiting.id
        }

        private mutating func addTrack(_ named: [String: ClosedRange<Double>]) {
            var track = Track(name: "Track \(project.tracks.count + 1)")
            for (name, range) in named.sorted(by: { $0.key < $1.key }) {
                let clip = clip(range)
                clips[name] = clip.id
                track.clips.append(clip)
            }
            tracks.append(track.id)
            project.tracks.append(track)
        }

        /// A clip over a stretch of the song, with a recording of its own.
        private mutating func clip(_ range: ClosedRange<Double>) -> Clip {
            let length = Int(((range.upperBound - range.lowerBound) * 48_000).rounded())
            let recording = Recording(lengthSamples: length, rawStart: range.lowerBound)
            project.recordings.append(recording)
            return Clip(segments: [Segment(recordingID: recording.id, inSample: 0, outSample: length)])
        }

        /// The ids of the clips with these names.
        func ids(_ names: String...) -> Set<UUID> {
            Set(names.map { clips[$0]! })
        }
    }

    // MARK: The clips a range touches

    @Test func theClipsWithSomePartInsideTheRangeAreTouched() {
        let song = Song()
        // a ends inside the range, b starts inside it, c lies across its start.
        #expect(song.project.shownClips(onTracks: [song.tracks[0], song.tracks[1]], touching: 3.5...7) == song.ids("a", "b", "c"))
        // A clip that reaches over the whole range is touched too.
        #expect(song.project.shownClips(onTracks: [song.tracks[0]], touching: 2.5...3) == song.ids("a"))
        // And a range with no width touches the clip it lies inside.
        #expect(song.project.shownClips(onTracks: [song.tracks[0]], touching: 3...3) == song.ids("a"))
    }

    @Test func aClipThatOnlyMeetsTheRangeAtAnEdgeIsNotTouched() {
        let song = Song()
        // a ends at 4 and b starts at 6.
        #expect(song.project.shownClips(onTracks: [song.tracks[0]], touching: 4...6).isEmpty)
        #expect(song.project.shownClips(onTracks: [song.tracks[0]], touching: 4...6.001) == song.ids("b"))
        #expect(song.project.shownClips(onTracks: [song.tracks[0]], touching: 3.999...6) == song.ids("a"))
        // A range with no width at the very start or end of a clip touches nothing.
        #expect(song.project.shownClips(onTracks: [song.tracks[0]], touching: 2...2).isEmpty)
        #expect(song.project.shownClips(onTracks: [song.tracks[0]], touching: 4...4).isEmpty)
    }

    @Test func onlyTheGivenTracksAreLookedAt() {
        let song = Song()
        // f on the third track and g on the fourth lie in the range, and are not asked for.
        #expect(song.project.shownClips(onTracks: [song.tracks[0], song.tracks[1]], touching: 0...20) == song.ids("a", "b", "c", "d"))
        #expect(song.project.shownClips(onTracks: [song.tracks[2]], touching: 0...20) == song.ids("f"))
        #expect(song.project.shownClips(onTracks: [], touching: 0...20).isEmpty)
        // A track the project does not have gives nothing and stops nothing.
        #expect(song.project.shownClips(onTracks: [UUID(), song.tracks[3]], touching: 0...20) == song.ids("g"))
    }

    @Test func aTakeThatWaitsIsNeverTouched() throws {
        var song = Song()
        // e lies exactly where c does, and only c is drawn.
        #expect(song.project.shownClips(onTracks: [song.tracks[1]], touching: 3...5) == song.ids("c"))
        // When e is the take that is heard, it is the other way round.
        for index in song.project.tracks[1].clips.indices {
            let id = song.project.tracks[1].clips[index].id
            if id == song.clips["c"] { song.project.tracks[1].clips[index].isActiveTake = false }
            if id == song.clips["e"] { song.project.tracks[1].clips[index].isActiveTake = true }
        }
        #expect(song.project.shownClips(onTracks: [song.tracks[1]], touching: 3...5) == song.ids("e"))
    }

    @Test func aClipWhoseRecordingIsGoneIsNotTouched() {
        var song = Song()
        song.project.tracks[0].clips.append(Clip(segments: [Segment(recordingID: UUID(), inSample: 0, outSample: 48_000)]))
        song.project.tracks[0].clips.append(Clip())
        #expect(song.project.shownClips(onTracks: [song.tracks[0]], touching: 0...20) == song.ids("a", "b"))
    }

    // MARK: The tracks a number of rows away

    @Test func theTracksGoFromTheFirstRowToTheRowThePointerIsIn() {
        let song = Song()
        let tracks = song.tracks
        #expect(song.project.tracks(from: tracks[1], rowsDown: 0) == [tracks[1]])
        #expect(song.project.tracks(from: tracks[1], rowsDown: 1) == [tracks[1], tracks[2]])
        #expect(song.project.tracks(from: tracks[0], rowsDown: 3) == tracks)
        // Upwards, and still in the order of the project.
        #expect(song.project.tracks(from: tracks[2], rowsDown: -1) == [tracks[1], tracks[2]])
        #expect(song.project.tracks(from: tracks[3], rowsDown: -3) == tracks)
    }

    @Test func theTracksStopAtTheFirstAndTheLastTrack() {
        let song = Song()
        let tracks = song.tracks
        #expect(song.project.tracks(from: tracks[2], rowsDown: 5) == [tracks[2], tracks[3]])
        #expect(song.project.tracks(from: tracks[1], rowsDown: -7) == [tracks[0], tracks[1]])
        // Past the end from the last track, and past the start from the first: that track alone.
        #expect(song.project.tracks(from: tracks[3], rowsDown: 2) == [tracks[3]])
        #expect(song.project.tracks(from: tracks[0], rowsDown: -2) == [tracks[0]])
        #expect(song.project.tracks(from: tracks[0], rowsDown: .max) == tracks)
        #expect(song.project.tracks(from: tracks[3], rowsDown: .min) == tracks)
    }

    @Test func aTrackTheProjectDoesNotHaveGivesNoTracks() {
        let song = Song()
        #expect(song.project.tracks(from: UUID(), rowsDown: 0).isEmpty)
        #expect(song.project.tracks(from: UUID(), rowsDown: 2).isEmpty)
    }

    // MARK: What a drag is right now

    /// The drag as the model asks about it, started on the track with this number.
    private func drag(
        in song: Song,
        fromTrack track: Int,
        start: Double,
        pointer: Double,
        rowsDown: Int,
        selectedBefore: Set<UUID> = [],
        addsToSelection: Bool = false
    ) -> SelectionDrag {
        SelectionDrag(
            in: song.project,
            trackID: song.tracks[track],
            startSeconds: start,
            pointerSeconds: pointer,
            rowsDown: rowsDown,
            selectedBefore: selectedBefore,
            addsToSelection: addsToSelection
        )
    }

    @Test func aDragThatStaysInItsRowIsAStretchOfThatTrack() {
        let song = Song()
        #expect(drag(in: song, fromTrack: 1, start: 3, pointer: 11, rowsDown: 0) == .stretch(trackID: song.tracks[1]))
        // Whatever was selected, and with or without Shift.
        #expect(
            drag(in: song, fromTrack: 1, start: 3, pointer: 11, rowsDown: 0, selectedBefore: song.ids("a"), addsToSelection: true)
                == .stretch(trackID: song.tracks[1])
        )
    }

    @Test func aDragIntoAnotherRowIsARectangleOverTheRowsBetween() {
        let song = Song()
        let down = drag(in: song, fromTrack: 0, start: 3.5, pointer: 7.5, rowsDown: 2)
        #expect(down == .rectangle(SelectionDrag.Rectangle(
            trackIDs: Array(song.tracks[0...2]),
            range: 3.5...7.5,
            clipIDs: song.ids("a", "b", "c", "f")
        )))
        // The pointer may be before where the drag started, and above it.
        let up = drag(in: song, fromTrack: 2, start: 7.5, pointer: 3.5, rowsDown: -1)
        #expect(up == .rectangle(SelectionDrag.Rectangle(
            trackIDs: Array(song.tracks[1...2]),
            range: 3.5...7.5,
            clipIDs: song.ids("c", "f")
        )))
    }

    @Test func aRectangleThatTouchesNoClipSelectsNone() {
        let song = Song()
        #expect(drag(in: song, fromTrack: 0, start: 13, pointer: 15, rowsDown: 3, selectedBefore: song.ids("a")) == .rectangle(
            SelectionDrag.Rectangle(trackIDs: song.tracks, range: 13...15, clipIDs: [])
        ))
    }

    @Test func backInTheFirstRowItIsAStretchAgain() {
        let song = Song()
        guard case .rectangle = drag(in: song, fromTrack: 1, start: 3, pointer: 8, rowsDown: 1) else {
            Issue.record("one row down is a rectangle")
            return
        }
        #expect(drag(in: song, fromTrack: 1, start: 3, pointer: 8, rowsDown: 0) == .stretch(trackID: song.tracks[1]))
    }

    @Test func pastTheFirstOrTheLastTrackThereIsNoOtherRowToReach() {
        let song = Song()
        // Above the first track are the song and the ruler, and below the last one nothing: the pointer is
        // in no other track's row, so the drag is the stretch it was.
        #expect(drag(in: song, fromTrack: 0, start: 3, pointer: 8, rowsDown: -1) == .stretch(trackID: song.tracks[0]))
        #expect(drag(in: song, fromTrack: 3, start: 3, pointer: 8, rowsDown: 4) == .stretch(trackID: song.tracks[3]))
        // From another track, a pointer past the end makes a rectangle that stops at the last track.
        #expect(drag(in: song, fromTrack: 2, start: 0, pointer: 20, rowsDown: 9) == .rectangle(
            SelectionDrag.Rectangle(trackIDs: Array(song.tracks[2...3]), range: 0...20, clipIDs: song.ids("f", "g"))
        ))
    }

    @Test func withoutShiftTheTouchedClipsReplaceTheSelection() {
        let song = Song()
        let found = drag(in: song, fromTrack: 0, start: 5.5, pointer: 9.5, rowsDown: 2, selectedBefore: song.ids("a", "d", "g"))
        #expect(found == .rectangle(SelectionDrag.Rectangle(
            trackIDs: Array(song.tracks[0...2]),
            range: 5.5...9.5,
            clipIDs: song.ids("b", "f")
        )))
    }

    @Test func withShiftTheTouchedClipsAreAddedToTheSelection() {
        let song = Song()
        // b was selected already and is touched again: it stays, once.
        let found = drag(
            in: song, fromTrack: 0, start: 5.5, pointer: 9.5, rowsDown: 2,
            selectedBefore: song.ids("a", "b", "g"), addsToSelection: true
        )
        #expect(found == .rectangle(SelectionDrag.Rectangle(
            trackIDs: Array(song.tracks[0...2]),
            range: 5.5...9.5,
            clipIDs: song.ids("a", "b", "f", "g")
        )))
        // The rectangle is worked out from the selection before the drag every time, so a clip it touched
        // a moment ago and has left again is not kept.
        let smaller = drag(
            in: song, fromTrack: 0, start: 5.5, pointer: 6.5, rowsDown: 1,
            selectedBefore: song.ids("a", "b", "g"), addsToSelection: true
        )
        #expect(smaller == .rectangle(SelectionDrag.Rectangle(
            trackIDs: Array(song.tracks[0...1]),
            range: 5.5...6.5,
            clipIDs: song.ids("a", "b", "g")
        )))
    }

    @Test func aDragFromATrackTheProjectDoesNotHaveIsAStretch() {
        let song = Song()
        let gone = UUID()
        let found = SelectionDrag(
            in: song.project, trackID: gone, startSeconds: 1, pointerSeconds: 9, rowsDown: 2,
            selectedBefore: [], addsToSelection: false
        )
        #expect(found == .stretch(trackID: gone))
    }
}

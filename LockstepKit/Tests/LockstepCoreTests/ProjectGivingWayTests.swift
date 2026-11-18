import Foundation
import Testing
@testable import LockstepCore

/// A twenty-second song with two empty tracks, "Track 1" and "Track 2".
private func song() -> Project {
    var project = Project(songLengthSamples: 960_000)
    project.addTrack()
    return project
}

/// Records a clip the way the app does: a new recording whose clip begins `start` seconds into the song and is
/// `seconds` long, aimed at `place` with the playhead at `playhead`. Without an aim only where the clip
/// starts says whether it is a take. Returns the id of the clip.
@discardableResult
private func record(
    _ start: Double,
    _ seconds: Double = 1,
    in project: inout Project,
    track: Int = 0,
    place: Double? = nil,
    playhead: Double? = nil
) -> UUID {
    let recording = Recording(lengthSamples: Int((seconds * Lockstep.sampleRate).rounded()), rawStart: start)
    return project.addRecording(
        recording,
        samples: 0..<recording.lengthSamples,
        asClipOn: project.tracks[track].id,
        aim: place.map { RecordAim(place: $0, playhead: playhead) }, voices: .none
    )!
}

/// The samples of the song a clip covers, or nil when the project has no such clip.
private func span(_ id: UUID, in project: Project) -> Range<Int>? {
    project.clip(id).flatMap { project.songSpan(of: $0) }
}

/// The samples of the song every clip of a track covers, in the order the track holds them.
private func spans(in project: Project, track: Int = 0) -> [Range<Int>] {
    project.tracks[track].clips.compactMap { project.songSpan(of: $0) }
}

/// A whole number of seconds as a sample of the song.
private func s(_ seconds: Double) -> Int {
    Int((seconds * Lockstep.sampleRate).rounded())
}

/// Max's rule of 13 November 2026: a recording started at a clip's start is a new take of it, and a recording
/// from anywhere else replaces what it covers. Every case is made as one edit and taken back with one Undo.
@Suite("Takes from a clip's start, and clips that give way")
@MainActor
struct ProjectGivingWayTests {
    /// Makes a change as one edit and gives back the project after it, having checked that one Undo puts
    /// the project back exactly as it was.
    private func edited(_ project: Project, _ change: (inout Project) -> Void) -> Project {
        let store = ProjectStore(project: project)
        let before = store.project
        store.edit("Change") { change(&$0) }
        let changed = store.project
        #expect(changed != before)
        store.undo()
        #expect(store.project == before)
        return changed
    }

    // MARK: A take from a clip's start

    @Test func aShortAndALongTakeFromAClipsStartAreTakesAndNeitherCutsTheLine() throws {
        var project = song()
        let line = record(4, 2, in: &project)
        let neighbour = record(8, in: &project)
        project.normalizeTakes()

        // A take that covers only the first half second of the clip.
        var short: UUID?
        do {
            let changed = edited(project) { short = record(4, 0.5, in: &$0) }
            let short = try #require(short)
            #expect(changed.takes(of: line).map(\.id) == [line, short])
            #expect(changed.clip(short)?.isActiveTake == true)
            #expect(changed.clip(line)?.isActiveTake == false)
            #expect(span(line, in: changed) == s(4)..<s(6))
            #expect(span(neighbour, in: changed) == s(8)..<s(9))
        }

        // A take that starts 20 ms after the clip's start and runs on over the clip after it. It covers
        // the whole clip it is a take of, which stays whole, and the neighbour, which is another line and goes.
        var long: UUID?
        do {
            let changed = edited(project) { long = record(4.02, 6, in: &$0) }
            let long = try #require(long)
            #expect(changed.takes(of: line).map(\.id) == [line, long])
            #expect(span(line, in: changed) == s(4)..<s(6))
            #expect(changed.clip(neighbour) == nil)
        }
    }

    @Test func aStartSixtyMillisecondsOffIsNoTakeAndTheNewClipWins() throws {
        var project = song()
        let old = record(4, 2, in: &project, place: 4, playhead: 4)
        project.normalizeTakes()

        var new: UUID?
        do {
            let changed = edited(project) { new = record(4.06, 1, in: &$0, place: 4.06, playhead: 4.06) }
            let new = try #require(new)
            #expect(changed.takeCount(of: new) == 1)
            #expect(changed.takeCount(of: old) == 1)
            // The 60 ms of the old clip before the new one are too short to keep. What it has after the new
            // one is still the same clip, shortened from the left.
            #expect(spans(in: changed) == [s(5.06)..<s(6), s(4.06)..<s(5.06)])
            #expect(changed.tracks[0].clips.map(\.id) == [old, new])
            #expect(changed.tracks[0].clips.filter { !$0.isActiveTake }.isEmpty)
        }
    }

    @Test func aTakeIsJudgedByThePlaceMaxAimedAtNotByWhereTheVoiceStarts() throws {
        // Recorded from the beat at 4 s, and the voice came in at 4.3 s, so that is where the clip starts.
        var project = song()
        let line = record(4.3, 1.7, in: &project, place: 4, playhead: 4)
        project.normalizeTakes()
        #expect(project.clip(line)?.recordPlace == 4)

        // The playhead was put on the clip's start. Record aimed at the nearest beat, half a second on,
        // and this time the voice started there.
        var onStart: UUID?
        do {
            let changed = edited(project) { onStart = record(4.5, 1, in: &$0, place: 4.5, playhead: 4.3) }
            let onStart = try #require(onStart)
            #expect(changed.takes(of: line).map(\.id) == [line, onStart])
            #expect(span(line, in: changed) == s(4.3)..<s(6))
        }

        // Recorded again from the same beat, and the voice started early, 400 ms before the clip's start.
        var again: UUID?
        do {
            let changed = edited(project) { again = record(3.9, 2, in: &$0, place: 4, playhead: 4) }
            let again = try #require(again)
            #expect(changed.takes(of: line).map(\.id) == [line, again])
            #expect(span(line, in: changed) == s(4.3)..<s(6))
        }

        // Aimed a whole beat earlier, the same sound is no take: it wins, and the line is cut where it is covered.
        var before: UUID?
        do {
            let changed = edited(project) { before = record(3.9, 2, in: &$0, place: 3.5, playhead: 3.5) }
            let before = try #require(before)
            #expect(changed.takeCount(of: before) == 1)
            #expect(span(line, in: changed) == s(5.9)..<s(6))
        }
    }

    @Test func theRecordPlaceMovesWithTheClipAndIsForgottenWhenTheStartIsTrimmed() throws {
        var project = song()
        let line = record(4.3, 1.7, in: &project, place: 4, playhead: 4)
        project.normalizeTakes()

        // Moved two seconds later: a recording from two seconds later is a take of it.
        var moved = project
        moved.moveClips([line], bySamples: 96_000, trackSteps: 0, voices: .none)
        #expect(moved.recordPlace(of: moved.clip(line)!) == 6)
        let take = record(6.1, 1, in: &moved, place: 6, playhead: 6)
        #expect(moved.takes(of: line).map(\.id) == [line, take])

        // The start is dragged in to 5 s, to make room. A recording from the old place, stopped before the
        // clip, is then a clip of its own and nothing is cut.
        var trimmed = project
        trimmed.trimClip(line, edge: .start, toSongSample: s(5), voices: .none)
        #expect(trimmed.clip(line)?.recordPlace == nil)
        let new = record(4.05, 0.9, in: &trimmed, place: 4, playhead: 4)
        #expect(trimmed.takeCount(of: new) == 1)
        #expect(spans(in: trimmed) == [s(5)..<s(6), s(4.05)..<s(4.95)])
    }

    @Test func thePassesOfALoopRecordingAreTakesOfOneLineWhereverEachVoiceStarts() {
        // Three times round a loop that starts at 8 s. Each pass's clip starts where its voice does.
        var project = song()
        let earlier = record(8.1, 1, in: &project, place: 8, playhead: 8)
        project.normalizeTakes()
        var passes: [UUID] = []
        for start in [8.0, 8.2, 7.9] {
            passes.append(record(start, 1.5, in: &project, place: 8))
        }
        project.normalizeTakes()

        #expect(project.takes(of: earlier).map(\.id) == [earlier] + passes)
        #expect(project.tracks[0].clips.filter(\.isActiveTake).map(\.id) == [passes[2]])
        #expect(span(earlier, in: project) == s(8.1)..<s(9.1))
    }

    // MARK: A recording over a clip of another line

    @Test func aRecordingOverAClipsEndShortensIt() throws {
        var project = song()
        let old = record(4, 2, in: &project)
        project.tracks[0].clips[0].name = "Hook"
        project.normalizeTakes()
        let recordings = project.recordings

        var new: UUID?
        do {
            let changed = edited(project) { new = record(5, 2, in: &$0) }
            let new = try #require(new)
            #expect(spans(in: changed) == [s(4)..<s(5), s(5)..<s(7)])
            #expect(changed.clip(old)?.name == "Hook")
            #expect(changed.takeCount(of: old) == 1)
            #expect(changed.takeCount(of: new) == 1)
            // No recording is changed, so the clip can be dragged out again as far as its recording goes.
            #expect(Array(changed.recordings.prefix(1)) == recordings)
            #expect(changed.trimRange(of: old, edge: .end)?.upperBound == s(6))
        }
    }

    @Test func aRecordingOverAClipsStartShortensItFromTheLeft() throws {
        var project = song()
        let old = record(4, 2, in: &project, place: 4)
        project.normalizeTakes()

        do {
            let changed = edited(project) { record(3, 2, in: &$0, place: 3) }
            #expect(spans(in: changed) == [s(5)..<s(6), s(3)..<s(5)])
            // It is the same clip, and its sound has not moved: it plays its recording from one second in.
            #expect(changed.clip(old)?.segments == [
                Segment(recordingID: project.recordings[0].id, inSample: 48_000, outSample: 96_000),
            ])
            // It no longer starts where it was recorded from.
            #expect(changed.clip(old)?.recordPlace == nil)
        }
    }

    @Test func aRecordingOverAClipsMiddleMakesTwoClipsOfIt() throws {
        var project = song()
        let old = record(4, 2, in: &project)
        project.tracks[0].clips[0].name = "Hook"
        project.tracks[0].clips[0].text = "I stay behind"
        project.normalizeTakes()

        do {
            let changed = edited(project) { record(4.5, 0.5, in: &$0) }
            #expect(spans(in: changed) == [s(4)..<s(4.5), s(5)..<s(6), s(4.5)..<s(5)])
            let first = changed.tracks[0].clips[0]
            let second = changed.tracks[0].clips[1]
            // As after a split: the piece before keeps the id and the name, the piece after is a new clip.
            #expect(first.id == old)
            #expect(first.name == "Hook")
            #expect(second.id != old)
            #expect(second.name == nil)
            #expect(second.text == nil)
            // Three clips, three lines, all of them shown.
            #expect(Set(changed.tracks[0].clips.map(\.line)).count == 3)
            #expect(changed.tracks[0].clips.filter { !$0.isActiveTake }.isEmpty)
        }
    }

    @Test func aRecordingOverAllOfAClipRemovesIt() throws {
        var project = song()
        let old = record(4, 2, in: &project)
        project.normalizeTakes()

        var new: UUID?
        do {
            let changed = edited(project) { new = record(3.5, 3, in: &$0) }
            let new = try #require(new)
            #expect(changed.clip(old) == nil)
            #expect(changed.tracks[0].clips.map(\.id) == [new])
            // Its recording stays, so Undo can bring it back with its sound.
            #expect(changed.recordings.count == 2)
        }
    }

    @Test func aLineWithThreeTakesGivesWayAsAWhole() throws {
        // Three takes from 4 s: two, two and a half and three seconds long. The second is the one shown.
        var project = song()
        let first = record(4, 2, in: &project)
        let second = record(4, 2.5, in: &project)
        let third = record(4, 3, in: &project)
        project.normalizeTakes()
        project.setActiveTake(second)

        // Over the end: every take ends where the new clip starts, and they are still one line.
        do {
            let changed = edited(project) { record(5, 3, in: &$0) }
            for take in [first, second, third] {
                #expect(span(take, in: changed) == s(4)..<s(5))
            }
            #expect(changed.takes(of: first).map(\.id) == [first, second, third])
            #expect(changed.clip(second)?.isActiveTake == true)
        }

        // Over the middle: each take becomes two clips. What lies before is one line and what lies after
        // is another, each with three takes and the same take shown.
        do {
            let changed = edited(project) { record(4.5, 0.5, in: &$0) }
            #expect(changed.takes(of: first).map(\.id) == [first, second, third])
            let after = changed.tracks[0].clips.filter { ![first, second, third].contains($0.id) }.dropLast()
            #expect(after.compactMap { changed.songSpan(of: $0) } == [s(5)..<s(6), s(5)..<s(6.5), s(5)..<s(7)])
            #expect(Set(after.map(\.line)).count == 1)
            #expect(after.first?.line != changed.clip(first)?.line)
            #expect(after.map(\.isActiveTake) == [false, true, false])
            #expect(changed.clip(second)?.isActiveTake == true)
        }

        // Over all of it: the whole line is gone.
        var new: UUID?
        do {
            let changed = edited(project) { new = record(3, 5, in: &$0) }
            let new = try #require(new)
            #expect(changed.tracks[0].clips.map(\.id) == [new])
        }
    }

    @Test func aMutedClipGivesWayAndMakesOthersGiveWayAndOtherTracksAreNotTouched() throws {
        var project = song()
        let muted = record(4, 2, in: &project)
        let below = record(4, 2, in: &project, track: 1)
        project.setClips([muted], muted: true)
        project.normalizeTakes()

        do {
            let changed = edited(project) { record(5, 2, in: &$0) }
            #expect(span(muted, in: changed) == s(4)..<s(5))
            #expect(span(below, in: changed) == s(4)..<s(6))
        }

        var winner: UUID?
        do {
            let changed = edited(project) {
                let id = record(10, 2, in: &$0)
                $0.setClips([id], muted: true)
                $0.moveClips([id], bySamples: -s(5), trackSteps: 0, voices: .none)
                winner = id
            }
            let winner = try #require(winner)
            #expect(span(winner, in: changed) == s(5)..<s(7))
            #expect(span(muted, in: changed) == s(4)..<s(5))
        }
    }

    // MARK: A line goes with its shown clip

    /// A line with two takes from 4 s: a long one of three seconds that waits, and a short one of one second
    /// that is shown. Returns the long and the short one.
    private func shortShownAndLongWaiting(in project: inout Project) -> (long: UUID, short: UUID) {
        let long = record(4, 3, in: &project)
        let short = record(4, 1, in: &project)
        project.normalizeTakes()
        return (long, short)
    }

    @Test func aRecordingOverAllOfTheShownClipTakesTheLineWithAllItsTakes() throws {
        var project = song()
        let line = shortShownAndLongWaiting(in: &project)
        #expect(project.clip(line.short)?.isActiveTake == true)

        // From 3.5 s to 6 s: all of the shown clip, and two of the three seconds of the take that waits.
        // The last second of that take is not left behind as a clip after the new one.
        var new: UUID?
        do {
            let changed = edited(project) { new = record(3.5, 2.5, in: &$0) }
            let new = try #require(new)
            #expect(changed.tracks[0].clips.map(\.id) == [new])
            #expect(spans(in: changed) == [s(3.5)..<s(6)])
            // The recordings stay, so Undo brings both takes back with their sound.
            #expect(changed.recordings.count == 3)
        }

        // A take that waits far from the new clip goes too: the line is gone, so nothing of it is left.
        var apart = song()
        let shown = record(4, 1, in: &apart, place: 4)
        let far = record(8, 1, in: &apart, place: 4)
        apart.normalizeTakes()
        apart.setActiveTake(shown)
        #expect(apart.takes(of: shown).map(\.id) == [shown, far])
        do {
            let changed = edited(apart) { new = record(3.5, 2, in: &$0, place: 3.5) }
            #expect(changed.tracks[0].clips.map(\.id) == [try #require(new)])
        }
    }

    @Test func aWaitingTakeKeepsNothingOnASideWhereTheShownClipHasNothingLeft() throws {
        var project = song()
        let line = shortShownAndLongWaiting(in: &project)

        // Over the end of the shown clip and the middle of the take that waits. Both end where the new clip
        // starts, they are still takes of each other, and nothing of the line is left after the new clip.
        var new: UUID?
        do {
            let changed = edited(project) { new = record(4.5, 1.5, in: &$0) }
            let new = try #require(new)
            #expect(changed.tracks[0].clips.map(\.id) == [line.long, line.short, new])
            #expect(spans(in: changed) == [s(4)..<s(4.5), s(4)..<s(4.5), s(4.5)..<s(6)])
            #expect(changed.takes(of: line.short).map(\.id) == [line.long, line.short])
            #expect(changed.tracks[0].clips.filter(\.isActiveTake).map(\.id) == [line.short, new])
            // Its recording is whole, so once it is the one shown it can be dragged out again.
            var chosen = changed
            chosen.chooseTake(line.long, voices: .none)
            #expect(chosen.trimRange(of: line.long, edge: .end)?.upperBound == s(7))
        }

        // After the shown clip, in the middle of the take that waits. The shown clip is not touched, and
        // the take that waits ends where the new clip starts.
        do {
            let changed = edited(project) { new = record(5.5, 1, in: &$0) }
            let new = try #require(new)
            #expect(changed.tracks[0].clips.map(\.id) == [line.long, line.short, new])
            #expect(spans(in: changed) == [s(4)..<s(5.5), s(4)..<s(5), s(5.5)..<s(6.5)])
        }

        // The other way round: the take that waits starts 400 ms before the shown one, and a short
        // recording lands in those 400 ms. What the waiting take has before it goes, and it stays a take
        // of its line.
        var early = song()
        let waiting = record(3.9, 2.1, in: &early, place: 4, playhead: 4)
        let shown = record(4.3, 1.7, in: &early, place: 4, playhead: 4)
        early.normalizeTakes()
        do {
            let changed = edited(early) { new = record(4.05, 0.1, in: &$0, place: 4.5) }
            let new = try #require(new)
            #expect(changed.tracks[0].clips.map(\.id) == [waiting, shown, new])
            #expect(spans(in: changed) == [s(4.15)..<s(6), s(4.3)..<s(6), s(4.05)..<s(4.15)])
            #expect(changed.takes(of: shown).map(\.id) == [waiting, shown])
        }

        // A take that waits and that the new clip does not reach into is left alone.
        var apart = song()
        let first = record(4, 1, in: &apart, place: 4)
        let far = record(8, 1, in: &apart, place: 4)
        apart.normalizeTakes()
        apart.setActiveTake(first)
        do {
            let changed = edited(apart) { record(4.5, 1, in: &$0, place: 4.5) }
            #expect(span(first, in: changed) == s(4)..<s(4.5))
            #expect(span(far, in: changed) == s(8)..<s(9))
            #expect(changed.takes(of: first).map(\.id) == [first, far])
        }
    }

    // MARK: No rest shorter than 100 ms

    @Test func aRestShorterThanAHundredMillisecondsIsRemovedAndALongerOneKept() throws {
        var project = song()
        let old = record(4, 2, in: &project, place: 4)
        project.normalizeTakes()

        // 60 ms before the new clip and 60 ms after it: neither is kept, so the clip is gone.
        do {
            let changed = edited(project) { record(4.06, 1.88, in: &$0, place: 4.06) }
            #expect(changed.clip(old) == nil)
            #expect(spans(in: changed) == [s(4.06)..<s(5.94)])
        }

        // Exactly 100 ms before the new clip is kept, and 99 ms after it is not.
        do {
            let changed = edited(project) { record(4.1, 1.801, in: &$0, place: 4.1) }
            #expect(spans(in: changed) == [s(4)..<s(4.1), s(4.1)..<s(5.901)])
            #expect(Project.leastRestSamples == s(0.1))
        }
    }

    @Test func aLineWhoseShownClipIsLeftWithLessThanAHundredMillisecondsGoes() throws {
        // The shown take is one second long and a take of three seconds waits behind it. A recording from
        // 60 ms after their start covers the rest of the shown one.
        var project = song()
        _ = shortShownAndLongWaiting(in: &project)

        var new: UUID?
        do {
            let changed = edited(project) { new = record(4.06, 1.5, in: &$0) }
            #expect(changed.tracks[0].clips.map(\.id) == [try #require(new)])
        }
    }

    @Test func aWaitingTakeLosesARestThatIsTooShortAndStaysATake() throws {
        // The take that waits starts 450 ms after the shown one. A recording from 4.5 s to 5 s divides
        // the line: the shown take has half a second before it, the waiting one only 50 ms.
        var project = song()
        let waiting = record(4.45, 1.55, in: &project, place: 4)
        let shown = record(4, 2, in: &project, place: 4)
        project.normalizeTakes()

        do {
            let changed = edited(project) { record(4.5, 0.5, in: &$0, place: 4.5) }
            // Before the new clip only the shown take is left. After it both are, as takes of one line.
            #expect(changed.takeCount(of: shown) == 1)
            #expect(span(shown, in: changed) == s(4)..<s(4.5))
            #expect(span(waiting, in: changed) == s(5)..<s(6))
            let after = changed.takes(of: waiting)
            #expect(after.compactMap { changed.songSpan(of: $0) } == [s(5)..<s(6), s(5)..<s(6)])
            #expect(after.map(\.isActiveTake) == [false, true])
        }
    }

    @Test func aDraggedEdgeAndAMovedClipLeaveNoShortRestEither() throws {
        var project = song()
        let dragged = record(3, 3, in: &project)
        project.trimClip(dragged, edge: .end, toSongSample: s(4), voices: .none)
        let neighbour = record(4, 1, in: &project, place: 4)
        let moved = record(10, 0.95, in: &project, track: 1)
        project.normalizeTakes()

        // The end is dragged out until 80 ms of the neighbour would be left: the neighbour goes.
        do {
            let changed = edited(project) { $0.trimClip(dragged, edge: .end, toSongSample: s(4.92), voices: .none) }
            #expect(changed.clip(neighbour) == nil)
            #expect(spans(in: changed) == [s(3)..<s(4.92)])
        }

        // A clip of 950 ms dropped 60 ms after the neighbour's start covers all of it but 60 ms.
        do {
            let changed = edited(project) { $0.moveClips([moved], bySamples: -s(5.94), trackSteps: -1, voices: .none) }
            #expect(changed.clip(neighbour) == nil)
            #expect(spans(in: changed) == [s(3)..<s(4), s(4.06)..<s(5.01)])
        }
    }

    // MARK: Choosing another take

    /// "Track 1" has a line from `start` with one take for every length given, in seconds, the last one
    /// shown. A line with two takes is then moved up from "Track 2" to start at 4 s: a long take of three
    /// seconds that waits, and a short one of one second that is shown. Only the shown take makes clips
    /// give way when it lands, so the long one now waits on top of the other line. Returns the long take,
    /// the short one and the takes of the other line.
    private func aWaitingTakeOver(
        _ start: Double,
        _ seconds: Double...,
        in project: inout Project
    ) -> (long: UUID, short: UUID, others: [UUID]) {
        let others = seconds.map { record(start, $0, in: &project) }
        let long = record(10, 3, in: &project, track: 1)
        let short = record(10, 1, in: &project, track: 1)
        project.normalizeTakes()
        project.moveClips([short], bySamples: -s(6), trackSteps: -1, voices: .none)
        project.normalizeTakes()
        return (long, short, others)
    }

    @Test func choosingATakeMakesWhatItCoversGiveWayInTheSameStep() throws {
        // The other clip lies from 6 s to 8 s, under the last second of the take that waits.
        var project = song()
        let clips = aWaitingTakeOver(6, 2, in: &project)
        #expect(spans(in: project) == [s(6)..<s(8), s(4)..<s(7), s(4)..<s(5)])
        #expect(project.takes(of: clips.short).map(\.id) == [clips.long, clips.short])
        #expect(project.clip(clips.short)?.isActiveTake == true)

        // Chosen, the long take is shown and the other clip starts where it ends. One Undo takes back both.
        do {
            let changed = edited(project) { $0.chooseTake(clips.long, voices: .none) }
            #expect(changed.clip(clips.long)?.isActiveTake == true)
            #expect(changed.clip(clips.short)?.isActiveTake == false)
            #expect(spans(in: changed) == [s(7)..<s(8), s(4)..<s(7), s(4)..<s(5)])
            // Choosing the short take again does not bring back what gave way.
            var back = changed
            #expect(back.chooseTake(clips.short, voices: .none) == false)
            #expect(spans(in: back) == spans(in: changed))
        }

        // A clip the chosen take covers all of goes, with the take that waits behind it.
        var covered = song()
        let under = aWaitingTakeOver(5.5, 1.4, 1.2, in: &covered)
        #expect(covered.takes(of: under.others[0]).map(\.id) == under.others)
        #expect(covered.tracks[0].clips.map(\.id) == under.others + [under.long, under.short])
        do {
            let changed = edited(covered) { $0.chooseTake(under.long, voices: .none) }
            #expect(changed.tracks[0].clips.map(\.id) == [under.long, under.short])
        }
    }

    @Test func listeningToATakeAndChoosingTheShownOneCutNothing() {
        var project = song()
        let clips = aWaitingTakeOver(6, 2, in: &project)

        // What a take's Play button does, on the copy only the player gets: the take is the one heard, and
        // no clip is cut.
        var heard = project
        heard.setActiveTake(clips.long)
        #expect(heard.clip(clips.long)?.isActiveTake == true)
        #expect(spans(in: heard) == spans(in: project))

        // The take that is already shown is chosen again: nothing changes.
        var same = project
        #expect(same.chooseTake(clips.short, voices: .none) == false)
        #expect(same == project)

        // A clip the project does not have.
        #expect(same.chooseTake(UUID(), voices: .none) == false)
        #expect(same == project)
    }

    // MARK: Dragging an edge out, and moving

    @Test func draggingTheShortenedClipBackOutMakesTheNewClipGiveWay() throws {
        var project = song()
        let old = record(4, 2, in: &project)
        let new = record(5, 2, in: &project)
        project.normalizeTakes()
        #expect(spans(in: project) == [s(4)..<s(5), s(5)..<s(7)])

        // Dragged back out as far as its recording goes: the clip that was touched last wins.
        do {
            let changed = edited(project) { $0.trimClip(old, edge: .end, toSongSample: s(6.5), voices: .none) }
            #expect(spans(in: changed) == [s(4)..<s(6), s(6)..<s(7)])
            #expect(changed.takeCount(of: old) == 1)
            #expect(changed.takeCount(of: new) == 1)
        }

        // And the new clip's start dragged out over the old one again, in turn.
        var again = project
        again.trimClip(old, edge: .end, toSongSample: s(6), voices: .none)
        do {
            let changed = edited(again) { $0.trimClip(new, edge: .start, toSongSample: s(5.5), voices: .none) }
            #expect(spans(in: changed) == [s(4)..<s(5.5), s(5.5)..<s(7)])
        }

        // An edge dragged inwards uncovers nothing and cuts nothing.
        do {
            let changed = edited(project) { $0.trimClip(new, edge: .start, toSongSample: s(5.5), voices: .none) }
            #expect(spans(in: changed) == [s(4)..<s(5), s(5.5)..<s(7)])
        }
    }

    @Test func aDraggedEdgeCutsTheWaitingTakesOfTheOtherLineToo() throws {
        // A clip from 4 s to 5 s, and after it a line with two takes from 5 s.
        var project = song()
        let dragged = record(3, 3, in: &project)
        project.trimClip(dragged, edge: .start, toSongSample: s(4), voices: .none)
        project.trimClip(dragged, edge: .end, toSongSample: s(5), voices: .none)
        let waiting = record(5, 2, in: &project)
        let shown = record(5, 1, in: &project)
        project.normalizeTakes()
        #expect(project.takes(of: shown).map(\.id) == [waiting, shown])

        do {
            let changed = edited(project) { $0.trimClip(dragged, edge: .end, toSongSample: s(5.5), voices: .none) }
            #expect(span(dragged, in: changed) == s(4)..<s(5.5))
            #expect(span(shown, in: changed) == s(5.5)..<s(6))
            #expect(span(waiting, in: changed) == s(5.5)..<s(7))
            #expect(changed.takes(of: shown).map(\.id) == [waiting, shown])
        }
    }

    @Test func movingAClipOntoAnotherMakesATakeAtItsStartAndCutsItAnywhereElse() throws {
        var project = song()
        let resting = record(4, 2, in: &project)
        let moved = record(10, 1, in: &project, track: 1)
        project.normalizeTakes()

        // Dropped on the start of the other clip, 30 ms off: a take of it, and the one shown.
        do {
            let changed = edited(project) { $0.moveClips([moved], bySamples: -s(5.97), trackSteps: -1, voices: .none) }
            #expect(changed.takes(of: resting).map(\.id) == [resting, moved])
            #expect(changed.clip(moved)?.isActiveTake == true)
            #expect(changed.clip(resting)?.isActiveTake == false)
            #expect(span(resting, in: changed) == s(4)..<s(6))
        }

        // Dropped in the middle of it: the other clip becomes two.
        do {
            let changed = edited(project) { $0.moveClips([moved], bySamples: -s(5.5), trackSteps: -1, voices: .none) }
            #expect(spans(in: changed) == [s(4)..<s(4.5), s(5.5)..<s(6), s(4.5)..<s(5.5)])
            #expect(changed.takeCount(of: moved) == 1)
        }

        // Moved along its own track, nothing on the other track is touched.
        do {
            let changed = edited(project) { $0.moveClips([moved], bySamples: -s(5.5), trackSteps: 0, voices: .none) }
            #expect(span(resting, in: changed) == s(4)..<s(6))
            #expect(span(moved, in: changed) == s(4.5)..<s(5.5))
        }
    }

    // MARK: The saved form

    @Test func anOlderProjectGetsItsLinesOnceByTheOldRule() throws {
        // As saved before lines were kept: two takes that overlap by 1.2 of their 2 seconds and do not share
        // a start, the later one shown, and a clip that overlaps the first by less than half.
        let recordings = [2.0, 2.8, 0.5].map { Recording(lengthSamples: 96_000, rawStart: $0) }
        var clips = recordings.map { Clip(segments: [Segment(recordingID: $0.id, inSample: 0, outSample: 96_000)]) }
        clips[0].isActiveTake = false
        let saved = Project(
            songLengthSamples: 960_000,
            tracks: [Track(name: "Track 1", clips: clips)],
            recordings: recordings
        )
        let data = try withoutLines(JSONEncoder().encode(saved))
        #expect(String(decoding: data, as: UTF8.self).contains("\"line\"") == false)

        let read = try JSONDecoder().decode(Project.self, from: data)

        // No take is lost and none is shown twice.
        #expect(read.takes(of: clips[1].id).map(\.id) == [clips[0].id, clips[1].id])
        #expect(read.takeCount(of: clips[2].id) == 1)
        #expect(read.tracks[0].clips.map(\.isActiveTake) == [false, true, true])
        var normalized = read
        normalized.normalizeTakes()
        #expect(normalized == read)

        // From then on the lines are saved, and reading them again changes nothing.
        let again = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(read))
        #expect(again == read)

        // The waiting take is trimmed to its first half second. Under the old rule it would no longer be a
        // take, and would be shown beside the other one. Its line is kept with it now.
        var trimmed = read
        trimmed.setActiveTake(clips[0].id)
        trimmed.trimClip(clips[0].id, edge: .end, toSongSample: s(2.5), voices: .none)
        trimmed.normalizeTakes()
        let reread = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(trimmed))
        #expect(reread.takes(of: clips[0].id).map(\.id) == [clips[0].id, clips[1].id])
    }

    @Test func clipsSavedWithLinesKeepThemHoweverTheyLie() throws {
        // Two lines that lie on top of each other, as when a longer take of one of them was chosen. Saved
        // with their lines, they are not made takes of each other when read.
        var project = song()
        let first = record(2, 2, in: &project)
        let second = record(8, 2, in: &project)
        project.tracks[0].clips[1].segments[0].offsetSamples = -s(5.5)
        project.normalizeTakes()

        let data = try JSONEncoder().encode(project)
        let read = try JSONDecoder().decode(Project.self, from: data)

        #expect(read == project)
        #expect(read.takeCount(of: first) == 1)
        #expect(read.takeCount(of: second) == 1)
        // The line is in the saved form under its own name, as text.
        let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tracks = try #require(saved["tracks"] as? [[String: Any]])
        let clips = try #require(tracks[0]["clips"] as? [[String: Any]])
        #expect(clips[0]["line"] as? String == project.clip(first)?.line.uuidString)
    }
}

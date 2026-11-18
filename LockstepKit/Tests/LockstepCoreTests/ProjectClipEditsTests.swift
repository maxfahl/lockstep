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

/// Changes one clip in place, wherever it is.
private func change(_ id: UUID, in project: inout Project, _ body: (inout Clip) -> Void) {
    for track in project.tracks.indices {
        for clip in project.tracks[track].clips.indices where project.tracks[track].clips[clip].id == id {
            body(&project.tracks[track].clips[clip])
        }
    }
}

/// One stretch of sound that is heard: which samples of which recording, and on which samples of the song.
private struct Heard: Equatable {
    var recording: UUID
    /// The sample of the song the stretch starts on.
    var song: Int
    /// The first sample of the recording that is played.
    var offset: Int
    var length: Int
}

/// Everything that is heard of the clips, in the order of the song. Stretches that play one recording straight
/// on are counted as one, so a clip cut in two without losing a sample is heard as it was before.
private func heard(_ project: Project) -> [Heard] {
    let pieces = project.clipPlaybackPlan(from: 0, voices: .none)
        .map { Heard(recording: $0.recordingID, song: $0.startDelay, offset: $0.offset, length: $0.length) }
        .sorted { ($0.song, $0.offset) < ($1.song, $1.offset) }
    var joined: [Heard] = []
    for piece in pieces {
        if let last = joined.last, last.recording == piece.recording,
           last.song + last.length == piece.song, last.offset + last.length == piece.offset {
            joined[joined.count - 1].length += piece.length
        } else {
            joined.append(piece)
        }
    }
    return joined
}

/// The samples of the song on which one sample of a recording sits, in every clip that holds it, heard or not.
private func places(ofSample sample: Int, of recording: UUID, in project: Project) -> [Int] {
    guard let source = project.recording(recording) else { return [] }
    var places: [Int] = []
    for clip in project.tracks.flatMap(\.clips) {
        for segment in clip.segments where segment.recordingID == recording
            && segment.inSample <= sample && sample < segment.outSample {
            places.append(source.songSample(ofSample: sample, offsetSamples: segment.offsetSamples))
        }
    }
    return places.sorted()
}

/// The recording a clip's first segment plays.
private func recordingID(of clip: UUID, in project: Project) -> UUID {
    project.clip(clip)!.segments[0].recordingID
}

/// Splitting, cutting and joining clips, worked out with numbers alone.
@Suite("Split, cut and join")
struct ProjectClipEditsTests {
    // MARK: Split

    @Test func aSplitInTheMiddleGivesTwoClipsThatAddUpToTheOriginal() {
        var project = emptySong()
        let id = record(2.0, in: &project)
        change(id, in: &project) { clip in
            clip.name = "Verse"
            clip.text = "one two three"
            clip.muted = true
            clip.gainDb = 3
            clip.normalizeGainDb = -2
            clip.feel = .triplets
            clip.segments[0].offsetSamples = 100
            clip.segments[0].gainDb = 1.5
        }
        let recording = recordingID(of: id, in: project)
        let before = heard(project)

        // 2.5 s is sample 120,000 of the song. The clip starts on 96,100, so the cut is 23,900 samples in.
        let pieces = project.splitClip(id, at: 2.5, voices: .none)
        #expect(pieces?.first == id)
        let first = project.clip(id)!
        let second = project.clip(pieces!.second)!

        #expect(project.tracks[0].clips.map(\.id) == [first.id, second.id])
        #expect(first.segments == [
            Segment(recordingID: recording, inSample: 0, outSample: 23_900, offsetSamples: 100, gainDb: 1.5),
        ])
        #expect(second.segments == [
            Segment(recordingID: recording, inSample: 23_900, outSample: 48_000, offsetSamples: 100, gainDb: 1.5),
        ])
        #expect(first.name == "Verse")
        #expect(first.text == "one two three")
        #expect(second.name == nil)
        #expect(second.text == nil)
        for piece in [first, second] {
            #expect(piece.muted)
            #expect(piece.gainDb == 3)
            #expect(piece.normalizeGainDb == -2)
            #expect(piece.feel == .triplets)
            #expect(piece.isActiveTake)
        }
        // Muted, so nothing is heard. Unmuted, the two pieces sound exactly like the one clip did.
        #expect(before.isEmpty)
        var unmutedBefore = emptySong()
        unmutedBefore.recordings = project.recordings
        unmutedBefore.tracks[0].clips = [Clip(segments: [
            Segment(recordingID: recording, inSample: 0, outSample: 48_000, offsetSamples: 100),
        ])]
        project.setClips([first.id, second.id], muted: false)
        #expect(heard(project) == heard(unmutedBefore))
    }

    @Test func aSplitAtAnEdgeOrOutsideTheClipIsRefused() {
        var project = emptySong()
        let id = record(2.0, in: &project)
        let untouched = project

        // On the clip's first and last sample, 0.5 ms inside either edge, and outside the clip.
        for seconds in [2.0, 3.0, 2.0005, 2.9995, 1.0, 5.0, -1.0, .nan, .infinity] {
            #expect(!project.canSplit(clip: id, at: seconds))
            #expect(project.splitClip(id, at: seconds, voices: .none) == nil)
        }
        #expect(!project.canSplit(clip: UUID(), at: 2.5))
        #expect(project == untouched)

        // Exactly 1 ms inside either edge is far enough.
        #expect(project.canSplit(clip: id, at: 2.001))
        #expect(project.canSplit(clip: id, at: 2.999))
    }

    @Test func aSplitInTheGapOfAJoinedClipIsRefused() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(4.0, in: &project)
        let joined = project.joinClips([first, second], voices: .none)!

        #expect(!project.canSplit(clip: joined, at: 3.5))
        #expect(project.canSplit(clip: joined, at: 2.5))
        #expect(project.canSplit(clip: joined, at: 4.5))
    }

    @Test func aSplitThenAJoinGivesTheOriginalBack() {
        var project = emptySong()
        let id = record(2.0, in: &project)
        change(id, in: &project) { clip in
            clip.name = "Verse"
            clip.text = "one two three"
            clip.gainDb = -3
            clip.normalizeGainDb = 4
            clip.segments[0].gainDb = 0.5
        }
        let original = project

        let pieces = project.splitClip(id, at: 2.4, voices: .none)!
        #expect(project != original)
        #expect(project.canJoin([pieces.first, pieces.second]))
        #expect(project.joinClips([pieces.first, pieces.second], voices: .none) == id)

        #expect(project == original)
        #expect(project.clip(id)?.segments.count == 1)
    }

    // MARK: Cut

    @Test func aCutInTheMiddleGivesTwoClipsAndTakesOnlyTheStretchAway() {
        var project = emptySong()
        let id = record(2.0, in: &project)
        change(id, in: &project) { $0.name = "Verse" }
        let recording = recordingID(of: id, in: project)
        #expect(heard(project) == [Heard(recording: recording, song: 96_000, offset: 0, length: 48_000)])

        // 2.25 s to 2.75 s: samples 108,000 to 132,000 of the song.
        let left = project.cut(range: 2.25..<2.75, onTrack: project.tracks[0].id, voices: .none)

        #expect(left?.count == 2)
        #expect(left?.first == id)
        #expect(project.tracks[0].clips.map(\.id) == left)
        #expect(project.clip(id)?.name == "Verse")
        #expect(project.clip(left![1])?.name == nil)
        #expect(heard(project) == [
            Heard(recording: recording, song: 96_000, offset: 0, length: 12_000),
            Heard(recording: recording, song: 132_000, offset: 36_000, length: 12_000),
        ])
    }

    @Test func aCutOverAWholeClipRemovesItAndLeavesTheOthers() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(4.0, in: &project)
        let untouched = project.clip(second)

        let left = project.cut(range: 1.5..<3.5, onTrack: project.tracks[0].id, voices: .none)

        // Something was cut, and nothing of it is left.
        #expect(left == [])
        #expect(project.clip(first) == nil)
        #expect(project.clip(second) == untouched)
        // The recording stays, so an undo has its sound.
        #expect(project.recordings.count == 2)
    }

    @Test func aCutAcrossTwoClipsShortensBoth() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(4.0, in: &project)
        change(second, in: &project) { $0.name = "Second" }
        let firstRecording = recordingID(of: first, in: project)
        let secondRecording = recordingID(of: second, in: project)

        let left = project.cut(range: 2.5..<4.5, onTrack: project.tracks[0].id, voices: .none)

        // Both are the clips they were, each with one end gone.
        #expect(left == [first, second])
        #expect(project.tracks[0].clips.map(\.id) == [first, second])
        #expect(project.clip(second)?.name == "Second")
        #expect(heard(project) == [
            Heard(recording: firstRecording, song: 96_000, offset: 0, length: 24_000),
            Heard(recording: secondRecording, song: 216_000, offset: 24_000, length: 24_000),
        ])
    }

    @Test func aCutThatTouchesNoClipChangesNothing() {
        var project = emptySong()
        record(2.0, in: &project)
        project.addTrack()
        record(6.0, in: &project, track: 1)
        let untouched = project
        let track = project.tracks[0].id

        // Beside the clip, ending exactly where it starts, on the other track's clip, with no length, nowhere.
        #expect(project.cut(range: 5.0..<7.0, onTrack: track, voices: .none) == nil)
        #expect(project.cut(range: 1.0..<2.0, onTrack: track, voices: .none) == nil)
        #expect(project.cut(range: 2.5..<2.5, onTrack: track, voices: .none) == nil)
        #expect(project.cut(range: 2.0..<3.0, onTrack: UUID(), voices: .none) == nil)
        #expect(project == untouched)
    }

    @Test func aCutInTheGapOfAJoinedClipGivesTwoClipsWithEverySampleLeft() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(4.0, in: &project)
        let joined = project.joinClips([first, second], voices: .none)!
        let before = heard(project)

        let left = project.cut(range: 3.2..<3.8, onTrack: project.tracks[0].id, voices: .none)

        #expect(left?.count == 2)
        #expect(left?.first == joined)
        #expect(project.tracks[0].clips.count == 2)
        #expect(project.tracks[0].clips.allSatisfy { $0.segments.count == 1 })
        #expect(heard(project) == before)
    }

    // MARK: Join

    @Test func aJoinOfThreeClipsKeepsTheGaps() {
        var project = emptySong()
        // Recorded out of order, and chosen in no order: the song decides which part is first.
        let third = record(6.0, in: &project)
        let first = record(2.0, in: &project)
        let second = record(4.0, in: &project)
        change(first, in: &project) { clip in
            clip.name = "First"
            clip.text = "one"
            clip.feel = .triplets
        }
        change(second, in: &project) { clip in
            clip.name = "Second"
            clip.text = "two"
        }
        let before = heard(project)
        #expect(before.count == 3)

        #expect(project.canJoin([third, first, second]))
        let joined = project.joinClips([third, first, second], voices: .none)

        #expect(joined == first)
        #expect(project.tracks[0].clips.count == 1)
        let clip = project.tracks[0].clips[0]
        #expect(clip.id == first)
        #expect(clip.name == "First")
        #expect(clip.feel == .triplets)
        #expect(clip.text == "one two")
        #expect(clip.segments.count == 3)
        #expect(clip.segments.compactMap { project.start(of: $0) } == [2.0, 4.0, 6.0])
        #expect(project.start(of: clip) == 2.0)
        #expect(project.end(of: clip) == 7.0)
        // The parts are heard where they were, with the silence between them.
        #expect(heard(project) == before)
    }

    @Test func aJoinWithAnotherClipBetweenIsRefused() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let between = record(4.0, in: &project)
        let last = record(6.0, in: &project)
        let untouched = project

        #expect(!project.canJoin([first, last]))
        #expect(project.joinClips([first, last], voices: .none) == nil)
        #expect(project == untouched)
        // With the one between chosen too, or as neighbours, they can be joined.
        #expect(project.canJoin([first, between, last]))
        #expect(project.canJoin([first, between]))
    }

    @Test func aJoinAcrossTracksOrOfTooFewClipsIsRefused() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        project.addTrack()
        let other = record(4.0, in: &project, track: 1)
        let untouched = project

        #expect(!project.canJoin([first, other]))
        #expect(project.joinClips([first, other], voices: .none) == nil)
        #expect(!project.canJoin([first]))
        #expect(!project.canJoin([]))
        #expect(!project.canJoin([first, UUID()]))
        #expect(project == untouched)
    }

    @Test func aJoinOfClipsOnTopOfEachOtherIsRefused() {
        // Two lines that overlap by 0.4 s, as when a longer take of one of them was chosen: both are shown
        // and heard. One clip cannot hold two sounds at the same place.
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(3.0, in: &project)
        project.tracks[0].clips[1].segments[0].offsetSamples = -19_200
        project.normalizeTakes()

        #expect(!project.canJoin([first, second]))
    }

    @Test func aJoinOfAMovedClipWithAnUnmovedOneLeavesBothWhereTheyWere() {
        var project = emptySong()
        let unmoved = record(2.0, in: &project)
        let moved = record(4.0, in: &project)
        // Moved a tenth of a second later.
        change(moved, in: &project) { $0.segments[0].offsetSamples = 4_800 }
        let before = heard(project)

        let joined = project.joinClips([unmoved, moved], voices: .none)!

        let segments = project.clip(joined)!.segments
        #expect(segments.map(\.offsetSamples) == [0, 4_800])
        #expect(segments.compactMap { project.start(of: $0) } == [2.0, 4.1])
        #expect(heard(project) == before)
    }

    @Test func aJoinOfClipsWithDifferentVolumesKeepsEveryPartAsLoudAsItWas() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(4.0, in: &project)
        // The first clip plays at -3 + 2 = -1 dB.
        change(first, in: &project) { clip in
            clip.gainDb = 2
            clip.normalizeGainDb = -3
        }
        // The second at -4 dB, and its segment 1 dB above that: -3 dB.
        change(second, in: &project) { clip in
            clip.gainDb = -4
            clip.segments[0].gainDb = 1
        }

        let id = project.joinClips([first, second], voices: .none)!
        let joined = project.clip(id)!

        // The clip keeps the first one's volume.
        #expect(joined.gainDb == 2)
        #expect(joined.normalizeGainDb == -3)
        // Clip and segment together are what each part had before: -1 dB and -3 dB.
        let clipGain = (joined.normalizeGainDb ?? 0) + joined.gainDb
        #expect(joined.segments.map { clipGain + $0.gainDb } == [-1, -3])
    }

    @Test func aJoinedClipIsMutedOnlyWhenEveryPartWas() {
        var project = emptySong()
        let first = record(2.0, in: &project)
        let second = record(4.0, in: &project)
        project.setClips([first], muted: true)
        var allMuted = project
        allMuted.setClips([second], muted: true)

        let joined = project.joinClips([first, second], voices: .none)!
        let joinedOfMuted = allMuted.joinClips([first, second], voices: .none)!
        #expect(project.clip(joined)?.muted == false)
        #expect(allMuted.clip(joinedOfMuted)?.muted == true)
    }

    // MARK: Takes

    /// One line recorded three times at the same place, with the second take chosen.
    private func lineWithThreeTakes() -> (project: Project, takes: [UUID]) {
        var project = emptySong()
        let takes = [record(2.0, in: &project), record(2.0, in: &project), record(2.0, in: &project)]
        project.normalizeTakes()
        project.setActiveTake(takes[1])
        return (project, takes)
    }

    /// Checks that a clip is one of three takes, and that the take heard plays the given recording.
    private func expectThreeTakes(of clip: UUID, heard recording: UUID, in project: Project) {
        let takes = project.takes(of: clip)
        #expect(takes.count == 3)
        #expect(takes.filter(\.isActiveTake).map { $0.segments[0].recordingID } == [recording])
        // In the order recorded, as before.
        #expect(takes.map { $0.segments[0].recordingID } == project.recordings.map(\.id))
    }

    @Test func aSplitOfAClipWithThreeTakesSplitsEveryTake() {
        var (project, takes) = lineWithThreeTakes()
        let chosen = recordingID(of: takes[1], in: project)

        let pieces = project.splitClip(takes[1], at: 2.5, voices: .none)!

        #expect(project.tracks[0].clips.count == 6)
        expectThreeTakes(of: pieces.first, heard: chosen, in: project)
        expectThreeTakes(of: pieces.second, heard: chosen, in: project)
        #expect(project.takes(of: pieces.first).allSatisfy { project.end(of: $0) == 2.5 })
        #expect(project.takes(of: pieces.second).allSatisfy { project.start(of: $0) == 2.5 })
        // The rule of one take heard per line already holds: putting the takes right changes nothing.
        var normalized = project
        normalized.normalizeTakes()
        #expect(normalized == project)
        // Only the chosen take is heard, all of it.
        #expect(heard(project) == [Heard(recording: chosen, song: 96_000, offset: 0, length: 48_000)])
    }

    @Test func aCutOutOfAClipWithThreeTakesCutsEveryTake() {
        var (project, takes) = lineWithThreeTakes()
        let chosen = recordingID(of: takes[1], in: project)

        let left = project.cut(range: 2.25..<2.75, onTrack: project.tracks[0].id, voices: .none)!

        #expect(left.count == 6)
        #expect(project.tracks[0].clips.count == 6)
        let second = project.tracks[0].clips.first { $0.id != takes[1] && $0.isActiveTake }!
        expectThreeTakes(of: takes[1], heard: chosen, in: project)
        expectThreeTakes(of: second.id, heard: chosen, in: project)
        #expect(project.takes(of: takes[1]).allSatisfy { project.end(of: $0) == 2.25 })
        #expect(project.takes(of: second.id).allSatisfy { project.start(of: $0) == 2.75 })
        var normalized = project
        normalized.normalizeTakes()
        #expect(normalized == project)
        #expect(heard(project) == [
            Heard(recording: chosen, song: 96_000, offset: 0, length: 12_000),
            Heard(recording: chosen, song: 132_000, offset: 36_000, length: 12_000),
        ])
    }

    @Test func aTakeThatDoesNotReachTheSplitIsLeftWhole() {
        // The second take starts 0.3 s after the first, and the split is before it starts.
        var project = emptySong()
        let early = record(2.0, in: &project)
        let late = record(2.3, in: &project, aimedAt: 2.0)
        project.normalizeTakes()
        project.setActiveTake(early)
        var whole = project.clip(late)

        let pieces = project.splitClip(early, at: 2.2, voices: .none)!

        #expect(project.tracks[0].clips.count == 3)
        // It is not cut. It lies after the split, so its line is now that of the second piece.
        whole?.line = project.clip(pieces.second)!.line
        #expect(project.clip(late) == whole)
        #expect(project.clip(pieces.second)!.line != project.clip(pieces.first)!.line)
        // The waiting take is a take of the piece it lies on, and still waits.
        #expect(project.takeCount(of: pieces.first) == 1)
        #expect(project.takes(of: pieces.second).map(\.id) == [pieces.second, late])
        var normalized = project
        normalized.normalizeTakes()
        #expect(normalized == project)
    }

    @Test func aJoinLeavesTheWaitingTakesAsTakesOfTheJoinedClip() {
        var project = emptySong()
        let waiting = record(2.0, in: &project)
        let first = record(2.0, in: &project)
        let waitingBehindSecond = record(3.2, 0.4, in: &project)
        let second = record(3.2, 0.5, in: &project)
        project.normalizeTakes()
        #expect(project.clip(waiting)?.isActiveTake == false)
        #expect(project.clip(waitingBehindSecond)?.isActiveTake == false)
        let untouched = project.clip(waiting)

        // A waiting take is not shown, so it can neither be joined nor be in the way.
        #expect(!project.canJoin([waiting, second]))
        let joined = project.joinClips([first, second], voices: .none)

        #expect(joined == first)
        #expect(project.clip(waiting) == untouched)
        // The take that waited behind the second part waits behind the joined clip now. It is not left as a
        // line of its own, which would bring it forward on top of the joined clip.
        #expect(project.takes(of: first).map(\.id) == [waiting, first, waitingBehindSecond])
        #expect(project.clip(waitingBehindSecond)?.isActiveTake == false)
        #expect(project.clip(waitingBehindSecond)?.segments[0].lengthSamples == 19_200)
        var normalized = project
        normalized.normalizeTakes()
        #expect(normalized == project)
    }

    // MARK: Nothing moves

    @Test func noSampleThatIsLeftIsHeardAnywhereElseAfterAnyOfThem() {
        // Two clips, the second moved a tenth of a second later, and a recording whose start is not on a whole
        // sample of the song.
        var project = emptySong()
        let first = record(2.00001, in: &project)
        let second = record(4.0, in: &project)
        change(second, in: &project) { $0.segments[0].offsetSamples = 4_800 }
        let firstRecording = recordingID(of: first, in: project)
        let secondRecording = recordingID(of: second, in: project)
        let probes = [(firstRecording, 0), (firstRecording, 10_000), (firstRecording, 40_000), (firstRecording, 47_999),
                      (secondRecording, 0), (secondRecording, 30_000), (secondRecording, 47_999)]
        let before = probes.map { places(ofSample: $0.1, of: $0.0, in: project) }
        #expect(before.allSatisfy { $0.count == 1 })
        let offsets = [firstRecording: 0, secondRecording: 4_800]

        /// Every probe that is still in a clip sits where it sat, and no segment was moved.
        func expectNothingMoved(_ project: Project, gone: Set<Int> = []) {
            for (index, probe) in probes.enumerated() {
                let now = places(ofSample: probe.1, of: probe.0, in: project)
                #expect(now == (gone.contains(index) ? [] : before[index]))
            }
            for segment in project.tracks.flatMap(\.clips).flatMap(\.segments) {
                #expect(segment.offsetSamples == offsets[segment.recordingID])
            }
        }

        let pieces = project.splitClip(first, at: 2.5, voices: .none)!
        expectNothingMoved(project)

        // 2.1 s to 2.3 s takes the probe at sample 10,000 of the first recording, and nothing else.
        project.cut(range: 2.1..<2.3, onTrack: project.tracks[0].id, voices: .none)
        expectNothingMoved(project, gone: [1])

        let all = Set(project.tracks[0].clips.map(\.id))
        #expect(all.count == 4)
        #expect(all.contains(pieces.second))
        #expect(project.joinClips(all, voices: .none) == first)
        expectNothingMoved(project, gone: [1])

        // 4.0 s to 4.2 s takes the first tenth of a second of the moved clip, which starts at 4.1 s.
        project.cut(range: 4.0..<4.2, onTrack: project.tracks[0].id, voices: .none)
        expectNothingMoved(project, gone: [1, 4])
    }
}

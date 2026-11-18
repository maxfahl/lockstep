import Foundation
import Testing
@testable import LockstepCore

/// A twenty-second song with one empty track, "Track 1".
private func emptySong() -> Project {
    Project(songLengthSamples: 960_000)
}

/// Records a clip the way the app does: a new recording that begins `start` seconds into the song and is
/// `seconds` long, with the samples `voiced` of it as the clip (all of it when left out). Returns the clip's id.
@discardableResult
private func record(
    _ start: Double,
    _ seconds: Double = 1,
    voiced: Range<Int>? = nil,
    in project: inout Project,
    aimedAt aim: Double? = nil
) -> UUID {
    let recording = Recording(lengthSamples: Int((seconds * Lockstep.sampleRate).rounded()), rawStart: start)
    return project.addRecording(
        recording,
        samples: voiced ?? 0..<recording.lengthSamples,
        asClipOn: project.tracks[0].id,
        aim: aim.map { RecordAim(place: $0) }, voices: .none
    )!
}

/// The sample of the song on which a sample of a clip's first recording is heard.
private func place(ofSample sample: Int, in clip: Clip, of project: Project) -> Int {
    let segment = clip.segments[0]
    return project.recording(segment.recordingID)!.songSample(ofSample: sample, offsetSamples: segment.offsetSamples)
}

@Suite("Trimming a clip by an edge")
struct ProjectTrimsTests {
    @Test("The start moves and no sound moves in the song")
    func startMovesAlone() {
        var project = emptySong()
        let id = record(2, 2, in: &project)
        let before = project.clip(id)!

        // Half a second in from the start, which is at second 2.
        let landed = project.trimClip(id, edge: .start, toSongSample: 120_000, voices: .none)

        let after = project.clip(id)!
        #expect(landed == 120_000)
        #expect(after.segments[0].inSample == 24_000)
        #expect(after.segments[0].outSample == before.segments[0].outSample)
        #expect(after.segments[0].offsetSamples == before.segments[0].offsetSamples)
        #expect(project.edgeSample(of: id, edge: .start) == 120_000)
        #expect(project.edgeSample(of: id, edge: .end) == 192_000)
        // A sample that is still played is heard where it was.
        #expect(place(ofSample: 50_000, in: after, of: project) == place(ofSample: 50_000, in: before, of: project))
        // The recording is as it was.
        #expect(project.recordings[0].lengthSamples == 96_000)
    }

    @Test("The end moves and the start stays")
    func endMovesAlone() {
        var project = emptySong()
        let id = record(2, 2, in: &project)

        #expect(project.trimClip(id, edge: .end, toSongSample: 150_000, voices: .none) == 150_000)

        let segment = project.clip(id)!.segments[0]
        #expect(segment.inSample == 0)
        #expect(segment.outSample == 54_000)
    }

    @Test("Inwards an edge stops when 50 ms are left")
    func stopsAtShortPiece() {
        var project = emptySong()
        let id = record(2, 2, in: &project)

        // Far past the other edge.
        #expect(project.trimClip(id, edge: .start, toSongSample: 500_000, voices: .none) == 192_000 - 2_400)
        #expect(project.clip(id)!.segments[0].lengthSamples == Project.trimMinimumSamples)

        var other = emptySong()
        let otherID = record(2, 2, in: &other)
        #expect(other.trimClip(otherID, edge: .end, toSongSample: 0, voices: .none) == 96_000 + 2_400)
        #expect(other.clip(otherID)!.segments[0].lengthSamples == Project.trimMinimumSamples)
    }

    @Test("Outwards an edge goes as far as the recording holds sound, and no further")
    func growsBackToTheRecording() {
        var project = emptySong()
        // A recording of three seconds, of which the clip is the second in the middle.
        let id = record(2, 3, voiced: 48_000..<96_000, in: &project)
        #expect(project.trimRange(of: id, edge: .start) == 96_000...(192_000 - 2_400))
        #expect(project.trimRange(of: id, edge: .end) == (144_000 + 2_400)...240_000)

        #expect(project.trimClip(id, edge: .start, toSongSample: 0, voices: .none) == 96_000)
        #expect(project.trimClip(id, edge: .end, toSongSample: 900_000, voices: .none) == 240_000)
        let segment = project.clip(id)!.segments[0]
        #expect(segment.inSample == 0)
        #expect(segment.outSample == 144_000)

        // Shortened and dragged back out: all of it is there again.
        project.trimClip(id, edge: .end, toSongSample: 150_000, voices: .none)
        #expect(project.trimClip(id, edge: .end, toSongSample: 240_000, voices: .none) == 240_000)
        #expect(project.clip(id)!.segments[0].outSample == 144_000)
    }

    @Test("Outwards an edge stops at the start and the end of the song")
    func staysInsideTheSong() {
        var project = emptySong()
        // The recording began half a second before the song and runs a second past its end.
        let early = record(-0.5, 2, voiced: 48_000..<72_000, in: &project)
        let late = record(19, 2, voiced: 12_000..<24_000, in: &project)

        #expect(project.trimClip(early, edge: .start, toSongSample: -100_000, voices: .none) == 0)
        #expect(project.clip(early)!.segments[0].inSample == 24_000)
        #expect(project.trimClip(late, edge: .end, toSongSample: 2_000_000, voices: .none) == 960_000)
    }

    @Test("Outwards an edge stops where the song is cut away")
    func staysInsideWhatIsLeftOfTheSong() {
        var project = emptySong()
        // One second is cut away at each end: seconds 1 to 19 are left.
        project.songPlace = SongPlace(cutStartSamples: 48_000, cutEndSamples: 48_000)
        // Both recordings hold sound that lies in a part of the song that is cut away.
        let early = record(0.5, 2, voiced: 48_000..<72_000, in: &project)
        let late = record(18, 2, voiced: 12_000..<24_000, in: &project)

        #expect(project.trimClip(early, edge: .start, toSongSample: 0, voices: .none) == 48_000)
        #expect(project.trimClip(late, edge: .end, toSongSample: 960_000, voices: .none) == 912_000)
    }

    @Test("An edge that is already where it is asked to be changes nothing")
    func samePlaceIsNothing() {
        var project = emptySong()
        let id = record(2, 2, in: &project)
        let before = project

        #expect(project.trimClip(id, edge: .start, toSongSample: 96_000, voices: .none) == nil)
        // The start is at the first sample of the recording, so it cannot go further out.
        #expect(project.trimClip(id, edge: .start, toSongSample: 0, voices: .none) == nil)
        #expect(project.trimClip(UUID(), edge: .start, toSongSample: 100_000, voices: .none) == nil)
        #expect(project == before)
    }

    @Test("In a joined clip an edge stays in its own piece")
    func joinedClipStopsAtTheJoin() {
        var project = emptySong()
        let first = record(2, 1, in: &project)
        let second = record(4, 1, in: &project)
        let joined = project.joinClips([first, second], voices: .none)!
        let before = project.clip(joined)!
        #expect(before.segments.count == 2)

        // The first piece is second 2 to 3 and the second one second 4 to 5.
        #expect(project.trimRange(of: joined, edge: .start) == 96_000...(144_000 - 2_400))
        #expect(project.trimRange(of: joined, edge: .end) == (192_000 + 2_400)...240_000)

        #expect(project.trimClip(joined, edge: .start, toSongSample: 230_000, voices: .none) == 144_000 - 2_400)
        #expect(project.trimClip(joined, edge: .end, toSongSample: 100_000, voices: .none) == 192_000 + 2_400)
        let after = project.clip(joined)!
        #expect(after.segments.count == 2)
        #expect(after.segments[0].outSample == before.segments[0].outSample)
        #expect(after.segments[1].inSample == before.segments[1].inSample)
    }

    @Test("Only the take that is shown is trimmed, and the takes behind it keep their sound")
    func takesKeepTheirSound() {
        var project = emptySong()
        let older = record(2, 2, in: &project)
        let newer = record(2, 2, in: &project)
        project.normalizeTakes()
        #expect(project.clip(newer)!.isActiveTake)
        #expect(!project.clip(older)!.isActiveTake)

        // A take that waits has no edge to take hold of.
        #expect(project.trimRange(of: older, edge: .start) == nil)
        #expect(project.trimClip(older, edge: .start, toSongSample: 120_000, voices: .none) == nil)

        #expect(project.trimClip(newer, edge: .start, toSongSample: 120_000, voices: .none) == 120_000)
        project.normalizeTakes()
        #expect(project.clip(older)!.segments[0].inSample == 0)
        #expect(project.clip(older)!.segments[0].outSample == 96_000)
        // A clip keeps its line, so they are still one line with the same take shown.
        #expect(project.takeCount(of: newer) == 2)
        #expect(project.clip(newer)!.isActiveTake)
        #expect(!project.clip(older)!.isActiveTake)
    }

    @Test("A take stays in its line however short it is trimmed")
    func trimmedTakeStaysInItsLine() {
        var project = emptySong()
        // Second 2 to 4, and a second take of the same line whose voice started at second 2.8.
        let older = record(2, 2, in: &project)
        let newer = record(2.8, 2, in: &project, aimedAt: 2)
        project.normalizeTakes()
        #expect(project.takeCount(of: older) == 2)
        project.setActiveTake(older)

        // The shown take now ends at second 3: it shares 0.2 seconds of its one second with the other.
        // Before each clip kept its line, that made the two stop being takes of each other.
        #expect(project.trimClip(older, edge: .end, toSongSample: 144_000, voices: .none) == 144_000)
        #expect(project.trimClip(older, edge: .start, toSongSample: 120_000, voices: .none) == 120_000)
        project.normalizeTakes()

        #expect(project.takes(of: older).map(\.id) == [older, newer])
        #expect(project.clip(older)!.isActiveTake)
        #expect(!project.clip(newer)!.isActiveTake)
        #expect(project.clip(newer)!.segments[0].lengthSamples == 96_000)
    }

    @Test("A clip the safe limit holds back is as loud after a trim as before")
    func heldBackClipKeepsItsLoudness() {
        var project = emptySong()
        let id = record(2, 2, in: &project)
        for index in project.tracks[0].clips.indices {
            project.tracks[0].clips[index].gainDb = 12
        }
        // The loud part is the first half second, which the trim takes away.
        let peaks: RecordingPeak = { _, samples in samples.lowerBound < 24_000 ? 1.0 : 0.1 }
        let before = project.clip(id)!.appliedGain(peaks: peaks)
        #expect(before.heldBackDb > 0)

        project.trimClip(id, edge: .start, toSongSample: 96_000 + 24_000, peaks: peaks, voices: .none)

        let after = project.clip(id)!
        let played = after.appliedGain(peaks: peaks).db + after.segments[0].gainDb
        #expect(abs(played - before.db) < 1e-9)
    }
}

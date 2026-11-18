import Foundation
import Testing
@testable import LockstepCore

@Suite("ProjectMarkers")
struct ProjectMarkersTests {
    /// A twenty-second song with one clip on its track: a recording that begins `start`
    /// seconds into the song and is two seconds long, all of it in the clip.
    private func songWithAClip(
        start: Double = 10, delay: Double = 0, excluded: [Int] = []
    ) -> (project: Project, clip: UUID, recording: UUID) {
        var project = Project(songLengthSamples: 960_000)
        let recording = Recording(lengthSamples: 96_000, rawStart: start, delay: delay, excludedMarkers: excluded)
        let clip = project.addRecording(recording, samples: 0..<96_000, asClipOn: project.tracks[0].id, voices: .none)!
        return (project, clip, recording.id)
    }

    private func markers(_ samples: [Int]) -> [SyllableMarker] {
        samples.map { SyllableMarker(sample: $0, strength: 20) }
    }

    @Test func afterASplitEachMarkerIsInExactlyOnePiece() throws {
        var (project, clip, recording) = songWithAClip()
        // One marker falls exactly on the sample where the clip is cut, one second in.
        let all = [recording: markers([4800, 47_999, 48_000, 90_000])]
        #expect(project.markers(in: project.clip(clip)!, allMarkers: all).map(\.sample) == [4800, 47_999, 48_000, 90_000])

        let split = project.splitClip(clip, at: 11, voices: .none)
        let pieces = try #require(split)
        let first = project.markers(in: project.clip(pieces.first)!, allMarkers: all)
        let second = project.markers(in: project.clip(pieces.second)!, allMarkers: all)
        #expect(first.map(\.sample) == [4800, 47_999])
        #expect(second.map(\.sample) == [48_000, 90_000])
        // A cut moves nothing: every marker sounds where it did.
        #expect(first.map(\.songTime) == [10.1, 10 + 47_999.0 / 48_000])
        #expect(second.map(\.songTime) == [11, 11.875])
        #expect(first.allSatisfy { $0.recordingID == recording })
    }

    @Test func markersOutsideTheClipsPartOfTheRecordingAreLeftOut() {
        var project = Project(songLengthSamples: 960_000)
        // The clip covers only the voice, from 0.2 s to 1.8 s of the recording.
        let recording = Recording(lengthSamples: 96_000, rawStart: 10)
        let clip = project.addRecording(recording, samples: 9600..<86_400, asClipOn: project.tracks[0].id, voices: .none)!
        let all = [recording.id: markers([4800, 9600, 48_000, 86_399, 86_400, 90_000])]

        #expect(project.markers(in: project.clip(clip)!, allMarkers: all).map(\.sample) == [9600, 48_000, 86_399])
        // A recording whose markers are not found yet gives none, and so does one the project lacks.
        #expect(project.markers(in: project.clip(clip)!, allMarkers: [:]).isEmpty)
        let stray = Clip(segments: [Segment(recordingID: UUID(), inSample: 0, outSample: 96_000)])
        #expect(project.markers(in: stray, allMarkers: all).isEmpty)
    }

    @Test func songTimeFollowsTheDelayAndAMove() throws {
        var (project, clip, recording) = songWithAClip(start: 10, delay: 0.05)
        let all = [recording: markers([24_000])]
        // Recorded at 10 s, moved back by the measured 50 ms: half a second in is 10.45 s.
        var marker = try #require(project.markers(in: project.clip(clip)!, allMarkers: all).first)
        #expect(abs(marker.songTime - 10.45) < 1e-9)

        // The clip is dragged half a second later. The marker goes with it and stays the same marker.
        project.moveClips([clip], bySamples: 24_000, trackSteps: 0, voices: .none)
        marker = try #require(project.markers(in: project.clip(clip)!, allMarkers: all).first)
        #expect(abs(marker.songTime - 10.95) < 1e-9)
        #expect(marker.sample == 24_000)
    }

    @Test func aJoinedClipGivesTheMarkersOfAllItsParts() throws {
        var (project, clip, recording) = songWithAClip()
        let all = [recording: markers([4800, 60_000])]
        let split = project.splitClip(clip, at: 11, voices: .none)
        let pieces = try #require(split)
        let joinedID = project.joinClips([pieces.first, pieces.second], voices: .none)
        let joined = try #require(joinedID)
        let found = project.markers(in: project.clip(joined)!, allMarkers: all)
        #expect(found.map(\.sample) == [4800, 60_000])
        #expect(found.map(\.songTime) == [10.1, 11.25])
    }

    @Test func anExclusionFollowsItsMarkerWhenItShiftsByFourMilliseconds() {
        // Max excluded the marker that was at sample 48,000.
        let (project, clip, recording) = songWithAClip(excluded: [48_000])
        let stored = project.recording(recording)!

        // Found again, every marker lies 4 ms (192 samples) later.
        let shifted = markers([4800 + 192, 48_000 + 192, 90_000 + 192])
        #expect(stored.excludedSamples(among: shifted) == [48_192])
        let shown = project.markers(in: project.clip(clip)!, allMarkers: [recording: shifted])
        #expect(shown.map(\.isExcluded) == [false, true, false])

        // 4 ms earlier is the same marker too, and so is the unchanged position.
        #expect(stored.excludedSamples(among: markers([47_808, 90_000])) == [47_808])
        #expect(stored.excludedSamples(among: markers([48_000])) == [48_000])
    }

    @Test func anExclusionMatchesNothingTwentyMillisecondsAway() {
        let (project, clip, recording) = songWithAClip(excluded: [48_000])
        let stored = project.recording(recording)!

        // 20 ms (960 samples) away is another syllable.
        let shifted = markers([4800, 48_960, 90_000])
        #expect(stored.excludedSamples(among: shifted).isEmpty)
        let shown = project.markers(in: project.clip(clip)!, allMarkers: [recording: shifted])
        #expect(shown.map(\.isExcluded) == [false, false, false])
        // Exactly 10 ms away still counts, one sample more does not.
        #expect(stored.excludedSamples(among: markers([48_480])) == [48_480])
        #expect(stored.excludedSamples(among: markers([48_481])).isEmpty)
        #expect(stored.excludedSamples(among: []).isEmpty)
    }

    @Test func markersAreReadBackFromTheCacheOnlyForTheSameDetectorVersion() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockstep-marker-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = ProjectPackage(url: folder.appendingPathComponent("Song.lockstep", isDirectory: true))
        let id = UUID()
        let found = [SyllableMarker(sample: 24_024, strength: 23.5), SyllableMarker(sample: 36_024, strength: 8)]

        // Nothing is there yet.
        #expect(package.readMarkers(forRecording: id, version: 1) == nil)

        try package.writeMarkers(found, forRecording: id, version: 1)
        #expect(package.markersFile(forRecording: id).path.hasSuffix("cache/markers/\(id.uuidString).json"))
        #expect(package.readMarkers(forRecording: id, version: 1) == found)
        // A newer detector does not trust what an older one found.
        #expect(package.readMarkers(forRecording: id, version: 2) == nil)
        // Another recording has no file.
        #expect(package.readMarkers(forRecording: UUID(), version: 1) == nil)

        // A recording with no syllables keeps an empty list, which is not the same as no file.
        try package.writeMarkers([], forRecording: id, version: 1)
        #expect(package.readMarkers(forRecording: id, version: 1) == [])

        // A damaged file counts as missing.
        try Data("not markers".utf8).write(to: package.markersFile(forRecording: id))
        #expect(package.readMarkers(forRecording: id, version: 1) == nil)
    }
}

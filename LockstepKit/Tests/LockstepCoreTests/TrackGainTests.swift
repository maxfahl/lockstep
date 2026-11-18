import Foundation
import Testing
@testable import LockstepCore

@Suite("A track's own volume")
struct TrackGainTests {
    /// A clip that plays one stretch of a recording.
    private func clip(_ recording: Recording, _ samples: Range<Int>, gainDb: Double = 0) -> Clip {
        Clip(
            segments: [Segment(recordingID: recording.id, inSample: samples.lowerBound, outSample: samples.upperBound)],
            gainDb: gainDb
        )
    }

    // MARK: In the project file

    @Test func aProjectSavedBeforeTracksHadAVolumePlaysEveryTrackAsBefore() throws {
        let old = try JSONDecoder().decode(
            Project.self,
            from: Data(#"{"songName":"Old","version":1,"tracks":[{"name":"Track 1"},{"name":"Track 2","muted":true}]}"#.utf8)
        )
        #expect(old.tracks.map(\.gainDb) == [0, 0])
        #expect(old.tracks.map(\.muted) == [false, true])
    }

    @Test func theVolumeIsSavedAndReadBackForEachTrack() throws {
        var project = Project(songName: "Song", tracks: [Track(name: "Track 1"), Track(name: "Track 2")])
        project.setTrack(project.tracks[0].id, gainDb: -7.5)
        project.setTrack(project.tracks[1].id, gainDb: 4)
        let read = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(read.tracks.map(\.gainDb) == [-7.5, 4])
        #expect(read == project)
    }

    @Test func aVolumeOutsideTheRangeIsBroughtIntoIt() throws {
        let read = try JSONDecoder().decode(
            Project.self, from: Data(#"{"tracks":[{"name":"Loud","gainDb":40},{"name":"Quiet","gainDb":-90}]}"#.utf8)
        )
        #expect(read.tracks.map(\.gainDb) == [Track.gainRange.upperBound, Track.gainRange.lowerBound])
        var project = Project(songName: "Song")
        project.setTrack(project.tracks[0].id, gainDb: 99)
        #expect(project.tracks[0].gainDb == 12)
        #expect(Track(gainDb: .nan).gainDb == 0)
    }

    @Test func settingTheVolumeATrackHasChangesNothing() {
        var project = Project(songName: "Song")
        let trackID = project.tracks[0].id
        let same = project.setTrack(trackID, gainDb: 0)
        let new = project.setTrack(trackID, gainDb: 3)
        let again = project.setTrack(trackID, gainDb: 3)
        let noSuchTrack = project.setTrack(UUID(), gainDb: 3)
        #expect([same, new, again, noSuchTrack] == [false, true, false, false])
    }

    @Test func aDuplicatedTrackHasTheSameVolume() {
        var project = Project(songName: "Song", tracks: [Track(name: "Track 1", gainDb: -5)])
        let copy = project.duplicateTrack(project.tracks[0].id, withClips: false)
        #expect(copy.flatMap { project.track($0) }?.gainDb == -5)
    }

    // MARK: What is heard

    @Test func everyClipOfTheTrackIsPlayedThatMuchLouderAndNoOtherTrackIs() {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        // Two clips on the first track, one with a volume of its own, and one clip on the second.
        let first = Track(name: "Track 1", gainDb: 6, clips: [clip(recording, 0..<1_000), clip(recording, 2_000..<3_000, gainDb: -2)])
        let second = Track(name: "Track 2", clips: [clip(recording, 4_000..<5_000)])
        let project = Project(songLengthSamples: 480_000, tracks: [first, second], recordings: [recording])

        #expect(project.clipPlaybackPlan(from: 0, voices: .none).map(\.gainDb) == [6, 4, 0])
    }

    @Test func theTrackVolumeComesOnTopOfAClipTheSafeLimitHoldsBack() {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        // The recording peaks at 0.5, about -6 dBFS, so a clip asked 12 dB up is held at the safe limit.
        let peaks: RecordingPeak = { _, _ in 0.5 }
        let raised = clip(recording, 0..<1_000, gainDb: 12)
        let held = raised.appliedGain(peaks: peaks)
        #expect(held.isHeldBack)
        let project = Project(
            songLengthSamples: 480_000,
            tracks: [Track(name: "Track 1", gainDb: -10, clips: [raised])],
            recordings: [recording]
        )

        // The limit is worked out for the clip alone. The track's volume moves what is left of it.
        #expect(project.clipPlaybackPlan(from: 0, peaks: peaks, voices: .none).map(\.gainDb) == [held.db - 10])
    }

    // MARK: Send to DaVinci

    @Test func aClipIsExportedTheSameWhateverItsTracksVolume() throws {
        let recording = ClipExporterTests.recording()
        let sounds = [recording.id: ClipExporterTests.voice(96_000)]
        let peaks = ClipExporterTests.peaks(of: sounds)
        let clip = ClipExporterTests.clip(recording, 1_000..<41_000, gainDb: 2)
        let plain = ClipExporterTests.project(recording, [clip])
        var turnedUp = plain
        turnedUp.setTrack(turnedUp.tracks[0].id, gainDb: 9)

        let before = try #require(ClipExporter.export(clip.id, in: plain, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none))
        let after = try #require(ClipExporter.export(clip.id, in: turnedUp, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none))

        #expect(after == before)
        // The player does hear it: the same clip in the mix of the project is louder.
        let quiet = OfflineMix.render(plain, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none)
        let loud = OfflineMix.render(turnedUp, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none)
        #expect(loud != quiet)
    }
}

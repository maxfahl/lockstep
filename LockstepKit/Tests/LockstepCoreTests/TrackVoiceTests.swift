import Foundation
import Testing
@testable import LockstepCore

@Suite("A track's Voice: its knobs, the project file, where its files go, and what stands in")
struct TrackVoiceTests {
    /// An id that is the same in every run, so the saved text and the paths are too.
    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)"))
    }

    /// The tracks of a saved project, as the text says them.
    private func savedTracks(_ text: Data) throws -> [[String: Any]] {
        let saved = try #require(JSONSerialization.jsonObject(with: text) as? [String: Any])
        return try #require(saved["tracks"] as? [[String: Any]])
    }

    // MARK: The knobs

    @Test func aKnobOutsideItsRangeIsBroughtInsideAndOneBetweenTwoStepsToTheNearer() {
        #expect(VoiceKnobs(depth: 40, pitch: -9) == VoiceKnobs(depth: 15, pitch: -4))
        #expect(VoiceKnobs(depth: -40, pitch: 9) == VoiceKnobs(depth: -15, pitch: 4))
        #expect(VoiceKnobs(depth: 6, pitch: 1.3).pitch == 1.5)
        #expect(VoiceKnobs(depth: 6, pitch: 1.2).pitch == 1)
        #expect(VoiceKnobs(depth: 6, pitch: -2.75).pitch == -3)
        #expect(VoiceKnobs(depth: 6, pitch: .nan).pitch == 0)
        #expect(VoiceKnobs(depth: 6, pitch: .infinity).pitch == 4)
        #expect(VoiceKnobs.depth(clamped: 6.4) == 6)
        #expect(VoiceKnobs.depth(clamped: -1e30) == -15)
        #expect(VoiceKnobs.depth(clamped: .nan) == 0)

        // Also when a knob is turned on a value that is there already.
        var knobs = VoiceKnobs(depth: 6, pitch: -1)
        knobs.depth = -99
        knobs.pitch = 2.74
        #expect(knobs == VoiceKnobs(depth: -15, pitch: 2.5))
    }

    @Test func bothKnobsInTheMiddleIsNeutralAndASmallNegativePitchIsPlainZero() {
        #expect(VoiceKnobs().isNeutral)
        #expect(VoiceKnobs.neutral == VoiceKnobs(depth: 0, pitch: 0))
        #expect(!VoiceKnobs(depth: 1, pitch: 0).isNeutral)
        #expect(!VoiceKnobs(depth: 0, pitch: -0.5).isNeutral)

        let almost = VoiceKnobs(depth: 0, pitch: -0.2)
        #expect(almost.isNeutral)
        #expect(almost.pitch.sign == .plus)
        #expect(almost.folderName == "d+00p+0.0")
    }

    @Test func aSettingIsAFolderNameWithBothSignsAndAlwaysAsManyDigits() {
        #expect(VoiceKnobs(depth: 6, pitch: -1).folderName == "d+06p-1.0")
        #expect(VoiceKnobs(depth: -6, pitch: 1.5).folderName == "d-06p+1.5")
        #expect(VoiceKnobs(depth: 15, pitch: 4).folderName == "d+15p+4.0")
        #expect(VoiceKnobs(depth: -15, pitch: -0.5).folderName == "d-15p-0.5")
        #expect(VoiceKnobs.neutral.folderName == "d+00p+0.0")

        // No two settings share a name.
        var names: Set<String> = []
        for depth in VoiceKnobs.depthRange {
            for step in -8...8 {
                names.insert(VoiceKnobs(depth: depth, pitch: Double(step) * VoiceKnobs.pitchStep).folderName)
            }
        }
        #expect(names.count == 31 * 17)
        #expect(names.allSatisfy { $0.count == 9 })
    }

    // MARK: In the project file

    @Test func aProjectSavedBeforeTracksHadAVoiceReadsAsBefore() throws {
        let old = try JSONDecoder().decode(
            Project.self,
            from: Data(#"{"songName":"Old","version":1,"tracks":[{"name":"Track 1"},{"name":"Track 2","muted":true}]}"#.utf8)
        )
        #expect(old.tracks.map(\.voice) == [nil, nil])
        #expect(old.tracks.map(\.muted) == [false, true])
        #expect(Track(name: "New").voice == nil)
    }

    @Test func aProjectInWhichNoTrackHasAVoiceIsWrittenExactlyAsBefore() throws {
        // What Lockstep wrote before a track could have a Sound, an effect or a Voice.
        let before = try fixture("project-before-sounds.json")
        let read = try ProjectPackage.decode(before)
        #expect(read.tracks.count == 2)
        #expect(read.tracks.allSatisfy { $0.voice == nil })
        #expect(try ProjectPackage.encode(read) == before)
        #expect(try savedTracks(ProjectPackage.encode(read)).allSatisfy { $0["voice"] == nil })
    }

    @Test func aVoiceIsWrittenWithItsKnobsBesideItsNameAndReadBackTheSame() throws {
        var project = Project(
            songName: "Song",
            tracks: [Track(id: id(1), name: "Track 1"), Track(id: id(2), name: "Track 2"), Track(id: id(3), name: "Track 3")]
        )
        project.tracks[0].voice = TrackVoice(name: "Darker", knobs: VoiceKnobs(depth: 6, pitch: -1))
        project.tracks[1].voice = TrackVoice(isOn: false, knobs: VoiceKnobs(depth: -3, pitch: 1.5), natural: true)

        let text = try ProjectPackage.encode(project)
        let read = try ProjectPackage.decode(text)
        #expect(read == project)
        #expect(read.tracks[0].voice == TrackVoice(isOn: true, name: "Darker", knobs: VoiceKnobs(depth: 6, pitch: -1), natural: false))
        #expect(read.tracks[1].voice == TrackVoice(isOn: false, name: "Custom", knobs: VoiceKnobs(depth: -3, pitch: 1.5), natural: true))
        #expect(read.tracks[2].voice == nil)

        let tracks = try savedTracks(text)
        let first = try #require(tracks[0]["voice"] as? [String: Any])
        #expect(Set(first.keys) == ["on", "name", "depth", "pitch"])
        #expect(first["on"] as? Bool == true)
        #expect(first["name"] as? String == "Darker")
        #expect(first["depth"] as? Int == 6)
        #expect(first["pitch"] as? Double == -1)
        // Switched off, it stays on the track with its knobs. Natural is said only when it is on.
        let second = try #require(tracks[1]["voice"] as? [String: Any])
        #expect(Set(second.keys) == ["on", "name", "depth", "pitch", "natural"])
        #expect(second["on"] as? Bool == false)
        #expect(second["depth"] as? Int == -3)
        #expect(second["pitch"] as? Double == 1.5)
        #expect(second["natural"] as? Bool == true)
        #expect(tracks[2]["voice"] == nil)
    }

    @Test func aVoiceWrittenByHandGetsItsDefaultsAndKnobsInsideTheirRange() throws {
        let text = """
        {"tracks":[
          {"name":"Short","voice":{"depth":40,"pitch":1.3}},
          {"name":"Whole","voice":{"on":false,"name":"Deeper","depth":10,"pitch":-2,"natural":true}},
          {"name":"Empty","voice":{"name":"","depth":6.4}}
        ]}
        """
        let tracks = try JSONDecoder().decode(Project.self, from: Data(text.utf8)).tracks
        #expect(tracks[0].voice == TrackVoice(isOn: true, name: "Custom", knobs: VoiceKnobs(depth: 15, pitch: 1.5), natural: false))
        #expect(tracks[1].voice == TrackVoice(isOn: false, name: "Deeper", knobs: VoiceKnobs(depth: 10, pitch: -2), natural: true))
        #expect(tracks[2].voice == TrackVoice(isOn: true, name: "Custom", knobs: VoiceKnobs(depth: 6, pitch: 0), natural: false))
    }

    @Test func aVoiceIsHeardOnlyWhenItIsOnAndAKnobIsTurned() {
        let darker = VoiceKnobs(depth: 6, pitch: -1)
        #expect(TrackVoice(knobs: darker).isHeard)
        #expect(!TrackVoice(isOn: false, knobs: darker).isHeard)
        #expect(!TrackVoice(knobs: .neutral).isHeard)
        #expect(TrackVoice(knobs: darker).name == TrackVoice.customName)
    }

    // MARK: Where the files go

    @Test func theFileOfAVoiceIsNamedByItsWayItsSettingAndItsRecording() {
        let package = ProjectPackage(url: URL(filePath: "/Projects/Song.lockstep"))
        #expect(package.voicesFolder.path == "/Projects/Song.lockstep/cache/voices")

        // A negative Depth and a half step of Pitch.
        let fast = VoiceKey(recordingID: id(7), knobs: VoiceKnobs(depth: -6, pitch: 1.5), way: VoiceWay(method: "world", revision: 3))
        #expect(package.voiceFile(for: fast).path
            == "/Projects/Song.lockstep/cache/voices/world-r3/d-06p+1.5/00000000-0000-0000-0000-000000000007.wav")

        // A Natural way ends with the start of its sample's id.
        let sample = UUID(uuidString: "4F2A9C1E-6D3B-4A7F-9E05-B1C8D2E3F4A6")!
        let natural = VoiceKey(
            recordingID: id(7),
            knobs: VoiceKnobs(depth: 6, pitch: -1),
            way: VoiceWay(method: "seed-vc", revision: 1, sampleID: sample)
        )
        #expect(package.voiceFile(for: natural).path
            == "/Projects/Song.lockstep/cache/voices/seed-vc-r1-4f2a9c1e/d+06p-1.0/00000000-0000-0000-0000-000000000007.wav")

        // A file that is being written lies beside the place it will have, under its job's name.
        let partial = package.partialVoiceFile(for: natural, job: id(9))
        #expect(partial.deletingLastPathComponent() == package.voiceFile(for: natural).deletingLastPathComponent())
        #expect(partial.lastPathComponent
            == "00000000-0000-0000-0000-000000000007.00000000-0000-0000-0000-000000000009.partial")
        #expect(partial.pathExtension == ProjectPackage.partialVoiceExtension)
    }

    @Test func anotherWayRevisionSampleOrSettingIsAnotherFile() {
        let package = ProjectPackage(url: URL(filePath: "/Projects/Song.lockstep"))
        let knobs = VoiceKnobs(depth: 6, pitch: -1)
        let world = VoiceWay(method: "world", revision: 1)
        let ways = [
            world,
            VoiceWay(method: "world", revision: 2),
            VoiceWay(method: "rubberband", revision: 1),
            VoiceWay(method: "seed-vc", revision: 1, sampleID: id(1)),
            VoiceWay(method: "seed-vc", revision: 1, sampleID: UUID(uuidString: "4F2A9C1E-6D3B-4A7F-9E05-B1C8D2E3F4A6")!),
        ]
        var files = Set(ways.map { package.voiceFile(for: VoiceKey(recordingID: id(7), knobs: knobs, way: $0)) })
        files.insert(package.voiceFile(for: VoiceKey(recordingID: id(7), knobs: VoiceKnobs(depth: 6, pitch: -1.5), way: world)))
        files.insert(package.voiceFile(for: VoiceKey(recordingID: id(8), knobs: knobs, way: world)))
        #expect(files.count == 7)

        // The same key is the same file, and a key can be looked up by.
        #expect(VoiceKey(recordingID: id(7), knobs: knobs, way: world) == VoiceKey(recordingID: id(7), knobs: VoiceKnobs(depth: 6, pitch: -1.2), way: world))

        // A method's name is always one folder, whatever is in it.
        #expect(VoiceWay(method: "a/b c", revision: 2).folderName == "a-b-c-r2")
        #expect(VoiceWay(method: "..", revision: 1).folderName == "..-r1")
        #expect(VoiceWay(method: "soulx-svc", revision: 12).folderName == "soulx-svc-r12")
    }

    // MARK: What stands in

    /// A clip that plays these recordings, one segment each, in this order.
    private func clip(playing recordings: [UUID]) -> Clip {
        Clip(segments: recordings.enumerated().map { index, recording in
            Segment(recordingID: recording, inSample: index * 48_000, outSample: (index + 1) * 48_000)
        })
    }

    @Test func nothingStandsInOnATrackWithoutAVoiceOrWithItOffOrNeutral() {
        let recording = id(1)
        let darker = TrackVoice(name: "Darker", knobs: VoiceKnobs(depth: 6, pitch: -1))
        var track = Track(id: id(10), name: "Track 1", clips: [clip(playing: [recording])])
        var voices = TrackVoices.none
        #expect(voices.isEmpty)

        // Nothing is kept: the recording, whatever the track says.
        track.voice = darker
        #expect(voices.soundID(forRecording: recording, on: track) == nil)
        #expect(voices.standIns(for: track.clips[0], on: track).isEmpty)

        voices.set(heard: id(50), before: nil, forRecording: recording, onTrack: track.id)
        #expect(!voices.isEmpty)
        #expect(voices.soundID(forRecording: recording, on: track) == id(50))
        #expect(voices.standIns(for: track.clips[0], on: track) == [recording: id(50)])

        // The same lookup, and the track as it is now decides.
        track.voice?.isOn = false
        #expect(voices.soundID(forRecording: recording, on: track) == nil)
        #expect(voices.standIns(for: track.clips[0], on: track).isEmpty)

        track.voice = TrackVoice(knobs: .neutral)
        #expect(voices.soundID(forRecording: recording, on: track) == nil)
        #expect(voices.standIns(for: track.clips[0], on: track).isEmpty)

        track.voice = nil
        #expect(voices.soundID(forRecording: recording, on: track) == nil)
        #expect(voices.standIns(for: track.clips[0], on: track).isEmpty)

        track.voice = darker
        #expect(voices.soundID(forRecording: recording, on: track) == id(50))
    }

    @Test func oneRecordingOnThreeTracksIsReadFromEachTracksOwnSound() {
        let recording = id(1)
        let plain = Track(id: id(10), name: "Plain")
        let darker = Track(id: id(11), name: "Darker", voice: VoicePresets.builtIn[0].voice)
        let deeper = Track(id: id(12), name: "Deeper", voice: VoicePresets.builtIn[1].voice)
        var voices = TrackVoices.none
        voices.set(heard: id(51), before: nil, forRecording: recording, onTrack: darker.id)
        voices.set(heard: id(52), before: id(51), forRecording: recording, onTrack: deeper.id)

        #expect(voices.soundID(forRecording: recording, on: plain) == nil)
        #expect(voices.soundID(forRecording: recording, on: darker) == id(51))
        #expect(voices.soundID(forRecording: recording, on: deeper) == id(52))
        // A recording nothing was made for yet is the recording itself.
        #expect(voices.soundID(forRecording: id(2), on: darker) == nil)

        // The one that stood in before is kept beside the one that is heard, and a new one takes its place.
        #expect(voices.entries[TrackVoices.Key(trackID: deeper.id, recordingID: recording)]
            == TrackVoices.Entry(heard: id(52), before: id(51)))
        voices.set(heard: id(53), before: id(52), forRecording: recording, onTrack: deeper.id)
        #expect(voices.soundID(forRecording: recording, on: deeper) == id(53))
        #expect(voices.entries.count == 2)
    }

    @Test func aClipsStandInsNameOnlyTheRecordingsAVoiceIsThereFor() {
        let track = Track(id: id(10), name: "Track 1", voice: VoicePresets.builtIn[0].voice)
        // Two pieces of one recording, and one of a recording whose voice is not made yet.
        let joined = clip(playing: [id(1), id(2), id(1)])
        var voices = TrackVoices.none
        voices.set(heard: id(51), before: nil, forRecording: id(1), onTrack: track.id)
        voices.set(heard: id(59), before: nil, forRecording: id(2), onTrack: id(11))
        #expect(voices.standIns(for: joined, on: track) == [id(1): id(51)])

        voices.set(heard: id(52), before: nil, forRecording: id(2), onTrack: track.id)
        #expect(voices.standIns(for: joined, on: track) == [id(1): id(51), id(2): id(52)])
        #expect(voices.standIns(for: Clip(), on: track).isEmpty)

        var same = TrackVoices.none
        same.set(heard: id(59), before: nil, forRecording: id(2), onTrack: id(11))
        same.set(heard: id(52), before: nil, forRecording: id(2), onTrack: track.id)
        same.set(heard: id(51), before: nil, forRecording: id(1), onTrack: track.id)
        #expect(same == voices)
        #expect(same != TrackVoices.none)
    }

    // MARK: The features

    @Test func theVoiceAndItsNaturalQualityAreTwoFeaturesOfTheirOwn() {
        #expect(FeatureSet.all.contains(.trackVoice))
        #expect(FeatureSet.all.contains(.naturalVoice))
        #expect(FeatureSet.trackVoice != .naturalVoice)
        #expect(FeatureSet.all.subtracting([.trackVoice, .naturalVoice]).isDisjoint(with: [.trackVoice, .naturalVoice]))
        #expect(FeatureSet.all.rawValue.nonzeroBitCount == FeatureSet.all.subtracting([.trackVoice, .naturalVoice]).rawValue.nonzeroBitCount + 2)
    }
}

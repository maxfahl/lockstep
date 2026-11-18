import Foundation
import Testing
@testable import LockstepCore

@Suite("Project clips")
struct ProjectClipsTests {
    /// A project folder in a temporary place, with an empty `song.wav` in it, and the
    /// folder to remove when the test is done.
    private func makePackage() throws -> (package: ProjectPackage, folder: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockstep-clips-tests-\(UUID().uuidString)", isDirectory: true)
        let package = ProjectPackage(url: folder.appendingPathComponent("Song.lockstep", isDirectory: true))
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
        try Data().write(to: package.url.appendingPathComponent(ProjectPackage.songFileName))
        return (package, folder)
    }

    /// Adds a recording as a clip and gives back the clip's id.
    private func add(
        _ recording: Recording,
        _ samples: Range<Int>,
        to project: inout Project,
        on trackID: UUID,
        aimedAt aim: Double? = nil
    ) throws -> UUID {
        let id = project.addRecording(
            recording, samples: samples, asClipOn: trackID, aim: aim.map { RecordAim(place: $0) }, voices: .none
        )
        return try #require(id)
    }

    // MARK: The position rule

    @Test func aSegmentSitsWhereThePositionRulePutsIt() {
        // Sample 0 was heard at 10 s, 0.25 s of that is delay, and the clip was moved 0.5 s later.
        let recording = Recording(lengthSamples: 480_000, rawStart: 10, delay: 0.25)
        let segment = Segment(recordingID: recording.id, inSample: 48_000, outSample: 144_000, offsetSamples: 24_000)
        let project = Project(recordings: [recording])

        // 10 - 0.25 + (24000 + 48000) / 48000
        #expect(project.start(of: segment) == 11.25)
        // 10 - 0.25 + (24000 + 144000) / 48000
        #expect(project.end(of: segment) == 13.25)
        #expect(recording.songTime(ofSample: 48_000, offsetSamples: 24_000) == 11.25)
        #expect(recording.songTime(ofSample: 0) == 9.75)
    }

    @Test func aClipRunsFromItsFirstSegmentToItsLast() {
        let recording = Recording(lengthSamples: 480_000, rawStart: 4, delay: 0.5)
        let clip = Clip(segments: [
            Segment(recordingID: recording.id, inSample: 24_000, outSample: 48_000, offsetSamples: -12_000),
            Segment(recordingID: recording.id, inSample: 96_000, outSample: 240_000, offsetSamples: -12_000),
        ])
        let project = Project(recordings: [recording])

        // 4 - 0.5 + (-12000 + 24000) / 48000
        #expect(project.start(of: clip) == 3.75)
        // 4 - 0.5 + (-12000 + 240000) / 48000
        #expect(project.end(of: clip) == 8.25)
    }

    @Test func aClipWithoutSegmentsOrWithoutItsRecordingHasNoPlace() {
        let project = Project()
        #expect(project.start(of: Clip()) == nil)
        #expect(project.end(of: Clip()) == nil)
        let lost = Clip(segments: [Segment(recordingID: UUID(), inSample: 0, outSample: 100)])
        #expect(project.start(of: lost) == nil)
        #expect(project.end(of: lost) == nil)
    }

    // MARK: The shown name

    @Test func theShownNameIsTheNameThenTheTextThenNothing() {
        let text = "Walking through the city as the night comes down"
        #expect(Clip(name: "Verse 1", text: text).displayName == "Verse 1")
        // Longer than 30 characters: cut between two words, with dots after.
        #expect(Clip(text: text).displayName == "Walking through the city as…")
        // The 30th character ends a word, so all 30 are kept.
        #expect(Clip(text: "Walking through the city alone tonight").displayName == "Walking through the city alone…")
        // Nothing hangs before the dots.
        #expect(Clip(text: "Walking through the city late, and then").displayName == "Walking through the city late…")
        // No space to cut at.
        #expect(Clip(text: String(repeating: "a", count: 40)).displayName == String(repeating: "a", count: 30) + "…")
        // Exactly 30 characters are shown whole.
        #expect(Clip(text: "Walking through the city alone").displayName == "Walking through the city alone")
        #expect(Clip(text: "Short line").displayName == "Short line")
        #expect(Clip(name: "", text: "Short line").displayName == "Short line")
        #expect(Clip().displayName == "")
    }

    // MARK: Adding and removing

    @Test func aNewProjectHasOneTrackCalledTrack1() {
        let project = Project()
        #expect(project.tracks.map(\.name) == ["Track 1"])
        #expect(project.tracks[0].clips.isEmpty)
        #expect(project.recordings.isEmpty)
    }

    @Test func aRecordingBecomesAClipOverTheVoiceOnly() throws {
        var project = Project()
        let trackID = project.tracks[0].id
        let recording = Recording(lengthSamples: 288_000, rawStart: 8)

        let clipID = try add(recording, 96_000..<240_000, to: &project, on: trackID)

        #expect(project.recordings == [recording])
        #expect(project.tracks[0].clips.count == 1)
        let clip = try #require(project.clip(clipID))
        #expect(clip.segments == [Segment(recordingID: recording.id, inSample: 96_000, outSample: 240_000)])
        #expect(clip.segments[0].offsetSamples == 0)
        #expect(clip.isActiveTake)
        #expect(!clip.muted)
        // The run-up before the voice is in the file, not in the clip.
        #expect(project.start(of: clip) == 10)
        #expect(project.end(of: clip) == 13)
        #expect(project.unusedRecordingIDs().isEmpty)
    }

    @Test func theSamplesOfANewClipStayInsideItsRecording() throws {
        var project = Project()
        let recording = Recording(lengthSamples: 1_000)
        let clipID = try add(recording, -50..<5_000, to: &project, on: project.tracks[0].id)
        let segment = try #require(project.clip(clipID)?.segments.first)
        #expect(segment.inSample == 0)
        #expect(segment.outSample == 1_000)
    }

    @Test func nothingIsAddedForATrackTheProjectDoesNotHave() {
        var project = Project()
        let before = project
        #expect(project.addRecording(Recording(lengthSamples: 1_000), samples: 0..<1_000, asClipOn: UUID(), voices: .none) == nil)
        #expect(project == before)
    }

    @Test func removedClipsLeaveTheirRecordingsBehind() throws {
        var project = Project(tracks: [Track(name: "Track 1"), Track(name: "Track 2")])
        let first = Recording(lengthSamples: 48_000, rawStart: 1)
        let second = Recording(lengthSamples: 48_000, rawStart: 2)
        let third = Recording(lengthSamples: 48_000, rawStart: 3)
        let a = try add(first, 0..<48_000, to: &project, on: project.tracks[0].id)
        let b = try add(second, 0..<48_000, to: &project, on: project.tracks[0].id)
        let c = try add(third, 0..<48_000, to: &project, on: project.tracks[1].id)
        let whole = project

        project.removeClips([a, c])

        #expect(project.tracks[0].clips.map(\.id) == [b])
        #expect(project.tracks[1].clips.isEmpty)
        #expect(project.recordings == [first, second, third])
        #expect(project.unusedRecordingIDs() == [first.id, third.id])

        project.removeClips([])
        project.removeClips([UUID()])
        #expect(project.tracks[0].clips.map(\.id) == [b])
        #expect(whole.unusedRecordingIDs().isEmpty)
    }

    @Test func aRecordingStaysUsedWhileAnyClipPlaysAPartOfIt() {
        let recording = Recording(lengthSamples: 96_000)
        let front = Clip(segments: [Segment(recordingID: recording.id, inSample: 0, outSample: 48_000)])
        let back = Clip(segments: [Segment(recordingID: recording.id, inSample: 48_000, outSample: 96_000)])
        var project = Project(tracks: [Track(name: "Track 1", clips: [front, back])], recordings: [recording])

        project.removeClips([front.id])
        #expect(project.unusedRecordingIDs().isEmpty)
        project.removeClips([back.id])
        #expect(project.unusedRecordingIDs() == [recording.id])
    }

    // MARK: Clips in a stretch of the song

    @Test func clipsAreFoundByTheStretchOfTheSongTheyCover() throws {
        var project = Project(tracks: [Track(name: "Track 1"), Track(name: "Track 2")])
        let one = project.tracks[0].id
        let two = project.tracks[1].id
        // On track 1: 2...4 s and 6...8 s. On track 2: 3...5 s.
        let a = try add(Recording(lengthSamples: 96_000, rawStart: 2), 0..<96_000, to: &project, on: one)
        let b = try add(Recording(lengthSamples: 96_000, rawStart: 6), 0..<96_000, to: &project, on: one)
        let c = try add(Recording(lengthSamples: 96_000, rawStart: 3), 0..<96_000, to: &project, on: two)

        #expect(project.clips(on: one, overlapping: 0..<100).map(\.id) == [a, b])
        #expect(project.clips(on: one, overlapping: 3.5..<3.6).map(\.id) == [a])
        #expect(project.clips(on: one, overlapping: 3.9..<6.1).map(\.id) == [a, b])
        #expect(project.clips(on: one, overlapping: 4.5..<5.5).isEmpty)
        // Touching at an edge is not overlapping.
        #expect(project.clips(on: one, overlapping: 4..<6).isEmpty)
        #expect(project.clips(on: two, overlapping: 0..<100).map(\.id) == [c])
        #expect(project.clips(on: UUID(), overlapping: 0..<100).isEmpty)
    }

    @Test func aClickLandsOnTheTakeThatIsShownNeverOnOneThatWaits() throws {
        var project = Project(tracks: [Track(name: "Track 1")])
        let track = project.tracks[0].id
        // The same line three times, recorded from the same place, each voice a little later than the one
        // before: 2...4 s, 2.1...4.1 s, 2.2...4.2 s.
        let first = try add(Recording(lengthSamples: 96_000, rawStart: 2), 0..<96_000, to: &project, on: track)
        let second = try add(
            Recording(lengthSamples: 96_000, rawStart: 2.1), 0..<96_000, to: &project, on: track, aimedAt: 2
        )
        let third = try add(
            Recording(lengthSamples: 96_000, rawStart: 2.2), 0..<96_000, to: &project, on: track, aimedAt: 2
        )

        // The first take is the one shown. The other two start later and would be in front if they were drawn.
        project.setActiveTake(first)
        #expect(project.clip(on: track, at: 3)?.id == first)
        // Where only a waiting take has sound, the track is empty to a click.
        #expect(project.clip(on: track, at: 4.15) == nil)

        project.setActiveTake(third)
        #expect(project.clip(on: track, at: 3)?.id == third)
        #expect(project.clip(on: track, at: 2.05) == nil)
        #expect(second != third)
    }

    // MARK: Saving

    @Test func aProjectSavedBeforeTracksExistedOpensWithTrack1() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        // What phases 7 and 8 wrote.
        try Data(
            #"""
            {
              "click" : { "division" : "beats", "isOn" : true, "sound" : "cowbell", "volume" : 0.35 },
              "grid" : { "anchors" : [], "barStartNumber" : 0, "beats" : [ { "estimated" : false, "number" : 0, "time" : 0.5 } ], "tempoLevel" : "normal" },
              "songFile" : "song.wav",
              "songLengthSamples" : 96000,
              "songName" : "Old",
              "version" : 1
            }
            """#.utf8
        ).write(to: package.projectFile)

        let project = try package.read()
        #expect(project.songName == "Old")
        #expect(project.grid?.beats == [Beat(number: 0, time: 0.5)])
        #expect(project.click.isOn)
        #expect(project.tracks.count == 1)
        #expect(project.tracks[0].name == "Track 1")
        #expect(project.tracks[0].clips.isEmpty)
        #expect(!project.tracks[0].muted)
        #expect(project.recordings.isEmpty)
    }

    @Test func aProjectSavedWithNoTracksOpensWithTrack1() throws {
        let project = try JSONDecoder().decode(Project.self, from: Data(#"{ "tracks": [] }"#.utf8))
        #expect(project.tracks.map(\.name) == ["Track 1"])
    }

    @Test func missingFieldsOfTracksClipsAndRecordingsGetTheirDefaults() throws {
        let id = UUID()
        let text = """
            {
              "tracks": [ { "name": "Double", "clips": [ { "segments": [ { "recordingID": "\(id.uuidString)", "inSample": 10, "outSample": 20 } ] } ] } ],
              "recordings": [ { "id": "\(id.uuidString)", "lengthSamples": 100, "rawStart": 1.5 } ]
            }
            """
        let project = try JSONDecoder().decode(Project.self, from: Data(text.utf8))

        let track = try #require(project.tracks.first)
        #expect(track.name == "Double")
        #expect(!track.muted)
        let clip = try #require(track.clips.first)
        #expect(clip.tighten == .off)
        #expect(clip.tightenWhenOn == .all)
        #expect(clip.strength == 1)
        #expect(!clip.stretch)
        #expect(clip.name == nil)
        #expect(clip.text == nil)
        #expect(!clip.muted)
        #expect(clip.gainDb == 0)
        #expect(clip.normalizeGainDb == nil)
        #expect(clip.feel == .sixteenths)
        #expect(clip.isActiveTake)
        #expect(clip.segments == [Segment(recordingID: id, inSample: 10, outSample: 20, offsetSamples: 0, gainDb: 0)])
        let recording = try #require(project.recordings.first)
        #expect(recording.id == id)
        #expect(recording.file == "takes/\(id.uuidString).wav")
        #expect(recording.delay == 0)
        #expect(recording.devicePair == nil)
        #expect(recording.excludedMarkers.isEmpty)
    }

    @Test func twoTracksAndThreeClipsComeBackExactlyAsTheyWereSaved() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }

        let pair = DevicePair(outputUID: "out-1", outputName: "AirPods Pro", inputUID: "in-1", inputName: "RODE NT-USB")
        let first = Recording(lengthSamples: 480_000, rawStart: 12.345_678_9, delay: 0.183, devicePair: pair, excludedMarkers: [4_800, 96_000])
        let second = Recording(lengthSamples: 240_000, rawStart: 31.5)
        let named = Clip(
            name: "Hook",
            text: "Walking through the city",
            segments: [
                Segment(recordingID: first.id, inSample: 9_600, outSample: 96_000, offsetSamples: -2_400, gainDb: -1.5),
                Segment(recordingID: first.id, inSample: 120_000, outSample: 400_000, offsetSamples: -2_400),
            ],
            muted: true,
            gainDb: 3,
            normalizeGainDb: -4.25,
            feel: .triplets,
            tighten: .all,
            strength: 0.6,
            stretch: true,
            isActiveTake: false
        )
        let plain = Clip(segments: [Segment(recordingID: second.id, inSample: 0, outSample: 240_000)])
        let other = Clip(
            text: "Natten faller ner",
            segments: [Segment(recordingID: second.id, inSample: 48_000, outSample: 96_000, offsetSamples: 480_000)],
            feel: .auto
        )
        let project = Project(
            songName: "Weighted Silence",
            songLengthSamples: 10_176_000,
            grid: Grid(beats: [Beat(number: 0, time: 0.5), Beat(number: 1, time: 1.0, estimated: true)]),
            click: ClickSettings(isOn: true, division: .subBeats, subBeats: .triplets),
            tracks: [
                Track(name: "Lead", muted: false, clips: [named, plain]),
                Track(name: "Double", muted: true, clips: [other]),
            ],
            recordings: [first, second]
        )

        try package.write(project)
        let read = try package.read()

        #expect(read == project)
        #expect(read.tracks.map(\.name) == ["Lead", "Double"])
        #expect(read.tracks.flatMap(\.clips).map(\.id) == [named.id, plain.id, other.id])
        #expect(read.start(of: named) == project.start(of: named))

        // The saved text is the readable form: every field is there by its name.
        let text = try String(contentsOf: package.projectFile, encoding: .utf8)
        for key in ["tracks", "recordings", "feel", "subBeats", "clips", "segments", "recordingID", "inSample", "outSample",
                    "offsetSamples", "gainDb", "normalizeGainDb", "isActiveTake", "tighten", "tightenWhenOn", "strength", "stretch",
                    "rawStart", "delay", "devicePair", "excludedMarkers", "lengthSamples", "file"] {
            #expect(text.contains("\"\(key)\""), "missing \(key)")
        }
    }
}

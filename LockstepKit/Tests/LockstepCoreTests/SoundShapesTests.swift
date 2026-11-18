import Foundation
import Testing
@testable import LockstepCore

@Suite("The shapes of a sound in the project")
struct SoundShapesTests {
    /// An id that is the same in every run, so the saved text is too.
    private func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }

    /// A project that uses nothing of phases 33 to 35, with every older field of a track and a clip in use.
    /// `Fixtures/project-before-sounds.json` is this project as Lockstep wrote it before a track could have a
    /// Sound.
    private func projectWithoutSounds() -> Project {
        let recording = Recording(id: id(1), lengthSamples: 480_000, rawStart: 1.5, delay: 0.012, excludedMarkers: [4_800])
        let shown = Clip(
            id: id(10),
            name: "Verse",
            text: "one two three",
            segments: [
                Segment(recordingID: id(1), inSample: 0, outSample: 96_000),
                Segment(recordingID: id(1), inSample: 120_000, outSample: 200_000, offsetSamples: -2_400, gainDb: -1.5),
            ],
            gainDb: 2,
            normalizeGainDb: -3.25,
            feel: .triplets,
            tighten: .lines,
            strength: 0.5,
            stretch: true,
            line: id(20),
            recordPlace: 1.5
        )
        let waiting = Clip(
            id: id(11),
            segments: [Segment(recordingID: id(1), inSample: 240_000, outSample: 336_000)],
            muted: true,
            isActiveTake: false,
            line: id(20)
        )
        return Project(
            songName: "Song",
            songLengthSamples: 960_000,
            grid: Grid(beats: (0..<4).map { Beat(number: $0, time: Double($0) * 0.5) }),
            tracks: [
                Track(id: id(30), name: "Track 1", gainDb: -4, clips: [shown, waiting]),
                Track(id: id(31), name: "Track 2", muted: true),
            ],
            recordings: [recording]
        )
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)"))
    }

    // MARK: In the project file

    @Test func aSoundKnobsAndEffectsAreWrittenAndReadBackTheSame() throws {
        var project = projectWithoutSounds()
        project.tracks[0].sound = TrackSound(
            name: "Rap lead",
            character: .rapLead,
            knobs: SoundKnobs(squeeze: 0.7, tone: 0.55, warmth: 0.35, space: 0.08)
        )
        project.tracks[0].clips[0].knobs = ClipKnobs(space: 0.6)
        project.tracks[0].clips[0].effects = [
            ClipEffect(id: id(40), kind: .thick, levelDb: -9),
            ClipEffect(
                id: id(41),
                kind: .echoEighth,
                span: ClipSpan(recordingID: id(1), inSample: 24_000, outSample: 48_000),
                levelDb: -6
            ),
        ]

        let text = try ProjectPackage.encode(project)
        let read = try ProjectPackage.decode(text)
        #expect(read == project)
        #expect(read.tracks[0].sound?.character == .rapLead)
        #expect(read.tracks[0].clips[0].knobs == ClipKnobs(space: 0.6))
        #expect(read.tracks[0].clips[0].effects.map(\.kind) == [.thick, .echoEighth])
        #expect(read.tracks[0].clips[0].effects[0].span == nil)
        // The other track and the other clip have none, and say nothing about it.
        let saved = try #require(JSONSerialization.jsonObject(with: text) as? [String: Any])
        let tracks = try #require(saved["tracks"] as? [[String: Any]])
        let clips = try #require(tracks[0]["clips"] as? [[String: Any]])
        #expect(tracks[0]["sound"] != nil)
        #expect(tracks[1]["sound"] == nil)
        #expect(clips[0]["knobs"] as? [String: Double] == ["space": 0.6])
        #expect(clips[1]["knobs"] == nil)
        #expect(clips[1]["effects"] == nil)
    }

    @Test func aProjectWithoutAnyOfThemIsWrittenExactlyAsBefore() throws {
        let before = try fixture("project-before-sounds.json")
        #expect(try ProjectPackage.encode(projectWithoutSounds()) == before)

        // And what was written before is read as a project without any of them.
        let read = try ProjectPackage.decode(before)
        #expect(read == projectWithoutSounds())
        #expect(read.tracks.allSatisfy { $0.sound == nil })
        #expect(read.tracks.flatMap(\.clips).allSatisfy { $0.knobs.isEmpty && $0.effects.isEmpty })
    }

    @Test func anEffectOfAnUnknownKindIsSkippedAndTheRestOfTheClipIsRead() throws {
        let recording = id(1).uuidString
        let text = """
        {"tracks":[{"name":"Track 1","clips":[{
          "id":"\(id(10).uuidString)",
          "name":"Verse",
          "segments":[{"recordingID":"\(recording)","inSample":0,"outSample":96000}],
          "knobs":{"tone":0.25},
          "effects":[
            {"id":"\(id(40).uuidString)","kind":"thick","levelDb":-9},
            {"id":"\(id(41).uuidString)","kind":"robot","levelDb":-3,"depth":7},
            {"id":"\(id(42).uuidString)","kind":"phone","levelDb":0,
             "span":{"recordingID":"\(recording)","inSample":100,"outSample":200}}
          ]}]}]}
        """
        let clip = try #require(try JSONDecoder().decode(Project.self, from: Data(text.utf8)).tracks[0].clips.first)
        #expect(clip.effects.map(\.id) == [id(40), id(42)])
        #expect(clip.effects.map(\.kind) == [.thick, .phone])
        #expect(clip.effects[1].span == ClipSpan(recordingID: id(1), inSample: 100, outSample: 200))
        #expect(clip.name == "Verse")
        #expect(clip.knobs == ClipKnobs(tone: 0.25))
        #expect(clip.segments.map(\.outSample) == [96_000])
    }

    // MARK: The finished sound of a clip

    @Test func aFinishedSoundIsGoneForAClipWhoseSegmentsChanged() {
        let clip = projectWithoutSounds().tracks[0].clips[0]
        let sound = FinishedSounds.Sound(id: id(50), drySamples: 173_600, tailSamples: 28_800, pieces: clip.segments, madeFrom: .recordings)
        var finished = FinishedSounds.none
        #expect(finished.sound(for: clip) == nil)
        finished.set(sound, for: clip.id)
        #expect(finished.sound(for: clip) == sound)
        #expect(sound.pieces.map(\.gainDb) == [0, 0])

        // Moved as a whole, or turned up: the same pieces.
        var moved = clip
        for index in moved.segments.indices { moved.segments[index].offsetSamples += 48_000 }
        moved.segments[1].gainDb = 3
        moved.gainDb = -6
        #expect(finished.sound(for: moved) == sound)

        // Trimmed, cut in two, or with one segment moved against the other: other pieces.
        var trimmed = clip
        trimmed.segments[0].inSample += 480
        #expect(finished.sound(for: trimmed) == nil)
        var cut = clip
        cut.segments.removeLast()
        #expect(finished.sound(for: cut) == nil)
        var shifted = clip
        shifted.segments[1].offsetSamples += 480
        #expect(finished.sound(for: shifted) == nil)

        // Another clip has no finished sound of its own.
        var copy = clip
        copy.id = id(12)
        #expect(finished.sound(for: copy) == nil)
    }
}

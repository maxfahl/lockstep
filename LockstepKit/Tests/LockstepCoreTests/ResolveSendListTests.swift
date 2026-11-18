import Foundation
import Testing
@testable import LockstepCore

/// The list Lockstep writes for its script in DaVinci Resolve: the frames it gives, more than one clip, and
/// names with characters that could break a Lua file.
@Suite("Resolve send list")
struct ResolveSendListTests {
    private static let firstID = UUID(uuidString: "0C6E1F7A-52B8-4E7B-9A0E-3D6C1B2A4F10")!
    private static let secondID = UUID(uuidString: "7B1D9C44-0E7F-4D0A-8C55-9E2F6A1B3C22")!

    /// The entry for a clip of the exporter's own test project, exported at a frame rate.
    private static func entry(
        _ samples: Range<Int>,
        frameRate: ResolveFrameRate,
        timelineStart: Timecode = ResolveSettings.defaultTimelineStart
    ) throws -> ResolveSendList.Clip {
        let recording = ClipExporterTests.recording()
        let clip = ClipExporterTests.clip(recording, samples)
        var project = ClipExporterTests.project(recording, [clip], frameRate: frameRate)
        project.resolve.timelineStart = timelineStart
        let export = try #require(ClipExporter.export(
            clip.id,
            in: project,
            recordings: [recording.id: ClipExporterTests.voice(96_000)],
            peaks: Clip.unknownPeaks,
            edgeFadeMs: 5, voices: .none
        ))
        return ResolveSendList.Clip(
            id: firstID,
            export: export,
            file: URL(fileURLWithPath: "/exports/\(export.fileName)"),
            clipName: "Verse 1",
            trackName: "Double",
            resolve: project.resolve
        )
    }

    // MARK: The frames

    @Test("An entry has the frame, the length in frames and the timecode of its export")
    func entryFollowsTheExport() throws {
        // The clip's first sound is sample 13,000 of the song: frame 6 at 25 frames per second, where a frame
        // is 1,920 samples. With 1,480 samples of padding its 40,000 samples end inside frame 27, so the file
        // is 22 frames long.
        let entry = try Self.entry(1_000..<41_000, frameRate: .fps25)

        #expect(entry.frame == 6)
        #expect(entry.lengthFrames == 22)
        #expect(entry.channels == 1)
        #expect(entry.timecode.text == "01:00:00:06")
        #expect(entry.frameRate == .fps25)
        #expect(entry.timelineStart.text == "01:00:00:00")
        #expect(entry.file == "/exports/Weighted Silence - Double - 01.00.00.06.wav")
    }

    @Test("An entry for a clip sent with its sound says two channels, and its frames count the tail and not the two sides")
    func entryOfAStereoExport() throws {
        let recording = ClipExporterTests.recording()
        let clip = ClipExporterTests.clip(recording, 1_000..<41_000)
        let project = ClipExporterTests.project(recording, [clip])
        let made = ClipExporterSoundTests.sound(for: clip, dry: 40_000, tail: 9_000)
        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: [recording.id: ClipExporterTests.voice(96_000)],
            peaks: Clip.unknownPeaks, edgeFadeMs: 5, finished: made.lookup, finishedSamples: made.samples, voices: .none
        ))

        let entry = ResolveSendList.Clip(
            id: Self.firstID, export: export, file: URL(fileURLWithPath: "/exports/a.wav"), clipName: "Verse 1",
            trackName: "Double", resolve: project.resolve
        )

        // 1,480 samples of padding, 40,000 of the clip and 9,000 of its tail end inside frame 27 of the file.
        #expect(entry.frame == 6)
        #expect(entry.lengthFrames == 27)
        #expect(entry.channels == 2)
        #expect(ResolveSendList(songName: "", clips: [entry]).luaText.contains("      frames = 27,\n      channels = 2,\n"))
    }

    @Test("The frames are counted at the project's own frame rate", arguments: ResolveFrameRate.allCases)
    func framesAtEveryRate(rate: ResolveFrameRate) throws {
        let entry = try Self.entry(1_000..<41_000, frameRate: rate)
        let perFrame = rate.samplesPerFrame
        let padding = 13_000 % perFrame

        #expect(entry.frame == 13_000 / perFrame)
        #expect(entry.lengthFrames == (padding + 40_000 + perFrame - 1) / perFrame)
    }

    @Test("The start of the timeline is written as a count of frames, 24 to the second at 23.976")
    func timelineStartAsFrames() throws {
        let at25 = try Self.entry(1_000..<41_000, frameRate: .fps25)
        let at23 = try Self.entry(1_000..<41_000, frameRate: .fps23_976)
        let fromZero = try Self.entry(
            1_000..<41_000,
            frameRate: .fps25,
            timelineStart: Timecode(hours: 0, minutes: 0, seconds: 0, frames: 0)
        )

        #expect(ResolveSendList(songName: "", clips: [at25]).luaText.contains("timelineStartFrame = 90000,"))
        #expect(ResolveSendList(songName: "", clips: [at23]).luaText.contains("timelineStartFrame = 86400,"))
        #expect(ResolveSendList(songName: "", clips: [fromZero]).luaText.contains("timelineStartFrame = 0,"))
        #expect(ResolveSendList(songName: "", clips: [fromZero]).luaText.contains("timecode = \"00:00:00:06\","))
    }

    // MARK: The text of the file

    @Test("Two clips are written in the order given, each with all it needs")
    func twoClips() {
        let list = ResolveSendList(
            songName: "Weighted Silence",
            clips: [
                ResolveSendList.Clip(
                    id: Self.firstID,
                    file: "/exports/Weighted Silence - Double - 01.00.16.00.wav",
                    clipName: "Verse 1",
                    trackName: "Double",
                    frame: 400,
                    lengthFrames: 80,
                    timecode: Timecode(hours: 1, minutes: 0, seconds: 16, frames: 0),
                    frameRate: .fps25,
                    timelineStart: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0)
                ),
                ResolveSendList.Clip(
                    id: Self.secondID,
                    file: "/exports/Weighted Silence - Ad-libs - 01.00.21.12.wav",
                    clipName: "Hook",
                    trackName: "Ad-libs",
                    frame: 537,
                    lengthFrames: 41,
                    channels: 2,
                    timecode: Timecode(hours: 1, minutes: 0, seconds: 21, frames: 12),
                    frameRate: .fps25,
                    timelineStart: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0)
                ),
            ]
        )

        #expect(list.luaText == """
            -- Written by Lockstep for its script in DaVinci Resolve. Each Send to DaVinci replaces it.
            return {
              version = 1,
              song = "Weighted Silence",
              clips = {
                {
                  id = "0C6E1F7A-52B8-4E7B-9A0E-3D6C1B2A4F10",
                  file = "/exports/Weighted Silence - Double - 01.00.16.00.wav",
                  clip = "Verse 1",
                  track = "Double",
                  frame = 400,
                  frames = 80,
                  channels = 1,
                  timecode = "01:00:16:00",
                  frameRate = "25",
                  timelineStart = "01:00:00:00",
                  timelineStartFrame = 90000,
                },
                {
                  id = "7B1D9C44-0E7F-4D0A-8C55-9E2F6A1B3C22",
                  file = "/exports/Weighted Silence - Ad-libs - 01.00.21.12.wav",
                  clip = "Hook",
                  track = "Ad-libs",
                  frame = 537,
                  frames = 41,
                  channels = 2,
                  timecode = "01:00:21:12",
                  frameRate = "25",
                  timelineStart = "01:00:00:00",
                  timelineStartFrame = 90000,
                },
              },
            }

            """)
    }

    @Test("A clip before the start of the timeline keeps its frame below zero")
    func frameBelowZero() {
        let clip = ResolveSendList.Clip(
            id: Self.firstID, file: "/a.wav", clipName: "", trackName: "", frame: -3, lengthFrames: 10,
            timecode: Timecode(hours: 0, minutes: 59, seconds: 59, frames: 22), frameRate: .fps25,
            timelineStart: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0)
        )

        #expect(ResolveSendList(songName: "", clips: [clip]).luaText.contains("      frame = -3,\n"))
    }

    @Test("A list with no clip is still a table")
    func noClips() {
        #expect(ResolveSendList(songName: "S", clips: []).luaText == """
            -- Written by Lockstep for its script in DaVinci Resolve. Each Send to DaVinci replaces it.
            return {
              version = 1,
              song = "S",
              clips = {
              },
            }

            """)
    }

    // MARK: Names with odd characters

    @Test("Plain names are written as they are")
    func plainText() {
        #expect(ResolveSendList.luaString("Double / lead") == "\"Double / lead\"")
        #expect(ResolveSendList.luaString("") == "\"\"")
        #expect(ResolveSendList.luaString("it's [[x]] --ok") == "\"it's [[x]] --ok\"")
    }

    @Test("A quote and a backslash cannot end the string")
    func quoteAndBackslash() {
        #expect(ResolveSendList.luaString("say \"hej\"") == "\"say \\\"hej\\\"\"")
        #expect(ResolveSendList.luaString("a\\b") == "\"a\\\\b\"")
        // A backslash at the very end must not swallow the closing quote.
        #expect(ResolveSendList.luaString("end\\") == "\"end\\\\\"")
    }

    @Test("Letters outside ASCII, line breaks and other control characters become the numbers of their bytes")
    func bytesAsNumbers() {
        #expect(ResolveSendList.luaString("Säg") == "\"S\\195\\164g\"")
        #expect(ResolveSendList.luaString("a\nb\r\tc") == "\"a\\010b\\013\\009c\"")
        #expect(ResolveSendList.luaString("\u{0}") == "\"\\000\"")
        #expect(ResolveSendList.luaString("\u{7F}") == "\"\\127\"")
        #expect(ResolveSendList.luaString("🎤") == "\"\\240\\159\\142\\164\"")
    }

    @Test("A digit after such a byte is not read as part of its number")
    func digitAfterAByte() {
        // "\t7" must not become "\97", which Lua reads as the letter a.
        #expect(ResolveSendList.luaString("\t7") == "\"\\0097\"")
        #expect(ResolveSendList.luaString("å1") == "\"\\195\\1651\"")
    }

    @Test("Odd names land in the file as one string each")
    func oddNamesInTheFile() {
        let clip = ResolveSendList.Clip(
            id: Self.firstID,
            file: "/Users/max/Music/Låtar \"nya\"/Night Shift - Kör 1 - 01.00.16.00.wav",
            clipName: "She said:\n\"hold on\" \\o/",
            trackName: "Kör 1 }, os.exit() --",
            frame: 400,
            lengthFrames: 80,
            timecode: Timecode(hours: 1, minutes: 0, seconds: 16, frames: 0),
            frameRate: .fps25,
            timelineStart: Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0)
        )
        let text = ResolveSendList(songName: "Night Shift", clips: [clip]).luaText

        #expect(text.contains(
            "      file = \"/Users/max/Music/L\\195\\165tar \\\"nya\\\"/Night Shift - K\\195\\182r 1 - 01.00.16.00.wav\",\n"
        ))
        #expect(text.contains("      clip = \"She said:\\010\\\"hold on\\\" \\\\o/\",\n"))
        #expect(text.contains("      track = \"K\\195\\182r 1 }, os.exit() --\",\n"))
        // Whatever the names hold, the file is plain ASCII with one line per value.
        #expect(text.utf8.allSatisfy { $0 == 0x0A || (0x20...0x7E).contains($0) })
        // Five lines open the file, thirteen hold the clip and two close it: no name added a line.
        #expect(text.split(separator: "\n").count == 20)
    }

    // MARK: The file

    @Test("Writing replaces the list before and removes the script's note of what it placed")
    func writingReplaces() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "lockstep-send-list-tests-\(UUID().uuidString)")
            .appending(path: "DaVinci")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let first = ResolveSendList(songName: "First", clips: [])
        let second = ResolveSendList(songName: "Second", clips: [])

        // The folder is not there yet: writing makes it.
        let url = try first.write(toFolder: folder)
        #expect(url == folder.appending(path: "clips.lua"))
        #expect(try String(contentsOf: url, encoding: .utf8) == first.luaText)

        // The script has noted a clip of the first list as placed.
        let placed = folder.appending(path: "placed.txt")
        try Data("0C6E1F7A-52B8-4E7B-9A0E-3D6C1B2A4F10\n".utf8).write(to: placed)

        try second.write(toFolder: folder)
        #expect(try String(contentsOf: url, encoding: .utf8) == second.luaText)
        #expect(!FileManager.default.fileExists(atPath: placed.path))
    }
}

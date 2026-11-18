import Foundation

/// The clips Lockstep hands to its script inside DaVinci Resolve: for each one the exported file, the frame it
/// goes on, and the track it goes to.
///
/// Another program cannot control the free edition of Resolve, so Lockstep cannot put a clip on the timeline
/// itself. It writes this list to a fixed place, and the Lockstep script, which Max chooses in Resolve's
/// Workspace > Scripts menu, reads it there and places every clip (`Lockstep/Resources/Lockstep.lua`).
///
///     let clip = ResolveSendList.Clip(export: export, file: url, clipName: "Verse 1", trackName: "Double",
///                                     resolve: project.resolve)
///     let list = ResolveSendList(songName: project.songName, clips: [clip])
///     try list.write(toFolder: folder)        // folder/clips.lua
///
/// The list always holds one send, the last one: writing a new list replaces the one before. So the script
/// places what the Send to DaVinci panel showed last, and never a clip from another day or another song.
///
/// The file is Lua that gives back one table, because the script can then read it with nothing but Lua itself
/// (see `luaText`). Nothing about a clip's place is worked out here: the frame and the timecode are the ones
/// the export was made with (`ClipExporter.export`).
public struct ResolveSendList: Sendable, Equatable {
    /// One clip to place.
    public struct Clip: Sendable, Equatable {
        /// Names this clip of this send. The script notes the ids it has placed, so choosing the script a
        /// second time does not place a clip twice. A clip that is sent again gets a new id and is placed again.
        public var id: UUID
        /// The exported file, as a full path.
        public var file: String
        /// The clip's name in Lockstep, for the script's report.
        public var clipName: String
        /// The name of the clip's track in Lockstep. The script puts the clip on the audio track with this name.
        public var trackName: String
        /// The frame the file starts on, counted from the start of the Resolve timeline.
        public var frame: Int
        /// How many frames the file lasts. Always whole, because an export ends on a frame.
        public var lengthFrames: Int
        /// How many channels the file has: 1, or 2 for a clip sent with its finished sound. The script needs
        /// a stereo audio track for a file with two.
        public var channels: Int
        /// The timecode of `frame`, for the script's report.
        public var timecode: Timecode
        /// The frame rate the file was exported for. The script places nothing on a timeline with another rate.
        public var frameRate: ResolveFrameRate
        /// The start of the timeline the file was exported for. The script places nothing on a timeline that
        /// starts elsewhere, because every frame would be off by the difference.
        public var timelineStart: Timecode

        public init(
            id: UUID = UUID(),
            file: String,
            clipName: String,
            trackName: String,
            frame: Int,
            lengthFrames: Int,
            channels: Int = 1,
            timecode: Timecode,
            frameRate: ResolveFrameRate,
            timelineStart: Timecode
        ) {
            self.id = id
            self.file = file
            self.clipName = clipName
            self.trackName = trackName
            self.frame = frame
            self.lengthFrames = lengthFrames
            self.channels = channels
            self.timecode = timecode
            self.frameRate = frameRate
            self.timelineStart = timelineStart
        }

        /// The entry for an export that was written to `file`. `resolve` is the Resolve timeline the export
        /// was made for: the project's own, at the moment of the export.
        public init(
            id: UUID = UUID(),
            export: ClipExport,
            file: URL,
            clipName: String,
            trackName: String,
            resolve: ResolveSettings
        ) {
            self.init(
                id: id,
                file: file.path,
                clipName: clipName,
                trackName: trackName,
                frame: export.startFrame,
                // Counted for one channel, so the tail of a clip sent with its sound is in it and its two
                // sides are not counted twice.
                lengthFrames: export.lengthSamples / resolve.samplesPerFrame,
                channels: export.channels,
                timecode: export.timecode,
                frameRate: resolve.frameRate,
                timelineStart: resolve.timelineStart
            )
        }
    }

    /// The form of the file. The script refuses a list with another number and says which side to update.
    public static let version = 1
    /// The name of the list's file in its folder.
    public static let fileName = "clips.lua"
    /// The name of the file, beside the list, in which the script notes the ids of the clips it has placed.
    public static let placedFileName = "placed.txt"

    /// The song the clips belong to, for the script's report.
    public var songName: String
    public var clips: [Clip]

    public init(songName: String, clips: [Clip]) {
        self.songName = songName
        self.clips = clips
    }

    /// The list as the text of its file: a Lua chunk that gives back one table.
    ///
    ///     return {
    ///       version = 1,
    ///       song = "Weighted Silence",
    ///       clips = {
    ///         {
    ///           id = "0C6E…",
    ///           file = "/Users/max/…/Weighted Silence - Double - 01.00.16.00.wav",
    ///           clip = "Verse 1",
    ///           track = "Double",
    ///           frame = 400,                  -- from the start of the timeline
    ///           frames = 80,                  -- the file's length
    ///           channels = 1,                 -- 2 for a clip sent with its finished sound
    ///           timecode = "01:00:16:00",
    ///           frameRate = "25",
    ///           timelineStart = "01:00:00:00",
    ///           timelineStartFrame = 90000,   -- the timeline start as a count of frames from 00:00:00:00
    ///         },
    ///       },
    ///     }
    ///
    /// `channels` was added on 15 November 2026 without a new version: a script that does not know the field
    /// reads the rest as before, and a list without it means one channel.
    ///
    /// Numbers are whole. Every text is a Lua string in which anything but plain printable ASCII is written as
    /// the numbers of its bytes (`luaString`), so a name with a quote, a line break or an "å" cannot break the
    /// file or be read as Lua.
    public var luaText: String {
        var lines = [
            "-- Written by Lockstep for its script in DaVinci Resolve. Each Send to DaVinci replaces it.",
            "return {",
            "  version = \(Self.version),",
            "  song = \(Self.luaString(songName)),",
            "  clips = {",
        ]
        for clip in clips {
            lines += [
                "    {",
                "      id = \(Self.luaString(clip.id.uuidString)),",
                "      file = \(Self.luaString(clip.file)),",
                "      clip = \(Self.luaString(clip.clipName)),",
                "      track = \(Self.luaString(clip.trackName)),",
                "      frame = \(clip.frame),",
                "      frames = \(clip.lengthFrames),",
                "      channels = \(clip.channels),",
                "      timecode = \(Self.luaString(clip.timecode.text)),",
                "      frameRate = \(Self.luaString(clip.frameRate.label)),",
                "      timelineStart = \(Self.luaString(clip.timelineStart.text)),",
                "      timelineStartFrame = \(clip.timelineStart.frameCount(at: clip.frameRate)),",
                "    },",
            ]
        }
        lines += ["  },", "}", ""]
        return lines.joined(separator: "\n")
    }

    /// A text as a Lua string, quotes included. A quote and a backslash get a backslash before them. Every
    /// byte that is not printable ASCII is written as a backslash and its number in three digits, which Lua
    /// reads back as that byte: "å" becomes `\195\165`, a line break `\010`. Three digits always, so a digit
    /// that follows in the text is never read as part of the number.
    static func luaString(_ text: String) -> String {
        var lua = "\""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""): lua += "\\\""
            case UInt8(ascii: "\\"): lua += "\\\\"
            case 0x20...0x7E: lua.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                let digits = String(byte)
                lua += "\\" + String(repeating: "0", count: 3 - digits.count) + digits
            }
        }
        return lua + "\""
    }

    /// Where the list lies in its folder.
    public static func file(inFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Writes the list into its folder, in place of the list that was there, and gives back where it is. The
    /// folder is made when it is not there yet. The list is whole on disk before it appears under its name.
    ///
    /// The script's note of what it placed is removed with the old list: its ids belong to that list, and
    /// every clip of the new one is still to be placed.
    @discardableResult
    public func write(toFolder folder: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = Self.file(inFolder: folder)
        try Data(luaText.utf8).write(to: url, options: .atomic)
        let placed = folder.appendingPathComponent(Self.placedFileName, isDirectory: false)
        if files.fileExists(atPath: placed.path) {
            try files.removeItem(at: placed)
        }
        return url
    }
}

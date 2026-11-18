import Foundation

// The DaVinci pane's settings: what the Resolve timeline of a new project starts as, and
// where exported clips go. The values of one project are in `ResolveSettings` and are
// saved with that project.

extension ResolveFrameRate: SettingValue {}

extension SettingKey where Value == String {
    /// The timecode the Resolve timeline of a new project starts at, as text such as
    /// "01:00:00:00". Read it through `AppSettings.newProjectResolve`, which only ever
    /// gives a timecode that is one.
    public static var defaultTimelineStart: SettingKey {
        SettingKey("davinci.defaultTimelineStart", pane: .davinci, default: ResolveSettings.defaultTimelineStart.text)
    }

    /// The folder exported clips are written to, as a path. `~` is the home folder.
    /// Empty means each project's own `exports` folder. Read it as a folder with
    /// `AppSettings.exportFolder`.
    public static var exportFolder: SettingKey {
        SettingKey("davinci.exportFolder", pane: .davinci, default: "")
    }
}

extension SettingKey where Value == Bool {
    /// Whether Send to DaVinci sends a clip as it sounds in Lockstep: with its track's Sound and its effects,
    /// in stereo, with what rings after it. Off, every clip is sent dry, as before a clip could have a
    /// finished sound. It is the switch "With sound" in the Send to DaVinci panel and is not in the settings
    /// window.
    public static var sendWithSound: SettingKey {
        SettingKey("davinci.sendWithSound", pane: .davinci, default: true)
    }
}

extension SettingKey where Value == ResolveFrameRate {
    /// The frame rate the Resolve timeline of a new project starts with.
    public static var defaultFrameRate: SettingKey {
        SettingKey(
            "davinci.defaultFrameRate",
            pane: .davinci,
            default: ResolveSettings.defaultFrameRate,
            choices: ResolveFrameRate.allCases
        )
    }
}

extension Timecode {
    /// Reads a timecode that was typed for one frame rate and has to hold at another.
    /// When only its frames are too many for the new rate (frame 40 does not exist at 25
    /// frames per second), it starts on the second: the frames become 00. Nil when the
    /// text is no timecode at any rate.
    public static func parse(_ text: String, fittedTo frameRate: ResolveFrameRate) -> Timecode? {
        if let timecode = parse(text, frameRate: frameRate) {
            return timecode
        }
        // The rate that counts the most frames to a second accepts every frames part
        // that any rate accepts.
        guard let fastest = ResolveFrameRate.allCases.max(by: {
            $0.timecodeFramesPerSecond < $1.timecodeFramesPerSecond
        }), var timecode = parse(text, frameRate: fastest) else {
            return nil
        }
        timecode.frames = 0
        return timecode
    }
}

extension AppSettings {
    /// The Resolve timeline a new project starts with: the timeline start and the frame
    /// rate from the DaVinci pane, and the song at the timeline start.
    ///
    /// A stored timeline start that is no timecode counts as 01:00:00:00, and one whose
    /// frames do not fit the frame rate starts on the second.
    public var newProjectResolve: ResolveSettings {
        let frameRate = self[.defaultFrameRate]
        let start = Timecode.parse(self[.defaultTimelineStart], fittedTo: frameRate)
            ?? ResolveSettings.defaultTimelineStart
        return ResolveSettings(timelineStart: start, frameRate: frameRate)
    }

    /// The folder of `davinci.exportFolder`, with `~` written out, or nil when none is
    /// chosen and every project exports to its own `exports` folder. A path that does
    /// not start at the root or at `~` names no folder, and counts as none.
    public var exportFolder: URL? {
        let path = (self[.exportFolder].trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

extension ProjectPackage {
    /// Whether the saved project says how it sits on the Resolve timeline. A project
    /// saved before Send to DaVinci existed does not, and gets the values new projects
    /// start with the first time it is opened. False when the project cannot be read.
    public func savedProjectHasResolveSettings() -> Bool {
        guard let data = try? Data(contentsOf: projectFile),
            let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return saved["resolve"] != nil
    }
}

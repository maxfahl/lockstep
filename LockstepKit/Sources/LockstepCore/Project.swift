/// One song and everything that has been done to it.
///
/// It is a plain value: a copy is a full, independent snapshot, which is what
/// undo keeps. Phase 9 defined every field of tracks, clips and recordings
/// with its default, also the ones later phases use, so the saved form does
/// not change when a later phase starts using a field.
public struct Project: Codable, Sendable, Equatable {
    /// The newest version of the saved form that this Lockstep writes and can read.
    /// A saved project with a higher number was made by a newer Lockstep and is not opened.
    public static let currentVersion = 1

    public var version: Int                 // starts at 1
    public var songName: String
    public var songFile: String             // "song.wav"
    public var songLengthSamples: Int
    public var grid: Grid?                  // nil until beats are found
    public var click: ClickSettings
    /// Where the song sits on Max's Resolve timeline. Phase 22.
    public var resolve: ResolveSettings
    /// What is cut away of the song and which moment of it stands at the timeline's 00:00. Phase 26.
    public var songPlace: SongPlace
    /// How much quieter than its file the song is played, in dB, inside `Project.songGainRange`. 0, which a
    /// new project has and one saved before the song had a volume gets, plays the song as it is. It is only
    /// for what is heard while playing and recording: the song file, the click file and what is sent to
    /// DaVinci never have it in them.
    public var songGainDb: Double
    /// The vocal tracks, top to bottom in the window. Never empty: a new
    /// project has one, so a recording always has a track to go to.
    public var tracks: [Track]
    /// The original recordings that clips play parts of.
    public var recordings: [Recording]

    /// The name of the one track a new project has.
    public static let firstTrackName = "Track 1"

    public init(
        version: Int = Project.currentVersion,
        songName: String = "",
        songFile: String = "song.wav",
        songLengthSamples: Int = 0,
        grid: Grid? = nil,
        click: ClickSettings = ClickSettings(),
        resolve: ResolveSettings = ResolveSettings(),
        songPlace: SongPlace = SongPlace(),
        songGainDb: Double = 0,
        tracks: [Track] = [Track(name: Project.firstTrackName)],
        recordings: [Recording] = []
    ) {
        self.version = version
        self.songName = songName
        self.songFile = songFile
        self.songLengthSamples = songLengthSamples
        self.grid = grid
        self.click = click
        self.resolve = resolve
        self.songPlace = songPlace
        self.songGainDb = Project.songGain(clamped: songGainDb)
        self.tracks = tracks
        self.recordings = recordings
    }

    /// Reads a saved project. A field that is missing, because the project was
    /// saved before the field existed, gets its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = Project()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? fresh.version
        songName = try container.decodeIfPresent(String.self, forKey: .songName) ?? fresh.songName
        songFile = try container.decodeIfPresent(String.self, forKey: .songFile) ?? fresh.songFile
        songLengthSamples = try container.decodeIfPresent(Int.self, forKey: .songLengthSamples)
            ?? fresh.songLengthSamples
        grid = try container.decodeIfPresent(Grid.self, forKey: .grid)
        click = try container.decodeIfPresent(ClickSettings.self, forKey: .click) ?? fresh.click
        resolve = try container.decodeIfPresent(ResolveSettings.self, forKey: .resolve) ?? fresh.resolve
        if let saved = try container.decodeIfPresent(SongPlace.self, forKey: .songPlace) {
            songPlace = saved.fitted(toLength: songLengthSamples)
        } else {
            // Saved before the song could be cut. Where the song lay on the Resolve timeline was then a
            // number of frames among the Resolve values, and it says the same thing as a cut does now.
            let before = try container.decodeIfPresent(ResolveOffsetBeforeCutting.self, forKey: .resolve)
            songPlace = SongPlace(
                resolveOffsetFrames: before?.songOffsetFrames ?? 0,
                samplesPerFrame: resolve.samplesPerFrame,
                ofLength: songLengthSamples
            )
        }
        // The file is text that can be changed by hand, so a volume outside the range is brought into it.
        songGainDb = Project.songGain(
            clamped: try container.decodeIfPresent(Double.self, forKey: .songGainDb) ?? fresh.songGainDb
        )
        // A project saved before tracks existed, or with none, gets "Track 1".
        var saved = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        try Project.giveSongFeel(to: &saved, from: decoder)
        recordings = try container.decodeIfPresent([Recording].self, forKey: .recordings) ?? fresh.recordings
        // A project saved before each clip kept its line gets the lines its takes had then.
        let needsLine = try SavedBeforeLines(from: decoder).needsLine
        Project.giveLines(to: &saved, needsLine: needsLine, recordings: recordings)
        tracks = saved.isEmpty ? fresh.tracks : saved
    }
}

// MARK: Projects saved before each clip kept its line

/// Which clips of a saved project say what line they belong to. A project saved before lines were kept has
/// none that do. It is read and never written.
private struct SavedBeforeLines: Decodable {
    var tracks: [SavedTrack]?

    struct SavedTrack: Decodable {
        var clips: [SavedClip]?
    }

    struct SavedClip: Decodable {
        /// Only whether it is there is asked, so it is read as the text it is saved as.
        var line: String?
    }

    /// For each track in the saved order, which of its clips have no line.
    var needsLine: [[Bool]] {
        (tracks ?? []).map { track in (track.clips ?? []).map { $0.line == nil } }
    }
}

// MARK: Projects saved while the song had sub-beats of its own

/// What a project saved before the sub-beats became the clip's alone (phase 27) said about them. It is read
/// and never written.
private struct SavedWithSongFeel: Decodable {
    /// The song's choice: "sixteenths", "triplets" or "auto". Missing before phase 21, when it was 16ths.
    var feel: String?
    var tracks: [SavedTrack]?

    struct SavedTrack: Decodable {
        var clips: [SavedClip]?
    }

    struct SavedClip: Decodable {
        /// "followSong", or nothing, for a clip that had no choice of its own.
        var feel: String?
    }
}

extension Project {
    /// Gives every clip that followed the song what the song had: 16ths, Triplets or Auto. A clip with a
    /// choice of its own keeps it. A project saved since then has no clip that follows, so nothing changes.
    ///
    /// The clips are found by their place in the saved file, track by track, since a clip saved without an
    /// id gets a new one each time it is read.
    fileprivate static func giveSongFeel(to tracks: inout [Track], from decoder: any Decoder) throws {
        let saved = try SavedWithSongFeel(from: decoder)
        let songFeel = saved.feel.flatMap(ClipFeel.init(rawValue:)) ?? .sixteenths
        for (track, savedTrack) in (saved.tracks ?? []).enumerated() where track < tracks.count {
            for (clip, savedClip) in (savedTrack.clips ?? []).enumerated() where clip < tracks[track].clips.count {
                let followed = savedClip.feel == nil || savedClip.feel == ClipFeel.savedFollowingSong
                if followed { tracks[track].clips[clip].feel = songFeel }
            }
        }
    }
}

/// What a project saved before phase 26 kept among its Resolve values about the song's place: how many frames
/// after the start of the Resolve timeline the song began, below zero when it began before it.
private struct ResolveOffsetBeforeCutting: Decodable {
    var songOffsetFrames: Int?
}

import LockstepCore

/// A song as the rest of the app works with it: stereo, 32-bit float, 48,000 Hz, all in memory.
public struct ImportedSong: Sendable, Equatable {
    /// Both sides in one list: left, right, left, right, and so on. Its count is `lengthSamples * 2`.
    public let samples: [Float]

    /// How long the song is, in samples for one side at 48,000 Hz.
    public let lengthSamples: Int

    /// How long the song is, in seconds.
    public var duration: Double {
        Double(lengthSamples) / Lockstep.sampleRate
    }

    public init(samples: [Float], lengthSamples: Int) {
        precondition(samples.count == lengthSamples * 2, "A song holds two values for every sample: left and right.")
        self.samples = samples
        self.lengthSamples = lengthSamples
    }
}

/// Why a dropped file could not become a song.
public enum SongImportError: Error, Equatable, Sendable {
    /// The file is missing, damaged, or not a kind of sound file the Mac can decode.
    case unreadableFile
    /// The file opened, but there is no sound track in it (a silent video, for example).
    case noAudio
    /// The file has a sound track with nothing in it.
    case zeroLength

    /// One plain sentence to show Max.
    public var message: String {
        switch self {
        case .unreadableFile: "Lockstep could not read this file."
        case .noAudio: "This file has no sound in it."
        case .zeroLength: "This file is empty."
        }
    }
}

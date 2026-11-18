import LockstepAudio
import LockstepCore

// The second line of the alerts for a file or a project that could not be opened: what
// Max can do about it. The first line, what happened, is each error's own `message`.

extension ProjectPackageError {
    /// What Max can do, or what he should know, in one or two plain sentences.
    var advice: String {
        switch self {
        case .notFound:
            "It was moved, renamed or deleted, so it was taken out of Open Recent."
        case .unreadable:
            "Something in the project folder is damaged or missing. "
                + "Lockstep changed nothing in it, so your recordings are still there."
        case .songMissing:
            "Put the song back in the project folder as song.wav, then open the project again."
        case .newerVersion:
            "Open it with the newer Lockstep."
        }
    }
}

extension SongImportError {
    /// What Max can do, in one or two plain sentences.
    var advice: String {
        switch self {
        case .unreadableFile:
            "It is damaged, or it is not a sound file. Lockstep opens m4a, mp3, wav and aiff files, among others."
        case .noAudio:
            "Drop a sound file, such as an m4a, mp3 or wav."
        case .zeroLength:
            "Its sound is 0 seconds long. Drop another file."
        }
    }
}

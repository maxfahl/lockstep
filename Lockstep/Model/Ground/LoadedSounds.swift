import Foundation
import LockstepAudio
import LockstepCore
import Observation

/// The song that is open: what the window and the commands need to know about it.
/// What is kept about it on disk is the project, in `AppModel.store`.
struct OpenSong {
    /// The file's name without its extension, shown in the song row's header.
    var name: String
    /// Seconds.
    var duration: Double
    /// The song's waveform at every level of detail.
    var waveform: WaveformPyramid
}

/// The sounds that are loaded: the open song, and the sound and the waveform of every
/// recording of the open project.
///
/// It is ground: `AppModel` makes one, and every part that needs the song or the sound of a
/// recording is handed it.
@MainActor
@Observable
final class LoadedSounds {
    /// The open song, or nil before one is dropped.
    var song: OpenSong?
    /// True while a dropped file is being read. The transport waits until it is done.
    var isOpening = false

    /// The sound of every recording of the open project, by recording id: mono, 48,000 Hz.
    /// It is read when the project opens, and a new take adds its own. The player plays
    /// the clips from it.
    @ObservationIgnored var sounds: [UUID: [Float]] = [:]
    /// The waveform of every recording of the open project, by recording id. The clips
    /// are drawn from it.
    @ObservationIgnored var waveforms: [UUID: WaveformPyramid] = [:]
    /// Measures how high stretches of the recordings peak, and remembers the answers.
    @ObservationIgnored private let recordingPeaks = RecordingPeaks()
    /// The highest sample of a stretch of a recording of the open project. The clip rules
    /// ask it to know whether the safe limit holds a clip back: when the clips are drawn,
    /// and when one is split, cut or joined, so its parts stay as loud as they were.
    var clipPeaks: RecordingPeak { recordingPeaks.lookup(in: sounds) }

    /// The same question, answered also for other sounds kept by an id of their own: the made voices of a
    /// track (`VoiceModel`), which the safe limit asks about on a track whose Voice is heard. They are not put
    /// in `sounds`, whose ids are the project's recordings and whose files are removed when it closes.
    func clipPeaks(with others: [UUID: [Float]]) -> RecordingPeak {
        guard !others.isEmpty else { return clipPeaks }
        return recordingPeaks.lookup(in: sounds.merging(others) { recording, _ in recording })
    }
}

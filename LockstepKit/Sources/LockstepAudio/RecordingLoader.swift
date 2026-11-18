import AVFoundation
import LockstepCore

/// Why a recording file could not be read.
public enum RecordingLoadError: Error, Equatable, Sendable {
    /// The file is missing, damaged, or not a sound file.
    case unreadableFile
    /// The file is not at 48,000 Hz. Lockstep's own recordings always are, so the file is not one of them.
    case wrongSampleRate
}

/// Reads recordings from a project's `takes` folder into memory, in the form `PlaybackEngine.setClips` and the
/// waveform drawing take them: mono, 32-bit float, 48,000 Hz, sample 0 first.
///
/// A three-minute recording is about 35 MB this way. The files are only read, never changed.
public enum RecordingLoader {
    /// Reads one recording file whole. Of a file with more than one channel, the first is kept.
    public static func read(_ url: URL) throws(RecordingLoadError) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { throw .unreadableFile }
        let format = file.processingFormat
        guard format.sampleRate == Lockstep.sampleRate else { throw .wrongSampleRate }
        guard file.length > 0 else { return [] }
        guard file.length <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { throw .unreadableFile }
        do {
            try file.read(into: buffer)
        } catch {
            throw .unreadableFile
        }
        guard let channels = buffer.floatChannelData else { throw .unreadableFile }
        return [Float](UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
    }

    /// Reads every recording of a project from its folder, by recording id. This is what happens to recordings
    /// when a project opens. The work never runs on the main thread, whoever calls it.
    ///
    /// A recording whose file is missing or cannot be read is left out of the answer. Its clips are then silent,
    /// and everything else plays.
    ///
    /// A take that was recorded slower (`Recording.recordedSpeed`) is read as its sped-up sound, which is what
    /// its clips count in: from the project's cache, or made again from its file (`SpedUpTake.sound`).
    @concurrent
    public static func readAll(of project: Project, in package: ProjectPackage) async -> [UUID: [Float]] {
        var sounds: [UUID: [Float]] = [:]
        for recording in project.recordings {
            if Task.isCancelled { break }
            if let samples = try? SpedUpTake.sound(of: recording, in: package) {
                sounds[recording.id] = samples
            }
        }
        return sounds
    }
}

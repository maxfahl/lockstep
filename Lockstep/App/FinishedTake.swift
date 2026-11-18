import Foundation
import LockstepAudio
import LockstepCore

/// A take once it has ended and been looked at: the recording, its sound, and the part of it that becomes a clip.
///
/// `make` does the looking, away from the main thread: it finds where the voice is, lets the take's count-in
/// decide what the clip covers (`TakeCountIn.clipSamples`), and keeps the voice's loudness curve in the project
/// for the later phases that read it. A take that is thrown away (shorter than 0.2 seconds, or silent and stopped
/// during the count-in) has `clipSamples` nil, and its file is already deleted.
///
///     let finished = await FinishedTake.make(from: captured, countedIn: counted, in: package)
///     if let samples = finished.clipSamples {
///         store.edit("Record Clip") { $0.addRecording(finished.recording, samples: samples, asClipOn: trackID) }
///     }
struct FinishedTake: Sendable {
    /// The recording as it goes into the project. Its file is at `recording.file` in the project.
    var recording: Recording
    /// The whole take, mono at 48,000 Hz, for playing it at once.
    var samples: [Float]
    /// The part of the recording its clip covers, or nil when the take is thrown away.
    var clipSamples: Range<Int>?
    /// The take's waveform at every level of detail, for drawing its clip. Nil for a take
    /// that is thrown away.
    var waveform: WaveformPyramid?
    /// How loud the clip's part of the take sounds, in LUFS, for normalising it as it becomes a clip. Nil for
    /// a take that is silent or thrown away.
    var loudness: Double?
    /// Where Max aimed the take (`TakeCountIn.aim`). It goes into the project with the clip, and says whether
    /// the clip is a new take of a clip that is already there. Nil for a take that is thrown away.
    var aim: RecordAim?

    /// Looks at a take that has just ended: a take that was stopped, or an attempt that a restart kept.
    ///
    /// The clip starts at the place recording started, or earlier where a word leads into it, and its
    /// loudness is measured over exactly the part the clip gets.
    ///
    /// - Parameters:
    ///   - take: what the recorder handed over when it stopped.
    ///   - counted: how the take was counted in: the place recording started and the clicks that were heard.
    ///   - package: the project the take's file is in.
    @concurrent
    static func make(
        from take: CapturedTake,
        countedIn counted: TakeCountIn,
        in package: ProjectPackage
    ) async -> FinishedTake {
        let recording = take.recording
        let file = package.url.appendingPathComponent(recording.file)
        // A take that is too short is not worth listening through for a voice.
        guard Double(recording.lengthSamples) >= RecordingPlacement.shortestTakeSeconds * Lockstep.sampleRate else {
            try? FileManager.default.removeItem(at: file)
            return FinishedTake(recording: recording, samples: take.samples, clipSamples: nil)
        }
        let envelope = VoiceEnvelope.envelope(of: take.samples)
        let clipSamples = counted.clipSamples(of: recording, envelope: envelope)
        guard let clipSamples else {
            try? FileManager.default.removeItem(at: file)
            return FinishedTake(recording: recording, samples: take.samples, clipSamples: nil)
        }
        // The curve can always be worked out again from the recording, so a failed write is not an error.
        try? envelope.write(forRecording: recording.id, to: package)
        return FinishedTake(
            recording: recording,
            samples: take.samples,
            clipSamples: clipSamples,
            waveform: WaveformPyramid(interleaved: take.samples, channelCount: 1),
            loudness: Self.loudness(of: take.samples, in: clipSamples),
            aim: counted.aim
        )
    }

    /// How loud a stretch of a take sounds, in LUFS. The stretch is kept inside the samples there are.
    private static func loudness(of samples: [Float], in stretch: Range<Int>) -> Double? {
        let first = min(max(stretch.lowerBound, 0), samples.count)
        let end = min(max(stretch.upperBound, first), samples.count)
        return Loudness.integrated(Array(samples[first..<end]))
    }

    /// Why a sound file could not be added as a take.
    enum FileFailure: Error {
        case unreadable
        case wrongSampleRate
        case notWritten(String)

        var message: String {
            switch self {
            case .unreadable: "the file could not be read as sound"
            case .wrongSampleRate: "the file is not at 48,000 Hz"
            case .notWritten(let why): "the take could not be written into the project: \(why)"
            }
        }
    }

    /// Makes a take from a sound file, as if the file had just been recorded with the record origin at a place
    /// in the song and the count-in off: its sound is written into the project as a recording of its own, and from there on it
    /// is treated exactly like a take from the microphone. This is what `-addTake` uses, so an agent can check
    /// everything that happens after a take without a microphone.
    ///
    /// - Parameters:
    ///   - url: a WAV file at 48,000 Hz. Of a file with more than one channel, the first is used.
    ///   - place: the record origin, in song seconds: where the first sample of the file is heard. Files
    ///     made for the same place are takes of one line, and a file made for another place replaces what
    ///     it covers.
    @concurrent
    static func make(
        fromFile url: URL,
        at place: Double = 0,
        in package: ProjectPackage
    ) async throws(FileFailure) -> FinishedTake {
        let samples: [Float]
        do {
            samples = try RecordingLoader.read(url)
        } catch {
            throw error == .wrongSampleRate ? .wrongSampleRate : .unreadable
        }
        let recording = Recording(lengthSamples: samples.count, rawStart: place)
        do {
            try FileManager.default.createDirectory(at: package.takesFolder, withIntermediateDirectories: true)
            try WavWriter.write(samples, channels: 1, to: package.url.appendingPathComponent(recording.file))
        } catch {
            throw .notWritten(error.localizedDescription)
        }
        return await make(
            from: CapturedTake(recording: recording, samples: samples),
            countedIn: TakeCountIn(offAt: place),
            in: package
        )
    }
}

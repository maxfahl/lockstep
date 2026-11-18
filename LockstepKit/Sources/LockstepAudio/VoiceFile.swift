import Darwin
import Foundation
import LockstepCore

/// A made voice as its maker hands it over, before it is checked.
public struct MadeVoice: Sendable {
    /// The samples, one channel after the other in turn when there is more than one.
    public var samples: [Float]
    /// The samples per second the maker says the voice has.
    public var sampleRate: Double
    /// How many channels the voice has.
    public var channels: Int

    /// A voice as `VoiceMaker.fast` gives it: mono, at 48,000 Hz.
    public init(_ samples: [Float], sampleRate: Double = Lockstep.sampleRate, channels: Int = 1) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// One voice to be kept: which voice it is, the recording it was made from, and where it goes.
public struct VoiceJob: Sendable {
    /// The voice: its recording, its setting and its way. It names the file.
    public var key: VoiceKey
    /// The recording's samples, as its clips count them: for a take recorded slower, its sped-up sound.
    public var recording: [Float]
    /// The project the voice is kept in.
    public var package: ProjectPackage
    /// This job, which names the file the voice is written to before it is checked and given its name.
    public var id: UUID

    public init(key: VoiceKey, recording: [Float], package: ProjectPackage, id: UUID = UUID()) {
        self.key = key
        self.recording = recording
        self.package = package
        self.id = id
    }
}

/// Why a made voice was not kept. Each one counts as a failed voice: the recording is heard instead.
public enum VoiceFileError: Error, Equatable, Sendable {
    /// The voice has more than one channel.
    case notMono(channels: Int)
    /// The voice is not at 48,000 Hz.
    case wrongSampleRate(Double)
    /// A value of the voice is not a number, or is infinite.
    case notANumber(atSample: Int)
    /// The voice is not exactly as long as the recording.
    case wrongLength(samples: Int, recording: Int)
    /// The recording has sound from this second on and the voice has none there, or none at all.
    case noSound(atSecond: Double)
    /// The voice would have to be turned up or down by more than 12 dB to be as loud as the recording.
    case tooFarFromTheRecording(gainDb: Double)
    /// The recording is silent by the measure Normalize uses: it stands for itself and gets no voice. Ask
    /// `VoiceFile.standsForItself` before making a voice.
    case recordingStandsForItself
    /// The file could not be written, read back or given its name.
    case notWritten(String)
}

/// Takes a made voice in, and reads one that was kept.
///
///     guard !VoiceFile.standsForItself(recording) else { … }          // heard as it is, counts as made
///     let made = try await VoiceMaker.fast(recording, knobs: knobs)
///     let kept = try await VoiceFile.takeIn(MadeVoice(made), for: VoiceJob(key: key, recording: recording, package: package))
///     kept.samples                                                     // what stands in for the recording
///
///     let again = await VoiceFile.read(key, in: package, lengthSamples: recording.count)   // nil: make it
///
/// A made voice is checked before it is kept, because a faulty one would stand in for Max's recording on every
/// clip of the track. Every rule is kept, also the ones a Rubber Band voice is unlikely to break.
///
/// Neither runs on the caller's actor, so reading, checking and writing a voice never holds up the main actor.
public enum VoiceFile {
    /// The voice once it is kept, as it was read back from its file.
    public struct Kept: Sendable {
        /// The voice this is.
        public var key: VoiceKey
        /// The voice's samples as its file gives them: what stands in for the recording.
        public var samples: [Float]
        /// How far the voice was turned up (or down, negative) to be as loud as the recording, in dB.
        public var gainDb: Double
        /// How far the gain was then lowered so that no sample passed full scale, in dB. 0 when it was not.
        public var loweredDb: Double
        /// The file the voice is kept in.
        public var file: URL
    }

    /// How far the voice may have to be turned up or down to be as loud as the recording, in dB.
    public static let largestGainDb = 12.0

    /// How much quieter than the recording a block of the voice may be where the recording's block counts in
    /// its loudness, in dB, once the voice is as loud as the recording. A block further down than that has
    /// lost its sound. A Rubber Band voice of a spoken line stayed within 0.7 dB of its recording on
    /// stretches of a line's size (task d0bdaf13), so this only catches a voice with a hole in it.
    public static let largestDropDb = 20.0

    /// Where the highest sample is put when the voice would otherwise pass full scale: -0.1 dBFS.
    public static let highestPeakDb = -0.1

    /// Whether a recording gets no voice: it is silent by the measure Normalize uses (nothing in it counts
    /// in its loudness). It is then heard as it is, and counts as made.
    public static func standsForItself(_ recording: [Float]) -> Bool {
        Loudness.integrated(recording) == nil
    }

    // MARK: Taking a voice in

    /// Checks a made voice, sets it to the recording's loudness, writes it into the project's cache and gives
    /// it back as its file holds it.
    ///
    /// The voice is refused when it is not mono at 48,000 Hz, holds a value that is not a number, is not
    /// exactly as long as the recording, has no sound where the recording has sound, or would have to be
    /// turned up or down by more than 12 dB. It is then turned to the recording's loudness, and down further
    /// when a sample would pass full scale, until the highest is at -0.1 dBFS. The file is written as WAV,
    /// 48,000 Hz, 24-bit, under its job's `.partial` name in the folder it will lie in, read back, and only then
    /// given its name, so a file that has its name is always whole.
    @concurrent
    public static func takeIn(_ voice: MadeVoice, for job: VoiceJob) async throws(VoiceFileError) -> Kept {
        let samples = try checked(voice, for: job.recording)
        let gain = try gain(of: samples, toMatch: job.recording)
        let file = job.package.voiceFile(for: job.key)
        let kept = try write(samples.map { $0 * Float(gain.factor) }, as: job.key, job: job.id, in: job.package)
        return Kept(key: job.key, samples: kept, gainDb: gain.db, loweredDb: gain.loweredDb, file: file)
    }

    /// The voice's samples when its shape is right: mono, 48,000 Hz, numbers only, as long as the recording.
    static func checked(_ voice: MadeVoice, for recording: [Float]) throws(VoiceFileError) -> [Float] {
        guard voice.channels == 1 else { throw .notMono(channels: voice.channels) }
        guard voice.sampleRate == Lockstep.sampleRate else { throw .wrongSampleRate(voice.sampleRate) }
        if let index = voice.samples.firstIndex(where: { !$0.isFinite }) { throw .notANumber(atSample: index) }
        guard voice.samples.count == recording.count else {
            throw .wrongLength(samples: voice.samples.count, recording: recording.count)
        }
        return voice.samples
    }

    /// The gain that makes the voice as loud as the recording, by the measure Normalize uses, lowered where a
    /// sample would pass full scale. It refuses a voice with no sound where the recording has sound, and one
    /// that would need more than 12 dB either way.
    static func gain(of voice: [Float], toMatch recording: [Float]) throws(VoiceFileError) -> (factor: Double, db: Double, loweredDb: Double) {
        // Each sound is measured once: its blocks give its loudness and say where it has sound.
        let recordingBlocks = Loudness.blocks(recording)
        let voiceBlocks = Loudness.blocks(voice)
        let recordingCounts = recordingBlocks.filter(\.counts)
        guard let wanted = Loudness.integrated(of: recordingBlocks) else { throw .recordingStandsForItself }
        guard let loudness = Loudness.integrated(of: voiceBlocks) else {
            throw .noSound(atSecond: Double(recordingCounts[0].start) / Lockstep.sampleRate)
        }
        let db = wanted - loudness
        guard abs(db) <= largestGainDb else { throw .tooFarFromTheRecording(gainDb: db) }

        // Every block that counts in the recording's loudness has sound in the voice too. The voice's blocks
        // lie at the same samples, because the two are as long as each other.
        for (heard, made) in zip(recordingBlocks, voiceBlocks) where heard.counts {
            guard made.lufs + db >= heard.lufs - largestDropDb else {
                throw .noSound(atSecond: Double(heard.start) / Lockstep.sampleRate)
            }
        }

        // Turned up, the highest sample must stay inside full scale. If it would not, the gain is lowered
        // until it lies at -0.1 dBFS.
        let peak = Loudness.peakDb(voice)
        guard peak + db > 0 else { return (pow(10, db / 20), db, 0) }
        let lowered = highestPeakDb - peak
        return (pow(10, lowered / 20), db, db - lowered)
    }

    /// Writes the voice under its job's `.partial` name, reads it back, and gives the file its name. The
    /// samples read back are given back. Whatever fails, the partial file is removed.
    static func write(_ samples: [Float], as key: VoiceKey, job: UUID, in package: ProjectPackage) throws(VoiceFileError) -> [Float] {
        let partial = package.partialVoiceFile(for: key, job: job)
        let file = package.voiceFile(for: key)
        do {
            try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            try WavWriter.write(samples, channels: 1, to: partial)
            let readBack = try RecordingLoader.read(partial)
            guard readBack.count == samples.count else {
                throw VoiceFileError.notWritten("the file holds \(readBack.count) samples of \(samples.count)")
            }
            // One step: a file of this name already there, made by another job of the same voice, is replaced.
            guard rename(partial.path, file.path) == 0 else {
                throw VoiceFileError.notWritten("the file could not be given its name: \(String(cString: strerror(errno)))")
            }
            return readBack
        } catch let error as VoiceFileError {
            try? FileManager.default.removeItem(at: partial)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw .notWritten(String(describing: error))
        }
    }

    // MARK: Reading a kept voice

    /// The kept voice of `key`, or nil when there is none, it cannot be read, or it is not `lengthSamples`
    /// long: then it is made again. A file that has its name is whole, so nothing else is checked.
    @concurrent
    public static func read(_ key: VoiceKey, in package: ProjectPackage, lengthSamples: Int) async -> [Float]? {
        guard let samples = try? RecordingLoader.read(package.voiceFile(for: key)), samples.count == lengthSamples
        else { return nil }
        return samples
    }
}

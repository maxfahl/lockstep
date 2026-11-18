import Accelerate
import Foundation
import LockstepCore

/// The sound of a take that was recorded slower, made as fast as the song at the same pitch, with its
/// consonants left as they were (phase 31).
///
/// The file of such a take holds it as it was recorded, slow, and is never changed. Everything that plays,
/// draws, corrects or sends the take uses the sped-up sound, which is made from the file by rule:
///
///     let made = SpedUpTake.make(from: slowSamples, rate: 0.85)
///     made.samples                                   // the take at full tempo
///     made.plan.atFullTempo(slowRecording, clip: slowClip)   // the recording and its clip in song time
///     try SpedUpTake.write(made.samples, forRecording: id, to: package)
///
///     // Later, whenever a recording's sound is read, slow take or not:
///     let sound = try SpedUpTake.sound(of: recording, in: package)
///
/// The same slow samples and the same rate always give the same sped-up samples, on any run. So the copy
/// kept in the project's `cache/sped-up/` folder is only there to save time: thrown away, it is made again
/// from the file, to the same samples.
///
/// How it is made. `SyllableDetector` finds where each syllable starts, `SpeedUpPlan` lays out which sample
/// lands where (a short stretch around every start keeps its length, the time comes out of the pauses first
/// and then out of the sound between), and `RubberBandStretcher` follows that map.
///
/// What comes back, as measured on 15 November 2026 with the made-up take of the tests, at 85 and at 90 %:
/// - A click on a syllable start lands on the sample the plan gives for it (19 of 20; one was 2 samples off),
///   as loud as it was.
/// - The attack of a syllable, from 5 ms before the vowel arrives to 20 ms after it, is the samples that went
///   in: at most 0.022 of full scale off where the click is 0.8, at most 2 samples shifted. Over nearly all
///   of the kept stretch (10 ms before to 40 ms after) it is the same sound, likeness 0.998 or more. Towards
///   the two ends of the kept stretch the library goes over to the squeezed sound.
/// - A held tone keeps its pitch (439.9999 of 440 Hz), and the whole is as loud as it was.
/// - 31 seconds of take are sped up in 1.2 s.
///
/// What nobody has heard yet is a real voice. The numbers of the plan (`SpeedUpPlan.Rules`) are starting
/// values for Max to judge by ear.
public enum SpedUpTake {
    /// The sped-up sound of a slow take, and the plan it was made by.
    ///
    /// - Parameters:
    ///   - slow: the take as it was recorded, mono at 48,000 Hz: the samples of its file.
    ///   - rate: the speed it was recorded at, as a share of the song's (`Recording.recordedSpeed`).
    /// - Returns: `plan.targetLength` samples. Each is a value a 24-bit file holds exactly, so the sound is the
    ///   same whether it was just made or read back from the cache.
    public static func make(from slow: [Float], rate: Double) -> (samples: [Float], plan: SpeedUpPlan) {
        let plan = plan(for: slow, rate: rate)
        guard plan.rate < 1, !slow.isEmpty, plan.targetLength > 0 else { return (WavWriter.asStored(slow), plan) }
        let stretched = RubberBandStretcher().stretch(slow, keyFrames: plan.keyFrames, outputLength: plan.targetLength)
        return (WavWriter.asStored(stretched), plan)
    }

    /// The plan of the speed-up of a slow take: where its syllables start and where it has sound, handed to
    /// `SpeedUpPlan`.
    public static func plan(for slow: [Float], rate: Double) -> SpeedUpPlan {
        let envelope = VoiceEnvelope.envelope(of: slow)
        return SpeedUpPlan(
            lengthSamples: slow.count,
            rate: rate,
            syllableStarts: SyllableDetector.markers(in: envelope).map(\.sample),
            sound: sound(in: slow, envelope: envelope)
        )
    }

    /// The stretches of a take with sound in them. Everything else is pause, which the plan shortens first.
    ///
    /// The voice's own curve (`VoiceEnvelope`) measures 300 to 3,000 Hz, where an s, an f or the breath after
    /// a t hardly show: they lie higher. Taken for pauses, those consonants would be the first thing to be
    /// shortened, which is what must not happen. So sound is what the voice's curve calls sound, and also what
    /// stands clearly above the noise in the high part of the take, by the same rule.
    static func sound(in slow: [Float], envelope: VoiceEnvelope) -> [Range<Int>] {
        envelope.voicedStretches() + hiss(of: slow).voicedStretches()
    }

    /// How loud the high part of a take is, once per millisecond, in the form of a `VoiceEnvelope` so that its
    /// rule for what counts as sound can be asked of it.
    ///
    /// The high part is the difference between each sample and the one before it. That lets through what
    /// changes fast: hardly anything at 300 Hz (28 dB less), all of it from 8,000 Hz up.
    static func hiss(of samples: [Float]) -> VoiceEnvelope {
        let count = samples.count
        guard count > 1 else { return VoiceEnvelope(values: [], lengthSamples: 0) }
        var squares = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { sound in
            squares.withUnsafeMutableBufferPointer { result in
                // result[i] = sound[i] - sound[i - 1], and the first sample has nothing before it.
                vDSP_vsub(sound.baseAddress!, 1, sound.baseAddress! + 1, 1, result.baseAddress! + 1, 1, vDSP_Length(count - 1))
                vDSP_vsq(result.baseAddress!, 1, result.baseAddress!, 1, vDSP_Length(count))
            }
        }
        let hop = VoiceEnvelope.hopSamples
        let valueCount = VoiceEnvelope.valueCount(forLength: count)
        var power = [Float](repeating: 0, count: valueCount)
        squares.withUnsafeBufferPointer { squares in
            for index in 0..<valueCount {
                let start = index * hop
                vDSP_meanv(squares.baseAddress! + start, 1, &power[index], vDSP_Length(min(hop, count - start)))
            }
        }
        // Smoothed as the voice's curve is: each value with five neighbours on either side.
        var runningSum = [Double](repeating: 0, count: valueCount + 1)
        for index in 0..<valueCount { runningSum[index + 1] = runningSum[index] + Double(power[index]) }
        let values = (0..<valueCount).map { index -> Float in
            let from = max(index - 5, 0), to = min(index + 6, valueCount)
            let mean = (runningSum[to] - runningSum[from]) / Double(to - from)
            return max(Float(10 * log10(max(mean, 1e-30))), VoiceEnvelope.quietestValue)
        }
        return VoiceEnvelope(values: values, lengthSamples: count)
    }
}

// MARK: - Kept in the project's cache

extension SpedUpTake {
    /// Keeps the sped-up sound of a slow take in the project's `cache/sped-up/` folder, replacing the copy
    /// that was there. The folder is made if it is missing.
    public static func write(_ samples: [Float], forRecording id: UUID, to package: ProjectPackage) throws {
        try FileManager.default.createDirectory(at: package.spedUpFolder, withIntermediateDirectories: true)
        try WavWriter.write(samples, channels: 1, to: package.spedUpFile(forRecording: id))
    }

    /// The sped-up sound that is kept for a slow take. Nil when none is kept, or when what is kept is not as
    /// long as the recording says its sound is: then it belongs to something else and is made again.
    public static func read(for recording: Recording, from package: ProjectPackage) -> [Float]? {
        guard let samples = try? RecordingLoader.read(package.spedUpFile(forRecording: recording.id)),
            samples.count == recording.lengthSamples
        else { return nil }
        return samples
    }

    /// The sound of a recording as everything but its file knows it: mono, 48,000 Hz, sample 0 first.
    ///
    /// For a take recorded at the song's own speed that is its file. For a take recorded slower it is the
    /// sped-up sound: the kept copy, or, when there is none, made again from the file and kept. The file in
    /// `takes/` is only read. A copy that cannot be written is no error: the sound is made again next time.
    public static func sound(of recording: Recording, in package: ProjectPackage) throws(RecordingLoadError) -> [Float] {
        guard let rate = recording.recordedSpeed else {
            return try RecordingLoader.read(package.url.appendingPathComponent(recording.file))
        }
        if let kept = read(for: recording, from: package) { return kept }
        let slow = try RecordingLoader.read(package.url.appendingPathComponent(recording.file))
        let made = make(from: slow, rate: rate).samples
        try? write(made, forRecording: recording.id, to: package)
        return made
    }
}

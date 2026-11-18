import Foundation
import LockstepAudio
import LockstepCore

/// What a recording leaves behind once it has ended and been looked at: one take, as always, or, when it was
/// recorded with Loop on, one take for every time the loop went round.
///
/// `make` is what Stop and Restart Recording call for every recording. Without a loop it is
/// `FinishedTake.make` and nothing else. With one, the long recording is divided into passes
/// (`LoopPasses.split`), each pass is written into the project as a recording file of its own, and the long
/// recording's file is deleted. Every pass is then a `FinishedTake` like any other, with its sound, its clip,
/// its waveform and its loudness, so it is normalised, written out as words and given its markers exactly as
/// any recording is.
///
/// A take that was recorded slower (`TakeCountIn.slow`) is looked at and divided in slow time, and then every
/// take is sped up and moved to song time (`FinishedTake.atFullTempo`). This is the one place that happens.
///
///     let finished = await FinishedPasses.make(from: captured, countedIn: counted, in: package)
///     model.keep(finished, on: trackID)      // one edit: "Record Clip", or "Record Takes" for a loop
struct FinishedPasses: Sendable {
    /// The takes, in the order recorded. Of an ordinary recording there is one, and it may be one that is
    /// thrown away (`FinishedTake.clipSamples` is nil).
    var takes: [FinishedTake]
    /// Which of `takes` becomes the active take of a loop recording: the last pass that ran its full length.
    /// Nil for an ordinary recording, where the newest take becomes active by itself.
    var active: Int?
    /// True when `takes` are the passes of a loop recording.
    var isLoopRecording: Bool

    /// Looks at a recording that has just ended: a take that was stopped, or an attempt that a restart kept.
    ///
    /// A recording made with Loop on in which the loop never came round is a take like any other. So is one
    /// whose passes could not be written into the project: the long recording is then kept whole, and nothing
    /// that was recorded is lost.
    ///
    /// - Parameters:
    ///   - take: what the recorder handed over when it stopped.
    ///   - counted: how the take was counted in, and the loop it went round in, if any.
    ///   - package: the project the take's file is in.
    @concurrent
    static func make(
        from take: CapturedTake,
        countedIn counted: TakeCountIn,
        in package: ProjectPackage
    ) async -> FinishedPasses {
        var finished: FinishedPasses
        if let loop = counted.loop, let passes = passes(of: take, countedIn: counted, loop: loop, in: package) {
            finished = passes
        } else {
            let whole = await FinishedTake.make(from: take, countedIn: counted, in: package)
            finished = FinishedPasses(takes: [whole], active: nil, isLoopRecording: false)
        }
        // A take that was recorded slower was looked at and cut in slow time, the time it was made in. Here,
        // where it is about to become a clip, each take is sped up and moved to song time. A loop recording's
        // passes each have a file of their own, so each is sped up from its own file.
        guard counted.slow.isSlow else { return finished }
        for index in finished.takes.indices {
            finished.takes[index] = await finished.takes[index].atFullTempo(recordedAt: counted.slow, in: package)
        }
        return finished
    }

    /// Makes a loop recording from a sound file, as if the file had just been recorded with Loop on and the
    /// count-in off, and its first sample was what the microphone heard on the loop's start. Its sound is
    /// written into the project as a recording, and from there on it is treated exactly like a loop
    /// recording from the microphone. This is what `-loopTake` uses, so an agent can check what happens
    /// after a loop recording without a microphone.
    ///
    /// - Parameters:
    ///   - url: a WAV file at 48,000 Hz. Of a file with more than one channel, the first is used.
    ///   - counted: a count-in that is off, for the loop (`TakeCountIn(loopingFrom:bars:...)` with 0 bars).
    @concurrent
    static func make(
        fromFile url: URL,
        countedIn counted: TakeCountIn,
        in package: ProjectPackage
    ) async throws(FinishedTake.FileFailure) -> FinishedPasses {
        let samples: [Float]
        do {
            samples = try RecordingLoader.read(url)
        } catch {
            throw error == .wrongSampleRate ? .wrongSampleRate : .unreadable
        }
        let recording = Recording(lengthSamples: samples.count, rawStart: counted.place)
        do {
            try FileManager.default.createDirectory(at: package.takesFolder, withIntermediateDirectories: true)
            try WavWriter.write(samples, channels: 1, to: package.url.appendingPathComponent(recording.file))
        } catch {
            throw .notWritten(error.localizedDescription)
        }
        return await make(from: CapturedTake(recording: recording, samples: samples), countedIn: counted, in: package)
    }

    /// Divides a loop recording into its passes and writes each into the project. Nil when it is not to be
    /// divided: the loop never came round, no pass is kept, or a pass could not be written.
    private static func passes(
        of take: CapturedTake,
        countedIn counted: TakeCountIn,
        loop: LoopRegion,
        in package: ProjectPackage
    ) -> FinishedPasses? {
        let capture = take.recording
        // The loop's start is looked for where it really is in the recording: moved back by the delay
        // measured for its headphones and microphone, as every pass will lie in the project.
        var placed = capture.movedBack { counted.delays[$0.key] }
        placed.lengthSamples = min(placed.lengthSamples, take.samples.count)
        let envelope = VoiceEnvelope.envelope(of: take.samples)
        let split = LoopPasses.split(
            placed,
            voicedStretches: envelope.voicedStretches(noiseFloorFrom: counted.fullLevelSample(of: placed)),
            loop: loop,
            grid: counted.grid,
            clickLeak: ClickRenderer.leak(of: counted.countIn, settings: counted.click)
        )
        guard !split.passes.isEmpty else { return nil }

        var takes: [FinishedTake] = []
        do {
            try FileManager.default.createDirectory(at: package.takesFolder, withIntermediateDirectories: true)
            for pass in split.passes {
                let samples = Array(take.samples[pass.samples])
                // Its start time puts the pass's first loop sample on the loop's start. The delay itself is
                // put on the recording when it is kept, as for any take, from the same measurement.
                let recording = Recording(
                    lengthSamples: samples.count,
                    rawStart: LoopPasses.rawStart(of: pass, loopStart: loop.start, delay: placed.delay),
                    devicePair: capture.devicePair
                )
                // Listed before it is written, so a file that was only half written is removed too.
                takes.append(FinishedTake(recording: recording, samples: samples))
                try WavWriter.write(samples, channels: 1, to: package.url.appendingPathComponent(recording.file))
                // The curve can always be worked out again from the recording, so a failed write is not an error.
                try? VoiceEnvelope.envelope(of: samples).write(forRecording: recording.id, to: package)
                let clip = (pass.clip.lowerBound - pass.samples.lowerBound)..<(pass.clip.upperBound - pass.samples.lowerBound)
                takes[takes.count - 1].clipSamples = clip
                takes[takes.count - 1].waveform = WaveformPyramid(interleaved: samples, channelCount: 1)
                takes[takes.count - 1].loudness = Loudness.integrated(Array(samples[clip]))
                // Every pass was aimed at the loop's start, which is what makes them takes of one line.
                takes[takes.count - 1].aim = counted.aim
            }
        } catch {
            // The long recording is still there. What was written of its passes goes.
            for written in takes {
                try? FileManager.default.removeItem(at: package.url.appendingPathComponent(written.recording.file))
                try? FileManager.default.removeItem(at: VoiceEnvelope.file(forRecording: written.recording.id, in: package))
            }
            return nil
        }
        // Every pass has its own file now. The long recording is in none of them and is not needed again.
        try? FileManager.default.removeItem(at: package.url.appendingPathComponent(capture.file))
        return FinishedPasses(takes: takes, active: split.active, isLoopRecording: true)
    }
}

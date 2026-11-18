import Accelerate
import AVFoundation
import LockstepCore
import Synchronization

/// What the window can ask about a take while it is being recorded.
public struct RecorderSnapshot: Sendable, Equatable {
    /// Whether a take is being recorded right now.
    public var isRecording: Bool
    /// The loudest sample of the latest block from the microphone, where 1 is the loudest a file can hold.
    public var peak: Float
    /// The loudest sample of the whole take so far. At 1 or above, the take has clipped.
    public var highestPeak: Float
    /// How much has been recorded so far, in samples at 48,000 Hz.
    public var lengthSamples: Int

    public init(isRecording: Bool = false, peak: Float = 0, highestPeak: Float = 0, lengthSamples: Int = 0) {
        self.isRecording = isRecording
        self.peak = peak
        self.highestPeak = highestPeak
        self.lengthSamples = lengthSamples
    }
}

/// A stretch of a take's waveform while it grows: the lowest and the highest sample of each block of
/// `WaveformPyramid.baseBlockSize` samples (256), the same blocks a finished recording is drawn from.
public struct LiveWaveform: Sendable, Equatable {
    /// The number of the first block given here, counted from the start of the take.
    public var firstBlock: Int
    public var minimums: [Float]
    public var maximums: [Float]

    public init(firstBlock: Int = 0, minimums: [Float] = [], maximums: [Float] = []) {
        self.firstBlock = firstBlock
        self.minimums = minimums
        self.maximums = maximums
    }
}

/// One block of sound as it came from the microphone: its first channel only, at the microphone's own rate.
struct InputBlock: Sendable {
    var samples: [Float]
    var sampleRate: Double
    /// The moment on the Mac's clock when the first of these samples was heard.
    var hostTime: UInt64

    /// Copies the first channel out of a buffer. Returns nil for an empty buffer and for one that does not hold
    /// floats (the Mac's microphones always deliver floats).
    init?(firstChannelOf buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        guard frames > 0, rate > 0, let channels = buffer.floatChannelData else { return nil }
        // With the channels woven together, the first channel is every `stride`-th value. Apart, the stride is 1.
        let stride = buffer.stride
        let first = channels[0]
        samples = [Float](unsafeUninitializedCapacity: frames) { values, count in
            for frame in 0..<frames {
                values[frame] = first[frame * stride]
            }
            count = frames
        }
        sampleRate = rate
        // A block that does not say when it was heard is taken to have ended just now.
        self.hostTime = hostTime
            ?? mach_absolute_time() &- AVAudioTime.hostTime(forSeconds: Double(frames) / rate)
    }
}

/// One take while it is being recorded: everything about recording that needs no microphone.
///
/// Blocks of sound are handed in with `take(_:hostTime:)`, from whatever thread they arrive on. The session keeps
/// the first channel, brings it to 48,000 Hz, writes it to the take's file on a queue of its own (so the thread
/// that delivers the sound never waits for the disk), keeps it in memory, and keeps the numbers the window draws
/// from. `finish()` ends the take.
///
/// The microphone itself is `Recorder`'s business. Tests hand this class blocks they made up.
final class RecordingSession: Sendable {
    /// The id of the recording being made.
    let id: UUID
    /// The take's file: `takes/<id>.wav` in the project.
    let url: URL

    private let writer: WavWriter
    /// Does the converting and the writing, one block after the other in the order they arrived.
    private let queue = DispatchQueue(label: "se.maxfahl.lockstep.recording", qos: .userInitiated)
    private let work: Mutex<Work>
    private let heard: Mutex<Heard>

    /// What only the queue uses.
    private struct Work {
        /// The rate of the first block. Every later block must have it.
        var sampleRate: Double?
        var resampler: TakeResampler?
        var finished = false
        /// The first thing that went wrong, if anything did.
        var failure: (any Error)?
    }

    /// What has been recorded so far. The window reads it while the queue adds to it.
    private struct Heard {
        var samples: [Float] = []
        var firstHostTime: UInt64?
        var peak: Float = 0
        var highestPeak: Float = 0
        var minimums: [Float] = []
        var maximums: [Float] = []

        /// Works out the lowest and highest sample of every block of 256 samples that has become full.
        mutating func addFullWaveformBlocks() {
            let size = WaveformPyramid.baseBlockSize
            let fullBlocks = samples.count / size
            guard fullBlocks > minimums.count else { return }
            samples.withUnsafeBufferPointer { values in
                guard let base = values.baseAddress else { return }
                for block in minimums.count..<fullBlocks {
                    var low: Float = 0
                    var high: Float = 0
                    vDSP_minv(base + block * size, 1, &low, vDSP_Length(size))
                    vDSP_maxv(base + block * size, 1, &high, vDSP_Length(size))
                    minimums.append(low)
                    maximums.append(high)
                }
            }
        }
    }

    /// Starts the take's file, empty, in the project's `takes` folder.
    init(id: UUID = UUID(), in package: ProjectPackage) throws {
        self.id = id
        url = package.url.appendingPathComponent(Recording.fileName(for: id))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try WavWriter(url: url, channels: 1)
        work = Mutex(Work())
        var heard = Heard()
        // Room for a minute up front, so the first lines of a take do not make the list move again and again.
        heard.samples.reserveCapacity(Int(Lockstep.sampleRate) * 60)
        self.heard = Mutex(heard)
    }

    // MARK: Taking sound

    /// Takes one block of sound. Safe to call from the thread the microphone's sound arrives on: it copies the
    /// first channel and returns, and the rest happens on the session's own queue.
    ///
    /// - Parameter hostTime: the moment on the Mac's clock when the block's first sample was heard, if known.
    func take(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
        guard let block = InputBlock(firstChannelOf: buffer, hostTime: hostTime) else { return }
        queue.async { self.process(block) }
    }

    private func process(_ block: InputBlock) {
        let converted: [Float]? = work.withLock { work in
            guard !work.finished, work.failure == nil else { return nil }
            if work.sampleRate == nil {
                work.sampleRate = block.sampleRate
                if block.sampleRate != Lockstep.sampleRate {
                    work.resampler = TakeResampler(sampleRate: block.sampleRate)
                    if work.resampler == nil { work.failure = RecorderError.unusableInput }
                }
            }
            // A microphone cannot change its rate in the middle of a take without the take being stopped.
            guard work.failure == nil, block.sampleRate == work.sampleRate else { return nil }
            guard let resampler = work.resampler else { return block.samples }
            return resampler.convert(block.samples)
        }
        guard let converted else { return }
        keep(converted, peak: vDSP.maximumMagnitude(block.samples), hostTime: block.hostTime)
    }

    /// Adds converted sound to the take: to memory, to the waveform and to the file.
    private func keep(_ samples: [Float], peak: Float?, hostTime: UInt64?) {
        heard.withLock { heard in
            // Sample 0 of the take is the first sample of the first block, also when the converter has not let
            // any of that block go yet.
            if heard.firstHostTime == nil { heard.firstHostTime = hostTime }
            if let peak {
                heard.peak = peak
                heard.highestPeak = max(heard.highestPeak, peak)
            }
            heard.samples.append(contentsOf: samples)
            heard.addFullWaveformBlocks()
        }
        guard !samples.isEmpty else { return }
        do {
            try writer.append(samples)
        } catch {
            work.withLock { $0.failure = $0.failure ?? error }
        }
    }

    // MARK: Reading

    func snapshot() -> RecorderSnapshot {
        heard.withLock {
            RecorderSnapshot(
                isRecording: true,
                peak: $0.peak,
                highestPeak: $0.highestPeak,
                lengthSamples: $0.samples.count
            )
        }
    }

    /// The take's waveform from block `firstBlock` to the last full block recorded so far.
    func waveform(fromBlock firstBlock: Int) -> LiveWaveform {
        heard.withLock { heard in
            let first = min(max(firstBlock, 0), heard.minimums.count)
            return LiveWaveform(
                firstBlock: first,
                minimums: Array(heard.minimums[first...]),
                maximums: Array(heard.maximums[first...])
            )
        }
    }

    // MARK: Ending

    /// What a finished take leaves behind.
    struct Finished: Sendable {
        /// The whole take: mono, 48,000 Hz. The file holds the same.
        var samples: [Float]
        /// The moment on the Mac's clock when sample 0 was heard, or nil when no sound ever arrived.
        var firstHostTime: UInt64?

        /// The song time of sample 0, before the calibrated delay is removed (`Recording.rawStart`).
        ///
        /// - Parameters:
        ///   - songPosition: the place in the song where playback was started for this take, in song seconds.
        ///   - songStartHostTime: the moment on the Mac's clock that playback was asked to start at.
        func rawStart(songPosition: Double, songStartHostTime: UInt64, clock: HostClock) -> Double {
            // A take in which no sound ever arrived has no first moment. It is put where playback started.
            guard let firstHostTime else { return songPosition }
            return RecordingPlacement.rawStart(
                playbackStartPosition: songPosition,
                songStartHostTime: songStartHostTime,
                firstInputHostTime: firstHostTime,
                clock: clock
            )
        }
    }

    /// Ends the take: writes what is still on its way, closes the file and hands over the sound.
    /// Sound that arrives after this is ignored.
    func finish() throws -> Finished {
        // The queue works through its blocks in order, so everything handed in before this is written first.
        let failure: (any Error)? = queue.sync {
            let tail: [Float]? = work.withLock { work in
                guard !work.finished else { return nil }
                work.finished = true
                return work.failure == nil ? work.resampler?.finish() : nil
            }
            if let tail, !tail.isEmpty {
                keep(tail, peak: nil, hostTime: nil)
            }
            return work.withLock { $0.failure }
        }
        let finished = heard.withLock { heard in
            let samples = heard.samples
            heard.samples = []
            return Finished(samples: samples, firstHostTime: heard.firstHostTime)
        }
        if let failure {
            guard !(failure is RecorderError) else { throw failure }
            // The file could not be written while recording (a full disk, for one). The take is still whole in
            // memory, so the file is written once more, in one go. If that fails too, the take cannot be kept.
            try? writer.close()
            try WavWriter.write(finished.samples, channels: 1, to: url)
        } else {
            try writer.close()
        }
        return finished
    }

    /// Waits until every block handed in so far has been written to the file. For tests.
    func waitUntilWritten() {
        queue.sync {}
    }
}

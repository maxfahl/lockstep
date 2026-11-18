import AVFoundation
import LockstepCore
import Synchronization

/// Why a take could not be started or kept. Problems with the disk arrive as the system's own errors.
public enum RecorderError: Error, Equatable, Sendable {
    /// `start` was called while a take is being recorded.
    case alreadyRecording
    /// `stop` was called while nothing is being recorded.
    case notRecording
    /// Lockstep has not been allowed to use the microphone. The app asks before it starts a take; the recorder
    /// itself never makes macOS ask.
    case microphoneNotAllowed
    /// The Mac has no microphone to record from.
    case noInputDevice
    /// The microphone delivers sound in a form that cannot be brought to 48,000 Hz.
    case unusableInput
}

/// A finished take: its place in the project, and its sound.
public struct CapturedTake: Sendable {
    /// The recording as it goes into the project. Its file is already written, at `recording.file` in the project.
    public var recording: Recording
    /// The whole take in memory, mono at 48,000 Hz, for drawing it and playing it at once. The file holds the same.
    public var samples: [Float]

    public init(recording: Recording, samples: [Float]) {
        self.recording = recording
        self.samples = samples
    }
}

/// The attempt that Restart Recording dropped: what was recorded from the start of the attempt until the restart.
/// No more sound reaches it. `end` decides what becomes of it.
public struct DroppedAttempt: Sendable {
    /// The id of the attempt's recording. Its file is `takes/<id>.wav` in the project.
    public var id: UUID { session.id }

    let session: RecordingSession
    /// The sound output and the microphone the attempt was made with, if the Mac said which they are.
    let devicePair: DevicePair?

    /// Ends the attempt the way the setting "When restarting, keep the dropped attempt" says.
    ///
    /// - Thrown away (`keeping` false): its file is closed and deleted, and nothing is handed back.
    /// - Kept (`keeping` true): its file is closed and stays, and the attempt is handed back exactly like a take
    ///   that was stopped, to become a clip. If the file cannot be closed and kept, the error is thrown and no
    ///   file is left behind.
    ///
    /// The two positions say how the song was started for this attempt, as for `Recorder.stop`.
    ///
    /// - Parameters:
    ///   - songPosition: the place in the song where playback started for the attempt, in song seconds.
    ///   - songStartHostTime: the moment on the Mac's clock that playback was asked to start at.
    public func end(keeping: Bool, songPosition: Double, songStartHostTime: UInt64) throws -> CapturedTake? {
        guard keeping else {
            _ = try? session.finish()
            try? FileManager.default.removeItem(at: session.url)
            return nil
        }
        do {
            return try session.capture(
                songPosition: songPosition,
                songStartHostTime: songStartHostTime,
                devicePair: devicePair
            )
        } catch {
            try? FileManager.default.removeItem(at: session.url)
            throw error
        }
    }
}

extension RecordingSession {
    /// Ends the take and hands it over as it goes into the project: with its length and its place in the song.
    fileprivate func capture(songPosition: Double, songStartHostTime: UInt64, devicePair: DevicePair?) throws -> CapturedTake {
        let finished = try finish()
        let recording = Recording(
            id: id,
            lengthSamples: finished.samples.count,
            rawStart: finished.rawStart(songPosition: songPosition, songStartHostTime: songStartHostTime, clock: .system),
            devicePair: devicePair
        )
        return CapturedTake(recording: recording, samples: finished.samples)
    }
}

/// Records the Mac's current microphone to a file in the project.
///
/// The microphone is open only between `start` and `stop`. Each take gets an audio engine of its own, apart from
/// the one that plays the song: an engine that has ever used the microphone keeps the microphone light on whenever
/// it runs, so the playing engine must never touch it. A new engine for every take also means every take follows
/// the microphone the Mac uses at that moment.
///
/// `restart` drops the attempt that is being recorded and begins the next one without closing the microphone:
/// only the file the sound goes to changes, which takes about a millisecond. Opening a microphone takes far
/// longer than Restart Recording may.
///
/// `start`, `restart` and `stop` are `async` and run away from the main thread. `snapshot()` and
/// `waveform(fromBlock:)` answer at once from any thread, so the window can ask on every display frame.
public actor Recorder {
    /// How many samples the microphone is asked to deliver at a time (about 21 ms). The Mac may choose otherwise.
    static let tapFrames: AVAudioFrameCount = 1_024

    /// The open microphone. Touched only by `start`, `stop` and `renderOffline`.
    private nonisolated let engine: Mutex<CaptureEngine?>
    /// The take being recorded, where the window can read it without waiting for the engine.
    private nonisolated let session: Mutex<RecordingSession?>
    /// Made-up microphone sound, in tests and in an agent's run of the app with `-recordTake`. Nil when
    /// Lockstep runs for Max.
    private nonisolated let offlineInput: OfflineInput?
    /// The sound output and the microphone the current take is being made with, if the Mac said which they are.
    private var devicePair: DevicePair?

    public init() {
        engine = Mutex(nil)
        session = Mutex(nil)
        offlineInput = nil
    }

    /// A recorder that never touches the microphone: its engine is not connected to any sound device, and "the
    /// microphone" delivers `samples` whenever `renderOffline(frames:)` asks for more. The engine and the block
    /// that receives the sound are the real ones, so tests can run them with nothing being recorded.
    ///
    /// The app makes one only in an agent's run with `-recordTake`, so that a take can be run from Record to
    /// the finished clip with a sound file in the microphone's place.
    ///
    /// - Parameter samples: one list of samples for each channel, all the same length.
    public init(offlineInput samples: [[Float]], sampleRate: Double) throws {
        engine = Mutex(nil)
        session = Mutex(nil)
        offlineInput = try OfflineInput(channels: samples, sampleRate: sampleRate)
    }

    deinit {
        engine.withLock { $0?.close() }
    }

    // MARK: Reading

    /// The level and length of the take right now. Safe to call from any thread.
    public nonisolated func snapshot() -> RecorderSnapshot {
        session.withLock { $0 }?.snapshot() ?? RecorderSnapshot()
    }

    /// The waveform of the take being recorded, from block `firstBlock` on, so the window can ask for only what
    /// is new since it last asked. Empty while nothing is being recorded.
    public nonisolated func waveform(fromBlock firstBlock: Int) -> LiveWaveform {
        session.withLock { $0 }?.waveform(fromBlock: firstBlock) ?? LiveWaveform()
    }

    // MARK: Controlling

    /// Opens the microphone and starts a take. Its sound goes to `takes/<id>.wav` in the project as it arrives.
    ///
    /// The app must have been allowed to use the microphone before this is called.
    ///
    /// - Returns: the id of the recording being made.
    @discardableResult
    public func start(in package: ProjectPackage) throws -> UUID {
        guard session.withLock({ $0 == nil }) else { throw RecorderError.alreadyRecording }
        // Opening the microphone without permission would make macOS ask, with nobody expecting the question.
        if offlineInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            throw RecorderError.microphoneNotAllowed
        }
        let take = try RecordingSession(in: package)
        // Read at the moment the microphone is opened, so it names the devices this take is really made with.
        // A recorder with a made-up microphone uses no device.
        devicePair = offlineInput == nil ? AudioDevices.currentPair() : nil
        do {
            let offlineInput = offlineInput
            try engine.withLock { engine in
                engine = try offlineInput.map { try CaptureEngine(offline: $0, into: take) }
                    ?? CaptureEngine(microphoneInto: take)
            }
        } catch {
            // No take was made, so no file is left behind.
            _ = try? take.finish()
            try? FileManager.default.removeItem(at: take.url)
            throw error
        }
        session.withLock { $0 = take }
        return take.id
    }

    /// Stops the take and closes the microphone, so the Mac's microphone light goes out.
    ///
    /// The two parameters say how the song was started for this take: they are the two values that were given to
    /// `PlaybackEngine.start(from:atHostTime:)`. From them and the moment the microphone was first heard, the
    /// recording gets its place in the song (`rawStart`). The microphone is opened before the song starts, so the
    /// recording begins a moment before `songPosition`; at the very start of the song that is a little below zero.
    ///
    /// - Parameters:
    ///   - songPosition: the place in the song where playback started, in song seconds (the start of the run-up).
    ///   - songStartHostTime: the moment on the Mac's clock that playback was asked to start at.
    /// - Returns: the recording, with its length and its place in the song, and its sound.
    public func stop(songPosition: Double, songStartHostTime: UInt64) throws -> CapturedTake {
        guard let take = session.withLock({ $0 }) else { throw RecorderError.notRecording }
        engine.withLock {
            $0?.close()
            $0 = nil
        }
        session.withLock { $0 = nil }
        return try take.capture(songPosition: songPosition, songStartHostTime: songStartHostTime, devicePair: devicePair)
    }

    /// Drops the attempt that is being recorded and begins the next one, for Restart Recording. The microphone
    /// stays open and loses nothing: from one block of sound to the next, the sound goes to a new file in the
    /// project. Every block ends up in exactly one of the two attempts.
    ///
    /// What becomes of the dropped attempt is the caller's choice, made with what is handed back
    /// (`DroppedAttempt.end(keeping:songPosition:songStartHostTime:)`). That can wait until the song has been
    /// started again, so it costs the restart no time.
    ///
    /// If the new file cannot be made, the error is thrown and the attempt that is going goes on untouched.
    ///
    /// - Returns: the attempt that was dropped. Nothing more is added to it.
    public func restart(in package: ProjectPackage) throws -> DroppedAttempt {
        guard session.withLock({ $0 != nil }) else { throw RecorderError.notRecording }
        let fresh = try RecordingSession(in: package)
        guard let dropped = engine.withLock({ $0?.target.change(to: fresh) }) else {
            // No open microphone to hand the new file to. It is not left behind.
            _ = try? fresh.finish()
            try? FileManager.default.removeItem(at: fresh.url)
            throw RecorderError.notRecording
        }
        session.withLock { $0 = fresh }
        // The microphone was not opened again, so the devices are the ones the take was started with.
        return DroppedAttempt(session: dropped, devicePair: devicePair)
    }

    /// The moment on the Mac's clock that lies `seconds` from now: the host time to start the song at, given to
    /// both `PlaybackEngine.start(from:atHostTime:)` and, when the take ends, `stop(songPosition:songStartHostTime:)`.
    public nonisolated static func hostTime(in seconds: Double) -> UInt64 {
        mach_absolute_time() + HostClock.system.ticks(forSeconds: seconds)
    }

    // MARK: For tests and for a take without a microphone

    /// Lets the made-up microphone deliver its next `frames` samples.
    /// Works only on a recorder made with `init(offlineInput:sampleRate:)`, and only while a take is going.
    /// It throws when no take is going and when the made-up sound has run out.
    ///
    /// It runs on the caller's thread, not on the recorder's own, the way the Mac calls with real sound.
    /// Nothing asks by itself: whoever made the recorder calls this as time goes, as often as sound is due.
    public nonisolated func renderOffline(frames: Int) throws {
        try engine.withLock { engine in
            guard let engine else { throw OfflineRenderingFailed() }
            try engine.renderOffline(frames: frames)
        }
    }
}

// MARK: - Blocks the system calls

/// Every block the recorder hands to the system is made here.
///
/// The system calls these on threads of its own. A block written inside the actor would be checked against the
/// actor's thread when it runs and would crash the app. So each one is made in a function that belongs to no actor,
/// is `@Sendable`, and holds only things that are safe to use from any thread.
private enum CaptureBlocks {
    /// For the microphone: a block of sound has arrived. All it does is hand the sound to the attempt that is
    /// being recorded at that moment.
    nonisolated static func tap(into target: CaptureTarget) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, when in
            target.take(buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil)
        }
    }

    /// For an engine without a sound device: it wants the next samples of the made-up microphone.
    nonisolated static func offlineInput(
        from input: OfflineInput
    ) -> @Sendable (AVAudioFrameCount) -> UnsafePointer<AudioBufferList>? {
        { frames in
            input.next(frames: Int(frames))
        }
    }
}

// MARK: - The audio engine

/// Where the microphone's sound goes right now: the attempt that is being recorded.
///
/// The block that receives the sound holds this, not the attempt itself, so Restart Recording can put another
/// attempt in its place while the microphone stays open. The attempt is kept under a lock, which is what makes
/// it safe to change from the recorder while the system's thread delivers sound.
private final class CaptureTarget: Sendable {
    private let session: Mutex<RecordingSession>

    init(_ session: RecordingSession) {
        self.session = Mutex(session)
    }

    /// Hands a block of sound to the attempt that is being recorded. The handing over happens under the lock,
    /// so a block can never reach an attempt that has already been put aside and closed.
    func take(_ buffer: AVAudioPCMBuffer, hostTime: UInt64?) {
        session.withLock { $0.take(buffer, hostTime: hostTime) }
    }

    /// Puts another attempt in place of the one that was being recorded.
    ///
    /// - Returns: the attempt that was there. No more sound reaches it.
    func change(to fresh: RecordingSession) -> RecordingSession {
        session.withLock { current in
            let dropped = current
            current = fresh
            return dropped
        }
    }
}

/// The audio engine of one take, with the microphone as its only part.
private struct CaptureEngine {
    let engine = AVAudioEngine()
    /// Where the microphone's sound goes. A restart changes the attempt in it and leaves the engine alone.
    let target: CaptureTarget

    /// Opens the Mac's current microphone and sends its sound to `session`.
    init(microphoneInto session: RecordingSession) throws {
        target = CaptureTarget(session)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        // The sound is taken in the microphone's own form. `RecordingSession` brings it to 48,000 Hz mono.
        input.installTap(onBus: 0, bufferSize: Recorder.tapFrames, format: nil, block: CaptureBlocks.tap(into: target))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// An engine with no sound device, whose "microphone" is made-up sound.
    init(offline source: OfflineInput, into session: RecordingSession) throws {
        target = CaptureTarget(session)
        try engine.enableManualRenderingMode(.offline, format: source.format, maximumFrameCount: OfflineInput.maximumFrames)
        let input = engine.inputNode
        guard input.setManualRenderingInputPCMFormat(source.format, inputBlock: CaptureBlocks.offlineInput(from: source)) else {
            throw OfflineRenderingFailed()
        }
        // Such an engine produces sound only when something asks for its output, so the microphone is led there.
        engine.connect(input, to: engine.mainMixerNode, format: source.format)
        input.installTap(onBus: 0, bufferSize: Recorder.tapFrames, format: nil, block: CaptureBlocks.tap(into: target))
        engine.prepare()
        try engine.start()
    }

    /// Stops listening and lets go of the microphone.
    func close() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func renderOffline(frames: Int) throws {
        guard engine.isInManualRenderingMode, engine.isRunning,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: engine.manualRenderingFormat,
                  frameCapacity: engine.manualRenderingMaximumFrameCount
              )
        else { throw OfflineRenderingFailed() }
        var rendered = 0
        while rendered < frames {
            let wanted = min(AVAudioFrameCount(frames - rendered), buffer.frameCapacity)
            let status = try engine.renderOffline(wanted, to: buffer)
            guard status == .success, buffer.frameLength > 0 else { throw OfflineRenderingFailed() }
            rendered += Int(buffer.frameLength)
        }
    }
}

// MARK: - A made-up microphone

/// Sound that stands in for the microphone in tests. The samples never change after it is made, and the place
/// reached in them is kept under a lock, which is what makes it safe to read from the engine's thread.
private final class OfflineInput: @unchecked Sendable {
    /// The most samples the engine may ask for at a time.
    static let maximumFrames: AVAudioFrameCount = 4_096

    let format: AVAudioFormat
    private let length: Int
    /// The samples of every channel, one channel after the other.
    private let memory: UnsafeMutablePointer<Float>
    /// Where the engine is told to find the next samples of each channel.
    private let list: UnsafeMutableAudioBufferListPointer
    private let position = Mutex(0)

    init(channels: [[Float]], sampleRate: Double) throws {
        let length = channels.first?.count ?? 0
        guard
            length > 0, channels.allSatisfy({ $0.count == length }),
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count))
        else { throw OfflineRenderingFailed() }
        self.format = format
        self.length = length
        memory = UnsafeMutablePointer<Float>.allocate(capacity: length * channels.count)
        for (index, channel) in channels.enumerated() {
            (memory + index * length).initialize(from: channel, count: length)
        }
        list = AudioBufferList.allocate(maximumBuffers: channels.count)
    }

    deinit {
        memory.deallocate()
        free(list.unsafeMutablePointer)
    }

    /// The next `frames` samples of every channel, or nil when the made-up sound has run out.
    func next(frames: Int) -> UnsafePointer<AudioBufferList>? {
        position.withLock { position in
            guard frames > 0, position + frames <= length else { return nil }
            for channel in 0..<list.count {
                list[channel] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: memory + channel * length + position
                )
            }
            position += frames
            return UnsafePointer(list.unsafeMutablePointer)
        }
    }
}

// MARK: - The Mac's clock

extension HostClock {
    /// How this Mac's clock counts, as the system reports it (`mach_timebase_info`).
    public static let system: HostClock = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return HostClock(numerator: info.numer, denominator: info.denom)
    }()
}

import Foundation
import LockstepCore

/// Why a calibration gave no delay.
public enum CalibrationFailure: Error, Sendable, Equatable {
    /// The microphone heard too little of the ticks to say where they are: the headphone was not close enough,
    /// the volume was too low, or the sound was off. The calibrate sheet's "Could not hear the ticks. Try again
    /// closer or louder."
    case notHeard
    /// Lockstep has not been allowed to use the microphone. The app asks before it calibrates, as it does
    /// before a take; the run itself never makes macOS ask.
    case microphoneNotAllowed
    /// The Mac has no microphone, or the microphone could not be opened.
    case noMicrophone
    /// A take is being recorded. Nothing was touched: the song plays on and the take goes on.
    case busy
    /// The ticks could not be played, or not at the moment they were due, so nothing can be said about the delay.
    case couldNotPlay
    /// The sound output or the microphone changed while the ticks played (AirPods connected, for one), or the
    /// Mac does not say which devices it uses. The delay would belong to no pair of devices.
    case devicesChanged
    /// The run was called off before it ended (its task was cancelled).
    case cancelled
}

/// What a calibration found: the delay, or why there is none, and in both cases the sound devices in use.
public enum CalibrationOutcome: Sendable, Equatable {
    /// The ticks were heard.
    ///
    /// - `delay`: how late a sound arrives in a recording made with these devices, in seconds. This is what
    ///   `Recording.delay` holds.
    /// - `quality`: from 0 to 1, how clean the ticks were in the recording (`DelayCalibration.Result`).
    /// - `devices`: the sound output and the microphone that were measured.
    /// - `outputIsWireless`: whether that output is a Bluetooth device, whose delay only holds until it
    ///   disconnects.
    case measured(delay: Double, quality: Double, devices: DevicePair, outputIsWireless: Bool)
    /// No delay. `devices` are the ones the Mac was using, when it said which.
    case failed(CalibrationFailure, devices: DevicePair?, outputIsWireless: Bool)

    /// The sound output and the microphone the run was made with, if the Mac said which they are.
    public var devices: DevicePair? {
        switch self {
        case .measured(_, _, let devices, _): devices
        case .failed(_, let devices, _): devices
        }
    }

    /// Whether the sound output is a Bluetooth device.
    public var outputIsWireless: Bool {
        switch self {
        case .measured(_, _, _, let wireless), .failed(_, _, let wireless): wireless
        }
    }
}

/// One calibration: plays the test ticks through the headphones, records them with the microphone, and works out
/// how late they arrived.
///
///     switch await CalibrationRun.run(with: engine, recorder: recorder) {
///     case .measured(let delay, _, let devices, let wireless):
///         settings.setDelay(delay, for: devices, wireless: wireless)
///     case .failed(let reason, _, _):
///         // show why, and offer Start again
///     }
///
/// The ticks go the way the song goes in a take, and the microphone is opened the way a take opens it: the same
/// two engines, the same clock arithmetic. So the delay that comes out is the one takes get: the time from
/// Lockstep handing a sound to the Mac until that sound is in the recording.
///
/// The run takes a little over four seconds. Nothing is added to a project: the recording goes to a folder of
/// its own among the Mac's temporary files, which is deleted before the run returns.
public enum CalibrationRun {
    /// How far ahead of "now" the ticks are asked to start, in seconds. Longer than for a take, so a sound
    /// output that was resting is awake when the moment comes.
    static let startLead: Double = 0.3
    /// How long the microphone goes on listening after the latest moment the last tick could arrive, in seconds.
    /// The microphone hands its sound over in blocks, a moment after it was heard.
    static let listeningMargin: Double = 0.25

    /// Runs one calibration and returns what it found. It never throws: every way it can go wrong is a
    /// `CalibrationFailure` in the outcome.
    ///
    /// Before calling:
    /// - The app must have been allowed to use the microphone (ask as before a take). Without it the outcome is
    ///   `.microphoneNotAllowed` and no sound is played.
    /// - Stop the song the app's own way, so the window knows. The run stops the engine's playback too, but
    ///   tells nobody.
    ///
    /// The Mac's sound output plays the ticks at the volume the Mac is set to. On a silent engine nothing is
    /// heard and the outcome is `.notHeard`. Cancelling the task that waits for the run ends it within a moment,
    /// with `.cancelled`.
    ///
    /// - Parameters:
    ///   - engine: the app's playback engine, the one that plays the song in a take.
    ///   - recorder: the app's recorder, the one takes are made with. While it is recording a take the run
    ///     does nothing and the outcome is `.busy`.
    public static func run(with engine: PlaybackEngine, recorder: Recorder) async -> CalibrationOutcome {
        let ticks = DelayCalibration.tickSignal()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lockstep calibration \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // The microphone first, as in a take, so it is listening well before the first tick.
        do {
            try await recorder.start(in: ProjectPackage(url: folder))
        } catch {
            return failed(failure(forNotStarting: error), devices: AudioDevices.currentPair())
        }

        let hostTime = Recorder.hostTime(in: startLead)
        var played = false
        var cancelled = false
        do {
            try await engine.playTicks(ticks.samples, atHostTime: hostTime)
            // If getting the sound output going took longer than the lead, the ticks started late by a time
            // nobody knows, and the delay measured from them would be too long by that much.
            played = Recorder.hostTime(in: 0) < hostTime
        } catch {
            played = false
        }
        if played {
            do {
                try await Task.sleep(for: .seconds(startLead + ticks.listeningSeconds + listeningMargin))
            } catch {
                cancelled = true
            }
        }

        await engine.stop()
        let take = try? await recorder.stop(songPosition: 0, songStartHostTime: hostTime)
        let devicesNow = AudioDevices.currentPair()
        if cancelled { return failed(.cancelled, devices: devicesNow) }
        guard played else { return failed(.couldNotPlay, devices: devicesNow) }
        guard let take else { return failed(.noMicrophone, devices: devicesNow) }
        return outcome(
            of: take,
            playing: ticks,
            devicesAfter: devicesNow,
            outputIsWireless: devicesNow.map { AudioDevices.isWireless(uid: $0.outputUID) } ?? false
        )
    }

    /// What a finished recording of the ticks says. This is everything that comes after the microphone is
    /// closed, and it needs no sound device.
    ///
    /// - Parameters:
    ///   - take: the recording, placed as a take is: its `rawStart` is when its first sample was heard, counted
    ///     from the moment the first sample of the ticks was due. Its `devicePair` is what the Mac was using when
    ///     the microphone was opened.
    ///   - ticks: the ticks that were played.
    ///   - devicesAfter: what the Mac was using when the run ended.
    static func outcome(
        of take: CapturedTake,
        playing ticks: DelayCalibration.TickSignal,
        devicesAfter: DevicePair?,
        outputIsWireless: Bool
    ) -> CalibrationOutcome {
        guard let devices = take.recording.devicePair, devices == devicesAfter else {
            return .failed(.devicesChanged, devices: devicesAfter, outputIsWireless: outputIsWireless)
        }
        let result = DelayCalibration.estimate(
            played: ticks,
            recorded: take.samples,
            recordedStart: take.recording.rawStart
        )
        switch result {
        case .measured(let delay, let quality):
            return .measured(delay: delay, quality: quality, devices: devices, outputIsWireless: outputIsWireless)
        case .failed:
            return .failed(.notHeard, devices: devices, outputIsWireless: outputIsWireless)
        }
    }

    /// Why the microphone could not be opened for the run.
    static func failure(forNotStarting error: any Error) -> CalibrationFailure {
        switch error as? RecorderError {
        case .alreadyRecording: .busy
        case .microphoneNotAllowed: .microphoneNotAllowed
        default: .noMicrophone
        }
    }

    private static func failed(_ failure: CalibrationFailure, devices: DevicePair?) -> CalibrationOutcome {
        .failed(
            failure,
            devices: devices,
            outputIsWireless: devices.map { AudioDevices.isWireless(uid: $0.outputUID) } ?? false
        )
    }
}

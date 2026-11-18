import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import Observation

/// Calibration, a part of the app's model: measuring how late the headphones and the microphone are.
///
/// Transport > Calibrate Delay..., or a press on the delay in the panel on the right, opens
/// the calibrate sheet (`openCalibrateSheet`). The sheet is drawn by `MainLayout` from
/// `calibrationSheet`, and its buttons come back here through `calibrationActions`, which is on `AppModel`.
///
/// Start (`startCalibration`) asks for the microphone as Record does, stops the song, plays
/// the test ticks and records them (`CalibrationRun`, about four seconds). The sheet then
/// shows the delay in milliseconds, or says why there is none. A delay that was measured is
/// kept in the settings for this pair of headphones and microphone
/// (`AppSettings.setDelay`), not in the project.
///
/// Recordings are moved back by the delay of the pair they were made with
/// (`ProjectDelays.swift` in `LockstepCore`): a new recording when it becomes a clip
/// (`keep`), the open project's earlier recordings of the pair right after a measurement
/// (`applyDelay`, one undo step, "Apply Delay"), and a project's recordings when it is
/// opened (`withStoredDelays`).
///
/// The delay in the panel on the right is the one in use for the sound output and the
/// microphone the Mac is using right now, or "Not calibrated". It follows the Mac's
/// devices (`SoundDeviceWatch`) and the settings (`followDelay`). The settings window
/// lists every measured delay (`MeasuredDelaysSection`).
///
/// While the sheet is open no other command acts (`canPerform`). Closing it during a
/// measurement calls the measurement off.
///
/// A run started with `-silent` never measures: Start opens no microphone and plays nothing,
/// and the sheet and a line on standard error say so.
@MainActor
@Observable
final class CalibrationModel {
    // The ground it is handed.
    @ObservationIgnored private let windowState: WindowState
    @ObservationIgnored private let loadedSounds: LoadedSounds
    @ObservationIgnored private let takeStatus: TakeStatus
    @ObservationIgnored private let player: Player
    @ObservationIgnored private let recorder: Recorder
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let settings: AppSettings

    // The parts it is handed, and calls directly.
    @ObservationIgnored private let clips: ClipsModel
    @ObservationIgnored private let transport: TransportModel

    // MARK: What it keeps

    /// What the calibrate sheet shows while it is open, or nil while it is closed. The
    /// window draws it from `content`, which is made anew for every song that is opened,
    /// so it is kept here as well.
    var calibrationSheet: CalibrationContent? {
        didSet {
            if windowState.content.calibration != calibrationSheet { windowState.content.calibration = calibrationSheet }
        }
    }
    /// The measurement that the sheet's Start button started and that has not ended, or nil.
    @ObservationIgnored var calibrationRun: Task<Void, Never>?
    /// The sound output and the microphone the Mac is using right now, or nil when it has
    /// none or does not say. The settings window reads it to know which measured delay
    /// can be measured again.
    var currentDevices: DevicePair?
    /// The delay the panel on the right shows: the one in use for `currentDevices`, in
    /// milliseconds, or nil for "Not calibrated". Kept here as well as in `content`, like
    /// `calibrationSheet`.
    @ObservationIgnored var shownDelayMilliseconds: Int? {
        didSet {
            if windowState.content.delayMilliseconds != shownDelayMilliseconds { windowState.content.delayMilliseconds = shownDelayMilliseconds }
        }
    }

    init(
        windowState: WindowState,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        player: Player,
        recorder: Recorder,
        store: ProjectStore,
        settings: AppSettings,
        clips: ClipsModel,
        transport: TransportModel
    ) {
        self.windowState = windowState
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.player = player
        self.recorder = recorder
        self.store = store
        self.settings = settings
        self.clips = clips
        self.transport = transport
    }

    /// Opens the calibrate sheet on the headphones and the microphone the Mac is using
    /// right now, with nothing measured yet.
    func openCalibrateSheet() {
        guard calibrationSheet == nil, takeStatus.phase == nil else { return }
        let devices = AudioDevices.currentPair()
        calibrationSheet = Self.calibrationContent(
            for: devices,
            wireless: devices.map { AudioDevices.isWireless(uid: $0.outputUID) } ?? false
        )
    }

    /// Close, Done or the Escape key: the sheet goes away, and a measurement that is
    /// under way is called off.
    func closeCalibrateSheet() {
        calibrationRun?.cancel()
        calibrationRun = nil
        calibrationSheet = nil
    }

    /// Start, Try Again or Measure Again: measures once. A press while a measurement is
    /// under way does nothing.
    func startCalibration() {
        guard calibrationSheet != nil, calibrationRun == nil, takeStatus.phase == nil else { return }
        // An agent's run. Nobody is there to hold a headphone to the microphone, and the
        // Mac must stay quiet, so nothing is opened and nothing is played.
        guard !LaunchOptions.current.isSilent else {
            refuseCalibration(
                saying: "Lockstep was started with its sound turned off (-silent), so nothing was measured.",
                toAgent: "did not calibrate because this is a -silent run: no ticks were played and the microphone was not opened"
            )
            return
        }
        calibrationRun = Task {
            let answer = await MicrophoneAccess.mayRecord()
            // The sheet was closed while macOS asked.
            guard !Task.isCancelled else { return }
            guard answer == .allowed else {
                calibrationRun = nil
                if answer == .notAskedInScratchRun {
                    refuseCalibration(
                        saying: "Lockstep has not been allowed to use the microphone yet, so nothing was measured.",
                        toAgent: "did not calibrate because the microphone has not been allowed and a -scratch run never asks"
                    )
                }
                return
            }
            let outcome = await measureDelay()
            guard !Task.isCancelled else { return }
            calibrationRun = nil
            calibrationEnded(outcome)
        }
    }

    /// A measurement has ended. A delay is kept for its pair of devices and shown in the
    /// sheet. Anything else is said in the sheet's failure box.
    private func calibrationEnded(_ outcome: LockstepAudio.CalibrationOutcome) {
        // The sheet was closed meanwhile. Nobody is waiting for the answer.
        guard calibrationSheet != nil else { return }
        switch outcome {
        case .measured(let delay, _, let devices, let wireless):
            settings.setDelay(delay, for: devices, wireless: wireless)
            applyDelay(delay, toRecordingsMadeWith: devices)
            calibrationSheet = Self.calibrationContent(
                for: devices,
                wireless: wireless,
                outcome: .measured(milliseconds: Self.milliseconds(delay))
            )
        case .failed(.cancelled, _, _):
            break
        case .failed(let reason, let devices, let wireless):
            calibrationSheet = Self.calibrationContent(
                for: devices,
                wireless: wireless,
                outcome: .failed,
                failureText: Self.words(for: reason)
            )
        }
    }

    /// Moves the recordings of the open project that were made with this pair before it was
    /// measured back by the new delay, as one step that can be undone ("Apply Delay"). A
    /// recording that already has a delay keeps it. When there is nothing to move, no undo
    /// step is made.
    private func applyDelay(_ delay: Double, toRecordingsMadeWith devices: DevicePair) {
        guard loadedSounds.song != nil, takeStatus.phase == nil,
            !store.project.recordingsWaitingForDelay(madeWith: devices).isEmpty
        else { return }
        store.edit("Apply Delay") { $0.applyDelay(delay, toRecordingsMadeWith: devices) }
        recordingsMoved()
    }

    /// A project as it is opened: every recording without a delay whose pair of devices has
    /// one in use gets it. `moved` says whether anything changed, so the project can be saved.
    func withStoredDelays(_ project: Project) -> (project: Project, moved: Bool) {
        var corrected = project
        let moved = corrected.applyStoredDelays { settings.delay(for: $0) } > 0
        return (corrected, moved)
    }

    /// Start was pressed and nothing may be measured: the sheet says why in its failure
    /// box, and so does a line on standard error for an agent that cannot see the sheet.
    private func refuseCalibration(saying text: String, toAgent line: String) {
        FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
        guard var sheet = calibrationSheet else { return }
        sheet.outcome = .failed
        sheet.failureText = text
        calibrationSheet = sheet
    }

    /// What the failure box says for each way a measurement can fail. Nil is the designed
    /// sentence, "Could not hear the ticks. Try again closer or louder."
    private static func words(for failure: CalibrationFailure) -> String? {
        switch failure {
        case .notHeard, .cancelled:
            nil
        case .microphoneNotAllowed:
            "Lockstep is not allowed to use the microphone. Allow it in System Settings, then try again."
        case .noMicrophone:
            "The microphone could not be opened. Check the sound input in System Settings, then try again."
        case .busy:
            "A recording is going on. Stop it, then try again."
        case .couldNotPlay:
            "The ticks could not be played. Check that the Mac has a sound output, then try again."
        case .devicesChanged:
            "The headphones or the microphone changed while the ticks played. Try again."
        }
    }

    // MARK: The delay in use

    /// Starts keeping the delay in the panel on the right in line with the headphones and
    /// the microphone the Mac is using. Called once, when the model is made.
    func followSoundDevices() {
        SoundDeviceWatch.start { [weak self] in self?.soundDevicesChanged() }
        soundDevicesChanged()
        followDelay()
    }

    /// The Mac uses another sound output or microphone, or a device was connected or
    /// disconnected. A wireless delay whose headphones are gone stops being used for good,
    /// and the window shows the delay of the pair in use now.
    private func soundDevicesChanged() {
        settings.endWirelessConnections(except: AudioDevices.connectedUIDs())
        let devices = AudioDevices.currentPair()
        if devices != currentDevices {
            currentDevices = devices
        }
        showDelay()
        // A sheet that is open and has measured nothing yet names the devices in use now.
        if let sheet = calibrationSheet, sheet.outcome == .notMeasured, calibrationRun == nil {
            calibrationSheet = Self.calibrationContent(
                for: devices,
                wireless: devices.map { AudioDevices.isWireless(uid: $0.outputUID) } ?? false
            )
        }
    }

    /// The delay in use for the devices the Mac is using, in seconds, or nil when that
    /// pair has none: never measured, removed, or wireless and measured in an earlier connection.
    private var delayInUse: Double? {
        currentDevices.flatMap { settings.delay(for: $0) }
    }

    private func showDelay() {
        shownDelayMilliseconds = delayInUse.map(Self.milliseconds)
    }

    /// Listens for the next change of the delay in use: a calibration, Remove or Restore
    /// Defaults in the settings window, or other devices. Called once at the start, and
    /// again after every change it heard of.
    private func followDelay() {
        withObservationTracking(
            { _ = delayInUse },
            onChange: Self.delayChangeReport(to: self)
        )
    }

    /// What is called when the delay in use is about to change. It is made here, outside
    /// the main actor, and comes back to the model on the main actor a moment later, when
    /// the new value is in place.
    private nonisolated static func delayChangeReport(to model: CalibrationModel) -> @Sendable () -> Void {
        { [weak model] in
            Task { @MainActor in
                model?.followDelay()
                model?.showDelay()
            }
        }
    }

    /// What the sheet shows for a pair of devices. A Mac that does not say which devices
    /// it uses gets "Unknown" for both.
    static func calibrationContent(
        for devices: DevicePair?,
        wireless: Bool,
        outcome: LockstepUI.CalibrationOutcome = .notMeasured,
        failureText: String? = nil
    ) -> CalibrationContent {
        CalibrationContent(
            headphones: Self.shownName(devices?.outputName),
            microphone: Self.shownName(devices?.inputName),
            headphonesAreWireless: wireless,
            outcome: outcome,
            failureText: failureText
        )
    }

    private static func shownName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "Unknown" }
        return name
    }

    /// A delay in whole milliseconds, as the sheet and the window write it.
    static func milliseconds(_ delay: Double) -> Int {
        Int((delay * 1000).rounded())
    }

    // MARK: The measurement

    /// Plays the test ticks and records them, and gives what the measurement found.
    ///
    /// The song is stopped first, the app's own way, so the window knows. The measurement
    /// then takes its turn in line with everything else the player is told, because it
    /// needs the player and the microphone to itself. Cancelling the task that waits for
    /// it ends it within a moment.
    func measureDelay() async -> LockstepAudio.CalibrationOutcome {
        if transport.takesStretch != nil {
            transport.endTakesStretch()
        } else if windowState.content.isPlaying {
            windowState.content.isPlaying = false
            player.tell { await $0.stop() }
        }
        let measuring = player.takeTurn { [engine = player.engine, recorder] in
            // Called off while it waited its turn: the microphone is not opened at all.
            let outcome = Task.isCancelled
                ? LockstepAudio.CalibrationOutcome.failed(.cancelled, devices: nil, outputIsWireless: false)
                : await CalibrationRun.run(with: engine, recorder: recorder)
            return outcome
        } afterNothingLeft: { outcome in
            // Given back to the one who waits, after the window was brought in line.
            outcome
        }
        return await withTaskCancellationHandler {
            await measuring.value
        } onCancel: {
            measuring.cancel()
        }
    }

    /// The recordings of the open project were moved by a new delay. The player and the
    /// window follow.
    func recordingsMoved() {
        clips.followClips(of: store.project)
    }
}

extension CalibrationModel {
    // MARK: A project opens

    /// A song or a project is about to be shown in place of what was open, and the window's
    /// content has just been made anew for it.
    func projectWillOpen() {
        // The calibrate sheet does not belong to a song. If it is open, it stays open.
        windowState.content.calibration = calibrationSheet
        windowState.content.delayMilliseconds = shownDelayMilliseconds
    }
}

extension AppModel {
    /// Gives `calibration` its closures: it has none, because everything it calls it is handed.
    /// `wire()` calls it once, when every part is made.
    func wireCalibration() {}
}

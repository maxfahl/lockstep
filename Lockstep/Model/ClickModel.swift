import AppKit
import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import UniformTypeIdentifiers

/// The click: a part of the app's model.
///
/// It holds the click the player ticks on the beats (on or off, its sound, volume, division and
/// sub-beats, the count-in), and the click file.
///
/// The click's settings are in `store.project.click` and are changed with `editClick`, one undo
/// step each. Whenever the beats or the click's settings change, `followClick` shows the settings
/// in the window, lays the click of the whole song out again in the background and hands it to
/// the player, which plays it beside the song.
///
/// The click popover also has the two rows about recording that are settings and not the song's:
/// the count-in and the recording speed (`chooseCountIn`, `chooseRecordSpeed`).
@MainActor
final class ClickModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let takeStatus: TakeStatus
    private let player: Player
    private let store: ProjectStore
    private let settings: AppSettings

    /// What the click that the player has, or is about to get, was laid out from.
    private var clickLayout: ClickLayout?
    /// The laying out of the click that is waiting or going on.
    private var clickRender: Task<Void, Never>?
    /// Where the click's volume slider stands while it is being dragged. The click is
    /// heard at this volume, and the project gets it when the slider is let go.
    var heldClickVolume: Double?
    /// True once the click file asked for with `-clickFile` was written, or could not be.
    private var launchClickFileTaken = false

    // What it asks of a part that is made after it. `wireClick` sets it.
    /// Another recording speed was chosen (`slowTake.followSpeed`): the slow song is made, or forgotten.
    var recordSpeedChanged: () -> Void = {}
    /// Whether the player holds the slow sound of a take right now (`slowTake.playerSlow`).
    var playerIsSlow: () -> Bool = { false }

    init(
        windowState: WindowState,
        takeStatus: TakeStatus,
        player: Player,
        store: ProjectStore,
        settings: AppSettings
    ) {
        self.windowState = windowState
        self.takeStatus = takeStatus
        self.player = player
        self.store = store
        self.settings = settings
    }

    // MARK: The click

    /// How long the beats and the click's settings must have been left alone before the
    /// click is laid out again. A beat line that is being dragged, or a setting that is
    /// being tried out, then gives one new click and not one for every step.
    private static let clickRenderPause = Duration.milliseconds(150)

    /// Turns the click on, or off: the button in the bar, and Click On or Off in the
    /// Transport menu.
    func turnClickOnOrOff() {
        editClick(store.project.click.isOn ? "Turn Click Off" : "Turn Click On") { $0.isOn.toggle() }
    }

    /// A sound was pressed in the click popover. It becomes the click's sound, and it is
    /// played once so it can be heard without starting the song. While the song plays
    /// with the click on, the click itself lets the new sound be heard.
    func chooseClickSound(_ sound: LockstepCore.ClickSound) {
        // During a take the click is left alone, and no sound is played into the take.
        guard takeStatus.phase == nil else { return }
        editClick("Change Click Sound") { $0.sound = sound }
        guard !(windowState.content.isPlaying && store.project.click.isOn) else { return }
        let samples = sound.samples(accent: false)
        let volume = store.project.click.gain
        // Hearing the sound is a help, not a must: without a sound output nothing is said.
        Task { [engine = player.engine] in try? await engine.playOnce(samples, volume: volume) }
    }

    /// The volume slider of the click popover was moved. While it is dragged the click
    /// only sounds at the new volume. Letting go makes it the click's volume, as one step
    /// that can be undone.
    func setClickVolume(_ volume: Double, isFinal: Bool) {
        if isFinal {
            heldClickVolume = nil
            editClick("Change Click Volume") { $0.volume = min(max(volume, 0), 1) }
            // Also when the slider was put back where it started and nothing was edited.
            followClick(of: store.project)
        } else {
            heldClickVolume = min(max(volume, 0), 1)
            player.engine.setClickVolume(Float(min(max(volume, 0), 1)))
        }
    }

    /// Beats, Half-beats or Sub-beats was chosen in the click popover.
    func chooseClickDivision(_ division: LockstepCore.ClickDivision) {
        editClick("Change Click Division") { $0.division = division }
    }

    /// 16ths or Triplets was chosen in the click popover, for a click on sub-beats. It is the click's own
    /// choice and changes no clip.
    func chooseClickSubBeats(_ subBeats: SubBeatGrid) {
        editClick("Change Click Sub-beats") { $0.subBeats = subBeats }
    }

    /// Off, 1 bar, 2 bars or 4 bars was chosen in the Count-in row of the click popover.
    /// It is kept as a setting (`recording.runUpBars`), the same for every song, so it is
    /// not a step that can be undone. A take that is going keeps the count-in it was
    /// started with, also for its restarts. The next Record uses the new choice.
    func chooseCountIn(_ bars: Int) {
        settings[.runUpBars] = bars
        followClick(of: store.project)
    }

    /// 100 %, 90 % or 85 % was chosen in the Record speed row of the click popover. Like the
    /// count-in it is kept as a setting (`recording.speedPercent`), the same for every song, and
    /// is no step that can be undone. A take that is going keeps the speed it was started at.
    /// The next Record uses the new choice.
    func chooseRecordSpeed(_ percent: Int) {
        settings[.recordSpeedPercent] = percent
        followClick(of: store.project)
        recordSpeedChanged()
    }

    /// Lays the click out again and hands it to the player, also when nothing it is made from has
    /// changed. After a take that was recorded slower the player has the real song again, and
    /// with the song it lost the click it had.
    func hearClickAgain() {
        clickLayout = nil
        followClick(of: store.project)
    }

    /// Changes the click of the open song as one step that can be undone, and lets the
    /// window and the player follow. A change that changes nothing is not a step.
    ///
    ///     editClick("Change Click Sound") { $0.sound = .cowbell }
    private func editClick(_ actionName: String, _ change: (inout LockstepCore.ClickSettings) -> Void) {
        // No edit while a take is going.
        guard takeStatus.phase == nil else { return }
        var changed = store.project.click
        change(&changed)
        guard changed != store.project.click else { return }
        store.edit(actionName) { $0.click = changed }
        followClick(of: store.project)
    }

    /// Brings the window and the player in line with a project's click: the button and
    /// the popover show it, on or off and the volume act at once, and the click is laid
    /// out again, in the background, when the beats, the sound, how often it clicks, its sub-beats or
    /// the accent on beat 1 have changed. While the song plays, the new click takes over without the song
    /// stopping.
    ///
    /// The project is handed in, and not read from the store, because this is also called
    /// in the middle of an edit, while the store's project is being changed.
    func followClick(of project: Project) {
        if windowState.content.clickIsOn != project.click.isOn {
            windowState.content.clickIsOn = project.click.isOn
        }
        let shown = LockstepUI.ClickSettings(
            project.click, countInBars: settings[.runUpBars], recordSpeedPercent: settings[.recordSpeedPercent]
        )
        if windowState.content.clickSettings != shown {
            windowState.content.clickSettings = shown
        }
        // The mark by the Record button says the same as the row, and is there only below 100 %.
        let mark = settings[.recordSpeedPercent] < 100 ? settings[.recordSpeedPercent] : nil
        if windowState.content.recordSpeedPercent != mark {
            windowState.content.recordSpeedPercent = mark
        }
        player.engine.setClickEnabled(project.click.isOn)
        // A slider that is being dragged has the last word on the volume until it is let go.
        player.engine.setClickVolume(heldClickVolume.map { Float($0) } ?? project.click.gain)

        let layout = ClickLayout(project, accentBeatOne: settings[.accentBeatOne])
        guard layout != clickLayout else { return }
        clickLayout = layout
        // A click that is still waiting or being laid out is for beats or settings that
        // have changed since.
        clickRender?.cancel()
        clickRender = Task { [engine = player.engine] in
            try? await Task.sleep(for: Self.clickRenderPause)
            guard !Task.isCancelled else { return }
            let samples = await layout.samples()
            guard !Task.isCancelled else { return }
            // During a take recorded slower the player has the slowed click. This one is for the real
            // song and would tick against the slow one, so it waits: when the take is over the click is
            // laid out again (`hearClickAgain`).
            guard !playerIsSlow() else {
                clickLayout = nil
                return
            }
            await engine.setClick(buffer: samples)
        }
    }

    // MARK: The click file

    /// Create Click Track: asks where to save the click of the open song, then writes it
    /// there in the background. Once it is saved nothing else happens. If it cannot be
    /// saved, an alert says so.
    func saveClickFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = ClickFile.defaultName(songName: store.project.songName)
        // A run with -scratch keeps to its own folder and does not start in one of Max's.
        if let scratchFolder = LaunchOptions.current.scratchFolder {
            panel.directoryURL = scratchFolder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The click as it is when Save is pressed.
        let project = store.project
        let accentBeatOne = settings[.accentBeatOne]
        Task {
            do {
                try await ClickFile.write(for: project, to: url, accentBeatOne: accentBeatOne)
            } catch {
                windowState.alert = MessageAlert(
                    title: "Lockstep could not save the click file.",
                    detail: "Check that the disk has room and that the folder can be written to, then try again."
                )
                windowState.showsAlert = true
            }
        }
    }

    /// Writes the click file asked for with `-clickFile`, without a panel, and says on
    /// standard error that it was written or why not. Called when the beats are found.
    func writeLaunchClickFile() {
        guard let url = takeLaunchClickFile() else { return }
        let project = store.project
        let accentBeatOne = settings[.accentBeatOne]
        Task {
            do {
                try await ClickFile.write(for: project, to: url, accentBeatOne: accentBeatOne)
                Agent.tell("wrote the click file \(url.path)")
            } catch {
                Agent.tell("could not write the click file \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// Says on standard error that the click file asked for with `-clickFile` will not come.
    func failLaunchClickFile(because reason: String) {
        guard let url = takeLaunchClickFile() else { return }
        Agent.tell("could not write the click file \(url.path): \(reason)")
    }

    /// The path given with `-clickFile`, the first time beat finding ends, and nil after
    /// that or when none was given. The file is for the song Lockstep was started with.
    private func takeLaunchClickFile() -> URL? {
        guard !launchClickFileTaken, let url = LaunchOptions.current.clickFile else { return nil }
        launchClickFileTaken = true
        return url
    }
}

extension ClickModel {
    // MARK: A project opens

    /// A song or a project is about to be shown in place of what was open, and the store has not
    /// opened it yet.
    func projectWillOpen() {
        // The song starts with the click as its project says, and without the click of
        // the song that was open.
        heldClickVolume = nil
    }
}

extension AppModel {
    /// Gives `click` its closures. `wire()` calls it once, when every part is made.
    func wireClick() {
        click.recordSpeedChanged = { [weak self] in self?.slowTake.followSpeed() }
        click.playerIsSlow = { [weak self] in self?.slowTake.playerSlow != nil }
    }
}

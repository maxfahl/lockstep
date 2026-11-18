import AppKit
import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import Observation

/// Send to DaVinci, a part of the app's model: every selected clip becomes a file that starts exactly on a frame of the
/// Resolve timeline, a list of them is left for the Lockstep script inside Resolve, and a panel
/// says what to do next there and at which timecode each clip goes.
///
/// File > Send to DaVinci..., the button in the panel on the right and the line in a clip's
/// right-click menu all open the panel (`openSendPanel`) on the selected clips. Opening
/// exports them at once (`write`), so the files the panel shows are on disk before the panel is
/// seen, and writes the list for the script (`handToScript`). The panel is drawn by
/// `MainLayout` from `sendSheet`, which `windowContent` hands to the window, and its buttons
/// come back here through `sendActions`, which is on `AppModel`.
///
/// Another program cannot control the free edition of Resolve. So Lockstep places nothing
/// there itself: Max chooses Workspace > Scripts > Lockstep in Resolve, and the script reads
/// the list and places the clips (`ResolveSendList`, `ResolveScriptInstall`). Placing by hand
/// still works: each timecode can be copied and each file dragged out of the panel.
///
/// The panel's three fields change the Resolve timeline of the project (`setResolve`, one
/// undo step each). The panel follows the project (`followSendPanel`, which `showClips`
/// calls): after such a change, and after Undo and Redo, the clips are exported again, the
/// timecodes and the files' names are the new ones, and the list is written again. A file the
/// panel wrote earlier under another name is removed then, so the folder holds one file for
/// each clip, not one for every value that was tried.
///
/// While the panel is open no other command acts (`canPerform`), as with the calibrate sheet.
///
/// The panel's switch "With sound" (`setSendWithSound`, kept in the settings as
/// `davinci.sendWithSound`) chooses what the files hold: each clip as it sounds in Lockstep, with
/// its track's Sound and its effects, in stereo and with what rings after it, or dry as before a
/// clip could have a finished sound. Switching it writes the files again, as a changed clip does.
///
/// What an exported file sounds like is decided in one place, `clipExport(of:in:)`, and where
/// it goes on the Resolve timeline in one place too, `ClipExporter.export`: the list and the
/// panel only repeat what an export says.
@MainActor
@Observable
final class SendModel {
    // The ground it is handed.
    @ObservationIgnored private let windowState: WindowState
    @ObservationIgnored private let selection: Selection
    @ObservationIgnored private let loadedSounds: LoadedSounds
    @ObservationIgnored private let takeStatus: TakeStatus
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let settings: AppSettings

    // The parts it is handed, and calls directly.
    @ObservationIgnored private let correction: CorrectionModel
    @ObservationIgnored private let sound: SoundModel
    @ObservationIgnored private let voice: VoiceModel

    // What it asks of code that holds it, or of the model's routing. `wireSend` sets them.
    /// Shows the clips of a project in the window, without telling the player (`showClips(of:)`,
    /// the clips' part).
    @ObservationIgnored var showClips: (Project) -> Void = { _ in }

    /// Carries out a command the way the menu and the keyboard do (`perform(_:)`, the model's
    /// routing).
    @ObservationIgnored var perform: (AppCommand) -> Void = { _ in }

    /// Moves or trims the song as one undo step with the given name (`setSongPlace(_:_:)`, the
    /// song's place, which holds this part). Only a song start typed in the panel calls it.
    @ObservationIgnored var setSongPlace: (SongPlace, String) -> Void = { _, _ in }

    // MARK: What it keeps

    /// What the Send to DaVinci panel shows while it is open, or nil while it is closed.
    /// `windowContent` hands it to the window.
    var sendSheet: SendContent?
    /// What is kept while the panel is open: the exports it shows and where their files are.
    @ObservationIgnored let sendWork = SendWork()
    /// The Lockstep script in DaVinci Resolve: whether it is installed, and installing it from
    /// Settings > DaVinci. An open Send to DaVinci panel is told when that changes.
    @ObservationIgnored lazy var resolveScript: ResolveScriptInstall = {
        let script = ResolveScriptInstall()
        script.changed = { [weak self] in self?.resolveScriptChanged() }
        return script
    }()

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore,
        settings: AppSettings,
        correction: CorrectionModel,
        sound: SoundModel,
        voice: VoiceModel
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
        self.settings = settings
        self.correction = correction
        self.sound = sound
        self.voice = voice
    }

    // MARK: The clip's sound

    /// The export of one clip as it is right now: its sound as the player plays it, and
    /// where it goes on the Resolve timeline. Nil when the clip is gone or plays nothing.
    ///
    /// This is the one place where the app hands a clip's sound to the exporter. It gives
    /// what `followClips` gives the player (the recordings' samples and the fade at clip
    /// edges) and the peaks the safe limit needs, so the file is the clip as it is heard.
    /// The panel, the file that is dragged and the agents' `-sendClip` all come here.
    ///
    /// A later phase that makes a clip sound different (lines slid onto the beat, syllables
    /// nudged, the feel) changes what the player is handed. The same must be handed in
    /// here, as the clip is heard.
    /// A clip whose sound is still being made again is waited for here, before the export.
    ///
    /// Tightening does both: `tightenedExport` gives the clip's tightened sound, and makes it
    /// first if it is not there yet. So does the finished sound: with "With sound" on,
    /// `finishedExport` gives the sound the player plays for the clip, and makes it first if it is
    /// not there yet or is out of date. The export is then that sound, in stereo, with its tail. A
    /// clip that has no sound to be made, and every clip while "With sound" is off, is exported
    /// dry: the file it was before a clip could have a finished sound.
    ///
    /// On a track with a Voice, the source is chosen here, once, and the same one is handed to the
    /// tightened sound, the finished sound, the peaks and the exporter, so a dry send is Max's own
    /// voice byte for byte, also with Lines, All and Stretch:
    /// - "With sound" on: the voice of the track's setting (`voice.forSend`). One that is not there
    ///   yet is neither made nor waited for here: the row has no export until it arrives, and the
    ///   pass that hands it over calls `followSendPanel`, which exports the clip then. One that could
    ///   not be made gives the clip in Max's own voice, and the row says so.
    /// - "With sound" off: Max's own recordings (`.none`).
    func clipExport(of clipID: UUID, in project: Project) -> ClipSend? {
        guard let chosen = ClipExporter.clipToExport(clipID, in: project) else { return nil }
        var voiced = VoicedClips.none
        var said = SendContent.Clip.Voice.none
        if settings[.sendWithSound] {
            switch voice.forSend(chosen.clip, on: chosen.track) {
            case .ready(let ready):
                voiced = ready
                said = chosen.track.voice?.isHeard == true ? .sent : .none
            case .failed:
                said = .failed
            case .making(let progress):
                return ClipSend(export: nil, voice: .making(progress: progress))
            }
        }
        let heard = correction.tightenedExport(of: clipID, in: project, voiced: voiced)
        let finished = settings[.sendWithSound]
            ? sound.finishedExport(of: clipID, in: project, voiced: voiced)
            : (finished: FinishedSounds.none, samples: [:])
        let export = ClipExporter.export(
            clipID,
            in: project,
            recordings: heard.recordings,
            peaks: loadedSounds.clipPeaks(with: voiced.samples),
            edgeFadeMs: settings[.edgeFadeMs],
            tightened: heard.tightened,
            finished: finished.finished,
            finishedSamples: finished.samples, voices: voiced.voices
        )
        return export.map { ClipSend(export: $0, voice: said) }
    }

    /// One clip's send as it is right now: its export, or none yet while its voice is being made,
    /// and what its row says about its track's Voice.
    struct ClipSend: Equatable {
        /// The file's sound and where it goes, or nil while the clip waits for its voice.
        var export: ClipExport?
        /// What the row says about the Voice: `making` exactly while `export` is nil.
        var voice: SendContent.Clip.Voice
    }

    /// The folder exported clips are written to: the one chosen in Settings > DaVinci, or
    /// the open project's own `exports` folder when none is chosen. A scratch run never
    /// gets a folder outside its scratch folder (`LaunchOptions.exportFolder`).
    private var sendFolder: URL? {
        LaunchOptions.current.exportFolder(in: settings) ?? store.package?.exportsFolder
    }

    /// Why clips could not be sent, in words for Max.
    private struct SendFailure: Error {
        var alert: MessageAlert
    }

    /// The clips a send is about: the selected ones, in the order they start in the song. A
    /// line with several takes counts once, as the take that is shown, because that is the
    /// one an export gives (`ClipExporter.clipToExport`).
    private func clipsToSend(in project: Project) -> [UUID] {
        var seen: Set<UUID> = []
        var found: [(id: UUID, start: Int, track: Int)] = []
        for selected in selection.clipIDs {
            guard let chosen = ClipExporter.clipToExport(selected, in: project),
                seen.insert(chosen.clip.id).inserted
            else { continue }
            found.append((
                id: chosen.clip.id,
                start: ClipExporter.startSample(of: chosen.clip.id, in: project, voices: .none) ?? .max,
                track: project.tracks.firstIndex { $0.id == chosen.track.id } ?? 0
            ))
        }
        // The selection has no order of its own. Clips that start together go top track first.
        return found.sorted { ($0.start, $0.track, $0.id.uuidString) < ($1.start, $1.track, $1.id.uuidString) }
            .map(\.id)
    }

    /// The sends of clips as they are right now, without the clips that play nothing. The voices the
    /// rows that wait need are made before every other.
    private func exports(of clipIDs: [UUID], in project: Project) -> [(clipID: UUID, send: ClipSend)] {
        let sends = clipIDs.compactMap { clipID in
            clipExport(of: clipID, in: project).map { (clipID: clipID, send: $0) }
        }
        voice.putFirstForSend(sends.filter { $0.send.export == nil }.compactMap {
            ClipExporter.clipToExport($0.clipID, in: project)
        })
        return sends
    }

    /// Writes exports into the export folder, each under its own name. When this returns,
    /// every file is whole on disk (`ClipExporter.write`). Each gets a new id for the list:
    /// a clip that is written again is to be placed again. A clip that waits for its voice gets
    /// its row and no file.
    private func write(
        _ exports: [(clipID: UUID, send: ClipSend)]
    ) throws(SendFailure) -> [SendWork.Sent] {
        let several = selection.clipIDs.count > 1
        let title = several ? "Lockstep could not export these clips." : "Lockstep could not export this clip."
        guard let folder = sendFolder, !exports.isEmpty else {
            throw SendFailure(alert: MessageAlert(
                title: title,
                detail: several ? "The clips have no sound to export." : "The clip has no sound to export."
            ))
        }
        var sent: [SendWork.Sent] = []
        var names: Set<String> = []
        do {
            for (clipID, send) in exports {
                guard let export = send.export else {
                    sent.append(SendWork.Sent(clipID: clipID, export: nil, voice: send.voice, file: nil, listID: UUID()))
                    continue
                }
                // Two tracks of one name with a clip on the same frame would give one file name
                // twice, and the second file would replace the first.
                var name = export.fileName
                var copy = 2
                while !names.insert(name).inserted {
                    name = (export.fileName as NSString).deletingPathExtension + " \(copy).wav"
                    copy += 1
                }
                let file = folder.appendingPathComponent(name, isDirectory: false)
                try ClipExporter.write(export, to: file)
                sent.append(SendWork.Sent(clipID: clipID, export: export, voice: send.voice, file: file, listID: UUID()))
            }
        } catch {
            throw SendFailure(alert: MessageAlert(
                title: title,
                detail: "Check that the folder \(folder.path) can be written to and that the disk has room. "
                    + "The export folder is chosen in Settings, under DaVinci."
            ))
        }
        return sent
    }

    // MARK: The list for the script in Resolve

    /// The list the script in Resolve reads, for clips that were just written. Each entry
    /// repeats what the clip's export says. `project` is the project the exports were made from.
    private func sendList(for sent: [SendWork.Sent], in project: Project) -> ResolveSendList {
        ResolveSendList(
            songName: project.songName,
            clips: sent.compactMap { one in
                guard let export = one.export, let file = one.file,
                      let chosen = ClipExporter.clipToExport(one.clipID, in: project)
                else { return nil }
                return ResolveSendList.Clip(
                    id: one.listID,
                    export: export,
                    file: file,
                    clipName: chosen.clip.displayName,
                    trackName: chosen.track.name,
                    resolve: project.resolve
                )
            }
        )
    }

    /// Leaves the list of these clips where the script in Resolve finds it, unless that very
    /// list is there already. A list that cannot be written is remembered as not written, and
    /// the panel then says the clips are placed by hand.
    ///
    /// Nothing is written while a clip waits for its voice: a list with some of the clips would
    /// place some of the clips. The panel says to wait (`scriptStep`), and the list is written by
    /// the `followSendPanel` that gives the last clip its file.
    private func handToScript(_ sent: [SendWork.Sent], in project: Project) {
        guard !sent.contains(where: { $0.file == nil }) else { return }
        let list = sendList(for: sent, in: project)
        guard list != sendWork.list else { return }
        do {
            try list.write(toFolder: LaunchOptions.current.sendListFolder)
            sendWork.list = list
        } catch {
            sendWork.list = nil
        }
    }

    /// The script in Resolve was installed, updated or removed. An open panel says the new thing.
    func resolveScriptChanged() {
        guard sendSheet != nil else { return }
        let shown = sendContent(for: sendWork.sent, in: store.project)
        if sendSheet != shown {
            sendSheet = shown
        }
    }

    // MARK: The panel

    /// Whether there is anything to send: at least one clip is selected, and no take is going.
    var canSendSelectedClip: Bool {
        loadedSounds.song != nil && !loadedSounds.isOpening && takeStatus.phase == nil && !selection.clipIDs.isEmpty
    }

    /// Send to DaVinci in a clip's right-click menu: the panel opens on the selected clips
    /// when that clip is one of them, and on that clip alone when it is not.
    func sendClip(_ clipID: UUID) {
        if !selection.clipIDs.contains(clipID) {
            selection.clipIDs = [clipID]
            showClips(store.project)
        }
        perform(.sendToDaVinci)
    }

    /// Send to DaVinci: exports the selected clips, hands them to the script in Resolve, then
    /// opens the panel on them. The song is stopped first, because nothing in the window can
    /// be reached while the panel is open. Clips that cannot be exported get an alert and no panel.
    func openSendPanel() {
        guard sendSheet == nil, canSendSelectedClip else { return }
        if windowState.content.isPlaying {
            perform(.playStop)
        }
        let project = store.project
        do {
            let sent = try write(exports(of: clipsToSend(in: project), in: project))
            sendWork.sent = sent
            handToScript(sent, in: project)
            // Looked at now, so the panel does not tell Max to choose a script that was removed.
            resolveScript.refresh()
            sendSheet = sendContent(for: sent, in: project)
        } catch {
            windowState.showAlert(error.alert)
        }
    }

    /// Done or the Escape key: the panel goes away. The exported files stay where they are,
    /// and so does the list, which the script in Resolve reads after this.
    ///
    /// The voices the panel waited for are made on in the queue's own order, for the track's sake,
    /// and the tightened sounds made for it in Max's own voice are let go.
    func closeSendPanel() {
        sendSheet = nil
        sendWork.sent = []
        sendWork.list = nil
        voice.putFirstForSend([])
        correction.forgetSendSounds()
    }

    /// Keeps the open panel in line with the project: called whenever the clips are shown
    /// again, which is after every edit, Undo and Redo. When the clips' exports are no
    /// longer the ones the panel shows (the Resolve timeline changed, or Undo changed a
    /// clip), they are exported again and the panel shows the new timecodes and files.
    /// When no clip is selected any more, the panel closes.
    ///
    /// It is also how a row that waits for its voice gets its file: the pass that hands the
    /// arrived voice over shows the clips again, and the clip's send is then ready. Nothing about
    /// the wait is remembered, so an edit, Undo, the switch "With sound" and the panel closing
    /// are covered by working every row out again.
    ///
    /// The project is handed in, and not read from the store, because this is also called
    /// in the middle of an undo, while the store's project is being changed.
    func followSendPanel(of project: Project) {
        guard sendSheet != nil else { return }
        guard takeStatus.phase == nil, !selection.clipIDs.isEmpty else {
            closeSendPanel()
            return
        }
        let now = exports(of: clipsToSend(in: project), in: project)
        let before = sendWork.sent
        if !now.isEmpty, now.map(\.clipID) == before.map(\.clipID), now.map(\.send) == sendWork.sends {
            // The same files. What else the panel and the list say may have changed: a name.
            handToScript(before, in: project)
            let shown = sendContent(for: before, in: project)
            if sendSheet != shown {
                sendSheet = shown
            }
            return
        }
        do {
            let sent = try write(now)
            // A file written before whose name is no longer in use has a timecode in it that
            // is not where its clip goes. It was made by this panel a moment ago, so it is removed.
            let inUse = Set(sent.compactMap(\.file))
            for old in before.compactMap(\.file) where !inUse.contains(old) {
                try? FileManager.default.removeItem(at: old)
            }
            sendWork.sent = sent
            handToScript(sent, in: project)
            sendSheet = sendContent(for: sent, in: project)
        } catch {
            closeSendPanel()
            windowState.showAlert(error.alert)
        }
    }

    /// What the panel shows for clips that were written: each clip's name, track, timecode
    /// and file, whether the file holds the clip's sound, what to do in Resolve, where the switch
    /// "With sound" stands, and the three values of the project's Resolve timeline.
    private func sendContent(for sent: [SendWork.Sent], in project: Project) -> SendContent {
        let clips = sent.map { one in
            let chosen = ClipExporter.clipToExport(one.clipID, in: project)
            var clip = SendContent.Clip(
                id: one.clipID,
                name: chosen?.clip.displayName ?? "",
                trackName: chosen?.track.name ?? "",
                timecode: one.export?.timecode.text ?? startTimecode(of: one.clipID, in: project) ?? "",
                fileName: one.file?.lastPathComponent ?? ""
            )
            // Read from the file that was written, not from the switch: a clip without a Sound and
            // without an effect is sent dry also while the switch is on.
            clip.isSentWithSound = one.export?.channels == 2
            clip.voice = one.voice
            return clip
        }
        let resolve = project.resolve
        var content = SendContent(
            clips: clips,
            script: scriptStep(for: clips),
            timelineStart: resolve.timelineStart.text,
            frameRate: resolve.frameRate.label,
            songStart: project.resolveSongStart.text
        )
        content.withSound = settings[.sendWithSound]
        return content
    }

    /// What the panel says about the script in Resolve: to wait while a clip's voice is made, to
    /// choose it there, or why the clips are placed by hand this time.
    private func scriptStep(for clips: [SendContent.Clip]) -> SendContent.ScriptStep {
        if clips.contains(where: { $0.fileName.isEmpty }) {
            return .waitingForVoices(for: clips)
        }
        guard sendWork.list != nil else {
            let folder = (LaunchOptions.current.sendListFolder.path as NSString).abbreviatingWithTildeInPath
            return .listNotWritten(for: clips, folder: folder)
        }
        return switch resolveScript.status {
        case .current: .ready(for: clips)
        case .missing: .notInstalled(for: clips)
        case .different: .outdated(for: clips)
        }
    }

    // MARK: The panel's buttons

    /// Copy: the clip's timecode goes to the clipboard as text, ready to type into Resolve.
    func copySendTimecode(of clipID: UUID) {
        guard let timecode = sendSheet?.clips.first(where: { $0.id == clipID })?.timecode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(timecode, forType: .string)
    }

    /// Show in Finder: Finder opens the export folder with the panel's files selected.
    func showSendFilesInFinder() {
        let files = sendWork.sent.compactMap { sendFileOnDisk(of: $0.clipID) }
        guard !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    /// The exported file of one of the panel's clips, for a drag out of the panel or for
    /// Finder, made sure to be on disk at this very moment. It was written before the panel
    /// showed it. If it has been removed or moved away since, from Finder for one, it is
    /// written again here from the export the panel keeps. Nil when there is no file and
    /// none could be written, and then nothing is dragged.
    func sendFileOnDisk(of clipID: UUID) -> URL? {
        guard sendSheet != nil, let one = sendWork.sent.first(where: { $0.clipID == clipID }),
              let export = one.export, let file = one.file
        else { return nil }
        if !FileManager.default.fileExists(atPath: file.path) {
            do {
                try ClipExporter.write(export, to: file)
            } catch {
                return nil
            }
        }
        return file
    }

    // MARK: The panel's switch

    /// "With sound" was switched in the panel. The choice is kept in the settings, so the next
    /// send starts with it. With the panel open, its clips are exported again and their files
    /// written again under the names they had, as after a changed clip: the script in Resolve
    /// then has these clips to place anew. Clips whose files stay the same (none of them has a
    /// sound to be made) are left as they are, and only the switch moves.
    func setSendWithSound(_ isOn: Bool) {
        guard settings[.sendWithSound] != isOn else { return }
        settings[.sendWithSound] = isOn
        followSendPanel(of: store.project)
    }

    // MARK: The panel's fields

    /// Another timeline start was typed. Text that is no timecode changes nothing, and the
    /// field shows the old value again.
    func sendTimelineStartTyped(_ text: String) {
        guard sendSheet != nil, let changed = store.project.resolve.withTimelineStart(typed: text) else { return }
        setResolve(changed)
    }

    /// Another frame rate was chosen.
    func sendFrameRateChosen(_ label: String) {
        guard sendSheet != nil, let rate = ResolveFrameRate(rawValue: label) else { return }
        setResolve(store.project.resolve.withFrameRate(rate))
    }

    /// Another timecode for the start of the song was typed. Text that is no timecode
    /// changes nothing. The field shows and changes the song's place on Lockstep's own
    /// timeline, whose 00:00 is the start of the Resolve timeline: a timecode before the
    /// timeline start cuts that much of the song's beginning away and puts what is left
    /// at 00:00, as dragging the song's edge and the song does.
    func sendSongStartTyped(_ text: String) {
        guard sendSheet != nil, let place = store.project.songPlace(withSongStartTyped: text) else { return }
        setSongPlace(place, "Move Song")
    }

    /// The line under the panel's fields while the text typed into one of them is not a
    /// timecode at the project's frame rate, or nil while it is. It says what Settings >
    /// DaVinci says for the same mistake.
    func sendTimecodeHint(for text: String) -> String? {
        let frameRate = store.project.resolve.frameRate
        guard Timecode.parse(text, frameRate: frameRate) == nil else { return nil }
        return "Write it as hours, minutes, seconds and frames, like 01:00:00:00, with the frames below "
            + "\(frameRate.timecodeFramesPerSecond). Lockstep keeps the timecode it had until then."
    }

    // MARK: For an agent's run

    /// Exports the first clip of the first track to the path given with `-sendClip`, once
    /// the first project is open and the takes given with `-addTake` are in it, and says on
    /// standard error where the clip goes. An agent that checks the app cannot select a
    /// clip, so it cannot open the panel.
    ///
    /// The export is the panel's own (`clipExport`). Only the place differs: the file goes
    /// to the path that was given, which must lie inside the scratch folder, and no panel
    /// is opened. The list for the script in Resolve is written as the panel writes it, into
    /// the scratch folder (`LaunchOptions.sendListFolder`), and a second line says where.
    ///
    /// The clip is sent with its sound, as the panel's switch stands in a fresh scratch folder.
    /// `-sendDry` switches "With sound" off first, through the function the switch calls.
    ///
    /// On a track with a Voice it waits, as the panel's row does, until the clip's voice is there
    /// (ten minutes at most), and the line says whether the clip was sent in the track's Voice.
    func sendLaunchClip() {
        guard !sendWork.launchClipTaken, let url = LaunchOptions.current.clipToSend else { return }
        sendWork.launchClipTaken = true
        Task {
            // Until the takes are added the project has no clip to send.
            await takeStatus.ended()
            // With `-tighten`, the clip is sent as it sounds once its lines have slid.
            await correction.launchTightened()
            // With `-trackSound` and `-clipKnob`, the clip is sent once its track has its Sound and
            // the clip its knob.
            await sound.launchSounded()
            if LaunchOptions.current.sendsDry {
                setSendWithSound(false)
            }
            await waitForLaunchClipsVoice()
            for line in sendLaunchClip(to: url) {
                Self.tellAgentAboutSend(line)
            }
        }
    }

    /// Waits until the first clip of the first track can be sent: its send has an export, which it
    /// lacks only while its voice is being made. Ten minutes at most, after which the line says so.
    private func waitForLaunchClipsVoice() async {
        let deadline = ContinuousClock.now + .seconds(600)
        while ContinuousClock.now < deadline {
            let project = store.project
            guard let clipID = project.tracks.first?.clips.first?.id,
                  let send = clipExport(of: clipID, in: project), send.export == nil
            else { return }
            if let chosen = ClipExporter.clipToExport(clipID, in: project) {
                voice.putFirstForSend([chosen])
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Does what `-sendClip` asks and gives the lines that say how it went: one for the file
    /// and, when the file was written, one for the list.
    private func sendLaunchClip(to url: URL) -> [String] {
        let refusal = "could not send the clip to \(url.path): "
        guard let scratch = LaunchOptions.current.scratchFolder, url.path.hasPrefix(scratch.path + "/") else {
            return [refusal + "the path is outside the scratch folder"]
        }
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil else {
            return [refusal + "the song is not ready"]
        }
        let project = store.project
        guard let clipID = project.tracks.first?.clips.first?.id else {
            return [refusal + "the first track has no clip"]
        }
        guard let send = clipExport(of: clipID, in: project) else {
            return [refusal + "the clip has no sound"]
        }
        voice.putFirstForSend([])
        guard let export = send.export else {
            return [refusal + "its voice was not made in ten minutes"]
        }
        do {
            try ClipExporter.write(export, to: url)
        } catch {
            return [refusal + error.localizedDescription]
        }
        // The length is counted for one channel, so a stereo file says as many samples as it lasts.
        let how = if export.channels == 2 {
            "sent with its sound"
        } else if settings[.sendWithSound] {
            "sent dry because the clip has no sound to be made"
        } else {
            "sent dry because \"With sound\" is off"
        }
        let sentLine = "sent the clip to \(url.path): timecode \(export.timecode.text), "
            + "\(export.lengthSamples) samples, \(export.channels) \(export.channels == 1 ? "channel" : "channels"), "
            + "padding \(export.paddingSamples) samples, tail \(export.tailSamples) samples, \(how), "
            + Self.voiceForAgent(send.voice, of: project.tracks.first)
            + "panel file name \"\(export.fileName)\""

        let folder = LaunchOptions.current.sendListFolder
        let list = sendList(
            for: [SendWork.Sent(clipID: clipID, export: export, voice: send.voice, file: url, listID: UUID())],
            in: project
        )
        do {
            let written = try list.write(toFolder: folder)
            let entry = list.clips.first
            return [
                sentLine,
                "wrote the list for the Resolve script to \(written.path): \(list.clips.count) clip, "
                    + "frame \(entry?.frame ?? 0), \(entry?.lengthFrames ?? 0) frames long, "
                    + "track \"\(entry?.trackName ?? "")\"",
            ]
        } catch {
            return [
                sentLine,
                "could not write the list for the Resolve script into \(folder.path): \(error.localizedDescription)",
            ]
        }
    }

    /// What the line of `-sendClip` says about the track's Voice, ending in ", ", or nothing for a
    /// track whose Voice is not heard, so a run without a Voice prints the line it always printed.
    private static func voiceForAgent(_ said: SendContent.Clip.Voice, of track: Track?) -> String {
        guard let voice = track?.voice, voice.isHeard else { return "" }
        let named = "the track's Voice \"\(voice.name)\" (\(voice.knobs.folderName))"
        return switch said {
        case .sent: "in \(named), "
        case .failed: "in Max's own voice because \(named) could not be made for it, "
        case .none: "in Max's own voice, not in \(named), "
        case .making: ""
        }
    }

    /// One line on standard error, for the agent that started Lockstep.
    private static func tellAgentAboutSend(_ line: String) {
        FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
    }

    // MARK: The Resolve timeline of the open project

    /// A project as it should be opened: one that was saved before Send to DaVinci
    /// existed says nothing about the Resolve timeline, and gets what Settings has for
    /// new projects. A project that has its own values keeps them, whatever Settings says.
    ///
    /// `changed` is true when the values were given just now. They are then written with
    /// the project, so the project keeps them when the settings change later.
    func withResolveDefaults(_ project: Project, in package: ProjectPackage) -> (project: Project, changed: Bool) {
        guard !package.savedProjectHasResolveSettings() else { return (project, false) }
        var given = project
        given.resolve = settings.newProjectResolve
        return (given, true)
    }

    /// Changes how the open project sits on the Resolve timeline, as one step that Undo
    /// takes back. The Send to DaVinci panel calls it for its three fields.
    func setResolve(_ resolve: ResolveSettings) {
        guard loadedSounds.song != nil, store.project.resolve != resolve else { return }
        store.edit("Change Resolve Timeline") { $0.resolve = resolve }
        // The start time of the selected clip is read from these values.
        showClips(store.project)
    }

    /// The Resolve start time of the selected clip, as the window writes it: the timecode
    /// of the frame an export of it would start on. Empty with no clip selected, or several.
    ///
    /// The clip's start is where its first sound lies in the song, with the measured delay
    /// and any move of the clip in it. The selected clip of a line with takes is always the
    /// take that is shown. A timing fix moves the start only when the clip's first line slid
    /// out of the clip to reach its sub-beat: the clip is then heard, and exported, from where
    /// that line starts. The sample is the very one the export starts from
    /// (`ClipExporter.startSample`, with the tightened sounds that are heard), so this timecode
    /// and the panel's are the same.
    ///
    /// `showClips` asks for it whenever the clips are shown again, which is after every
    /// selection, edit, Undo and Redo, so it also follows the project's Resolve timeline.
    func resolveStartText(of project: Project) -> String {
        guard selection.clipIDs.count == 1, let clipID = selection.clipIDs.first else { return "" }
        return startTimecode(of: clipID, in: project) ?? ""
    }

    /// The timecode of the frame an export of the clip would start on, as it is heard right now. The
    /// panel's row of a clip that waits for its voice shows it too: a voice moves no sound, so the
    /// file will start there. Nil for a clip that plays nothing.
    private func startTimecode(of clipID: UUID, in project: Project) -> String? {
        guard let sample = ClipExporter.startSample(
            of: clipID, in: project, tightened: correction.heardTightened, voices: voice.heard
        ) else { return nil }
        let resolve = project.resolve
        let onTimeline = project.songPlace.timelineSample(forSong: sample)
        return resolve.timecode(frame: resolve.startFrame(forTimelineSample: onTimeline)).text
    }
}

/// What the model keeps while the Send to DaVinci panel is open.
@MainActor
final class SendWork {
    /// One clip the panel shows. A clip that waits for its voice has no export and no file yet.
    struct Sent {
        var clipID: UUID
        /// The export the panel shows for the clip. It is kept so the file can be written again
        /// if it was removed from outside, and to know when the clip's export has changed.
        var export: ClipExport?
        /// What the row says about its track's Voice.
        var voice: SendContent.Clip.Voice
        /// Where that export's file is.
        var file: URL?
        /// The id the clip has in the list for the script in Resolve (`ResolveSendList.Clip.id`).
        var listID: UUID
    }

    /// The clips the panel shows, in its order. Empty while the panel is closed.
    var sent: [Sent] = []

    /// What `followSendPanel` compares to know whether the files must be written again.
    var sends: [SendModel.ClipSend] {
        sent.map { SendModel.ClipSend(export: $0.export, voice: $0.voice) }
    }
    /// The list for the script in Resolve as it was last written for the panel, or nil when it
    /// could not be written.
    var list: ResolveSendList?
    /// True once the clip asked for with `-sendClip` was exported, or could not be.
    var launchClipTaken = false
}

extension AppModel {
    /// Gives `send` its closures. `wire()` calls it once, when every part is made.
    func wireSend() {
        send.showClips = { [weak self] project in self?.clips.showClips(of: project) }
        send.perform = { [weak self] command in self?.perform(command) }
        send.setSongPlace = { [weak self] place, actionName in self?.songPlace.setSongPlace(place, actionName) }
    }
}

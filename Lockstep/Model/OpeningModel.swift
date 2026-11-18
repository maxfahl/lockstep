import AppKit
import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import os
import UniformTypeIdentifiers

/// Opening and saving: a part of the app's model.
///
/// It holds opening a song or a project, showing it (which puts every part back to its start,
/// in a fixed order), closing it, and what is said when saving fails.
///
/// Opening: `open` takes a song (a new project is made) or a `.lockstep` project (it is
/// read from disk, with its song, its beats and its click, and no beats are looked for
/// unless the project's cache is gone). At start `openLaunchFile` opens the file named
/// with `-open`, or else the project that was open last. `recentProjects` is what
/// File > Open Recent lists.
///
/// Saving: a dropped song gets a project folder in the projects folder chosen in
/// Settings (`LaunchOptions.projectsFolder(in:)`), with the song in it as `song.wav`. From then
/// on the store writes the project by itself after every change, and `saveBeforeClosing` writes
/// what is still waiting when the window closes or Lockstep quits. There is no Save command.
///
/// Its `init` is final. It has no closures: everything it calls it is handed.
@MainActor
final class OpeningModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let loopState: LoopState
    private let player: Player
    private let store: ProjectStore
    private let settings: AppSettings
    private let playhead: PlayheadPosition
    private let recentProjects: RecentProjects

    // The parts it is handed, and calls directly.
    private let timelineView: TimelineViewModel
    private let transport: TransportModel
    private let beats: BeatsModel
    private let click: ClickModel
    private let clips: ClipsModel
    private let tracks: TracksModel
    private let songPlace: SongPlaceModel
    private let calibration: CalibrationModel
    private let send: SendModel
    private let correction: CorrectionModel
    private let loop: LoopModel
    private let playheadModel: PlayheadModel
    private let words: WordsModel
    private let clipEditing: ClipEditingModel
    private let songVolume: SongVolumeModel
    private let trackVolume: TrackVolumeModel
    private let slowTake: SlowTakeModel
    private let sound: SoundModel
    private let voice: VoiceModel

    /// The reading of a dropped file that is still going on.
    private var opening: Task<Void, Never>?
    /// Counts every file that was opened, so progress from a file that was given up
    /// for a newer one is not shown.
    private var openingNumber = 0
    private var openedLaunchFile = false
    /// True once anything was asked to open, by Max or by a launch argument.
    private var hasOpenedSomething = false

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        loopState: LoopState,
        player: Player,
        store: ProjectStore,
        settings: AppSettings,
        playhead: PlayheadPosition,
        recentProjects: RecentProjects,
        timelineView: TimelineViewModel,
        transport: TransportModel,
        beats: BeatsModel,
        click: ClickModel,
        clips: ClipsModel,
        tracks: TracksModel,
        songPlace: SongPlaceModel,
        calibration: CalibrationModel,
        send: SendModel,
        correction: CorrectionModel,
        loop: LoopModel,
        playheadModel: PlayheadModel,
        words: WordsModel,
        clipEditing: ClipEditingModel,
        songVolume: SongVolumeModel,
        trackVolume: TrackVolumeModel,
        slowTake: SlowTakeModel,
        sound: SoundModel,
        voice: VoiceModel
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.loopState = loopState
        self.player = player
        self.store = store
        self.settings = settings
        self.playhead = playhead
        self.recentProjects = recentProjects
        self.timelineView = timelineView
        self.transport = transport
        self.beats = beats
        self.click = click
        self.clips = clips
        self.tracks = tracks
        self.songPlace = songPlace
        self.calibration = calibration
        self.send = send
        self.correction = correction
        self.loop = loop
        self.playheadModel = playheadModel
        self.words = words
        self.clipEditing = clipEditing
        self.songVolume = songVolume
        self.trackVolume = trackVolume
        self.slowTake = slowTake
        self.sound = sound
        self.voice = voice
    }
}

extension OpeningModel {
    // MARK: Opening a song

    /// Where the settings keep the path of the project that was open last.
    private static let lastProjectKey = "lastProjectPath"

    /// The kind of file a project is, as the app's Info.plist declares it.
    private static let projectType = UTType(exportedAs: ProjectPackage.typeIdentifier, conformingTo: .package)

    /// Opens what Lockstep starts with: the file named with `-open`, or else the project
    /// that was open last time. Call it when the window is up. It acts only the first time.
    ///
    /// A scratch run reopens nothing, and neither does a start with "Reopen the last
    /// project at launch" turned off in Settings. A last project that is gone is passed
    /// over without a word, and the window stays empty. A last project that is there but cannot be
    /// opened gets its alert once and is not tried again at the next start. If something
    /// was already asked to open, such as a project double-clicked in Finder, that one stands.
    func openLaunchFile() {
        guard !openedLaunchFile else { return }
        openedLaunchFile = true
        guard !hasOpenedSomething else { return }
        let options = LaunchOptions.current
        if let url = options.fileToOpen {
            open(url)
        } else if !options.isScratch, settings[.reopenLastProject],
            let path = options.settings.string(forKey: Self.lastProjectKey),
            FileManager.default.fileExists(atPath: path)
        {
            open(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    /// Opens the first sound file or project among files dropped on the window. When
    /// none of them is one, the first file is tried all the same, so the alert says why
    /// nothing opened: a drop that does nothing looks like a fault.
    func open(dropped urls: [URL]) {
        let wanted = urls.first { Self.isSoundFile($0) || ProjectPackage.isProject($0) }
        guard let url = wanted ?? urls.first else { return }
        open(url)
    }

    /// Opens a project, or a sound file as the song of a new project, in place of what
    /// was open. If it cannot be opened, an alert says why and the window stays as it was.
    func open(_ url: URL) {
        // A take belongs to the project that is open. Nothing else is opened until it has ended.
        guard takeStatus.phase == nil else { return }
        hasOpenedSomething = true
        // The Send to DaVinci panel is about the clips of the project that is open. A project opened
        // from Finder or the Dock while it is up closes it first, so it never follows the new project's
        // clips, nor removes the files it sent for the old one.
        send.closeSendPanel()
        // What the open project still has waiting is written before anything is read,
        // so opening the very project that is open reads it as it is now. Its view too.
        store.close()
        timelineView.writeViewIfChanged()
        opening?.cancel()
        openingNumber += 1
        let number = openingNumber
        let progress = Self.progressReport(to: self, opening: number)
        if loadedSounds.song == nil {
            windowState.content.openingProgress = 0
        } else if windowState.content.isPlaying {
            // The song that is open stops before it is replaced. A take that its Play button
            // was playing is forgotten first, so the player has the clips as the project has
            // them if the opening fails and the window stays as it was.
            transport.forgetTakesStretch()
            windowState.content.isPlaying = false
            player.tell { await $0.stop() }
        }
        loadedSounds.isOpening = true
        opening = Task {
            if ProjectPackage.isProject(url) {
                await openProject(ProjectPackage(url: url), opening: number, progress: progress)
            } else {
                await openSong(at: url, opening: number, progress: progress)
            }
        }
    }

    /// Reads a saved project and shows it: its song, its beats with Max's corrections
    /// and its click. The beats are only looked for again when the project's cache is
    /// missing or damaged.
    private func openProject(
        _ package: ProjectPackage,
        opening number: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async {
        do {
            let saved = try await Self.read(package, progress: progress)
            let waveform = await WaveformPyramid.build(interleaved: saved.song.samples, channelCount: 2)
            // The recordings, so the clips can be heard as soon as the project is shown.
            let recorded = await RecordingLoader.readAll(of: saved.project, in: package)
            let recordedWaveforms = await Self.waveforms(of: recorded)
            // A newer file may have taken over while this one was read.
            try Task.checkCancellation()
            player.tell { await $0.load(song: saved.song.samples) }
            await player.hasDoneItsOrders()
            show(
                OpenSong(name: saved.project.songName, duration: saved.song.duration, waveform: waveform),
                project: saved.project,
                in: package,
                cache: saved.cache,
                sound: saved.song,
                recorded: recorded,
                waveforms: recordedWaveforms
            )
            if number == openingNumber {
                loadedSounds.isOpening = false
            }
        } catch is CancellationError {
            // The newer file shows its own progress and result.
        } catch {
            // One plain sentence for each way a project can fail to open. The project on
            // disk is left exactly as it is: nothing of it was put in the store, so
            // nothing can be saved over it.
            let failure = error as? ProjectPackageError ?? .unreadable
            forget(package, because: failure)
            failedToOpen(MessageAlert(title: failure.message, detail: failure.advice), opening: number)
        }
    }

    /// Stops offering a project that could not be opened: a project that is gone leaves
    /// File > Open Recent, and no project that failed is tried again at the next start.
    /// Only Lockstep's memory of the project changes, never the project.
    private func forget(_ package: ProjectPackage, because failure: ProjectPackageError) {
        if failure == .notFound {
            recentProjects.remove(package.url)
        }
        let settings = LaunchOptions.current.settings
        if settings.string(forKey: Self.lastProjectKey) == package.url.path {
            settings.removeObject(forKey: Self.lastProjectKey)
        }
    }

    /// Everything a saved project holds, read from its folder away from the main thread:
    /// the project, its song, and what beat finding kept (nil when that is gone).
    @concurrent
    private nonisolated static func read(
        _ package: ProjectPackage,
        progress: @Sendable (Double) -> Void
    ) async throws -> (project: Project, song: ImportedSong, cache: BeatCache?) {
        let project = try package.read()
        let song: ImportedSong
        do {
            song = try await SongImporter.importSong(from: package.songFile(of: project), progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The song is there but is not sound that can be read.
            throw ProjectPackageError.unreadable
        }
        return (project, song, BeatCache.read(from: package))
    }

    /// The waveform of every recording, for drawing the clips, worked out away from the
    /// main thread.
    @concurrent
    private nonisolated static func waveforms(of recorded: [UUID: [Float]]) async -> [UUID: WaveformPyramid] {
        recorded.mapValues { WaveformPyramid(interleaved: $0, channelCount: 1) }
    }

    /// Reads a sound file, makes a project for it and shows it.
    private func openSong(
        at url: URL,
        opening number: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async {
        do {
            let imported = try await SongImporter.importSong(from: url, progress: progress)
            let waveform = await WaveformPyramid.build(interleaved: imported.samples, channelCount: 2)
            // A newer file may have taken over while this one was read.
            try Task.checkCancellation()
            let name = url.deletingPathExtension().lastPathComponent
            // A new song's click starts with what Settings says under "New songs".
            let click = LockstepCore.ClickSettings(
                sound: settings[.clickDefaultSound],
                volume: settings[.clickDefaultVolume],
                division: settings[.clickDefaultDivision]
            )
            let project = Project(
                songName: name,
                songLengthSamples: imported.lengthSamples,
                click: click,
                // And its Resolve timeline with what the DaVinci pane says.
                resolve: settings.newProjectResolve
            )
            let package: ProjectPackage
            do {
                // The folder chosen in Settings, or the usual one when that cannot be used.
                let folder = LaunchOptions.current.projectsFolder(in: settings).url
                package = try await Self.makeProject(project, in: folder, song: imported)
            } catch {
                failedToOpen(
                    MessageAlert(
                        title: "Lockstep could not make a project for this song.",
                        detail: "Check that the projects folder can be written to and that the disk has room. "
                            + "The projects folder is chosen in Settings, under General."
                    ),
                    opening: number
                )
                return
            }
            guard !Task.isCancelled else {
                // Nobody will ever see this project: a newer file took over while it
                // was written. It was made a moment ago and holds nothing but the song.
                try? FileManager.default.removeItem(at: package.url)
                return
            }
            player.tell { await $0.load(song: imported.samples) }
            await player.hasDoneItsOrders()
            show(
                OpenSong(name: name, duration: imported.duration, waveform: waveform),
                project: project,
                in: package,
                cache: nil,
                sound: imported,
                recorded: [:],
                waveforms: [:]
            )
            if number == openingNumber {
                loadedSounds.isOpening = false
            }
        } catch is CancellationError {
            // The newer file shows its own progress and result.
        } catch {
            let failure = error as? SongImportError ?? .unreadableFile
            failedToOpen(MessageAlert(title: failure.message, detail: failure.advice), opening: number)
        }
    }

    /// Makes the project folder of a new song, with the song in it as `song.wav`. Writing
    /// the song takes a moment, so it is done away from the main thread.
    @concurrent
    private nonisolated static func makeProject(
        _ project: Project,
        in folder: URL,
        song: ImportedSong
    ) async throws -> ProjectPackage {
        try ProjectPackage.create(project, in: folder) { url in
            try WavWriter.write(song.samples, channels: 2, to: url)
        }
    }

    /// File > Open: lets Max pick one project, or one sound file to start a new project
    /// with, exactly like dropping it on the window.
    func chooseSong() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // A project is a folder that is picked like a file, not looked into.
        panel.treatsFilePackagesAsDirectories = false
        // A run with -scratch starts among its own projects and not in a folder of Max's.
        if LaunchOptions.current.isScratch {
            panel.directoryURL = LaunchOptions.current.chosenProjectsFolder(in: settings)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Puts a song and its project in the window, in place of what was open.
    ///
    /// `cache` is what beat finding kept for this song, or nil when its beats have to be
    /// found, which is then started with `sound`, the song as it was just read. `recorded`
    /// is the sound of the project's recordings and `waveforms` their waveforms, by
    /// recording id.
    ///
    /// Every part puts its own state back to its start: in its `projectWillOpen` before the store
    /// opens the project, and in its `projectOpened` after. The order of everything here is kept as
    /// it is: the store hands the clips to the player and shows them the moment it opens the
    /// project, and what the launch arguments ask for comes last.
    private func show(
        _ opened: OpenSong,
        project: Project,
        in package: ProjectPackage,
        cache: BeatCache?,
        sound: ImportedSong,
        recorded: [UUID: [Float]],
        waveforms recordedWaveforms: [UUID: WaveformPyramid]
    ) {
        loadedSounds.song = opened
        playhead.seconds = 0
        takeStatus.lastTakeStart = nil
        let keptView = timelineView.projectWillOpen(in: package)

        var timeline = TimelineContent.empty
        timeline.songName = opened.name
        timeline.songLength = opened.duration
        timeline.songWaveform = SongWaveform(opened.waveform)
        timeline.closestBeatLineSpacing = BeatsModel.closestBeatLineSpacing
        var content = MainLayoutContent(timeline: timeline)
        // The click popover has its Record speed row from the start. The setting is not the project's, so
        // it is known already, and is written with the rest in one go.
        content.clickSettings.recordSpeedPercent = settings[.recordSpeedPercent]
        windowState.content = content
        // Until beats are shown there is no click to save.
        windowState.content.canCreateClickTrack = false
        calibration.projectWillOpen()
        beats.showTempo(in: nil)
        click.projectWillOpen()
        songVolume.projectWillOpen()
        trackVolume.projectWillOpen()
        // `sound` alone is the song that was read, in this function.
        self.sound.projectWillOpen()
        voice.projectWillOpen()

        beats.projectWillOpen(cache: cache)
        // The project that was open is closed for good: its unused recordings go, while
        // `sounds` still says which recordings were its own.
        closeProject()
        // The clips of this project are heard and drawn from its own recordings, and
        // recordings go to its first track. All of it is in place before the store opens
        // the project, because that is when the clips are handed to the player and shown.
        loadedSounds.sounds = recorded
        loadedSounds.waveforms = recordedWaveforms
        clips.projectWillOpen()
        // What was selected when the project was left. Clips and a track that are gone are
        // let go when the clips are shown (`showClips`).
        selection.trackID = keptView?.selectedTrackID ?? project.tracks.first?.id
        tracks.projectWillOpen()
        selection.clipIDs = Set(keptView?.selectedClipIDs ?? [])
        selection.markedStretch = nil
        // A loop belongs to the song it was marked in. The in and out this project was left
        // with come back once it is in the store (`restore`).
        loopState.region = nil
        loopState.inOut = nil
        songPlace.forgetShortenedByCut()
        transport.takesStretch = nil
        // Edits of the old song cannot be undone into this one. The store writes what the
        // old project still had waiting, then fits this project's beat lines from the
        // cache and lets the click follow (`rebuildDerived`).
        // Recordings made before their headphones and microphone were measured are moved back first.
        let corrected = calibration.withStoredDelays(project)
        // A project from before Send to DaVinci gets the Resolve timeline of new projects.
        let timed = send.withResolveDefaults(corrected.project, in: package)
        store.open(timed.project, in: package)
        timelineView.projectOpened(in: package, with: keptView)
        // Now that the store knows the folder, the voices the clips need are read or made.
        voice.projectOpened(in: package)
        correction.findMarkers(ofOpenedRecordings: recorded, in: package)
        if corrected.moved || timed.changed {
            // Nothing was changed by hand, so it is no undo step. This has it written to disk.
            store.setDerived { _ in }
        }
        beats.projectOpened(cache: cache, sound: sound)
        // With a slower recording speed chosen, the slow song of this project is made now.
        slowTake.projectOpened()

        // This is the project to come back to next time, and the newest of the recent ones.
        LaunchOptions.current.settings.set(package.url.path, forKey: Self.lastProjectKey)
        recentProjects.note(package.url)
        transport.addLaunchTake()
        playheadModel.moveToLaunchPlayhead()
        songVolume.setLaunchSongVolume()
        trackVolume.setLaunchTrackVolume()
        // The Voice first: the correction's launch arguments wait for its voices.
        voice.voiceLaunchTrack()
        correction.tightenLaunchTrack()
        correction.strengthenLaunchTrack()
        correction.lockDoubleLaunchTrack()
        self.sound.soundLaunchTrack()
        send.sendLaunchClip()
        words.setLaunchClipText()
        clipEditing.deleteLaunchClip()
        clipEditing.pasteLaunchClip()
        clipEditing.buildLaunchBigProject()
        clipEditing.selectLaunchRectangle()
        clipEditing.timeLaunchEdits()
        timelineView.dragLaunchTimeline()
        slowTake.setLaunchSpeed()
        transport.recordLaunchTake()
        voice.voiceOffLaunchTrack { [correction, sound = self.sound] in
            await correction.launchTightened()
            await sound.launchSounded()
        }
    }

    private func showOpeningProgress(_ fraction: Double, opening number: Int) {
        guard number == openingNumber, let shown = windowState.content.openingProgress, fraction > shown else { return }
        windowState.content.openingProgress = fraction
    }

    private func failedToOpen(_ message: MessageAlert, opening number: Int) {
        guard number == openingNumber else { return }
        loadedSounds.isOpening = false
        windowState.content.openingProgress = nil
        windowState.alert = message
        windowState.showsAlert = true
    }

    // MARK: Saving

    /// Writes changes of the project that are still waiting to be saved, and removes the
    /// recordings no clip uses any more. Called when the window closes and when Lockstep quits.
    func saveBeforeClosing() {
        timelineView.writeViewIfChanged()
        closeProject()
    }

    /// Closes the open project for good: recordings that no clip uses any more are
    /// taken out of it and their files are removed, and what is still waiting is saved.
    /// The undo steps are forgotten, because they could ask for a recording that is gone.
    ///
    /// Only files of recordings this project named, or that were recorded while it was
    /// open, are removed. Anything else in the project's folder is left alone.
    private func closeProject() {
        guard let package = store.package else {
            store.close()
            return
        }
        let removed = store.forgetUnusedRecordings()
        // What is being made of voices stops, and the voices folder keeps only what the project as it closes
        // can use.
        voice.projectWillClose(store.project, in: package)
        store.close()
        let inUse = Set(store.project.recordings.map(\.id))
        var files: [UUID: String] = [:]
        // A take that Undo took away is not in the project any more, but its sound is still here.
        for id in loadedSounds.sounds.keys where !inUse.contains(id) {
            files[id] = Recording.fileName(for: id)
        }
        for recording in removed {
            files[recording.id] = recording.file
        }
        for (id, file) in files {
            try? FileManager.default.removeItem(at: package.url.appendingPathComponent(file))
            try? FileManager.default.removeItem(at: VoiceEnvelope.file(forRecording: id, in: package))
            try? FileManager.default.removeItem(at: package.markersFile(forRecording: id))
            // The sped-up sound of a take that was recorded slower. Most recordings have none.
            try? FileManager.default.removeItem(at: package.spedUpFile(forRecording: id))
            loadedSounds.sounds[id] = nil
            loadedSounds.waveforms[id] = nil
        }
    }

    /// The project could not be written to disk. The changes are still in memory, and
    /// the next change tries to save again.
    func saveFailed(_ error: any Error) {
        windowState.alert = MessageAlert(
            title: "Lockstep could not save this project.",
            detail: "Check that the disk has room and that the project folder is still there. "
                + "Your changes are kept while Lockstep stays open, and the next change tries to save again."
        )
        windowState.showsAlert = true
    }

    /// True for a file whose kind is a kind of sound (m4a, mp3, wav, aiff and so on).
    private static func isSoundFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .audio) ?? false
    }

    /// What the reading of a file calls to say how far it has come. It is called from
    /// the reading thread, many times a second, so it is made here, outside the main
    /// actor, and passes on only every hundredth to the window.
    private nonisolated static func progressReport(
        to model: OpeningModel,
        opening number: Int
    ) -> @Sendable (Double) -> Void {
        let passedOn = OSAllocatedUnfairLock(initialState: 0.0)
        return { [weak model] fraction in
            let isNewStep = passedOn.withLock { last in
                guard fraction - last >= 0.01 else { return false }
                last = fraction
                return true
            }
            guard isNewStep else { return }
            Task { @MainActor in
                model?.showOpeningProgress(fraction, opening: number)
            }
        }
    }
}

extension AppModel {
    /// Gives `openingModel` its closures: it has none, because everything it calls it is handed.
    /// `wire()` calls it once, when every part is made.
    func wireOpening() {}
}

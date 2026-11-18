import AVFoundation
import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import Observation

/// The app's model: what the window and the menus hold.
///
/// It keeps no state of a feature and no function of one. It does three things:
///
/// - It owns the project (`store`), the settings, the ground (the small objects in
///   `Lockstep/Model/Ground/` that many parts share) and the parts (one class for each feature,
///   in `Lockstep/Model/`). `init` makes them in order and hands each what it needs, and `wire()`
///   gives each part the closures it asks of a part that holds it, or of the routing here.
/// - It routes commands. The menu bar and the shortcut keys ask `canPerform` and call `perform`,
///   and each case reads from, or calls, the part that carries the command out. `isOn` and
///   `menuTitle` say how a menu item is shown.
/// - It routes the window's actions (`AppModel+RoutingWindow.swift`). The window (`MainWindow`)
///   draws `windowContent` with `MainLayout` and hands the layout `layoutActions`, the tables of
///   what its controls do.
///
/// The project (what is kept about the song, and every edit that can be undone) is in `store`.
/// An edit is made with `store.edit`, never by changing the project in another way.
///
/// What a feature does is written above its part. What a part is handed shows in its initialiser and
/// in the wire function at the end of its file.
@MainActor
@Observable
final class AppModel {
    /// The features whose controls the window shows.
    let features = FeatureSet.built

    /// The open project. Every edit goes through `store.edit`, which is what makes
    /// it undoable. The Edit menu's Undo and Redo act on it.
    let store = ProjectStore()

    /// Lockstep's settings: Max's own, or the scratch folder's in a scratch run. The
    /// settings window changes them and the model reads them.
    let settings = AppSettings(store: LaunchOptions.current.settings)

    /// The projects under File > Open Recent. A scratch run has a list of its own.
    let recentProjects = RecentProjects(
        scratchSettings: LaunchOptions.current.isScratch ? LaunchOptions.current.settings : nil
    )

    // MARK: The ground
    //
    // Small objects that many parts of the model share, in `Lockstep/Model/Ground/`. A part is
    // handed the ones it needs and uses them directly.

    /// What the window shows: the content it draws, and the alert.
    let windowState = WindowState()
    /// What is selected: the clips, the track, the song and the marked stretch.
    let selection: Selection
    /// The open song, and the sound and the waveform of every recording of the open project.
    let loadedSounds = LoadedSounds()
    /// The player, and the line of everything it is told to do.
    let player: Player
    /// Whether a take is going, and how far it has come.
    let takeStatus = TakeStatus()
    /// The loop: the stretch that repeats, and its in and out.
    let loopState: LoopState
    // The microphone is ground too. It is `recorder`, further down: made there, once, and handed
    // from there to the code that records and to calibration.

    // The parts. Each is a feature of its own, handed the ground and the parts it calls, and
    // none of them holds this model. They are made in `init` in this order, because a part can
    // only be handed parts that are made already, and `wire()` then gives each its closures.

    /// The click.
    let click: ClickModel
    /// The loop commands.
    let loop: LoopModel
    /// The timeline's view.
    let timelineView: TimelineViewModel
    /// A track's Voice.
    let voice: VoiceModel
    /// Correction.
    let correction: CorrectionModel
    /// A track's Sound.
    let sound: SoundModel
    /// The words of clips.
    let words: WordsModel
    /// The volume of clips.
    let volume: VolumeModel
    /// The song's own volume.
    let songVolume: SongVolumeModel
    /// Tracks.
    let tracks: TracksModel
    /// A track's own volume.
    let trackVolume: TrackVolumeModel
    /// Editing clips.
    let clipEditing: ClipEditingModel
    /// The effects of clips.
    let clipEffects: ClipEffectsModel
    /// Choosing takes.
    let takes: TakesModel
    /// Copy Sound and Paste Sound.
    let soundCopy: SoundCopyModel
    /// Send to DaVinci.
    let send: SendModel
    /// Showing and hearing clips.
    let clips: ClipsModel
    /// The beats.
    let beats: BeatsModel
    /// Recording slower.
    let slowTake: SlowTakeModel
    /// The transport.
    let transport: TransportModel
    /// Calibration.
    let calibration: CalibrationModel
    /// Moving the playhead.
    let playheadModel: PlayheadModel
    /// The song's place.
    let songPlace: SongPlaceModel
    /// Opening and saving.
    let openingModel: OpeningModel

    /// Where the playhead is. Only the timeline's playhead view reads it.
    let playhead = PlayheadPosition()

    /// The tempo at the playhead, as the bar shows it. Only the tempo readout reads
    /// it, so a change of the tempo while the song plays draws nothing else again.
    let tempo = TempoReading()

    /// The microphone level, as the bar shows it. Only the level meter reads it. It
    /// moves while a take is going and is empty otherwise, because the microphone is
    /// closed then.
    let micLevel = MicLevelReading()

    /// The microphone. It is open only while a take is going. This is the one place a recorder is
    /// made: an agent's run with `-recordTake` gets one that hears a sound file and never opens the
    /// microphone (`TransportModel+RecordTake.swift`), and every other run the usual one.
    @ObservationIgnored private let recorder = FileMicrophone.current?.recorder ?? Recorder()

    init() {
        selection = Selection(store: store)
        player = Player(windowState: windowState)
        loopState = LoopState(windowState: windowState, player: player)
        // The parts, each after the parts it is handed.
        click = ClickModel(
            windowState: windowState, takeStatus: takeStatus, player: player, store: store,
            settings: settings
        )
        loop = LoopModel(
            selection: selection, loadedSounds: loadedSounds, takeStatus: takeStatus,
            loopState: loopState, store: store, settings: settings, playhead: playhead
        )
        timelineView = TimelineViewModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, loopState: loopState, store: store, settings: settings,
            playhead: playhead
        )
        voice = VoiceModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, store: store, settings: settings, playhead: playhead
        )
        correction = CorrectionModel(
            selection: selection, loadedSounds: loadedSounds, takeStatus: takeStatus, store: store,
            settings: settings, voice: voice
        )
        sound = SoundModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, store: store, settings: settings, playhead: playhead,
            correction: correction, voice: voice
        )
        words = WordsModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds, takeStatus: takeStatus, store: store,
            settings: settings
        )
        volume = VolumeModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, store: store, settings: settings
        )
        songVolume = SongVolumeModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, player: player, store: store
        )
        tracks = TracksModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, store: store, words: words, voice: voice
        )
        trackVolume = TrackVolumeModel(takeStatus: takeStatus, store: store, tracks: tracks)
        clipEditing = ClipEditingModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, player: player, store: store, settings: settings,
            playhead: playhead, timelineView: timelineView, loop: loop, words: words, tracks: tracks,
            correction: correction
        )
        clipEffects = ClipEffectsModel(
            selection: selection, loadedSounds: loadedSounds, takeStatus: takeStatus, store: store,
            correction: correction, sound: sound, clipEditing: clipEditing
        )
        takes = TakesModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, store: store, words: words, voice: voice, clipEditing: clipEditing
        )
        soundCopy = SoundCopyModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, store: store
        )
        send = SendModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, store: store, settings: settings, correction: correction,
            sound: sound, voice: voice
        )
        clips = ClipsModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, player: player, store: store, settings: settings,
            voice: voice, correction: correction, sound: sound, words: words, volume: volume, tracks: tracks,
            clipEditing: clipEditing, clipEffects: clipEffects, takes: takes, send: send
        )
        beats = BeatsModel(
            windowState: windowState, loadedSounds: loadedSounds, takeStatus: takeStatus,
            store: store, settings: settings, playhead: playhead, tempo: tempo, click: click,
            loop: loop, correction: correction, clips: clips
        )
        slowTake = SlowTakeModel(
            windowState: windowState, loadedSounds: loadedSounds, loopState: loopState, player: player,
            store: store, settings: settings, click: click, correction: correction
        )
        transport = TransportModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, loopState: loopState, player: player, recorder: recorder,
            store: store, settings: settings, playhead: playhead, micLevel: micLevel,
            timelineView: timelineView, correction: correction, words: words, volume: volume,
            takes: takes, loop: loop, clips: clips, beats: beats, slowTake: slowTake
        )
        calibration = CalibrationModel(
            windowState: windowState, loadedSounds: loadedSounds, takeStatus: takeStatus,
            player: player, recorder: recorder, store: store, settings: settings, clips: clips,
            transport: transport
        )
        playheadModel = PlayheadModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, store: store, settings: settings, playhead: playhead,
            timelineView: timelineView, clips: clips, transport: transport
        )
        songPlace = SongPlaceModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, loopState: loopState, player: player, store: store,
            settings: settings, playhead: playhead, timelineView: timelineView, click: click,
            send: send, clips: clips, calibration: calibration
        )
        openingModel = OpeningModel(
            windowState: windowState, selection: selection, loadedSounds: loadedSounds,
            takeStatus: takeStatus, loopState: loopState, player: player, store: store,
            settings: settings, playhead: playhead, recentProjects: recentProjects,
            timelineView: timelineView, transport: transport, beats: beats, click: click,
            clips: clips, tracks: tracks, songPlace: songPlace, calibration: calibration, send: send,
            correction: correction, loop: loop, playheadModel: playheadModel, words: words,
            clipEditing: clipEditing, songVolume: songVolume, trackVolume: trackVolume,
            slowTake: slowTake, sound: sound, voice: voice
        )
        wire()
        // What the ground asks of the transport.
        player.nothingLeft = { [weak self] in self?.transport.readEngine() }
        takeStatus.phaseChanged = { [weak self] in self?.transport.takePhaseChanged() }
        loopState.takesStretchGoesRound = { [weak self] in self?.transport.takesStretch?.repeats == true }
        player.frames.onFrame = { [weak self] in self?.transport.followPlayback() }
        // Undo and Redo put an older copy of the project back. Its beat list is fitted
        // again from what beat finding kept, with the corrections that copy holds, and
        // the click and the clips follow what that copy says.
        store.rebuildDerived = { [weak self] project in
            // What is left of the song comes first: the click and the clips are laid out for it.
            self?.songPlace.followSongPlace(of: project)
            self?.beats.refit(&project)
            self?.click.followClick(of: project)
            // The song is heard as loud as that copy says.
            self?.songVolume.followSongVolume(of: project)
            // A copy from before some words arrived gets them again, before the clips are drawn.
            self?.words.fillInWords(&project)
            // A clip that Undo took away or brought back is heard, or not, at once.
            self?.clips.followClips(of: project)
        }
        store.saveFailed = { [weak self] error in self?.openingModel.saveFailed(error) }
        words.startWords()
        // So a Delete can say how long its key press waited (`ClipEditingModel+EditTiming.swift`).
        KeyPressWatch.app.start()
        beats.followSettings()
        // Command held turns snapping the other way, also in the middle of a drag (`SnapKeyWatch`).
        watchSnapKey()
        clipEditing.followPlayheadForSplitting()
        calibration.followSoundDevices()
        // Any audio engine: the one that plays and the one a take records with.
        transport.deviceChangeWatch = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil,
            using: TransportModel.deviceChangeReport(to: transport)
        )
    }

    // MARK: Wiring

    /// Gives every part its closures: what it asks of a part that holds it, which it therefore
    /// cannot be handed, or of this model's routing. Each part has its own function for it, in
    /// its own file, so that filling one part never changes the lines of another.
    private func wire() {
        wireClick()
        wireLoop()
        wireTimelineView()
        wireVoice()
        wireCorrection()
        wireSound()
        wireWords()
        wireVolume()
        wireSongVolume()
        wireTracks()
        wireTrackVolume()
        wireClipEditing()
        wireClipEffects()
        wireTakes()
        wireSoundCopy()
        wireSend()
        wireClips()
        wireBeats()
        wireSlowTake()
        wireTransport()
        wireCalibration()
        wirePlayhead()
        wireSongPlace()
        wireOpening()
    }

    // MARK: Commands

    /// Whether a command can do anything right now. The menu greys out the rest.
    func canPerform(_ command: AppCommand) -> Bool {
        // The calibrate sheet lies over the window. Until it is closed nothing else is done.
        if calibration.calibrationSheet != nil { return false }
        // The same while the Send to DaVinci panel is open.
        if send.sendSheet != nil { return false }
        // While a take is going, only stopping it, starting it over and zooming are left.
        if let takePhase = takeStatus.phase {
            switch command {
            // Play or Stop stops the take.
            case .playStop: return takePhase != .finishing
            // Record starts it over. Also during the moment a restart is being carried out:
            // the item stays as it is and a second press is simply ignored (`restartTake`).
            case .record: return takeStatus.flow.isGoing
            case .zoomIn, .zoomOut, .zoomToFit: return true
            case .tallerTracks, .lowerTracks: return timelineView.canStepTrackHeight(command)
            default: return false
            }
        }
        return switch command {
        case .openSong: true
        // The submenu is always there. Its own items say what can be done.
        case .openRecent: true
        // Without beats there is no click to save.
        case .createClickTrack: store.project.grid != nil
        // Every selected clip is sent.
        case .sendToDaVinci: send.canSendSelectedClip
        case .playStop, .goBack, .goToStart, .previousScreen, .nextScreen: loadedSounds.song != nil && !loadedSounds.isOpening
        // Without beats there is nothing to step along.
        case .previousSubBeat, .nextSubBeat, .previousHalfBeat, .nextHalfBeat, .previousBeat, .nextBeat:
            playheadModel.canStepPlayhead
        // Whether there is a clip that way is found out when the key is pressed.
        case .previousClip, .nextClip, .clipAbove, .clipBelow: loadedSounds.song != nil && !loadedSounds.isOpening
        case .clickOnOff: loadedSounds.song != nil
        // Also while the microphone is refused, so that pressing it can say how to allow it.
        case .record: loadedSounds.song != nil && !loadedSounds.isOpening
        // Needs no song: the ticks are the app's own sound.
        case .calibrateDelay: !loadedSounds.isOpening
        // Loop can always be switched off. It is switched on for a marked stretch.
        case .loop: loopState.region != nil || loop.canTurnLoopOn
        // The playhead always stands somewhere in the song, so an end can always be put there.
        case .setLoopIn, .setLoopOut: loadedSounds.song != nil && !loadedSounds.isOpening
        case .clearLoopInAndOut: loopState.region != nil || loopState.inOut != nil
        case .zoomIn, .zoomOut, .zoomToFit: loadedSounds.song != nil
        case .tallerTracks, .lowerTracks: timelineView.canStepTrackHeight(command)
        case .findBeatsAgain: loadedSounds.song != nil && !loadedSounds.isOpening
        // Halving and doubling go one step at a time and stop at the ends.
        case .halveTempo: store.project.grid.map { $0.tempoLevel != .halved } ?? false
        case .doubleTempo: store.project.grid.map { $0.tempoLevel != .doubled } ?? false
        case .thisIsBeatOne: store.project.grid != nil
        // A project always has a track, and one of them is always selected.
        case .newTrack, .renameTrack, .muteTrack, .duplicateTrack, .duplicateTrackWithClips:
            loadedSounds.song != nil && !loadedSounds.isOpening
        // A merge needs another track to go into, and the only track cannot be deleted.
        case .mergeInto, .deleteTrack: loadedSounds.song != nil && !loadedSounds.isOpening && store.project.tracks.count > 1
        // Delete removes the marked stretch, or else the selected clips.
        case .delete: selection.markedStretch != nil || !selection.clipIDs.isEmpty
        case .copyClips: clipEditing.canCopySelectedClips
        case .pasteClips: clipEditing.canPasteClips
        // One selected clip, or a selected track, has a sound to copy, and a copied sound goes on either.
        case .copySound: soundCopy.canCopySound
        case .pasteSound: soundCopy.canPasteSound
        case .muteClip: !selection.clipIDs.isEmpty
        case .splitAtPlayhead: clipEditing.canSplitAtPlayhead
        case .joinClips: store.project.canJoin(selection.clipIDs)
        // Snapping is a setting of the app, so it can be switched with or without a song.
        case .snapping: true
        // So are the choices of what to snap to.
        case .snapToGrid, .snapToClipEdges, .snapToPlayhead, .snapToRecordedPlace,
             .snapGridSubBeats, .snapGridHalfBeats, .snapGridBeats, .snapGridBars: true
        // There is nothing to clear until a stretch is marked. Its key, Escape, is then free for everything else.
        case .clearMarkedStretch: selection.markedStretch != nil
        // A name is typed for one clip at a time.
        case .renameClip: selection.clipIDs.count == 1
        // Only a selected clip that has other takes has a take to step to, or to delete.
        case .nextTake, .previousTake, .deleteOtherTakes:
            selection.clipIDs.contains { store.project.takeCount(of: $0) > 1 }
        case .normalize: volume.canNormalizeSelectedClips
        case .normalizeTrack: volume.canNormalizeSelectedTrack
        // The correction is switched and chosen for the selected clips.
        case .correctionOnOff, .correctionOff, .correctionLines, .correctionAll: !selection.clipIDs.isEmpty
        // So is what it aims at. The submenu of tracks needs a track the selected clips are not on.
        case .aimAtBeat: correction.canChooseAim
        case .aimAt: correction.canChooseAim && !correction.aimTargets.isEmpty
        case .writeOutWords: words.canWriteOutSelectedClips
        case .clipFeelSixteenths, .clipFeelTriplets, .clipFeelAuto: correction.canChooseFeel(command)
        // An effect goes on the words that are marked in a clip, or else on the selected clips.
        case .doubleThick, .doubleLowFourth, .doubleLowOctave, .doubleHigh, .doubleBig, .doubleSmall,
             .wordEchoQuarter, .wordEchoEighth, .wordPhone, .wordStutter, .wordTapeStop, .wordSwell:
            clipEffects.canAddEffect
        // A track's effect goes on the selected track.
        case .trackDoubleThick, .trackDoubleLowFourth, .trackDoubleLowOctave, .trackDoubleHigh, .trackDoubleBig,
             .trackDoubleSmall, .trackEchoQuarter, .trackEchoEighth, .trackPhone:
            clipEffects.canAddTrackEffect
        // A track's Voice belongs to the selected track.
        case .trackVoiceOnOff, .trackVoiceDarker, .trackVoiceDeeper, .trackVoiceLighter:
            selection.trackID.flatMap { store.project.track($0) } != nil
        }
    }

    func perform(_ command: AppCommand) {
        guard canPerform(command) else { return }
        // A name that is being typed is kept before anything else is done. Zooming
        // changes nothing, so the typing goes on.
        if command != .renameTrack, !command.changesOnlyTheView {
            tracks.stopRenamingTrack()
        }
        // The same for the name of a clip.
        if command != .renameClip, !command.changesOnlyTheView {
            clipEditing.stopRenamingClip()
        }
        // Open Song and Create Click Track wait in a panel until Max has chosen, which is no edit to time.
        guard command != .openSong, command != .createClickTrack else { return carryOut(command) }
        // A command that shows the clips again leaves a line in the Mac's log saying how long it took.
        clipEditing.timeEdit(menuTitle(of: command)) { carryOut(command) }
    }

    /// Hands a command to the part that carries it out.
    private func carryOut(_ command: AppCommand) {
        switch command {
        case .openSong: openingModel.chooseSong()
        // Choosing a project in the submenu opens it. The submenu itself does nothing.
        case .openRecent: break
        case .createClickTrack: click.saveClickFile()
        case .sendToDaVinci: send.openSendPanel()
        case .playStop: transport.playOrStop()
        case .goBack: playheadModel.goBack()
        case .goToStart: transport.jump(to: store.project.keptSeconds.lowerBound)
        case .previousScreen: transport.jumpScreen(by: -1)
        case .nextScreen: transport.jumpScreen(by: 1)
        case .previousSubBeat, .nextSubBeat, .previousHalfBeat, .nextHalfBeat, .previousBeat, .nextBeat:
            playheadModel.stepPlayhead(command)
        case .previousClip, .nextClip, .clipAbove, .clipBelow: playheadModel.jumpToClip(command)
        case .clickOnOff: click.turnClickOnOrOff()
        case .record: transport.recordOrRestart()
        case .calibrateDelay: calibration.openCalibrateSheet()
        case .loop: loop.toggleLoop()
        case .setLoopIn: loop.setLoopEnd(.in)
        case .setLoopOut: loop.setLoopEnd(.out)
        case .clearLoopInAndOut: loop.clearLoopInAndOut()
        case .zoomIn: timelineView.zoom(by: TimelineViewModel.zoomStep)
        case .zoomOut: timelineView.zoom(by: 1 / TimelineViewModel.zoomStep)
        case .zoomToFit: timelineView.zoomToFit()
        case .tallerTracks: timelineView.trackHeight = TrackHeight.stepped(timelineView.trackHeight, taller: true)
        case .lowerTracks: timelineView.trackHeight = TrackHeight.stepped(timelineView.trackHeight, taller: false)
        case .findBeatsAgain: beats.findBeatsAgain()
        case .halveTempo: beats.stepTempoLevel(by: -1, command)
        case .doubleTempo: beats.stepTempoLevel(by: 1, command)
        // From the menu bar it is the beat nearest the playhead.
        case .thisIsBeatOne: beats.setBeatOne(nearest: playhead.seconds)
        case .newTrack: tracks.addTrack()
        case .renameTrack: tracks.renameSelectedTrack()
        case .duplicateTrack: tracks.duplicateSelectedTrack(withClips: false)
        case .duplicateTrackWithClips: tracks.duplicateSelectedTrack(withClips: true)
        // Choosing a track in the submenu merges. The submenu itself does nothing.
        case .mergeInto: break
        case .muteTrack: tracks.muteSelectedTrack()
        case .deleteTrack: tracks.deleteSelectedTrack()
        case .delete: clipEditing.deleteMarkedStretchOrClips()
        case .copyClips: clipEditing.copySelectedClips()
        case .pasteClips: clipEditing.pasteCopiedClips()
        case .copySound: soundCopy.copySound()
        case .pasteSound: soundCopy.pasteSound()
        case .splitAtPlayhead: clipEditing.splitAtPlayhead()
        case .joinClips: clipEditing.joinSelectedClips()
        case .snapping: toggleSnapping()
        case .snapToGrid, .snapToClipEdges, .snapToPlayhead, .snapToRecordedPlace,
             .snapGridSubBeats, .snapGridHalfBeats, .snapGridBeats, .snapGridBars: chooseSnapTo(command)
        case .clearMarkedStretch: clipEditing.clearMarkedStretch()
        case .renameClip: clipEditing.renameSelectedClip()
        case .muteClip: clipEditing.muteSelectedClips()
        case .nextTake: takes.stepTake(by: 1, command)
        case .previousTake: takes.stepTake(by: -1, command)
        case .deleteOtherTakes: takes.deleteOtherTakes()
        case .normalize: volume.normalizeSelectedClips()
        case .normalizeTrack: volume.normalizeSelectedTrack()
        case .correctionOnOff: correction.toggleCorrection()
        case .correctionOff: correction.setSelectedClipsCorrection(.off)
        case .correctionLines: correction.setSelectedClipsCorrection(.lines)
        case .correctionAll: correction.setSelectedClipsCorrection(.all)
        case .aimAtBeat: correction.setSelectedClipsAim(nil)
        // A submenu: its lines are tracks, and choosing one comes through `aimSelectedClips(at:)`.
        case .aimAt: break
        case .writeOutWords: words.writeOutSelectedClips()
        case .clipFeelSixteenths, .clipFeelTriplets, .clipFeelAuto: correction.chooseFeel(command)
        case .doubleThick, .doubleLowFourth, .doubleLowOctave, .doubleHigh, .doubleBig, .doubleSmall,
             .wordEchoQuarter, .wordEchoEighth, .wordPhone, .wordStutter, .wordTapeStop, .wordSwell:
            if let kind = command.effectKind { clipEffects.addEffect(kind) }
        case .trackDoubleThick, .trackDoubleLowFourth, .trackDoubleLowOctave, .trackDoubleHigh, .trackDoubleBig,
             .trackDoubleSmall, .trackEchoQuarter, .trackEchoEighth, .trackPhone:
            if let kind = command.trackEffectKind { clipEffects.addTrackEffect(kind) }
        case .trackVoiceOnOff:
            if let trackID = selection.trackID { voice.voiceMenu(.onOrOff, on: trackID) }
        case .trackVoiceDarker, .trackVoiceDeeper, .trackVoiceLighter:
            if let trackID = selection.trackID, let name = command.voicePresetName {
                voice.voiceMenu(.chosen(name), on: trackID)
            }
        }
    }

    /// Whether what a command switches is on. The menu ticks its item while it is.
    func isOn(_ command: AppCommand) -> Bool {
        if let choice = command.snapChoice {
            return settings.snapChoices[keyPath: choice]
        }
        if let unit = command.snapGridUnit {
            return settings[.snapGridUnit] == unit
        }
        return switch command {
        case .snapping: settings[.snapping]
        case .correctionOnOff: correction.selectedClipsAreCorrected
        case .correctionOff, .correctionLines, .correctionAll: correction.correctionIsChosen(command)
        case .aimAtBeat: correction.aimIsChosen(nil)
        case .clipFeelSixteenths, .clipFeelTriplets, .clipFeelAuto: correction.feelIsChosen(command)
        case .loop: loopState.region != nil
        case .trackVoiceOnOff, .trackVoiceDarker, .trackVoiceDeeper, .trackVoiceLighter: voice.isChosen(command, on: selection.trackID)
        default: false
        }
    }

    /// The title of a command's item in the menu bar right now. Delete says what it would
    /// remove: the marked stretch, one clip or several. Every other command has its own title.
    func menuTitle(of command: AppCommand) -> String {
        guard command == .delete else { return command.title }
        if selection.markedStretch != nil {
            return ClipEditingModel.deleteMarkedStretchTitle
        }
        return selection.clipIDs.count > 1 ? "Delete Clips" : "Delete Clip"
    }

    // MARK: Snapping

    /// Snapping: turns snapping on, or off when it is on. The setting is kept at once.
    func toggleSnapping() {
        settings[.snapping].toggle()
        // Whatever is being dragged right now snaps, or stops snapping, at once.
        followSnappingDrags()
    }

    /// A choice of Edit > Snap To: one of the four things to snap to is switched on or off, or a unit
    /// of the grid is chosen. The settings keep it at once.
    func chooseSnapTo(_ command: AppCommand) {
        var choices = settings.snapChoices
        if let choice = command.snapChoice {
            choices[keyPath: choice].toggle()
        } else if let unit = command.snapGridUnit {
            choices.gridUnit = unit
        }
        setSnapChoices(choices)
    }

    /// What snapping catches on was changed, in the menu beside the snapping button or in Edit > Snap To.
    /// A drag that is going on keeps what it started with.
    func setSnapChoices(_ choices: SnapChoices) {
        settings.snapChoices = choices
    }

    /// Snapping was turned the other way in the middle of a drag (N, or Command pressed or let go):
    /// whatever is being dragged snaps, or stops snapping, at once. Each does nothing without a drag.
    func followSnappingDrags() {
        clipEditing.followClipDrag()
        clipEditing.followClipTrim()
        clipEditing.followStretchDrag()
        playheadModel.followPlayheadDrag()
        songPlace.followSongDrag()
    }

    /// Starts listening for Command, once, for as long as the app runs.
    func watchSnapKey() {
        SnapKeyWatch.app.onChange = { [weak self] in self?.followSnappingDrags() }
        SnapKeyWatch.app.start()
    }
}

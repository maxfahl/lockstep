import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import Observation

/// The beats: a part of the app's model.
///
/// It holds the beats of the song: finding them, correcting them (moving a beat, beat one, half
/// and double tempo), fitting them again when a setting changes, the beat lines of the timeline and
/// the tempo readout.
///
/// When a song has been opened, its beats are found in the background (`findBeats`).
/// `beatFinding` says how far that has come. The beats end up in `store.project.grid`. What Max
/// corrects about them goes through `editGrid`, which fits the beat lines again. If the beats
/// cannot be found, the window's message says so (`windowState.content.message`).
///
/// It is also where the settings the open song follows are listened for. `settings` is what the
/// settings window changes, and most of it is read at the moment it is needed. The three beat
/// settings and the accent on beat 1 also act on the song that is open: `followSettings` hears of
/// a change and tells the click, the clips and then the beats, so the beat lines are fitted, or
/// the click is laid out, again.
///
/// Its `init` is final. It has no closures: everything it calls it is handed.
@MainActor
@Observable
final class BeatsModel {
    // The ground it is handed.
    @ObservationIgnored private let windowState: WindowState
    @ObservationIgnored private let loadedSounds: LoadedSounds
    @ObservationIgnored private let takeStatus: TakeStatus
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let playhead: PlayheadPosition
    @ObservationIgnored private let tempo: TempoReading

    // The parts it is handed, and calls directly.
    @ObservationIgnored private let click: ClickModel
    @ObservationIgnored private let loop: LoopModel
    @ObservationIgnored private let correction: CorrectionModel
    @ObservationIgnored private let clips: ClipsModel

    /// How far the finding of the open song's beats has come, and what is being done
    /// right now ("Listening", "Finding beats", "Lining up"). Nil when beats are not
    /// being found. The beats, once found, are in `store.project.grid`. The song row
    /// shows it under the song's name.
    var beatFinding: BeatFindingProgress? {
        didSet { windowState.content.timeline.beatFinding = beatFinding }
    }

    /// What beat finding worked out for the open song: the model's answer and the onset
    /// curve. The beat lines are fitted again from it after every correction, without
    /// running the model. Nil until the beats are found. It is also kept in the
    /// project's cache folder.
    @ObservationIgnored var beatCache: BeatCache? {
        // The fit that was kept was made from the cache before this one.
        didSet { keptFit = nil }
    }
    /// The beat list that was fitted last, and the four things besides `beatCache` it was fitted from.
    /// A fit depends on nothing else (`BeatFinder.refit`), so `refit` hands the same list back while they
    /// are the same. Undo and Redo ask for a fit every time, and nearly always for the one that is there.
    private struct KeptFit {
        var settings: BeatSettings
        var decided: Grid
        var grid: Grid

        func isOf(_ settings: BeatSettings, _ decided: Grid) -> Bool {
            self.settings == settings && self.decided.anchors == decided.anchors
                && self.decided.tempoLevel == decided.tempoLevel && self.decided.beatOne == decided.beatOne
        }
    }
    @ObservationIgnored private var keptFit: KeptFit?
    /// The finding of beats that is still going on.
    @ObservationIgnored private(set) var beatSearch: Task<Void, Never>?
    /// Counts every search for beats, so progress and results of a search that was given
    /// up for a newer one are not shown.
    @ObservationIgnored var beatSearchNumber = 0
    /// What beat finding worked out for the open song when it ended without beats. It is kept
    /// so that moving the slider in Settings > Beats and Click can pick the beats again at once,
    /// without running the model. It is not `beatCache`, because a song without beats has no
    /// beat lines to fit again, and it is not written into the project, so the next opening
    /// searches anew and says again that there are none.
    @ObservationIgnored var beatlessCache: BeatCache?
    /// The three settings of beat finding, as Settings has them right now.
    private var beatSettings: BeatSettings {
        BeatSettings(
            maxGapBeats: settings[.maxGapBeats],
            smoothingBeats: settings[.smoothingBeats],
            certaintyLimit: settings[.certaintyLimit]
        )
    }
    /// The beat settings the open song's beat lines were last fitted with.
    @ObservationIgnored private var fittedBeatSettings: BeatSettings?
    /// The wait before the beat lines are fitted again after a beat setting changed.
    @ObservationIgnored private var settingsRefit: Task<Void, Never>?
    /// Where the playhead was, in song seconds, when the tempo was last worked out.
    @ObservationIgnored private(set) var tempoShownAt = 0.0

    init(
        windowState: WindowState,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore,
        settings: AppSettings,
        playhead: PlayheadPosition,
        tempo: TempoReading,
        click: ClickModel,
        loop: LoopModel,
        correction: CorrectionModel,
        clips: ClipsModel
    ) {
        self.windowState = windowState
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
        self.settings = settings
        self.playhead = playhead
        self.tempo = tempo
        self.click = click
        self.loop = loop
        self.correction = correction
        self.clips = clips
    }

    // MARK: Settings the open song follows

    /// How long a beat setting must have been left alone before the beat lines are
    /// fitted again. A stepper that is clicked many times, or a slider that is dragged,
    /// then gives one new fit and not one for every step.
    private static let settingsRefitPause = Duration.milliseconds(300)

    /// Listens for the next change of a setting that the open song has to follow: the
    /// three beat settings, the accent on beat 1 and the count-in the click menu shows.
    /// Called once at the start, and again after every change it heard of.
    func followSettings() {
        withObservationTracking(
            {
                _ = beatSettings
                _ = settings[.accentBeatOne]
                _ = settings[.edgeFadeMs]
                // Restore Defaults in Settings > Recording puts the count-in back, and the click menu shows it.
                _ = settings[.runUpBars]
                // The pause between lines, the furthest slide and how far off counts as meant: a tightened
                // track is made again with the new numbers (`followClips` sees that its sounds are out of date).
                _ = correction.tightenSettings
            },
            onChange: Self.settingsChangeReport(to: self)
        )
    }

    /// What the settings call when one that is listened for is about to change. It is
    /// made here, outside the main actor, and comes back to the model on the main
    /// actor a moment later, when the new value is in place.
    private nonisolated static func settingsChangeReport(to model: BeatsModel) -> @Sendable () -> Void {
        { [weak model] in
            Task { @MainActor in
                model?.settingsChanged()
            }
        }
    }

    /// A beat setting or the accent on beat 1 was changed in the settings window.
    private func settingsChanged() {
        followSettings()
        // Without a song there is nothing that could follow.
        guard loadedSounds.song != nil else { return }
        // The click is laid out again only if the accent is what changed.
        click.followClick(of: store.project)
        // The clips are handed to the player again, with the fade at their edges as it is now.
        // The player does nothing when neither the clips nor the fade have changed.
        clips.followClips(of: store.project)
        guard beatSettings != fittedBeatSettings else { return }
        settingsRefit?.cancel()
        settingsRefit = Task {
            try? await Task.sleep(for: Self.settingsRefitPause)
            guard !Task.isCancelled else { return }
            refitAfterSettingsChange()
        }
    }

    /// Fits the open song's beat lines again with the beat settings as they are now,
    /// from what beat finding kept, without running the model. What Max corrected (the
    /// dragged beats, the tempo level, his beat 1) stays. It is not an undo step: the
    /// setting is for every song, not an edit of this one.
    private func refitAfterSettingsChange() {
        guard beatSettings != fittedBeatSettings else { return }
        if let beatlessCache {
            pickBeatsAgain(from: beatlessCache)
            return
        }
        guard beatCache != nil, store.project.grid != nil else { return }
        store.setDerived { refit(&$0) }
        // A stricter limit can leave a song without beats, and a looser one brings them back.
        if store.project.grid?.beats.isEmpty ?? true {
            windowState.content.message = Self.noBeatsMessage
        } else if windowState.content.message == Self.noBeatsMessage {
            windowState.content.message = nil
        }
    }

    /// A song in which no beats were found gets its beats from what that search kept, once the
    /// limit in Settings lets some through. The model does not run again. From then on the song
    /// is like any other with beats: they are saved, and what they were fitted from is kept in
    /// the project.
    private func pickBeatsAgain(from kept: BeatCache) {
        guard let package = store.package else { return }
        let settings = beatSettings
        fittedBeatSettings = settings
        let grid = BeatFinder.refit(cache: kept, settings: settings, anchors: [], tempoLevel: .normal, beatOne: nil)
        guard !grid.beats.isEmpty else { return }
        beatlessCache = nil
        beatCache = kept
        if windowState.content.message == Self.noBeatsMessage {
            windowState.content.message = nil
        }
        store.setDerived { refit(&$0) }
        Self.keep(kept, in: package)
    }

    // MARK: Finding the beats

    /// What the window says when the beats could not be found. The banner is one line of
    /// about 75 letters and cuts a longer text short, so this says what happened and the
    /// one thing to try in fewer than that.
    private static let noBeatsMessage = "No beats found. Try Loose in Settings > Beats and Click."

    /// Finds the beats of the open song in the background and puts them in the project.
    /// It is called when a song has been opened. Calling it again starts over.
    ///
    /// The song plays as usual meanwhile. `beatFinding` holds the progress. Finding the
    /// beats is not an edit, so it is not an undo step. If it fails, a message at the top
    /// of the window says why and the project keeps the beats it had, if any.
    ///
    /// `sound` is the song when the caller has just read it. Without it the song is read
    /// from the project's `song.wav`, so the sound of a whole song need not be kept in
    /// memory just for this.
    func findBeats(in sound: ImportedSong? = nil) {
        guard loadedSounds.song != nil, let package = store.package else { return }
        let songFile = package.songFile(of: store.project)
        beatSearch?.cancel()
        beatSearchNumber += 1
        beatlessCache = nil
        let number = beatSearchNumber
        if windowState.content.message != nil {
            windowState.content.message = nil
        }
        beatFinding = BeatFindingProgress(phaseName: BeatFinder.Phase.listening.name, fraction: 0)
        let progress = Self.beatProgressReport(to: self, search: number)
        let settings = beatSettings
        beatSearch = Task {
            do {
                let heard: ImportedSong
                if let sound {
                    heard = sound
                } else {
                    heard = try await SongImporter.importSong(from: songFile)
                }
                let found = try await BeatFinder.findBeats(in: heard, settings: settings, progress: progress)
                // Another song, or another search, may have taken over meanwhile.
                guard number == beatSearchNumber else { return }
                beatFinding = nil
                guard !found.grid.beats.isEmpty else {
                    windowState.content.message = Self.noBeatsMessage
                    // A looser limit in Settings may find beats in what the model gave.
                    beatlessCache = found.cache
                    fittedBeatSettings = settings
                    tellAgentAboutBeats(nil, from: found.cache, with: settings)
                    // The slider may have been moved while the search was going.
                    refitAfterSettingsChange()
                    click.failLaunchClickFile(because: "no beats were found")
                    loop.turnLaunchLoopOn(beatsWereFound: false)
                    return
                }
                beatCache = found.cache
                // The store saves the beats with the project. What they were fitted from
                // goes into the project's cache, so the model need not run again next time.
                store.setDerived { refit(&$0) }
                Self.keep(found.cache, in: package)
                tellAgentAboutBeats(store.project.grid, from: found.cache, with: beatSettings)
                click.writeLaunchClickFile()
                loop.turnLaunchLoopOn(beatsWereFound: true)
            } catch is CancellationError {
                // The newer search shows its own progress and result.
            } catch {
                guard number == beatSearchNumber else { return }
                beatFinding = nil
                windowState.content.message = error as? BeatModelError == .notInstalled
                    ? BeatModelError.notInstalled.message
                    : Self.noBeatsMessage
                click.failLaunchClickFile(because: "the beats could not be found")
                loop.turnLaunchLoopOn(beatsWereFound: false)
            }
        }
    }

    /// In a `-scratch` run, one line on standard error says what the search for beats ended
    /// with: how many beats, how many of them were found by trying again less strictly, and the
    /// limit that was in force. The project file cannot tell those beats from other uncertain ones.
    private func tellAgentAboutBeats(_ grid: Grid?, from cache: BeatCache, with settings: BeatSettings) {
        guard LaunchOptions.current.isScratch else { return }
        let limit = String(format: "%.2f", settings.certaintyLimit)
        guard let grid, !grid.beats.isEmpty else {
            Agent.tell("found no beats, with the limit at \(limit)")
            return
        }
        let loosened = BeatFinder.loosenedBeatCount(cache: cache, settings: settings)
        let uncertain = BeatRefiner.uncertainRanges(in: grid.beats).count
        Agent.tell(
            "found \(grid.beats.count) beats, \(loosened) of them by trying again less strictly, "
                + "\(uncertain) uncertain stretches, with the limit at \(limit)"
        )
    }

    /// Writes what beat finding worked out into a project's cache folder, in the
    /// background. If that fails nothing is said: the cache can always be made again,
    /// and the next opening of the project then finds the beats anew.
    private nonisolated static func keep(_ cache: BeatCache, in package: ProjectPackage) {
        Task.detached(priority: .utility) {
            try? cache.write(to: package)
        }
    }

    /// Changes what Max decided about the beats (a dragged beat, half or double tempo,
    /// which beat is beat 1) and fits the beat lines again, as one step that can be undone.
    /// Does nothing before the beats are found.
    ///
    ///     model.editGrid("Move Beat") { $0.anchors.append(Anchor(from: was, to: now)) }
    ///     model.editGrid("Halve Tempo") { $0.tempoLevel = .halved }
    func editGrid(_ actionName: String, _ change: (inout Grid) -> Void) {
        // No edit while a take is going.
        guard takeStatus.phase == nil else { return }
        guard beatCache != nil, store.project.grid != nil else { return }
        store.edit(actionName) { project in
            guard var grid = project.grid else { return }
            change(&grid)
            project.grid = grid
            refit(&project)
        }
    }

    // MARK: Correcting the beats

    /// A beat line was dragged from one place in the song to another and let go. The
    /// beat becomes an anchor: it stays exactly where Max put it, and the beats around
    /// it follow smoothly.
    func moveBeat(from: Double, to: Double) {
        guard let beatCache, let grid = store.project.grid,
            let beat = grid.beats.first(where: { $0.time == from })
        else { return }
        // Where every beat stands when no beat was dragged. The anchor is told from there.
        let unanchored = BeatFinder.refit(
            cache: beatCache,
            settings: beatSettings,
            anchors: [],
            tempoLevel: grid.tempoLevel,
            beatOne: grid.beatOne
        )
        let anchors = BeatMove.anchors(moving: beat, to: to, in: grid, unanchored: unanchored)
        editGrid("Move Beat") { $0.anchors = anchors }
    }

    /// Makes the beat nearest to a place in the song beat 1 of its bar. The bars of the
    /// whole song are counted from it.
    func setBeatOne(nearest seconds: Double) {
        guard let beat = store.project.grid?.beat(nearest: seconds) else { return }
        editGrid("Set Beat 1") { $0.setBeatOne(at: beat.number) }
    }

    /// Halve Tempo (`step` -1) and Double Tempo (`step` 1): one step along halved,
    /// normal, doubled. Does nothing at the ends.
    func stepTempoLevel(by step: Int, _ command: AppCommand) {
        let levels = TempoLevel.allCases
        guard let grid = store.project.grid,
            let index = levels.firstIndex(of: grid.tempoLevel), levels.indices.contains(index + step)
        else { return }
        editGrid(command.title) { $0.tempoLevel = levels[index + step] }
    }

    /// Find Beats Again: forgets what Max corrected (the dragged beats, half or double
    /// tempo, his beat 1) and finds the beats from scratch.
    ///
    /// Forgetting the corrections is an edit, so Undo brings them back, on the beats as
    /// they are found anew. The search itself is not an edit. Until it is done the
    /// window shows the beats without the corrections.
    func findBeatsAgain() {
        if let grid = store.project.grid, !grid.anchors.isEmpty || grid.tempoLevel != .normal || grid.beatOne != nil {
            editGrid(AppCommand.findBeatsAgain.title) { grid in
                grid.anchors = []
                grid.tempoLevel = .normal
                grid.beatOne = nil
            }
        }
        findBeats()
    }

    /// Builds a project's beat list again from what beat finding kept, with the
    /// corrections the project holds: its anchors, its tempo level and its beat 1. A
    /// project without a grid (a copy from before the beats were found) gets the beats as
    /// they were found. Before the beats are found, nothing happens.
    ///
    /// Every change of the beats comes through here (finding them, a correction, Undo
    /// and Redo), so this is also where the window is given the new beat lines.
    func refit(_ project: inout Project) {
        guard let beatCache else { return }
        let decided = project.grid ?? Grid()
        let fitted = beatSettings
        fittedBeatSettings = fitted
        let grid: Grid
        if let keptFit, keptFit.isOf(fitted, decided) {
            grid = keptFit.grid
        } else {
            grid = BeatFinder.refit(
                cache: beatCache,
                settings: fitted,
                anchors: decided.anchors,
                tempoLevel: decided.tempoLevel,
                beatOne: decided.beatOne
            )
            keptFit = KeptFit(settings: fitted, decided: decided, grid: grid)
        }
        project.grid = grid
        showBeats(of: grid)
        click.followClick(of: project)
    }

    // MARK: The tempo

    /// How far the playhead moves, in song seconds, before the tempo is worked out again
    /// while the song plays.
    static let tempoStep = 0.1

    /// Shows the tempo of a grid where the playhead is: one decimal, or a dash where the
    /// song has no beats (before the first beat, after the last, in a stretch left empty).
    /// Without beats at all the readout is not there.
    ///
    /// The grid is handed in, and not read from the store, because this is also called
    /// in the middle of an edit, while the store's project is being changed.
    func showTempo(in grid: Grid?) {
        tempoShownAt = playhead.seconds
        var text = ""
        if let grid, !grid.beats.isEmpty {
            text = grid.tempo(at: playhead.seconds).map { String(format: "%.1f", $0) } ?? "–"
        }
        if tempo.text != text {
            tempo.text = text
        }
    }

    // MARK: The beats on the timeline

    /// When the song is zoomed so far out that its beat lines would stand closer together
    /// than this many points, the timeline draws only the bar lines.
    static let closestBeatLineSpacing: CGFloat = 4

    /// Hands the timeline the lines of a grid: a line on every beat, stronger at bar
    /// starts and with the bar's number for the ruler, the stretches the app is unsure
    /// about, and the stretches where no beat was placed.
    func showBeats(of grid: Grid) {
        let shown = ShownBeats(grid)
        var changed = windowState.content
        changed.timeline.beatLines = shown.lines
        changed.timeline.uncertainRanges = shown.uncertainRanges
        changed.timeline.unfilledGaps = shown.unfilledGaps
        // The song's right-click menu greys these out at the ends, like the Song menu.
        changed.canHalveTempo = grid.tempoLevel != .halved
        changed.canDoubleTempo = grid.tempoLevel != .doubled
        // With beats there is a click to save.
        changed.canCreateClickTrack = true
        // Undo and Redo show the beats every time, and nearly always the ones that are shown already.
        // Then nothing is written, and the window is not worked out for it.
        let isNew = changed != windowState.content
        if isNew {
            windowState.content = changed
        }
        showTempo(in: grid)
        // The markers of a selected clip are coloured by their distance to these beats.
        if isNew {
            correction.remeasureMarkers()
        }
    }

    private func showBeatProgress(_ progress: BeatFinder.Progress, search number: Int) {
        // Progress that arrives after the search has ended, or out of order, is dropped.
        guard number == beatSearchNumber, let shown = beatFinding, progress.fraction >= shown.fraction ?? 0 else { return }
        beatFinding = BeatFindingProgress(phaseName: progress.phase.name, fraction: progress.fraction)
    }

    /// What the finding of beats calls to say how far it has come. It is called from the
    /// working thread, so it is made here, outside the main actor.
    private nonisolated static func beatProgressReport(
        to model: BeatsModel,
        search number: Int
    ) -> @Sendable (BeatFinder.Progress) -> Void {
        { [weak model] progress in
            Task { @MainActor in
                model?.showBeatProgress(progress, search: number)
            }
        }
    }
}

extension BeatsModel {
    // MARK: A project opens

    /// A song or a project is about to be shown in place of what was open, and the store has not
    /// opened it yet. `cache` is what beat finding kept for the new song, or nil when its beats
    /// have to be found.
    func projectWillOpen(cache: BeatCache?) {
        // A search for the beats of the song that was open is not this song's.
        beatSearch?.cancel()
        beatSearchNumber += 1
        beatFinding = nil
        beatCache = cache
        beatlessCache = nil
    }

    /// The store has opened the project, and has fitted its beat lines from `cache` if there is
    /// one. Without it the beats are found, in `sound`, the song as it was just read.
    func projectOpened(cache: BeatCache?, sound: ImportedSong) {
        if cache == nil {
            // Beats that were saved are shown while they are found again.
            if let grid = store.project.grid {
                showBeats(of: grid)
            }
            findBeats(in: sound)
        } else if store.project.grid != nil {
            // The beats are known already, so a click file asked for at start can be written.
            click.writeLaunchClickFile()
            // And the stretch given with `-loop` can be looped on whole bars.
            loop.turnLaunchLoopOn()
        }
    }
}

extension AppModel {
    /// Gives `beats` its closures: it has none, because everything it calls it is handed.
    /// `wire()` calls it once, when every part is made.
    func wireBeats() {}
}

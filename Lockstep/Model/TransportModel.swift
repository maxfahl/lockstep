import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

/// The stretch of the song that the Play button of a take plays once, and the take that is
/// heard while it plays.
struct TakesStretch {
    /// The take that is heard in the place of the chosen take of its line. The project is not
    /// changed for it: only what the player is handed is (`followClips`).
    var takeID: UUID
    /// Where the stretch ends and the song stops, in song seconds.
    var end: Double
    /// Where the playhead stood before, and goes back to when the stretch is over.
    var returnTo: Double
    /// True when the stretch goes round until it is stopped, because Loop is on. The player
    /// then loops the take's stretch, and gets the loop of the Loop command back afterwards.
    var repeats = false
}

/// The take that is going: what the app keeps about it besides its place in the song.
/// Where it was started from, and how far it has come, is in `TakeStatus.flow`.
struct Take: Sendable {
    /// Tells this take from the one before and the one after. A restart (Record pressed
    /// during the take) goes on with the same take, so the number stays.
    let number: Int
    /// The project the take's files are written into.
    let package: ProjectPackage
    /// How the take is counted in: the place recording starts, the count-in before it
    /// and its clicks. Decided when Record is pressed and the same for every restart.
    let countIn: TakeCountIn
    /// What the player is handed for a take that is recorded slower (`countIn.slow`), and what gives it
    /// its own sound back afterwards. Nil for a take at full speed.
    var backing: SlowBacking?
    /// The moment on the Mac's clock the song was last started at for the take: by
    /// Record, and again by every restart. The place in the song of what is being
    /// recorded is worked out from it. Nil until the microphone is open and the song has
    /// been told to start.
    var songStartHostTime: UInt64?
    /// The place in the song that belongs to `songStartHostTime`, in song seconds, as the
    /// player gave it: the start of the count-in, below zero when the click counts in
    /// before the song.
    var songStartPosition = 0.0
}

/// The transport: a part of the app's model.
///
/// It holds playing and recording: Play and Stop, moving the playhead while the song plays,
/// Record with its count-in, starting a take over, Stop, turning what was recorded into clips, a
/// take's Play button, the red clip and the meter, and `-addTake` and `-recordTake`.
///
/// Playing: it tells the player what to do, one thing after the other (`Player.tell`), and reads
/// the player's answer when it is done (`readEngine`). While the song plays, the playhead is
/// moved once per display frame from the player's own position (`followPlayback`).
///
/// Recording: Record (`recordOrRestart`) aims at the beat nearest the playhead, remembers that
/// place and which track is selected, opens the microphone and counts in: the click counts the
/// bars chosen in the click menu (also before the start of the song), the song rises from
/// silence, and a louder click marks the place (`TakeCountIn`). `takeStatus.flow` keeps that place
/// and says how far the take has come (`takeStatus.phase`): running up, recording, finishing.
/// Stopping it (Play or Stop, the end of the song, Quit) turns the take into a clip with one
/// edit, "Record Clip" (`keep`). While a take is going nothing else may change the project or
/// move the song: `canPerform` on `AppModel` and the edit functions refuse.
///
/// Recording slower: with 90 or 85 % chosen in the click menu, the take is counted in and recorded
/// in slow time (`TakeCountIn.slow`) against the slow sound that `slowTake` hands the player, and is
/// sped up where it is looked at (`FinishedPasses.make`). What this part remembers of a take is song
/// time, and the player's position is read through `slowTake.songSeconds(ofPlayer:)`.
///
/// Restarting: Record pressed while a take is going starts it over. `restartTake` drops what was
/// recorded since the song was last started for the take and counts in again in the same way,
/// with the microphone left open. The dropped attempt is deleted, or kept as a clip of its own
/// when Settings says so.
///
/// While a take is recorded, the red clip on the track grows from `takeStatus.progress`, which
/// only that clip reads, so nothing else in the window is drawn again.
///
/// A take's Play button (`playOrStopTake`) plays the line once with the song and everything else,
/// with that take in the place of the active one, and then puts the playhead back
/// (`takesStretch`). The project is not changed by listening.
///
/// Sound devices: when headphones or a microphone are connected or disconnected during a take,
/// the take is stopped and kept, and a message says why (`audioDeviceChanged`). At any other time
/// the player moves to the new device by itself and nothing is said.
///
/// It is one class in three files. This one has the class, playing and a take's Play button.
/// Recording, restarting, stopping, what becomes of a recording, the red clip, the meter and
/// `-addTake` are in `TransportModel+Recording.swift`, and `-recordTake` is in
/// `TransportModel+RecordTake.swift`.
@MainActor
final class TransportModel {
    // The ground it is handed. Not `private`, because the part's other files use it too.
    let windowState: WindowState
    let selection: Selection
    let loadedSounds: LoadedSounds
    let takeStatus: TakeStatus
    let loopState: LoopState
    let player: Player
    let recorder: Recorder
    let store: ProjectStore
    let settings: AppSettings
    let playhead: PlayheadPosition
    let micLevel: MicLevelReading

    // The parts it is handed, and calls directly. Not `private`, for the same reason.
    let timelineView: TimelineViewModel
    let correction: CorrectionModel
    let words: WordsModel
    let volume: VolumeModel
    let takes: TakesModel
    let loop: LoopModel
    let clips: ClipsModel
    let beats: BeatsModel
    let slowTake: SlowTakeModel

    // What it asks of code that holds it, or of the model's routing. `wireTransport` sets them.
    /// Carries out a command the way the menu and the keyboard do (`perform(_:)`, the model's
    /// routing). Only `-recordTake` calls it, so that an agent's take goes through the same code as
    /// a key press.
    var perform: (AppCommand) -> Void = { _ in }

    /// Whether a command may act now (`canPerform(_:)`, the model's routing). Only `-recordTake`
    /// asks.
    var canPerform: (AppCommand) -> Bool = { _ in false }

    // MARK: What it keeps
    //
    // Not `private`, because the part's other files use it too.

    /// Lets the meter rise at once and fall slowly.
    var micLevelFollower = MicLevel()
    /// The stretch of the song that the Play button of a take is playing, with the take
    /// that is heard, or nil when the song is stopped or plays the usual way.
    var takesStretch: TakesStretch?
    /// The waveform of the take so far, from the record origin on, in the recorder's blocks.
    var takeLevels = WaveformLevels(minimums: [], maximums: [])
    /// The next block of the take's waveform to ask the recorder for. Nil until the
    /// song has reached the record origin.
    var takeNextBlock: Int?
    /// The take that is going: its project and when the song was started for it.
    var take: Take?
    /// Counts the takes, so the end of an earlier one can be told from the one going now.
    var takeNumber = 0
    /// True while Record has been pressed and the answer about the microphone is awaited.
    var isAskingForMicrophone = false
    /// True once the sound file given with `-addTake` was added, or could not be.
    var launchTakeTaken = false
    /// Keeps the model listening for changes of the Mac's sound devices.
    var deviceChangeWatch: (any NSObjectProtocol)?

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        loopState: LoopState,
        player: Player,
        recorder: Recorder,
        store: ProjectStore,
        settings: AppSettings,
        playhead: PlayheadPosition,
        micLevel: MicLevelReading,
        timelineView: TimelineViewModel,
        correction: CorrectionModel,
        words: WordsModel,
        volume: VolumeModel,
        takes: TakesModel,
        loop: LoopModel,
        clips: ClipsModel,
        beats: BeatsModel,
        slowTake: SlowTakeModel
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.loopState = loopState
        self.player = player
        self.recorder = recorder
        self.store = store
        self.settings = settings
        self.playhead = playhead
        self.micLevel = micLevel
        self.timelineView = timelineView
        self.correction = correction
        self.words = words
        self.volume = volume
        self.takes = takes
        self.loop = loop
        self.clips = clips
        self.beats = beats
        self.slowTake = slowTake
    }
}

extension TransportModel {
    // MARK: Playing

    /// Starts the song at the playhead, or stops it there.
    func playOrStop() {
        guard let song = loadedSounds.song else { return }
        // During a take, stopping the song ends the take.
        guard takeStatus.phase == nil else {
            stopTake()
            return
        }
        if takesStretch != nil {
            // Stopping the stretch of a take early ends it like its own end does.
            endTakesStretch()
        } else if windowState.content.isPlaying {
            windowState.content.isPlaying = false
            player.tell { await $0.stop() }
        } else {
            // At the very end there is nothing left to play, so Play starts over.
            let kept = store.project.keptSeconds
            let start = playhead.seconds >= kept.upperBound ? kept.lowerBound : playhead.seconds
            windowState.content.isPlaying = true
            player.tell { try await $0.play(from: start) }
            // Play pressed while the playhead is out of view: the timeline comes to it.
            timelineView.bringToMiddle(start, moving: true)
        }
    }

    /// Moves the playhead to a place in the song. While playing, the sound goes on from there.
    ///
    /// The timeline stays where it is: this is what a click and a drag in the ruler use, and
    /// the place under the pointer is in view, or the drag scrolls the timeline itself. A
    /// command that moves the playhead uses `jump(to:)`.
    ///
    /// - Returns: Whether the playhead was moved. During a take it is not.
    @discardableResult
    func seek(to seconds: Double) -> Bool {
        // A take is tied to the place the song is at, so the song cannot be moved under it.
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil else { return false }
        // Max moved the playhead himself, so it is not put back where it stood before
        // a take's Play: the song plays on from here the usual way.
        forgetTakesStretch()
        // The playhead stays on what is left of the song.
        let kept = store.project.keptSeconds
        let target = min(max(seconds, kept.lowerBound), kept.upperBound)
        playhead.seconds = target
        beats.showTempo(in: store.project.grid)
        player.tell { try await $0.seek(to: target) }
        return true
    }

    /// Moves the playhead as a command does: a key (the steps, Go Back, the jumps between
    /// clips) or `-playhead`. When the new place is outside what the timeline shows, the
    /// timeline glides so the playhead stands in the middle. This is not the following of
    /// the playhead while the song plays, so the setting for that does not turn it off.
    func jump(to seconds: Double) {
        guard seek(to: seconds) else { return }
        timelineView.bringToMiddle(playhead.seconds, moving: windowState.content.isPlaying)
    }

    /// Previous Screen (-1) and Next Screen (1): the playhead moves by the width the timeline
    /// shows, and the timeline glides by as much as the playhead moved, so the playhead keeps
    /// its place on screen. At the ends of what is kept of the song the playhead stops there,
    /// and the timeline at its limit. A playhead that was out of view is then brought in.
    func jumpScreen(by direction: Double) {
        let shown = timelineView.restingScale
        guard timelineView.timelineWidth > 0, shown.pointsPerSecond > 0 else { return }
        let before = playhead.seconds
        guard seek(to: before + direction * timelineView.timelineWidth / shown.pointsPerSecond) else { return }
        var moved = shown
        moved.scrollOffsetSeconds += playhead.seconds - before
        moved.clamp(range: timelineView.timelineRange, viewWidth: timelineView.timelineWidth)
        timelineView.glide(to: moved)
        timelineView.bringToMiddle(playhead.seconds, moving: windowState.content.isPlaying)
    }

    /// Brings the window in line with the player: where the playhead is, whether the
    /// button shows play or stop, and whether the playhead is moved on every frame.
    func readEngine() {
        let now = player.snapshot()
        showPosition(slowTake.songSeconds(ofPlayer: now.position))
        beats.showTempo(in: store.project.grid)
        if windowState.content.isPlaying != now.isPlaying {
            windowState.content.isPlaying = now.isPlaying
        }
        if now.isPlaying {
            player.frames.start()
        } else {
            player.frames.stop()
            // The stretch of a take ran into the end of the song, or could not be played.
            if takesStretch != nil {
                endTakesStretch()
            }
            // The song has played to its end during a take. That stops the take like Stop does.
            if take?.songStartHostTime != nil {
                stopTake()
            }
        }
    }

    /// Once per display frame while the song plays: moves the playhead to where the
    /// player is, lets the timeline follow it as Settings says, and notices the end
    /// of the song. Nothing else in the window changes here.
    func followPlayback() {
        // While the player is still doing what it was told (a jump, for example), its
        // position is the old one. The playhead already stands where it was sent.
        guard player.ordersInFlight == 0 else { return }
        let now = player.snapshot()
        guard now.isPlaying else {
            readEngine()
            return
        }
        let before = playhead.seconds
        // The player's place in the song. During a take recorded slower the player counts in slow
        // time, and this is the one place its position is read while the song plays.
        let playerPosition = slowTake.songSeconds(ofPlayer: now.position)
        showPosition(playerPosition)
        // Where the playhead stands: the player's place, or the start of the song while
        // the click still counts in before it.
        let position = playhead.seconds
        // The stretch that a take's Play button plays is over.
        if let stretch = takesStretch, position >= stretch.end {
            endTakesStretch()
            return
        }
        // A loop came round: the playhead jumped back to the loop's start. A loop is never
        // shorter than a quarter of a second, so a step back this large is the jump.
        if position < before - Self.loopJumpSeconds {
            loopCameRound(from: before, to: position)
        }
        // The count-in is over when the song reaches the place recording starts. This
        // asks the player's own position, which is below zero before the song: a take
        // at the very start of the song is not recording yet while the click counts in.
        if takeStatus.phase == .runningUp, let origin = takeStatus.flow.origin, playerPosition >= origin.seconds {
            takeStatus.flow.reach(playerPosition)
        }
        if takeStatus.phase == .recording, let origin = takeStatus.flow.origin {
            drawTake(from: origin.seconds, at: playerPosition)
        }
        if takeStatus.phase == .runningUp || takeStatus.phase == .recording {
            showMicLevel()
        }
        switch settings[.followPlayhead] {
        case .toTheMiddle: timelineView.followPlayheadOutOfView(from: before, to: position)
        case .smooth: timelineView.scrollUnderPlayhead(from: before, to: position)
        case .off: break
        }
        // The song moves on one second per second, so this is ten times a second at most.
        if abs(position - beats.tempoShownAt) >= BeatsModel.tempoStep {
            beats.showTempo(in: store.project.grid)
        }
    }

    /// How far back the playhead must step between two frames, in song seconds, for the step
    /// to be a loop coming round and not the player's position wavering by a hair.
    private static let loopJumpSeconds = 0.1

    /// The loop has come round and the playhead stands near its start again. If the
    /// timeline had moved on with the pass, it comes back to the playhead, unless
    /// following is turned off in Settings: this is the song playing, not a command.
    private func loopCameRound(from before: Double, to position: Double) {
        if settings[.followPlayhead] != .off {
            timelineView.followPlayheadOutOfView(from: before, to: position)
        }
        // While recording, the red clip starts again for the new time round.
        if takeStatus.phase == .recording {
            emptyTakeDrawing()
        }
    }

    /// Shows where the player is: the playhead and the time readout in the bar.
    ///
    /// A count-in that begins before the start of the song is reported by the player as a
    /// position before it: below zero, or before the start of what is left when the
    /// song's beginning is cut away. The playhead cannot stand before the song, so it
    /// waits at its start, and the time readout shows the time the count-in has reached,
    /// with a minus sign while that is before 00:00.
    func showPosition(_ position: Double) {
        let start = store.project.keptSeconds.lowerBound
        playhead.seconds = max(position, start)
        let beforeSong = max(start - position, 0)
        if playhead.secondsBeforeSong != beforeSong {
            playhead.secondsBeforeSong = beforeSong
        }
    }

    // MARK: The takes of a line

    /// Another take was just chosen. If a Play button is playing a take of the same line,
    /// the chosen take is the one heard from here on, and its row the one marked as playing.
    /// So clicking through the takes while the line goes round is heard at once, as it is
    /// while the song plays the usual way. Call it before the clips are handed to the player.
    func hearChosenTakes(_ chosen: some Sequence<UUID>) {
        guard let playing = takesStretch?.takeID else { return }
        for id in chosen where store.project.takes(of: id).contains(where: { $0.id == playing }) {
            takesStretch?.takeID = id
        }
    }

    /// The Play button of a take in the takes list: plays the line once, from the start of
    /// its takes to half a second after it (`TakeAudition`), with everything that is heard there
    /// (the song, the click as it is set and every other clip) and with this take in the
    /// place of the active one, tightened the way its own settings say. Then the song stops
    /// and the playhead goes back to where it stood. The project is not changed.
    ///
    /// Pressed on the take that is playing, it stops, like Play or Stop. Pressed on another
    /// take while one plays, that one is played from the start of the stretch, and the
    /// playhead still goes back to where it stood before the first of them.
    func playOrStopTake(_ number: Int) {
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil, let take = takes.take(numbered: number) else { return }
        if takesStretch?.takeID == take.id {
            endTakesStretch()
            return
        }
        guard let range = TakeAudition.stretch(ofLine: store.project.takes(of: take.id), in: store.project)
        else { return }
        let kept = store.project.keptSeconds
        let start = min(max(range.lowerBound, kept.lowerBound), kept.upperBound)
        let end = min(range.upperBound, kept.upperBound)
        guard end > start else { return }
        // With Loop on, the stretch goes round until it is stopped. The player loops the
        // take's stretch for as long.
        let round = loopState.region == nil
            ? nil
            : LoopRegion(from: start, to: end, songLengthSamples: store.project.songLengthSamples)
        takesStretch = TakesStretch(
            takeID: take.id,
            end: end,
            returnTo: takesStretch?.returnTo ?? playhead.seconds,
            repeats: round != nil
        )
        playhead.seconds = start
        timelineView.bringToMiddle(start, moving: true)
        beats.showTempo(in: store.project.grid)
        windowState.content.isPlaying = true
        // The player gets the clips with this take in its line before it starts, so not a
        // sample of the active take is heard.
        clips.followClips(of: store.project)
        player.tell { engine in
            if let round {
                await engine.setLoop(round)
            }
            try await engine.play(from: start)
        }
    }

    /// The stretch of a take is no longer what plays, though the song may play on: Max moved
    /// the playhead, or pressed Record. The player gets the clips as the project has them
    /// again, and a stretch that went round gives it the loop of the Loop command back.
    func forgetTakesStretch() {
        guard let stretch = takesStretch else { return }
        takesStretch = nil
        if stretch.repeats {
            let region = loopState.region
            player.tell { await $0.setLoop(region) }
        }
        clips.followClips(of: store.project)
    }

    /// The stretch of a take is over: it reached its end, was stopped early with the take's
    /// button or with Play or Stop, or ran into the end of the song. The song stops, the
    /// playhead goes back to where it stood before, and the player gets the clips as the
    /// project has them again.
    func endTakesStretch() {
        guard let stretch = takesStretch else { return }
        takesStretch = nil
        if windowState.content.isPlaying {
            windowState.content.isPlaying = false
        }
        let returnTo = stretch.returnTo
        playhead.seconds = returnTo
        timelineView.bringToMiddle(returnTo, moving: false)
        beats.showTempo(in: store.project.grid)
        // After a stretch that went round, the player gets the loop of the Loop command back.
        let repeated = stretch.repeats
        let region = loopState.region
        player.tell { engine in
            await engine.stop()
            if repeated {
                await engine.setLoop(region)
            }
            try await engine.seek(to: returnTo)
        }
        // After the song has stopped, so the active take is not heard for a moment at the end.
        clips.followClips(of: store.project)
    }
}

extension AppModel {
    /// Gives `transport` its closures. `wire()` calls it once, when every part is made.
    func wireTransport() {
        transport.perform = { [weak self] command in self?.perform(command) }
        transport.canPerform = { [weak self] command in self?.canPerform(command) ?? false }
    }
}

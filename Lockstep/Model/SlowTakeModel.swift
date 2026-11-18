import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

/// The song of the open project made slower, with the song as it is, for one recording speed.
struct SlowSong: Sendable {
    /// The project the song belongs to.
    let projectURL: URL
    /// The speed it was made for.
    let slow: SlowTime
    /// The song as it is: stereo, left and right in turn. The player gets it back after the take.
    let real: [Float]
    /// The song made longer by `1 / slow.rate` at the same pitch, in the same form.
    let slowed: [Float]
}

/// Everything the player is handed for one take that is recorded slower, gathered on the main thread
/// when Record is pressed, and what it needs to get its own sound back afterwards.
///
/// The player is not taught a speed. It gets a slowed song, a click laid out on the slowed beats, the
/// row of the other voices made slower as one sound, and the slowed loop, and plays them as it plays
/// anything: on the sample.
struct SlowBacking: Sendable {
    /// The speed of the take.
    let slow: SlowTime
    /// The slowed song, stereo.
    let song: [Float]
    /// The song as it is, for afterwards.
    let realSong: [Float]
    /// What is left of the slowed song after the project's cut, in its own samples.
    let kept: Range<Int>
    /// The click of the slowed project.
    let click: ClickLayout
    /// The project as it is heard when Record is pressed, in song time, with the sounds its clips play.
    let project: Project
    let recordings: [UUID: [Float]]
    let tightened: TightenedSounds
    /// Which voice stands in for which recording on which track, as heard when Record is pressed. Their
    /// samples are in `recordings`, so a track with a Voice is heard in it at the slow speed too.
    let voices: TrackVoices
    /// The setting `timing.edgeFadeMs`.
    let edgeFadeMs: Double
    /// The loop in slow time, or nil while Loop is off.
    let loop: LoopRegion?

    /// Lays the click and the row of voices out, and puts everything into the player. The song that was
    /// playing stops. What takes time here is the row: it is laid out as it is heard at full speed and
    /// then made slower as one sound (about half a second for a few minutes of song with voices in it).
    @concurrent
    func put(into engine: PlaybackEngine) async {
        async let clickSamples = click.samples()
        // The row as the player lays it out itself (`PlaybackEngine.setClips`): from where what is left of
        // the song starts, counted from the song's first sample.
        let whole = project.keptSamples
        let length = min(whole.upperBound, project.songLengthSamples)
        var plan = project.clipPlaybackPlan(
            from: whole.lowerBound, to: length, peaks: RecordingPeaks().lookup(in: recordings), tightened: tightened, voices: voices.having(recordings)
        )
        for index in plan.indices {
            plan[index].startDelay += whole.lowerBound
        }
        var row: [Float] = []
        if !plan.isEmpty {
            let heard = OfflineMix.render(
                plan, recordings: recordings, lengthSamples: length, fadeSamples: EdgeFade.samples(milliseconds: edgeFadeMs)
            )
            row = await SlowedBacking.slowed(heard, channels: 1, rate: slow.rate) ?? []
        }
        await engine.load(song: song)
        await engine.keepSong(kept)
        await engine.setClick(buffer: await clickSamples)
        await engine.setClips(row: row)
        await engine.setLoop(loop)
    }
}

/// Recording slower: a part of the app's model.
///
/// For a passage that is too fast to rap cleanly, the click menu's Record speed row chooses 90 or 85 %.
/// Only a take is slow then. Play and everything else stay at full tempo.
///
/// There is one seam. A slow take is run in "slow time" by the recording code as it is, on a slowed
/// copy of what it reads (`TakeCountIn`, which is handed the speed). The player is not taught a speed:
/// this part hands it sound that is already slow, and gives it its own sound back when the take ends.
/// Where the take is looked at (`FinishedPasses.make`), its sound is sped up and the recording and its
/// clip are moved to song time (`FinishedTake.atFullTempo`, at the end of this file). From there on
/// nothing knows about speed.
///
/// What it holds:
/// - The slowed song of the open project for the chosen speed (`followSpeed`). It is made in the
///   background as soon as a speed below 100 % is chosen or a project opens with one chosen, and
///   forgotten when another project opens or the speed goes back to 100 %. It is the whole song: the
///   cut is laid on it when it is handed to the player, so a changed cut needs no new one.
/// - What a take is handed (`backing`), putting it into the player before the take (`put`) and taking
///   it out after (`putBack`).
/// - Which time the player's position is in (`songSeconds(ofPlayer:)`): slow time from `put` to
///   `putBack`, song time otherwise. Everything that reads the player's position asks here.
@MainActor
final class SlowTakeModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let loadedSounds: LoadedSounds
    private let loopState: LoopState
    private let player: Player
    private let store: ProjectStore
    private let settings: AppSettings

    // The parts it is handed, and calls directly.
    private let click: ClickModel
    private let correction: CorrectionModel

    /// The slowed song that is ready, or nil.
    private var made: SlowSong?
    /// The making of a slowed song that is going on, with what it is made for.
    private var making: (projectURL: URL, slow: SlowTime, task: Task<SlowSong?, Never>)?
    /// The speed of the take the player holds the slow sound of, or nil while it holds its own sound.
    private(set) var playerSlow: SlowTime?
    /// True once the speed given with `-recordSpeed` was chosen.
    private var launchSpeedTaken = false

    /// What the window says while Record waits for the slow song.
    private static let makingMessage = "Making the slow song…"
    /// What the window says when a take is recorded at full speed although a slower one is chosen.
    static let notMadeMessage = "The slow song could not be made, so this take is recorded at full speed."

    init(
        windowState: WindowState,
        loadedSounds: LoadedSounds,
        loopState: LoopState,
        player: Player,
        store: ProjectStore,
        settings: AppSettings,
        click: ClickModel,
        correction: CorrectionModel
    ) {
        self.windowState = windowState
        self.loadedSounds = loadedSounds
        self.loopState = loopState
        self.player = player
        self.store = store
        self.settings = settings
        self.click = click
        self.correction = correction
    }

    // MARK: The slowed song

    /// The speed the next take is recorded at (`recording.speedPercent`).
    var speed: SlowTime { SlowTime(percent: settings[.recordSpeedPercent]) }

    /// Brings the slowed song in line with the chosen speed and the open project: makes it, in the
    /// background, when a slower speed is chosen and it is not there, and forgets it when it is for
    /// another speed or another project. Called when a speed is chosen and when a project has opened.
    func followSpeed() {
        let slow = speed
        guard slow.isSlow, loadedSounds.song != nil, let package = store.package else {
            making?.task.cancel()
            making = nil
            made = nil
            return
        }
        if let made, made.projectURL == package.url, made.slow == slow { return }
        if let making, making.projectURL == package.url, making.slow == slow { return }
        making?.task.cancel()
        made = nil
        let url = package.url
        let songFile = package.songFile(of: store.project)
        let task = Task { [weak self] in
            let song = await Self.slowSong(of: songFile, in: url, at: slow)
            self?.wasMade(song, for: url, at: slow)
            return song
        }
        making = (url, slow, task)
    }

    /// A slowed song is ready, or could not be made. It is kept if it is still the one wanted.
    private func wasMade(_ song: SlowSong?, for projectURL: URL, at slow: SlowTime) {
        guard let making, making.projectURL == projectURL, making.slow == slow else { return }
        self.making = nil
        made = song
    }

    /// Reads the project's song and makes it slower, away from the main thread. Nil when the song
    /// cannot be read or the work was given up.
    @concurrent
    private nonisolated static func slowSong(of songFile: URL, in projectURL: URL, at slow: SlowTime) async -> SlowSong? {
        guard let song = try? await SongImporter.importSong(from: songFile),
            let slowed = await SlowedBacking.slowed(song.samples, channels: 2, rate: slow.rate)
        else { return nil }
        return SlowSong(projectURL: projectURL, slow: slow, real: song.samples, slowed: slowed)
    }

    /// The slowed song for the take that Record is about to start, waited for if it is still being
    /// made. The window says "Making the slow song…" meanwhile.
    ///
    /// - Returns: nil at full speed, where a take needs none, and when the song could not be made.
    func slowedSong() async -> SlowSong? {
        followSpeed()
        if let made { return made }
        guard let making else { return nil }
        windowState.content.message = Self.makingMessage
        let song = await making.task.value
        if windowState.content.message == Self.makingMessage {
            windowState.content.message = nil
        }
        // The speed or the project may have changed while it was made.
        guard let song, let package = store.package, song.projectURL == package.url, song.slow == speed else { return nil }
        return song
    }

    // MARK: What a take is handed

    /// What the player is handed for a slow take that starts now: the slowed song, and the click, the
    /// other voices, the cut and the loop of the project as it is at this moment.
    ///
    /// - Parameter loop: the loop the take goes round in, in slow time (`TakeCountIn.loop`), or nil.
    func backing(with song: SlowSong, loop: LoopRegion?) -> SlowBacking {
        let project = store.project
        // The voices as they are heard: tightened where Lines or All is chosen.
        let heard = correction.tightenedClips(of: ProjectLookup(project))
        let slowed = song.slow.slowed(project)
        return SlowBacking(
            slow: song.slow,
            song: song.slowed,
            realSong: song.real,
            kept: slowed.keptSamples,
            click: ClickLayout(slowed, accentBeatOne: settings[.accentBeatOne]),
            project: project,
            recordings: heard.recordings,
            tightened: heard.tightened,
            voices: heard.voices,
            edgeFadeMs: settings[.edgeFadeMs],
            loop: loop
        )
    }

    /// Puts the slow sound of a take into the player. From here until `putBack` the player's position
    /// is slow time. Call it in the player's line (`Player.takeTurn`), in the turn that starts the take.
    func put(_ backing: SlowBacking) async {
        // Said before the sound is in: a click that is laid out meanwhile for the real song then waits
        // (`ClickModel.followClick`) and cannot land on the slowed one.
        playerSlow = backing.slow
        await backing.put(into: player.engine)
    }

    /// Gives the player its own sound back after a slow take: the real song with its cut, the loop and
    /// the click, at the place the take stopped, in song time. Call it in the player's line, when the
    /// song has stopped. The clips are handed over by the code that ends the take, once it is over.
    func putBack(_ backing: SlowBacking) async {
        guard playerSlow != nil else { return }
        let engine = player.engine
        let stoppedAt = backing.slow.songSeconds(forSlow: engine.snapshot().position)
        let kept = store.project.keptSamples
        let loop = loopState.region
        await engine.load(song: backing.realSong)
        await engine.keepSong(kept)
        await engine.setLoop(loop)
        try? await engine.seek(to: stoppedAt)
        playerSlow = nil
        // The click went with the slowed song.
        click.hearClickAgain()
    }

    /// Where the player is in the song, in song seconds, for a position it gave. This is the one
    /// place that knows the player's position is slow time during a slow take.
    func songSeconds(ofPlayer position: Double) -> Double {
        playerSlow?.songSeconds(forSlow: position) ?? position
    }
}

extension SlowTakeModel {
    // MARK: A project opens

    /// A song or a project has been put in the window in place of what was open: the slowed song of
    /// the project before is not this one's.
    func projectOpened() {
        followSpeed()
    }

    /// Chooses the recording speed given with `-recordSpeed`, through the same code as the Record speed
    /// row of the click menu, and says so on standard error. Only the first project opened gets it.
    func setLaunchSpeed() {
        guard !launchSpeedTaken, let percent = LaunchOptions.current.recordSpeed else { return }
        launchSpeedTaken = true
        click.chooseRecordSpeed(percent)
        Agent.tell("set the recording speed to \(settings[.recordSpeedPercent]) %")
    }
}

// MARK: - The finished take at full tempo

extension FinishedTake {
    /// A take that was recorded slower and has just been looked at, as it goes into the project: its
    /// sound sped up to the song's tempo with the consonants kept (`SpedUpTake`), and its recording and
    /// its clip moved to song time (`SpeedUpPlan.atFullTempo`). The waveform, the loudness and the
    /// voice's curve are made again from the sped-up sound, which is what everything shows, plays and
    /// corrects, and the sped-up sound is kept in the project's `cache/sped-up/`. The file in `takes/`
    /// stays the slow original.
    ///
    /// A take at full speed, and one that was thrown away, come back as they are.
    @concurrent
    func atFullTempo(recordedAt slow: SlowTime, in package: ProjectPackage) async -> FinishedTake {
        guard slow.isSlow, let slowClip = clipSamples else { return self }
        let made = SpedUpTake.make(from: samples, rate: slow.rate)
        let mapped = made.plan.atFullTempo(recording, clip: slowClip)
        let clip = mapped.clip.map { $0.clamped(to: 0..<made.samples.count) } ?? 0..<0
        var fast = self
        fast.recording = mapped.recording
        fast.samples = made.samples
        guard !clip.isEmpty else {
            // Nothing is left of the clip at full tempo, so the take goes like one that is too short.
            try? FileManager.default.removeItem(at: package.url.appendingPathComponent(recording.file))
            fast.clipSamples = nil
            return fast
        }
        fast.clipSamples = clip
        fast.waveform = WaveformPyramid(interleaved: made.samples, channelCount: 1)
        fast.loudness = Loudness.integrated(Array(made.samples[clip]))
        // Both can be made again from the take's file, so a failed write is not an error. The curve
        // that was written when the take was looked at is the slow sound's.
        try? VoiceEnvelope.envelope(of: made.samples).write(forRecording: recording.id, to: package)
        try? SpedUpTake.write(made.samples, forRecording: recording.id, to: package)
        return fast
    }
}

extension AppModel {
    /// Gives `slowTake` its closures: it has none, because everything it calls it is handed.
    /// `wire()` calls it once, when every part is made.
    func wireSlowTake() {}
}

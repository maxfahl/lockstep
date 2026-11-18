import Accelerate
import AVFoundation
import LockstepCore
import os
import Synchronization

/// What the window needs to know about playback at one moment.
public struct PlaybackSnapshot: Sendable, Equatable {
    /// The place in the song, in song seconds. While stopped it is the last place.
    public var position: Double
    /// Whether the song is playing.
    public var isPlaying: Bool
    /// The length of the loaded song in seconds, or zero when no song is loaded.
    public var duration: Double

    public init(position: Double = 0, isPlaying: Bool = false, duration: Double = 0) {
        self.position = position
        self.isPlaying = isPlaying
        self.duration = duration
    }
}

/// Plays the song through the Mac's sound output and knows the exact place in it.
///
/// Everything that changes playback (`load`, `play`, `stop`, `seek`) is `async` and runs away from the main thread.
/// `snapshot()`, `position` and `isPlaying` answer at once from any thread, so the window can ask on every display
/// frame and keep the answer in its own main-actor state.
///
/// The click plays beside the song from a player of its own. It is handed over as one row of samples as long as the
/// song (`setClick(buffer:)`), and both players are always started together, from the same sample of the song at the
/// same moment, so the click cannot slide against the song. `setClickEnabled` and `setClickVolume` act at once.
///
/// The clips play beside the song in the same way, from a third player: `setClips(of:recordings:)` lays all the
/// clips that are heard out as one row of samples as long as the song, each at its own volume. So two hundred clips cost the same while
/// playing as one, and a changed clip is a new row that takes the place of the old one while the song plays on.
/// The new row is a copy of the old one with only the stretches that changed laid out again, so an edit costs
/// the same in a project of twenty tracks as in one of two (`OfflineMix.rowChange`).
/// A clip that has a finished sound is laid out from that sound, and the row is then two, left and right.
public actor PlaybackEngine {
    /// How far ahead of "now" `play(from:)` asks the sound to start, in seconds. It is long enough for the Mac to
    /// start the sound on the exact sample, and short enough that jumping while playing leaves no gap you can hear.
    public static let startLead: Double = 0.02

    /// The audio engine and everything read from it. The lock lets the window read the position from the main thread
    /// while this actor works on another one.
    private nonisolated let graph: Mutex<Graph>
    /// The last answer given, for the rare frame when the engine is busy and cannot be asked.
    private nonisolated let latest: Mutex<PlaybackSnapshot>
    /// Counts every start and stop, so a "the song has ended" message from an earlier start can be told apart.
    private var run = 0
    /// How many times playback was moved to a new sound device.
    var deviceChangesFollowed = 0
    /// Counts the sounds played once, so the end of an earlier one can be told apart.
    private var soundsPlayedOnce = 0
    /// What the row of clips in the engine was made of. A call of `setClips` that would make the same row again
    /// is known by it and does nothing.
    private var clipPieces: [ClipPiece] = []
    /// The length of the fade at clip edges that the row of clips in the engine was made with, in samples.
    private var clipFadeSamples = 0
    /// How many rows of clips were made from the row before them, and not from nothing. Tests read it.
    var clipRowsMadeFromTheRowBefore = 0
    /// Where the engine says how long it took to take changed clips over: the Mac's log, beside the lines
    /// the app writes for every edit.
    private static let handoverLog = Logger(subsystem: "se.maxfahl.lockstep", category: "EditTiming")
    /// The clicks of the count-in that was played last, and what they were made from.
    private var countInClicks: (made: CountInClicks, sound: ClickStorage?)?
    /// How high the stretches of recordings that clips play peak, for the safe limit on each clip's volume.
    /// Each stretch is measured the first time it is asked for and remembered from then on.
    private let clipPeaks = RecordingPeaks()

    /// - Parameter silent: when true nothing can be heard, and everything else, the position included, works the same.
    public init(silent: Bool = false) {
        graph = Mutex(Graph(silent: silent))
        latest = Mutex(PlaybackSnapshot())
        watchForDeviceChanges()
    }

    /// An engine that is not connected to any sound device. It produces sound only when `renderOffline(frames:)` asks
    /// for it, so tests can run the real engine without anything reaching the speakers.
    init(offlineWithMaximumFrames maximumFrames: Int, silent: Bool = false) throws {
        graph = Mutex(try Graph(offlineWithMaximumFrames: AVAudioFrameCount(maximumFrames), silent: silent))
        latest = Mutex(PlaybackSnapshot())
        watchForDeviceChanges()
    }

    deinit {
        graph.withLock { graph in
            if let observer = graph.observer {
                NotificationCenter.default.removeObserver(observer)
            }
            graph.player.stop()
            graph.clickPlayer.stop()
            graph.clipPlayer.stop()
            graph.countInPlayer.stop()
            graph.oncePlayer.stop()
            graph.engine.stop()
        }
    }

    // MARK: Reading

    /// The position, play state and length right now. Safe to call from any thread, and it never waits.
    public nonisolated func snapshot() -> PlaybackSnapshot {
        guard let fresh = graph.withLockIfAvailable({ $0.read() }) else {
            return latest.withLock { $0 }
        }
        latest.withLock { $0 = fresh }
        return fresh
    }

    /// The place in the song, in song seconds. While stopped it is the last place.
    public nonisolated var position: Double { snapshot().position }

    /// Whether the song is playing.
    public nonisolated var isPlaying: Bool { snapshot().isPlaying }

    // MARK: Controlling

    /// Takes a song as stereo samples at 48,000 Hz, left and right in turn, and puts the position at its start.
    /// Playback stops first. The click and the clips of the song before are forgotten.
    public func load(song samples: [Float]) {
        run += 1
        let song = SongStorage(interleavedStereo: samples)
        clipPieces = []
        graph.withLock { $0.load(song) }
        publish()
    }

    /// Leaves a stretch of the loaded song to be played, when its beginning or its end is cut away
    /// (`Project.keptSamples`), or gives the whole song back with the whole range.
    ///
    /// Before the stretch the song is silent, so a count-in that runs before the new start is heard as one
    /// before the start of the song is: the click alone. The song ends where the stretch ends: playback
    /// stops there, `snapshot().duration` is that place, and no position lies after it. Positions stay
    /// song seconds, counted from the first sample of the whole song.
    ///
    /// The click and the loop are kept. Hand the clips over again afterwards (`setClips`), which lays them
    /// out for what is left. While the song plays, all players start again from where the song is, as a
    /// jump does. Calling it with the stretch that is already kept does nothing.
    public func keepSong(_ kept: Range<Int>) {
        guard let whole = graph.withLock({ $0.wholeSong }) else { return }
        let end = min(max(kept.upperBound, 0), whole.length)
        let range = min(max(kept.lowerBound, 0), end)..<end
        guard range != graph.withLock({ $0.keptRange }) else { return }
        // Copying a song takes a few thousandths of a second, so it is done before the lock is taken.
        let song = range == 0..<whole.length ? whole : SongStorage(keeping: range, of: whole)
        let wasPlaying = graph.withLock { $0.keep(song, range) }
        if wasPlaying {
            startAgainInStep()
        }
        publish()
    }

    /// Starts playing from a place in the song, almost at once.
    public func play(from seconds: Double) throws {
        try graph.withLock { try $0.wake() }
        try start(from: seconds, atHostTime: AudioBlocks.hostTime(in: Self.startLead))
    }

    /// Starts playing from a place in the song at an exact moment on the Mac's clock (a host time).
    ///
    /// Every start goes through here. Later phases start the click and the clips against the same moment, which is
    /// what keeps them together to the sample.
    public func start(from seconds: Double, atHostTime hostTime: UInt64) throws {
        run += 1
        let onEnd = AudioBlocks.songEnded(tell: self, run: run)
        defer { publish() }
        try graph.withLock { try $0.start(from: seconds, atHostTime: hostTime, onEnd: onEnd) }
    }

    /// Stops playing. The position stays where the sound stopped.
    public func stop() {
        run += 1
        graph.withLock { $0.stop() }
        publish()
    }

    /// Moves to a place in the song. While playing, the sound continues from there.
    public func seek(to seconds: Double) throws {
        if graph.withLock({ $0.playing }) {
            try play(from: seconds)
        } else {
            graph.withLock { $0.rest(at: seconds) }
            publish()
        }
    }

    // MARK: The click

    /// How far ahead a new click, or a new row of clips, takes the place of the old one while the song plays, in
    /// samples (85 ms). It is longer than the longest block of sound the Mac asks for at a time, so the new sound is
    /// always in place before its first sample is due.
    static let swapLead = 4_096

    /// Takes the click for the loaded song: mono samples at 48,000 Hz, as long as the song, starting at song time
    /// zero (what `ClickRenderer.render` gives). An empty row means no click.
    ///
    /// While the song plays, the new click takes over within a tenth of a second and the song is not touched.
    /// Loading another song forgets the click.
    public func setClick(buffer samples: [Float]) {
        let click = ClickStorage(samples)
        let inStep = graph.withLock { $0.setClick(click) }
        if !inStep {
            startAgainInStep()
        }
    }

    // MARK: Looping

    /// Switches Loop on for a stretch of the song, or off with nil.
    ///
    /// With Loop on, playback that reaches the end of the region goes on from its start, on the exact sample:
    /// the song, the click and the clips all come round together, pass after pass, and `position` goes round
    /// with them. Playback that starts before the region plays into it and then loops. Playback that starts
    /// after it, or a jump there, plays on to the end of the song. A take's count-in leads into the loop the
    /// same way (`start(countingIn:...)`).
    ///
    /// A new click or new clips handed over while a loop plays take over without the loop losing its step.
    ///
    /// Switched while the song plays, the change is made by starting all players again from where the song
    /// is, as a jump does. Loading another song forgets the loop.
    public func setLoop(_ region: LoopRegion?) {
        let restarts: Bool = graph.withLock { graph in
            guard graph.loop != region else { return false }
            graph.loop = region
            guard graph.playing else { return false }
            // Only playback that goes round now, or would from where it is, has anything to change.
            let position = PlaybackPosition.sample(forSeconds: graph.read().position, lengthSamples: graph.lengthSamples)
            return graph.runLoop != graph.loop(reachedFrom: position)
        }
        if restarts {
            startAgainInStep()
        }
    }

    /// A player beside the song could not say where it is (the sound has only just been asked to start), so its new
    /// sound cannot be put in step by itself. All players start again together from where the song is.
    private func startAgainInStep() {
        let seconds = graph.withLock { $0.read().position }
        try? play(from: seconds)
    }

    // MARK: The clips

    /// Takes the clips to play with the loaded song. This one call is all the engine needs to know about clips.
    ///
    /// Call it after `load(song:)` when a project opens, and again after every change to the project that can
    /// change what is heard of the clips: a new recording, a deleted, muted, moved, cut or joined clip, a muted
    /// track, an undo or a redo. Calling it after a change that leaves the clips as they were costs almost nothing.
    ///
    /// What is heard is decided by `Project.clipPlaybackPlan(from:to:)`: every clip that is not muted, on a track
    /// that is not muted, each at its place in the song. Of several takes of the same line only the active one
    /// plays (`Clip.isActiveTake`), so choosing another take is a change to hand over here like any other.
    ///
    /// Every clip is played with its volume: what Normalize set plus what Max set, held back when needed so the
    /// clip's highest sample stays at or below -1 dBFS (`Clip.appliedGain`), plus each segment's own. The volume
    /// of its track (`Track.gainDb`) comes on top of that for every clip of the track. The engine measures the
    /// peaks it needs from `recordings` itself. A changed volume, of a clip or of a track, is a change like any
    /// other: hand the clips over again, and it is heard within a tenth of a second, while the song plays on.
    ///
    /// Every segment of a clip gets a short fade at its start and at its end (`EdgeFade`), so a clip that was cut
    /// in the middle of a sound does not click. The fade is put on the row of samples made here. The recordings
    /// are only read. A changed fade length is a change like any other: hand the clips over again with it.
    ///
    /// While the song plays, the new clips take over within a tenth of a second and the song plays on untouched.
    /// While stopped, the next start plays them. Starting and jumping always start the clips on the same sample as
    /// the song. Loading another song forgets the clips.
    ///
    /// How long a call takes does not grow with the project: the row the engine has is copied and only what
    /// changed is laid out again, to the very samples a row made from nothing would hold. One line in the Mac's
    /// log says how long each handover took and how the row was made (subsystem `se.maxfahl.lockstep`,
    /// category `EditTiming`).
    ///
    /// - Parameters:
    ///   - project: the project as it is now. Only its tracks, clips and recordings are read.
    ///   - recordings: the sound of the recordings, by recording id: mono samples at 48,000 Hz, sample 0 first
    ///     (what `RecordingLoader` reads from `takes/<id>.wav`, or what the recorder kept in memory). The lists
    ///     are only read, never copied whole, so handing over all of them every time is cheap. A recording that
    ///     is missing here is silent.
    ///   - tightened: the tightened sounds to play in place of segments on tracks with Tighten lines on (see
    ///     `TightenedSounds`). Their samples are in `recordings` under their own ids. Left out, every clip is
    ///     heard as it was recorded, which is what Before plays. Handing the clips over with another lookup
    ///     is a change like any other, and that is all Before and After is to the engine.
    ///   - finished: the finished sounds to play in place of whole clips (see `FinishedSounds`): a clip's
    ///     sound with its track's Sound and its effects, in stereo, with what rings after the clip. Such a
    ///     clip is as loud as its sound and its track's volume say. Left out, every clip is played from its
    ///     segments, as before a clip could have a finished sound. A finished sound that was made again has
    ///     a new id, so handing it over is a change like any other.
    ///   - finishedSamples: the samples of the finished sounds, by their ids. They are only read. A
    ///     finished sound whose samples are not here counts as none, and its clip is played dry.
    ///   - edgeFadeMs: how long the fade at every segment edge is, in milliseconds: the setting
    ///     `timing.edgeFadeMs`. 0 is no fade. Left out, it is what that setting starts as.
    ///   - crossfadeMs: how long the clips that were heard fade into the new ones when the song is playing,
    ///     in milliseconds. 0, which it is when left out, changes from one sample to the next, as it always
    ///     did. Before and After asks for 10: the same voice a few hundredths of a second apart would
    ///     otherwise click where the two meet. The fade begins where the change would have been, so the
    ///     new sound is all that is heard that many milliseconds later.
    ///   - voices: which made voice stands in for which recording on which track (see `TrackVoices`). Their
    ///     samples are in `recordings` under their own ids. A voice whose samples are not there counts as
    ///     not made, and its recording is heard: a plan that named it would leave its clip silent. `.none`:
    ///     every clip is heard in Max's own voice.
    public func setClips(
        of project: Project,
        recordings: [UUID: [Float]],
        tightened: TightenedSounds = .none,
        finished: FinishedSounds = .none,
        finishedSamples: [UUID: StereoSound] = [:],
        edgeFadeMs: Double = SettingKey<Double>.edgeFadeMs.defaultValue,
        crossfadeMs: Double = 0,
        voices: TrackVoices
    ) {
        let started = ContinuousClock.now
        let length = graph.withLock { $0.lengthSamples }
        // Where the song's beginning is cut away no clip is heard either, so the plan starts where what is
        // left starts, and its pieces are counted from the song's first sample again.
        let from = min(max(project.keptSamples.lowerBound, 0), length)
        var plan = project.clipPlaybackPlan(
            from: from, to: length, peaks: clipPeaks.lookup(in: recordings), tightened: tightened,
            finished: finished.having(finishedSamples), voices: voices.having(recordings)
        )
        for index in plan.indices {
            plan[index].startDelay += from
        }
        let pieces = OfflineMix.playable(plan, recordings: recordings, finished: finishedSamples, lengthSamples: length)
        let fadeSamples = EdgeFade.samples(milliseconds: edgeFadeMs)
        // With no clips there is nothing a fade could change.
        guard pieces != clipPieces || (fadeSamples != clipFadeSamples && !pieces.isEmpty) else { return }
        // After an edit nearly all of the row the engine has is still right, so the new row is a copy of it
        // in which only the stretches that changed are laid again. In a project of twenty tracks that is a
        // few thousandths of a second, where mixing every clip of every track again took about forty. The row
        // the engine has is the one made of `clipPieces` whenever that list is not empty.
        var clips: ClipStorage?
        var how = "made from nothing"
        if !clipPieces.isEmpty, let before = graph.withLock({ $0.clips }), before.length == length,
           case .layAgain(let stretches) = OfflineMix.rowChange(
               from: clipPieces, fadeSamples: clipFadeSamples, to: pieces, fadeSamples: fadeSamples, lengthSamples: length
           )
        {
            clips = ClipStorage(
                pieces, after: before, layingAgain: stretches,
                recordings: recordings, finished: finishedSamples, fadeSamples: fadeSamples
            )
            let seconds = Double(stretches.reduce(0) { $0 + $1.count }) / Lockstep.sampleRate
            how = "made from the row before, \(stretches.count) stretches of \(String(format: "%.1f", seconds)) s laid again"
        }
        if clips != nil {
            clipRowsMadeFromTheRowBefore += 1
        } else {
            clips = ClipStorage(
                pieces, recordings: recordings, finished: finishedSamples, lengthSamples: length, fadeSamples: fadeSamples
            )
        }
        clipPieces = pieces
        clipFadeSamples = fadeSamples
        let crossfadeSamples = EdgeFade.samples(milliseconds: crossfadeMs)
        let inStep = graph.withLock { $0.setClips(clips, crossfadeSamples: crossfadeSamples) }
        // The app notes "player has the clips" on the main thread, which is busy drawing the edit just then,
        // so that mark says more about the window than about the player. This line is the player's own time,
        // from being told to the row being handed to the Mac's player.
        let took = (ContinuousClock.now - started).components
        let milliseconds = Double(took.seconds) * 1_000 + Double(took.attoseconds) / 1e15
        Self.handoverLog.info(
            "Player took the clips over in \(String(format: "%.1f", milliseconds), privacy: .public) ms: \(pieces.count, privacy: .public) pieces, row \(clips == nil ? "empty" : how, privacy: .public)"
        )
        if !inStep {
            startAgainInStep()
        }
    }

    /// Takes the row of clips ready-made: mono samples at 48,000 Hz, starting at the loaded song's first sample.
    ///
    /// A take that is recorded slower uses it (`SlowedBacking`). The song in the engine is then the slowed
    /// one, and the clips that are heard with it cannot be laid out from the project, whose clips are in song
    /// time: the row is laid out as it is heard, made slower as one sound, and handed over here. It takes the
    /// place of the clips the engine had, like any change of the clips.
    ///
    /// The row is made exactly as long as the loaded song: a longer one is cut off there, a shorter one is
    /// silent to the end. An empty row means no clips. The next `setClips(of:recordings:...)` always lays its
    /// clips out again, whatever it was last handed.
    public func setClips(row samples: [Float]) {
        clipPieces = []
        clipFadeSamples = 0
        let clips = ClipStorage(row: samples, lengthSamples: graph.withLock { $0.lengthSamples })
        let inStep = graph.withLock { $0.setClips(clips) }
        if !inStep {
            startAgainInStep()
        }
    }

    /// Turns the click on or off, at once. While off, the click still runs in step with the song, without sound.
    public nonisolated func setClickEnabled(_ enabled: Bool) {
        graph.withLock {
            $0.clickEnabled = enabled
            $0.applyClickLevel()
        }
    }

    /// Sets how loud the click is, from 0 (silent) to 1 (the samples as they are), at once.
    public nonisolated func setClickVolume(_ volume: Float) {
        graph.withLock {
            $0.clickVolume = min(max(volume, 0), 1)
            $0.applyClickLevel()
        }
    }

    /// Sets how loud the song is, from 0 (silent) to 1 (its samples as they are), at once and also while it plays.
    /// Only the song follows it: the click, the clips and a count-in keep their own levels. It stays until it is
    /// set again, also when another song is loaded.
    public nonisolated func setSongVolume(_ volume: Float) {
        graph.withLock { $0.player.volume = min(max(volume, 0), 1) }
    }

    /// Plays a short sound once, right away, whether the song plays or not: the click sound that was just chosen, so
    /// it can be heard without starting the song. The place in the song is not touched. A sound that is still being
    /// played this way is cut off by the next one.
    ///
    /// - Parameters:
    ///   - samples: mono samples at 48,000 Hz.
    ///   - volume: from 0 (silent) to 1 (the samples as they are).
    public func playOnce(_ samples: [Float], volume: Float) throws {
        guard let sound = ClickStorage(samples) else { return }
        soundsPlayedOnce += 1
        let onEnd = AudioBlocks.soundPlayedOnceEnded(tell: self, number: soundsPlayedOnce)
        try graph.withLock { try $0.playOnce(sound, volume: min(max(volume, 0), 1), onEnd: onEnd) }
    }

    // MARK: Messages from the system

    /// The sound numbered `finished` that was played once has ended. When the song is not playing, the audio engine
    /// can rest again.
    fileprivate func soundPlayedOnceEnded(number finished: Int) {
        guard finished == soundsPlayedOnce else { return }
        graph.withLock { $0.restAfterPlayingOnce() }
    }

    /// The player has played the last sample of the start numbered `finished`.
    fileprivate func songEnded(run finished: Int) {
        guard finished == run else { return }
        run += 1
        graph.withLock { $0.finishAtEnd() }
        publish()
    }

    /// The sound device changed (headphones plugged in, AirPods connected). Continues on the new device from the
    /// same place.
    fileprivate func followDeviceChange() {
        run += 1
        let onEnd = AudioBlocks.songEnded(tell: self, run: run)
        graph.withLock { $0.followDeviceChange(onEnd: onEnd) }
        deviceChangesFollowed += 1
        publish()
    }

    private nonisolated func watchForDeviceChanges() {
        let block = AudioBlocks.deviceChanged(tell: self)
        graph.withLock { graph in
            graph.observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: graph.engine,
                queue: nil,
                using: block
            )
        }
    }

    private func publish() {
        let fresh = graph.withLock { $0.read() }
        latest.withLock { $0 = fresh }
    }

    // MARK: For tests

    /// Produces the next `frames` samples of sound, as the Mac's output would have received them.
    /// Works only on an engine made with `init(offlineWithMaximumFrames:silent:)`.
    func renderOffline(frames: Int) throws -> (left: [Float], right: [Float]) {
        defer { publish() }
        return try graph.withLock { try $0.renderOffline(frames: frames) }
    }

    /// Whether the audio engine is awake. It rests while nothing plays.
    var engineIsAwake: Bool {
        graph.withLock { $0.engine.isRunning }
    }

    /// Sends the message the system sends when the sound device changes.
    func announceDeviceChange() {
        graph.withLock { graph in
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: graph.engine)
        }
    }
}

/// The offline engine could not produce sound.
struct OfflineRenderingFailed: Error {}

// MARK: - Blocks the system calls

/// Every block that is handed to the system is made here.
///
/// The system calls these on threads of its own. A block written inside the actor would be checked against the
/// actor's thread when it runs and would crash the app. So each one is made in a function that belongs to no actor,
/// is `@Sendable`, and holds only things that are safe to use from any thread. All it does is pass the message on.
private enum AudioBlocks {
    /// For the player: the sound it was given has been played to its end, or was thrown away by a stop.
    nonisolated static func songEnded(
        tell engine: PlaybackEngine,
        run: Int
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak engine] _ in
            guard let engine else { return }
            Task { await engine.songEnded(run: run) }
        }
    }

    /// For the player of single sounds: the sound it was given has been played to its end, or was cut off.
    nonisolated static func soundPlayedOnceEnded(
        tell engine: PlaybackEngine,
        number: Int
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak engine] _ in
            guard let engine else { return }
            Task { await engine.soundPlayedOnceEnded(number: number) }
        }
    }

    /// For the notification centre: the sound device changed and the audio engine has stopped itself.
    nonisolated static func deviceChanged(tell engine: PlaybackEngine) -> @Sendable (Notification) -> Void {
        { [weak engine] _ in
            guard let engine else { return }
            Task { await engine.followDeviceChange() }
        }
    }

    /// For a buffer that points into the song's or the click's memory: keeps that memory alive until the player has
    /// let go of the buffer. (The list it is called with belongs to the buffer and is not ours to free.)
    nonisolated static func release(keeping storage: any PlayableStorage) -> @Sendable (UnsafePointer<AudioBufferList>) -> Void {
        { _ in
            withExtendedLifetime(storage) {}
        }
    }

    /// The song, or the click, from `startSample` to its end, as a buffer a player can be given. No sound is copied.
    ///
    /// - Parameter endSample: one past the last sample to play. Left out, the sound is played to its end.
    nonisolated static func buffer(
        of storage: any PlayableStorage,
        from startSample: Int,
        to endSample: Int? = nil,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frames = min(endSample ?? storage.length, storage.length) - startSample
        let byteCount = frames * MemoryLayout<Float>.size
        guard startSample >= 0, frames > 0, byteCount <= Int(UInt32.max) else { return nil }
        // The buffer copies this small description of where the two sides are, so it is only needed for the call.
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(byteCount), mData: storage.left + startSample)
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(byteCount), mData: storage.right + startSample)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: list.unsafePointer,
            deallocator: release(keeping: storage)
        )
        buffer?.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// Samples `startSample` up to `endSample` of a sound, as a buffer of exactly that many samples. Every
    /// player in a loop is handed its stretches this way: the song, the click and the clips must each come
    /// round after exactly as many samples as the loop is long, or they would slide against each other.
    ///
    /// The sound is normally as long as the song and nothing is copied. A sound that ends before `endSample`
    /// is copied and filled up with silence.
    nonisolated static func stretch(
        of storage: any PlayableStorage,
        from startSample: Int,
        to endSample: Int,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frames = endSample - startSample
        guard startSample >= 0, frames > 0 else { return nil }
        if endSample <= storage.length {
            return buffer(of: storage, from: startSample, to: endSample, format: format)
        }
        guard let padded = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let sides = padded.floatChannelData
        else { return nil }
        padded.frameLength = AVAudioFrameCount(frames)
        let there = max(storage.length - startSample, 0)
        for (side, source) in [storage.left, storage.right].enumerated() {
            vDSP_vclr(sides[side], 1, vDSP_Length(frames))
            if there > 0 {
                sides[side].update(from: source + startSample, count: there)
            }
        }
        return padded
    }

    /// A copy of a stretch of the song, the click or the clips whose level rises evenly, sample by sample: the
    /// first sample is multiplied by `firstLevel` and each one after it by `step` more. The song fading up during
    /// a count-in is made of these, so its level is right on every sample and does not move in steps.
    nonisolated static func rising(
        _ storage: any PlayableStorage,
        from startSample: Int,
        count: Int,
        firstLevel: Double,
        step: Double,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard startSample >= 0, count > 0, startSample + count <= storage.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let sides = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        // The levels are counted up with more digits than the sound has, so that the last one of a long rise is
        // where it should be and the full level that follows is no jump.
        var first = firstLevel
        var step = step
        var exact = [Double](repeating: 0, count: count)
        vDSP_vrampD(&first, &step, &exact, 1, vDSP_Length(count))
        var levels = [Float](repeating: 0, count: count)
        vDSP_vdpsp(exact, 1, &levels, 1, vDSP_Length(count))
        vDSP_vmul(storage.left + startSample, 1, levels, 1, sides[0], 1, vDSP_Length(count))
        vDSP_vmul(storage.right + startSample, 1, levels, 1, sides[1], 1, vDSP_Length(count))
        return buffer
    }

    /// A stretch in which one sound fades out while another fades in, evenly, sample by sample: `count` samples
    /// from `startSample` of both. Either may be nil, which is silence. Played between the old row of clips and
    /// the new one, it is what makes a change of the clips a crossfade and not a cut.
    ///
    /// The two levels always add up to 1, and they are read in the middle of each sample, as the fades at clip
    /// edges are. So where the old and the new sound are the same, as they are for every clip the change does
    /// not touch, what comes out is that sound, unchanged but for the last digit.
    nonisolated static func crossfade(
        from old: (any PlayableStorage)?,
        to new: (any PlayableStorage)?,
        from startSample: Int,
        count: Int,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frames = min(count, old.map { $0.length - startSample } ?? count, new.map { $0.length - startSample } ?? count)
        guard startSample >= 0, frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let sides = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        // The level of the new sound on each sample. It is measured against the length asked for, so a fade
        // that the end of the song cuts short does not speed up.
        var first = 0.5 / Float(count)
        var step = 1 / Float(count)
        var rising = [Float](repeating: 0, count: frames)
        vDSP_vramp(&first, &step, &rising, 1, vDSP_Length(frames))
        var falling = [Float](repeating: 0, count: frames)
        var minusOne: Float = -1
        var one: Float = 1
        vDSP_vsmsa(rising, 1, &minusOne, &one, &falling, 1, vDSP_Length(frames))
        for side in 0..<2 {
            let out = sides[side]
            vDSP_vclr(out, 1, vDSP_Length(frames))
            if let old {
                vDSP_vma((side == 0 ? old.left : old.right) + startSample, 1, falling, 1, out, 1, out, 1, vDSP_Length(frames))
            }
            if let new {
                vDSP_vma((side == 0 ? new.left : new.right) + startSample, 1, rising, 1, out, 1, out, 1, vDSP_Length(frames))
            }
        }
        return buffer
    }

    /// One sample of silence. Handing it to the click player in place of what it plays is how the click is taken
    /// away while the song goes on.
    nonisolated static func silence(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1), let sides = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = 1
        for side in 0..<Int(format.channelCount) {
            sides[side][0] = 0
        }
        return buffer
    }

    /// A moment on the Mac's clock that lies `seconds` from now.
    nonisolated static func hostTime(in seconds: Double) -> UInt64 {
        mach_absolute_time() + AVAudioTime.hostTime(forSeconds: seconds)
    }

    /// How many seconds ago a moment on the Mac's clock was. Negative when it has not come yet.
    nonisolated static func secondsSince(hostTime: UInt64) -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: hostTime)
    }
}

// MARK: - The song in memory

/// The song's samples, left and right apart, as the player wants them. Never changed after it is made, which is what
/// makes it safe to read from the system's audio thread while the app does other things.
private final class SongStorage: PlayableStorage, @unchecked Sendable {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    /// The length in samples for one side.
    let length: Int

    /// - Parameter samples: left and right in turn. Returns nil when there is not a single whole sample.
    init?(interleavedStereo samples: [Float]) {
        let length = samples.count / 2
        guard length > 0 else { return nil }
        let left = UnsafeMutablePointer<Float>.allocate(capacity: length)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: length)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            base.withMemoryRebound(to: DSPComplex.self, capacity: length) { pairs in
                var sides = DSPSplitComplex(realp: left, imagp: right)
                vDSP_ctoz(pairs, 2, &sides, 1, vDSP_Length(length))
            }
        }
        self.left = left
        self.right = right
        self.length = length
    }

    /// What is left of a song whose beginning or end is cut away: silent before `range`, the song's own
    /// samples inside it, and ending where it ends. The samples keep their places, so a position in it is a
    /// position in the whole song.
    init(keeping range: Range<Int>, of whole: SongStorage) {
        let length = range.upperBound
        let left = UnsafeMutablePointer<Float>.allocate(capacity: max(length, 1))
        let right = UnsafeMutablePointer<Float>.allocate(capacity: max(length, 1))
        for (side, source) in [(left, whole.left), (right, whole.right)] {
            side.initialize(repeating: 0, count: range.lowerBound)
            (side + range.lowerBound).initialize(from: source + range.lowerBound, count: range.count)
        }
        self.left = left
        self.right = right
        self.length = length
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }
}

/// Sound kept in memory in the form a player takes it: one row of samples for the left side and one for the right.
private protocol PlayableStorage: AnyObject, Sendable {
    var left: UnsafeMutablePointer<Float> { get }
    var right: UnsafeMutablePointer<Float> { get }
    /// The length in samples for one side.
    var length: Int { get }
}

/// The click's samples. Never changed after it is made, like the song's. A changed click is a new one of these.
///
/// The click is mono: there is one row of samples, and the left and the right side both point at it. So the click
/// comes out the same on both sides, exactly as loud as its samples say.
private final class ClickStorage: PlayableStorage, @unchecked Sendable {
    let samples: UnsafeMutablePointer<Float>
    let length: Int
    var left: UnsafeMutablePointer<Float> { samples }
    var right: UnsafeMutablePointer<Float> { samples }

    /// Returns nil for an empty row, which means "no click".
    init?(_ mono: [Float]) {
        guard !mono.isEmpty else { return nil }
        samples = UnsafeMutablePointer<Float>.allocate(capacity: mono.count)
        samples.initialize(from: mono, count: mono.count)
        length = mono.count
    }

    deinit {
        samples.deallocate()
    }
}

/// Every clip that is heard, laid out as one row of samples as long as the song, each clip at its place and the
/// rest silence. Where clips lie on top of each other their samples are added. Never changed after it is made, like
/// the song's samples. Changed clips are a new one of these.
///
/// It is mono, like the click, unless a clip is played from its finished sound: the left and the right side both
/// point at the one row, so the voice comes out the same on both sides. With a finished piece among the pieces
/// there are two rows, and each finished sound's left and right go to their own side, while every other clip is
/// laid into both. Each piece is as loud as the plan says (`ClipPiece.gainDb`): at 0 dB, exactly as loud as its
/// samples say. The rows are laid out by `OfflineMix` of `LockstepCore`, which the export uses too.
private final class ClipStorage: PlayableStorage, @unchecked Sendable {
    let left: UnsafeMutablePointer<Float>
    /// The same row as `left` when no piece is a finished one.
    let right: UnsafeMutablePointer<Float>
    let length: Int

    /// - Parameters:
    ///   - pieces: what `OfflineMix.playable` gave for a plan of the whole song (from sample 0).
    ///   - finished: the samples of the finished sounds the finished pieces name.
    ///   - fadeSamples: the length of the fade at every segment edge, in samples.
    ///
    /// Returns nil when there is nothing to hear, which means "no clips".
    init?(
        _ pieces: [ClipPiece],
        recordings: [UUID: [Float]],
        finished: [UUID: StereoSound],
        lengthSamples: Int,
        fadeSamples: Int
    ) {
        guard !pieces.isEmpty, lengthSamples > 0 else { return nil }
        // The row is made this way for the first clips and whenever most of it changed, also while the song plays,
        // and the change must be heard within 100 ms, of which `swapLead` takes 85. So the row is asked for as memory
        // that is already silent, which costs next to nothing. Writing a zero into every sample of a song of
        // three and a half minutes took 8 to 10 ms in a Debug build.
        guard let silence = calloc(lengthSamples, MemoryLayout<Float>.stride) else { return nil }
        let row = silence.bindMemory(to: Float.self, capacity: lengthSamples)
        // The one function that turns clips into sound, so what is played and what is later exported are the
        // same samples. It sets each piece at its place, at its volume and faded at the edges of its segment.
        if pieces.contains(where: \.isFinished) {
            // A second row only now: a project without finished sounds costs what it always did.
            guard let other = calloc(lengthSamples, MemoryLayout<Float>.stride) else {
                free(silence)
                return nil
            }
            let second = other.bindMemory(to: Float.self, capacity: lengthSamples)
            OfflineMix.add(
                pieces,
                recordings: recordings,
                finished: finished,
                toLeft: UnsafeMutableBufferPointer(start: row, count: lengthSamples),
                right: UnsafeMutableBufferPointer(start: second, count: lengthSamples),
                fadeSamples: fadeSamples
            )
            right = second
        } else {
            OfflineMix.add(
                pieces,
                recordings: recordings,
                to: UnsafeMutableBufferPointer(start: row, count: lengthSamples),
                fadeSamples: fadeSamples
            )
            right = row
        }
        left = row
        length = lengthSamples
    }

    /// The row of `pieces`, made from the row before it: a copy of that row in which only `stretches` are laid
    /// again. It holds the very samples the row made from nothing holds (`OfflineMix.rowChange`, which also
    /// gives the stretches), and is as long as the row before.
    ///
    /// The row before is only read: the player may still be playing it. With a finished piece among the
    /// pieces there are two rows, as when made from nothing, and both sides of a row that was one are copies
    /// of it. With none, one row is enough again: no finished sound is left outside the stretches, so there
    /// the two sides were alike.
    ///
    /// Returns nil when there is no memory for the copy. The row can then still be made from nothing.
    init?(
        _ pieces: [ClipPiece],
        after before: ClipStorage,
        layingAgain stretches: [Range<Int>],
        recordings: [UUID: [Float]],
        finished: [UUID: StereoSound],
        fadeSamples: Int
    ) {
        let count = before.length
        guard !pieces.isEmpty, count > 0, let copy = malloc(count * MemoryLayout<Float>.stride) else { return nil }
        let row = copy.bindMemory(to: Float.self, capacity: count)
        row.update(from: before.left, count: count)
        if pieces.contains(where: \.isFinished) {
            guard let other = malloc(count * MemoryLayout<Float>.stride) else {
                free(copy)
                return nil
            }
            let second = other.bindMemory(to: Float.self, capacity: count)
            second.update(from: before.right, count: count)
            OfflineMix.layAgain(
                stretches,
                of: pieces,
                recordings: recordings,
                finished: finished,
                toLeft: UnsafeMutableBufferPointer(start: row, count: count),
                right: UnsafeMutableBufferPointer(start: second, count: count),
                fadeSamples: fadeSamples
            )
            right = second
        } else {
            OfflineMix.layAgain(
                stretches,
                of: pieces,
                recordings: recordings,
                to: UnsafeMutableBufferPointer(start: row, count: count),
                fadeSamples: fadeSamples
            )
            right = row
        }
        left = row
        length = count
    }

    /// A row that is already laid out, copied and made `lengthSamples` long. Returns nil for an empty row or
    /// a song without length, which means "no clips".
    init?(row: [Float], lengthSamples: Int) {
        guard !row.isEmpty, lengthSamples > 0 else { return nil }
        // Asked for as silence, like the row above, so what a shorter row leaves is silent.
        guard let silence = calloc(lengthSamples, MemoryLayout<Float>.stride) else { return nil }
        let copied = silence.bindMemory(to: Float.self, capacity: lengthSamples)
        row.withUnsafeBufferPointer { source in
            guard let first = source.baseAddress else { return }
            copied.update(from: first, count: min(row.count, lengthSamples))
        }
        left = copied
        right = copied
        length = lengthSamples
    }

    deinit {
        if right != left {
            free(right)
        }
        free(left)
    }
}

// MARK: - The audio engine

/// The audio engine with its players, one for the song, one for the click and one for the clips, and what is known
/// about the current playback. Only ever touched while holding the lock it is stored in.
private struct Graph {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    /// Plays the click. It is started and stopped only together with `player`, so both count their samples from the
    /// same sample of the song.
    let clickPlayer = AVAudioPlayerNode()
    /// Plays the clips, all of them as one row of samples. Started and stopped only together with `player`, like
    /// the click player.
    let clipPlayer = AVAudioPlayerNode()
    /// Plays the clicks of a take's count-in. They are heard also when the click is switched off and before the
    /// song starts, so they cannot come from the click player. Started only together with `player`.
    let countInPlayer = AVAudioPlayerNode()
    /// Plays one short sound at a time, apart from the song: the click sound that was just chosen.
    let oncePlayer = AVAudioPlayerNode()
    /// 48,000 Hz, stereo, 32-bit float: the format of everything inside the app.
    let format: AVAudioFormat
    var observer: (any NSObjectProtocol)?
    /// What is played of the loaded song: all of it, or what is left when its beginning or end is cut away.
    var song: SongStorage?
    /// The loaded song as it was loaded, which a cut is made from and taken back to.
    var wholeSong: SongStorage?
    /// The samples of `wholeSong` that `song` plays.
    var keptRange: Range<Int> = 0..<0
    /// The click of the loaded song, or nil when there is none.
    var click: ClickStorage?
    /// The clips of the loaded song as one row of samples, or nil when no clip is heard.
    var clips: ClipStorage?
    var clickEnabled = false
    var clickVolume: Float = 1
    var playing = false
    /// The sample of the song where the current playback started. The player counts from there, after the part
    /// before the song if there is one (`leadInSamples`).
    var runStartSample = 0
    /// The length of the part before the song in the current playback, in samples: how long the players count
    /// before the song's sample `runStartSample` comes out. Zero unless a count-in began before the song.
    var leadInSamples = 0
    /// The players' count of samples at which the song and the clips have risen to full level in the current
    /// playback. Zero unless it began with a count-in.
    var fadeEndSample: Int64 = 0
    /// The players' count of samples from which the click player plays the song's click again in the current
    /// playback: the end of the count-in's click to start on. Zero unless it began with a count-in.
    var clickHeldUntil: Int64 = 0
    /// The moment on the Mac's clock when the current playback was asked to start.
    var runStartHostTime: UInt64 = 0
    /// The last position worked out. It is the position while stopped.
    var lastSeconds: Double = 0
    /// The stretch of the song that repeats while Loop is on, or nil while it is off. Every start reads it.
    var loop: LoopRegion?
    /// The loop the current playback goes round in, or nil when it plays straight on to the end of the
    /// song: Loop is off, or playback started after the region.
    var runLoop: LoopRegion?

    /// An engine that plays through the Mac's current sound output.
    init(silent: Bool) {
        format = Self.songFormat()
        connect(silent: silent)
    }

    /// An engine with no sound device, which produces sound only when asked.
    init(offlineWithMaximumFrames maximumFrames: AVAudioFrameCount, silent: Bool) throws {
        format = Self.songFormat()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrames)
        connect(silent: silent)
    }

    private static func songFormat() -> AVAudioFormat {
        // Cannot fail for a plain sample rate and two channels.
        AVAudioFormat(standardFormatWithSampleRate: Lockstep.sampleRate, channels: 2)!
    }

    private func connect(silent: Bool) {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.attach(clickPlayer)
        engine.connect(clickPlayer, to: engine.mainMixerNode, format: format)
        engine.attach(clipPlayer)
        engine.connect(clipPlayer, to: engine.mainMixerNode, format: format)
        engine.attach(countInPlayer)
        engine.connect(countInPlayer, to: engine.mainMixerNode, format: format)
        engine.attach(oncePlayer)
        engine.connect(oncePlayer, to: engine.mainMixerNode, format: format)
        applyClickLevel()
        setSilent(silent)
    }

    var lengthSamples: Int { song?.length ?? 0 }

    // MARK: Reading

    mutating func read() -> PlaybackSnapshot {
        if playing, let seconds = playingSeconds() {
            lastSeconds = seconds
        }
        return PlaybackSnapshot(
            position: lastSeconds,
            isPlaying: playing,
            duration: PlaybackPosition.seconds(forSample: lengthSamples)
        )
    }

    /// The position taken from the player's own count of played samples, or nil when the player cannot say (the
    /// engine is not running, or has not produced any sound since the start).
    func playingSeconds() -> Double? {
        guard engine.isRunning,
              let report = player.lastRenderTime, report.isSampleTimeValid,
              let played = player.playerTime(forNodeTime: report), played.isSampleTimeValid
        else { return nil }
        return PlaybackPosition.seconds(
            runStartSample: runStartSample,
            leadInSamples: leadInSamples,
            playerSample: played.sampleTime,
            secondsSinceReport: report.isHostTimeValid ? AudioBlocks.secondsSince(hostTime: report.hostTime) : 0,
            lengthSamples: lengthSamples,
            loop: runLoop
        )
    }

    /// The sample of the song that the players play when their count of samples is `count`: straight on from
    /// where playback started, and round the loop once its end has been reached.
    func songSample(atCount count: Int64) -> Int {
        let played = Int(count) - leadInSamples
        return runLoop?.songSample(afterPlaying: played, from: runStartSample) ?? runStartSample + played
    }

    /// The loop that playback starting at `startSample` goes round in, or nil when it plays straight on.
    func loop(reachedFrom startSample: Int) -> LoopRegion? {
        loop.flatMap { $0.isReached(from: startSample) && $0.endSample <= lengthSamples ? $0 : nil }
    }

    /// Hands a player a sound to play from a sample of the song on: to the end of the song, or, in a loop,
    /// to the end of the region and then the region again and again. Every start and every change of a
    /// sound while playing goes through here, so all players come round on the same sample.
    ///
    /// - Parameters:
    ///   - time: the player's count of samples at which `songSample` is due, or nil for a player that is
    ///     about to be started and plays it first.
    ///   - options: `.interrupts` when the sound takes the place of what the player has.
    ///   - onEnd: called when the sound has been played to the end of the song. A loop has no end.
    /// - Returns: false when there is nothing of the sound left to play from there.
    @discardableResult
    func scheduleRest(
        of sound: any PlayableStorage,
        on node: AVAudioPlayerNode,
        from songSample: Int,
        at time: AVAudioTime?,
        options: AVAudioPlayerNodeBufferOptions = [],
        onEnd: (@Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void)? = nil
    ) -> Bool {
        if let runLoop, songSample < runLoop.endSample {
            guard let first = AudioBlocks.stretch(of: sound, from: songSample, to: runLoop.endSample, format: format),
                  let round = AudioBlocks.stretch(
                      of: sound, from: runLoop.startSample, to: runLoop.endSample, format: format
                  )
            else { return false }
            node.scheduleBuffer(first, at: time, options: options, completionHandler: nil)
            // The region itself follows, and the player repeats it by itself, on the exact sample, until it
            // is stopped or handed something else. It is given its own count to start on, unless the player
            // is only about to start: handed over "after what is there", it could be put after a sound that
            // the first piece is meant to replace.
            let roundTime = time.map {
                AVAudioTime(sampleTime: $0.sampleTime + Int64(first.frameLength), atRate: Lockstep.sampleRate)
            }
            node.scheduleBuffer(round, at: roundTime, options: .loops, completionHandler: nil)
            return true
        }
        guard let rest = AudioBlocks.buffer(of: sound, from: songSample, format: format) else { return false }
        if let onEnd {
            node.scheduleBuffer(
                rest,
                at: time,
                options: options,
                completionCallbackType: engine.isInManualRenderingMode ? .dataRendered : .dataPlayedBack,
                completionHandler: onEnd
            )
        } else {
            node.scheduleBuffer(rest, at: time, options: options, completionHandler: nil)
        }
        return true
    }

    // MARK: Controlling

    mutating func load(_ newSong: SongStorage?) {
        halt()
        song = newSong
        wholeSong = newSong
        keptRange = 0..<(newSong?.length ?? 0)
        // The click and the clips belonged to the song that was loaded before.
        click = nil
        clips = nil
        lastSeconds = 0
        // And so did the loop.
        loop = nil
        runLoop = nil
    }

    /// Puts what is left of the song in place of what was played of it.
    ///
    /// - Returns: true when the song is playing. The players still hold the sound that was there, so the
    ///   caller starts them again from where the song is. While stopped, the place to rest at is held
    ///   inside what is left.
    mutating func keep(_ kept: SongStorage, _ range: Range<Int>) -> Bool {
        if playing, let seconds = playingSeconds() {
            lastSeconds = seconds
        }
        song = kept
        keptRange = range
        if !playing {
            rest(at: lastSeconds)
        }
        return playing
    }

    /// Starts the audio engine if it is resting.
    func wake() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    mutating func start(
        from seconds: Double,
        atHostTime hostTime: UInt64,
        onEnd: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) throws {
        player.stop()
        clickPlayer.stop()
        clipPlayer.stop()
        countInPlayer.stop()
        playing = false
        // Ordinary playback has no count-in. One that was being played is over.
        leadInSamples = 0
        fadeEndSample = 0
        clickHeldUntil = 0
        let startSample = PlaybackPosition.sample(forSeconds: seconds, lengthSamples: lengthSamples)
        lastSeconds = PlaybackPosition.seconds(forSample: startSample)
        runLoop = nil
        guard let song, startSample < song.length else {
            // No song, or asked to start at the very end: there is nothing to play, so the engine can rest.
            engine.pause()
            return
        }
        try wake()
        // An engine without a sound device has no clock to wait for. It starts with the next sample it is asked for.
        let offline = engine.isInManualRenderingMode
        // With Loop on, playback that starts before the end of the region goes round in it.
        runLoop = loop(reachedFrom: startSample)
        scheduleRest(of: song, on: player, from: startSample, at: nil, onEnd: onEnd)
        if let click {
            scheduleRest(of: click, on: clickPlayer, from: startSample, at: nil)
        }
        if let clips {
            scheduleRest(of: clips, on: clipPlayer, from: startSample, at: nil)
        }
        // All three players are told the same moment, so the song, the click and the clips leave on the same
        // sample. The click player and the clip player start even with nothing to play: a click, or clips, that
        // arrive later are then placed on their count of samples.
        let moment = offline ? nil : AVAudioTime(hostTime: hostTime)
        player.play(at: moment)
        clickPlayer.play(at: moment)
        clipPlayer.play(at: moment)
        playing = true
        runStartSample = startSample
        runStartHostTime = hostTime
    }

    mutating func stop() {
        if playing, let seconds = playingSeconds() {
            lastSeconds = seconds
        }
        // Stopped in the part before the song, the place to rest at is the start of the song: of what is left
        // of it, when its beginning is cut away.
        lastSeconds = max(lastSeconds, PlaybackPosition.seconds(forSample: keptRange.lowerBound))
        halt()
    }

    mutating func rest(at seconds: Double) {
        lastSeconds = PlaybackPosition.seconds(
            forSample: PlaybackPosition.sample(forSeconds: seconds, lengthSamples: lengthSamples)
        )
    }

    mutating func finishAtEnd() {
        halt()
        lastSeconds = PlaybackPosition.seconds(forSample: lengthSamples)
    }

    /// Silences the player and lets the audio engine rest, so the Mac's sound output is not kept busy (and the Mac
    /// awake) while nothing plays.
    private mutating func halt() {
        player.stop()
        clickPlayer.stop()
        clipPlayer.stop()
        countInPlayer.stop()
        // A single sound that is cut short here must not sound its rest when the engine wakes up again.
        oncePlayer.stop()
        playing = false
        engine.pause()
    }

    // MARK: The click

    /// The click is as loud as its volume says while it is on, and silent while it is off.
    func applyClickLevel() {
        clickPlayer.volume = clickEnabled ? clickVolume : 0
    }

    /// Puts another click in place of the one that was there. While stopped, the next start plays it.
    ///
    /// - Returns: false when the song is playing and the new click could not be put in step (see `swap`).
    mutating func setClick(_ newClick: ClickStorage?) -> Bool {
        click = newClick
        return swap(to: newClick, on: clickPlayer)
    }

    /// Puts another row of clips in place of the one that was there. While stopped, the next start plays it.
    ///
    /// - Parameter crossfadeSamples: over how many samples the row that was there fades into the new one
    ///   while the song plays. 0 changes from one sample to the next.
    /// - Returns: false when the song is playing and the new clips could not be put in step (see `swap`).
    mutating func setClips(_ newClips: ClipStorage?, crossfadeSamples: Int = 0) -> Bool {
        let oldClips = clips
        clips = newClips
        return swap(to: newClips, on: clipPlayer, fadingFrom: oldClips, over: crossfadeSamples)
    }

    /// Hands one of the players beside the song (the click's or the clips') other sound while the song plays.
    ///
    /// The player goes on counting and is handed the new sound from a sample a little ahead (`swapLead`), to play
    /// when its count reaches that sample. The song player is not touched. While stopped there is nothing to do.
    ///
    /// With a crossfade (`fadeSamples` above 0), the player is handed two things for that sample: first a short
    /// stretch in which the sound it had fades out and the new one fades in, and then the new sound from the
    /// end of that stretch. A change during a count-in, while the clips are still rising with the song, is
    /// made without a crossfade.
    ///
    /// - Parameters:
    ///   - sound: as long as the song and starting at song time zero, or nil for silence.
    ///   - old: the sound the player was handed before, for the crossfade. Only read when `fadeSamples` is
    ///     above 0.
    /// - Returns: false when the song is playing and the player cannot say which sample it is at. The new sound
    ///   is then not in place, and all players must be started again.
    private func swap(
        to sound: (any PlayableStorage)?,
        on beside: AVAudioPlayerNode,
        fadingFrom old: (any PlayableStorage)? = nil,
        over fadeSamples: Int = 0
    ) -> Bool {
        guard playing else { return true }
        guard let count = samplesCounted(by: beside) else { return false }
        // The player's count is negative while it still waits for its moment to start. In the part before the
        // song there is nothing of the song's to play yet.
        var swapAt = max(count + Int64(PlaybackEngine.swapLead), Int64(leadInSamples))
        if let handedOver = swapDuringCountIn(to: sound, on: beside, at: swapAt) {
            return handedOver
        }
        var songSample = songSample(atCount: swapAt)
        // A crossfade that would run over the end of the loop waits for the start of the next pass, a few
        // thousandths of a second later: half of it before the jump and half after would be a click.
        if fadeSamples > 0, let runLoop, songSample < runLoop.endSample, songSample + fadeSamples > runLoop.endSample {
            swapAt += Int64(runLoop.endSample - songSample)
            songSample = runLoop.startSample
        }
        if fadeSamples > 0, let blend = AudioBlocks.crossfade(
            from: old, to: sound, from: songSample, count: fadeSamples, format: format
        ) {
            beside.scheduleBuffer(
                blend,
                at: AVAudioTime(sampleTime: swapAt, atRate: Lockstep.sampleRate),
                options: .interrupts,
                completionHandler: nil
            )
            // The new sound follows from where the crossfade ends. It is given its own count to start on:
            // handed over "after what is there", it would be put after the sound it replaces, which is
            // thrown away when the crossfade starts. With no new sound, silence follows by itself.
            let faded = Int(blend.frameLength)
            if let sound {
                scheduleRest(
                    of: sound,
                    on: beside,
                    from: songSample + faded,
                    at: AVAudioTime(sampleTime: swapAt + Int64(faded), atRate: Lockstep.sampleRate)
                )
            }
            return true
        }
        let time = AVAudioTime(sampleTime: swapAt, atRate: Lockstep.sampleRate)
        if let sound, scheduleRest(of: sound, on: beside, from: songSample, at: time, options: .interrupts) {
            return true
        }
        // No sound, or none left from there on: silence takes the place of what the player has.
        guard let silence = AudioBlocks.silence(format: format) else { return false }
        beside.scheduleBuffer(silence, at: time, options: .interrupts, completionHandler: nil)
        return true
    }

    /// How many samples a player has counted since it was told to play, or nil when it cannot say.
    private func samplesCounted(by node: AVAudioPlayerNode) -> Int64? {
        if engine.isRunning,
           let report = node.lastRenderTime, report.isSampleTimeValid,
           let played = node.playerTime(forNodeTime: report), played.isSampleTimeValid {
            return played.sampleTime
        }
        // A player cannot say right after it was started, before any sound has come out. Ordinary playback is
        // then started again from where it is. A count-in cannot be: it would begin anew, or the song would
        // start early and the take would be placed wrong. While the clock says the count-in is still under way,
        // the player has only just started and its count is taken as zero.
        let countInSamples = max(clickHeldUntil, fadeEndSample, Int64(leadInSamples))
        guard countInSamples > 0 else { return nil }
        let sinceStart = AudioBlocks.secondsSince(hostTime: runStartHostTime)
        return sinceStart < Double(countInSamples) / Lockstep.sampleRate ? 0 : nil
    }

    mutating func followDeviceChange(onEnd: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void) {
        guard playing else { return }
        // The engine has normally stopped itself by now and the player cannot be asked, so the clock gives the place.
        // The part before the song, if there was one, went by before the song's own first sample.
        let sinceSongStart = AudioBlocks.secondsSince(hostTime: runStartHostTime)
            - Double(leadInSamples) / Lockstep.sampleRate
        // In a loop the clock's answer goes round like the sound did.
        let estimated = runLoop.map {
            $0.songSeconds(forStraight: PlaybackPosition.seconds(forSample: runStartSample) + max(sinceSongStart, 0))
        } ?? PlaybackPosition.estimatedSeconds(
            runStartSample: runStartSample,
            secondsSinceStart: sinceSongStart,
            lengthSamples: lengthSamples
        )
        let seconds = playingSeconds() ?? estimated
        do {
            try wake()
            try start(from: seconds, atHostTime: AudioBlocks.hostTime(in: PlaybackEngine.startLead), onEnd: onEnd)
        } catch {
            // No usable sound device right now: stay stopped at the place that was reached.
            halt()
            lastSeconds = seconds
        }
    }

    // MARK: A single sound

    /// Plays a sound once from its start, through the same output as the song, so silence silences it too.
    func playOnce(
        _ sound: ClickStorage,
        volume: Float,
        onEnd: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) throws {
        oncePlayer.stop()
        guard let buffer = AudioBlocks.buffer(of: sound, from: 0, format: format) else { return }
        // While the song is stopped the engine rests, so it is woken for the length of the sound.
        try wake()
        oncePlayer.volume = volume
        oncePlayer.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: engine.isInManualRenderingMode ? .dataRendered : .dataPlayedBack,
            completionHandler: onEnd
        )
        oncePlayer.play()
    }

    /// The single sound has ended. With the song stopped, nothing is left to play and the engine rests again.
    func restAfterPlayingOnce() {
        oncePlayer.stop()
        if !playing {
            engine.pause()
        }
    }

    // MARK: For tests

    func renderOffline(frames: Int) throws -> (left: [Float], right: [Float]) {
        guard engine.isInManualRenderingMode, engine.isRunning,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: engine.manualRenderingFormat,
                  frameCapacity: engine.manualRenderingMaximumFrameCount
              )
        else { throw OfflineRenderingFailed() }
        var left: [Float] = []
        var right: [Float] = []
        while left.count < frames {
            let wanted = min(AVAudioFrameCount(frames - left.count), buffer.frameCapacity)
            let status = try engine.renderOffline(wanted, to: buffer)
            guard status == .success, buffer.frameLength > 0, let sides = buffer.floatChannelData else {
                throw OfflineRenderingFailed()
            }
            let produced = Int(buffer.frameLength)
            left.append(contentsOf: UnsafeBufferPointer(start: sides[0], count: produced))
            right.append(contentsOf: UnsafeBufferPointer(start: sides[1], count: produced))
        }
        return (left, right)
    }
}

// MARK: - A take's count-in

/// What the sound of a count-in's clicks was made from. The same again needs no new sound.
private struct CountInClicks: Equatable {
    var countIn: CountIn
    var sound: ClickSound
    var division: ClickDivision
    var subBeats: SubBeatGrid
    var accentBeatOne: Bool
    var volume: Float
}

extension PlaybackEngine {
    /// Starts a take: plays the count-in and then the song, at an exact moment on the Mac's clock (a host time).
    /// Ordinary playback (`play`, `start(from:atHostTime:)`, `seek`) has no count-in and is not changed by this.
    ///
    /// - The clicks of the count-in are heard at the click's volume also when the click is switched off. From
    ///   the place recording starts, the song's own click is heard again if the switch says so. The place itself
    ///   gets the higher, louder click to start on, and the song's click waits the 60 ms that it sounds.
    /// - The song and the clips rise from silence to full level over the first half of the count-in, evenly,
    ///   sample by sample (`CountIn.songLevel(atSample:)`). The click is not faded.
    /// - A count-in that begins before the song: its clicks are played, and the song's first sample comes out
    ///   exactly `countIn.leadInSamples` samples after the start. During that part `position` is below zero:
    ///   -1.5 means the song starts in a second and a half.
    /// - Restart Recording calls this again with the same count-in, and gets the same count-in again.
    /// - A count-in that is off starts the song at the place at once, like `start(from:atHostTime:)`.
    ///
    /// The clicks are made as loud as the click's volume is at this moment. A volume changed during the count-in
    /// is heard from the next start on.
    ///
    /// - Parameters:
    ///   - countIn: what `RecordingPlacement.countIn(to:bars:grid:)` gave.
    ///   - settings: the click of the song (`Project.click`): its sound and how often it clicks. Whether it is on
    ///     and its volume are not read from here. The volume is the one given to `setClickVolume`.
    ///   - accentBeatOne: the setting `click.accentBeatOne`.
    ///   - hostTime: the moment the first sample of the count-in is due (`Recorder.hostTime(in:)`).
    /// - Returns: the place in the song that belongs to `hostTime`, in song seconds, exact to the sample. It is
    ///   below zero when the count-in begins before the song. Hand it to the recorder as `songPosition`, with
    ///   `hostTime` as `songStartHostTime`, and the take is placed right: what the microphone hears during the
    ///   part before the song lies before song second 0.
    @discardableResult
    public func start(
        countingIn countIn: CountIn,
        click settings: ClickSettings,
        accentBeatOne: Bool = SettingKey<Bool>.accentBeatOne.defaultValue,
        atHostTime hostTime: UInt64
    ) throws -> Double {
        guard !countIn.isOff, countIn.lengthSamples > 0 else {
            try start(from: countIn.place, atHostTime: hostTime)
            return graph.withLock { $0.lastSeconds }
        }
        let clicks = clicks(of: countIn, click: settings, accentBeatOne: accentBeatOne)
        run += 1
        let onEnd = AudioBlocks.songEnded(tell: self, run: run)
        defer { publish() }
        return try graph.withLock {
            try $0.start(countingIn: countIn, clicks: clicks, atHostTime: hostTime, onEnd: onEnd)
            return $0.lastSeconds
        }
    }

    /// Makes the clicks of a count-in ahead of time, so that the start of the take that follows has nothing left
    /// to work out. Making them takes a few hundredths of a second, and a take is started for a moment only a
    /// tenth of a second ahead. Call it with what `start(countingIn:...)` will be given, before that moment is
    /// chosen. Without this call the take still starts, and makes its clicks then.
    public func prepare(
        countingIn countIn: CountIn,
        click settings: ClickSettings,
        accentBeatOne: Bool = SettingKey<Bool>.accentBeatOne.defaultValue
    ) {
        _ = clicks(of: countIn, click: settings, accentBeatOne: accentBeatOne)
    }

    /// The clicks of a count-in as the count-in player takes them, at the click's volume as it is now. The ones
    /// made last are kept: a restart asks for the clicks it has just had, and making them again would only cost
    /// time.
    private func clicks(of countIn: CountIn, click settings: ClickSettings, accentBeatOne: Bool) -> ClickStorage? {
        let made = CountInClicks(
            countIn: countIn,
            sound: settings.sound,
            division: settings.division,
            subBeats: settings.subBeats,
            accentBeatOne: accentBeatOne,
            volume: graph.withLock { $0.clickVolume }
        )
        if countInClicks?.made != made {
            let samples = ClickRenderer.renderCountIn(
                countIn, settings: settings, volume: made.volume, accentBeatOne: accentBeatOne
            )
            countInClicks = (made, ClickStorage(samples))
        }
        return countInClicks?.sound
    }
}

extension Graph {
    /// How long the song's click takes to come back to its level after the click to start on, in samples
    /// (10 ms). Coming back at once could begin in the middle of the ring of a click and be heard as a tick.
    static let clickReturnSamples = 480

    /// Starts the four players together for a take: the count-in's clicks at once, the song and the clips
    /// after the part before the song and rising, the song's click after the click to start on.
    mutating func start(
        countingIn countIn: CountIn,
        clicks: ClickStorage?,
        atHostTime hostTime: UInt64,
        onEnd: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) throws {
        player.stop()
        clickPlayer.stop()
        clipPlayer.stop()
        countInPlayer.stop()
        playing = false
        leadInSamples = 0
        fadeEndSample = 0
        clickHeldUntil = 0
        let startSample = min(countIn.songStartSample, lengthSamples)
        // With Loop on the count-in leads into the loop, which then goes round like any playback.
        runLoop = loop(reachedFrom: startSample)
        guard let song, startSample < song.length else {
            // No song, or a place at its very end: there is nothing to play, so the engine can rest.
            lastSeconds = PlaybackPosition.seconds(forSample: startSample)
            engine.pause()
            return
        }
        try wake()
        runStartSample = startSample
        leadInSamples = countIn.leadInSamples
        fadeEndSample = Int64(countIn.fadeSamples)
        clickHeldUntil = Int64(countIn.lengthSamples + ClickSound.startLengthSamples)
        lastSeconds = PlaybackPosition.seconds(forSample: startSample) - Double(leadInSamples) / Lockstep.sampleRate

        let songStart = Int64(leadInSamples)
        schedule(song, on: player, fromCount: songStart, interrupting: false, onEnd: onEnd)
        if let clips {
            schedule(clips, on: clipPlayer, fromCount: songStart, interrupting: false, onEnd: nil)
        }
        if let click {
            scheduleClickAfterCountIn(click, interrupting: false)
        }
        if let clicks, let buffer = AudioBlocks.buffer(of: clicks, from: 0, format: format) {
            countInPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }
        // All four players are told the same moment, and each was handed its sound for a count of samples from
        // that moment. So the song's first sample leaves exactly as long after the first click as the part before
        // the song lasts. An engine without a sound device starts with the next sample it is asked for.
        let moment = engine.isInManualRenderingMode ? nil : AVAudioTime(hostTime: hostTime)
        player.play(at: moment)
        clickPlayer.play(at: moment)
        clipPlayer.play(at: moment)
        countInPlayer.play(at: moment)
        playing = true
        runStartHostTime = hostTime
    }

    /// Hands a player the song, or the clips, to play from its count of samples `first` on: rising as the
    /// count-in says until `fadeEndSample`, and as it is from there.
    ///
    /// - Returns: false when there is nothing of the sound left to play from there.
    @discardableResult
    func schedule(
        _ sound: any PlayableStorage,
        on node: AVAudioPlayerNode,
        fromCount first: Int64,
        interrupting: Bool,
        onEnd: (@Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void)?
    ) -> Bool {
        var songSample = runStartSample + Int(first) - leadInSamples
        guard songSample >= 0 else { return false }
        // Sound for the very start needs no time: the player begins with it at the moment it is told to play.
        var time = first == 0 && !interrupting ? nil : AVAudioTime(sampleTime: first, atRate: Lockstep.sampleRate)
        var options: AVAudioPlayerNodeBufferOptions = interrupting ? .interrupts : []
        if first < fadeEndSample {
            let count = min(Int(fadeEndSample - first), sound.length - songSample)
            let rise = Double(fadeEndSample)
            guard let rising = AudioBlocks.rising(
                sound, from: songSample, count: count, firstLevel: Double(first) / rise, step: 1 / rise, format: format
            ) else { return false }
            node.scheduleBuffer(rising, at: time, options: options, completionHandler: nil)
            songSample += count
            // What follows is given its own count to start on, unless the rise began at the very start. Handed
            // over "after what is there", it would be put after the sound it is meant to replace, which is
            // thrown away when the rise starts.
            time = time.map { _ in AVAudioTime(sampleTime: first + Int64(count), atRate: Lockstep.sampleRate) }
            options = []
        }
        return scheduleRest(of: sound, on: node, from: songSample, at: time, options: options, onEnd: onEnd)
    }

    /// Hands the click player the song's click to play from the end of the count-in's click to start on
    /// (`clickHeldUntil`). Until then it is silent: the count-in has clicks of its own, and two clicks on one
    /// beat would add up to more than full scale. The song's click comes back over 10 ms.
    @discardableResult
    func scheduleClickAfterCountIn(_ click: any PlayableStorage, interrupting: Bool) -> Bool {
        let songSample = runStartSample + Int(clickHeldUntil) - leadInSamples
        let time = AVAudioTime(sampleTime: clickHeldUntil, atRate: Lockstep.sampleRate)
        let options: AVAudioPlayerNodeBufferOptions = interrupting ? .interrupts : []
        let count = min(Self.clickReturnSamples, click.length - songSample)
        guard let returning = AudioBlocks.rising(
            click, from: songSample, count: count, firstLevel: 0, step: 1 / Double(Self.clickReturnSamples), format: format
        ) else {
            // The song ends before the click would come back. A click that was to be replaced still has to go.
            guard interrupting, let silence = AudioBlocks.silence(format: format) else { return !interrupting }
            clickPlayer.scheduleBuffer(silence, at: time, options: options, completionHandler: nil)
            return true
        }
        clickPlayer.scheduleBuffer(returning, at: time, options: options, completionHandler: nil)
        // The rest is given its own count to start on. Handed over "after what is there", it would be put
        // after the sound it is meant to replace, which is thrown away when the first part starts.
        let restTime = AVAudioTime(sampleTime: clickHeldUntil + Int64(count), atRate: Lockstep.sampleRate)
        scheduleRest(of: click, on: clickPlayer, from: songSample + count, at: restTime)
        return true
    }

    /// A new click, or new clips, handed over while a count-in is still under way, to take over at the players'
    /// count `swapAt`. The song's click stays silent until the click to start on has sounded, and clips that
    /// arrive while the song is rising rise with it.
    ///
    /// - Returns: nil when the count-in does not touch this change and it is made the ordinary way. Otherwise
    ///   whether the new sound is in place.
    func swapDuringCountIn(to sound: (any PlayableStorage)?, on beside: AVAudioPlayerNode, at swapAt: Int64) -> Bool? {
        if beside === clickPlayer, swapAt < clickHeldUntil {
            if let sound {
                return scheduleClickAfterCountIn(sound, interrupting: true)
            }
            guard let silence = AudioBlocks.silence(format: format) else { return false }
            let time = AVAudioTime(sampleTime: swapAt, atRate: Lockstep.sampleRate)
            beside.scheduleBuffer(silence, at: time, options: .interrupts, completionHandler: nil)
            return true
        }
        if beside === clipPlayer, swapAt < fadeEndSample, let sound {
            return schedule(sound, on: beside, fromCount: swapAt, interrupting: true, onEnd: nil)
        }
        return nil
    }
}

// MARK: - Silence

extension PlaybackEngine {
    /// Turns the sound off or on. While silent the song still plays and the position still moves.
    public func setSilent(_ silent: Bool) {
        graph.withLock { $0.setSilent(silent) }
    }
}

extension Graph {
    /// Silence is the engine's own volume at zero and nothing else: the song still runs through the player, so the
    /// position, the end of the song and everything else behave as they do with sound.
    func setSilent(_ silent: Bool) {
        engine.mainMixerNode.outputVolume = silent ? 0 : 1
    }
}

// MARK: - Test ticks

extension PlaybackEngine {
    /// Stops the song and plays a sound once, from its first sample, at an exact moment on the Mac's clock (a host
    /// time): the test ticks that measure the delay of the headphones and the microphone (`CalibrationRun`).
    ///
    /// The sound leaves the same way the song does in a take: a player in this engine that is told its moment
    /// with a host time, through the same mixer to the same sound output. So it comes out exactly as late as the
    /// song does. It is always played as loud as its samples say, whatever the click is set to. A silent engine
    /// plays it without sound. `stop()` cuts it off.
    ///
    /// - Parameters:
    ///   - samples: mono samples at 48,000 Hz.
    ///   - hostTime: the moment the first sample is due, a little ahead of now (`Recorder.hostTime(in:)`).
    public func playTicks(_ samples: [Float], atHostTime hostTime: UInt64) throws {
        stop()
        guard let sound = ClickStorage(samples) else { return }
        soundsPlayedOnce += 1
        let onEnd = AudioBlocks.soundPlayedOnceEnded(tell: self, number: soundsPlayedOnce)
        try graph.withLock { try $0.playOnce(sound, atHostTime: hostTime, onEnd: onEnd) }
    }
}

extension Graph {
    /// Plays a sound once from its start at an exact moment, at full volume. The song is not playing.
    func playOnce(
        _ sound: ClickStorage,
        atHostTime hostTime: UInt64,
        onEnd: @escaping @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void
    ) throws {
        oncePlayer.stop()
        guard let buffer = AudioBlocks.buffer(of: sound, from: 0, format: format) else { return }
        try wake()
        // An engine without a sound device has no clock to wait for. It starts with the next sample it is asked for.
        let offline = engine.isInManualRenderingMode
        oncePlayer.volume = 1
        oncePlayer.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: offline ? .dataRendered : .dataPlayedBack,
            completionHandler: onEnd
        )
        oncePlayer.play(at: offline ? nil : AVAudioTime(hostTime: hostTime))
    }
}

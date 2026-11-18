import Foundation
import LockstepAudio
import LockstepCore

/// How one take is counted in, decided once when Record is pressed and used for every
/// attempt of that take: the place recording starts, the count-in before it, and the
/// click and the beats it was made with.
///
/// This is the one place the app goes to for a take's count-in. Record, Restart
/// Recording and every attempt a restart keeps use it, and loop recording (phase 23)
/// makes one for the start of the loop and calls the same three functions:
///
///     let counted = TakeCountIn(nearest: playhead, bars: settings[.runUpBars], in: project,
///                               accentBeatOne: settings[.accentBeatOne], delays: settings.delaysInUse)
///     await counted.prepare(engine)                    // before the moment is chosen
///     let hostTime = Recorder.hostTime(in: lead)
///     let songPosition = try await counted.start(engine, atHostTime: hostTime)
///     // later, for the attempt that was started this way:
///     let captured = try await recorder.stop(songPosition: songPosition, songStartHostTime: hostTime)
///     let finished = await FinishedTake.make(from: captured, countedIn: counted, in: package)
///
/// Everything is kept as it was when Record was pressed, so a restart counts in exactly
/// as the first attempt did, and the clip of each attempt is chosen with the clicks that
/// were really heard during it.
///
/// A take that is recorded slower (`slow`) is counted in, played and cut in its own time, "slow
/// time": the place, the start, the beats and the loop here are those of the slowed song, which is
/// what the player plays and the microphone hears during the take. Only `aim` and `startLine` are
/// in song seconds. When the take has been looked at it is moved to song time
/// (`FinishedPasses.make`). At full speed slow time is song time and nothing differs.
struct TakeCountIn: Sendable, Equatable {
    /// The count-in: the place, where it begins (below zero when before the song) and its clicks.
    let countIn: CountIn
    /// The click of the song as it was when Record was pressed: its sound and how often it clicks.
    let click: LockstepCore.ClickSettings
    /// The setting `click.accentBeatOne` as it was when Record was pressed.
    let accentBeatOne: Bool
    /// The song's beats as they were when Record was pressed, or nil when they were not known.
    let grid: Grid?
    /// The delays measured for pairs of headphones and microphone that were in use when
    /// Record was pressed, in seconds, by the key of the pair (`AppSettings.delaysInUse`).
    let delays: [String: Double]
    /// The loop the take goes round in, when Record was pressed with Loop on, or nil. The place is
    /// then the loop's start, and when the take ends every time round becomes a take of its own
    /// (`FinishedPasses`).
    let loop: LoopRegion?
    /// Where the playhead stood when Record was pressed, in song seconds. Nil when it had no say in where
    /// recording starts: with Loop on, and for a take made from a file.
    let playhead: Double?
    /// The speed the take is recorded at. Everything else here is in the time of that speed.
    let slow: SlowTime

    /// The place recording starts, in the take's own seconds: the record origin.
    var place: Double { countIn.place }
    /// Where Max aimed the take, in song seconds: the place recording starts, and where the playhead stood.
    /// It decides whether the take becomes a new take of a clip that is already there
    /// (`Project.addRecording`). The clip of a take is cut to where the voice is and may start well before
    /// or after the place, so where the clip starts cannot say it.
    var aim: RecordAim {
        RecordAim(place: slow.songSeconds(forSlow: countIn.place), playhead: playhead.map(slow.songSeconds(forSlow:)))
    }
    /// Where the count-in begins, in the take's own seconds. Below zero when it begins before the song.
    var start: Double { countIn.start }

    /// The count-in for Record pressed with the playhead at `playhead`.
    ///
    /// Record aims at the beat nearest the playhead, so the click to start on lands on a
    /// beat. Where the song has no beats it is the playhead itself.
    ///
    /// - Parameters:
    ///   - playhead: where the playhead stands, in song seconds.
    ///   - bars: the setting `recording.runUpBars`: 0 (Off), 1, 2 or 4.
    ///   - project: the open project. Its beats, its click and the song's length are read.
    ///   - accentBeatOne: the setting `click.accentBeatOne`.
    ///   - delays: the measured delays in use right now (`AppSettings.delaysInUse`).
    ///   - slow: the speed the take is recorded at. The playhead and the project are handed in as they
    ///     are, in song time, and are slowed here.
    init(
        nearest songPlayhead: Double, bars: Int, in songProject: Project, accentBeatOne: Bool,
        delays: [String: Double], slow: SlowTime = SlowTime(rate: 1)
    ) {
        let playhead = slow.slowSeconds(forSong: songPlayhead)
        let project = slow.slowed(songProject)
        var place = RecordingPlacement.recordPlace(nearest: playhead, grid: project.grid)
        // A beat at the very end of the song leaves nothing to record over, and a take cannot be placed
        // where the song's beginning is cut away. The playhead's own place, on what is left, does.
        let kept = project.keptSeconds
        if place >= kept.upperBound || place < kept.lowerBound {
            place = min(max(playhead, kept.lowerBound), kept.upperBound)
        }
        countIn = RecordingPlacement.countIn(to: place, bars: bars, grid: project.grid)
        click = project.click
        self.accentBeatOne = accentBeatOne
        grid = project.grid
        self.delays = delays
        loop = nil
        self.playhead = playhead
        self.slow = slow
    }

    /// The count-in for Record pressed with Loop on: the place is the loop's start, wherever the
    /// playhead stands, and the count-in is heard once, before the first time round.
    ///
    /// - Parameters:
    ///   - region: the loop, as `LoopState.region` has it.
    ///   - bars: the setting `recording.runUpBars`: 0 (Off), 1, 2 or 4.
    ///   - project: the open project. Its beats and its click are read.
    ///   - slow: the speed the take is recorded at. The loop and the project are handed in as they are,
    ///     in song time, and are slowed here.
    init(
        loopingFrom songRegion: LoopRegion, bars: Int, in songProject: Project, accentBeatOne: Bool,
        delays: [String: Double], slow: SlowTime = SlowTime(rate: 1)
    ) {
        let region = slow.slowed(songRegion) ?? songRegion
        let project = slow.slowed(songProject)
        countIn = RecordingPlacement.countIn(to: region.start, bars: bars, grid: project.grid)
        click = project.click
        self.accentBeatOne = accentBeatOne
        grid = project.grid
        self.delays = delays
        loop = region
        playhead = nil
        self.slow = slow
    }

    /// No count-in at all, with recording starting at `place`: what `-addTake` uses, for a
    /// take placed as if Record had been pressed at the very start of the song with the
    /// count-in off.
    init(offAt place: Double) {
        countIn = CountIn(place: place, start: place)
        click = LockstepCore.ClickSettings()
        accentBeatOne = SettingKey<Bool>.accentBeatOne.defaultValue
        grid = nil
        delays = [:]
        loop = nil
        playhead = nil
        slow = SlowTime(rate: 1)
    }

    /// Makes the count-in's clicks ahead of time. Call it before the moment to start at
    /// is chosen: making them can take longer than the moment lies ahead. When they are
    /// already made, as for a restart, this costs nothing.
    func prepare(_ engine: PlaybackEngine) async {
        await engine.prepare(countingIn: countIn, click: click, accentBeatOne: accentBeatOne)
    }

    /// Starts the count-in and then the song, at an exact moment on the Mac's clock.
    /// With the count-in off the song starts at the place at once.
    ///
    /// - Returns: the place in the song that belongs to `hostTime`, in song seconds, below
    ///   zero when the click counts in before the song. Hand it to the recorder with the
    ///   same host time when the attempt ends, and the recording is placed right.
    func start(_ engine: PlaybackEngine, atHostTime hostTime: UInt64) async throws -> Double {
        try await engine.start(countingIn: countIn, click: click, accentBeatOne: accentBeatOne, atHostTime: hostTime)
    }

    /// The part of an attempt that becomes its clip, in samples of the recording, or nil
    /// when the attempt is thrown away (`RecordingPlacement.clipSamples`).
    ///
    /// The clip starts at the place, or earlier where a word leads into it. The clicks of
    /// the count-in leak from the headphones into the microphone, so their times are
    /// handed over and a leaked click is not taken for a word.
    ///
    /// Sound arrives in a recording later than it was played, by the delay measured for
    /// the headphones and the microphone. The place and the clicks are looked for where
    /// they really are in the attempt: in the recording moved back by that delay, as it
    /// is when it goes into the project. Without a measured delay nothing is moved.
    ///
    /// - Parameters:
    ///   - recording: the attempt as the recorder handed it over, with its length and
    ///     its place in the song.
    ///   - envelope: the loudness curve of the attempt's sound (`VoiceEnvelope.envelope(of:)`).
    func clipSamples(of recording: Recording, envelope: VoiceEnvelope) -> Range<Int>? {
        let placed = recording.movedBack { delays[$0.key] }
        return RecordingPlacement.clipSamples(
            of: placed,
            voicedStretches: envelope.voicedStretches(noiseFloorFrom: fullLevelSample(of: placed)),
            origin: countIn.place,
            grid: grid,
            clickLeak: ClickRenderer.leak(of: countIn, settings: click)
        )
    }

    /// The sample of an attempt from which the song in the headphones was at full level.
    /// What counts as quiet in the attempt is measured from there: the part before it,
    /// with the song silent or still rising, is quieter than the rest and would make the
    /// song leaking in afterwards look like a voice. Zero, the whole attempt, when the
    /// count-in is off.
    func fullLevelSample(of recording: Recording) -> Int {
        guard !countIn.isOff else { return 0 }
        let fullLevel = countIn.start + countIn.seconds * CountIn.fadeShare
        return max(Int(((fullLevel - recording.songTime(ofSample: 0)) * Lockstep.sampleRate).rounded()), 0)
    }

    /// What a `-scratch` run says on standard error when a take starts: the place, where
    /// the count-in begins, and how much of it lies before the song, in song seconds. A take
    /// that is recorded slower also says its speed: every second of the song then lasts longer.
    var startLine: String {
        let line = String(
            format: "started a take at %.3f s, counted in from %.3f s, of which %.3f s before the song",
            slow.songSeconds(forSlow: countIn.place), slow.songSeconds(forSlow: countIn.start),
            slow.songSeconds(forSlow: countIn.leadInSeconds)
        )
        guard slow.isSlow else { return line }
        return line + String(format: ", recorded at %.0f %% of the song's speed", slow.rate * 100)
    }
}

extension AppSettings {
    /// The measured delay of every pair of headphones and microphone whose delay is in
    /// use right now, in seconds, by the key of the pair (`DevicePair.key`): what
    /// `delay(for:)` answers, as a list that can be taken along to another thread.
    var delaysInUse: [String: Double] {
        var delays: [String: Double] = [:]
        for entry in measuredDelays {
            delays[entry.id] = delay(for: entry.devices)
        }
        return delays
    }
}

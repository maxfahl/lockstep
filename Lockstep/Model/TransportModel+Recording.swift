import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import QuartzCore

// Recording. It is part of `TransportModel` and lives in a file of its own so the part's main
// file stays readable: Record with its count-in, starting a take over, Stop, the end of the song
// and a change of sound devices, what becomes of what was recorded, the window following the
// take's phase, the red clip and the meter, Quit during a take, and `-addTake`. What it keeps
// between two calls is in the class, in `TransportModel.swift`.
extension TransportModel {
    // MARK: Recording

    /// How far ahead of "now" the song is asked to start for a take, in seconds. The
    /// player then starts on that exact moment, and the recording's place in the song is
    /// worked out from it.
    private nonisolated static let takeStartLead = 0.1

    /// True from the press of Record until the take is a clip or has been thrown away.
    var isTakeGoing: Bool { takeStatus.phase != nil }

    /// Record: starts a take, or starts the one that is going over, the count-in included.
    /// A take is stopped with Play or Stop.
    ///
    /// Before the first take macOS asks for the microphone. While it is refused, every
    /// press shows how to allow it and nothing is recorded.
    func recordOrRestart() {
        guard takeStatus.phase == nil else {
            restartTake(keepingAttempt: settings[.restartKeepsAttempt])
            return
        }
        guard loadedSounds.song != nil, !loadedSounds.isOpening, !isAskingForMicrophone else { return }
        isAskingForMicrophone = true
        Task {
            let answer = await MicrophoneAccess.mayRecord()
            guard answer == .allowed else {
                isAskingForMicrophone = false
                return
            }
            // With a slower speed chosen the take needs the slow song, which may still be being made.
            // Record waits for it, and further presses are ignored as they are while macOS is asked.
            let wantsSlow = slowTake.speed.isSlow
            let slowSong = await slowTake.slowedSong()
            isAskingForMicrophone = false
            startTake(slowSong: slowSong)
            if wantsSlow, slowSong == nil, takeStatus.phase != nil {
                windowState.content.message = SlowTakeModel.notMadeMessage
            }
        }
    }

    /// Remembers the record origin (the beat nearest the playhead, and the selected
    /// track), opens the microphone and counts in to that place: the click counts the
    /// bars chosen in the click menu, the song and the clips rise from silence, and a
    /// louder click marks the place. With the count-in off, recording starts at once.
    ///
    /// - Parameter slowSong: the slowed song, for a take that is recorded slower, or nil for a take
    ///   at full speed. The count-in is then made in slow time and the player is handed the slow sound
    ///   in the same turn of its line as the start. What is remembered here (the record origin, the
    ///   place Go Back returns to) stays song time.
    private func startTake(slowSong: SlowSong?) {
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil, let package = store.package,
            let trackID = selection.recordingTrackID
        else { return }
        // At the very end there is nothing left to record over, so Record starts over, like Play.
        let kept = store.project.keptSeconds
        let stoodAt = playhead.seconds >= kept.upperBound ? kept.lowerBound : playhead.seconds
        // As many bars of count-in as the click menu says. Every restart of this take
        // counts in the same way, also if the choice is changed meanwhile.
        let slow = slowSong?.slow ?? SlowTime(rate: 1)
        var countIn = TakeCountIn(
            nearest: stoodAt,
            bars: settings[.runUpBars],
            in: store.project,
            accentBeatOne: settings[.accentBeatOne],
            delays: settings.delaysInUse,
            slow: slow
        )
        // With Loop on, recording starts at the loop's start wherever the playhead stands, the loop
        // goes round under one long recording, and every time round becomes a take when it ends.
        if let loopRegion = loopState.region {
            countIn = TakeCountIn(
                loopingFrom: loopRegion,
                bars: settings[.runUpBars],
                in: store.project,
                accentBeatOne: settings[.accentBeatOne],
                delays: settings.delaysInUse,
                slow: slow
            )
        }
        takeNumber += 1
        take = Take(number: takeNumber, package: package, countIn: countIn)
        // Record pressed while a take's stretch plays: the song goes on as a take, and the
        // take is recorded over the clips as the project has them.
        forgetTakesStretch()
        // The other voices are heard slow with the song, as they sound at this moment.
        let backing = slowSong.map { slowTake.backing(with: $0, loop: countIn.loop) }
        take?.backing = backing
        // A message about the take before is no longer news.
        if windowState.content.message == Self.deviceChangedMessage || windowState.content.message == Self.attemptNotKeptMessage {
            windowState.content.message = nil
        }
        emptyTakeDrawing()
        // Counting in, or recording at once when the count-in is off. The origin is song time.
        let runUpStart = slow.songSeconds(forSlow: countIn.start)
        takeStatus.flow.record(
            from: RecordOrigin(seconds: slow.songSeconds(forSlow: countIn.place), trackID: trackID, runUpStart: runUpStart)
        )
        showPosition(runUpStart)
        beats.showTempo(in: store.project.grid)
        // The count-in may start out of view: before the left edge, or at a loop that lies
        // somewhere else than the playhead stood. The timeline comes to it. The playhead
        // does not move yet: the microphone is opened first.
        timelineView.bringToMiddle(playhead.seconds, moving: false)
        windowState.content.isPlaying = true

        // In line with everything else the player is told, so a jump or a stop that was
        // asked for just before is carried out first.
        player.takeTurn { [self, engine = player.engine, recorder] in
            // The slow sound goes in first, so the microphone is not open while the voices are made slower.
            if let backing {
                await slowTake.put(backing)
            }
            let start = await Self.startTake(on: recorder, with: engine, in: package, countingIn: countIn)
            // A slow take that never got going leaves the player as it found it.
            if let backing, !start.isStarted {
                await slowTake.putBack(backing)
            }
            return start
        } beforeNothingLeft: { [self] start in
            takeStarted(start)
        } afterNothingLeft: { _ in
            // Nothing more: the start was handed on before the window read the player.
        }
    }

    /// How the start of a take went.
    private enum TakeStart: Sendable {
        /// The microphone is open and the count-in starts at this moment on the Mac's clock,
        /// which belongs to this place in the song (below zero when it starts before the song).
        case started(songStartHostTime: UInt64, songPosition: Double)
        /// The microphone could not be opened. Nothing was recorded and the song was not touched.
        case noMicrophone(RecorderError?)
        /// The microphone was open but the song could not be played. The take is gone.
        case noPlayback

        var isStarted: Bool {
            if case .started = self { true } else { false }
        }
    }

    /// Opens the microphone, then starts the count-in and the song for the take. The
    /// microphone comes first, so it is already listening when the first click is heard.
    @concurrent
    private nonisolated static func startTake(
        on recorder: Recorder,
        with engine: PlaybackEngine,
        in package: ProjectPackage,
        countingIn countIn: TakeCountIn
    ) async -> TakeStart {
        // The clicks are made before the moment to start at is chosen. Making them then
        // could take longer than the moment lies ahead.
        await countIn.prepare(engine)
        do {
            try await recorder.start(in: package)
        } catch {
            return .noMicrophone(error as? RecorderError)
        }
        let hostTime = Recorder.hostTime(in: takeStartLead)
        do {
            let songPosition = try await countIn.start(engine, atHostTime: hostTime)
            return .started(songStartHostTime: hostTime, songPosition: songPosition)
        } catch {
            // A take cannot be called off, so it is stopped and its file is removed.
            if let captured = try? await recorder.stop(songPosition: countIn.start, songStartHostTime: hostTime) {
                try? FileManager.default.removeItem(at: package.url.appendingPathComponent(captured.recording.file))
            }
            return .noPlayback
        }
    }

    /// The player and the microphone have done what `startTake` asked, or could not.
    private func takeStarted(_ start: TakeStart) {
        switch start {
        case .started(let songStartHostTime, let songPosition):
            take?.songStartHostTime = songStartHostTime
            take?.songStartPosition = songPosition
            takeStatus.flow.started()
            // Go Back returns here.
            takeStatus.lastTakeStart = takeStatus.flow.origin?.seconds
            // For a check that cannot hear: where the take starts and how it is counted in.
            if LaunchOptions.current.isScratch, let countIn = take?.countIn {
                Agent.tell(countIn.startLine)
            }
        case .noMicrophone(let error):
            giveUpTake()
            windowState.alert = MessageAlert(
                title: "Lockstep could not start recording.",
                detail: error == .noInputDevice
                    ? "This Mac has no microphone to record from. Connect one, then try again."
                    : "The microphone could not be opened. Check the sound input in System Settings, then try again."
            )
            windowState.showsAlert = true
        case .noPlayback:
            giveUpTake()
            windowState.alert = MessageAlert(
                title: "Lockstep could not play the song.",
                detail: "Check that the Mac has a sound output, then try again."
            )
            windowState.showsAlert = true
        }
    }

    /// Forgets a take that never got going, or that could not go on.
    private func giveUpTake() {
        let wasSlow = take?.backing != nil
        take = nil
        takeStatus.flow.end()
        hearClips(afterSlowTake: wasSlow)
    }

    /// Hands the player the clips when a take is over. After an ordinary take only those it was not
    /// given meanwhile. After a take recorded slower all of them: the player had the slowed row, and
    /// lost its clips when it got the real song back.
    private func hearClips(afterSlowTake wasSlow: Bool) {
        if wasSlow {
            clips.followClips(of: store.project)
        } else {
            clips.hearWaitingClips()
        }
    }

    /// The red clip starts empty: during the count-in only the starting place is marked.
    /// For the first attempt of a take and for every attempt after a restart.
    func emptyTakeDrawing() {
        takeStatus.progress.recordedUntil = nil
        takeStatus.progress.levels = WaveformLevels(minimums: [], maximums: [])
        takeLevels = takeStatus.progress.levels
        takeNextBlock = nil
    }

    // MARK: Restarting a take

    /// How far ahead of "now" the song is asked to start again after a restart, in
    /// seconds. Shorter than for Record (`takeStartLead`), because nothing has to be
    /// woken up: the player is running and the microphone is open. It is still several
    /// of the blocks the Mac asks for at a time, so the song starts on the exact moment
    /// and the new attempt is placed right.
    private nonisolated static let restartLead = 0.05

    /// What the window says when an attempt that was to be kept could not be.
    private static let attemptNotKeptMessage = "The attempt before this one could not be kept."

    /// Record pressed during a take: drops what was recorded since the song was last started
    /// for the take, and starts again from the same place with the same count-in. It can be
    /// pressed any number of times, during the count-in and while recording.
    ///
    /// The target is that sound is heard again within 150 ms. So nothing is closed and
    /// opened: the player keeps running and only starts the count-in, the song, the click
    /// and the clips again, and the microphone stays open and only gets a new file. The
    /// dropped attempt is dealt with after the count-in is on its way.
    ///
    /// A restart asked for while the one before is still being carried out is ignored,
    /// and so is one at any time no take is going (`TakeFlow.restart`).
    ///
    /// - Parameter keepingAttempt: what becomes of the dropped attempt. False deletes its
    ///   file and makes no clip. True makes it a clip like any finished recording, with
    ///   an undo step of its own.
    private func restartTake(keepingAttempt: Bool) {
        guard let going = take, let place = takeStatus.flow.restart() else { return }
        // The window follows at once: the red clip is gone, the meter starts over and
        // the playhead stands where the count-in begins.
        emptyTakeDrawing()
        clearMicLevel()
        showPosition(place.runUpStart)
        beats.showTempo(in: store.project.grid)
        // The timeline may have moved on with the attempt. It comes back to where the
        // count-in begins, which the playhead leaves a moment later.
        timelineView.bringToMiddle(playhead.seconds, moving: false)

        // In line with everything else the player is told, like the start of a take.
        player.takeTurn { [self, engine = player.engine, recorder] in
            var restart: TakeRestart?
            // Read only now: an earlier restart has been carried out and has left its moment in `take`.
            if take?.number == going.number, let attemptStartedAt = take?.songStartHostTime,
                let attemptStartedFrom = take?.songStartPosition
            {
                restart = await Self.restartTake(
                    on: recorder,
                    with: engine,
                    in: going.package,
                    countingIn: going.countIn,
                    attemptStartedAt: attemptStartedAt,
                    attemptStartedFrom: attemptStartedFrom,
                    keepingAttempt: keepingAttempt
                )
            }
            // A slow take whose song could not be started again is over, and nothing else will end it:
            // the player gets its own sound back here.
            if case .noPlayback = restart, let backing = going.backing {
                await slowTake.putBack(backing)
            }
            return restart
        } beforeNothingLeft: { [self] restart in
            if let restart {
                takeRestarted(restart, of: going, on: place.trackID)
            }
        } afterNothingLeft: { _ in
            // Nothing more: the restart was handed on before the window read the player.
        }
    }

    /// How a restart went.
    private enum TakeRestart: Sendable {
        /// The count-in starts again at this moment on the Mac's clock, which belongs to this
        /// place in the song, and a new attempt is being recorded.
        case restarted(songStartHostTime: UInt64, songPosition: Double, attempt: AttemptEnd)
        /// The file for a new attempt could not be made. Nothing was touched: the song
        /// plays on and the attempt that was going is still being recorded.
        case notRestarted
        /// The song could not be started again. Nothing is being recorded any more.
        case noPlayback(attempt: AttemptEnd)
    }

    /// What became of the attempt a restart dropped.
    private enum AttemptEnd: Sendable {
        /// Its file is deleted. This is what a restart does unless asked to keep attempts.
        case thrownAway
        /// It was looked at like a take that was stopped, and becomes a clip if there is enough of it,
        /// or one take for every time round when it was recorded with Loop on.
        case kept(FinishedPasses)
        /// It was to be kept, and its file could not be closed.
        case lost
    }

    /// Gives the microphone a new file, starts the same count-in again, and then deals
    /// with the attempt that was dropped. The order matters: the quick steps come first,
    /// so the count-in is heard again as soon as it can be, and closing, deleting or
    /// looking at the dropped attempt happens while it already plays.
    ///
    /// - Parameters:
    ///   - attemptStartedAt: the moment on the Mac's clock the dropped attempt was started at.
    ///   - attemptStartedFrom: the place in the song that belongs to that moment.
    @concurrent
    private nonisolated static func restartTake(
        on recorder: Recorder,
        with engine: PlaybackEngine,
        in package: ProjectPackage,
        countingIn countIn: TakeCountIn,
        attemptStartedAt: UInt64,
        attemptStartedFrom: Double,
        keepingAttempt: Bool
    ) async -> TakeRestart {
        let dropped: DroppedAttempt
        do {
            dropped = try await recorder.restart(in: package)
        } catch {
            return .notRestarted
        }
        // The clicks are the ones the attempt before had, so this costs nothing, unless
        // the click's volume was changed meanwhile. Then they are made now, before the
        // moment is chosen.
        await countIn.prepare(engine)
        let hostTime = Recorder.hostTime(in: restartLead)
        var songPosition = countIn.start
        var isPlaying = true
        do {
            // This stops the players and starts them again together. The audio engine
            // itself keeps running, which is what makes it fast.
            songPosition = try await countIn.start(engine, atHostTime: hostTime)
        } catch {
            isPlaying = false
            await engine.stop()
            // The attempt that was just begun has no song to go with. It is stopped and its file removed.
            if let begun = try? await recorder.stop(songPosition: countIn.start, songStartHostTime: hostTime) {
                try? FileManager.default.removeItem(at: package.url.appendingPathComponent(begun.recording.file))
            }
        }

        var attempt = AttemptEnd.thrownAway
        do {
            let captured = try dropped.end(
                keeping: keepingAttempt,
                songPosition: attemptStartedFrom,
                songStartHostTime: attemptStartedAt
            )
            if let captured {
                // A kept attempt is cut like a take that was stopped: by the same count-in.
                attempt = .kept(await FinishedPasses.make(from: captured, countedIn: countIn, in: package))
            }
        } catch {
            attempt = .lost
        }
        return isPlaying
            ? .restarted(songStartHostTime: hostTime, songPosition: songPosition, attempt: attempt)
            : .noPlayback(attempt: attempt)
    }

    /// The player and the microphone have done what `restartTake` asked, or could not.
    private func takeRestarted(_ restart: TakeRestart, of restarted: Take, on trackID: UUID) {
        guard take?.number == restarted.number else { return }
        takeStatus.flow.started()
        switch restart {
        case .restarted(let songStartHostTime, let songPosition, let attempt):
            take?.songStartHostTime = songStartHostTime
            take?.songStartPosition = songPosition
            keep(attempt, on: trackID)
        case .notRestarted:
            // What was recorded is all still there, so it is kept the way Stop keeps it.
            stopTake()
            windowState.alert = MessageAlert(
                title: "Lockstep could not restart the recording.",
                detail: "Check that the disk has room. What you had recorded so far was kept."
            )
            windowState.showsAlert = true
        case .noPlayback(let attempt):
            keep(attempt, on: trackID)
            giveUpTake()
            windowState.alert = MessageAlert(
                title: "Lockstep could not play the song.",
                detail: "Check that the Mac has a sound output, then try again."
            )
            windowState.showsAlert = true
        }
    }

    /// Does what a restart decided about the attempt it dropped: a kept attempt becomes a
    /// clip, and one that was to be kept and could not be is mentioned in the window. It
    /// is a line in the window and not an alert, because the next attempt is already
    /// being recorded and an alert would be in its way.
    private func keep(_ attempt: AttemptEnd, on trackID: UUID) {
        switch attempt {
        case .thrownAway:
            break
        case .kept(let finished):
            keep(finished, on: trackID)
        case .lost:
            windowState.content.message = Self.attemptNotKeptMessage
        }
    }

    /// What the window says after a take was stopped by a change of sound devices.
    private static let deviceChangedMessage = "Recording stopped because a sound device was connected or removed."

    /// What the system calls when a sound device was connected or disconnected and an
    /// audio engine has to follow. It is called on a thread of the system's, so it is
    /// made here, outside the main actor, and only passes the news on to the model.
    nonisolated static func deviceChangeReport(to model: TransportModel) -> @Sendable (Notification) -> Void {
        { [weak model] _ in
            Task { @MainActor in
                model?.audioDeviceChanged()
            }
        }
    }

    /// Headphones or a microphone were connected or disconnected. A take that is going
    /// is stopped and kept, because the rest of it could not be placed in the song any
    /// more, and a message says why. When no take is going there is nothing to do here:
    /// the player moves to the new device by itself.
    private func audioDeviceChanged() {
        stopTake(becauseDeviceChanged: true)
    }

    /// Stops the take that is going: the song and the microphone stop, and what was
    /// recorded becomes a clip (`keep`). The playhead stays where the song stopped.
    ///
    /// - Parameter becauseDeviceChanged: the take is stopped because a sound device
    ///   changed, not because Max stopped it. A message in the window then says so.
    func stopTake(becauseDeviceChanged: Bool = false) {
        guard let stopped = take, let place = takeStatus.flow.origin, takeStatus.flow.stop() else { return }
        if windowState.content.isPlaying {
            windowState.content.isPlaying = false
        }
        let ending = player.takeTurn { [self, engine = player.engine, recorder] in
            // Read only now: the start has been carried out and has left its moment in `take`.
            let going = take?.number == stopped.number ? take : nil
            let end = await Self.endTake(
                countedIn: stopped.countIn,
                in: stopped.package,
                startedAt: going?.songStartHostTime,
                from: going?.songStartPosition ?? stopped.countIn.start,
                on: recorder,
                with: engine
            )
            // After a take recorded slower the player gets its own sound back, in the same turn: the
            // real song, at the place the take stopped, in song time.
            if let backing = stopped.backing {
                await slowTake.putBack(backing)
            }
            return end
        } afterNothingLeft: { [self] end in
            takeEnded(end, of: stopped, on: place.trackID)
            if becauseDeviceChanged {
                windowState.content.message = Self.deviceChangedMessage
            }
        }
        takeStatus.ending = ending
    }

    /// How the end of a take went.
    private enum TakeEnd: Sendable {
        case finished(FinishedPasses)
        /// The take had not started when it was stopped, or its start failed. Nothing was recorded.
        case neverStarted
        /// The recording could not be closed and kept.
        case failed
    }

    /// Stops the song and the microphone, and looks at what was recorded.
    ///
    /// - Parameters:
    ///   - songStartHostTime: the moment on the Mac's clock the attempt was started at,
    ///     or nil when it never was.
    ///   - songPosition: the place in the song that belongs to that moment.
    @concurrent
    private nonisolated static func endTake(
        countedIn countIn: TakeCountIn,
        in package: ProjectPackage,
        startedAt songStartHostTime: UInt64?,
        from songPosition: Double,
        on recorder: Recorder,
        with engine: PlaybackEngine
    ) async -> TakeEnd {
        await engine.stop()
        guard let songStartHostTime else { return .neverStarted }
        do {
            let captured = try await recorder.stop(songPosition: songPosition, songStartHostTime: songStartHostTime)
            return .finished(await FinishedPasses.make(from: captured, countedIn: countIn, in: package))
        } catch {
            return .failed
        }
    }

    /// The take has been stopped and looked at. It becomes a clip, unless it was thrown away.
    private func takeEnded(_ end: TakeEnd, of ended: Take, on trackID: UUID) {
        // A take whose start failed is already forgotten, and a newer one may be going.
        guard take?.number == ended.number else { return }
        take = nil
        takeStatus.flow.end()
        switch end {
        case .finished(let finished):
            keep(finished, on: trackID)
        case .neverStarted:
            break
        case .failed:
            windowState.alert = MessageAlert(
                title: "Lockstep could not keep this recording.",
                detail: "Check that the disk has room, then record again."
            )
            windowState.showsAlert = true
        }
        // Also when the last attempt left no clip of its own.
        hearClips(afterSlowTake: ended.backing != nil)
    }

    /// Puts a finished take into the project as a clip on a track, as one step that can
    /// be undone, and lets it be heard. A take that was thrown away changes nothing.
    ///
    /// - Returns: the id of the new clip, or nil when no clip was made.
    @discardableResult
    private func keep(_ finished: FinishedTake, on trackID: UUID) -> UUID? {
        guard let samples = finished.clipSamples else { return nil }
        // The sound is in place before the edit, so the player finds it when it is handed the clips.
        loadedSounds.sounds[finished.recording.id] = finished.samples
        loadedSounds.waveforms[finished.recording.id] = finished.waveform
        // Moved back by the delay measured for the headphones and the microphone it was made with.
        let recording = finished.recording.movedBack { settings.delay(for: $0) }
        // Aimed at the start of a clip that is there, the take becomes a new take of it. Anywhere else it
        // wins over what it covers: those clips give way, in the same step.
        var changed = store.project
        let clipID = changed.addRecording(
            recording, samples: samples, asClipOn: trackID, aim: finished.aim, peaks: correction.voice.peaks, voices: correction.voice.heard
        )
        volume.normalizeNewClip(clipID, loudness: finished.loudness, in: &changed)
        // The words of a clip that gave way are for more sound than it now plays.
        let cut = words.clearWordsOfCutClips(in: &changed).filter { $0 != clipID }
        store.edit("Record Clip") { $0 = changed }
        correction.findMarkers(ofRecording: recording.id, sound: finished.samples)
        clips.followClips(of: store.project)
        words.writeOutWords(ofNewClip: clipID)
        words.writeOutWords(ofCutClips: cut)
        return clipID
    }

    /// Puts what a recording left behind into the project: the one take of an ordinary
    /// recording, as `keep` above does, or, of a recording made with Loop on, one take for
    /// every time round, all in one step that can be undone ("Record Takes").
    ///
    /// The passes were all aimed at the loop's start, so they are takes of one line, and
    /// new takes of a line that was recorded from there before. What they cover of other
    /// lines gives way, in the same step. The general rule
    /// would make the pass recorded last the active take, and that is the one that was
    /// stopped on its way. So the last pass that ran its full length is made active in the
    /// same edit. Every pass gets its volume, its markers and its words like any recording,
    /// and the delay measured for the headphones and the microphone it was made with.
    ///
    /// - Returns: the ids of the new clips, in the order recorded.
    @discardableResult
    func keep(_ finished: FinishedPasses, on trackID: UUID) -> [UUID] {
        guard finished.isLoopRecording else {
            return finished.takes.compactMap { keep($0, on: trackID) }
        }
        var kept: [(take: FinishedTake, recording: Recording, samples: Range<Int>)] = []
        for take in finished.takes {
            guard let samples = take.clipSamples else { continue }
            // The sound is in place before the edit, so the player finds it when it is handed the clips.
            loadedSounds.sounds[take.recording.id] = take.samples
            loadedSounds.waveforms[take.recording.id] = take.waveform
            kept.append((take, take.recording.movedBack { settings.delay(for: $0) }, samples))
        }
        guard !kept.isEmpty else { return [] }
        let activeRecording = finished.active.flatMap { finished.takes.indices.contains($0) ? finished.takes[$0].recording.id : nil }
        var clipIDs: [UUID] = []
        var changed = store.project
        var activeClip: UUID?
        for pass in kept {
            guard let clipID = changed.addRecording(
                pass.recording, samples: pass.samples, asClipOn: trackID, aim: pass.take.aim, peaks: correction.voice.peaks, voices: correction.voice.heard
            ) else { continue }
            volume.normalizeNewClip(clipID, loudness: pass.take.loudness, in: &changed)
            clipIDs.append(clipID)
            if pass.recording.id == activeRecording { activeClip = clipID }
        }
        if let activeClip {
            changed.setActiveTake(activeClip)
        }
        // The words of a clip that gave way are for more sound than it now plays.
        let cut = words.clearWordsOfCutClips(in: &changed).filter { !clipIDs.contains($0) }
        store.edit("Record Takes") { $0 = changed }
        for pass in kept {
            correction.findMarkers(ofRecording: pass.recording.id, sound: pass.take.samples)
        }
        clips.followClips(of: store.project)
        for clipID in clipIDs {
            words.writeOutWords(ofNewClip: clipID)
        }
        words.writeOutWords(ofCutClips: cut)
        return clipIDs
    }

    // MARK: The phase of a take

    /// The phase of the take has changed (`takeStatus.phaseChanged`): the window follows.
    func takePhaseChanged() {
        let isRunningUp = takeStatus.phase == .runningUp
        let isRecording = takeStatus.phase == .recording
        if windowState.content.isRunningUp != isRunningUp { windowState.content.isRunningUp = isRunningUp }
        if windowState.content.isRecording != isRecording { windowState.content.isRecording = isRecording }
        // The track shows the mark of a take while one is going, and loses it after.
        clips.showClips(of: store.project)
        // The microphone is open only during the run-up and the recording. Before and
        // after, the meter is empty and the mark for "too loud" is off.
        if !isRunningUp, !isRecording {
            clearMicLevel()
        }
    }

    // MARK: The red clip and the meter

    /// Once per display frame while recording: lets the red clip on the track grow to
    /// the playhead, with the waveform of what the microphone has delivered so far.
    /// Only the red clip is drawn again.
    func drawTake(from origin: Double, at position: Double) {
        let blockSize = Double(WaveformPyramid.baseBlockSize)
        // How many blocks of sound fit between the record origin and the playhead. A take recorded
        // slower holds more sound for the same stretch of the song: a second of song lasts longer.
        let rate = take?.countIn.slow.rate ?? 1
        let blocksSinceOrigin = max((position - origin) / rate * Lockstep.sampleRate / blockSize, 0)
        var nextBlock: Int
        if let takeNextBlock {
            nextBlock = takeNextBlock
        } else {
            // The first frame of recording. The attempt also holds the run-up, which is not
            // drawn, so the waveform starts at the block heard when the song reached the origin.
            let recorded = Double(recorder.snapshot().lengthSamples) / blockSize
            nextBlock = max(Int((recorded - blocksSinceOrigin).rounded(.down)), 0)
        }
        let fresh = recorder.waveform(fromBlock: nextBlock)
        takeLevels.minimums.append(contentsOf: fresh.minimums)
        takeLevels.maximums.append(contentsOf: fresh.maximums)
        nextBlock = fresh.firstBlock + fresh.minimums.count
        takeNextBlock = nextBlock

        // The microphone's sound arrives a moment after it was made. The last stretch
        // before the playhead is drawn as silence until it arrives, so the waveform that
        // is there keeps its place and is not stretched to fill the clip.
        var shown = takeLevels
        let missing = Int(blocksSinceOrigin) - shown.minimums.count
        if missing > 0 {
            shown.minimums.append(contentsOf: repeatElement(0, count: missing))
            shown.maximums.append(contentsOf: repeatElement(0, count: missing))
        }
        takeStatus.progress.levels = shown
        takeStatus.progress.recordedUntil = position
    }

    /// Once per display frame while the microphone is open: moves the level meter in
    /// the bar. It rises at once and falls back over about 0.3 seconds. Once the
    /// microphone has been too loud, the end of the meter stays red until the take ends.
    func showMicLevel() {
        let heard = recorder.snapshot()
        let level = micLevelFollower.follow(peak: heard.peak, at: CACurrentMediaTime())
        if micLevel.level != level {
            micLevel.level = level
        }
        if heard.highestPeak >= MicLevel.clippingPeak, !micLevel.isClipping {
            micLevel.isClipping = true
        }
    }

    /// Empties the level meter: no take is going, so the microphone is closed.
    func clearMicLevel() {
        micLevelFollower = MicLevel()
        if micLevel.level != 0 {
            micLevel.level = 0
        }
        if micLevel.isClipping {
            micLevel.isClipping = false
        }
    }

    // MARK: Quit during a take, and `-addTake`

    /// Quit during a take: stops the take and waits until it is a clip in the project,
    /// so that quitting keeps what was recorded.
    func finishTakeBeforeQuitting() async {
        stopTake()
        await takeStatus.ending?.value
    }

    /// Adds the sound files given with `-addTake` to the project that was just opened,
    /// one after the other in the order given, each as if it had been recorded a moment
    /// ago with Record pressed at the very start of the song, or at the place given after
    /// "@", and says on standard error how each went. Files aimed at the same place become
    /// takes of one line, the later one active. A file aimed at another place is a clip of
    /// its own, and what it covers of the clips before it gives way. Only the first project
    /// opened gets them.
    func addLaunchTake() {
        let files = LaunchOptions.current.takesToAdd
        guard !launchTakeTaken, !files.isEmpty else { return }
        launchTakeTaken = true
        guard takeStatus.phase == nil, let package = store.package, let trackID = selection.recordingTrackID else {
            for file in files {
                Agent.tell("could not add the take \(file.url.path): no project is open")
            }
            return
        }
        // As after a take from the microphone that was started at the very start of the
        // song and has just been stopped: nothing else changes the project until the take
        // is in it.
        var flow = takeStatus.flow
        flow.record(from: RecordOrigin(seconds: 0, trackID: trackID, runUpStart: 0))
        flow.stop()
        takeStatus.flow = flow
        takeStatus.ending = Task {
            defer { takeStatus.flow.end() }
            for file in files {
                let url = file.url
                do {
                    let finished = try await FinishedTake.make(fromFile: url, at: file.place, in: package)
                    guard let clipID = keep(finished, on: trackID), let clip = store.project.clip(clipID),
                        let start = store.project.start(of: clip), let end = store.project.end(of: clip)
                    else {
                        Agent.tell("did not add the take \(url.path): it is shorter than 0.2 seconds")
                        continue
                    }
                    Agent.tell(
                        "added the take \(url.path) as a clip from "
                            + String(format: "%.3f s to %.3f s", start, end)
                            + ", take \(store.project.takeNumber(of: clipID) ?? 1)"
                            + " of \(store.project.takeCount(of: clipID))"
                    )
                } catch {
                    let reason = (error as? FinishedTake.FileFailure)?.message ?? error.localizedDescription
                    Agent.tell("could not add the take \(url.path): \(reason)")
                }
            }
        }
    }

    /// For `-lockedDouble`: adds a track under the last one ("New Track", one undo step) and puts a sound
    /// file on it as a take, as if it had just been recorded there with Record pressed at the very start
    /// of the song ("Record Clip", a second step). The selection stays where it is.
    ///
    /// - Returns: the new track and the new clip, with an empty `problem`, or what was in the way. The
    ///   track is added also when the file cannot be used.
    func addTakeOnNewTrack(fromFile url: URL) async -> (trackID: UUID, clipID: UUID, problem: String) {
        let none = UUID()
        guard takeStatus.phase == nil, let package = store.package else {
            return (none, none, "no project is open, or a take is going")
        }
        var changed = store.project
        let trackID = changed.addTrack()
        store.edit("New Track") { $0 = changed }
        // As in `addLaunchTake`: nothing else changes the project until the take is in it.
        var flow = takeStatus.flow
        flow.record(from: RecordOrigin(seconds: 0, trackID: trackID, runUpStart: 0))
        flow.stop()
        takeStatus.flow = flow
        let adding = Task { () -> (clipID: UUID, problem: String) in
            defer { takeStatus.flow.end() }
            do {
                let finished = try await FinishedTake.make(fromFile: url, in: package)
                guard let clipID = keep(finished, on: trackID) else { return (none, "it is shorter than 0.2 seconds") }
                return (clipID, "")
            } catch {
                return (none, (error as? FinishedTake.FileFailure)?.message ?? error.localizedDescription)
            }
        }
        // Quit, and everything else an agent's launch arguments do to the clips, waits for it.
        takeStatus.ending = Task { _ = await adding.value }
        let added = await adding.value
        return (trackID, added.clipID, added.problem)
    }
}

import AppKit
import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import os

/// A track's Voice: a part of the app's model.
///
/// It holds a track's Voice (the switch, the presets, the two knobs and their undo steps), Max's own presets
/// of a Voice, the voices in memory, the queue of voices to make and the making, what the section "Voice" of
/// the panel says, what failed, and `-trackVoice`.
///
/// It does for voices what `SoundModel` does for finished sounds, one step earlier in the pass:
/// `followClips` asks `voicedClips(of:)` first, and hands what it answers to the correction, the Sound part
/// and the player. A voice is the whole recording made again with the track's knobs, exactly as long as the
/// recording, and it stands in for the recording on that track (`TrackVoices`).
///
/// - A voice in memory stands in. One that is on disk is read in the background, and one that is nowhere is
///   made, the clips nearest the playhead first (`VoiceQueue.order`), a few at a time, away from the main
///   actor (`VoiceMaker.fast`), checked and kept (`VoiceFile.takeIn`). Either way the clips are handed over
///   again once it is in memory.
/// - Until a track's voice is there, what stood in before on that track is heard, or the recording.
/// - Nothing is made while a take is going or counting in.
/// - Only the recordings' samples are read here. No syllable, pause, line or note-end finder ever runs on a
///   made voice: what they found in the recording is the voice's too.
@MainActor
final class VoiceModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let store: ProjectStore
    private let settings: AppSettings
    private let playhead: PlayheadPosition

    /// What is kept for voices: the ones in memory, the ones being made, and what stood in last.
    private let work = VoiceWork()

    // What it asks of code that holds it, or of the model's routing. `wireVoice` sets them.
    /// Lets the player and the window follow the clips of a project (`followClips(of:)`, the clips' part).
    var followClips: (Project) -> Void = { _ in }

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore,
        settings: AppSettings,
        playhead: PlayheadPosition
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
        self.settings = settings
        self.playhead = playhead
        showOwnPresets()
    }
}

/// What one pass through the clips is handed about voices: which voice stands in for which recording on
/// which track, and the samples of those voices, by the id they stand in under.
///
/// The lookup names only voices whose samples are in here (`TrackVoices.having`), and the same value goes to
/// every rule of the pass, so a tightened or a finished sound is never named after a voice it was not made
/// from.
struct VoicedClips {
    var voices: TrackVoices
    var samples: [UUID: [Float]]

    /// No voice at all: every clip is read from Max's own recordings.
    static let none = VoicedClips(voices: .none, samples: [:])
}

extension VoiceModel {
    // MARK: The pass

    /// Which voice stands in for which recording on which track right now, with the voices' samples, and the
    /// work of keeping the voices up to date. `followClips` calls it first, before
    /// `correction.tightenedClips(of:voiced:)`, and hands its answer on.
    ///
    /// What stands in for a recording on a track whose Voice is heard is, in this order (the design's four
    /// steps):
    /// 1. the voice of the track's setting, when it is in memory;
    /// 2. (Natural, which is not built);
    /// 3. or else the voice that stood in before on this same track, while the track's Voice is still heard:
    ///    the setting before a knob was turned, so the ear hears one change, from the old to the new;
    /// 4. or else the recording.
    ///
    /// A track whose Voice is off, gone or in the middle gets nothing, and forgets what stood in on it, so
    /// switching it on again never brings an older setting back.
    func voicedClips(of lookup: ProjectLookup) -> VoicedClips {
        let project = lookup.project
        let work = work
        noteNewRecordings(of: project)
        // A project without a heard Voice costs one look at each track.
        guard project.tracks.contains(where: { $0.voice?.isHeard == true }) else {
            if !work.stood.isEmpty || !work.running.isEmpty || !work.samples.isEmpty {
                work.stood = [:]
                work.samples = [:]
                cancelMaking(keeping: [])
            }
            work.current = .none
            return .none
        }

        var voices = TrackVoices.none
        var samples: [UUID: [Float]] = [:]
        var stood: [TrackVoices.Key: TrackVoices.Entry] = [:]
        for track in project.tracks {
            guard let voice = track.voice, voice.isHeard else { continue }
            var asked: Set<UUID> = []
            for clip in track.clips {
                for segment in clip.segments where asked.insert(segment.recordingID).inserted {
                    let recordingID = segment.recordingID
                    let key = VoiceKey(recordingID: recordingID, knobs: voice.knobs, way: .fast)
                    let place = TrackVoices.Key(trackID: track.id, recordingID: recordingID)
                    // A silent recording stands for itself: nothing is made, and the recording is heard.
                    guard !work.silent.contains(key) else { continue }
                    let before = work.stood[place]
                    var entry: TrackVoices.Entry?
                    if let made = work.samples[key] {
                        let id = work.id(of: key)
                        // What stood in just before stays the one before, also over several passes.
                        let earlier = before.map { $0.heard == id ? $0.before : $0.heard } ?? nil
                        entry = TrackVoices.Entry(heard: id, before: earlier)
                        samples[id] = made
                    } else if let before, let held = work.key(of: before.heard).flatMap({ work.samples[$0] }) {
                        // The setting before is heard until the new one is made.
                        entry = before
                        samples[before.heard] = held
                    }
                    guard let entry else { continue }
                    stood[place] = entry
                    voices.set(heard: entry.heard, before: entry.before, forRecording: recordingID, onTrack: track.id)
                }
            }
        }
        work.stood = stood
        // For each track and recording, the voice that is heard and the one before it stay in memory. The rest
        // are read again from disk when they are wanted.
        let kept = Set(stood.values.flatMap { [$0.heard, $0.before].compactMap { $0 } })
        work.samples = work.samples.filter { kept.contains(work.id(of: $0.key)) }

        startWanted(in: project)
        // Every voice in the lookup has its samples here, so this filters nothing: it is the one value every rule
        // of the pass is handed.
        let voiced = VoicedClips(voices: voices.having(samples), samples: samples)
        work.current = voiced
        return voiced
    }

    /// The voices as they were last handed to the player: for the questions that come between two passes (the
    /// safe limit of an edit, the "held back" mark, where a clip is heard first).
    var heard: TrackVoices {
        work.current.voices
    }

    /// The pass as it was last handed to the player, with the voices' samples. The correction asks it outside
    /// a pass, for a slow take's row of voices.
    var current: VoicedClips {
        work.current
    }

    /// The safe limit asked about the sound each clip is read from on its own track: the voices as they were
    /// last heard. The edits that keep a part as loud as it was are handed it beside `peaks`.
    var peaks: RecordingPeak {
        loadedSounds.clipPeaks(with: work.current.samples)
    }

    /// Notes the recordings that are new since the last pass, so their voices are made first: a new take on a
    /// track with a Voice goes to the front of the queue as soon as it has become a clip.
    private func noteNewRecordings(of project: Project) {
        let ids = Set(project.recordings.map(\.id))
        if let seen = work.seenRecordings {
            work.fresh.formUnion(ids.subtracting(seen))
            work.fresh.formIntersection(ids)
        }
        work.seenRecordings = ids
    }

    // MARK: The queue

    /// Starts the voices that are wanted and not there, in the order of `VoiceQueue.order` with the new
    /// takes' recordings first, a few at a time, and cancels the making of every voice that is not wanted
    /// any more. Nothing is started while a take is going or counting in: the Mac's work then belongs to the
    /// recording, and what runs is cancelled.
    private func startWanted(in project: Project) {
        let work = work
        guard takeStatus.phase == nil else {
            cancelMaking(keeping: [])
            followWhenTakeIsOver()
            return
        }
        // Until the project's folder is known, nothing is read or written: the first pass of an opening
        // project comes before the store has its folder.
        guard work.package != nil else { return }
        let sounds = loadedSounds.sounds
        var order = VoiceQueue.order(project, playhead: playhead.seconds, isThere: { key in
            work.samples[key] != nil || work.silent.contains(key) || work.hasFailed(key)
                || sounds[key.recordingID] == nil
        })
        if !work.fresh.isEmpty {
            let first = order.filter { work.fresh.contains($0.recordingID) }
            order = first + order.filter { !work.fresh.contains($0.recordingID) }
        }
        // The voices a row of the Send to DaVinci panel waits for come before everything else.
        if !work.forSend.isEmpty {
            let first = order.filter { work.forSend.contains($0) }
            order = first + order.filter { !work.forSend.contains($0) }
        }
        work.fresh = work.fresh.filter { id in order.contains { $0.recordingID == id } }
        cancelMaking(keeping: Set(order))
        for key in order where work.running.count < VoiceWork.atATime && work.running[key] == nil {
            guard let recording = sounds[key.recordingID] else { continue }
            startMaking(key, from: recording)
        }
    }

    /// Reads one voice from the cache, or makes it when it is not there, away from the main actor.
    private func startMaking(_ key: VoiceKey, from recording: [Float]) {
        let work = work
        let package = work.package
        let session = work.session
        work.running[key] = Task { [weak self] in
            let outcome = await Self.obtain(key, from: recording, in: package)
            self?.voiceArrived(outcome, for: key, session: session, seconds: Double(recording.count) / Lockstep.sampleRate)
        }
    }

    /// What became of one voice.
    enum Outcome: Sendable {
        /// It was on disk, whole and of the right length.
        case read([Float])
        /// It was made and kept, in this many seconds, and turned down this far to stay under full scale.
        case made([Float], took: Double, loweredDb: Double)
        /// The recording is silent: it stands for itself and gets no voice.
        case silent
        /// It could not be made. `refused` when the made voice was refused by `VoiceFile.takeIn`, which is not
        /// tried again until Try Again.
        case failed(String, refused: Bool)
        /// It was cancelled on its way: not wanted any more, or the project is closing.
        case cancelled
    }

    /// The slow part: the voice from the cache, or else made with Rubber Band and taken in. It never runs on
    /// the main actor.
    @concurrent
    private nonisolated static func obtain(_ key: VoiceKey, from recording: [Float], in package: ProjectPackage?) async -> Outcome {
        if let package, let kept = await VoiceFile.read(key, in: package, lengthSamples: recording.count) {
            return .read(kept)
        }
        guard !Task.isCancelled else { return .cancelled }
        guard !VoiceFile.standsForItself(recording) else { return .silent }
        guard let package else { return .cancelled }
        let started = ContinuousClock.now
        let made: [Float]
        do {
            made = try await VoiceMaker.fast(recording, knobs: key.knobs)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed("the voice could not be made (\(error))", refused: false)
        }
        guard !Task.isCancelled else { return .cancelled }
        do {
            let kept = try await VoiceFile.takeIn(MadeVoice(made), for: VoiceJob(key: key, recording: recording, package: package))
            let took = ContinuousClock.now - started
            return .made(kept.samples, took: took.seconds, loweredDb: kept.loweredDb)
        } catch {
            return .failed("the made voice was refused (\(error))", refused: true)
        }
    }

    /// A voice is done, or failed, or was cancelled. A voice of a session that has ended is thrown away. One
    /// that is done is kept in memory, and the clips are handed over again a moment later, which also starts
    /// what waits next.
    private func voiceArrived(_ outcome: Outcome, for key: VoiceKey, session: Int, seconds: Double) {
        let work = work
        guard session == work.session else { return }
        work.running[key] = nil
        switch outcome {
        case .read(let samples):
            work.samples[key] = samples
            work.readCount += 1
            tell(key, "was read from the cache", seconds: seconds)
        case .made(let samples, let took, let loweredDb):
            work.samples[key] = samples
            work.madeCount += 1
            let lowered = loweredDb > 0 ? String(format: ", turned down %.1f dB to stay under full scale", loweredDb) : ""
            tell(key, String(format: "was made in %.2f s", took) + lowered, seconds: seconds)
        case .silent:
            work.silent.insert(key)
            tell(key, "is not made: the recording is silent and stands for itself", seconds: seconds)
        case .failed(let reason, let refused):
            work.failures[key, default: 0] += refused ? VoiceWork.triesBeforeGivingUp : 1
            work.failedCount += 1
            tell(key, "failed: \(reason)" + (work.hasFailed(key) ? ", so the recording is heard" : ", tried again"), seconds: seconds)
        case .cancelled:
            break
        }
        followSoon()
    }

    /// Cancels the making of every voice that is not among these. A cancelled task gives up at its next step.
    private func cancelMaking(keeping wanted: Set<VoiceKey>) {
        for (key, task) in work.running where !wanted.contains(key) {
            task.cancel()
            work.running[key] = nil
        }
    }

    /// Hands the clips over again once the take that holds the making back is over, so the voices that wait
    /// are started then.
    private func followWhenTakeIsOver() {
        guard !work.waitsForTake else { return }
        work.waitsForTake = true
        Task { [weak self] in
            while let self, self.takeStatus.phase != nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self else { return }
            self.work.waitsForTake = false
            self.followSoon()
        }
    }

    /// Hands the clips to the player again 100 ms from now, so the voices that are done close together are
    /// handed over together.
    private func followSoon() {
        let work = work
        guard !work.followIsWaiting else { return }
        work.followIsWaiting = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(VoiceWork.handOverMs))
            guard let self else { return }
            self.work.followIsWaiting = false
            guard self.loadedSounds.song != nil else { return }
            self.followClips(self.store.project)
        }
    }

    /// One line for each voice that is read, made or fails: on standard error in a scratch run, and in the
    /// Mac's log (category `Voice`) in Max's own run too, so how long his voices take can be read afterwards.
    private func tell(_ key: VoiceKey, _ what: String, seconds: Double) {
        let project = store.project
        let track = project.tracks.first { track in
            track.voice?.knobs == key.knobs && track.clips.contains { $0.segments.contains { $0.recordingID == key.recordingID } }
        }
        let line = "the voice of the recording \(key.recordingID.uuidString) on the track \"\(track?.name ?? "none")\" at "
            + "\(key.knobs.folderName) (\(key.way.folderName)), "
            + String(format: "%.2f s of sound, ", seconds) + what
        Self.log.info("\(line, privacy: .public)")
        if LaunchOptions.current.isScratch {
            Agent.tell(line)
        }
    }

    private static let log = Logger(subsystem: "se.maxfahl.lockstep", category: "Voice")
}

extension VoiceModel {
    // MARK: A track's Voice

    /// The switch in the heading of a track's section "Voice" was switched, or "Voice On or Off" was chosen.
    /// A track that never had a Voice is given the first preset, Darker, so the switch is heard at once. One
    /// step that can be undone, "Turn Voice On" or "Turn Voice Off". Nothing happens during a take.
    func switchVoice(of trackID: UUID, on isOn: Bool) {
        guard takeStatus.phase == nil, let track = store.project.track(trackID) else { return }
        var voice = track.voice ?? VoicePresets.builtIn[0].voice
        voice.isOn = isOn
        setVoice(voice, of: trackID, as: isOn ? "Turn Voice On" : "Turn Voice Off")
    }

    /// A line was chosen in the Voice menu of a track: in the panel's box, in the track's right-click menu or
    /// under Track > Voice. Nothing happens during a take.
    func voiceMenu(_ command: VoiceMenu.Command, on trackID: UUID) {
        guard takeStatus.phase == nil, let track = store.project.track(trackID) else { return }
        switch command {
        case .onOrOff:
            switchVoice(of: trackID, on: !(track.voice?.isOn ?? false))
        case .chosen(let name):
            guard let preset = settings[.ownVoicePresets].preset(named: name) else { return }
            setVoice(preset.voice, of: trackID, as: "Choose Voice")
        case .saveAsPreset:
            guard let voice = track.voice else { return }
            let own = VoicePresets.builtIn(named: voice.name) == nil && voice.name != TrackVoice.customName
            guard let name = Self.askPresetName(suggesting: own ? voice.name : "") else { return }
            savePreset(named: name, fromTrack: trackID)
        case .deletePreset(let name):
            if settings.removeOwnVoicePreset(named: name) {
                showOwnPresets()
            }
        }
    }

    /// A knob of a track's Voice was moved. Nothing is made while it is dragged: letting go is the edit, one
    /// step that can be undone, "Change Voice", and the Voice is then "Custom". A track that never had a Voice
    /// gets one, switched on.
    ///
    /// - Parameter value: in the knob's own unit, percent for Depth and semitones for Pitch.
    func turnKnob(_ knob: VoiceKnob, of trackID: UUID, to value: Double, isFinal: Bool) {
        guard isFinal, takeStatus.phase == nil, let track = store.project.track(trackID) else { return }
        var voice = track.voice ?? TrackVoice(knobs: .neutral)
        var knobs = voice.knobs
        switch knob {
        case .depth: knobs.depth = VoiceKnobs.depth(clamped: value)
        case .pitch: knobs.pitch = VoiceKnobs.pitch(clamped: value)
        }
        guard knobs != voice.knobs || track.voice == nil else { return }
        voice.knobs = knobs
        voice.name = TrackVoice.customName
        setVoice(voice, of: trackID, as: "Change Voice")
    }

    /// Whether a command of Track > Voice is what the track has, which ticks its item: "Voice On or Off" while
    /// the Voice is on, and a preset while the track's Voice carries its name, on or off, as the panel's menu
    /// ticks it.
    func isChosen(_ command: AppCommand, on trackID: UUID?) -> Bool {
        guard let voice = trackID.flatMap({ store.project.track($0) })?.voice else { return false }
        if command == .trackVoiceOnOff { return voice.isOn }
        return command.voicePresetName.map { $0 == voice.name } ?? false
    }

    /// "Try Again" was pressed for a track: the voices of its recordings that could not be made are tried again.
    func tryAgain(on trackID: UUID) {
        guard let track = store.project.track(trackID), let knobs = track.voice?.knobs else { return }
        let recordings = Set(track.clips.flatMap { $0.segments.map(\.recordingID) })
        work.failures = work.failures.filter { !($0.key.knobs == knobs && recordings.contains($0.key.recordingID)) }
        followClips(store.project)
    }

    /// Gives a track a Voice as one step that can be undone, when it changes anything, and hands the clips over.
    private func setVoice(_ voice: TrackVoice, of trackID: UUID, as name: String) {
        var probe = store.project
        guard probe.setTrack(trackID, voice: voice) else { return }
        store.edit(name) { $0.setTrack(trackID, voice: voice) }
        followClips(store.project)
    }

    /// Keeps a track's two knobs as one of Max's own presets under this name. The track's Voice then has that
    /// name, so the menu ticks the preset that was just saved: one step that can be undone, "Choose Voice".
    ///
    /// A name that is empty, a built-in preset's or "Custom" is refused, with a message that says why.
    func savePreset(named name: String, fromTrack trackID: UUID) {
        guard takeStatus.phase == nil, var voice = store.project.track(trackID)?.voice else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.saveOwnVoicePreset(named: name, knobs: voice.knobs) else {
            windowState.showAlert(MessageAlert(
                title: "The preset was not saved.",
                detail: name.isEmpty
                    ? "A preset needs a name."
                    : "\u{201C}\(name)\u{201D} is the name of a built-in preset. Choose another name."
            ))
            return
        }
        showOwnPresets()
        voice.name = settings[.ownVoicePresets].preset(named: name)?.name ?? name
        setVoice(voice, of: trackID, as: "Choose Voice")
    }

    /// Asks for the name of a preset with the system's own prompt. Nil when Max cancelled.
    private static func askPresetName(suggesting name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Save as Preset"
        alert.informativeText = "The track's Voice is kept under this name, with its two knobs as they stand, for every project."
        let field = NSTextField(string: name)
        field.placeholderString = "Name"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Hands the window Max's own presets of a Voice, for the Voice menus.
    private func showOwnPresets() {
        let presets = settings[.ownVoicePresets].presets
        if windowState.content.ownVoicePresets != presets {
            windowState.content.ownVoicePresets = presets
        }
    }

    // MARK: What the window shows

    /// Called by `showClips`: gives every track in the rows its Voice and how far its voices have come, for the
    /// section "Voice" of the panel on the right, and dims the section while a take is going.
    ///
    /// The count is `VoiceQueue.progress`: the shown clips that have every voice they need in memory. Clips
    /// whose voice failed are counted apart, and are said once nothing else of the track is being made.
    func showVoice(in rows: inout [TrackRow], of project: Project) {
        let work = work
        let isThere: (VoiceKey) -> Bool = { work.samples[$0] != nil || work.silent.contains($0) }
        for row in rows.indices {
            guard let track = project.track(rows[row].id) else { continue }
            if rows[row].voice != track.voice {
                rows[row].voice = track.voice
            }
            var state = VoiceState.ready
            if let voice = track.voice, voice.isHeard {
                let progress = VoiceQueue.progress(of: track.id, in: project, isThere: isThere)
                if !progress.isComplete {
                    let failed = track.clips.filter { clip in
                        clip.isActiveTake && clip.segments.contains { segment in
                            work.hasFailed(VoiceKey(recordingID: segment.recordingID, knobs: voice.knobs, way: .fast))
                        }
                    }.count
                    state = progress.done + failed < progress.clips
                        ? .making(done: progress.done, of: progress.clips)
                        : .failed(clips: failed)
                }
            }
            if rows[row].voiceState != state {
                rows[row].voiceState = state
            }
        }
        let canChange = takeStatus.phase == nil
        if windowState.content.canChangeVoice != canChange {
            windowState.content.canChangeVoice = canChange
        }
    }
}

extension VoiceModel {
    // MARK: Sending

    /// What one clip is sent in with "With sound" on.
    enum ForSend {
        /// It can be sent now, read from these: the voices of its track's setting for its recordings, with
        /// their samples, or `.none` on a track whose Voice is not heard.
        case ready(VoicedClips)
        /// The voice of one of its recordings could not be made: the clip is sent in Max's own voice, all of
        /// it, so the file is what its row says.
        case failed
        /// A voice it needs is still being read or made: its row waits without a file. `progress` is the
        /// share of its recordings whose voice is there, for a clip that plays more than one, and nil for one.
        case making(progress: Double?)
    }

    /// What one clip is sent in with "With sound" on: the voice of its track's setting for every recording it
    /// plays, not the setting before it, which may still be heard while the new one is made. Nothing is made
    /// or waited for here. A silent recording, and one that is not loaded, is read as it is.
    func forSend(_ clip: Clip, on track: Track) -> ForSend {
        guard let voice = track.voice, voice.isHeard else { return .ready(.none) }
        let work = work
        var voices = TrackVoices.none
        var samples: [UUID: [Float]] = [:]
        var missing = 0
        let recordings = Array(Set(clip.segments.map(\.recordingID)))
        for recordingID in recordings {
            let key = VoiceKey(recordingID: recordingID, knobs: voice.knobs, way: .fast)
            if work.hasFailed(key) { return .failed }
            if let made = work.samples[key] {
                let id = work.id(of: key)
                voices.set(heard: id, before: nil, forRecording: recordingID, onTrack: track.id)
                samples[id] = made
            } else if !work.silent.contains(key), loadedSounds.sounds[recordingID] != nil {
                missing += 1
            }
        }
        guard missing == 0 else {
            let progress = recordings.count > 1 ? Double(recordings.count - missing) / Double(recordings.count) : nil
            return .making(progress: progress)
        }
        return .ready(VoicedClips(voices: voices, samples: samples))
    }

    /// The clips the Send to DaVinci panel waits for: the voices they need are made before every other, and
    /// started at once. An empty list when the panel closes: the queue goes on in its own order, for the
    /// track's sake.
    func putFirstForSend(_ clips: [(clip: Clip, track: Track)]) {
        var keys: Set<VoiceKey> = []
        for (clip, track) in clips {
            guard let voice = track.voice, voice.isHeard else { continue }
            for segment in clip.segments {
                keys.insert(VoiceKey(recordingID: segment.recordingID, knobs: voice.knobs, way: .fast))
            }
        }
        guard keys != work.forSend else { return }
        work.forSend = keys
        guard !keys.isEmpty else { return }
        startWanted(in: store.project)
    }
}

extension VoiceModel {
    // MARK: A project opens and closes

    /// A song or a project is about to be shown in place of what was open: the voices in memory, and what
    /// stood in, belonged to the old one. What the window shows was just made anew, so it is handed Max's
    /// presets again.
    func projectWillOpen() {
        showOwnPresets()
        work.session += 1
        cancelMaking(keeping: [])
        work.samples = [:]
        work.ids = [:]
        work.keys = [:]
        work.stood = [:]
        work.silent = []
        work.failures = [:]
        work.fresh = []
        work.forSend = []
        work.seenRecordings = nil
        work.current = .none
        work.package = nil
    }

    /// The project is open in this folder: its voices are read from the cache, and the missing ones queued,
    /// with a pass through the clips. The store hands the clips over once while it opens, before it knows the
    /// folder, so that pass starts nothing.
    func projectOpened(in package: ProjectPackage) {
        work.package = package
        followClips(store.project)
    }

    /// The open project is closed for good, as it is now: the session ends, what is being made is cancelled,
    /// and once it has let go of its files (a second at most) the voices folder is tidied (`VoiceFiles.stale`):
    /// partial files, voices of recordings the project no longer holds, old ways, and settings no track has.
    func projectWillClose(_ project: Project, in package: ProjectPackage) {
        work.session += 1
        work.package = nil
        let running = Array(work.running.values)
        cancelMaking(keeping: [])
        guard !running.isEmpty else {
            Self.tidy(package, of: project)
            return
        }
        Task.detached {
            await Self.waitForCancelled(running)
            Self.tidy(package, of: project)
        }
    }

    /// Whether voices are being made right now. Quit waits for them to let go first (`stopMaking`).
    var isMaking: Bool {
        !work.running.isEmpty
    }

    /// Cancels every voice that is being made and waits until each has let go of its files, a second at most.
    /// Quit calls it, so the voices folder is tidied when the project closes right after.
    func stopMaking() async {
        let running = Array(work.running.values)
        cancelMaking(keeping: [])
        await Self.waitForCancelled(running)
    }

    /// Waits until these cancelled tasks have ended, or a second has gone by.
    private nonisolated static func waitForCancelled(_ tasks: [Task<Void, Never>]) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for task in tasks { await task.value }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Removes what `VoiceFiles.stale` says from the project's voices folder.
    private nonisolated static func tidy(_ package: ProjectPackage, of project: Project) {
        let folder = package.voicesFolder
        guard let listing = try? FileManager.default.subpathsOfDirectory(atPath: folder.path) else { return }
        for path in VoiceFiles.stale(in: listing, of: project) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(path))
        }
    }
}

extension VoiceModel {
    // MARK: For an agent's run

    /// Does what `-trackVoice` asks, once the first project is open and the takes given with `-addTake` are in
    /// it, and says on standard error how it went. The correction's own launch arguments wait for it
    /// (`launchVoiced`), so `-tighten`, `-strength` and `-stretch` act on clips that have their voices, and
    /// everything that waits for them waits for this too.
    func voiceLaunchTrack() {
        guard work.launch == nil, let value = LaunchOptions.current.trackVoice else { return }
        work.launch = Task { [weak self] in
            await self?.takeStatus.ended()
            guard let line = await self?.voiceFirstTrackForAgent(value) else { return }
            Agent.tell(line)
        }
    }

    /// Waits until what `-trackVoice` asked for is done. Returns at once when it was not given.
    func launchVoiced() async {
        await work.launch?.value
    }

    /// Does what `-trackVoiceOff` asks, after everything else an agent's run asked for: switches the first
    /// track's Voice off through the code of the switch, and says so.
    func voiceOffLaunchTrack(after others: @escaping () async -> Void) {
        guard LaunchOptions.current.trackVoiceOff, work.offLaunch == nil else { return }
        work.offLaunch = Task { [weak self] in
            await self?.takeStatus.ended()
            await self?.launchVoiced()
            await others()
            guard let self, let track = self.store.project.tracks.first else { return }
            // The voices the track's clips need are read or made first, so the line can say they were there
            // and the switch is heard to take them away.
            let deadline = ContinuousClock.now + .seconds(600)
            while !self.voicesAreThere(ofTrack: track.id), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            self.switchVoice(of: track.id, on: false)
            let voice = self.store.project.track(track.id)?.voice
            Agent.tell(
                "switched the Voice of the track \"\(track.name)\" off: "
                    + (voice.map { "it keeps \"\($0.name)\" at \($0.knobs.folderName), on: \($0.isOn)" } ?? "it has no Voice")
                    + ", \(self.work.current.voices.isHeard(on: self.store.project.track(track.id) ?? track) ? "a voice is still heard" : "the recordings are heard")"
                    + ", undo step: \(self.store.undoTitle ?? "none")"
            )
        }
    }

    /// Does what `-trackVoice` asks and gives the line that says how it went: a preset's name, or knobs as
    /// `depth=8,pitch=-1.5`, through the code of the panel's menu and knobs. It waits until the voices of the
    /// track's shown clips are there, ten minutes at most.
    private func voiceFirstTrackForAgent(_ value: String) async -> String {
        let refusal = "could not give the first track the Voice \"\(value)\": "
        guard loadedSounds.song != nil, takeStatus.phase == nil, let track = store.project.tracks.first else {
            return refusal + "the song is not ready"
        }
        let madeBefore = work.madeCount
        let readBefore = work.readCount
        let started = ContinuousClock.now
        if let preset = settings[.ownVoicePresets].preset(named: value) {
            voiceMenu(.chosen(preset.name), on: track.id)
        } else if let knobs = Self.knobs(from: value) {
            turnKnob(.depth, of: track.id, to: Double(knobs.depth), isFinal: true)
            turnKnob(.pitch, of: track.id, to: knobs.pitch, isFinal: true)
        } else {
            return refusal + "it is neither a preset ("
                + (VoicePresets.builtIn + settings[.ownVoicePresets].presets).map(\.name).joined(separator: ", ")
                + ") nor knobs such as depth=8,pitch=-1.5"
        }
        let deadline = started + .seconds(600)
        while !voicesAreThere(ofTrack: track.id) {
            guard ContinuousClock.now < deadline else { return refusal + "the voices were not made in ten minutes" }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let took = (ContinuousClock.now - started).seconds
        let project = store.project
        guard let voice = project.track(track.id)?.voice else { return refusal + "the track has no Voice" }
        let progress = VoiceQueue.progress(of: track.id, in: project, isThere: { self.work.samples[$0] != nil || self.work.silent.contains($0) })
        let made = work.madeCount - madeBefore
        let read = work.readCount - readBefore
        return "gave the track \"\(track.name)\" the Voice \"\(voice.name)\": depth \(voice.knobs.depth) %, "
            + "pitch \(voice.knobs.pitch) st, \(voice.knobs.folderName) (\(VoiceWay.fast.folderName)), "
            + "\(progress.done) of \(progress.clips) \(progress.clips == 1 ? "clip has" : "clips have") its voice, "
            + "\(made) \(made == 1 ? "voice" : "voices") made and \(read) read from the cache "
            + String(format: "in %.2f s", took)
            + ", undo step: \(store.undoTitle ?? "none")"
    }

    /// Knobs written as `depth=8,pitch=-1.5`, either one left out for the middle. Nil when it is not that.
    private static func knobs(from value: String) -> VoiceKnobs? {
        var knobs = VoiceKnobs.neutral
        var any = false
        for part in value.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard pair.count == 2, let number = Double(pair[1]) else { return nil }
            switch pair[0] {
            case "depth": knobs.depth = VoiceKnobs.depth(clamped: number)
            case "pitch": knobs.pitch = VoiceKnobs.pitch(clamped: number)
            default: return nil
            }
            any = true
        }
        return any ? knobs : nil
    }

    /// Whether every voice the track's shown clips need is in memory (or failed, or stands for itself), and the
    /// player was handed them.
    private func voicesAreThere(ofTrack trackID: UUID) -> Bool {
        let project = store.project
        guard let track = project.track(trackID), let voice = track.voice, voice.isHeard else { return true }
        let progress = VoiceQueue.progress(of: trackID, in: project, isThere: { key in
            self.work.samples[key] != nil || self.work.silent.contains(key) || self.work.hasFailed(key)
        })
        return progress.isComplete && !work.followIsWaiting && work.running.isEmpty
            && work.current.voices.isHeard(on: track) == (progress.clips > 0 && !work.samples.isEmpty)
    }

    /// What the Quit line of a scratch run says about voices (`RunCounts`), or nil when this run never had a
    /// track with a Voice heard.
    var countsForAgent: String? {
        guard work.madeCount + work.readCount + work.failedCount > 0 || work.hadVoices else { return nil }
        return "\(work.madeCount) \(work.madeCount == 1 ? "voice" : "voices") made the Fast way (\(VoiceWay.fast.folderName)), "
            + "\(work.readCount) read from the cache, \(work.failedCount) failed"
    }
}

/// What the model keeps for voices: the ones in memory, the ones being made, and what stood in for which
/// recording on which track last. Nothing in the window watches it.
@MainActor
final class VoiceWork {
    /// How many voices are made at the same time: half the Mac's performance cores, at least one.
    static let atATime: Int = {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
            cores = Int32(ProcessInfo.processInfo.activeProcessorCount)
        }
        return max(Int(cores) / 2, 1)
    }()
    /// How long the player waits for more voices before it is handed the ones that are done, in milliseconds.
    static let handOverMs = 100
    /// How many times the making of a voice may fail before it is left until Try Again.
    static let triesBeforeGivingUp = 2

    /// The voices in memory, by what they are.
    var samples: [VoiceKey: [Float]] = [:]
    /// The id each voice stands in under, among the recordings' samples, for the open project. A voice keeps
    /// its id while the project is open, so the player knows it as the same sound.
    var ids: [VoiceKey: UUID] = [:]
    var keys: [UUID: VoiceKey] = [:]
    /// The recordings that are silent with a setting: they stand for themselves.
    var silent: Set<VoiceKey> = []
    /// How many times the making of a voice failed.
    var failures: [VoiceKey: Int] = [:]
    /// The voices being read or made, each by a task of its own.
    var running: [VoiceKey: Task<Void, Never>] = [:]
    /// What stood in for which recording on which track in the last pass.
    var stood: [TrackVoices.Key: TrackVoices.Entry] = [:]
    /// The last pass's answer.
    var current = VoicedClips.none
    /// The number of the open project's session. A voice that arrives for an earlier one is thrown away.
    var session = 0
    /// The folder of the open project, where its voices are kept. Nil until it is open.
    var package: ProjectPackage?
    /// The recordings of the last pass, and those that came since and are made first.
    var seenRecordings: Set<UUID>?
    var fresh: Set<UUID> = []
    /// The voices a row of the open Send to DaVinci panel waits for, made before every other.
    var forSend: Set<VoiceKey> = []
    /// True while a handing over of the clips is waiting to happen.
    var followIsWaiting = false
    /// True while a pass waits for the take to be over.
    var waitsForTake = false
    /// What `-trackVoice` and `-trackVoiceOff` asked for, while it is going on and after.
    var launch: Task<Void, Never>?
    var offLaunch: Task<Void, Never>?
    /// Counts for the Quit line of a scratch run.
    var madeCount = 0
    var readCount = 0
    var failedCount = 0
    /// True once a track with a heard Voice was seen in this run.
    var hadVoices: Bool { !ids.isEmpty || madeCount + readCount > 0 }

    /// The id a voice stands in under, made the first time it is asked for.
    func id(of key: VoiceKey) -> UUID {
        if let id = ids[key] { return id }
        let id = UUID()
        ids[key] = id
        keys[id] = key
        return id
    }

    /// The voice an id stands for, or nil for an id that is no voice's.
    func key(of id: UUID) -> VoiceKey? {
        keys[id]
    }

    /// Whether a voice is left alone until Try Again: its making failed twice, or the made voice was refused.
    func hasFailed(_ key: VoiceKey) -> Bool {
        failures[key, default: 0] >= Self.triesBeforeGivingUp
    }
}

extension Duration {
    /// The duration in seconds, as a number.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

extension AppModel {
    /// Gives `voice` its closures. `wire()` calls it once, when every part is made.
    func wireVoice() {
        voice.followClips = { [weak self] project in self?.clips.followClips(of: project) }
    }
}

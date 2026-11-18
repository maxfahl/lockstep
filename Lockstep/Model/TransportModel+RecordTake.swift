import Foundation
import LockstepAudio
import LockstepCore

// A take without a microphone (`-recordTake <wav file>`, in a run with `-scratch` and `-open`).
//
// An agent cannot press Record and must never open the microphone, so until phase 29 no agent's
// run went through the code that records. With `-recordTake` the app presses the keys itself and
// the recorder hears a sound file:
//
// - The model's recorder is the one `FileMicrophone` made: the recorder's own made-up microphone
//   (`Recorder.init(offlineInput:sampleRate:)`), an audio engine connected to no sound device. The
//   real microphone is never opened, and `MicrophoneAccess.mayRecord` answers "allowed" without
//   asking macOS, because there is nothing to allow.
// - The keys are pressed through `perform`, as the menu and the keyboard press them: Record, then
//   Record again twice for two restarts, then Play or Stop. So the take goes through
//   `recordOrRestart`, `startTake`, `followPlayback`, `restartTake`, `stopTake` and `keep` with
//   not one line of them written for this.
// - Nothing feeds a made-up microphone by itself. While an attempt is going, `feed` hands the
//   recorder the next blocks of the file as time goes, 1,024 samples at a time, so the red clip
//   and the level meter get their sound the way they do from a microphone.
//
// What one run does, once the song is open, its beats are found (or could not be) and the other
// launch arguments have acted:
//
// 1. Record at the playhead (`-playhead` chooses where). The count-in is the one the scratch
//    folder's settings say, one bar unless they say otherwise.
// 2. The first attempt: the count-in, then 3 seconds of recording. Record again: a restart, with
//    "When restarting, keep the dropped attempt" as the scratch folder's settings have it (off in
//    a fresh folder, so the attempt is thrown away).
// 3. The second attempt, the same length. Record again, this time with that setting switched on
//    for the press, so the attempt becomes a clip while the third one is counted in. The setting
//    is put back at once.
// 4. The third attempt, the same length. Play or Stop: the take ends and becomes a clip.
//
// The file is what the microphone hears from the first press of Record until Stop, the count-ins
// included, and it starts over when it ends. Every attempt is fed the same number of samples in
// every run, so which part of the file each attempt holds is always the same.
//
// What it does not reach: a take's place against the clock. A block of sound from a real
// microphone says when it was heard. A block from the made-up one does not, and the recorder then
// takes it to have been heard at the moment it arrived, which is the moment this file fed it. So
// a recording is placed in the song about where a real one would be, give or take the few
// milliseconds this file's clock is off, and the places in the lines below differ by that much
// from run to run (3 and 12 ms between two runs on 15 November 2026). How many samples each
// attempt holds does not differ. A clip's length is the same too as long as its ends are set by
// where the voice is, and differs by those milliseconds when its start is set by the place.

/// The sound file given with `-recordTake`, standing where the microphone would.
@MainActor
final class FileMicrophone {
    /// The file of this run, or nil in every run without `-recordTake`. It is made the first time
    /// it is asked for, which is when the model makes its recorder.
    static let current: FileMicrophone? = LaunchOptions.current.recordTake.map { FileMicrophone(url: $0) }

    /// The file that was given.
    let url: URL
    /// The recorder that hears the file and never opens the microphone, or nil when the file
    /// cannot be used. The model then has its usual recorder, and nothing presses Record.
    let recorder: Recorder?
    /// Why the file cannot be used, or nil when it can.
    let failure: String?
    /// True once the take `-recordTake` asked for was started, or could not be.
    var launchTaken = false

    /// How much sound the recorder is given at least, in seconds: more than three attempts take
    /// with the longest count-in on a slow song. A shorter file is heard over and over.
    private static let shortestSoundSeconds = 120.0

    private init(url: URL) {
        self.url = url
        do {
            let file = try RecordingLoader.read(url)
            guard !file.isEmpty else {
                recorder = nil
                failure = "the file holds no sound"
                return
            }
            var sound = file
            let needed = Int(Self.shortestSoundSeconds * Lockstep.sampleRate)
            sound.reserveCapacity(max(needed + file.count, file.count))
            while sound.count < needed {
                sound.append(contentsOf: file)
            }
            recorder = try Recorder(offlineInput: [sound], sampleRate: Lockstep.sampleRate)
            failure = nil
        } catch let error as RecordingLoadError {
            recorder = nil
            failure = error == .wrongSampleRate ? "the file is not at 48,000 Hz" : "the file could not be read as sound"
        } catch {
            recorder = nil
            failure = "no recorder could be made for it"
        }
    }
}

extension TransportModel {
    /// How long each attempt records after its count-in, in seconds.
    private static let recordedSeconds = 3.0
    /// How many samples the recorder is fed at a time: what the microphone is asked to deliver at a
    /// time (`Recorder.tapFrames`).
    private static let fedBlock = 1_024
    /// How many attempts the take has: the first, and one after each of the two restarts.
    private static let attemptCount = 3

    /// Makes the take `-recordTake` asks for, once the first project is open, and says on standard
    /// error how it went.
    func recordLaunchTake() {
        guard let microphone = FileMicrophone.current, !microphone.launchTaken else { return }
        microphone.launchTaken = true
        Task {
            await takeStatus.ended()
            await recordTakeForAgent(with: microphone)
        }
    }

    /// Does what `-recordTake` asks: presses Record, feeds the file while the take is going,
    /// presses Record twice more and then Stop, with one line on standard error for each restart
    /// and one for the end, or one that says why it could not be done. The line for the start of
    /// the take is the model's own, as for every take in a scratch run.
    private func recordTakeForAgent(with microphone: FileMicrophone) async {
        let refusal = "could not record a take from \(microphone.url.path): "
        guard let recorder = microphone.recorder else {
            return Self.tellAgentAboutTake(refusal + (microphone.failure ?? "the file cannot be used"))
        }
        // Record aims at the beat nearest the playhead and counts in on the beats, so the beats come
        // first, and with them what `-loop`, `-tighten` and `-strength` asked for.
        for _ in 0..<240 where beats.beatFinding != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        await loop.launchLoopIsOn()
        await correction.launchTightened()
        // The playhead is moved by a task of its own once the takes are in.
        try? await Task.sleep(for: .milliseconds(500))
        await player.hasDoneItsOrders()
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil, canPerform(.record) else {
            return Self.tellAgentAboutTake(refusal + "the song is not ready")
        }
        // An app that was started behind the other windows is slowed down like a resting app, and
        // the sound would then be fed in bursts.
        let inUse = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Recording a take from a file"
        )
        defer { ProcessInfo.processInfo.endActivity(inUse) }

        // A take recorded slower says so in every line: what an attempt held is slow, and its clip is at
        // full tempo, shorter by the speed.
        let speed = slowTake.speed
        let atSpeed = speed.isSlow ? String(format: " at %.0f %% of the song's speed", speed.rate * 100) : ""
        var recordingsBefore = allRecordingIDs
        perform(.record)
        // Record first asks whether the microphone may be used, which takes a turn of the main thread.
        // With a slower speed (`-recordSpeed`) it also waits for the slow song to be made.
        for _ in 0..<(slowTake.speed.isSlow ? 6_000 : 300) where takeStatus.phase == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await player.hasDoneItsOrders()
        guard takeStatus.flow.isGoing, !takeStatus.flow.isStarting else {
            return Self.tellAgentAboutTake(refusal + "Record did not start a take" + alertWords)
        }

        for attempt in 1...Self.attemptCount {
            guard let origin = takeStatus.flow.origin else { break }
            // The count-in and the seconds after it, in whole blocks, the same in every run. The origin
            // is song time. In a take recorded slower the count-in lasts longer by the take's speed.
            let rate = take?.countIn.slow.rate ?? 1
            let wanted = ((origin.seconds - origin.runUpStart) / rate + Self.recordedSeconds) * Lockstep.sampleRate
            let frames = Int((wanted / Double(Self.fedBlock)).rounded(.up)) * Self.fedBlock
            let fed = await feed(frames, to: recorder, during: attempt)
            let held = recorder.snapshot().lengthSamples
            guard fed, takeStatus.flow.isGoing, takeStatus.flow.attempt == attempt else {
                // The song reached its end, a sound device changed, or the file could not be fed.
                await player.hasDoneItsOrders()
                return Self.tellAgentAboutTake(
                    "the take ended by itself in attempt \(attempt), which held \(held) samples\(atSpeed) and "
                        + fate(ofRecordingsNewSince: recordingsBefore, kept: true, slow: speed.isSlow) + alertWords
                )
            }
            if attempt < Self.attemptCount {
                // The first restart does what the scratch folder's settings say about the attempt.
                // The second keeps it, so one run goes through both.
                let keeps = settings[.restartKeepsAttempt]
                let isKept = keeps || attempt == Self.attemptCount - 1
                if isKept != keeps { settings[.restartKeepsAttempt] = isKept }
                perform(.record)
                if isKept != keeps { settings[.restartKeepsAttempt] = keeps }
                await player.hasDoneItsOrders()
                let line = "restarted the take: attempt \(attempt) held \(held) samples\(atSpeed) and "
                    + fate(ofRecordingsNewSince: recordingsBefore, kept: isKept, slow: speed.isSlow)
                recordingsBefore = allRecordingIDs
                guard takeStatus.flow.isGoing, takeStatus.flow.attempt == attempt + 1, !takeStatus.flow.isStarting else {
                    await player.hasDoneItsOrders()
                    return Self.tellAgentAboutTake(line + ", and the take did not go on" + alertWords)
                }
                Self.tellAgentAboutTake(line)
            } else {
                perform(.playStop)
                // The ending of a take is the last thing the player was told.
                await player.hasDoneItsOrders()
                Self.tellAgentAboutTake(
                    "stopped the take: attempt \(attempt) held \(held) samples\(atSpeed) and "
                        + fate(ofRecordingsNewSince: recordingsBefore, kept: true, slow: speed.isSlow)
                        + (takeStatus.phase == nil ? "" : ", and the take did not end") + alertWords
                )
            }
        }
    }

    /// Hands the recorder the next `frames` samples of the file as time goes, a block at a time,
    /// then waits until the song has come to the place recording starts and until the recorder has
    /// taken in everything it was handed.
    ///
    /// - Returns: false when the attempt ended before it was fed: the take was stopped by something
    ///   else, or the recorder could not be fed.
    private func feed(_ frames: Int, to recorder: Recorder, during attempt: Int) async -> Bool {
        let clock = ContinuousClock()
        let began = clock.now
        var fed = 0
        while fed < frames {
            guard takeStatus.flow.isGoing, takeStatus.flow.attempt == attempt else { return false }
            let passed = (clock.now - began).components
            let seconds = Double(passed.seconds) + Double(passed.attoseconds) * 1e-18
            let due = min(frames, Int(seconds * Lockstep.sampleRate) / Self.fedBlock * Self.fedBlock)
            while fed < due {
                do {
                    try recorder.renderOffline(frames: Self.fedBlock)
                } catch {
                    return false
                }
                fed += Self.fedBlock
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        // The song was started a moment after the first block was fed, so it reaches the place a
        // moment after the count-in's samples are in.
        for _ in 0..<300 where takeStatus.phase == .runningUp {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // The engine hands a block on a moment after it was asked for, and the recorder takes it in
        // on a queue of its own. Nothing is pressed until that has come to rest.
        var held = recorder.snapshot().lengthSamples
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            let now = recorder.snapshot().lengthSamples
            if now == held { break }
            held = now
        }
        return takeStatus.flow.isGoing && takeStatus.flow.attempt == attempt && takeStatus.phase == .recording
    }

    /// The ids of every recording of the open project.
    private var allRecordingIDs: Set<UUID> {
        Set(store.project.recordings.map(\.id))
    }

    /// What became of an attempt, for the line on standard error: the clips of the recordings that
    /// are new in the project, each with its place and its length, or that there is none. A clip is
    /// known by its recording and not by being new, because what is left of a clip that gave way to
    /// the take is a new clip too.
    ///
    /// - Parameters:
    ///   - before: the recordings the project had before the attempt could become a clip.
    ///   - kept: whether the attempt was to become a clip. False for one a restart threw away.
    ///   - slow: whether the take was recorded slower. The clip's length is then said to be at full tempo.
    private func fate(ofRecordingsNewSince before: Set<UUID>, kept: Bool, slow: Bool) -> String {
        let clips = store.project.tracks.flatMap(\.clips).filter { clip in
            clip.segments.contains { !before.contains($0.recordingID) }
        }
        guard !clips.isEmpty else { return kept ? "left no clip" : "was thrown away" }
        let described = clips.map { clip -> String in
            let start = store.project.start(of: clip) ?? 0
            let end = store.project.end(of: clip) ?? 0
            let length = clip.segments.reduce(0) { $0 + $1.outSample - $1.inSample }
            return String(format: "a clip from %.3f s to %.3f s", start, end)
                + ", at sample \(Int((start * Lockstep.sampleRate).rounded())) of the song and \(length) samples long"
                + (slow ? " at full tempo" : "")
                + ", take \(store.project.takeNumber(of: clip.id) ?? 1) of \(store.project.takeCount(of: clip.id))"
        }
        return "became " + described.joined(separator: "; ") + " (undo: \(store.undoTitle ?? "none"))"
    }

    /// The title of the alert that is open, for a line that says something went wrong.
    private var alertWords: String {
        windowState.showsAlert ? " (the window says: \(windowState.alert.title))" : ""
    }

    /// One line on standard error, for the agent that started Lockstep.
    private static func tellAgentAboutTake(_ line: String) {
        FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
    }
}

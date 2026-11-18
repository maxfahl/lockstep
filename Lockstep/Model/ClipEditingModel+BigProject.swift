import AppKit
import Foundation
import LockstepAudio
import LockstepCore

// The big test project, in an agent's run: `-bigProject` fills the opened song's project up to a size like
// Max's own (`BigTestProject` says what it holds), so an edit can be timed in a project that is big enough
// to be slow. It is part of `ClipEditingModel`, as `-deleteClip` is, and in every build.
//
// Every take of it is put in as a finished take is: its sound and its waveform are loaded
// (`loadedSounds`), its syllables are found (`correction.findMarkers(ofRecording:sound:)`), and its clip
// goes into the project as one edit. Two things are done differently, to keep the building short:
//
// - The loudness curve and the syllables of a recording are worked out once for each of the twelve made-up
//   voices and written into the project's cache for every recording that is that voice, where the search
//   for syllables finds them. Six hundred and fifty recordings would otherwise be listened through one by
//   one, though only twelve of them differ.
// - The words of a clip are in the clip when it is added, where a finished transcription puts them
//   (`Clip.text`). `-clipText` hands its words over the way the speech model's answer comes, which shows
//   every clip in the window again for each clip that gets words.
//
// The clips are added once the syllables of every recording are known, so each tightened sound is made
// once. Then it waits until every one of them is made, and says on standard error what the project holds
// and how long the building took.
extension ClipEditingModel {
    /// Builds what `-bigProject` asks for, once the first project is open, the takes given with `-addTake`
    /// are in it and what `-tighten` and `-strength` asked for is done.
    func buildLaunchBigProject() {
        guard bigProjectLaunch == nil, LaunchOptions.current.buildsBigProject else { return }
        bigProjectLaunch = Task {
            await takeStatus.ended()
            await launchTightened()
            Self.tellAgentAboutEdit(await buildBigProjectForAgent())
        }
    }

    /// One of the made-up voices with everything that is worked out from its sound once.
    private struct MadeUpVoice: Sendable {
        var samples: [Float]
        var waveform: WaveformPyramid
        var envelope: VoiceEnvelope
        var markers: [LockstepCore.SyllableMarker]
    }

    /// Does what `-bigProject` asks and gives the line that says how it went.
    private func buildBigProjectForAgent() async -> String {
        let refusal = "could not build the big project: "
        // The lines slide toward the song's sub-beats, so the clips wait for the beats.
        for _ in 0..<240 where store.project.grid == nil || beatsAreBeingFound() {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil, store.project.grid != nil,
              let package = store.package
        else { return refusal + "the song is not ready" }
        let started = ContinuousClock.now
        tracks.stopRenamingTrack()
        stopRenamingClip()

        let voices: [MadeUpVoice]
        let plan: BigTestProject.Plan
        do {
            voices = try await Self.madeUpVoices(in: package)
            plan = BigTestProject.plan(for: store.project, voiceLengths: voices.map(\.samples.count))
            try await Self.writeCaches(of: plan.takes.map { ($0.recording.id, $0.voice) }, voices: voices, in: package)
        } catch {
            return refusal + "its sound could not be written into the project: \(error.localizedDescription)"
        }
        for take in plan.takes {
            let voice = voices[take.voice]
            loadedSounds.sounds[take.recording.id] = voice.samples
            loadedSounds.waveforms[take.recording.id] = voice.waveform
            correction.findMarkers(ofRecording: take.recording.id, sound: voice.samples)
        }
        let recordingIDs = plan.recordings.map(\.id)
        guard await waitForAgent(seconds: 120, until: { model in
            recordingIDs.allSatisfy { model.correction.hasMarkers(ofRecording: $0) }
        }) else { return refusal + "the syllables of its recordings were not found" }

        let peaks = loadedSounds.clipPeaks
        store.edit("Add Big Test Project") { BigTestProject.add(plan, to: &$0, peaks: peaks) }
        followClips(store.project)
        guard await soundsSettle(within: 900) else { return refusal + "the tightened sounds were not made" }

        let project = store.project
        let clips = project.tracks.flatMap(\.clips)
        let shown = clips.count(where: \.isActiveTake)
        let syllables = clips.reduce(0) { $0 + correction.markers(in: $1).count }
        let took = ContinuousClock.now - started
        let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        let isVisible = NSApplication.shared.windows.contains { $0.occlusionState.contains(.visible) }
        return "built the big project: \(project.tracks.count) tracks "
            + "(\(project.tracks.count(where: \.muted)) muted), \(shown) clips shown, "
            + "\(clips.count - shown) takes waiting behind them, \(project.recordings.count) recordings, "
            + "\(syllables) syllables in the clips, \(clips.count(where: { $0.tighten == .lines })) clips on Lines "
            + "and \(clips.count(where: { $0.tighten == .all })) on All, "
            + "\(clips.count(where: { $0.segments.count > 1 })) cut and joined, "
            + String(format: "in %.1f s", seconds) + " (window \(isVisible ? "visible" : "hidden"))"
    }

    /// Makes the twelve voices, writes each into the project's takes folder, and works out what is read
    /// from a recording's sound once: its waveform, its loudness curve and its syllables. Away from the
    /// main thread, as the same work on a real take is.
    @concurrent
    private nonisolated static func madeUpVoices(in package: ProjectPackage) async throws -> [MadeUpVoice] {
        try FileManager.default.createDirectory(at: package.takesFolder, withIntermediateDirectories: true)
        return try BigTestProject.voices().enumerated().map { index, samples in
            try WavWriter.write(samples, channels: 1, to: package.url.appendingPathComponent(BigTestProject.voiceFile(index)))
            let envelope = VoiceEnvelope.envelope(of: samples)
            return MadeUpVoice(
                samples: samples,
                waveform: WaveformPyramid(interleaved: samples, channelCount: 1),
                envelope: envelope,
                markers: SyllableDetector.markers(in: envelope)
            )
        }
    }

    /// Writes the loudness curve and the syllables of every recording into the project's cache, where the
    /// search for syllables and the making of the tightened sounds read them.
    @concurrent
    private nonisolated static func writeCaches(
        of recordings: [(id: UUID, voice: Int)],
        voices: [MadeUpVoice],
        in package: ProjectPackage
    ) async throws {
        for recording in recordings {
            let voice = voices[recording.voice]
            try voice.envelope.write(forRecording: recording.id, to: package)
            try package.writeMarkers(voice.markers, forRecording: recording.id, version: SyllableDetector.version)
        }
    }

    // MARK: Waiting

    /// Waits until no tightened sound is being made or waited for. False when that took too long.
    ///
    /// A sound that is done is handed to the player a moment later, and that can ask for another, so it
    /// must hold two times in a row.
    func soundsSettle(within seconds: Double) async -> Bool {
        var wasSettled = false
        return await waitForAgent(seconds: seconds, every: .milliseconds(100)) { model in
            let isSettled = model.correction.soundsAreSettled
            defer { wasSettled = isSettled }
            return isSettled && wasSettled
        }
    }

    /// Looks again and again whether something has happened, for so many seconds at most.
    private func waitForAgent(
        seconds: Double,
        every pause: Duration = .milliseconds(50),
        until isDone: (ClipEditingModel) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !isDone(self) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: pause)
        }
        return true
    }
}

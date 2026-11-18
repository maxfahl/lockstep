import AVFoundation
import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// These tests run the recorder's real audio engine and the real block that receives the microphone's sound, but
/// without a microphone: the engine is made "offline", connected to no sound device, and its microphone is sound the
/// test made up. Nothing is recorded and macOS asks for no permission.
///
/// The engine calls the receiving block itself, as it does in the app. That is where a block that breaks the audio
/// callback rule in AGENTS.md goes wrong.
///
/// Only the last test opens the real microphone, and it runs only when `LOCKSTEP_MIC=1` is set.
@Suite("Recorder")
struct RecorderTests {
    /// Made-up sound whose samples say where they are: sample `n` is `(n + 1) / 65536` on the first channel.
    /// The second channel is a steady -0.5, so it cannot be mistaken for the first.
    static func microphoneSound(samples count: Int) -> [[Float]] {
        [(0..<count).map { Float($0 + 1) / 65_536 }, [Float](repeating: -0.5, count: count)]
    }

    @Test("Sound from the engine reaches the take's file through the real receiving block, without a crash")
    func soundFromTheEngineReachesTheFile() async throws {
        let project = try TakeProject()
        defer { project.remove() }
        let sound = Self.microphoneSound(samples: 48_000)
        let recorder = try Recorder(offlineInput: sound, sampleRate: 48_000)
        #expect(recorder.snapshot() == RecorderSnapshot())

        let id = try await recorder.start(in: project.package)
        #expect(recorder.snapshot().isRecording)
        // The song is "started" from 10 s at this moment, and the microphone delivers right after.
        let songStart = Recorder.hostTime(in: 0)
        // 0.2 seconds of the made-up microphone, and a little more so the last block is on its way too.
        try recorder.renderOffline(frames: 9_600 + 4_096)
        let take = try await recorder.stop(songPosition: 10, songStartHostTime: songStart)

        #expect(take.recording.id == id)
        #expect(take.recording.file == "takes/\(id.uuidString).wav")
        #expect(take.recording.lengthSamples == take.samples.count)
        // The take is placed by the clock: it began when the song was started, give or take the moment it took
        // the test to get from one line to the next. (The exact arithmetic is tested with made-up clock readings.)
        #expect(abs(take.recording.rawStart - 10) < 0.5)
        #expect(take.recording.delay == 0)
        // What was recorded is the first channel from its first sample, with nothing missing in between.
        #expect(take.samples.count >= 9_600)
        #expect(take.samples == Array(sound[0].prefix(take.samples.count)))
        let read = try TakeSound.readBack(project.package.url.appending(path: take.recording.file))
        #expect(read.sampleRate == 48_000)
        #expect(read.bitDepth == 24)
        #expect(read.channels.count == 1)
        #expect(TakeSound.furthestOff(read.channels[0], take.samples) <= 1 / 8_388_608)
        // After stopping, nothing is being recorded any more.
        #expect(recorder.snapshot() == RecorderSnapshot())
        #expect(recorder.waveform(fromBlock: 0) == LiveWaveform())
    }

    @Test("A microphone at 44,100 Hz is recorded at 48,000 Hz")
    func otherSampleRateIsRecordedAt48k() async throws {
        let project = try TakeProject()
        defer { project.remove() }
        let recorder = try Recorder(offlineInput: Self.microphoneSound(samples: 44_100), sampleRate: 44_100)

        try await recorder.start(in: project.package)
        try recorder.renderOffline(frames: 22_050)
        let take = try await recorder.stop(songPosition: 0, songStartHostTime: Recorder.hostTime(in: 0))

        // Half a second was heard, give or take the last block still on its way: about 24,000 samples at 48 kHz.
        #expect(abs(take.samples.count - 24_000) <= 2_400)
        let read = try TakeSound.readBack(project.package.url.appending(path: take.recording.file))
        #expect(read.sampleRate == 48_000)
        #expect(read.frames == take.samples.count)
    }

    @Test("Starting twice and stopping without a take are refused")
    func startingTwiceAndStoppingWithoutATakeAreRefused() async throws {
        let project = try TakeProject()
        defer { project.remove() }
        let recorder = try Recorder(offlineInput: Self.microphoneSound(samples: 4_800), sampleRate: 48_000)

        await #expect(throws: RecorderError.notRecording) { try await recorder.stop(songPosition: 0, songStartHostTime: 0) }
        try await recorder.start(in: project.package)
        await #expect(throws: RecorderError.alreadyRecording) { try await recorder.start(in: project.package) }
        _ = try await recorder.stop(songPosition: 0, songStartHostTime: 0)
        await #expect(throws: RecorderError.notRecording) { try await recorder.stop(songPosition: 0, songStartHostTime: 0) }

        // The refused start left no file of its own behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: project.package.takesFolder.path).count == 1)
    }

    // MARK: Restart Recording

    /// Which sample of the made-up microphone a recorded value is: the opposite of `microphoneSound`.
    private static func microphoneIndex(of value: Float) -> Int {
        Int((value * 65_536).rounded()) - 1
    }

    /// The files in the project's takes folder.
    private static func takeFiles(in project: TakeProject) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: project.package.takesFolder.path)
    }

    /// Waits until the recorder's attempt holds at least this many samples. The engine hands sound to the
    /// receiving block on a thread of its own, a moment after it was asked for, as the real microphone does.
    private static func waitUntilHeard(_ samples: Int, by recorder: Recorder) async throws {
        for _ in 0..<2_000 where recorder.snapshot().lengthSamples < samples {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(recorder.snapshot().lengthSamples >= samples)
    }

    @Test("A restart with the setting off deletes the attempt's file and goes on recording to a new one")
    func restartThrowsTheAttemptAway() async throws {
        let project = try TakeProject()
        defer { project.remove() }
        let sound = Self.microphoneSound(samples: 48_000)
        let recorder = try Recorder(offlineInput: sound, sampleRate: 48_000)

        let first = try await recorder.start(in: project.package)
        try recorder.renderOffline(frames: 9_600)
        try await Self.waitUntilHeard(4_096, by: recorder)
        let dropped = try await recorder.restart(in: project.package)
        #expect(dropped.id == first)
        // The recorder goes on at once, with an empty attempt of its own.
        #expect(recorder.snapshot().isRecording)
        let kept = try dropped.end(keeping: false, songPosition: 10, songStartHostTime: Recorder.hostTime(in: 0))
        #expect(kept == nil)
        #expect(try Self.takeFiles(in: project).count == 1)
        #expect(!FileManager.default.fileExists(atPath: project.package.url.appending(path: Recording.fileName(for: first)).path))

        try recorder.renderOffline(frames: 9_600 + 4_096)
        let take = try await recorder.stop(songPosition: 10, songStartHostTime: Recorder.hostTime(in: 0))

        #expect(take.recording.id != first)
        #expect(try Self.takeFiles(in: project) == ["\(take.recording.id.uuidString).wav"])
        // The new attempt holds what the microphone heard after the restart, with nothing missing in between.
        let start = Self.microphoneIndex(of: try #require(take.samples.first))
        #expect(start > 0)
        #expect(take.samples.count >= 9_600)
        #expect(take.samples == Array(sound[0][start..<start + take.samples.count]))
        let read = try TakeSound.readBack(project.package.url.appending(path: take.recording.file))
        #expect(read.frames == take.samples.count)
    }

    @Test("A restart with the setting on keeps the attempt, and no sound is lost or doubled between the two")
    func restartKeepsTheAttempt() async throws {
        let project = try TakeProject()
        defer { project.remove() }
        let sound = Self.microphoneSound(samples: 48_000)
        let recorder = try Recorder(offlineInput: sound, sampleRate: 48_000)

        let first = try await recorder.start(in: project.package)
        let songStart = Recorder.hostTime(in: 0)
        try recorder.renderOffline(frames: 14_400)
        try await Self.waitUntilHeard(4_096, by: recorder)
        let dropped = try await recorder.restart(in: project.package)
        let attempt = try #require(try dropped.end(keeping: true, songPosition: 10, songStartHostTime: songStart))
        try recorder.renderOffline(frames: 9_600 + 4_096)
        let take = try await recorder.stop(songPosition: 10, songStartHostTime: Recorder.hostTime(in: 0))

        // The kept attempt is a recording like any other: its own file, its length, its place by the clock.
        #expect(attempt.recording.id == first)
        #expect(attempt.recording.lengthSamples == attempt.samples.count)
        #expect(abs(attempt.recording.rawStart - 10) < 0.5)
        let read = try TakeSound.readBack(project.package.url.appending(path: attempt.recording.file))
        #expect(read.frames == attempt.samples.count)
        #expect(TakeSound.furthestOff(read.channels[0], attempt.samples) <= 1 / 8_388_608)
        #expect(Set(try Self.takeFiles(in: project)) == [
            "\(attempt.recording.id.uuidString).wav", "\(take.recording.id.uuidString).wav",
        ])
        // Every sample went to one attempt or the other: together they are the microphone's sound from its
        // first sample on, in order.
        #expect(!attempt.samples.isEmpty)
        #expect(!take.samples.isEmpty)
        let both = attempt.samples + take.samples
        #expect(both.count >= 14_400 + 9_600)
        #expect(both == Array(sound[0].prefix(both.count)))
    }

    @Test("Ten restarts in a row, some with no sound in between, leave no stray files")
    func tenRestartsLeaveNoStrayFiles() async throws {
        let project = try TakeProject()
        defer { project.remove() }
        let recorder = try Recorder(offlineInput: Self.microphoneSound(samples: 48_000), sampleRate: 48_000)

        try await recorder.start(in: project.package)
        for round in 0..<10 {
            // Every other restart follows the one before with nothing heard in between.
            if round.isMultiple(of: 2) {
                try recorder.renderOffline(frames: 2_048)
            }
            let dropped = try await recorder.restart(in: project.package)
            #expect(try dropped.end(keeping: false, songPosition: 0, songStartHostTime: 0) == nil)
            #expect(try Self.takeFiles(in: project).count == 1)
        }
        try recorder.renderOffline(frames: 4_096)
        let take = try await recorder.stop(songPosition: 0, songStartHostTime: Recorder.hostTime(in: 0))

        #expect(try Self.takeFiles(in: project) == ["\(take.recording.id.uuidString).wav"])
        #expect(recorder.snapshot() == RecorderSnapshot())
    }

    @Test("A restart with nothing being recorded is refused and leaves no file")
    func restartWithoutATakeIsRefused() async throws {
        let project = try TakeProject()
        defer { project.remove() }
        let recorder = try Recorder(offlineInput: Self.microphoneSound(samples: 4_800), sampleRate: 48_000)

        await #expect(throws: RecorderError.notRecording) { try await recorder.restart(in: project.package) }
        #expect(!FileManager.default.fileExists(atPath: project.package.takesFolder.path))
        // After a take has been stopped there is nothing to restart either.
        try await recorder.start(in: project.package)
        _ = try await recorder.stop(songPosition: 0, songStartHostTime: 0)
        await #expect(throws: RecorderError.notRecording) { try await recorder.restart(in: project.package) }
        #expect(try Self.takeFiles(in: project).count == 1)
    }

    /// The only test that opens the real microphone. It shows that the real engine starts, delivers sound to the
    /// receiving block on the system's own thread, and stops, on this Mac's current microphone.
    @Test(
        "The real microphone records for 0.2 s without a crash",
        .enabled(if: ProcessInfo.processInfo.environment["LOCKSTEP_MIC"] == "1", "Opens the microphone, so it runs only with LOCKSTEP_MIC=1.")
    )
    func realMicrophoneRecordsBriefly() async throws {
        let project = try TakeProject()
        defer { project.remove() }
        let recorder = Recorder()

        do {
            try await recorder.start(in: project.package)
        } catch RecorderError.noInputDevice {
            print("Skipped: this Mac has no microphone to record from.")
            return
        } catch RecorderError.microphoneNotAllowed {
            print("Skipped: the program running the tests is not allowed to use the microphone.")
            return
        }
        try await Task.sleep(for: .milliseconds(200))
        let take = try await recorder.stop(songPosition: 0, songStartHostTime: Recorder.hostTime(in: 0))

        #expect(take.samples.count > 0)
        #expect(take.recording.lengthSamples == take.samples.count)
        #expect(try TakeSound.readBack(project.package.url.appending(path: take.recording.file)).frames == take.samples.count)
    }
}

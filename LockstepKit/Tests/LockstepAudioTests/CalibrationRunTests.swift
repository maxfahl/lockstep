import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// A calibration without a sound: the engines are the real ones, but connected to no sound device (see
/// `PlaybackEngineTests` and `RecorderTests`). The ticks are taken as the playing engine would have sent them to
/// the headphones, made later by a known time, and handed to the recorder as what its microphone hears.
///
/// What these tests cannot show is the one thing only real devices have: that the moment the Mac says a tick was
/// played and the moment it says the tick was heard are on the same clock. That is shown when Max calibrates.
@Suite("Calibration run")
struct CalibrationRunTests {
    static let devices = DevicePair(outputUID: "out", outputName: "Headphones", inputUID: "in", inputName: "Microphone")

    /// Noise that is the same every time, as loud as `level` at most.
    static func noise(count: Int, level: Float) -> [Float] {
        var state: UInt64 = 0xCA11_B8A7
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 23) - 1) * level
        }
    }

    /// What the microphone hears: `before` samples of the room before the ticks are due, then the sound the
    /// engine sent out, `delay` samples late, in a little noise. The length suits the made-up microphone, which
    /// delivers 4,096 samples at a time.
    static func microphoneSound(of played: [Float], before: Int, delay: Int) -> [Float] {
        let wanted = before + delay + played.count + 48_000
        let count = (wanted / 4_096 + 1) * 4_096
        var sound = noise(count: count, level: 0.02)
        for (index, sample) in played.enumerated() {
            sound[before + delay + index] += sample * 0.5
        }
        return sound
    }

    @Test("The ticks leave the engine as they are, at full volume, and the song stops for them")
    func ticksLeaveTheEngineAsTheyAre() async throws {
        let ticks = DelayCalibration.tickSignal()
        let engine = try await PlaybackEngineClickTests.engine()
        // The click is turned down and off: the ticks must not care.
        engine.setClickVolume(0.25)
        engine.setClickEnabled(false)
        try await engine.play(from: 0)
        _ = try await engine.renderOffline(frames: 4_096)

        try await engine.playTicks(ticks.samples, atHostTime: Recorder.hostTime(in: 0.3))
        #expect(!engine.isPlaying)
        let sound = try await engine.renderOffline(frames: ticks.samples.count + 4_096)
        #expect(Array(sound.left.prefix(ticks.samples.count)) == ticks.samples)
        #expect(sound.left == sound.right)
        #expect(sound.left[ticks.samples.count...].allSatisfy { $0 == 0 })
        // When the ticks have ended the engine rests, as after any single sound.
        #expect(await PlaybackEngineTests.waitUntil { await !engine.engineIsAwake })
    }

    @Test("A silent engine plays the ticks without sound")
    func silentEnginePlaysNoTicks() async throws {
        let ticks = DelayCalibration.tickSignal()
        let engine = try await PlaybackEngineTests.engine(silent: true)
        try await engine.playTicks(ticks.samples, atHostTime: Recorder.hostTime(in: 0.3))
        let sound = try await engine.renderOffline(frames: 24_000)
        #expect(sound.left.allSatisfy { $0 == 0 })
        #expect(sound.right.allSatisfy { $0 == 0 })
    }

    @Test("Ticks played by the engine and heard 217 ms late by the recorder give a delay of 217 ms")
    func playedAndRecordedTicksGiveTheDelay() async throws {
        let ticks = DelayCalibration.tickSignal()
        let engine = try await PlaybackEngineTests.engine()
        try await engine.playTicks(ticks.samples, atHostTime: Recorder.hostTime(in: 0.3))
        let played = try await engine.renderOffline(frames: ticks.samples.count).left

        // The microphone was opened 7,214 samples (150 ms) before the ticks were due, and hears them 10,416
        // samples (217 ms) late.
        let before = 7_214
        let delay = 10_416
        let heard = Self.microphoneSound(of: played, before: before, delay: delay)
        let project = try TakeProject()
        defer { project.remove() }
        let recorder = try Recorder(offlineInput: [heard], sampleRate: 48_000)
        try await recorder.start(in: project.package)
        // The engine hands sound to the recorder on a thread of its own, a tenth of a second at a time, and lets
        // go of sound that is not taken in time. So the microphone is let on a block at a time, and the recorder
        // is waited for whenever it is more than two of its own blocks behind.
        var rendered = 0
        while rendered < heard.count {
            try recorder.renderOffline(frames: 4_096)
            rendered += 4_096
            let expected = rendered - 9_600
            #expect(await PlaybackEngineTests.waitUntil { recorder.snapshot().lengthSamples >= expected })
        }
        var take = try await recorder.stop(songPosition: 0, songStartHostTime: Recorder.hostTime(in: 0))
        // Without sound devices no clock says when the microphone was opened. The test knows: 7,214 samples
        // before the ticks were due. And it names the devices, which a made-up microphone does not have.
        take.recording.rawStart = -Double(before) / 48_000
        take.recording.devicePair = Self.devices

        let outcome = CalibrationRun.outcome(of: take, playing: ticks, devicesAfter: Self.devices, outputIsWireless: true)
        guard case .measured(let measured, let quality, let devices, let wireless) = outcome else {
            Issue.record("The ticks were not found: \(outcome)")
            return
        }
        #expect(abs(measured - 0.217) < 0.000_05)
        #expect(quality > 0.9)
        #expect(devices == Self.devices)
        #expect(wireless)
        #expect(outcome.devices == Self.devices)
        #expect(outcome.outputIsWireless)

        // Devices that changed while the ticks played belong to no pair, so there is no delay to keep.
        let other = DevicePair(outputUID: "airpods", outputName: "maxax", inputUID: "in", inputName: "Microphone")
        #expect(
            CalibrationRun.outcome(of: take, playing: ticks, devicesAfter: other, outputIsWireless: true)
                == .failed(.devicesChanged, devices: other, outputIsWireless: true)
        )
        take.recording.devicePair = nil
        #expect(
            CalibrationRun.outcome(of: take, playing: ticks, devicesAfter: nil, outputIsWireless: false)
                == .failed(.devicesChanged, devices: nil, outputIsWireless: false)
        )
    }

    @Test("A recording in which the ticks cannot be heard says so")
    func ticksThatWereNotHeardFail() {
        let ticks = DelayCalibration.tickSignal()
        let recording = Recording(lengthSamples: 192_000, rawStart: -0.15, devicePair: Self.devices)
        let take = CapturedTake(recording: recording, samples: Self.noise(count: 192_000, level: 0.02))
        #expect(
            CalibrationRun.outcome(of: take, playing: ticks, devicesAfter: Self.devices, outputIsWireless: false)
                == .failed(.notHeard, devices: Self.devices, outputIsWireless: false)
        )
    }

    @Test("While a take is being recorded a calibration does nothing, and the song plays on")
    func calibrationWaitsForTheTake() async throws {
        let engine = try await PlaybackEngineTests.engine()
        try await engine.play(from: 0)
        let project = try TakeProject()
        defer { project.remove() }
        let recorder = try Recorder(offlineInput: RecorderTests.microphoneSound(samples: 48_000), sampleRate: 48_000)
        try await recorder.start(in: project.package)

        let outcome = await CalibrationRun.run(with: engine, recorder: recorder)
        guard case .failed(.busy, _, _) = outcome else {
            Issue.record("Expected a busy recorder, got \(outcome)")
            return
        }
        #expect(engine.isPlaying)
        #expect(recorder.snapshot().isRecording)
        _ = try await recorder.stop(songPosition: 0, songStartHostTime: 0)
    }

    @Test("Why the microphone could not be opened is passed on")
    func reasonsForNotStarting() {
        #expect(CalibrationRun.failure(forNotStarting: RecorderError.alreadyRecording) == .busy)
        #expect(CalibrationRun.failure(forNotStarting: RecorderError.microphoneNotAllowed) == .microphoneNotAllowed)
        #expect(CalibrationRun.failure(forNotStarting: RecorderError.noInputDevice) == .noMicrophone)
        #expect(CalibrationRun.failure(forNotStarting: CocoaError(.fileWriteNoPermission)) == .noMicrophone)
    }

    @Test("The Mac's own sound devices are among the connected ones, and a made-up one is not wireless")
    func connectedDevicesHoldTheCurrentOnes() {
        // Only asks the Mac what it has. Nothing is opened, played or recorded.
        let connected = AudioDevices.connectedUIDs()
        if let current = AudioDevices.currentPair() {
            #expect(connected.contains(current.outputUID))
            #expect(connected.contains(current.inputUID))
        }
        #expect(!AudioDevices.isWireless(uid: "no device has this id"))
    }
}

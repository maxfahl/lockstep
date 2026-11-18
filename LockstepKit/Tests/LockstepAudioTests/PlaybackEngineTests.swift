import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// These tests run the real audio engine, with its real player and the real blocks the system calls back, but
/// without a sound device: the engine is made "offline", so it produces samples only when a test asks for them and
/// hands them to the test instead of to the speakers. Nothing can be heard.
///
/// The blocks that the engine hands to the system (the player's "the sound has ended" block and the "the sound device
/// changed" block) are called here by the system itself, on a thread of its own, exactly as in the app. That is where
/// a block that breaks the audio callback rule in AGENTS.md goes wrong.
@Suite("PlaybackEngine")
struct PlaybackEngineTests {
    /// A song whose samples say where they are: sample number `n` is `(n + 1) / 65536` on the left and the same,
    /// negative, on the right. Silence is zero, so it cannot be mistaken for a sample of the song.
    static func song(samples count: Int) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(count * 2)
        for n in 0..<count {
            let value = Float(n + 1) / 65_536
            samples.append(value)
            samples.append(-value)
        }
        return samples
    }

    /// Which sample of the song a value that came out of the engine is, or nil for silence.
    static func songSample(_ value: Float) -> Int? {
        value == 0 ? nil : Int((value * 65_536).rounded()) - 1
    }

    static func engine(silent: Bool = false, songSamples: Int = 48_000) async throws -> PlaybackEngine {
        let engine = try PlaybackEngine(offlineWithMaximumFrames: 4_096, silent: silent)
        await engine.load(song: song(samples: songSamples))
        return engine
    }

    /// Waits until something that happens on another thread has happened, for five seconds at most.
    static func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    @Test("A 0.2 s buffer plays to its end and the player's end message arrives without a crash")
    func endMessageArrivesFromTheSystemsThread() async throws {
        let engine = try await Self.engine(songSamples: 9_600)
        #expect(engine.snapshot().duration == 0.2)

        try await engine.play(from: 0)
        #expect(engine.isPlaying)

        let sound = try await engine.renderOffline(frames: 9_600 + 4_096)
        #expect(Self.songSample(sound.left[9_599]) == 9_599)
        #expect(sound.left[9_600] == 0)

        // The player calls the end block on a thread of its own; the block passes the news to the engine.
        #expect(await Self.waitUntil { !engine.isPlaying })
        #expect(engine.position == 0.2)
    }

    @Test("The position is the sample that is coming out, counted by the player")
    func positionFollowsThePlayer() async throws {
        let engine = try await Self.engine()
        #expect(engine.position == 0)
        #expect(!engine.isPlaying)

        try await engine.play(from: 0.25)
        #expect(engine.position == 0.25)

        var produced = 0
        for frames in [512, 512, 1, 4_096, 2_079] {
            let sound = try await engine.renderOffline(frames: frames)
            #expect(sound.left.count == frames)
            for (offset, value) in sound.left.enumerated() {
                #expect(Self.songSample(value) == 12_000 + produced + offset)
            }
            #expect(zip(sound.left, sound.right).allSatisfy { $0 == -$1 })
            produced += frames
            // The next sample to come out is the position.
            #expect(engine.position == Double(12_000 + produced) / 48_000)
            #expect(engine.isPlaying)
        }
    }

    @Test("Jumping while playing continues from the new place with no silent sample in between")
    func seekWhilePlaying() async throws {
        let engine = try await Self.engine()
        try await engine.play(from: 0)
        _ = try await engine.renderOffline(frames: 1_000)

        try await engine.seek(to: 0.5)
        #expect(engine.position == 0.5)
        #expect(engine.isPlaying)

        let sound = try await engine.renderOffline(frames: 1_000)
        #expect(Self.songSample(sound.left[0]) == 24_000)
        #expect(Self.songSample(sound.left[999]) == 24_999)
        #expect(engine.position == Double(25_000) / 48_000)

        // The jump threw away the old sound, and the player reports that as an ending too. It belongs to the
        // earlier start, so playback must go on.
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.isPlaying)
        let more = try await engine.renderOffline(frames: 10)
        #expect(Self.songSample(more.left[0]) == 25_000)
    }

    @Test("Stopping keeps the place, jumping while stopped moves it, and playing starts again from there")
    func stopAndSeekWhileStopped() async throws {
        let engine = try await Self.engine()
        try await engine.play(from: 0)
        _ = try await engine.renderOffline(frames: 2_400)

        await engine.stop()
        #expect(!engine.isPlaying)
        #expect(engine.position == 0.05)

        try await engine.seek(to: 0.3)
        #expect(!engine.isPlaying)
        #expect(engine.position == 0.3)

        // Places outside the song are pulled back into it.
        try await engine.seek(to: -4)
        #expect(engine.position == 0)
        try await engine.seek(to: 99)
        #expect(engine.position == 1)

        try await engine.play(from: 0.3)
        let sound = try await engine.renderOffline(frames: 100)
        #expect(Self.songSample(sound.left[0]) == 14_400)
        #expect(engine.position == Double(14_500) / 48_000)
    }

    @Test("Playing from the very end plays nothing and stays at the end")
    func playFromTheEnd() async throws {
        let engine = try await Self.engine()
        try await engine.play(from: 1)
        #expect(!engine.isPlaying)
        #expect(engine.position == 1)
    }

    @Test("When the sound device changes, playback continues from the same place")
    func deviceChangeWhilePlaying() async throws {
        let engine = try await Self.engine()
        try await engine.play(from: 0.5)
        _ = try await engine.renderOffline(frames: 4_800)

        // The system's message is delivered through the real notification block.
        await engine.announceDeviceChange()
        #expect(await Self.waitUntil { await engine.deviceChangesFollowed == 1 })

        #expect(engine.isPlaying)
        #expect(engine.position == 0.6)
        let sound = try await engine.renderOffline(frames: 100)
        #expect(Self.songSample(sound.left[0]) == 28_800)
    }

    @Test("When the sound device changes while stopped, the place is kept and nothing starts")
    func deviceChangeWhileStopped() async throws {
        let engine = try await Self.engine()
        try await engine.seek(to: 0.4)

        await engine.announceDeviceChange()
        #expect(await Self.waitUntil { await engine.deviceChangesFollowed == 1 })

        #expect(!engine.isPlaying)
        #expect(engine.position == 0.4)
    }

    @Test("Loading another song stops playback and goes back to the start")
    func loadReplacesTheSong() async throws {
        let engine = try await Self.engine()
        try await engine.play(from: 0.5)
        _ = try await engine.renderOffline(frames: 100)

        await engine.load(song: Self.song(samples: 24_000))
        #expect(!engine.isPlaying)
        #expect(engine.snapshot() == PlaybackSnapshot(position: 0, isPlaying: false, duration: 0.5))

        try await engine.play(from: 0)
        let sound = try await engine.renderOffline(frames: 100)
        #expect(Self.songSample(sound.left[0]) == 0)
    }

    @Test("With no song there is nothing to play")
    func noSong() async throws {
        let engine = try PlaybackEngine(offlineWithMaximumFrames: 4_096)
        try await engine.play(from: 3)
        #expect(engine.snapshot() == PlaybackSnapshot())
    }
}

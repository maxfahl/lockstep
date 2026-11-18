import Testing
@testable import LockstepAudio

/// A silent engine is what agents use to try the app at night. These tests run the real engine without a sound
/// device (see `PlaybackEngineTests`) and look at the samples it would have sent to the speakers.
@Suite("PlaybackEngine, silent")
struct PlaybackEngineSilentTests {
    @Test("A silent engine puts out no sound and counts the position all the same")
    func silentEngine() async throws {
        let engine = try await PlaybackEngineTests.engine(silent: true)
        try await engine.play(from: 0.25)
        let quiet = try await engine.renderOffline(frames: 4_800)
        #expect(quiet.left.allSatisfy { $0 == 0 })
        #expect(quiet.right.allSatisfy { $0 == 0 })
        #expect(engine.position == 0.35)
        #expect(engine.isPlaying)

        // Turned on or off while playing, the engine fades over the block of samples it is producing (4,096 here,
        // about 10 ms on a real device) instead of cutting, so there is no click. After that block the change is whole.
        await engine.setSilent(false)
        let loud = try await engine.renderOffline(frames: 4_800)
        #expect(PlaybackEngineTests.songSample(loud.left[4_096]) == 12_000 + 4_800 + 4_096)
        #expect(PlaybackEngineTests.songSample(loud.left[4_799]) == 12_000 + 9_599)

        await engine.setSilent(true)
        let quietAgain = try await engine.renderOffline(frames: 9_600)
        #expect(quietAgain.left.dropFirst(4_096).allSatisfy { $0 == 0 })
        #expect(quietAgain.right.dropFirst(4_096).allSatisfy { $0 == 0 })
        #expect(engine.position == 0.65)
    }

    @Test("A silent engine still reaches the end of the song")
    func silentEngineReachesTheEnd() async throws {
        let engine = try await PlaybackEngineTests.engine(silent: true, songSamples: 9_600)
        try await engine.play(from: 0)
        let quiet = try await engine.renderOffline(frames: 9_600 + 4_096)
        #expect(quiet.left.allSatisfy { $0 == 0 })
        #expect(await PlaybackEngineTests.waitUntil { !engine.isPlaying })
        #expect(engine.position == 0.2)
    }
}

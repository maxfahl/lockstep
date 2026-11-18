import Testing
@testable import LockstepAudio

/// The click beside the song, on the real engine without a sound device (see `PlaybackEngineTests`). Nothing can be
/// heard: the tests look at the samples the engine would have sent to the speakers.
///
/// The song of these tests is the one of `PlaybackEngineTests`: sample `n` is `(n + 1) / 65536` on the left and the
/// same, negative, on the right. The click is mono, so it comes out the same on both sides. Half the sum of the two
/// sides is therefore the click alone, and half their difference is the song alone.
@Suite("PlaybackEngine, click")
struct PlaybackEngineClickTests {
    /// A click whose samples say where they are, like the song's: sample `n` is `(n + 1) / 131072`. A second click,
    /// to tell a changed click from the first, has the same values, negative.
    static func click(samples count: Int, negative: Bool = false) -> [Float] {
        (0..<count).map { (negative ? -1 : 1) * Float($0 + 1) / 131_072 }
    }

    /// Which sample of the click a pair of values that came out of the engine holds, or nil when there is no click
    /// in it. `level` is what the click was multiplied by.
    static func clickSample(_ left: Float, _ right: Float, level: Float = 1) -> Int? {
        let value = (left + right) / 2 / level
        return value == 0 ? nil : Int((abs(value) * 131_072).rounded()) - 1
    }

    static func songSample(_ left: Float, _ right: Float) -> Int? {
        PlaybackEngineTests.songSample((left - right) / 2)
    }

    /// An engine with a one-second song and a click as long, switched on at full volume.
    static func engine(silent: Bool = false) async throws -> PlaybackEngine {
        let engine = try await PlaybackEngineTests.engine(silent: silent)
        await engine.setClick(buffer: click(samples: 48_000))
        engine.setClickEnabled(true)
        engine.setClickVolume(1)
        return engine
    }

    /// True when every pair of samples holds the song and the click at the same place, counting on from `first`.
    static func inStep(_ sound: (left: [Float], right: [Float]), from first: Int, level: Float = 1) -> Bool {
        sound.left.indices.allSatisfy { offset in
            songSample(sound.left[offset], sound.right[offset]) == first + offset
                && clickSample(sound.left[offset], sound.right[offset], level: level) == first + offset
        }
    }

    @Test("The click starts on the same sample as the song, from the start and from the middle")
    func clickStartsWithTheSong() async throws {
        let engine = try await Self.engine()
        try await engine.play(from: 0)
        #expect(Self.inStep(try await engine.renderOffline(frames: 5_000), from: 0))
        await engine.stop()

        try await engine.play(from: 0.25)
        #expect(Self.inStep(try await engine.renderOffline(frames: 5_000), from: 12_000))
        #expect(engine.position == Double(17_000) / 48_000)
    }

    @Test("Jumping while playing moves the song and the click together")
    func clickSeeksWithTheSong() async throws {
        let engine = try await Self.engine()
        try await engine.play(from: 0)
        _ = try await engine.renderOffline(frames: 1_000)

        try await engine.seek(to: 0.5)
        #expect(Self.inStep(try await engine.renderOffline(frames: 3_000), from: 24_000))
    }

    @Test("After the sound device changes, the song and the click go on together")
    func clickFollowsADeviceChange() async throws {
        let engine = try await Self.engine()
        try await engine.play(from: 0.5)
        _ = try await engine.renderOffline(frames: 4_800)

        await engine.announceDeviceChange()
        #expect(await PlaybackEngineTests.waitUntil { await engine.deviceChangesFollowed == 1 })
        #expect(Self.inStep(try await engine.renderOffline(frames: 1_000), from: 28_800))
    }

    @Test("The click ends with the song and playback stops as before")
    func clickEndsWithTheSong() async throws {
        let engine = try await PlaybackEngineTests.engine(songSamples: 9_600)
        await engine.setClick(buffer: Self.click(samples: 9_600))
        engine.setClickEnabled(true)
        try await engine.play(from: 0)

        let sound = try await engine.renderOffline(frames: 9_600 + 4_096)
        #expect(Self.clickSample(sound.left[9_599], sound.right[9_599]) == 9_599)
        #expect(sound.left[9_600...].allSatisfy { $0 == 0 })
        #expect(sound.right[9_600...].allSatisfy { $0 == 0 })
        #expect(await PlaybackEngineTests.waitUntil { !engine.isPlaying })
        #expect(engine.position == 0.2)
    }

    @Test("Switched off there is no click, and switching it on brings it back in step")
    func clickOnAndOff() async throws {
        let engine = try await Self.engine()
        engine.setClickEnabled(false)
        try await engine.play(from: 0)

        let off = try await engine.renderOffline(frames: 4_096)
        #expect(zip(off.left, off.right).allSatisfy { Self.clickSample($0, $1) == nil })
        #expect(Self.songSample(off.left[4_095], off.right[4_095]) == 4_095)

        // The change comes in over the block of samples being produced (see `PlaybackEngineSilentTests`), so the
        // next block is looked at.
        engine.setClickEnabled(true)
        _ = try await engine.renderOffline(frames: 4_096)
        #expect(Self.inStep(try await engine.renderOffline(frames: 2_000), from: 8_192))

        engine.setClickEnabled(false)
        _ = try await engine.renderOffline(frames: 4_096)
        let offAgain = try await engine.renderOffline(frames: 2_000)
        #expect(zip(offAgain.left, offAgain.right).allSatisfy { Self.clickSample($0, $1) == nil })
        #expect(Self.songSample(offAgain.left[0], offAgain.right[0]) == 14_288)
    }

    @Test("The volume makes the click quieter and leaves the song as it is")
    func clickVolume() async throws {
        let engine = try await Self.engine()
        engine.setClickVolume(0.5)
        try await engine.play(from: 0)
        _ = try await engine.renderOffline(frames: 4_096)
        #expect(Self.inStep(try await engine.renderOffline(frames: 2_000), from: 4_096, level: 0.5))

        engine.setClickVolume(0.25)
        _ = try await engine.renderOffline(frames: 4_096)
        #expect(Self.inStep(try await engine.renderOffline(frames: 2_000), from: 10_192, level: 0.25))
    }

    @Test("A new click takes over within 100 ms while the song plays on without a break")
    func clickIsSwappedWhilePlaying() async throws {
        let engine = try await Self.engine()
        try await engine.play(from: 0.1)
        let before = try await engine.renderOffline(frames: 3_000)
        #expect(Self.inStep(before, from: 4_800))

        await engine.setClick(buffer: Self.click(samples: 48_000, negative: true))
        #expect(engine.isPlaying)
        let sound = try await PlaybackEngineClipTests.renderAtDeviceSpeed(engine, frames: 9_600)

        // The song never noticed.
        #expect(sound.left.indices.allSatisfy { Self.songSample(sound.left[$0], sound.right[$0]) == 7_800 + $0 })

        // From some sample within 100 ms (4,800 samples) on, the click is the new one, at the song's own place.
        let clickValues = zip(sound.left, sound.right).map { ($0 + $1) / 2 }
        let firstNew = try #require(clickValues.firstIndex { $0 < 0 })
        #expect(firstNew <= 4_800)
        #expect(clickValues[firstNew...].indices.allSatisfy { clickValues[$0] == -Float(7_800 + $0 + 1) / 131_072 })
        // Before that sample there is the old click in step, or silence, and nothing else.
        #expect(clickValues[..<firstNew].indices.allSatisfy {
            clickValues[$0] == 0 || clickValues[$0] == Float(7_800 + $0 + 1) / 131_072
        })
    }

    @Test("A click that arrives right after Play, before any sound has come out, is in step too")
    func clickIsSetRightAfterPlay() async throws {
        let engine = try await PlaybackEngineTests.engine()
        engine.setClickEnabled(true)
        try await engine.play(from: 0.25)
        await engine.setClick(buffer: Self.click(samples: 48_000))
        #expect(engine.isPlaying)

        let sound = try await PlaybackEngineClipTests.renderAtDeviceSpeed(engine, frames: 9_600)
        let firstClick = try #require(sound.left.indices.first { Self.clickSample(sound.left[$0], sound.right[$0]) != nil })
        #expect(firstClick <= 4_800)
        #expect(sound.left.indices.allSatisfy { Self.songSample(sound.left[$0], sound.right[$0]) == 12_000 + $0 })
        #expect(sound.left[firstClick...].indices.allSatisfy {
            Self.clickSample(sound.left[$0], sound.right[$0]) == 12_000 + $0
        })
    }

    @Test("Taking the click away while playing silences it and leaves the song playing")
    func clickIsTakenAwayWhilePlaying() async throws {
        let engine = try await Self.engine()
        try await engine.play(from: 0)
        _ = try await engine.renderOffline(frames: 3_000)

        await engine.setClick(buffer: [])
        let sound = try await PlaybackEngineClipTests.renderAtDeviceSpeed(engine, frames: 9_600)
        #expect(sound.left.indices.allSatisfy { Self.songSample(sound.left[$0], sound.right[$0]) == 3_000 + $0 })
        #expect(sound.left[4_800...].indices.allSatisfy { Self.clickSample(sound.left[$0], sound.right[$0]) == nil })
    }

    @Test("Loading another song forgets the click of the old one")
    func loadForgetsTheClick() async throws {
        let engine = try await Self.engine()
        await engine.load(song: PlaybackEngineTests.song(samples: 24_000))
        try await engine.play(from: 0)
        let sound = try await engine.renderOffline(frames: 2_000)
        #expect(zip(sound.left, sound.right).allSatisfy { Self.clickSample($0, $1) == nil })
        #expect(Self.songSample(sound.left[0], sound.right[0]) == 0)
    }

    @Test("A chosen sound is played once while the song is stopped, and the engine rests again after it")
    func soundIsPlayedOnce() async throws {
        let engine = try await Self.engine()
        try await engine.seek(to: 0.3)
        try await engine.playOnce(Self.click(samples: 1_000), volume: 1)

        let sound = try await engine.renderOffline(frames: 1_000 + 4_096)
        #expect((0..<1_000).allSatisfy { Self.clickSample(sound.left[$0], sound.right[$0]) == $0 })
        #expect(sound.left == sound.right)
        #expect(sound.left[1_000...].allSatisfy { $0 == 0 })

        // The song did not start and did not move. The sound's end is told by the system on a thread of its own.
        #expect(!engine.isPlaying)
        #expect(engine.position == 0.3)
        #expect(await PlaybackEngineTests.waitUntil { await !engine.engineIsAwake })
    }

    @Test("A sound played once over the playing song leaves the song and its click alone")
    func soundIsPlayedOnceWhilePlaying() async throws {
        let engine = try await Self.engine()
        engine.setClickEnabled(false)
        try await engine.play(from: 0)
        _ = try await engine.renderOffline(frames: 4_096)

        try await engine.playOnce(Self.click(samples: 500), volume: 1)
        let sound = try await engine.renderOffline(frames: 2_000)
        #expect(sound.left.indices.allSatisfy { Self.songSample(sound.left[$0], sound.right[$0]) == 4_096 + $0 })
        #expect((0..<500).allSatisfy { Self.clickSample(sound.left[$0], sound.right[$0]) == $0 })
        #expect((500..<2_000).allSatisfy { Self.clickSample(sound.left[$0], sound.right[$0]) == nil })

        // The song plays on after the sound has ended.
        try await Task.sleep(for: .milliseconds(100))
        #expect(engine.isPlaying)
        let more = try await engine.renderOffline(frames: 100)
        #expect(Self.songSample(more.left[0], more.right[0]) == 6_096)
    }

    @Test("A silent engine puts out no click either, also not a sound played once")
    func silentEnginePlaysNoSingleSound() async throws {
        let engine = try await Self.engine(silent: true)
        try await engine.playOnce(Self.click(samples: 1_000), volume: 1)
        let quiet = try await engine.renderOffline(frames: 2_000)
        #expect(quiet.left.allSatisfy { $0 == 0 })
        #expect(quiet.right.allSatisfy { $0 == 0 })
    }

    @Test("A silent engine puts out no click either")
    func silentEngineHasNoClick() async throws {
        let engine = try await Self.engine(silent: true)
        try await engine.play(from: 0)
        let quiet = try await engine.renderOffline(frames: 4_800)
        #expect(quiet.left.allSatisfy { $0 == 0 })
        #expect(quiet.right.allSatisfy { $0 == 0 })
        #expect(engine.position == 0.1)
    }
}

import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// Looping, on the real engine without a sound device (see `PlaybackEngineTests`). Nothing can be heard: the
/// tests look at the samples the engine would have sent to the speakers.
///
/// The song is the one of `PlaybackEngineTests`, in which every sample has a value of its own, so each sample
/// that comes out says which sample of the song it is. Half the difference of the two sides is the song alone
/// and half their sum is the clips and the clicks alone (see `PlaybackEngineClipTests`).
@Suite("PlaybackEngine, looping")
struct PlaybackEngineLoopTests {
    /// A loop of a quarter of a second, from 0.25 s to 0.5 s of the one-second song.
    static let loop = LoopRegion(startSample: 12_000, lengthSamples: 12_000)!

    /// Which sample of the song each pair of samples that came out is.
    static func songSamples(_ sound: (left: [Float], right: [Float])) -> [Int?] {
        sound.left.indices.map { PlaybackEngineTests.songSample((sound.left[$0] - sound.right[$0]) / 2) }
    }

    /// The samples of the song that should come out when playback started at `start` and `played` samples had
    /// already come out before these.
    static func expected(_ count: Int, from start: Int, after played: Int = 0, in loop: LoopRegion = loop) -> [Int?] {
        (0..<count).map { loop.songSample(afterPlaying: played + $0, from: start) }
    }

    @Test("Inside the region the song repeats from the region's start, on the exact sample, pass after pass")
    func songGoesRound() async throws {
        let engine = try await PlaybackEngineTests.engine()
        await engine.setLoop(Self.loop)
        try await engine.play(from: 0.3)
        // A little over five passes.
        let sound = try await engine.renderOffline(frames: 62_000)
        #expect(Self.songSamples(sound) == Self.expected(62_000, from: 14_400))
        // The song does not end, and the position is inside the region.
        #expect(engine.isPlaying)
        #expect(engine.position >= Self.loop.start && engine.position < Self.loop.end)
    }

    @Test("Playback that starts before the region plays into it and then loops")
    func playsIntoTheRegion() async throws {
        let engine = try await PlaybackEngineTests.engine()
        await engine.setLoop(Self.loop)
        try await engine.play(from: 0.1)
        let sound = try await engine.renderOffline(frames: 40_000)
        #expect(Self.songSamples(sound) == Self.expected(40_000, from: 4_800))
    }

    @Test("Playback that starts after the region plays on to the end of the song")
    func playsOnAfterTheRegion() async throws {
        let engine = try await PlaybackEngineTests.engine()
        await engine.setLoop(Self.loop)
        try await engine.play(from: 0.6)
        let sound = try await engine.renderOffline(frames: 19_200)
        #expect(Self.songSamples(sound) == (28_800..<48_000).map { $0 })
        #expect(await PlaybackEngineTests.waitUntil { !engine.isPlaying })
    }

    @Test("A jump out of the region while looping plays from there, and a jump back loops again")
    func jumpsOutAndBack() async throws {
        let engine = try await PlaybackEngineTests.engine()
        await engine.setLoop(Self.loop)
        try await engine.play(from: 0.3)
        _ = try await engine.renderOffline(frames: 20_000)
        try await engine.seek(to: 0.75)
        #expect(Self.songSamples(try await engine.renderOffline(frames: 4_000)) == (36_000..<40_000).map { $0 })
        try await engine.seek(to: 0.05)
        #expect(Self.songSamples(try await engine.renderOffline(frames: 40_000)) == Self.expected(40_000, from: 2_400))
    }

    @Test("The clips and the click go round with the song")
    func clipsAndClickGoRound() async throws {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        let voice = PlaybackEngineClipTests.voice(samples: 48_000)
        var row = PlaybackEngineClipTests.silence()
        PlaybackEngineClipTests.lay(voice, 0..<48_000, at: 0, into: &row)
        // A click that is a value of its own on every sample, so it too says where it is.
        let click = (0..<48_000).map { Float($0 % 4_096) / 32_768 }

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClips(
            of: PlaybackEngineClipTests.project([recording], [PlaybackEngineClipTests.clip(recording, 0..<48_000)]),
            recordings: [recording.id: voice],
            edgeFadeMs: 0, voices: .none
        )
        await engine.setClick(buffer: click)
        engine.setClickEnabled(true)
        await engine.setLoop(Self.loop)
        try await engine.play(from: 0.3)
        let sound = try await engine.renderOffline(frames: 50_000)
        let places = Self.expected(50_000, from: 14_400)
        #expect(Self.songSamples(sound) == places)
        let beside = PlaybackEngineClipTests.clipValues(sound)
        #expect(beside.indices.allSatisfy { beside[$0] == row[places[$0]!] + click[places[$0]!] })
    }

    @Test("Clips changed while a loop plays are heard within 100 ms and the loop keeps its step")
    func clipsChangeWhileLooping() async throws {
        let old = Recording(lengthSamples: 48_000, rawStart: 0)
        let new = Recording(lengthSamples: 6_000, rawStart: 0.3)
        let voice = PlaybackEngineClipTests.voice(samples: 48_000)
        let hum = PlaybackEngineClipTests.hum(samples: 6_000)
        var before = PlaybackEngineClipTests.silence()
        PlaybackEngineClipTests.lay(voice, 0..<48_000, at: 0, into: &before)
        var after = before
        PlaybackEngineClipTests.lay(hum, 0..<6_000, at: 14_400, into: &after)

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClips(
            of: PlaybackEngineClipTests.project([old], [PlaybackEngineClipTests.clip(old, 0..<48_000)]),
            recordings: [old.id: voice],
            edgeFadeMs: 0, voices: .none
        )
        await engine.setLoop(Self.loop)
        try await engine.play(from: 0.25)
        _ = try await engine.renderOffline(frames: 3_000)

        await engine.setClips(
            of: PlaybackEngineClipTests.project(
                [old, new],
                [PlaybackEngineClipTests.clip(old, 0..<48_000), PlaybackEngineClipTests.clip(new, 0..<6_000)]
            ),
            recordings: [old.id: voice, new.id: hum],
            edgeFadeMs: 0, voices: .none
        )
        let sound = try await PlaybackEngineClipTests.renderAtDeviceSpeed(engine, frames: 36_000)

        // The song never noticed: it goes round as if nothing had happened.
        let places = Self.expected(36_000, from: 12_000, after: 3_000)
        #expect(Self.songSamples(sound) == places)
        // From some sample within 100 ms on, the new clip is heard too, at its place in every pass.
        let values = PlaybackEngineClipTests.clipValues(sound)
        let firstNew = try #require(values.indices.first {
            after[places[$0]!] != before[places[$0]!] && values[$0] == after[places[$0]!]
        })
        #expect(firstNew <= 4_800)
        #expect(values[firstNew...].indices.allSatisfy { values[$0] == after[places[$0]!] })
        #expect(values[..<firstNew].indices.allSatisfy { values[$0] == before[places[$0]!] })
    }

    @Test("Loop switched off while it plays: the song plays on from where it is, to its end")
    func loopSwitchedOffWhilePlaying() async throws {
        let engine = try await PlaybackEngineTests.engine()
        await engine.setLoop(Self.loop)
        try await engine.play(from: 0.3)
        _ = try await engine.renderOffline(frames: 30_000)
        await engine.setLoop(nil)
        let sound = Self.songSamples(try await engine.renderOffline(frames: 20_000))
        // It goes on inside the region, where it was, and then straight past the region's end.
        let first = try #require(sound[0])
        #expect(first >= Self.loop.startSample && first < Self.loop.endSample)
        #expect(sound == (first..<first + 20_000).map { $0 })
    }

    @Test("Loop switched on while the song plays before the end of the region: the song then goes round")
    func loopSwitchedOnWhilePlaying() async throws {
        let engine = try await PlaybackEngineTests.engine()
        try await engine.play(from: 0.1)
        _ = try await engine.renderOffline(frames: 2_000)
        await engine.setLoop(Self.loop)
        let sound = Self.songSamples(try await engine.renderOffline(frames: 40_000))
        let first = try #require(sound[0])
        #expect(first >= 4_800 && first < 12_000)
        #expect(sound == Self.expected(40_000, from: first))
    }

    @Test("A take's count-in leads into the loop, and the loop then goes round")
    func countInLeadsIntoTheLoop() async throws {
        // Beats a tenth of a second apart, so a bar of count-in is 0.4 s and fits before a loop at 0.6 s.
        let grid = Grid(beats: (0..<13).map { Beat(number: $0, time: Double($0) * 0.1) }, barStartNumber: 2)
        let loop = try #require(LoopRegion(startSample: 28_800, lengthSamples: 12_000))
        let countIn = RecordingPlacement.countIn(to: loop.start, bars: 1, grid: grid)
        #expect(countIn.songStartSample == 9_600)

        let engine = try await PlaybackEngineTests.engine(songSamples: 62_400)
        await engine.setLoop(loop)
        let startedAt = try await engine.start(countingIn: countIn, click: ClickSettings(), atHostTime: 0)
        #expect(abs(startedAt - 0.2) < 1e-9)
        let sound = try await engine.renderOffline(frames: 60_000)
        // From the place on the song is at full level, and it goes round the loop.
        let places = Self.songSamples(sound)
        #expect(Array(places[19_200...]) == Array(Self.expected(60_000, from: 9_600, in: loop)[19_200...]))
        #expect(engine.isPlaying)
    }

    @Test("The position goes round with the sound")
    func positionGoesRound() {
        // Started half a second into a song of four seconds, with a loop from second 2 to second 3.
        let loop = LoopRegion(startSample: 96_000, lengthSamples: 48_000)!
        func position(afterPlaying samples: Int64, sinceReport: Double = 0) -> Double {
            PlaybackPosition.seconds(
                runStartSample: 24_000,
                leadInSamples: 0,
                playerSample: samples,
                secondsSinceReport: sinceReport,
                lengthSamples: 192_000,
                loop: loop
            )
        }
        #expect(position(afterPlaying: 0) == 0.5)
        #expect(position(afterPlaying: 96_000) == 2.5)
        // 2.5 seconds played: the end of the region, which is its start.
        #expect(abs(position(afterPlaying: 120_000) - 2.0) < 1e-12)
        #expect(abs(position(afterPlaying: 120_000 + 48_000 * 100 + 4_800) - 2.1) < 1e-9)
        // A block that is on its way out when the loop comes round is already at the start again.
        #expect(abs(position(afterPlaying: 119_520, sinceReport: 0.02) - 2.01) < 1e-9)
        // Without a loop the same count plays straight on.
        let straight = PlaybackPosition.seconds(
            runStartSample: 24_000, leadInSamples: 0, playerSample: 120_000, secondsSinceReport: 0,
            lengthSamples: 192_000, loop: nil
        )
        #expect(straight == 3.0)
    }
}

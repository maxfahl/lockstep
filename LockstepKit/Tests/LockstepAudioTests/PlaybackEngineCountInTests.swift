import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// A take's count-in, on the real engine without a sound device (see `PlaybackEngineTests`). Nothing can be heard:
/// the tests look at the samples the engine would have sent to the speakers.
///
/// The song of these tests is the one of `PlaybackEngineTests`, one second long: sample `n` is `(n + 1) / 65536`
/// on the left and the same, negative, on the right. The clicks and the clips are mono, so they come out the same
/// on both sides. Half the difference of the two sides is therefore the song alone, and half their sum is
/// everything else: the count-in's clicks, the song's own click and the clips.
@Suite("PlaybackEngine, count-in")
struct PlaybackEngineCountInTests {
    /// A count-in of a quarter of a second to the place at 0.5 s, all of it inside the song: 12,000 samples, with
    /// a click on its first sample, one in its middle, and the click to start on at the place.
    static let inside = CountIn(place: 0.5, start: 0.25, clicks: [
        .init(time: 0.25, kind: .barStart), .init(time: 0.375, kind: .beat), .init(time: 0.5, kind: .start),
    ])

    /// A count-in of half a second to the place at 0.25 s: its first 12,000 samples lie before the song.
    static let before = CountIn(place: 0.25, start: -0.25, clicks: [
        .init(time: -0.25, kind: .barStart), .init(time: -0.125, kind: .beat), .init(time: 0, kind: .beat),
        .init(time: 0.125, kind: .beat), .init(time: 0.25, kind: .start),
    ])

    static let woodblock = ClickSettings(sound: .woodblock, division: .beats)

    /// The clicks of a count-in as the engine should put them out.
    static func clicks(of countIn: CountIn, volume: Float) -> [Float] {
        ClickRenderer.renderCountIn(countIn, settings: woodblock, volume: volume)
    }

    /// The song alone, for each pair of samples that came out of the engine.
    static func song(_ sound: (left: [Float], right: [Float])) -> [Float] {
        zip(sound.left, sound.right).map { ($0 - $1) / 2 }
    }

    /// Everything but the song, for each pair of samples that came out of the engine.
    static func beside(_ sound: (left: [Float], right: [Float])) -> [Float] {
        zip(sound.left, sound.right).map { ($0 + $1) / 2 }
    }

    /// The value of the song's sample `n`.
    static func songValue(_ n: Int) -> Float { Float(n + 1) / 65_536 }

    /// The value of sample `n` of the song's click of these tests (`PlaybackEngineClickTests.click`).
    static func clickValue(_ n: Int) -> Float { Float(n + 1) / 131_072 }

    static func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-6 }

    /// An engine with the one-second song and a click as long. The click is switched off unless asked for.
    static func engine(clickOn: Bool = false, volume: Float = 0.5) async throws -> PlaybackEngine {
        let engine = try await PlaybackEngineTests.engine()
        await engine.setClick(buffer: PlaybackEngineClickTests.click(samples: 48_000))
        engine.setClickEnabled(clickOn)
        engine.setClickVolume(volume)
        return engine
    }

    // MARK: The clicks

    @Test("With the click off, the count-in still clicks, and nothing clicks after it")
    func countInClicksWithTheClickOff() async throws {
        let engine = try await Self.engine()
        // The app makes the clicks ahead of the start. The start then plays exactly those.
        await engine.prepare(countingIn: Self.inside, click: Self.woodblock)
        try await engine.start(countingIn: Self.inside, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02))
        let out = Self.beside(try await engine.renderOffline(frames: 30_000))

        let clicks = Self.clicks(of: Self.inside, volume: 0.5)
        // The count-in's own clicks are there, on their samples and at the click's volume.
        #expect(clicks.indices.allSatisfy { Self.near(out[$0], clicks[$0]) })
        #expect(out[0] != 0)
        #expect(out[6_000] != 0)
        #expect(out[12_000] != 0)
        // After the click to start on has rung out there is no click: the switch is off.
        #expect(clicks.count == 12_000 + ClickSound.startLengthSamples)
        #expect(out[clicks.count...].allSatisfy { $0 == 0 })
    }

    @Test("The louder click is on the place, on the exact sample")
    func startClickIsOnThePlace() async throws {
        let engine = try await Self.engine()
        try await engine.start(countingIn: Self.inside, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02))
        let sound = try await engine.renderOffline(frames: 30_000)
        let out = Self.beside(sound)

        // The place, 0.5 s, is sample 24,000 of the song, and it comes out 12,000 samples after the start.
        #expect(PlaybackEngineTests.songSample(Self.song(sound)[12_000]) == 24_000)
        // The click to start on begins on that sample: silence just before it, its own sound from there.
        let start = ClickSound.startSamples(peak: ClickRenderer.startClickPeak(volume: 0.5, accentBeatOne: true))
        #expect(out[11_999] == 0)
        #expect(start.indices.allSatisfy { Self.near(out[12_000 + $0], start[$0]) })
        // It is 6 dB louder than the click on the first beat of the bar, and below full scale.
        let startPeak = out[12_000..<14_880].reduce(0) { max($0, abs($1)) }
        let barPeak = out[..<6_000].reduce(0) { max($0, abs($1)) }
        #expect(abs(20 * log10(Double(startPeak / barPeak)) - 6) < 0.01)
        #expect(startPeak < 1)
    }

    @Test("With the click on, the song's click waits for the click to start on and is then in step")
    func songClickComesBackAfterTheCountIn() async throws {
        let engine = try await Self.engine(clickOn: true)
        try await engine.start(countingIn: Self.inside, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02))
        let out = Self.beside(try await engine.renderOffline(frames: 30_000))

        // During the count-in, and while the click to start on sounds, only the count-in's clicks are heard.
        let clicks = Self.clicks(of: Self.inside, volume: 0.5)
        #expect(clicks.indices.allSatisfy { Self.near(out[$0], clicks[$0]) })
        // Then the song's click comes back over 10 ms, at the song's own place and at the click's volume.
        #expect((14_880..<15_360).allSatisfy {
            Self.near(out[$0], Self.clickValue(12_000 + $0) * 0.5 * Float($0 - 14_880) / 480)
        })
        #expect((15_360..<30_000).allSatisfy { Self.near(out[$0], Self.clickValue(12_000 + $0) * 0.5) })
    }

    // MARK: The song fading up

    @Test("The song is silent at the start of the count-in, at half level a quarter in, and at full level from half of it on")
    func songRisesOverTheFirstHalf() async throws {
        let engine = try await Self.engine()
        try await engine.start(countingIn: Self.inside, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02))
        let sound = try await engine.renderOffline(frames: 30_000)
        let song = Self.song(sound)

        // The start, a quarter, the middle and the end of the count-in.
        #expect(song[0] == 0)
        #expect(Self.near(song[3_000], Self.songValue(15_000) * 0.5))
        #expect(song[6_000] == Self.songValue(18_000))
        #expect(song[12_000] == Self.songValue(24_000))
        // On every sample the level is what the count-in says, and the song is never out of step.
        #expect(song.indices.allSatisfy {
            Self.near(song[$0], Self.songValue(12_000 + $0) * Self.inside.songLevel(atSample: $0))
        })
        // From the middle of the count-in on the song is untouched, sample for sample.
        #expect((6_000..<30_000).allSatisfy { PlaybackEngineTests.songSample(song[$0]) == 12_000 + $0 })
        // The position is the place in the song, as in ordinary playback.
        #expect(engine.position == Double(42_000) / 48_000)
    }

    @Test("The clips rise with the song, and the click does not")
    func clipsRiseWithTheSong() async throws {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        let voice = PlaybackEngineClipTests.voice(samples: 48_000)
        let project = PlaybackEngineClipTests.project([recording], [PlaybackEngineClipTests.clip(recording, 0..<48_000)])

        // With the click's volume at zero the count-in is silent, so everything beside the song is the clip.
        let engine = try await Self.engine(volume: 0)
        await engine.setClips(of: project, recordings: [recording.id: voice], edgeFadeMs: 0, voices: .none)
        try await engine.start(countingIn: Self.inside, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02))
        let out = Self.beside(try await engine.renderOffline(frames: 20_000))
        #expect(out[0] == 0)
        #expect(Self.near(out[3_000], voice[15_000] * 0.5))
        #expect(out.indices.allSatisfy { Self.near(out[$0], voice[12_000 + $0] * Self.inside.songLevel(atSample: $0)) })
        #expect((6_000..<20_000).allSatisfy { out[$0] == voice[12_000 + $0] })
    }

    // MARK: A count-in before the song

    @Test("With a count-in before the song, the song's first sample comes out exactly the length of that part after the start")
    func songStartsOnTimeAfterTheClicks() async throws {
        let engine = try await Self.engine()
        let hostTime = Recorder.hostTime(in: 0.02)
        let position = try await engine.start(countingIn: Self.before, click: Self.woodblock, atHostTime: hostTime)
        // The start is a quarter of a second before the song, and the engine says so.
        #expect(position == -0.25)
        #expect(engine.position == -0.25)
        #expect(engine.isPlaying)

        let first = try await engine.renderOffline(frames: 4_800)
        #expect(engine.position == -0.15)
        let rest = try await engine.renderOffline(frames: 25_200)
        let sound = (left: first.left + rest.left, right: first.right + rest.right)
        let song = Self.song(sound)

        // Silence for 12,000 samples, then the song from its first sample, at full level: the first half of the
        // count-in is over when the song starts.
        #expect(song[..<12_000].allSatisfy { $0 == 0 })
        #expect((12_000..<30_000).allSatisfy { PlaybackEngineTests.songSample(song[$0]) == $0 - 12_000 })
        #expect(engine.position == Double(18_000) / 48_000)

        // The click counted alone before the song, and the click to start on is on the place.
        let out = Self.beside(sound)
        let clicks = Self.clicks(of: Self.before, volume: 0.5)
        #expect(clicks.indices.allSatisfy { Self.near(out[$0], clicks[$0]) })
        #expect(out[0] != 0)
        #expect(out[6_000] != 0)
        #expect(out[23_999] == 0)
        #expect(out[24_000] != 0)

        // What the microphone hears 0.1 s after the start is placed before the song: at -0.15 s.
        let heard = hostTime + HostClock.system.ticks(forSeconds: 0.1)
        let rawStart = RecordingPlacement.rawStart(
            playbackStartPosition: position, songStartHostTime: hostTime, firstInputHostTime: heard, clock: .system
        )
        #expect(abs(rawStart - -0.15) < 1e-6)
    }

    @Test("A song that starts during the first half of the count-in starts at the level the count-in has reached")
    func songStartsPartWayUpTheRise() async throws {
        // Half a second to the place at 0.4 s: 4,800 samples before the song, and the rise lasts 12,000.
        let countIn = CountIn(place: 0.4, start: -0.1, clicks: [.init(time: -0.1, kind: .beat), .init(time: 0.4, kind: .start)])
        let engine = try await Self.engine()
        try await engine.start(countingIn: countIn, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02))
        let song = Self.song(try await engine.renderOffline(frames: 30_000))

        #expect(song[..<4_800].allSatisfy { $0 == 0 })
        #expect(Self.near(song[4_800], Self.songValue(0) * 0.4))
        #expect(song[4_800] != 0)
        #expect((4_800..<30_000).allSatisfy {
            Self.near(song[$0], Self.songValue($0 - 4_800) * countIn.songLevel(atSample: $0))
        })
        #expect(song[12_000] == Self.songValue(7_200))
    }

    @Test("Stopped during the part before the song, the position rests at the start of the song")
    func stopBeforeTheSong() async throws {
        let engine = try await Self.engine()
        try await engine.start(countingIn: Self.before, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02))
        _ = try await engine.renderOffline(frames: 4_800)
        await engine.stop()
        #expect(!engine.isPlaying)
        #expect(engine.position == 0)

        // Ordinary playback afterwards has no count-in left in it.
        try await engine.play(from: 0.25)
        let sound = try await engine.renderOffline(frames: 4_800)
        let song = Self.song(sound)
        #expect(song.indices.allSatisfy { PlaybackEngineTests.songSample(song[$0]) == 12_000 + $0 })
        #expect(Self.beside(sound).allSatisfy { $0 == 0 })
        #expect(engine.position == 0.35)
    }

    // MARK: Restarting, and no count-in

    @Test("Restart Recording goes back to the same count-in")
    func restartPlaysTheCountInAgain() async throws {
        let engine = try await Self.engine()
        try await engine.start(countingIn: Self.before, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02))
        // Well into the take, with the song playing.
        _ = try await engine.renderOffline(frames: 28_000)

        let position = try await engine.start(
            countingIn: Self.before, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02)
        )
        #expect(position == -0.25)
        #expect(engine.position == -0.25)
        let sound = try await engine.renderOffline(frames: 30_000)
        let song = Self.song(sound)
        let out = Self.beside(sound)
        let clicks = Self.clicks(of: Self.before, volume: 0.5)
        #expect(song[..<12_000].allSatisfy { $0 == 0 })
        #expect((12_000..<30_000).allSatisfy { PlaybackEngineTests.songSample(song[$0]) == $0 - 12_000 })
        #expect(clicks.indices.allSatisfy { Self.near(out[$0], clicks[$0]) })
        #expect(out[clicks.count...].allSatisfy { $0 == 0 })
    }

    @Test("A count-in that is off starts the song at the place at once, with no click")
    func countInOff() async throws {
        let engine = try await Self.engine()
        let off = CountIn(place: 0.5, start: 0.5)
        let position = try await engine.start(countingIn: off, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02))
        #expect(position == 0.5)
        let sound = try await engine.renderOffline(frames: 5_000)
        let song = Self.song(sound)
        #expect(song.indices.allSatisfy { PlaybackEngineTests.songSample(song[$0]) == 24_000 + $0 })
        #expect(Self.beside(sound).allSatisfy { $0 == 0 })
    }

    // MARK: Changes while the count-in plays

    @Test("A click that arrives during the count-in waits for the click to start on, and the count-in goes on untouched")
    func clickIsSetDuringTheCountIn() async throws {
        let engine = try await Self.engine(clickOn: true, volume: 1)
        try await engine.start(countingIn: Self.inside, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02))
        let first = try await engine.renderOffline(frames: 2_000)

        await engine.setClick(buffer: PlaybackEngineClickTests.click(samples: 48_000, negative: true))
        #expect(engine.isPlaying)
        let rest = try await PlaybackEngineClipTests.renderAtDeviceSpeed(engine, frames: 22_000)
        let sound = (left: first.left + rest.left, right: first.right + rest.right)
        let song = Self.song(sound)
        let out = Self.beside(sound)

        // The song rose and played on as if nothing had happened.
        #expect(song.indices.allSatisfy {
            Self.near(song[$0], Self.songValue(12_000 + $0) * Self.inside.songLevel(atSample: $0))
        })
        // The count-in's clicks are all there, and the new click comes in after the click to start on, in step.
        let clicks = Self.clicks(of: Self.inside, volume: 1)
        #expect(clicks.indices.allSatisfy { Self.near(out[$0], clicks[$0]) })
        #expect((15_360..<24_000).allSatisfy { Self.near(out[$0], -Self.clickValue(12_000 + $0)) })
    }

    @Test("A click that arrives right after the take was started does not start the count-in again")
    func clickIsSetRightAfterTheStart() async throws {
        let engine = try await Self.engine(clickOn: true, volume: 1)
        let position = try await engine.start(
            countingIn: Self.before, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02)
        )
        // No sound has come out yet, so the players cannot say where they are.
        await engine.setClick(buffer: PlaybackEngineClickTests.click(samples: 48_000, negative: true))
        #expect(engine.isPlaying)
        #expect(position == -0.25)

        let sound = try await PlaybackEngineClipTests.renderAtDeviceSpeed(engine, frames: 30_000)
        let song = Self.song(sound)
        let out = Self.beside(sound)
        // The song still starts exactly 12,000 samples after the start, and the count-in is whole.
        #expect(song[..<12_000].allSatisfy { $0 == 0 })
        #expect((12_000..<30_000).allSatisfy { PlaybackEngineTests.songSample(song[$0]) == $0 - 12_000 })
        let clicks = Self.clicks(of: Self.before, volume: 1)
        #expect(clicks.indices.allSatisfy { Self.near(out[$0], clicks[$0]) })
        // The place is sample 12,000 of the song. The new click is in step from 10 ms after the click to start on.
        #expect((27_360..<30_000).allSatisfy { Self.near(out[$0], -Self.clickValue($0 - 12_000)) })
    }

    @Test("Clips that arrive while the song is rising rise with it, in place of the clips that were there")
    func clipsAreSetDuringTheRise() async throws {
        let old = Recording(lengthSamples: 48_000, rawStart: 0)
        let new = Recording(lengthSamples: 48_000, rawStart: 0)
        let hum = PlaybackEngineClipTests.hum(samples: 48_000)
        let voice = PlaybackEngineClipTests.voice(samples: 48_000)
        // A count-in of 0.75 s, so the song rises for 18,000 samples: longer than a new sound takes to come in.
        let long = CountIn(place: 0.9, start: 0.15, clicks: [.init(time: 0.9, kind: .start)])

        // With the click's volume at zero the count-in is silent, so everything beside the song is the clips.
        let engine = try await Self.engine(volume: 0)
        await engine.setClips(
            of: PlaybackEngineClipTests.project([old], [PlaybackEngineClipTests.clip(old, 0..<48_000)]),
            recordings: [old.id: hum],
            edgeFadeMs: 0, voices: .none
        )
        try await engine.start(countingIn: long, click: Self.woodblock, atHostTime: Recorder.hostTime(in: 0.02))
        let first = try await engine.renderOffline(frames: 2_000)
        await engine.setClips(
            of: PlaybackEngineClipTests.project([new], [PlaybackEngineClipTests.clip(new, 0..<48_000)]),
            recordings: [new.id: voice],
            edgeFadeMs: 0, voices: .none
        )
        let rest = try await PlaybackEngineClipTests.renderAtDeviceSpeed(engine, frames: 22_000)
        let out = Self.beside((left: first.left + rest.left, right: first.right + rest.right))

        // From some sample within 100 ms of the change the new clip is heard, at the level the song has there,
        // and it plays on at full level when the rise is over.
        let firstNew = try #require(out.indices.first { $0 > 0 && Self.near(out[$0], voice[7_200 + $0] * long.songLevel(atSample: $0)) })
        #expect(firstNew >= 2_000)
        #expect(firstNew <= 2_000 + 4_800)
        #expect(out[firstNew...].indices.allSatisfy {
            Self.near(out[$0], voice[7_200 + $0] * long.songLevel(atSample: $0))
        })
        #expect(out[18_000] == voice[25_200])
        // Until then the clip that was there rises, with no silent sample.
        #expect(out[..<firstNew].indices.allSatisfy { Self.near(out[$0], hum[7_200 + $0] * long.songLevel(atSample: $0)) })
    }
}

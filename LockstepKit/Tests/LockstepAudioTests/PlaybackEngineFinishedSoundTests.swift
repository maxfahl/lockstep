import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// Clips that are played from their finished sound, on the real engine without a sound device (see
/// `PlaybackEngineTests`). Nothing can be heard: the tests look at the samples the engine would have sent to the
/// speakers.
///
/// The song of these tests is one second of silence, so what comes out is the clips alone, left and right apart,
/// and can be compared sample for sample. That the song itself plays on is tested in `PlaybackEngineClipTests`.
///
/// How a finished sound is made is tested where it is made (`FinishedSoundRendererTests`). Here it is any two
/// rows that can be told from each other and from the recording, because the engine only has to play the right
/// row on the right side at the right place.
@Suite("PlaybackEngine, finished sounds")
struct PlaybackEngineFinishedSoundTests {
    typealias Clips = PlaybackEngineClipTests

    static func engine() async throws -> PlaybackEngine {
        let engine = try PlaybackEngine(offlineWithMaximumFrames: 4_096)
        await engine.load(song: [Float](repeating: 0, count: 2 * Clips.songSamples))
        return engine
    }

    /// A stand-in for a finished sound. `sign` tells two of them apart.
    static func finished(_ count: Int, sign: Float = 1) -> StereoSound {
        StereoSound(
            left: (0..<count).map { sign * Float($0 + 1) / 262_144 },
            right: (0..<count).map { -sign * Float($0 + 1) / 524_288 }
        )
    }

    /// The lookup that says `clip` has this finished sound, and the sound's samples by its id.
    static func sound(
        _ sound: StereoSound, for clip: Clip, tail: Int
    ) -> (lookup: FinishedSounds, samples: [UUID: StereoSound], id: UUID) {
        let id = UUID()
        var lookup = FinishedSounds()
        lookup.set(
            FinishedSounds.Sound(id: id, drySamples: sound.left.count - tail, tailSamples: tail, pieces: clip.segments, madeFrom: .recordings),
            for: clip.id
        )
        return (lookup, [id: sound], id)
    }

    @Test("What the engine plays of a clip with a finished sound is sample for sample what its export holds")
    func playedIsWhatIsExported() async throws {
        // The recording began a quarter of a second into the song. The clip plays its samples 1,000 to 9,000,
        // which is samples 13,000 to 21,000 of the song, and the finished sound rings 2,400 samples longer.
        let recording = Recording(lengthSamples: 20_000, rawStart: 0.25)
        var clip = Clips.clip(recording, 1_000..<9_000)
        clip.gainDb = 5
        let project = Clips.project([recording], [clip])
        let sounds = [recording.id: Clips.voice(samples: 20_000)]
        let made = Self.sound(Self.finished(10_400), for: clip, tail: 2_400)
        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: sounds, peaks: RecordingPeaks().lookup(in: sounds), edgeFadeMs: 5,
            finished: made.lookup, finishedSamples: made.samples, voices: .none
        ))
        #expect(export.channels == 2)
        let padding = export.paddingSamples
        let file = (
            left: stride(from: 0, to: export.samples.count, by: 2).map { export.samples[$0] },
            right: stride(from: 1, to: export.samples.count, by: 2).map { export.samples[$0] }
        )

        let engine = try await Self.engine()
        await engine.setClips(
            of: project, recordings: sounds, finished: made.lookup, finishedSamples: made.samples, edgeFadeMs: 5, voices: .none
        )
        try await engine.play(from: 0)
        let played = try await engine.renderOffline(frames: Clips.songSamples)
        await engine.stop()

        #expect(Array(played.left[13_000..<23_400]) == Array(file.left[padding..<(padding + 10_400)]))
        #expect(Array(played.right[13_000..<23_400]) == Array(file.right[padding..<(padding + 10_400)]))
        #expect(played.left[13_000] == made.samples[made.id]?.left[0])
        #expect(played.right[23_399] == made.samples[made.id]?.right[10_399])
        // Before the clip and after its tail there is silence, on both sides.
        for side in [played.left, played.right] {
            #expect(side[..<13_000].allSatisfy { $0 == 0 })
            #expect(side[23_400...].allSatisfy { $0 == 0 })
        }
    }

    @Test("Playback that starts inside a finished sound, or inside its tail, starts on the right sample of it")
    func fromInside() async throws {
        let recording = Recording(lengthSamples: 20_000, rawStart: 0.25)
        let clip = Clips.clip(recording, 1_000..<9_000)
        let project = Clips.project([recording], [clip])
        let sounds = [recording.id: Clips.voice(samples: 20_000)]
        let sound = Self.finished(10_400)
        let made = Self.sound(sound, for: clip, tail: 2_400)
        let engine = try await Self.engine()
        await engine.setClips(of: project, recordings: sounds, finished: made.lookup, finishedSamples: made.samples, voices: .none)

        // 0.3 s is sample 14,400 of the song: 1,400 samples into the sound.
        try await engine.play(from: 0.3)
        let inside = try await engine.renderOffline(frames: 2_000)
        #expect(inside.left == Array(sound.left[1_400..<3_400]))
        #expect(inside.right == Array(sound.right[1_400..<3_400]))
        await engine.stop()

        // 0.45 s is sample 21,600: 600 samples into the tail, of which 1,800 are left.
        try await engine.play(from: 0.45)
        let tail = try await engine.renderOffline(frames: 2_000)
        #expect(Array(tail.left[..<1_800]) == Array(sound.left[8_600...]))
        #expect(Array(tail.right[..<1_800]) == Array(sound.right[8_600...]))
        #expect(tail.left[1_800...].allSatisfy { $0 == 0 })
    }

    @Test("A finished sound is as loud as its track says, and a clip without one beside it plays on both sides as before")
    func besideADryClip() async throws {
        let recording = Recording(lengthSamples: 20_000, rawStart: 0.25)
        let withSound = Clips.clip(recording, 1_000..<9_000)
        var dry = Clips.clip(recording, 12_000..<16_000)
        dry.gainDb = -3
        var project = Project(
            songLengthSamples: Clips.songSamples,
            tracks: [Track(name: "Lead", gainDb: -6, clips: [withSound]), Track(name: "Double", clips: [dry])],
            recordings: [recording]
        )
        project.normalizeTakes()
        let sounds = [recording.id: Clips.voice(samples: 20_000)]
        let sound = Self.finished(18_000)
        // The tail reaches over the whole of the dry clip, which starts on sample 24,000 of the song.
        let made = Self.sound(sound, for: withSound, tail: 10_000)
        let mono = OfflineMix.render(project, recordings: sounds, peaks: RecordingPeaks().lookup(in: sounds), edgeFadeMs: 5, voices: .none)
        var onlyDry = mono
        onlyDry.replaceSubrange(13_000..<21_000, with: [Float](repeating: 0, count: 8_000))

        let engine = try await Self.engine()
        await engine.setClips(
            of: project, recordings: sounds, finished: made.lookup, finishedSamples: made.samples, edgeFadeMs: 5, voices: .none
        )
        try await engine.play(from: 0)
        let played = try await engine.renderOffline(frames: Clips.songSamples)

        let gain = Float(pow(10, -6.0 / 20))
        for place in 0..<Clips.songSamples {
            let inSound = (13_000..<31_000).contains(place)
            let left = onlyDry[place] + (inSound ? sound.left[place - 13_000] * gain : 0)
            let right = onlyDry[place] + (inSound ? sound.right[place - 13_000] * gain : 0)
            guard abs(played.left[place] - left) < 1e-6, abs(played.right[place] - right) < 1e-6 else {
                Issue.record("Sample \(place) of the song is \(played.left[place]) and \(played.right[place]), not \(left) and \(right)")
                return
            }
        }
    }

    @Test("A project without any finished sound plays what it played before, the same on both sides")
    func withoutFinishedSounds() async throws {
        let recording = Recording(lengthSamples: 20_000, rawStart: 0.25)
        var clip = Clips.clip(recording, 1_000..<9_000)
        clip.gainDb = -3
        let project = Clips.project([recording], [clip])
        let sounds = [recording.id: Clips.voice(samples: 20_000)]
        let row = OfflineMix.render(project, recordings: sounds, peaks: RecordingPeaks().lookup(in: sounds), edgeFadeMs: 5, voices: .none)
        // A finished sound of a clip that is not in the project, with its samples, changes nothing.
        let stray = Self.sound(Self.finished(9_000), for: Clips.clip(recording, 0..<9_000), tail: 0)

        let engine = try await Self.engine()
        await engine.setClips(of: project, recordings: sounds, edgeFadeMs: 5, voices: .none)
        try await engine.play(from: 0)
        let plain = try await engine.renderOffline(frames: Clips.songSamples)
        await engine.stop()
        await engine.setClips(
            of: project, recordings: sounds, finished: stray.lookup, finishedSamples: stray.samples, edgeFadeMs: 5, voices: .none
        )
        try await engine.play(from: 0)
        let withStray = try await engine.renderOffline(frames: Clips.songSamples)
        await engine.stop()
        // And a finished sound of this clip whose samples are not handed over leaves the clip dry.
        let missing = Self.sound(Self.finished(9_000), for: clip, tail: 1_000)
        await engine.setClips(of: project, recordings: sounds, finished: missing.lookup, edgeFadeMs: 5, voices: .none)
        try await engine.play(from: 0)
        let withoutSamples = try await engine.renderOffline(frames: Clips.songSamples)

        for played in [plain, withStray, withoutSamples] {
            #expect(played.left == row)
            #expect(played.right == row)
        }
    }

    @Test("A finished sound that was made again is heard, and so is the clip going back to dry")
    func madeAgain() async throws {
        let recording = Recording(lengthSamples: 20_000, rawStart: 0.25)
        let clip = Clips.clip(recording, 1_000..<9_000)
        let project = Clips.project([recording], [clip])
        let voice = Clips.voice(samples: 20_000)
        let sounds = [recording.id: voice]
        let first = Self.sound(Self.finished(8_000), for: clip, tail: 0)
        // The same length at the same place: only its id and its samples are new.
        let second = Self.sound(Self.finished(8_000, sign: -1), for: clip, tail: 0)
        let engine = try await Self.engine()

        await engine.setClips(of: project, recordings: sounds, finished: first.lookup, finishedSamples: first.samples, edgeFadeMs: 0, voices: .none)
        try await engine.play(from: 0.25)
        let before = try await engine.renderOffline(frames: 2_000)
        await engine.stop()
        #expect(before.left[1_000] == first.samples[first.id]?.left[0])

        await engine.setClips(of: project, recordings: sounds, finished: second.lookup, finishedSamples: second.samples, edgeFadeMs: 0, voices: .none)
        try await engine.play(from: 0.25)
        let after = try await engine.renderOffline(frames: 2_000)
        await engine.stop()
        #expect(after.left[1_000] == second.samples[second.id]?.left[0])
        #expect(after.right[1_999] == second.samples[second.id]?.right[999])

        await engine.setClips(of: project, recordings: sounds, edgeFadeMs: 0, voices: .none)
        try await engine.play(from: 0.25)
        let dry = try await engine.renderOffline(frames: 2_000)
        #expect(dry.left[1_000] == voice[1_000])
        #expect(dry.right[1_000] == voice[1_000])
    }

    @Test("While the song plays, a finished sound takes over from the dry clip within 100 ms, over the crossfade asked for")
    func takesOverWhilePlaying() async throws {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        let clip = Clips.clip(recording, 0..<48_000)
        let project = Clips.project([recording], [clip])
        let voice = Clips.voice(samples: 48_000)
        let sound = Self.finished(48_000)
        let made = Self.sound(sound, for: clip, tail: 0)
        let engine = try await Self.engine()
        await engine.setClips(of: project, recordings: [recording.id: voice], edgeFadeMs: 0, voices: .none)
        try await engine.play(from: 0.1)
        let dry = try await engine.renderOffline(frames: 3_000)
        #expect(dry.left == Array(voice[4_800..<7_800]))

        await engine.setClips(
            of: project, recordings: [recording.id: voice], finished: made.lookup, finishedSamples: made.samples,
            edgeFadeMs: 0, crossfadeMs: 10, voices: .none
        )
        let played = try await Clips.renderAtDeviceSpeed(engine, frames: 9_600)

        // The first sample that is no longer the voice is where the crossfade begins, on both sides at once.
        let first = 7_800
        let start = try #require(played.left.indices.first { played.left[$0] != voice[first + $0] })
        #expect(played.right.indices.first { played.right[$0] != voice[first + $0] } == start)
        #expect(start + 480 <= 4_800)
        for step in 0..<480 {
            let rising = (Float(step) + 0.5) / 480
            let place = first + start + step
            #expect(abs(played.left[start + step] - ((1 - rising) * voice[place] + rising * sound.left[place])) < 1e-6)
            #expect(abs(played.right[start + step] - ((1 - rising) * voice[place] + rising * sound.right[place])) < 1e-6)
        }
        #expect(played.left[(start + 480)...].indices.allSatisfy { played.left[$0] == sound.left[first + $0] })
        #expect(played.right[(start + 480)...].indices.allSatisfy { played.right[$0] == sound.right[first + $0] })
    }
}

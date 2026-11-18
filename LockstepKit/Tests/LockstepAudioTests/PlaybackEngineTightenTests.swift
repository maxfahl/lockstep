import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// Tightened clips and the Before / After switch, on the real engine without a sound device (see
/// `PlaybackEngineTests` and `PlaybackEngineClipTests`, whose song and helpers these tests use). Nothing can be
/// heard: the tests look at the samples the engine would have sent to the speakers.
///
/// How a tightened sound is made is tested where it is made (`ClipTighteningTests`). Here the tightened sound
/// is any row of samples that can be told from the recording, because the engine only has to play the right
/// one at the right place, and to get from one to the other without a click or a slip.
@Suite("PlaybackEngine, tightened clips")
struct PlaybackEngineTightenTests {
    typealias Clips = PlaybackEngineClipTests

    /// A stand-in for a tightened sound: sample `n` is `-(n + 1) / 262144`, so it has the recording's shape
    /// and can never be taken for it.
    static func tightened(samples count: Int) -> [Float] {
        (0..<count).map { -Float($0 + 1) / 262_144 }
    }

    /// A project with one track that holds this clip, with the clip's lines tightened.
    static func project(_ recording: Recording, _ clip: Clip) -> Project {
        var clip = clip
        clip.tighten = .lines
        return Project(
            songLengthSamples: Clips.songSamples,
            tracks: [Track(name: "Track 1", clips: [clip])],
            recordings: [recording]
        )
    }

    @Test("A tightened sound is heard in place of its segment, at the segment's place, also from the middle")
    func tightenedSoundPlaysAtItsPlace() async throws {
        // The recording began a quarter of a second into the song, and the clip plays samples 1,000 to 5,000.
        let recording = Recording(lengthSamples: 6_000, rawStart: 0.25)
        let clip = Clips.clip(recording, 1_000..<5_000)
        let project = Self.project(recording, clip)
        let voice = Clips.voice(samples: 6_000)
        // The tightened sound has the segment's length. Its sample 0 is the segment's first sample.
        let tight = Self.tightened(samples: 4_000)
        let tightID = UUID()
        var lookup = TightenedSounds()
        lookup.set(tightID, for: clip.segments[0], at: 0, of: clip.id, madeFrom: .recordings)
        var row = Clips.silence()
        Clips.lay(tight, 0..<4_000, at: 13_000, into: &row)

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClips(of: project, recordings: [recording.id: voice, tightID: tight], tightened: lookup, edgeFadeMs: 0, voices: .none)
        try await engine.play(from: 0)
        let fromTheStart = try await engine.renderOffline(frames: 20_000)
        #expect(Clips.inStep(fromTheStart, with: row, from: 0))
        #expect(Clips.clipValues(fromTheStart)[13_000] == tight[0])
        #expect(Clips.clipValues(fromTheStart)[16_999] == tight[3_999])
        await engine.stop()

        // From 0.3 s, which is 1,400 samples into the segment.
        try await engine.play(from: 0.3)
        let fromInside = try await engine.renderOffline(frames: 5_000)
        #expect(Clips.inStep(fromInside, with: row, from: 14_400))
        #expect(Clips.clipValues(fromInside)[0] == tight[1_400])
    }

    @Test("Before and After flip within 100 ms while playing, over a 10 ms crossfade, and the song never slips")
    func beforeAndAfterFlipWhilePlaying() async throws {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        let clip = Clips.clip(recording, 0..<48_000)
        let project = Self.project(recording, clip)
        let voice = Clips.voice(samples: 48_000)
        let tight = Self.tightened(samples: 48_000)
        let tightID = UUID()
        let sounds = [recording.id: voice, tightID: tight]
        var lookup = TightenedSounds()
        lookup.set(tightID, for: clip.segments[0], at: 0, of: clip.id, madeFrom: .recordings)
        // The clip covers the whole song, so the rows are the two sounds themselves.
        let before = voice
        let after = tight
        let fade = 480

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClips(of: project, recordings: sounds, tightened: lookup, edgeFadeMs: 0, voices: .none)
        try await engine.play(from: 0.1)
        #expect(Clips.inStep(try await engine.renderOffline(frames: 3_000), with: after, from: 4_800))

        /// Checks what came out after a flip from `old` to `new`, from sample `first` of the song on: the old
        /// sound untouched, then 10 ms in which it fades into the new one, then the new sound untouched, all
        /// within 100 ms, with the song in step.
        func expectCrossfade(
            _ sound: (left: [Float], right: [Float]), from old: [Float], to new: [Float], first: Int
        ) throws {
            #expect(Clips.songInStep(sound, from: first))
            let values = Clips.clipValues(sound)
            // The first sample that is no longer the old sound is where the crossfade begins.
            let start = try #require(values.indices.first { values[$0] != old[first + $0] })
            // The new sound alone is heard within 100 ms (4,800 samples) of the flip.
            #expect(start + fade <= 4_800)
            // The levels of the two always add up to 1, and they are read in the middle of each sample.
            for step in 0..<fade {
                let rising = (Float(step) + 0.5) / Float(fade)
                let place = first + start + step
                let expected = (1 - rising) * old[place] + rising * new[place]
                #expect(abs(values[start + step] - expected) < 1e-6)
            }
            // From the end of the crossfade on it is the new sound, sample for sample, with none lost or doubled.
            #expect(values[(start + fade)...].indices.allSatisfy { values[$0] == new[first + $0] })
        }

        // Before: the clips are handed over without the lookup.
        await engine.setClips(of: project, recordings: sounds, edgeFadeMs: 0, crossfadeMs: 10, voices: .none)
        #expect(engine.isPlaying)
        try expectCrossfade(try await Clips.renderAtDeviceSpeed(engine, frames: 9_600), from: after, to: before, first: 7_800)

        // After again.
        await engine.setClips(of: project, recordings: sounds, tightened: lookup, edgeFadeMs: 0, crossfadeMs: 10, voices: .none)
        try expectCrossfade(try await Clips.renderAtDeviceSpeed(engine, frames: 9_600), from: before, to: after, first: 17_400)
        #expect(engine.isPlaying)
    }

    @Test("A crossfade to no clips at all fades the clips out, and one from none fades them in")
    func crossfadeToAndFromSilence() async throws {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        let voice = Clips.hum(samples: 48_000)
        var project = Self.project(recording, Clips.clip(recording, 0..<48_000))
        let engine = try await PlaybackEngineTests.engine()
        await engine.setClips(of: project, recordings: [recording.id: voice], edgeFadeMs: 0, voices: .none)
        try await engine.play(from: 0)
        _ = try await engine.renderOffline(frames: 2_000)

        // The only clip is muted: the hum, which is 0.25 all through, falls to silence over 480 samples.
        project.tracks[0].clips[0].muted = true
        await engine.setClips(of: project, recordings: [recording.id: voice], edgeFadeMs: 0, crossfadeMs: 10, voices: .none)
        let out = Clips.clipValues(try await Clips.renderAtDeviceSpeed(engine, frames: 9_600))
        let fall = try #require(out.indices.first { out[$0] != 0.25 })
        #expect(fall + 480 <= 4_800)
        #expect((1..<480).allSatisfy { out[fall + $0] < out[fall + $0 - 1] })
        #expect(out[(fall + 480)...].allSatisfy { $0 == 0 })

        // And back.
        project.tracks[0].clips[0].muted = false
        await engine.setClips(of: project, recordings: [recording.id: voice], edgeFadeMs: 0, crossfadeMs: 10, voices: .none)
        let back = Clips.clipValues(try await Clips.renderAtDeviceSpeed(engine, frames: 9_600))
        let rise = try #require(back.indices.first { back[$0] != 0 })
        #expect(rise + 480 <= 4_800)
        #expect((1..<480).allSatisfy { back[rise + $0] > back[rise + $0 - 1] })
        #expect(back[(rise + 480)...].allSatisfy { $0 == 0.25 })
    }
}

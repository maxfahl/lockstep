import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// Each clip's volume, on the real engine without a sound device (see `PlaybackEngineTests`). Nothing can be
/// heard: the tests look at the samples the engine would have sent to the speakers.
///
/// The song of these tests is one second of silence, so what comes out is the mix of the clips alone and can be
/// compared with the recordings number for number. The clips have no fades at their edges, for the same reason.
@Suite("PlaybackEngine, clip volume")
struct PlaybackEngineClipGainTests {
    typealias Clips = PlaybackEngineClipTests

    /// An engine with a silent song of one second loaded.
    static func engine() async throws -> PlaybackEngine {
        let engine = try PlaybackEngine(offlineWithMaximumFrames: 4_096)
        await engine.load(song: [Float](repeating: 0, count: Clips.songSamples * 2))
        return engine
    }

    /// The whole mix of these clips: what comes out when the song is played from start to end.
    static func mix(of project: Project, _ sounds: [UUID: [Float]]) async throws -> [Float] {
        let engine = try await engine()
        await engine.setClips(of: project, recordings: sounds, edgeFadeMs: 0, voices: .none)
        try await engine.play(from: 0)
        let sound = try await engine.renderOffline(frames: Clips.songSamples)
        #expect(sound.left == sound.right)
        return sound.left
    }

    /// A sample value that is this many dB below full scale.
    static func level(_ db: Double) -> Float {
        Float(pow(10, db / 20))
    }

    @Test("The mix of a clip at -6 dB is the raw mix times 0.501, however the -6 dB is made up")
    func clipAtMinusSixDb() async throws {
        let recording = Recording(lengthSamples: 20_000, rawStart: 0.1)
        let voice = Clips.voice(samples: 20_000)
        var clip = Clips.clip(recording, 0..<20_000)
        var project = Clips.project([recording], [clip])
        let raw = try await Self.mix(of: project, [recording.id: voice])
        // The clip really is in there, as recorded.
        #expect(raw[4_800] == voice[0] && raw[24_799] == voice[19_999] && raw[24_800] == 0)

        // Max turned it down 6 dB.
        clip.gainDb = -6
        project.tracks[0].clips = [clip]
        let turnedDown = try await Self.mix(of: project, [recording.id: voice])
        let factor = Float(pow(10, -6.0 / 20))
        #expect(abs(factor - 0.501) < 0.0005)
        #expect(turnedDown == raw.map { $0 * factor })

        // Normalize took 4 dB away, Max gave 1 back, and the part carries -3 of its own: -6 dB again.
        clip.normalizeGainDb = -4
        clip.gainDb = 1
        clip.segments[0].gainDb = -3
        project.tracks[0].clips = [clip]
        #expect(try await Self.mix(of: project, [recording.id: voice]) == turnedDown)
    }

    @Test("A clip turned up as far as it goes never comes out above -1 dBFS")
    func safeLimit() async throws {
        // The recording peaks at -3 dBFS, downward, in one place. Asked for +22 dB, it is given +2.
        let recording = Recording(lengthSamples: 20_000, rawStart: 0.1)
        var sound = [Float](repeating: 0.05, count: 20_000)
        sound[7_000] = -Self.level(-3)
        var clip = Clips.clip(recording, 0..<20_000)
        clip.gainDb = 12
        clip.normalizeGainDb = 10
        let mix = try await Self.mix(of: Clips.project([recording], [clip]), [recording.id: sound])

        let highest = mix.reduce(0) { max($0, abs($1)) }
        #expect(highest <= Self.level(-1) * 1.000001)
        #expect(abs(highest - Self.level(-1)) < 0.0001)
        #expect(abs(mix[11_800]) == highest)
        // The rest of the clip is raised by the same 2 dB.
        #expect(abs(mix[5_000] - 0.05 * Self.level(2)) < 0.0001)
    }

    @Test("A clip held back by the safe limit, split so one piece no longer holds the peak, sounds as it did")
    func splitOfAHeldBackClip() async throws {
        // The first half of the recording peaks at -3 dBFS and the second half is far quieter. Asked for +6 dB,
        // the clip is given +2 dB.
        let recording = Recording(lengthSamples: 40_000, rawStart: 0.1)
        var sound = Clips.voice(samples: 40_000).map { $0 * 0.1 }
        sound[9_000] = Self.level(-3)
        let sounds = [recording.id: sound]
        var clip = Clips.clip(recording, 0..<40_000)
        clip.gainDb = 6
        var project = Clips.project([recording], [clip])
        let before = try await Self.mix(of: project, sounds)
        #expect(abs(before[4_800 + 9_000] - Self.level(-1)) < 0.0001)
        #expect(abs(before[4_800 + 30_000] - sound[30_000] * Self.level(2)) < 0.000001)

        // Split in the middle, as the app does it: with the peaks of the recordings.
        let peaks = RecordingPeaks().lookup(in: sounds)
        let pieces = project.splitClip(clip.id, at: 0.1 + 20_000.0 / 48_000, peaks: peaks, voices: .none)
        #expect(pieces != nil)
        #expect(project.tracks[0].clips.count == 2)
        let after = try await Self.mix(of: project, sounds)
        // Both pieces are as loud as before. The volume is worked out anew, so the last digit may differ.
        #expect(zip(before, after).allSatisfy { abs($0 - $1) <= 0.000001 })
        // The quiet piece did not go up to the +6 dB it now has room for.
        #expect(abs(after[4_800 + 30_000] - sound[30_000] * Self.level(2)) < 0.000001)

        // Joined again, still the same.
        let joined = project.joinClips(Set(project.tracks[0].clips.map(\.id)), peaks: peaks, voices: .none)
        #expect(joined != nil)
        let again = try await Self.mix(of: project, sounds)
        #expect(zip(before, again).allSatisfy { abs($0 - $1) <= 0.000001 })
    }

    @Test("A changed volume is heard within 100 ms while the song plays on")
    func volumeChangesWhilePlaying() async throws {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        let hum = Clips.hum(samples: 48_000)
        var project = Clips.project([recording], [Clips.clip(recording, 0..<48_000)])

        let engine = try await Self.engine()
        await engine.setClips(of: project, recordings: [recording.id: hum], edgeFadeMs: 0, voices: .none)
        try await engine.play(from: 0)
        #expect(try await engine.renderOffline(frames: 3_000).left.allSatisfy { $0 == 0.25 })

        // Turned down 6 dB, as a move of the volume control does.
        project.tracks[0].clips[0].gainDb = -6
        await engine.setClips(of: project, recordings: [recording.id: hum], edgeFadeMs: 0, voices: .none)
        #expect(engine.isPlaying)
        let sound = try await Clips.renderAtDeviceSpeed(engine, frames: 9_600).left
        let quieter = 0.25 * Float(pow(10, -6.0 / 20))
        let firstQuieter = try #require(sound.firstIndex(of: quieter))
        #expect(firstQuieter <= 4_800)
        #expect(sound[firstQuieter...].allSatisfy { $0 == quieter })
        // Until then the clip plays on as loud as it was, with no gap.
        #expect(sound[..<firstQuieter].allSatisfy { $0 == 0.25 })
        #expect(abs(engine.position - 12_600.0 / 48_000) < 0.000_1)
    }
}

/// The measuring of how high recordings peak, which the safe limit rests on.
@Suite("RecordingPeaks")
struct RecordingPeaksTests {
    @Test("The peak of a stretch is its highest sample without its sign, and only that stretch counts")
    func peakOfAStretch() {
        let id = UUID()
        var sound = [Float](repeating: 0.1, count: 1_000)
        sound[100] = 0.5
        sound[600] = -0.8
        let sounds = [id: sound]
        let peaks = RecordingPeaks()

        #expect(peaks.peak(of: id, samples: 0..<1_000, in: sounds) == 0.8)
        #expect(peaks.peak(of: id, samples: 0..<600, in: sounds) == 0.5)
        #expect(peaks.peak(of: id, samples: 600..<601, in: sounds) == 0.8)
        #expect(peaks.peak(of: id, samples: 101..<600, in: sounds) == 0.1)
        // Asked again, the answer is the same.
        #expect(peaks.peak(of: id, samples: 0..<600, in: sounds) == 0.5)
        // A stretch that reaches outside the sound is kept inside it.
        #expect(peaks.peak(of: id, samples: -50..<5_000, in: sounds) == 0.8)
        #expect(peaks.peak(of: id, samples: 2_000..<3_000, in: sounds) == 0)
        #expect(peaks.peak(of: id, samples: 300..<300, in: sounds) == 0)
        // A recording there is no sound for is silent.
        #expect(peaks.peak(of: UUID(), samples: 0..<1_000, in: sounds) == 0)

        // The form `LockstepCore` asks in.
        let lookup = peaks.lookup(in: sounds)
        #expect(lookup(id, 0..<1_000) == 0.8)
        let clip = Clip(segments: [Segment(recordingID: id, inSample: 0, outSample: 600)], gainDb: 12)
        #expect(abs(clip.appliedGain(peaks: lookup).db - (-1 - 20 * log10(0.5))) < 0.000_001)
    }
}

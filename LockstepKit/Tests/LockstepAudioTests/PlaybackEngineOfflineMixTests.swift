import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// What the engine plays of the clips is the row `OfflineMix` gives, so playing and the export that is built on
/// `OfflineMix` cannot differ. On the real engine without a sound device: nothing can be heard.
///
/// The song and the way the clips are told from it are those of `PlaybackEngineClipTests`.
@Suite("PlaybackEngine, clips against the offline mix")
struct PlaybackEngineOfflineMixTests {
    @Test("A joined clip with gaps, volumes and the 5 ms fades comes out of the engine as the offline mix has it")
    func engineMatchesOfflineMix() async throws {
        // The recording began a tenth of a second into the song.
        let recording = Recording(lengthSamples: 30_000, rawStart: 0.1)
        let sound = PlaybackEngineClipTests.voice(samples: 30_000)
        let sounds = [recording.id: sound]
        var first = PlaybackEngineClipTests.clip(recording, 1_000..<6_000)
        first.gainDb = -3
        var second = PlaybackEngineClipTests.clip(recording, 9_000..<15_000)
        second.gainDb = 2
        let third = PlaybackEngineClipTests.clip(recording, 20_000..<29_000)
        var project = PlaybackEngineClipTests.project([recording], [first, second, third])
        let done = project.joinClips([first.id, second.id, third.id], voices: .none)
        #expect(done != nil)
        #expect(project.tracks[0].clips[0].segments.count == 3)

        // The engine measures the peaks itself, so the offline mix is given the same answers.
        let peaks = RecordingPeaks().lookup(in: sounds)
        let row = OfflineMix.render(project, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none)
        #expect(row.count == PlaybackEngineClipTests.songSamples)
        #expect(row.contains { $0 != 0 })

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClips(of: project, recordings: sounds, edgeFadeMs: 5, voices: .none)
        try await engine.play(from: 0)
        let played = try await engine.renderOffline(frames: PlaybackEngineClipTests.songSamples)
        await engine.stop()

        #expect(PlaybackEngineClipTests.songInStep(played, from: 0))
        // The song is added to the clips on the way out and taken away again here, which costs the last digit.
        let values = PlaybackEngineClipTests.clipValues(played)
        #expect(values.indices.allSatisfy { abs(values[$0] - row[$0]) < 1e-6 })
    }
}

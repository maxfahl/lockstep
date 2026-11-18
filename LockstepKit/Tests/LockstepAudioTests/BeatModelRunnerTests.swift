import Foundation
import Synchronization
import Testing
import LockstepCore
@testable import LockstepAudio

/// The tests marked "needs the model" use the beat model installed on this Mac
/// (`Scripts/install-beat-model.sh`). They run one after the other because the model is heavy.
@Suite(.serialized) struct BeatModelRunnerTests {
    // MARK: Cutting into chunks and joining

    @Test func chunksStartWhereTheOriginalStartsThem() {
        #expect(BeatModelRunner.chunkStarts(frameCount: 0) == [])
        // Up to 1,488 frames: one chunk.
        #expect(BeatModelRunner.chunkStarts(frameCount: 601) == [-6])
        #expect(BeatModelRunner.chunkStarts(frameCount: 1_488) == [-6])
        // One frame more: a second chunk, moved back to end 6 frames after the song.
        #expect(BeatModelRunner.chunkStarts(frameCount: 1_489) == [-6, -5])
        // An example worked out by hand from the model's own chunking code.
        #expect(BeatModelRunner.chunkStarts(frameCount: 3_501) == [-6, 1_482, 2_007])
        // Max's reference song.
        #expect(BeatModelRunner.chunkStarts(frameCount: 10_599).count == 8)
    }

    /// A stand-in for the model that answers, for each frame of a chunk, with the number of the
    /// chunk and the song frame it saw there. The joined result then shows which chunk every
    /// frame was taken from.
    @Test func overlappingChunksAreJoinedKeepingTheEarlierOne() async throws {
        let frames = 3_501
        // Band 0 of every frame holds the frame's own number, plus 1 so that silence (0) stands out.
        var values = [Float](repeating: 0, count: frames * 128)
        for frame in 0..<frames { values[frame * 128] = Float(frame + 1) }
        let calls = Mutex(0)
        let fractions = Mutex<[Double]>([])

        let output = try await BeatModelRunner.run(
            BeatSpectrogram(values: values, frameCount: frames),
            progress: { fraction in fractions.withLock { $0.append(fraction) } }
        ) { chunk in
            let call = calls.withLock { count in
                count += 1
                return count
            }
            #expect(chunk.count == 1_500 * 128)
            return (0..<1_500).flatMap { [chunk[$0 * 128], Float(call)] }
        }

        #expect(calls.withLock { $0 } == 3)
        #expect(fractions.withLock { $0 } == [1.0 / 3, 2.0 / 3, 1])
        #expect(output.frameCount == frames)
        for frame in 0..<frames {
            // Every frame got the answer for itself, not for a neighbour or for the padding.
            #expect(output.logits[frame * 2] == Float(frame + 1))
        }
        // Chunk 1 gives frames 0 to 1,487, chunk 2 gives 1,488 to 2,975, and the moved chunk 3
        // only what is left, although it also covers frames from 2,013.
        let chunkOfFrame = (0..<frames).map { Int(output.logits[$0 * 2 + 1]) }
        #expect(chunkOfFrame[0..<1_488].allSatisfy { $0 == 1 })
        #expect(chunkOfFrame[1_488..<2_976].allSatisfy { $0 == 2 })
        #expect(chunkOfFrame[2_976..<frames].allSatisfy { $0 == 3 })
    }

    @Test func aShortSongIsFilledUpWithSilenceAndThePaddingIsThrownAway() async throws {
        let frames = 601
        let values = [Float](repeating: 1, count: frames * 128)

        let output = try await BeatModelRunner.run(BeatSpectrogram(values: values, frameCount: frames)) { chunk in
            // 6 frames of silence, the 601 frames of the song, then silence to the end.
            #expect(chunk[0..<(6 * 128)].allSatisfy { $0 == 0 })
            #expect(chunk[(6 * 128)..<(607 * 128)].allSatisfy { $0 == 1 })
            #expect(chunk[(607 * 128)...].allSatisfy { $0 == 0 })
            // Answer: 5 where there is sound, -5 where there is silence.
            return (0..<1_500).flatMap { frame in [chunk[frame * 128] == 1 ? Float(5) : -5, -5] }
        }

        #expect(output.frameCount == frames)
        #expect((0..<frames).allSatisfy { output.logits[$0 * 2] == 5 })
        #expect(BeatModelRunner.chunkStarts(frameCount: frames) == [-6])
    }

    @Test func cancellingStopsBetweenChunks() async {
        let spectrogram = BeatSpectrogram(values: [Float](repeating: 0, count: 3_501 * 128), frameCount: 3_501)
        let calls = Mutex(0)
        let task = Task {
            try await BeatModelRunner.run(spectrogram) { _ in
                calls.withLock { $0 += 1 }
                // The song is given up for another one while its first chunk is in the model.
                withUnsafeCurrentTask { $0?.cancel() }
                return [Float](repeating: -5, count: 3_000)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls.withLock { $0 } == 1)
    }

    // MARK: Picking beats

    @Test func aPeakIsTheLargestPositiveLogitWithinThreeFrames() {
        var logits = [Float](repeating: -5, count: 100)
        logits[10] = 4                  // a beat
        logits[13] = 3                  // within 3 frames of a larger one: not a beat
        logits[14] = 2
        logits[30] = -0.5               // the largest around, but not above 0
        logits[50] = 2; logits[51] = 2  // two equal neighbours: one beat between them
        logits[70] = 1; logits[74] = 1.5 // 4 frames apart: both
        logits[99] = 6                  // the last frame

        let times = BeatModelRunner.peaks(in: logits)

        #expect(times == [0.2, 1.01, 1.4, 1.48, 1.98])
        #expect(BeatModelRunner.peaks(in: []).isEmpty)
        #expect(BeatModelRunner.peaks(in: [Float](repeating: -1, count: 20)).isEmpty)
    }

    @Test func barStartsAreMovedOntoTheNearestBeat() {
        var logits = [Float](repeating: -5, count: 200 * 2)
        for frame in [10, 40, 70, 100, 130] { logits[frame * 2] = 5 }
        // Bar-start peaks: one a frame late, two that both belong to the beat at frame 70.
        for frame in [11, 66, 73] { logits[frame * 2 + 1] = 5 }

        let output = BeatModelOutput(logits: logits)

        #expect(output.beats == [0.2, 0.8, 1.4, 2.0, 2.6])
        #expect(output.barStarts == [0.2, 1.4])
        // With no beats at all, bar starts stay where they are.
        var onlyBars = [Float](repeating: -5, count: 40)
        onlyBars[21] = 5
        #expect(BeatModelOutput(logits: onlyBars).barStarts == [0.2])
    }

    // MARK: Against the original (needs the model)

    /// The whole chain on the 70 second test sound: three chunks, the last one moved back.
    @Test func matchesTheOriginalOnThreeChunks() async throws {
        let fixture = BeatFixture.reference
        let expected = try fixture.logits()
        let picked = try fixture.picked()
        let model = try await BeatModel(url: try installedModelURL())
        let spectrogram = BeatFrontEnd.spectrogram(of: try fixture.samples(), sampleRate: 22_050)

        let output = try await BeatModelRunner.run(spectrogram, model: model)

        #expect(output.logits.count == expected.count)
        let differences = zip(output.logits, expected).map { abs($0 - $1) }
        let mean = differences.reduce(0, +) / Float(differences.count)
        let furthestOff = differences.max() ?? 1
        // No jump where the chunks join: frames 1,488 and 2,976, and 2,013 where the moved chunk begins.
        var furthestOffAtJoins: Float = 0
        for join in [1_488, 2_013, 2_976] {
            let values: ArraySlice<Float> = differences[((join - 8) * 2)..<((join + 8) * 2)]
            furthestOffAtJoins = max(furthestOffAtJoins, values.max() ?? 1)
        }
        print("Logits against the original over three chunks: mean \(mean), furthest off \(furthestOff), at the joins \(furthestOffAtJoins)")
        #expect(mean < 0.05)
        #expect(furthestOffAtJoins < 0.05)

        #expect(output.beats.count == picked.beats.count)
        #expect(output.barStarts.count == picked.barStarts.count)
        #expect(zip(output.beats, picked.beats).allSatisfy { abs($0 - $1) <= 0.02 + 1e-9 })
        #expect(zip(output.barStarts, picked.barStarts).allSatisfy { abs($0 - $1) <= 0.02 + 1e-9 })
    }

    /// The 12 second sound is shorter than a chunk. The original runs it as a chunk of its own
    /// length, which the Core ML model cannot do, so here it is filled up with silence. The
    /// logits then differ from the original's, but the beats picked from them must not.
    @Test func aShortSoundGivesTheSameBeatsAsTheOriginal() async throws {
        let fixture = BeatFixture.short
        let expected = try fixture.logits()
        let picked = try fixture.picked()
        let model = try await BeatModel(url: try installedModelURL())
        let spectrogram = BeatFrontEnd.spectrogram(of: try fixture.samples(), sampleRate: 22_050)

        let output = try await BeatModelRunner.run(spectrogram, model: model)

        #expect(output.logits.count == expected.count)
        let differences = zip(output.logits, expected).map { abs($0 - $1) }
        print("Logits of the padded short sound against the original: mean \(differences.reduce(0, +) / Float(differences.count)), furthest off \(differences.max() ?? 0)")
        #expect(output.beats.count == picked.beats.count)
        #expect(output.barStarts.count == picked.barStarts.count)
        #expect(zip(output.beats, picked.beats).allSatisfy { abs($0 - $1) <= 0.02 + 1e-9 })
        #expect(zip(output.barStarts, picked.barStarts).allSatisfy { abs($0 - $1) <= 0.02 + 1e-9 })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCKSTEP_SONG"] != nil))
    func wholeSongIsFasterThanThePrototype() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCKSTEP_SONG"]!)
        let song = try await SongImporter.importSong(from: url)
        let clock = ContinuousClock()
        let start = clock.now
        let model = try await BeatModel(url: try installedModelURL())
        let spectrogram = BeatFrontEnd.spectrogram(of: song)
        let output = try await BeatModelRunner.run(spectrogram, model: model)
        let taken = clock.now - start
        print("Beat model over \(song.duration) s of song: \(output.beats.count) beats and \(output.barStarts.count) bar starts in \(taken), spectrogram and loading the model included")
        #expect(output.frameCount == spectrogram.frameCount)
        // The Python prototype took 32 seconds.
        #expect(taken < .seconds(32) * (song.duration / 212))
        #expect(output.beats.count > 250)
    }

    private func installedModelURL() throws -> URL {
        let url = BeatModel.installedURL
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "The beat model is not installed. Run Scripts/install-beat-model.sh first."
        )
        return url
    }
}

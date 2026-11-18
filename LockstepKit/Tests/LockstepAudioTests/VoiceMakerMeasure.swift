import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// How fast the app's Fast maker is, and the voices it keeps, for the summary of the task that built it. A
/// tool, not a test: it only runs when `LOCKSTEP_VOICE_MAKER_MEASURE` names a WAV file of made-up speech of a
/// minute or more (`Scripts/voice-test/make-speech.sh` makes `daniel-long.wav`).
///
///     LOCKSTEP_VOICE_MAKER_MEASURE=build/voice-test/speech/daniel-long.wav \
///         swift test --package-path LockstepKit --filter VoiceMakerMeasure
///
/// For 3, 10 and 60 seconds from the start of the file, it makes the voice at Darker three times, one at a
/// time, and prints the middle time of `VoiceMaker.fast` and of `VoiceFile.takeIn`, each also for one
/// second of voice. Then it keeps the voice of a line at each of the three amounts the first gate measured (a
/// little darker, Darker and Deeper) through `VoiceFile.takeIn`, and copies each kept file beside the line as
/// `<line>.fast.d<depth>p<pitch>.wav`, for `Scripts/measure-timing.sh`. The line is the file that
/// `LOCKSTEP_VOICE_MAKER_LINE` names (`daniel-fast.wav`, the line the first gate found hardest), or else the
/// first 10 seconds of the speech, written beside it as `<name>.10s.wav`. It also prints, for every setting at the far ends of the knobs, how far the
/// quietest block that counts in the recording's loudness lay under it in the kept voice: the room the
/// 20 dB of `VoiceFile.largestDropDb` leaves.
struct VoiceMakerMeasure {
    static let file = ProcessInfo.processInfo.environment["LOCKSTEP_VOICE_MAKER_MEASURE"]
    static let lineFile = ProcessInfo.processInfo.environment["LOCKSTEP_VOICE_MAKER_LINE"]

    /// The settings measured: the three amounts of the first gate, and the far ends of the two knobs.
    static let amounts = [VoiceKnobs(depth: 3, pitch: -0.5), VoiceKnobs(depth: 6, pitch: -1), VoiceKnobs(depth: 10, pitch: -2)]
    static let farEnds = [
        VoiceKnobs(depth: 15, pitch: -4), VoiceKnobs(depth: -15, pitch: 4), VoiceKnobs(depth: 15, pitch: 4),
        VoiceKnobs(depth: -15, pitch: -4),
    ]

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The middle of three times of `work`.
    static func middleTime(_ work: () async throws -> Void) async rethrows -> Double {
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<3 {
            let started = clock.now
            try await work()
            times.append(seconds(started.duration(to: clock.now)))
        }
        return times.sorted()[1]
    }

    /// How far the quietest counted block of the recording lies under it in the voice, in dB.
    static func largestDrop(_ voice: [Float], from recording: [Float]) -> Double {
        let wanted = Loudness.integrated(recording) ?? 0
        let gain = wanted - (Loudness.integrated(voice) ?? wanted)
        return zip(Loudness.blocks(recording), Loudness.blocks(voice))
            .filter { $0.0.counts }
            .map { $0.0.lufs - ($0.1.lufs + gain) }
            .max() ?? 0
    }

    @Test(.enabled(if: file != nil, "A tool: run with LOCKSTEP_VOICE_MAKER_MEASURE set."))
    func measure() async throws {
        let source = URL(filePath: try #require(Self.file))
        let speech = try RecordingLoader.read(source)
        try #require(speech.count >= 60 * 48_000, "The file is shorter than a minute.")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockstep-voice-maker-measure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = ProjectPackage(url: folder.appendingPathComponent("Measure.lockstep", isDirectory: true))
        let darker = VoiceKnobs(depth: 6, pitch: -1)

        for length in [3, 10, 60] {
            let line = Array(speech[0..<(length * 48_000)])
            var voice: [Float] = []
            let making = try await Self.middleTime { voice = try await VoiceMaker.fast(line, knobs: darker) }
            let key = VoiceKey(recordingID: UUID(), knobs: darker, way: .fast)
            let keeping = try await Self.middleTime {
                _ = try await VoiceFile.takeIn(MadeVoice(voice), for: VoiceJob(key: key, recording: line, package: package))
            }
            print(String(
                format: "%2d s at Darker: made in %.3f s (%.4f s for each second), taken in in %.3f s (%.4f s for each second)",
                length, making, making / Double(length), keeping, keeping / Double(length)))
        }

        var lineURL = source.deletingPathExtension().appendingPathExtension("10s.wav")
        var line = Array(speech[0..<(10 * 48_000)])
        if let lineFile = Self.lineFile {
            lineURL = URL(filePath: lineFile)
            line = try RecordingLoader.read(lineURL)
        } else {
            try WavWriter.write(line, channels: 1, to: lineURL)
        }
        let stem = lineURL.deletingPathExtension().lastPathComponent
        let out = lineURL.deletingLastPathComponent()
        for knobs in Self.amounts + Self.farEnds {
            let key = VoiceKey(recordingID: UUID(), knobs: knobs, way: .fast)
            let made = try await VoiceMaker.fast(line, knobs: knobs)
            let kept = try await VoiceFile.takeIn(MadeVoice(made), for: VoiceJob(key: key, recording: line, package: package))
            print(String(
                format: "%@: gain %+.2f dB, lowered %.2f dB, quietest counted block %.2f dB under the recording",
                knobs.folderName, kept.gainDb, kept.loweredDb, Self.largestDrop(kept.samples, from: line)))
            if Self.amounts.contains(knobs) {
                let copy = out.appending(path: "\(stem).fast.\(knobs.folderName).wav")
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: kept.file, to: copy)
            }
        }
    }
}

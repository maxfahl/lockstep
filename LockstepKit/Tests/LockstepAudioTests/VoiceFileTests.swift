import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// What `VoiceFile.takeIn` refuses, what it does to a voice it keeps, and how a kept voice is read
/// again.
@Suite struct VoiceFileTests {
    /// A spoken-like recording of two seconds: a voice of 150 Hz, loud and quiet in turn as syllables are.
    private static let recording = StretchFixtures.voice(period: 320, count: 96_000) { index in
        0.6 + 0.4 * sin(2 * Double.pi * Double(index) / 9_600)
    }

    private static let key = VoiceKey(recordingID: UUID(), knobs: VoiceKnobs(depth: 6, pitch: -1), way: .fast)

    /// A project folder in a temporary place, and the folder to remove when the test is done.
    private func makeProject() -> (package: ProjectPackage, folder: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockstep-voice-file-tests-\(UUID().uuidString)", isDirectory: true)
        return (ProjectPackage(url: folder.appendingPathComponent("Song.lockstep", isDirectory: true)), folder)
    }

    private func job(_ package: ProjectPackage, recording: [Float] = recording) -> VoiceJob {
        VoiceJob(key: Self.key, recording: recording, package: package)
    }

    /// `samples` turned up or down by `db`.
    private static func scaled(_ samples: [Float], by db: Double) -> [Float] {
        let factor = Float(pow(10, db / 20))
        return samples.map { $0 * factor }
    }

    /// Takes `voice` in for the recording and gives back why it was refused, or nil when it was kept.
    private func refusal(_ voice: MadeVoice, recording: [Float] = recording) async -> VoiceFileError? {
        let (package, folder) = makeProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try await VoiceFile.takeIn(voice, for: job(package, recording: recording))
            return nil
        } catch {
            // Nothing is left on disk by a voice that was refused, under either name.
            let setting = package.voiceFile(for: Self.key).deletingLastPathComponent()
            #expect((try? FileManager.default.contentsOfDirectory(atPath: setting.path))?.isEmpty ?? true)
            return error
        }
    }

    // MARK: What is refused

    @Test func aVoiceThatIsShortOrLongIsRefused() async {
        let short = Array(Self.recording.dropLast())
        let long = Self.recording + [0]

        #expect(await refusal(MadeVoice(short)) == .wrongLength(samples: 95_999, recording: 96_000))
        #expect(await refusal(MadeVoice(long)) == .wrongLength(samples: 96_001, recording: 96_000))
    }

    @Test func aVoiceAtAnotherRateOrWithTwoChannelsIsRefused() async {
        #expect(await refusal(MadeVoice(Self.recording, sampleRate: 44_100)) == .wrongSampleRate(44_100))
        let stereo = Self.recording.flatMap { [$0, $0] }
        #expect(await refusal(MadeVoice(stereo, channels: 2)) == .notMono(channels: 2))
    }

    @Test func aVoiceWithAValueThatIsNotANumberIsRefused() async {
        var voice = Self.recording
        voice[1234] = .nan
        #expect(await refusal(MadeVoice(voice)) == .notANumber(atSample: 1234))
        voice[1234] = .infinity
        #expect(await refusal(MadeVoice(voice)) == .notANumber(atSample: 1234))
    }

    @Test func aSilentVoiceIsRefused() async {
        let silence = [Float](repeating: 0, count: Self.recording.count)

        #expect(await refusal(MadeVoice(silence)) == .noSound(atSecond: 0))
    }

    @Test func aVoiceWithAHoleWhereTheRecordingHasSoundIsRefused() async {
        // Half a second of silence from 1.0 s, where the recording speaks.
        var voice = Self.recording
        for index in 48_000..<72_000 { voice[index] = 0 }

        let refused = await refusal(MadeVoice(voice))

        guard case .noSound(let second) = refused else {
            Issue.record("refused as \(String(describing: refused))")
            return
        }
        // The first block of 400 ms that lies wholly in the hole starts at 1.0 s.
        #expect(abs(second - 1.0) < 0.05)
    }

    @Test func aVoiceTwentyDecibelsTooQuietIsRefused() async {
        let refused = await refusal(MadeVoice(Self.scaled(Self.recording, by: -20)))

        guard case .tooFarFromTheRecording(let gain) = refused else {
            Issue.record("refused as \(String(describing: refused))")
            return
        }
        #expect(abs(gain - 20) < 0.01)
    }

    @Test func aSilentRecordingStandsForItselfAndGetsNoVoice() async {
        let silence = [Float](repeating: 0, count: Self.recording.count)

        #expect(VoiceFile.standsForItself(silence))
        #expect(!VoiceFile.standsForItself(Self.recording))
        #expect(await refusal(MadeVoice(Self.recording), recording: silence) == .recordingStandsForItself)
    }

    // MARK: What is kept

    @Test func aKeptVoiceIsAsLoudAsTheRecordingAndIsTheFilesSamples() async throws {
        let (package, folder) = makeProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        let voice = Self.scaled(Self.recording, by: -6)

        let kept = try await VoiceFile.takeIn(MadeVoice(voice), for: job(package))

        let wanted = try #require(Loudness.integrated(Self.recording))
        let loudness = try #require(Loudness.integrated(kept.samples))
        #expect(abs(loudness - wanted) < 0.01)
        #expect(abs(kept.gainDb - 6) < 0.01)
        #expect(kept.loweredDb == 0)
        #expect(kept.file == package.voiceFile(for: Self.key))
        // What is handed back is what the file holds: its 24-bit values, under its own name, and the partial
        // file is gone.
        #expect(kept.samples == (try RecordingLoader.read(kept.file)))
        let names = try FileManager.default.contentsOfDirectory(atPath: kept.file.deletingLastPathComponent().path)
        #expect(names == [kept.file.lastPathComponent])
        #expect(await VoiceFile.read(Self.key, in: package, lengthSamples: Self.recording.count) == kept.samples)
    }

    @Test func aVoiceThatWouldPassFullScaleIsTurnedDownUntilItsPeakIsAtMinusATenthOfADecibel() async throws {
        let (package, folder) = makeProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The voice is 10 dB quieter than the recording, and has one sharp peak. Turned up by 10 dB, that
        // peak would lie above full scale.
        var voice = Self.scaled(Self.recording, by: -10)
        voice[40_000] = 0.6

        let kept = try await VoiceFile.takeIn(MadeVoice(voice), for: job(package))

        let peak = Loudness.peakDb(kept.samples)
        #expect(abs(peak - VoiceFile.highestPeakDb) < 0.001, "the highest sample is at \(peak) dBFS")
        let lowered = kept.gainDb - (VoiceFile.highestPeakDb - 20 * log10(0.6))
        #expect(abs(kept.loweredDb - lowered) < 0.001)
        #expect(kept.loweredDb > 0)
    }

    @Test func aKeptVoiceOfAnotherLengthIsNotReadAgain() async throws {
        let (package, folder) = makeProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await VoiceFile.read(Self.key, in: package, lengthSamples: Self.recording.count) == nil)

        _ = try await VoiceFile.takeIn(MadeVoice(Self.recording), for: job(package))

        #expect(await VoiceFile.read(Self.key, in: package, lengthSamples: Self.recording.count + 1) == nil)
    }
}

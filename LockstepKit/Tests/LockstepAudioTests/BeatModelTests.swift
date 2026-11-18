import Foundation
import Testing
@testable import LockstepAudio

/// All but the first of these need the beat model on this Mac. `Scripts/install-beat-model.sh`
/// puts it there. They run one after the other because loading the model is heavy.
@Suite(.serialized) struct BeatModelTests {
    @Test func aMissingModelIsReportedInPlainWords() async {
        let nowhere = URL(filePath: "/nonexistent/lockstep-test/BeatThis.mlpackage")
        await #expect(throws: BeatModelError.notInstalled) {
            _ = try await BeatModel(url: nowhere)
        }
        #expect(BeatModelError.notInstalled.message == "The beat model is not installed.")
    }

    @Test func theInstalledModelRunsOnSilence() async throws {
        let model = try await BeatModel(url: try installedModelURL())
        let silence = [Float](repeating: 0, count: BeatModel.frameCount * BeatModel.bandCount)

        let logits = try await model.logits(for: silence)

        #expect(logits.count == BeatModel.frameCount * BeatModel.valuesPerFrame)
        // What the original PyTorch model answers for silence, at the first, a middle and the
        // last frame: beat logit, then bar-start logit. All far below 0: no beat anywhere.
        let original: [(frame: Int, beat: Float, barStart: Float)] = [
            (0, -10.938694, -12.133381),
            (750, -10.589516, -11.784642),
            (1_499, -10.243800, -13.809855),
        ]
        for expected in original {
            #expect(abs(logits[expected.frame * 2] - expected.beat) < 0.001)
            #expect(abs(logits[expected.frame * 2 + 1] - expected.barStart) < 0.001)
        }
        #expect(logits.allSatisfy { $0 < 0 })
    }

    @Test func theCompiledCopyIsKeptNextToTheModelAndMadeAgainOnlyForANewerModel() async throws {
        // A copy of the model in a folder of the test's own, so the installed one is left alone.
        let folder = FileManager.default.temporaryDirectory.appending(path: "lockstep-beat-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "BeatThis.mlpackage")
        try FileManager.default.copyItem(at: try installedModelURL(), to: url)
        let compiled = BeatModel.compiledURL(for: url)
        #expect(compiled == folder.appending(path: "BeatThis.mlmodelc"))
        #expect(!FileManager.default.fileExists(atPath: compiled.path))

        _ = try await BeatModel(url: url)
        let firstCompile = try modificationDate(of: compiled)

        _ = try await BeatModel(url: url)
        #expect(try modificationDate(of: compiled) == firstCompile)

        // A model installed after the copy was compiled.
        try FileManager.default.setAttributes([.modificationDate: firstCompile.addingTimeInterval(60)], ofItemAtPath: url.path)
        _ = try await BeatModel(url: url)
        #expect(try modificationDate(of: compiled) != firstCompile)
    }

    @Test func aChunkOfTheWrongSizeIsRefused() async throws {
        let model = try await BeatModel(url: try installedModelURL())
        let tooShort = [Float](repeating: 0, count: 600 * BeatModel.bandCount)

        await #expect(throws: BeatModelError.wrongChunkSize(expected: 192_000, actual: 76_800)) {
            _ = try await model.logits(for: tooShort)
        }
    }

    private func installedModelURL() throws -> URL {
        let url = BeatModel.installedURL
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "The beat model is not installed. Run Scripts/install-beat-model.sh first."
        )
        return url
    }

    private func modificationDate(of url: URL) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }
}

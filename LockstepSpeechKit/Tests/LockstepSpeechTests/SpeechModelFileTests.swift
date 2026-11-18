import Foundation
import LockstepCore
import Testing
@testable import LockstepSpeech

/// A folder of its own for one test, removed when the test is over.
private final class Scratch {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LockstepSpeechTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// Writes `contents` as a pretend model file that should be `expectedLength` bytes long.
    func model(holding contents: Data, expectedLength: Int) throws -> SpeechModelFile {
        let url = folder.appendingPathComponent("model.bin")
        try contents.write(to: url)
        return SpeechModelFile(url: url, byteCount: Int64(expectedLength))
    }
}

/// What the file looks like from outside: its bytes and when it was last written.
private func state(of url: URL) throws -> (Data, Date?) {
    let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    return (try Data(contentsOf: url), written)
}

private let whole = Data((0..<5_000).map { UInt8($0 % 251) })

@Test func aModelFileOfTheRightLengthPasses() throws {
    let scratch = try Scratch()
    let model = try scratch.model(holding: whole, expectedLength: whole.count)
    try model.checkPresence(of: .swedish)
}

@Test func aMissingModelFileIsReportedAsMissing() throws {
    let scratch = try Scratch()
    let model = SpeechModelFile(url: scratch.folder.appendingPathComponent("Models/model.bin"), byteCount: 5_000)
    #expect(throws: SpeechModelError.missing(.multilingual)) { try model.checkPresence(of: .multilingual) }
    // Looking for the file must not make its folder.
    #expect(!FileManager.default.fileExists(atPath: scratch.folder.appendingPathComponent("Models").path))
}

@Test func aHalfWrittenModelFileIsRefusedAndLeftAlone() throws {
    let scratch = try Scratch()
    let model = try scratch.model(holding: whole.prefix(2_500), expectedLength: whole.count)
    let before = try state(of: model.url)

    #expect(throws: SpeechModelError.wrongSize(.swedish, found: 2_500)) { try model.checkPresence(of: .swedish) }

    let after = try state(of: model.url)
    #expect(after.0 == before.0)
    #expect(after.1 == before.1)
}

@Test func theMessagesSayHowToInstallTheModel() {
    let missing = SpeechModelError.missing(.swedish).localizedDescription
    #expect(missing.contains("Scripts/install-speech-model.sh swedish"))
    let broken = SpeechModelError.wrongSize(.multilingual, found: 10).localizedDescription
    #expect(broken.contains("Scripts/install-speech-model.sh multilingual --force"))
}

@Test func eachLanguageHasItsModel() {
    #expect(SpeechModel.for(.swedish) == .swedish)
    #expect(SpeechModel.for(.automatic) == .multilingual)
    #expect(SpeechModel.swedish.languageCode == "sv")
    #expect(SpeechModel.multilingual.languageCode == "auto")
}

/// With a model file that is not whole, whisper.cpp is never reached, and the file is still there
/// afterwards, exactly as it was.
@Test func theEngineIsNotCalledWhenTheModelFileIsNotWhole() async throws {
    let scratch = try Scratch()
    let model = try scratch.model(holding: whole.prefix(100), expectedLength: whole.count)
    let before = try state(of: model.url)
    let engine = WhisperSpeechEngine(language: .swedish) { _ in model }

    await #expect(throws: SpeechModelError.wrongSize(.swedish, found: 100)) { try await engine.prepare() }
    await #expect(throws: SpeechModelError.wrongSize(.swedish, found: 100)) {
        _ = try await engine.text(for: [0, 0.1, -0.1])
    }

    let after = try state(of: model.url)
    #expect(after.0 == before.0)
    #expect(after.1 == before.1)
    try await engine.unload()
}

@Test func theEngineAsksForTheModelOfTheChosenLanguage() async throws {
    let scratch = try Scratch()
    let folder = scratch.folder
    let engine = WhisperSpeechEngine(language: .swedish) { model in
        SpeechModelFile(url: folder.appendingPathComponent("\(model.rawValue).bin"), byteCount: 1)
    }
    await #expect(throws: SpeechModelError.missing(.swedish)) { try await engine.prepare() }
    await engine.choose(.automatic)
    await #expect(throws: SpeechModelError.missing(.multilingual)) { try await engine.prepare() }
}

@Test func noSamplesGiveNoTextWithoutTheModel() async throws {
    let scratch = try Scratch()
    let none = scratch.folder.appendingPathComponent("none.bin")
    let engine = WhisperSpeechEngine(language: .swedish) { _ in SpeechModelFile(url: none, byteCount: 1) }
    #expect(try await engine.text(for: []) == "")
}

@Test func decoderMarkersAndOuterSpacesAreTakenOut() {
    #expect(WhisperSpeechEngine.spokenText(" Hej då.<|nospeech|> ") == "Hej då.")
    #expect(WhisperSpeechEngine.spokenText("<|nospeech|>") == "")
}

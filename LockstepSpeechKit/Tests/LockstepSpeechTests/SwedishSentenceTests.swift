import AVFAudio
import Foundation
import LockstepCore
import Testing
@testable import LockstepSpeech

/// The proof that the real engine writes out Swedish, with the model that
/// `Scripts/install-speech-model.sh swedish` installs.
///
/// It loads about half a gigabyte, so it runs only when asked for:
/// `LOCKSTEP_SPEECH=1 swift test --package-path LockstepSpeechKit --filter writesOutASwedishSentence`.
/// No microphone and no loudspeaker: the sentence is made by the Mac's Swedish voice straight
/// into a file.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LOCKSTEP_SPEECH"] == "1"))
func writesOutASwedishSentence() async throws {
    let sentence = "Hej, det här är ett kort test. I dag skiner solen och vi går en promenad."
    let samples = try spoken(sentence)

    // Nothing may happen to the model's file, so note what it looks like before and after.
    let model = SpeechModel.swedish.file
    let fileBefore = try FileManager.default.attributesOfItem(atPath: model.url.path)

    let clock = ContinuousClock()
    let engine = WhisperSpeechEngine(language: .swedish)
    let any: any SpeechEngine = engine
    let memoryBefore = memoryInUse()

    var first = ""
    var second = ""
    var loading = Duration.zero
    var firstTime = Duration.zero
    var secondTime = Duration.zero
    var memoryLoaded: UInt64 = 0
    var memoryAfterText: UInt64 = 0
    do {
        loading = try await clock.measure { try await engine.prepare() }
        memoryLoaded = memoryInUse()
        firstTime = try await clock.measure { first = try await any.text(for: samples) }
        secondTime = try await clock.measure { second = try await any.text(for: samples) }
        memoryAfterText = memoryInUse()
    } catch {
        // The process must not end with the model still loaded.
        try? await any.unload()
        throw error
    }
    try await any.unload()
    let memoryUnloaded = memoryInUse()
    // Metal gives memory back a moment after it is asked to, so look once more.
    try await Task.sleep(for: .seconds(3))
    let memoryLater = memoryInUse()

    let megabyte = 1_048_576.0
    print(
        """
        LOCKSTEP_SPEECH smoke test
          sound: \(String(format: "%.2f", Double(samples.count) / 16_000)) s
          loading the model: \(loading)
          writing out, first time: \(firstTime)
          writing out, second time: \(secondTime)
          memory before loading: \(String(format: "%.0f", Double(memoryBefore) / megabyte)) MB
          memory with the model loaded: \(String(format: "%.0f", Double(memoryLoaded) / megabyte)) MB
          memory after writing out twice: \(String(format: "%.0f", Double(memoryAfterText) / megabyte)) MB
          memory right after unload: \(String(format: "%.0f", Double(memoryUnloaded) / megabyte)) MB
          memory three seconds after unload: \(String(format: "%.0f", Double(memoryLater) / megabyte)) MB
          text: \(first)
        """)

    let words = first.lowercased()
    for word in ["kort", "test", "solen", "promenad"] {
        #expect(words.contains(word), "\"\(word)\" is missing from: \(first)")
    }
    #expect(second == first)

    let fileAfter = try FileManager.default.attributesOfItem(atPath: model.url.path)
    #expect(fileAfter[.size] as? NSNumber == fileBefore[.size] as? NSNumber)
    #expect(fileAfter[.modificationDate] as? Date == fileBefore[.modificationDate] as? Date)
    #expect(fileAfter[.systemFileNumber] as? NSNumber == fileBefore[.systemFileNumber] as? NSNumber)
}

/// The proof that "Any language" writes out a language the Swedish model is not for, with the model
/// that `Scripts/install-speech-model.sh multilingual` installs, and finds the language by itself.
///
/// It loads over half a gigabyte, so it runs only when asked for:
/// `LOCKSTEP_SPEECH=1 swift test --package-path LockstepSpeechKit --filter writesOutAnEnglishSentenceInAnyLanguage`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LOCKSTEP_SPEECH"] == "1"))
func writesOutAnEnglishSentenceInAnyLanguage() async throws {
    let samples = try spoken("The sun is shining today, so we are going for a long walk.", voice: "Samantha")
    let engine = WhisperSpeechEngine(language: .automatic)

    let text: String
    do {
        text = try await engine.text(for: samples)
    } catch {
        try? await engine.unload()
        throw error
    }
    try await engine.unload()
    print("LOCKSTEP_SPEECH any language: \(text)")

    let words = text.lowercased()
    for word in ["sun", "shining", "walk"] {
        #expect(words.contains(word), "\"\(word)\" is missing from: \(text)")
    }
}

/// `sentence` as the model wants it: one channel at 16,000 Hz, said by one of the Mac's voices
/// (its Swedish one unless another is named).
///
/// `say -o` writes a file and plays nothing. The files are made in a folder of their own, which is
/// removed before this returns.
private func spoken(_ sentence: String, voice name: String = "Alva") throws -> [Float] {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("LockstepSpeechSmoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let voice = folder.appendingPathComponent("sentence.aiff")
    let wave = folder.appendingPathComponent("sentence.wav")
    try run("/usr/bin/say", "-v", name, "-o", voice.path, sentence)
    try run("/usr/bin/afconvert", "-f", "WAVE", "-d", "LEF32@16000", "-c", "1", voice.path, wave.path)

    let file = try AVAudioFile(forReading: wave)
    let format = file.processingFormat
    try #require(format.sampleRate == 16_000 && format.channelCount == 1)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData)[0]
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

private struct ToolFailed: Error, CustomStringConvertible {
    var description: String
}

/// Runs a command-line tool and throws when it does not end well. A missing Swedish voice shows
/// up here, as `say` failing.
private func run(_ tool: String, _ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolFailed(description: "\(tool) ended with \(process.terminationStatus): \(said)")
    }
}

/// The memory this process holds, as Activity Monitor counts it. It includes what Metal holds
/// for the model.
private func memoryInUse() -> UInt64 {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? usage.ri_phys_footprint : 0
}

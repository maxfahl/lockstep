import AVFAudio
import Foundation
import LockstepCore
import Testing
@testable import LockstepSpeech

/// The proof that the queue works with the real engine: three clips asked for at once come back in
/// order, and the model's memory is given back after the idle time.
///
/// It loads the Swedish model (over a gigabyte while loaded), so it runs only when asked for:
/// `LOCKSTEP_SPEECH=1 swift test --package-path LockstepSpeechKit --filter writesOutThreeClipsInOrderAndUnloads`.
/// No microphone and no loudspeaker: the sentences are made by the Mac's Swedish voice straight into
/// files. The idle time is two seconds here instead of thirty.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LOCKSTEP_SPEECH"] == "1"))
func writesOutThreeClipsInOrderAndUnloads() async throws {
    let sentences = [
        "Hej, det här är ett kort test.",
        "I dag skiner solen och vi går en promenad.",
        "Jag dricker kaffe och läser en bok.",
    ]
    let expected = [["kort", "test"], ["solen", "promenad"], ["kaffe", "bok"]]
    let clips = try spokenAt48k(sentences).map { (id: UUID(), samples: $0) }

    let (reports, reporter) = AsyncStream.makeStream(of: Transcription.self)
    let idleTime = Duration.seconds(2)
    let transcriber = Transcriber(language: .swedish, idleTime: idleTime) { reporter.yield($0) }
    let memoryBefore = footprint()

    let clock = ContinuousClock()
    let start = clock.now
    // All three at once, as when a project with three clips without text is opened.
    for clip in clips {
        await transcriber.request(clipID: clip.id, samples: clip.samples)
    }
    var results: [Transcription] = []
    var arrived: [Duration] = []
    for await report in reports {
        results.append(report)
        arrived.append(clock.now - start)
        if results.count == clips.count { break }
    }
    let memoryLoaded = footprint()

    // Past the idle time, and a little more because Metal gives memory back a moment after it is asked to.
    try await Task.sleep(for: idleTime + .seconds(4))
    let memoryIdle = footprint()

    await transcriber.shutDown()
    let memoryShutDown = footprint()

    let megabyte = 1_048_576.0
    func megabytes(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / megabyte) }
    print(
        """
        LOCKSTEP_SPEECH queue test
          sounds: \(clips.map { String(format: "%.2f s", Double($0.samples.count) / 48_000) }.joined(separator: ", "))
          texts arrived after: \(arrived.map { "\($0)" }.joined(separator: ", "))
          memory before the first request: \(megabytes(memoryBefore))
          memory when the third text arrived (model loaded): \(megabytes(memoryLoaded))
          memory \(idleTime + .seconds(4)) later (idle time \(idleTime), model unloaded by the queue): \(megabytes(memoryIdle))
          memory after shutDown: \(megabytes(memoryShutDown))
          texts: \(results.map { $0.text ?? "nil (\($0.outcome))" })
        """)

    #expect(results.map(\.clipID) == clips.map(\.id))
    for (result, words) in zip(results, expected) {
        let text = (result.text ?? "").lowercased()
        for word in words {
            #expect(text.contains(word), "\"\(word)\" is missing from: \(result.text ?? "no text")")
        }
    }
    // The model itself is about half a gigabyte of the memory. Some of what was used stays with
    // the process after unloading, so only the drop is checked.
    #expect(memoryLoaded > memoryIdle + 300 * 1_048_576, "the model was not unloaded after the idle time")
}

/// Each sentence as a clip's sound: one channel at 48,000 Hz, said by the Mac's Swedish voice.
///
/// `say -o` writes a file and plays nothing. The files are made in a folder of their own under the
/// checkout's `build` folder, which git ignores, and the folder is removed before this returns.
private func spokenAt48k(_ sentences: [String]) throws -> [[Float]] {
    // This file is LockstepSpeechKit/Tests/LockstepSpeechTests/TranscriberTests.swift.
    let checkout = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let folder = checkout.appendingPathComponent("build/SpeechQueueTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    return try sentences.enumerated().map { number, sentence in
        let voice = folder.appendingPathComponent("\(number).aiff")
        let wave = folder.appendingPathComponent("\(number).wav")
        try runTool("/usr/bin/say", "-v", "Alva", "-o", voice.path, sentence)
        try runTool("/usr/bin/afconvert", "-f", "WAVE", "-d", "LEF32@48000", "-c", "1", voice.path, wave.path)

        let file = try AVAudioFile(forReading: wave)
        let format = file.processingFormat
        try #require(format.sampleRate == 48_000 && format.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData)[0]
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

private struct ToolDidNotEndWell: Error, CustomStringConvertible {
    var description: String
}

/// Runs a command-line tool and throws when it does not end well.
private func runTool(_ tool: String, _ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolDidNotEndWell(description: "\(tool) ended with \(process.terminationStatus): \(said)")
    }
}

/// The memory this process holds, as Activity Monitor counts it. It includes what Metal holds for
/// the model.
private func footprint() -> UInt64 {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? usage.ri_phys_footprint : 0
}

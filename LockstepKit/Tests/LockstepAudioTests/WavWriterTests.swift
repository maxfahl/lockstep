import AVFoundation
import Foundation
import Testing
@testable import LockstepAudio

@Suite struct WavWriterTests {
    /// One step of a 24-bit sample, as a float.
    private let step: Float = 1 / 8_388_608

    @Test func monoRampReadsBackAsWritten() throws {
        let folder = try WavFolder()
        defer { folder.remove() }
        // From -1 up to just under 1 in 48,001 samples: an odd count, so the file needs its spare byte.
        let ramp = (0...48_000).map { Float($0) / 24_000.5 - 1 }
        let url = folder.url.appending(path: "ramp.wav")

        try WavWriter.write(ramp, channels: 1, to: url)

        let read = try readBack(url)
        #expect(read.sampleRate == 48_000)
        #expect(read.bitDepth == 24)
        #expect(read.isFloat == false)
        #expect(read.channels.count == 1)
        #expect(read.frames == 48_001)
        #expect(furthestOff(read.channels[0], ramp) <= step)
        // Nothing but the 44-byte header, the sound and the spare byte.
        #expect(try Data(contentsOf: url).count == 44 + 48_001 * 3 + 1)
    }

    @Test func stereoSineReadsBackAsWritten() throws {
        let folder = try WavFolder()
        defer { folder.remove() }
        // Half a second: 440 Hz on the left, 1 kHz and quieter on the right.
        let left = (0..<24_000).map { Float(0.8 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let right = (0..<24_000).map { Float(0.3 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        let url = folder.url.appending(path: "sine.wav")

        try WavWriter.write(zip(left, right).flatMap { [$0, $1] }, channels: 2, to: url)

        let read = try readBack(url)
        #expect(read.sampleRate == 48_000)
        #expect(read.bitDepth == 24)
        #expect(read.channels.count == 2)
        #expect(read.frames == 24_000)
        #expect(furthestOff(read.channels[0], left) <= step)
        #expect(furthestOff(read.channels[1], right) <= step)
    }

    @Test func samplesAreRoundedAndHeldInRange() throws {
        let folder = try WavFolder()
        defer { folder.remove() }
        let url = folder.url.appending(path: "edges.wav")
        // 0.4 and 0.6 of a step, the two ends, and three values no file can hold.
        let samples: [Float] = [0, 0.4 * step, 0.6 * step, -0.6 * step, 1, -1, 2.5, -2.5, .nan]

        try WavWriter.write(samples, channels: 1, to: url)

        let bytes = [UInt8](try Data(contentsOf: url)).dropFirst(44)
        let written = stride(from: bytes.startIndex, to: bytes.startIndex + samples.count * 3, by: 3).map { index in
            // The top byte is read as signed, which carries the sign of the 24-bit number.
            Int32(bytes[index]) | Int32(bytes[index + 1]) << 8 | Int32(Int8(bitPattern: bytes[index + 2])) << 16
        }
        #expect(written == [0, 0, 1, -1, 8_388_607, -8_388_608, 8_388_607, -8_388_608, 0])
    }

    @Test func writingInBlocksGivesTheSameFile() throws {
        let folder = try WavFolder()
        defer { folder.remove() }
        // Three and a bit seconds of stereo, so the sizes are updated several times on the way.
        var generator = SystemRandomNumberGenerator()
        let samples = (0..<(150_001 * 2)).map { _ in Float.random(in: -1...1, using: &generator) }
        let whole = folder.url.appending(path: "whole.wav")
        let grown = folder.url.appending(path: "grown.wav")

        try WavWriter.write(samples, channels: 2, to: whole)
        let writer = try WavWriter(url: grown, channels: 2)
        // Blocks of 1,024 frames, as a microphone would deliver them, and a shorter one at the end.
        for start in stride(from: 0, to: samples.count, by: 2_048) {
            try writer.append(Array(samples[start..<min(start + 2_048, samples.count)]))
        }
        try writer.close()

        #expect(try Data(contentsOf: grown) == Data(contentsOf: whole))
        #expect(throws: WavWriterError.closed) { try writer.append([0, 0]) }
    }

    @Test func monoInBlocksWithAnOddLengthGivesTheSameFile() throws {
        let folder = try WavFolder()
        defer { folder.remove() }
        let samples = (0..<100_001).map { Float(sin(Double($0) * 0.01)) }
        let whole = folder.url.appending(path: "whole.wav")
        let grown = folder.url.appending(path: "grown.wav")

        try WavWriter.write(samples, channels: 1, to: whole)
        let writer = try WavWriter(url: grown, channels: 1)
        for start in stride(from: 0, to: samples.count, by: 4_800) {
            try writer.append(Array(samples[start..<min(start + 4_800, samples.count)]))
        }
        try writer.close()

        #expect(try Data(contentsOf: grown) == Data(contentsOf: whole))
    }

    @Test func fileIsReadableWhileStillBeingWritten() throws {
        let folder = try WavFolder()
        defer { folder.remove() }
        let url = folder.url.appending(path: "recording.wav")
        let samples = (0..<120_000).map { Float(sin(Double($0) * 0.02)) * 0.5 }

        // 2.5 seconds arrive and the writer is never closed, as when the app is killed while recording.
        let writer = try WavWriter(url: url, channels: 1)
        #expect(try readBack(url).frames == 0)
        for start in stride(from: 0, to: samples.count, by: 512) {
            try writer.append(Array(samples[start..<min(start + 512, samples.count)]))
        }

        let read = try readBack(url)
        #expect(read.sampleRate == 48_000)
        #expect(read.bitDepth == 24)
        // At most the last second is missing, and what is there is right.
        #expect(read.frames >= 120_000 - 48_000)
        #expect(read.frames <= 120_000)
        #expect(furthestOff(read.channels[0], Array(samples.prefix(read.frames))) <= step)
        try writer.close()
        #expect(try readBack(url).frames == 120_000)
    }

    @Test func writingAgainReplacesTheOldFile() throws {
        let folder = try WavFolder()
        defer { folder.remove() }
        let url = folder.url.appending(path: "click.wav")

        try WavWriter.write([Float](repeating: 0.25, count: 1_000), channels: 1, to: url)
        try WavWriter.write([Float](repeating: -0.25, count: 10), channels: 1, to: url)

        let read = try readBack(url)
        #expect(read.frames == 10)
        #expect(read.channels[0] == [Float](repeating: -0.25, count: 10))
        // The temporary file was moved into place, not left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["click.wav"])
    }

    // MARK: Helpers

    private struct ReadBack {
        var sampleRate: Double
        var bitDepth: Int
        var isFloat: Bool
        var frames: Int
        /// One list of samples for each channel.
        var channels: [[Float]]
    }

    /// Reads a file with the system's own reader, which shares no code with the writer.
    private func readBack(_ url: URL) throws -> ReadBack {
        let file = try AVAudioFile(forReading: url)
        let settings = file.fileFormat.settings
        var channels = [[Float]](repeating: [], count: Int(file.processingFormat.channelCount))
        if file.length > 0 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let data = try #require(buffer.floatChannelData)
            for channel in channels.indices {
                channels[channel] = Array(UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
            }
        }
        return ReadBack(
            sampleRate: file.fileFormat.sampleRate,
            bitDepth: settings[AVLinearPCMBitDepthKey] as? Int ?? 0,
            isFloat: settings[AVLinearPCMIsFloatKey] as? Bool ?? true,
            frames: Int(file.length),
            channels: channels
        )
    }

    /// The largest difference between two lists, or infinity when their lengths differ.
    private func furthestOff(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }
}

private struct WavFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "lockstep-wav-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

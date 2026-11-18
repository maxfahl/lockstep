import AVFoundation
import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// These tests record without a microphone: they hand `RecordingSession` blocks of sound they made up, the way the
/// microphone would deliver them, and then read the take's file back with the system's own reader.
@Suite("RecordingSession")
struct RecordingSessionTests {
    /// One step of a 24-bit sample, as a float.
    private let step: Float = 1 / 8_388_608

    @Test("Sound at 44,100 Hz becomes a 48,000 Hz file of the right length, with the sound in place")
    func otherSampleRateIsConvertedInPlace() throws {
        let project = try TakeProject()
        defer { project.remove() }
        // Two seconds as a 44.1 kHz microphone hears them: silence, then a 1 kHz tone from 0.5 s to 1.5 s.
        let heard = (0..<88_200).map { frame -> Float in
            let seconds = Double(frame) / 44_100
            return (0.5..<1.5).contains(seconds) ? Float(0.5 * sin(2 * Double.pi * 1_000 * seconds)) : 0
        }
        let session = try RecordingSession(in: project.package)

        for block in try blocks(of: [heard], sampleRate: 44_100, frames: 1_024) {
            session.take(block, hostTime: 0)
        }
        let finished = try session.finish()

        let read = try readBack(session.url)
        #expect(read.sampleRate == 48_000)
        #expect(read.bitDepth == 24)
        #expect(read.channels.count == 1)
        // Two seconds are 96,000 samples at 48 kHz, and not one more or less.
        #expect(read.frames == 96_000)
        #expect(finished.samples.count == 96_000)
        #expect(furthestOff(read.channels[0], finished.samples) <= step)
        // The tone is where it was: against the same two seconds made directly at 48 kHz, nothing is off by more
        // than the ripple a converter leaves where a tone starts and stops abruptly.
        let expected = (0..<96_000).map { frame -> Float in
            let seconds = Double(frame) / 48_000
            return (0.5..<1.5).contains(seconds) ? Float(0.5 * sin(2 * Double.pi * 1_000 * seconds)) : 0
        }
        #expect(furthestOff(Array(finished.samples[30_000..<66_000]), Array(expected[30_000..<66_000])) < 0.001)
        #expect(furthestOff(finished.samples, expected) < 0.1)
        // Half a millisecond before the tone there is still silence: the sound was not moved earlier.
        #expect(finished.samples[..<23_976].allSatisfy { abs($0) < 0.02 })
    }

    @Test("Of a microphone with two channels, only the first is kept")
    func onlyTheFirstChannelIsKept() throws {
        let project = try TakeProject()
        defer { project.remove() }
        let first = (0..<24_000).map { Float(sin(Double($0) * 0.01)) * 0.5 }
        let second = (0..<24_000).map { Float(cos(Double($0) * 0.037)) * 0.25 }
        let session = try RecordingSession(in: project.package)

        for block in try blocks(of: [first, second], sampleRate: 48_000, frames: 512) {
            session.take(block, hostTime: 0)
        }
        let finished = try session.finish()

        let read = try readBack(session.url)
        #expect(read.channels.count == 1)
        #expect(read.frames == 24_000)
        #expect(finished.samples == first)
        #expect(furthestOff(read.channels[0], first) <= step)
    }

    @Test("Channels that arrive woven together are told apart too")
    func interleavedChannelsAreToldApart() throws {
        let project = try TakeProject()
        defer { project.remove() }
        let first: [Float] = (0..<4_800).map { Float($0) / 9_600 }
        let second = [Float](repeating: -0.75, count: 4_800)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<4_800 {
            data[0][frame * 2] = first[frame]
            data[0][frame * 2 + 1] = second[frame]
        }
        buffer.frameLength = 4_800
        let session = try RecordingSession(in: project.package)

        session.take(buffer, hostTime: 0)

        #expect(try session.finish().samples == first)
    }

    @Test("The file can be read when recording stops without warning")
    func fileIsValidAfterAnAbruptStop() throws {
        let project = try TakeProject()
        defer { project.remove() }
        let heard = (0..<120_000).map { Float(sin(Double($0) * 0.02)) * 0.5 }
        var session: RecordingSession? = try RecordingSession(in: project.package)
        let url = try #require(session?.url)

        // 2.5 seconds arrive and the take is never finished, as when the app is killed while recording.
        for block in try blocks(of: [heard], sampleRate: 48_000, frames: 1_024) {
            session?.take(block, hostTime: 0)
        }
        session?.waitUntilWritten()

        let read = try readBack(url)
        #expect(read.sampleRate == 48_000)
        // At most the last second is missing, and what is there is right.
        #expect(read.frames >= 120_000 - 48_000)
        #expect(read.frames <= 120_000)
        #expect(furthestOff(read.channels[0], Array(heard.prefix(read.frames))) <= step)

        // When the take is let go of without being finished, the file is closed with everything in it.
        session = nil
        #expect(try readBack(url).frames == 120_000)
    }

    @Test("The level, the length and the growing waveform follow the sound")
    func levelAndWaveformFollowTheSound() throws {
        let project = try TakeProject()
        defer { project.remove() }
        let session = try RecordingSession(in: project.package)
        #expect(session.snapshot() == RecorderSnapshot(isRecording: true))
        #expect(session.waveform(fromBlock: 0) == LiveWaveform())

        // 600 samples that rise from -0.3 to 0.3: two full blocks of 256 and a part of a third.
        let rising = (0..<600).map { Float($0) / 1_000 - 0.3 }
        session.take(try buffer(of: [rising], sampleRate: 48_000), hostTime: 0)
        session.waitUntilWritten()

        var now = session.snapshot()
        #expect(now.lengthSamples == 600)
        #expect(abs(now.peak - 0.3) < 0.002)
        #expect(now.highestPeak == now.peak)
        let start = session.waveform(fromBlock: 0)
        #expect(start.firstBlock == 0)
        #expect(start.minimums == [rising[0], rising[256]])
        #expect(start.maximums == [rising[255], rising[511]])

        // A quiet block follows. The level drops, the loudest moment of the take stays.
        session.take(try buffer(of: [[Float](repeating: -0.1, count: 424)], sampleRate: 48_000), hostTime: 0)
        session.waitUntilWritten()

        now = session.snapshot()
        #expect(now.lengthSamples == 1_024)
        #expect(now.peak == 0.1)
        #expect(abs(now.highestPeak - 0.3) < 0.002)
        // Asking from block 2 gives only what is new: the third block, which the first sound began, and the fourth.
        let new = session.waveform(fromBlock: 2)
        #expect(new.firstBlock == 2)
        #expect(new.minimums == [-0.1, -0.1])
        #expect(new.maximums == [rising[599], -0.1])
        #expect(session.waveform(fromBlock: 99) == LiveWaveform(firstBlock: 4))
    }

    @Test("Sound that arrives after the take has ended is left out")
    func soundAfterTheEndIsLeftOut() throws {
        let project = try TakeProject()
        defer { project.remove() }
        let session = try RecordingSession(in: project.package)
        let sound = try buffer(of: [[Float](repeating: 0.5, count: 1_000)], sampleRate: 48_000)

        session.take(sound, hostTime: 0)
        #expect(try session.finish().samples.count == 1_000)
        session.take(sound, hostTime: 0)
        session.waitUntilWritten()

        #expect(try readBack(session.url).frames == 1_000)
    }

    @Test("A take is placed in the song by the moment its first block was heard")
    func takeIsPlacedByItsFirstBlock() throws {
        let project = try TakeProject()
        defer { project.remove() }
        // A clock on which 24,000,000 ticks are a second, as on this Mac.
        let clock = HostClock(numerator: 125, denominator: 3)
        let songStart: UInt64 = 5_000_000_000_000
        let block = [Float](repeating: 0.1, count: 1_024)
        let session = try RecordingSession(in: project.package)

        // A microphone at 44.1 kHz, first heard 30 ms after the song was started from 12 s. Later blocks carry
        // later moments, which must not move the take.
        for number in 0..<20 {
            let heardAt = songStart + 720_000 + UInt64(number) * 557_279
            session.take(try buffer(of: [block], sampleRate: 44_100), hostTime: heardAt)
        }
        let finished = try session.finish()

        #expect(finished.firstHostTime == songStart + 720_000)
        #expect(finished.rawStart(songPosition: 12, songStartHostTime: songStart, clock: clock) == 12.03)
        // The microphone was already open 50 ms before the song started: the take begins before that place.
        #expect(finished.rawStart(songPosition: 12, songStartHostTime: songStart + 1_920_000, clock: clock) == 11.95)
    }

    @Test("A take in which no sound arrived is put where playback started")
    func emptyTakeIsPutWherePlaybackStarted() throws {
        let project = try TakeProject()
        defer { project.remove() }
        let session = try RecordingSession(in: project.package)

        let finished = try session.finish()

        #expect(finished.samples.isEmpty)
        #expect(finished.rawStart(songPosition: 7.5, songStartHostTime: 123, clock: .system) == 7.5)
        #expect(try readBack(session.url).frames == 0)
    }

    // MARK: Helpers

    /// Cuts made-up sound into buffers of `frames` samples, with a shorter one at the end, as a microphone
    /// delivers them. `channels` holds one list of samples for each channel.
    private func blocks(of channels: [[Float]], sampleRate: Double, frames: Int) throws -> [AVAudioPCMBuffer] {
        let length = channels[0].count
        return try stride(from: 0, to: length, by: frames).map { start in
            let end = min(start + frames, length)
            return try buffer(of: channels.map { Array($0[start..<end]) }, sampleRate: sampleRate)
        }
    }

    private func buffer(of channels: [[Float]], sampleRate: Double) throws -> AVAudioPCMBuffer {
        try TakeSound.buffer(of: channels, sampleRate: sampleRate)
    }

    private func readBack(_ url: URL) throws -> TakeSound.ReadBack {
        try TakeSound.readBack(url)
    }

    private func furthestOff(_ a: [Float], _ b: [Float]) -> Float {
        TakeSound.furthestOff(a, b)
    }
}

/// A project folder for one test, in the Mac's folder for temporary files.
struct TakeProject {
    let package: ProjectPackage

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "lockstep-take-tests-\(UUID().uuidString).lockstep")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        package = ProjectPackage(url: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: package.url)
    }
}

/// Making sound for the recording tests, and reading a take's file back.
enum TakeSound {
    struct ReadBack {
        var sampleRate: Double
        var bitDepth: Int
        var frames: Int
        /// One list of samples for each channel.
        var channels: [[Float]]
    }

    /// A buffer as the microphone delivers it: floats, each channel apart.
    static func buffer(of channels: [[Float]], sampleRate: Double) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)))
        let frames = channels[0].count
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        let data = try #require(buffer.floatChannelData)
        for (index, channel) in channels.enumerated() {
            data[index].update(from: channel, count: frames)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// Reads a file with the system's own reader, which shares no code with the writer.
    static func readBack(_ url: URL) throws -> ReadBack {
        let file = try AVAudioFile(forReading: url)
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
            bitDepth: file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 0,
            frames: Int(file.length),
            channels: channels
        )
    }

    /// The largest difference between two lists, or infinity when their lengths differ.
    static func furthestOff(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }
}

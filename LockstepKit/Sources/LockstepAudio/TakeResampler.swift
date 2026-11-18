import AVFoundation
import LockstepCore
import Synchronization

/// Brings the microphone's sound to the app's 48,000 Hz when the microphone runs at another rate.
///
/// The sound arrives a block at a time while a take is being recorded, so the converter is fed block by block and
/// remembers what it needs between them. `finish()` hands out the last samples it was still holding.
///
/// It is not safe to use from two threads at once. `RecordingSession` keeps it under a lock.
final class TakeResampler {
    /// How many converted samples are collected at a time.
    private static let outputChunk: AVAudioFrameCount = 8_192

    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private let feed: Feed
    private let input: AVAudioConverterInputBlock

    /// - Parameter sampleRate: the rate the microphone delivers. Returns nil when no converter exists for it.
    init?(sampleRate: Double) {
        guard
            sampleRate > 0,
            let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let takeFormat = AVAudioFormat(standardFormatWithSampleRate: Lockstep.sampleRate, channels: 1),
            let converter = AVAudioConverter(from: sourceFormat, to: takeFormat),
            let output = AVAudioPCMBuffer(pcmFormat: takeFormat, frameCapacity: Self.outputChunk)
        else { return nil }
        // The best quality the Mac offers. It was measured for the song import (12 November 2026): the sound comes
        // out exactly in place and with its exact length.
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
        self.output = output
        feed = Feed()
        input = Self.inputBlock(feed: feed, format: sourceFormat)
    }

    /// Converts the next block. The answer can be a little shorter or longer than the block, because the converter
    /// looks a few samples ahead before it lets a sample go.
    func convert(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        feed.state.withLock { $0.waiting = samples }
        return pull()
    }

    /// The samples the converter was still holding. Call it once, after the last block.
    func finish() -> [Float] {
        feed.state.withLock { $0.ended = true }
        return pull()
    }

    /// Takes everything the converter can give right now.
    private func pull() -> [Float] {
        var converted: [Float] = []
        while true {
            var failure: NSError?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &failure, withInputFrom: input)
            if let data = output.floatChannelData, output.frameLength > 0 {
                converted.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            // "Have data" means the output was filled and there may be more. Everything else ends this round.
            guard status == .haveData else { return converted }
        }
    }

    /// The block waiting to go into the converter, and whether the take has ended.
    private final class Feed: Sendable {
        struct State {
            var waiting: [Float]?
            var ended = false
        }

        let state = Mutex(State())
    }

    /// The block the converter calls whenever it wants more sound. It follows the audio callback rule: made here,
    /// outside any actor, and it touches only the locked `Feed`.
    private static func inputBlock(feed: Feed, format: AVAudioFormat) -> AVAudioConverterInputBlock {
        { @Sendable _, status in
            let (waiting, ended) = feed.state.withLock { state in
                let waiting = state.waiting
                state.waiting = nil
                return (waiting, state.ended)
            }
            guard
                let waiting, !waiting.isEmpty,
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(waiting.count)),
                let data = buffer.floatChannelData
            else {
                // Between blocks the converter is told to wait. Only after the last block is it told to let go of
                // what it holds.
                status.pointee = ended ? .endOfStream : .noDataNow
                return nil
            }
            data[0].update(from: waiting, count: waiting.count)
            buffer.frameLength = AVAudioFrameCount(waiting.count)
            status.pointee = .haveData
            return buffer
        }
    }
}

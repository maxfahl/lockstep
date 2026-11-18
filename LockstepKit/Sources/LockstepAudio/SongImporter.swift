import AVFoundation
import LockstepCore
import Synchronization

/// Turns any sound file the Mac can decode (m4a, mp3, wav, aiff) into an `ImportedSong`.
public enum SongImporter {
    /// Reads the whole file into memory as stereo 32-bit float at 48,000 Hz.
    ///
    /// The work never runs on the main thread, whoever calls it. `progress` is called from the
    /// reading thread with values rising from 0 to 1. Cancelling the surrounding task stops the
    /// reading and throws `CancellationError`. Every other failure is a `SongImportError`.
    @concurrent
    public static func importSong(
        from url: URL,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> ImportedSong {
        progress(0)
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        var expectedSeconds = 0.0
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            if duration.isNumeric { expectedSeconds = duration.seconds }
        } catch {
            try Task.checkCancellation()
            throw SongImportError.unreadableFile
        }
        try Task.checkCancellation()
        guard let track = tracks.first else { throw SongImportError.noAudio }

        // Neither a sample rate nor a channel count is asked for, so the file's own audio arrives
        // untouched. `appendStereo` and `resample` then turn it into the app's format.
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard let reader = try? AVAssetReader(asset: asset), reader.canAdd(output) else {
            throw SongImportError.unreadableFile
        }
        reader.add(output)
        guard reader.startReading() else {
            throw expectedSeconds > 0 ? SongImportError.unreadableFile : SongImportError.zeroLength
        }

        var (samples, sampleRate) = try decode(
            reader: reader,
            output: output,
            expectedSeconds: expectedSeconds,
            progress: progress
        )
        guard !samples.isEmpty else { throw SongImportError.zeroLength }
        if sampleRate != Lockstep.sampleRate {
            samples = try resample(samples, from: sampleRate, progress: progress)
        }
        progress(1)
        return ImportedSong(samples: samples, lengthSamples: samples.count / 2)
    }

    /// The part of the progress bar that decoding fills when the song must also be resampled.
    private static let decodingShare = 0.5

    /// Pulls decoded audio out of the reader until the file ends, as interleaved stereo at the
    /// file's own sample rate.
    private static func decode(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        expectedSeconds: Double,
        progress: (Double) -> Void
    ) throws -> (samples: [Float], sampleRate: Double) {
        var samples: [Float] = []
        var sampleRate = 0.0
        var lastReported = 0.0

        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let format = buffer.formatDescription?.audioStreamBasicDescription else {
                throw SongImportError.unreadableFile
            }
            let isInterleavedFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                && format.mBitsPerChannel == 32
            let channels = Int(format.mChannelsPerFrame)
            guard isInterleavedFloat, channels > 0, format.mSampleRate > 0 else {
                throw SongImportError.unreadableFile
            }
            if sampleRate == 0 {
                sampleRate = format.mSampleRate
                // Room for the whole song up front, so an 80 MB list is not copied again and again
                // as it grows. A file that claims an absurd length gets room for half an hour.
                let expectedSamples = min(max(expectedSeconds, 0), 1_800) * sampleRate
                samples.reserveCapacity(Int(expectedSamples) * 2 + 16_384)
            }
            guard format.mSampleRate == sampleRate else { throw SongImportError.unreadableFile }

            do {
                try buffer.withAudioBufferList { list, _ in
                    for part in list {
                        appendStereo(UnsafeBufferPointer<Float>(part), channels: channels, to: &samples)
                    }
                }
            } catch {
                throw SongImportError.unreadableFile
            }

            if expectedSeconds > 0 {
                // Stays under 1 until the file has really ended; the caller reports 1 itself.
                let done = min(Double(samples.count / 2) / (expectedSeconds * sampleRate), 0.99)
                let fraction = sampleRate == Lockstep.sampleRate ? done : done * decodingShare
                if fraction >= lastReported + 0.01 {
                    lastReported = fraction
                    progress(fraction)
                }
            }
        }

        switch reader.status {
        case .completed:
            return (samples, sampleRate)
        case .cancelled:
            throw CancellationError()
        default:
            throw SongImportError.unreadableFile
        }
    }

    /// Adds one decoded piece to the song as left-right pairs. `values` holds whole frames of
    /// `channels` values each. One channel goes to both sides; of more than two, the first two are kept.
    static func appendStereo(_ values: UnsafeBufferPointer<Float>, channels: Int, to samples: inout [Float]) {
        let frames = values.count / channels
        switch channels {
        case 2:
            samples.append(contentsOf: values.prefix(frames * 2))
        case 1:
            for value in values {
                samples.append(value)
                samples.append(value)
            }
        default:
            for frame in 0..<frames {
                samples.append(values[frame * channels])
                samples.append(values[frame * channels + 1])
            }
        }
    }

    /// How many samples go through the converter at a time. Small enough that progress moves and a
    /// cancel is noticed quickly.
    private static let resamplingChunk = 16_384

    /// Converts interleaved stereo from another sample rate to 48,000 Hz.
    ///
    /// The reader could convert by itself, but measured on this Mac (12 November 2026) it loses the
    /// last 17 samples of a 44.1 kHz file and places the audio about one sample late. This converter
    /// gives the exact length with the audio exactly in place.
    private static func resample(
        _ source: [Float],
        from sampleRate: Double,
        progress: (Double) -> Void
    ) throws -> [Float] {
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: true
            ),
            let songFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Lockstep.sampleRate, channels: 2, interleaved: true
            ),
            let converter = AVAudioConverter(from: sourceFormat, to: songFormat),
            let converted = AVAudioPCMBuffer(pcmFormat: songFormat, frameCapacity: AVAudioFrameCount(resamplingChunk))
        else {
            throw SongImportError.unreadableFile
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let input = resamplerInput(source, format: sourceFormat)

        let expectedValues = Double(source.count) * Lockstep.sampleRate / sampleRate
        var samples: [Float] = []
        samples.reserveCapacity(Int(expectedValues) + resamplingChunk * 2)
        var lastReported = decodingShare

        while true {
            try Task.checkCancellation()
            var failure: NSError?
            let status = autoreleasepool { converter.convert(to: converted, error: &failure, withInputFrom: input) }
            if let data = converted.floatChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength) * 2))
            }
            switch status {
            case .haveData:
                let done = min(Double(samples.count) / expectedValues, 0.99)
                let fraction = decodingShare + done * (1 - decodingShare)
                if fraction >= lastReported + 0.01 {
                    lastReported = fraction
                    progress(fraction)
                }
            case .endOfStream, .inputRanDry:
                return samples
            case .error:
                throw SongImportError.unreadableFile
            @unknown default:
                throw SongImportError.unreadableFile
            }
        }
    }

    /// The block the converter calls whenever it wants more of the song. It follows the audio
    /// callback rule: made here, outside any actor, and it touches only the unchanging song and a
    /// locked counter.
    private static func resamplerInput(_ source: [Float], format: AVAudioFormat) -> AVAudioConverterInputBlock {
        let totalFrames = source.count / 2
        let nextFrame = Mutex(0)
        return { @Sendable _, status in
            let start = nextFrame.withLock { next in
                let start = next
                next = min(next + resamplingChunk, totalFrames)
                return start
            }
            let frames = min(resamplingChunk, totalFrames - start)
            guard
                frames > 0,
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                let data = buffer.floatChannelData
            else {
                status.pointee = .endOfStream
                return nil
            }
            source.withUnsafeBufferPointer { values in
                if let base = values.baseAddress {
                    data[0].update(from: base + start * 2, count: frames * 2)
                }
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            status.pointee = .haveData
            return buffer
        }
    }
}

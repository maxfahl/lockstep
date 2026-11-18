import Foundation
import LockstepCore
import Synchronization

/// Why a WAV file could not be written. Problems with the disk itself arrive as the system's own errors.
public enum WavWriterError: Error, Equatable, Sendable {
    /// The sound would pass the 4 GB a WAV file can hold (more than eight hours of mono).
    case tooLong
    /// Sound was handed to a writer that has already been closed.
    case closed
}

/// Writes sound as a WAV file: 48,000 Hz, 24-bit, with nothing in it but the format and the sound.
///
/// There are two ways to use it. `WavWriter.write` saves a finished stretch of sound in one go.
/// A `WavWriter` made with `init(url:channels:)` takes the sound a block at a time, for recording.
///
/// Samples are floats from -1 to 1. With more than one channel they come in turn: left, right, left, right.
public final class WavWriter: Sendable {
    /// How many samples per channel may arrive before the sizes at the top of the file are brought up to date.
    /// One second: if the app is killed while recording, the file on disk is whole up to the last update,
    /// so at most the last second is lost.
    static let framesBetweenHeaderUpdates = Int(Lockstep.sampleRate)

    private struct State {
        var handle: FileHandle?
        var dataBytes = 0
        var framesSinceHeaderUpdate = 0
    }

    private let channels: Int
    private let state: Mutex<State>

    // MARK: A whole file at once

    /// Saves `samples` as a WAV file at `url`, replacing a file already there.
    /// The file is written beside its final place and moved in when complete, so a half-written file is never seen.
    public static func write(_ samples: [Float], channels: Int, to url: URL) throws {
        checkShape(sampleCount: samples.count, channels: channels)
        let dataBytes = samples.count * 3
        guard dataBytes <= maximumDataBytes else { throw WavWriterError.tooLong }
        var file = Data(capacity: headerBytes + dataBytes + 1)
        file.append(contentsOf: header(channels: channels, dataBytes: dataBytes))
        file.append(contentsOf: bytes(for: samples))
        if !dataBytes.isMultiple(of: 2) { file.append(0) }
        try file.write(to: url, options: .atomic)
    }

    // MARK: A file that grows

    /// Starts a WAV file at `url`, replacing a file already there. It is a valid, empty file straight away.
    public init(url: URL, channels: Int) throws {
        Self.checkShape(sampleCount: 0, channels: channels)
        try Data(Self.header(channels: channels, dataBytes: 0)).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.channels = channels
        state = Mutex(State(handle: handle))
    }

    /// Adds a block of sound to the end of the file.
    public func append(_ samples: [Float]) throws {
        Self.checkShape(sampleCount: samples.count, channels: channels)
        let channels = channels
        try state.withLock { state in
            guard let handle = state.handle else { throw WavWriterError.closed }
            guard state.dataBytes + samples.count * 3 <= Self.maximumDataBytes else { throw WavWriterError.tooLong }
            try handle.write(contentsOf: Self.bytes(for: samples))
            state.dataBytes += samples.count * 3
            state.framesSinceHeaderUpdate += samples.count / channels
            if state.framesSinceHeaderUpdate >= Self.framesBetweenHeaderUpdates {
                try Self.updateHeader(handle, channels: channels, dataBytes: state.dataBytes)
                state.framesSinceHeaderUpdate = 0
            }
        }
    }

    /// Finishes the file. Closing twice does no harm.
    public func close() throws {
        let channels = channels
        try state.withLock { state in
            guard let handle = state.handle else { return }
            state.handle = nil
            defer { try? handle.close() }
            try Self.updateHeader(handle, channels: channels, dataBytes: state.dataBytes)
            // A WAV file's sound takes an even number of bytes. The spare byte is not counted as sound.
            if !state.dataBytes.isMultiple(of: 2) { try handle.write(contentsOf: [0]) }
        }
    }

    deinit {
        try? close()
    }

    // MARK: The file format

    private static let headerBytes = 44
    /// The sizes in a WAV file are 32-bit numbers, and the larger one also counts 36 bytes of header and a spare byte.
    private static let maximumDataBytes = Int(UInt32.max) - 37

    private static func checkShape(sampleCount: Int, channels: Int) {
        precondition((1...Int(UInt16.max)).contains(channels), "A WAV file has at least one channel.")
        precondition(sampleCount.isMultiple(of: channels), "Every channel needs the same number of samples.")
    }

    /// Writes the sizes at the top of the file again, then goes back to the end of the sound.
    private static func updateHeader(_ handle: FileHandle, channels: Int, dataBytes: Int) throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(channels: channels, dataBytes: dataBytes))
        try handle.seek(toOffset: UInt64(headerBytes + dataBytes))
    }

    /// The 44 bytes every plain WAV file starts with: "RIFF", the format, then "data" and its size.
    /// No `bext` chunk and no other description follows.
    private static func header(channels: Int, dataBytes: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerBytes)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        let sampleRate = UInt32(Lockstep.sampleRate)
        let bytesPerFrame = channels * 3
        bytes.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes + dataBytes % 2))
        bytes.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                                 // the format description is 16 bytes long
        append(UInt16(1))                                  // whole-number samples, not compressed
        append(UInt16(channels))
        append(sampleRate)
        append(sampleRate * UInt32(bytesPerFrame))         // bytes for one second
        append(UInt16(bytesPerFrame))
        append(UInt16(24))                                 // bits in a sample
        bytes.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        return bytes
    }

    /// The 24-bit whole number a sample is stored as: rounded to the nearest step, and held at the loudest
    /// value the file can store when it is beyond it.
    private static func stored(_ sample: Float) -> Int32 {
        let scaled = (sample * 8_388_608).rounded()
        // The comparisons are written so that a sample that is not a number becomes silence.
        return scaled >= 8_388_607 ? 8_388_607 : scaled <= -8_388_608 ? -8_388_608 : scaled == scaled ? Int32(scaled) : 0
    }

    /// The samples as a file written here gives them back when it is read: each one the nearest value a
    /// 24-bit file holds. Sound that is kept in a file and can also be made again is rounded this way when it
    /// is made, so it is the same samples whichever way it came (`SpedUpTake`).
    public static func asStored(_ samples: [Float]) -> [Float] {
        samples.map { Float(stored($0)) / 8_388_608 }
    }

    /// Each float as a 24-bit whole number, lowest byte first.
    private static func bytes(for samples: [Float]) -> [UInt8] {
        [UInt8](unsafeUninitializedCapacity: samples.count * 3) { buffer, count in
            for (index, sample) in samples.enumerated() {
                let value = stored(sample)
                buffer[index * 3] = UInt8(truncatingIfNeeded: value)
                buffer[index * 3 + 1] = UInt8(truncatingIfNeeded: value >> 8)
                buffer[index * 3 + 2] = UInt8(truncatingIfNeeded: value >> 16)
            }
            count = samples.count * 3
        }
    }
}

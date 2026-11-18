import Foundation
import Synchronization
import Testing
@testable import LockstepAudio

@Suite struct SongImporterTests {
    @Test func monoFileAt44kBecomesStereoAt48k() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        // Two seconds of a 1 kHz sine at half volume.
        let sine = (0..<88_200).map { Int16((sin(2 * Double.pi * 1_000 * Double($0) / 44_100) * 16_384).rounded()) }
        let url = try folder.writeWAV(named: "sine.wav", sampleRate: 44_100, channels: 1, values: sine)

        let song = try await SongImporter.importSong(from: url)

        #expect(abs(song.lengthSamples - 96_000) <= 2)
        #expect(song.samples.count == song.lengthSamples * 2)
        let left = stride(from: 0, to: song.samples.count, by: 2).map { song.samples[$0] }
        let right = stride(from: 1, to: song.samples.count, by: 2).map { song.samples[$0] }
        #expect(left == right)
        // Still 1 kHz: the middle second, away from the ends, crosses zero upwards 1,000 times.
        // Had the 44.1 kHz samples been taken as 48 kHz ones, it would be 1,088 times.
        let middle = left[24_000..<72_000]
        let risingCrossings = zip(middle, middle.dropFirst()).count { $0 < 0 && $1 >= 0 }
        #expect(abs(risingCrossings - 1_000) <= 1)
        // And it sits exactly where it was: every sample matches the same sine worked out at 48 kHz.
        let furthestOff = middle.indices.map { abs(Double(middle[$0]) - 0.5 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }.max()
        #expect((furthestOff ?? 1) < 0.001)
    }

    @Test func stereoFileAt48kIsSampleExact() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        var generator = SystemRandomNumberGenerator()
        let values = (0..<(48_000 * 2)).map { _ in Int16.random(in: Int16.min...Int16.max, using: &generator) }
        let url = try folder.writeWAV(named: "noise.wav", sampleRate: 48_000, channels: 2, values: values)

        let song = try await SongImporter.importSong(from: url)

        #expect(song.lengthSamples == 48_000)
        #expect(song.duration == 1)
        #expect(song.samples == values.map { Float($0) / 32_768 })
    }

    @Test func textFileNamedWavIsUnreadable() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = folder.url.appending(path: "notes.wav")
        try Data("These are lyrics, not sound.\n".utf8).write(to: url)

        await #expect(throws: SongImportError.unreadableFile) {
            try await SongImporter.importSong(from: url)
        }
        #expect(SongImportError.unreadableFile.message == "Lockstep could not read this file.")
    }

    @Test func missingFileIsUnreadable() async throws {
        await #expect(throws: SongImportError.unreadableFile) {
            try await SongImporter.importSong(from: URL(filePath: "/nonexistent/lockstep-test/song.m4a"))
        }
    }

    /// The fixture has the same make-up as Max's Suno files: Opus audio in an MP4 container.
    /// Made once with: ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2"
    /// -ac 2 -c:a libopus -b:a 24k -f mp4 opus-two-seconds.m4a
    ///
    /// Its full length is 96,648 samples, not 96,000: the file holds 101 Opus packets of 960
    /// samples, less the 312 samples of lead-in that every decoder drops. ffmpeg decodes it to
    /// exactly that many. The Mac's reader usually does too, but now and then it leaves out the
    /// decoder's last few milliseconds (seen on Max's reference song, 12 November 2026), so any
    /// length from the nominal two seconds up to the full one is right.
    @Test func opusInMP4HasTheRightLength() async throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/opus-two-seconds.m4a")

        let song = try await SongImporter.importSong(from: url)

        #expect((96_000...96_648).contains(song.lengthSamples))
        let left = stride(from: 0, to: song.samples.count, by: 2).map { song.samples[$0] }
        #expect((left.max() ?? 0) > 0.05)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCKSTEP_SONG"] != nil))
    func referenceSongHasItsFullLength() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LOCKSTEP_SONG"])

        let song = try await SongImporter.importSong(from: URL(filePath: path))

        #expect(abs(song.duration - 211.97) < 0.02)
    }

    /// Once for a file already at 48 kHz, and once for one that is also resampled, where the
    /// progress is shared between the two steps.
    @Test(arguments: [48_000, 44_100])
    func progressRisesFromZeroToOne(sampleRate: Int) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = try folder.writeWAV(
            named: "long.wav", sampleRate: sampleRate, channels: 2, values: [Int16](repeating: 1_000, count: sampleRate * 2 * 20)
        )
        let reported = Reported()

        let song = try await SongImporter.importSong(from: url) { reported.add($0) }

        #expect(abs(song.lengthSamples - 48_000 * 20) <= 2)
        let values = reported.values
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(values.count > 10)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func cancellingStopsTheImport() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let url = try folder.writeWAV(
            named: "long.wav", sampleRate: 48_000, channels: 2, values: [Int16](repeating: 1_000, count: 48_000 * 2 * 20)
        )

        // The import cancels its own task at its first progress report, so the timing is certain.
        await #expect(throws: CancellationError.self) {
            try await SongImporter.importSong(from: url) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }

    @Test func oneChannelGoesToBothSidesAndExtraChannelsAreDropped() {
        var mono: [Float] = []
        [0.1, 0.2, 0.3].withUnsafeBufferPointer { SongImporter.appendStereo($0, channels: 1, to: &mono) }
        #expect(mono == [0.1, 0.1, 0.2, 0.2, 0.3, 0.3])

        var stereo: [Float] = []
        [0.1, 0.2, 0.3, 0.4].withUnsafeBufferPointer { SongImporter.appendStereo($0, channels: 2, to: &stereo) }
        #expect(stereo == [0.1, 0.2, 0.3, 0.4])

        var surround: [Float] = []
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12].withUnsafeBufferPointer {
            SongImporter.appendStereo($0, channels: 6, to: &surround)
        }
        #expect(surround == [1, 2, 7, 8])
    }
}

/// A folder of the test's own, removed when the test ends.
private struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "lockstep-import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes a plain 16-bit WAV. `values` holds every channel in turn: left, right, left, right.
    func writeWAV(named name: String, sampleRate: Int, channels: Int, values: [Int16]) throws -> URL {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = values.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * 2))
        append(UInt16(channels * 2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        values.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(rebasing: $0[...])) }
        let url = url.appending(path: name)
        try data.write(to: url)
        return url
    }
}

/// Collects the progress values, which arrive from the reading thread.
private final class Reported: Sendable {
    private let storage = Mutex<[Double]>([])

    func add(_ value: Double) {
        storage.withLock { $0.append(value) }
    }

    var values: [Double] {
        storage.withLock { $0 }
    }
}

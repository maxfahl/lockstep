import Foundation
import Testing

/// The reference results of the original Python beat model, made by
/// `Scripts/make-beat-reference.py` and kept in `Fixtures/`: `beatref` (70 s) and `beatshort` (12 s).
struct BeatFixture {
    static let reference = BeatFixture(name: "beatref")
    static let short = BeatFixture(name: "beatshort")

    let name: String

    /// What the original picked: beat and bar-start times in seconds, and the sizes of the sound.
    struct Picked: Decodable {
        let sampleRate: Double
        let samples: Int
        let frames: Int
        let beats: [Double]
        let barStarts: [Double]
    }

    private static let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    private func url(_ ending: String) -> URL {
        Self.folder.appending(path: name + ending)
    }

    /// The test sound: mono, 22,050 Hz, as the numbers the original worked from (16-bit / 32,768).
    func samples() throws -> [Float] {
        let data = try Data(contentsOf: url(".wav"))
        // The script writes the plain 44-byte header: 16-bit, one channel.
        try #require(data.count > 44 && data.prefix(4) == Data("RIFF".utf8))
        return data.dropFirst(44).withUnsafeBytes { bytes in
            (0..<(bytes.count / 2)).map {
                Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32_768
            }
        }
    }

    /// The original's spectrogram: frames x 128.
    func spectrogram() throws -> [Float] { try Self.floats(at: url("-mel.f32")) }

    /// The original model's answer: frames x 2, the beat logit and then the bar-start logit.
    func logits() throws -> [Float] { try Self.floats(at: url("-logits.f32")) }

    func picked() throws -> Picked {
        try JSONDecoder().decode(Picked.self, from: Data(contentsOf: url("-beats.json")))
    }

    /// A file of 32-bit floats, as numpy's `tofile` writes them.
    static func floats(at url: URL) throws -> [Float] {
        try Data(contentsOf: url).withUnsafeBytes { bytes in
            (0..<(bytes.count / 4)).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
            }
        }
    }
}

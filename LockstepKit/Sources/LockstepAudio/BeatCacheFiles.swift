import Foundation
import LockstepCore

/// Keeping what beat finding worked out in a project's `cache/` folder, so that opening the
/// project never runs the beat model again.
///
/// - `beats-raw.json`: the beat model's answer (its values for every frame, the beats and the
///   bar starts picked from them), as JSON.
/// - `onset.f32`: the onset curve, one 32-bit float after the other, lowest byte first.
///
/// Both can be thrown away at any time. `read` then gives nil, and the beats are found again.
///
///     try found.cache.write(to: package)
///     let cache = BeatCache.read(from: package)   // nil when missing or damaged
extension BeatCache {
    /// Writes both files, replacing the ones that were there. The cache folder is made if
    /// it is missing.
    public func write(to package: ProjectPackage) throws {
        try FileManager.default.createDirectory(at: package.cacheFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = Self.oddNumbersAsText.encoding
        try encoder.encode(model).write(to: package.beatsRawFile, options: .atomic)
        try onsets.values.withUnsafeBytes { Data($0) }.write(to: package.onsetFile, options: .atomic)
    }

    /// Reads both files. Nil when either is missing or cannot be what it should be; the
    /// beats are then found again, which rewrites them.
    public static func read(from package: ProjectPackage) -> BeatCache? {
        guard let rawBeats = try? Data(contentsOf: package.beatsRawFile),
            let rawOnsets = try? Data(contentsOf: package.onsetFile)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = oddNumbersAsText.decoding
        guard let model = try? decoder.decode(BeatModelOutput.self, from: rawBeats) else { return nil }

        let bytesPerValue = MemoryLayout<Float>.size
        guard !rawOnsets.isEmpty, rawOnsets.count.isMultiple(of: bytesPerValue) else { return nil }
        let values = [Float](unsafeUninitializedCapacity: rawOnsets.count / bytesPerValue) { buffer, count in
            count = rawOnsets.copyBytes(to: buffer) / bytesPerValue
        }
        return BeatCache(model: model, onsets: OnsetCurve(values: values))
    }

    /// JSON has no way to write "infinite" or "not a number". The model's values should
    /// never be either, but if one is, the cache is still written and read instead of failing.
    private static var oddNumbersAsText: (
        encoding: JSONEncoder.NonConformingFloatEncodingStrategy,
        decoding: JSONDecoder.NonConformingFloatDecodingStrategy
    ) {
        (
            .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"),
            .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        )
    }
}

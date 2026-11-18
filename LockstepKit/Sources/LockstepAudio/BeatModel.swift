import CoreML
import Foundation

/// The beat-finding model ("Beat This!", checkpoint final0), run with Core ML.
///
/// It reads one chunk of the song's spectrogram, 30 seconds long, and says for each of the
/// chunk's 1,500 frames how much that frame looks like a beat and like a bar start. Turning
/// sound into the spectrogram, cutting a song into chunks and picking the beats are done
/// elsewhere.
///
/// The model is not part of the app. `Scripts/install-beat-model.sh` puts it at `installedURL`.
public actor BeatModel {
    /// Frames in one chunk. A frame is 20 ms, so a chunk is 30 seconds.
    public static let frameCount = 1_500
    /// Mel bands in each frame of the spectrogram.
    public static let bandCount = 128
    /// Values the model gives for each frame: the beat logit, then the bar-start logit.
    public static let valuesPerFrame = 2

    /// Where the model is installed on this Mac: outside the repository and outside the app, so
    /// that the app, the tests and every git worktree use the same copy.
    public static var installedURL: URL {
        URL.applicationSupportDirectory.appending(path: "Lockstep/Models/BeatThis.mlpackage")
    }

    /// Where the compiled copy of the model at `url` is kept: next to it, with the same name.
    public static func compiledURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("mlmodelc")
    }

    private let model: MLModel

    /// Loads the model at `url` (a `.mlpackage`).
    ///
    /// Core ML can only run a compiled model. Compiling takes a few seconds, so it is done the
    /// first time only and the compiled copy is kept next to the model. It is made again when
    /// the model is newer than the copy. The work never runs on the main thread.
    ///
    /// Throws `BeatModelError.notInstalled` when there is nothing at `url`.
    public init(url: URL) async throws {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { throw BeatModelError.notInstalled }

        let compiled = Self.compiledURL(for: url)
        do {
            if try Self.needsCompiling(model: url, compiled: compiled) {
                let fresh = try await MLModel.compileModel(at: url)
                try? files.removeItem(at: compiled)
                try files.moveItem(at: fresh, to: compiled)
            }
            let configuration = MLModelConfiguration()
            // The processor alone runs a chunk in about 0.3 s and is the closest to the original
            // model's numbers. The graphics chip is faster per chunk but needs seconds to warm up.
            configuration.computeUnits = .cpuOnly
            model = try MLModel(contentsOf: compiled, configuration: configuration)
        } catch {
            throw BeatModelError.unusable
        }
    }

    /// Runs the model on one chunk.
    ///
    /// - Parameter spectrogram: `frameCount` frames of `bandCount` values each, frame after
    ///   frame: the log-mel spectrogram, 96,000 values in all. A chunk with less sound in it is
    ///   filled up with zeros, which is what silence looks like.
    /// - Returns: `frameCount` pairs, frame after frame: the beat logit, then the bar-start
    ///   logit. A logit above 0 means "more likely than not".
    public func logits(for spectrogram: [Float]) throws -> [Float] {
        let expected = Self.frameCount * Self.bandCount
        guard spectrogram.count == expected else {
            throw BeatModelError.wrongChunkSize(expected: expected, actual: spectrogram.count)
        }
        do {
            let input = MLShapedArray<Float>(scalars: spectrogram, shape: [1, Self.frameCount, Self.bandCount])
            let features = try MLDictionaryFeatureProvider(dictionary: ["spectrogram": MLMultiArray(input)])
            let result = try model.prediction(from: features)
            guard let output = result.featureValue(for: "logits")?.multiArrayValue,
                output.dataType == .float32,
                output.count == Self.frameCount * Self.valuesPerFrame
            else { throw BeatModelError.unusable }
            return MLShapedArray<Float>(output).scalars
        } catch {
            throw BeatModelError.unusable
        }
    }

    /// Whether the compiled copy is missing or older than the model it was made from.
    private static func needsCompiling(model: URL, compiled: URL) throws -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: compiled.path) else { return true }
        // Asked of the file system each time. A URL remembers the dates it was asked for before.
        let modelDate = try files.attributesOfItem(atPath: model.path)[.modificationDate] as? Date
        let compiledDate = try files.attributesOfItem(atPath: compiled.path)[.modificationDate] as? Date
        guard let modelDate, let compiledDate else { return true }
        return modelDate > compiledDate
    }
}

/// Why the beat model could not be used.
public enum BeatModelError: Error, Equatable, Sendable {
    /// There is no model at the place it was looked for.
    case notInstalled
    /// The model is there, but Core ML could not compile, load or run it.
    case unusable
    /// A chunk with the wrong number of values was handed to the model. A mistake in the code.
    case wrongChunkSize(expected: Int, actual: Int)

    /// One plain sentence to show Max.
    public var message: String {
        switch self {
        case .notInstalled: "The beat model is not installed."
        case .unusable, .wrongChunkSize: "The beat model could not be used."
        }
    }
}

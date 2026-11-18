import Foundation
import LockstepCore

/// Why the speech model cannot be used. Each one says how to put it right.
public enum SpeechModelError: Error, Equatable, Sendable, LocalizedError {
    /// There is no file where the model should be.
    case missing(SpeechModel)
    /// The file is there and Lockstep may not read it.
    case unreadable(SpeechModel)
    /// The file is not as long as the model is, for example because it is still being written.
    case wrongSize(SpeechModel, found: Int64)
    /// whisper.cpp could not load the file.
    case notLoaded(SpeechModel)

    /// The model the problem is about.
    public var model: SpeechModel {
        switch self {
        case .missing(let model), .unreadable(let model), .wrongSize(let model, _), .notLoaded(let model):
            model
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missing(let model):
            "The \(model.purpose) speech model is not installed. Run \(model.installCommand) in Lockstep's folder."
        case .unreadable(let model):
            "Lockstep is not allowed to read the \(model.purpose) speech model in \(model.file.url.path)."
        case .wrongSize(let model, _), .notLoaded(let model):
            "The \(model.purpose) speech model is not complete. Run \(model.installCommand) --force in Lockstep's folder."
        }
    }
}

/// A speech model that writes out the words of clips, and where `Scripts/install-speech-model.sh`
/// puts it.
///
/// Both are whisper.cpp models from Hugging Face. The script holds the same names, sizes and
/// checksums, and checks each file in full when it downloads it, so the app only checks that the
/// file is there and has the right length.
public enum SpeechModel: String, CaseIterable, Sendable {
    /// KBLab's KB-Whisper Small (Apache 2.0), trained on far more Swedish than OpenAI's models,
    /// in the f16 file of the commit KBLab tagged `strict`. The words are written out in Swedish.
    case swedish
    /// OpenAI's Whisper large-v3-turbo (MIT), quantised to q5_0 by the whisper.cpp project. About
    /// the size of the Swedish model, and good in many languages, which it finds by itself.
    case multilingual

    /// The model for the language chosen in Settings > Recording.
    public static func `for`(_ language: SpeechLanguage) -> SpeechModel {
        switch language {
        case .swedish: .swedish
        case .automatic: .multilingual
        }
    }

    /// The folder all speech models are kept in, outside the repository, next to the beat model.
    public static var folder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Lockstep/Models/Speech", isDirectory: true)
    }

    /// The model's file and how long it must be.
    public var file: SpeechModelFile {
        switch self {
        case .swedish:
            SpeechModelFile(
                url: Self.folder.appendingPathComponent("kb-whisper-small.bin"),
                byteCount: 487_601_984
            )
        case .multilingual:
            SpeechModelFile(
                url: Self.folder.appendingPathComponent("whisper-large-v3-turbo-q5_0.bin"),
                byteCount: 574_041_195
            )
        }
    }

    /// What whisper.cpp is told the language is: "sv", or "auto" to let the model find it.
    var languageCode: String {
        switch self {
        case .swedish: "sv"
        case .multilingual: "auto"
        }
    }

    /// The model's use, in the messages: "Swedish" or "multilingual".
    var purpose: String {
        switch self {
        case .swedish: "Swedish"
        case .multilingual: "multilingual"
        }
    }

    /// The command that installs this model, from the repository's folder.
    public var installCommand: String {
        "Scripts/install-speech-model.sh \(rawValue)"
    }
}

/// A model's file and the length it must have. Nothing in this type writes, moves or removes anything.
public struct SpeechModelFile: Sendable, Equatable {
    public var url: URL
    /// How long the whole model is, in bytes.
    public var byteCount: Int64

    public init(url: URL, byteCount: Int64) {
        self.url = url
        self.byteCount = byteCount
    }

    /// Throws unless the file is there, readable and exactly as long as the model. Quick: it reads
    /// no contents. This keeps Lockstep away from a file the install script is still writing.
    ///
    /// - Parameter model: the model the file is for, named in the error.
    public func checkPresence(of model: SpeechModel) throws(SpeechModelError) {
        let files = FileManager.default
        guard let attributes = try? files.attributesOfItem(atPath: url.path) else { throw .missing(model) }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size == byteCount else { throw .wrongSize(model, found: size) }
        guard files.isReadableFile(atPath: url.path) else { throw .unreadable(model) }
    }
}

extension SpeechModel {
    /// Throws unless this model's file is there, readable and as long as it must be. Quick.
    public func checkPresence() throws(SpeechModelError) {
        try file.checkPresence(of: self)
    }

    /// Whether this model's file is there with the right length. Quick.
    public var isInstalled: Bool {
        (try? checkPresence()) != nil
    }
}

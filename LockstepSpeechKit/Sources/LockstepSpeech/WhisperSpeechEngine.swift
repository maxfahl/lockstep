import Foundation
import LockstepCore
import whisper

/// Writes out speech with whisper.cpp and the model of the chosen language.
///
/// The model is the Swedish one or the multilingual one (`SpeechModel.for`), whichever the
/// language chosen last asks for. A change of language takes effect on the next clip: the model in
/// memory is then let go and the other one loaded, so only one is ever held.
///
/// One call at a time: `TranscriptionQueue` is the only caller and never overlaps its calls. To
/// stop a call, cancel the task that made it. Before the app quits, wait for the running call to
/// end and then call `unload()`: with a model still loaded, the process fails on its way out while
/// Metal shuts down.
public actor WhisperSpeechEngine: SpeechEngine {
    private let worker = WhisperWorker()
    /// Where each model's file is. The real places, except in tests.
    private let fileOf: @Sendable (SpeechModel) -> SpeechModelFile
    /// The language the next clip is written out in.
    private var language: SpeechLanguage
    /// The model in memory, or nil when none is.
    private var loaded: SpeechModel?

    public init(language: SpeechLanguage) {
        self.init(language: language) { $0.file }
    }

    /// For tests: an engine that looks for its models somewhere else.
    init(language: SpeechLanguage, fileOf: @escaping @Sendable (SpeechModel) -> SpeechModelFile) {
        self.language = language
        self.fileOf = fileOf
    }

    /// Chooses the language of the clips written out from now on.
    public func choose(_ language: SpeechLanguage) {
        self.language = language
    }

    /// Loads the model of the chosen language, unless it is loaded. `text(for:)` does this by
    /// itself; call it only to have the wait over with before the first clip.
    ///
    /// Throws `SpeechModelError` when the model's file is missing, not whole, or cannot be loaded.
    /// whisper.cpp is not called at all when the file is missing or of the wrong length.
    public func prepare() async throws {
        let model = SpeechModel.for(language)
        if loaded == model { return }
        let file = fileOf(model)
        try file.checkPresence(of: model)

        if loaded != nil {
            loaded = nil
            await worker.unload()
        }
        guard try await worker.load(file.url) else { throw SpeechModelError.notLoaded(model) }
        loaded = model
    }

    public func text(for samples16k: [Float]) async throws -> String {
        if samples16k.isEmpty { return "" }
        try await prepare()
        guard let model = loaded else { return "" }

        let cancellation = CancellationFlag()
        let raw = try await withTaskCancellationHandler {
            try await worker.transcribe(samples16k, language: model.languageCode, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
        return Self.spokenText(raw)
    }

    public func unload() async throws {
        // Before the wait, not after it: a call that slips in while the worker unloads must find
        // no model marked as loaded, and load it again.
        loaded = nil
        await worker.unload()
    }

    /// The words of whisper.cpp's segments, as a clip shows them.
    ///
    /// The model writes decoder markers such as `<|nospeech|>` as plain text, most often for
    /// silence; they are taken out so that silence gives no text. Every segment starts with a
    /// space, so the ends are trimmed.
    static func spokenText(_ raw: String) -> String {
        raw.replacing(/<\|[^|<>]*\|>/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Why whisper.cpp stopped without words.
public enum WhisperError: Error, Equatable, Sendable, LocalizedError {
    /// `whisper_full` gave this code instead of 0.
    case failed(Int32)

    public var errorDescription: String? {
        switch self {
        case .failed(let code): "whisper.cpp failed with code \(code)."
        }
    }
}

/// Set when the task that asked for the words is cancelled. whisper.cpp reads it from a thread of
/// its own while it works, so it is guarded by a lock.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

/// whisper.cpp's context for one loaded model. Freed when the last reference goes.
private final class WhisperContext {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        whisper_free(pointer)
    }
}

/// Owns the C context and makes every call into whisper.cpp, away from the main actor. The calls
/// are synchronous, so nothing else touches the context while one runs.
private actor WhisperWorker {
    private var context: WhisperContext?

    /// Loads the model file. False when whisper.cpp could not make a context of it.
    func load(_ file: URL) throws -> Bool {
        try Task.checkCancellation()
        if context != nil { return true }
        let parameters = whisper_context_default_params()
        guard let pointer = whisper_init_from_file_with_params(file.path, parameters) else { return false }
        context = WhisperContext(pointer)
        return true
    }

    func unload() {
        context = nil
    }

    /// The raw text of all segments of `samples` (16 kHz, one channel).
    ///
    /// Greedy decoding, no translation, and no text carried over from an earlier clip: the
    /// settings Lockstep's Swedish words have been written out with from the start. `language` is
    /// "sv", or "auto" for the model to find the language itself.
    func transcribe(_ samples: [Float], language: String, cancellation: CancellationFlag) throws -> String {
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard let context else { return "" }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.translate = false
        parameters.no_context = true
        // True would only find the language and write out nothing.
        parameters.detect_language = false
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        parameters.abort_callback = { flag in
            guard let flag else { return false }
            return Unmanaged<CancellationFlag>.fromOpaque(flag).takeUnretainedValue().isCancelled
        }
        parameters.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()

        let code = withExtendedLifetime(cancellation) {
            language.withCString { code in
                parameters.language = code
                return samples.withUnsafeBufferPointer {
                    whisper_full(context.pointer, parameters, $0.baseAddress, Int32($0.count))
                }
            }
        }
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard code == 0 else { throw WhisperError.failed(code) }

        return (0..<whisper_full_n_segments(context.pointer))
            .map { String(cString: whisper_full_get_segment_text(context.pointer, $0)) }
            .joined()
    }
}

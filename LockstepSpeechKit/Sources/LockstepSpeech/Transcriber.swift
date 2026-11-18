import Foundation
import LockstepCore

/// Writes out the words of clips in the background, with whisper.cpp and the model of the chosen
/// language.
///
/// The app makes one of these and keeps it for as long as it runs:
///
///     let transcriber = Transcriber(language: .swedish) { result in
///         await model.wordsArrived(result)      // result.clipID, result.text (nil when it failed)
///     }
///     await transcriber.choose(settings[.speechLanguage])
///     await transcriber.request(clipID: clip.id, samples: clip.speechSamples(from: recordings))
///
/// Clips are written out one at a time, oldest request first. The model is loaded for the first clip
/// and unloaded when there has been nothing to do for 30 seconds, so the memory it takes (over a
/// gigabyte) is held only while it is used. All of that is `TranscriptionQueue` in LockstepCore,
/// where it is tested with a stand-in engine. This type only gives the queue the real engine.
///
/// Before the app quits it must wait for `shutDown()`. With the model still loaded the process
/// fails on its way out, while Metal shuts down.
public actor Transcriber {
    private let engine: WhisperSpeechEngine
    private let queue: TranscriptionQueue

    /// - Parameters:
    ///   - language: the language of the words, until `choose(_:)` says another.
    ///   - idleTime: how long there must be nothing to do before the model is unloaded.
    ///   - report: called once for each clip that was written out or failed, in the order they ran.
    public init(
        language: SpeechLanguage,
        idleTime: Duration = TranscriptionQueue.idleTime,
        report: @escaping TranscriptionQueue.Report
    ) {
        engine = WhisperSpeechEngine(language: language)
        queue = TranscriptionQueue(engine: engine, idleTime: idleTime, report: report)
    }

    /// Chooses the language of the clips that are written out from now on, the ones already
    /// waiting included. The model of the other language is loaded for the next clip.
    public func choose(_ language: SpeechLanguage) async {
        await engine.choose(language)
    }

    /// Asks for the words of a clip. A newer request for the same clip replaces the older one.
    ///
    /// - Parameters:
    ///   - clipID: the clip the words are for.
    ///   - samples: the clip's sound at 48,000 samples a second, as `Clip.speechSamples(from:)` gives it.
    public func request(clipID: UUID, samples: [Float]) async {
        await queue.request(clipID: clipID, samples: samples)
    }

    /// For when the app quits: stops the clip being written out, waits for it to end and unloads
    /// the model. Clips that were waiting get no report, and later requests are ignored.
    public func shutDown() async {
        await queue.shutDown()
    }
}

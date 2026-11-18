import Foundation
import LockstepAudio
import LockstepCore
import LockstepSpeech
import LockstepUI

/// The words of clips: a part of the app's model.
///
/// It holds the words of clips: writing them out with the speech model, clearing them when a
/// clip is cut, and showing them.
@MainActor
final class WordsModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let store: ProjectStore
    private let settings: AppSettings

    /// What is kept for the words of clips, and the speech model.
    private let wordsWork = WordsWork()

    // What it asks of code that holds it, or of the model's routing. `wireWords` sets them.
    /// Shows the clips of a project in the window, without telling the player (`showClips(of:)`,
    /// the clips' part).
    var showClips: (Project) -> Void = { _ in }

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore,
        settings: AppSettings
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
        self.settings = settings
    }
}

// The words of clips: what is rapped in each clip, written out on this Mac by whisper.cpp with the
// speech model of the language chosen in Settings > Recording (`SpeechModel` in LockstepSpeech).
// What it keeps is in `wordsWork`.
//
// The rules of which words go on which clip are `ClipWords` in LockstepCore, where they are
// tested. This file decides when words are asked for, and owns the speech model:
//
// - A new recording (`writeOutWords(ofNewClip:)`, from `keep`): every take, and every attempt
//   a restart kept.
// - The pieces a split or a cut left (`clearWordsOfCutClips` before the edit, so losing the old
//   words is part of the same undo step, and `writeOutWords(ofCutClips:)` after it).
// - Clips found without words when a project is opened, and after Undo and Redo
//   (`fillInWords`, from the store's `rebuildDerived`).
// - Clip > Write Out Words Again, for the selected clips (`writeOutSelectedClips`).
//
// The first three happen only while Settings > Recording has "Write out the words of new
// recordings" on. The command always works.
//
// The speech model: one `Transcriber` for as long as the app runs, made the first time a clip
// is written out. It loads the model (over a gigabyte) for the first clip and frees it after
// half a minute without work. Before Lockstep quits it must be shut down (`shutDownWords`).
// Each clip is handed over with the language chosen at that moment, so a change in Settings
// counts from the next clip on.
//
// When the model of the chosen language is not installed (`Scripts/install-speech-model.sh`),
// no clip is handed over and clips simply get no words. The window's message says once in a run
// how to install it, and Settings > Recording says it under the switch.
//
// An agent's run (`-silent`) never makes the `Transcriber`, so the model is never loaded: its
// gigabyte of memory would only slow the Mac down for whoever works on it. The first clip that
// would have been written out is mentioned on standard error. `-clipText <text>` puts words on a
// clip without the model.
extension WordsModel {
    // MARK: Asking for words

    /// Whether clips are written out by themselves: the setting in Settings > Recording.
    private var writesOutByItself: Bool {
        FeatureSet.built.contains(.clipText) && settings[.writeOutNewRecordings]
    }

    /// Sets up the keeping of words for the app's one store. Called once, when the model is made.
    func startWords() {
        let words = ClipWords(store: store, sounds: { [weak self] in self?.loadedSounds.sounds ?? [:] }) { [weak self] clipID, samples in
            self?.askSpeechModel(for: clipID, sound: samples) ?? false
        }
        // Words that arrived are drawn. The player is not told: nothing that is heard has changed.
        words.changed = { [weak self] in
            guard let self else { return }
            showClips(store.project)
        }
        wordsWork.words = words
    }

    /// A recording has just become a clip. Its words are written out, when the setting says so.
    func writeOutWords(ofNewClip clipID: UUID?) {
        guard let clipID, writesOutByItself else { return }
        wordsWork.words?.writeOut([clipID])
    }

    /// For a project that a split or a cut was just made in, before it goes into the store: the
    /// clips that no longer play what they played lose their words, which describe more sound than
    /// they now hold. Give the answer to `writeOutWords(ofCutClips:)` after the edit.
    ///
    /// With the setting off nothing is taken away, because no new words would come in their place.
    ///
    /// - Parameter copies: the clips the edit made as copies, as they were made. They keep their words.
    func clearWordsOfCutClips(in changed: inout Project, copies: [Clip] = []) -> [UUID] {
        guard writesOutByItself else { return [] }
        return changed.clearWordsOfCutClips(since: store.project, copies: copies)
    }

    /// Writes out the pieces a split or a cut left, once the edit is in the store.
    func writeOutWords(ofCutClips clipIDs: [UUID]) {
        guard !clipIDs.isEmpty else { return }
        wordsWork.words?.writeOut(clipIDs)
    }

    /// For a copy of the project that the store is about to put in place: an opened project, or
    /// the copy Undo or Redo brings back, which can be older than words that arrived later. Clips
    /// without words get the ones already written out for the same sound, and the rest are
    /// written out when the setting says so.
    func fillInWords(_ project: inout Project) {
        wordsWork.words?.fillIn(&project, askingForTheRest: writesOutByItself)
    }

    /// Whether Write Out Words Again has a clip to act on.
    var canWriteOutSelectedClips: Bool {
        !selection.clipIDs.isEmpty
    }

    /// Clip > Write Out Words Again: the selected clips are written out once more, whatever the
    /// setting says. Each keeps the words it has until the new ones arrive.
    func writeOutSelectedClips() {
        wordsWork.words?.writeOut(store.project.clips(selection.clipIDs).map(\.id))
    }

    // MARK: Showing the words

    /// Called by `showClips`: marks the clips in the window whose words are being worked out, which
    /// their bars say.
    ///
    /// The help tag of a bar, which holds all of the clip's words, is in the rows already: `ShownClips`
    /// reads it from the clip when it makes a row. Neither is the name in the bar set here. It is
    /// `Clip.displayName`: the typed name, or else the first words.
    ///
    /// - Returns: the words of the one selected clip, for the panel on the right. Empty when none
    ///   or several are selected, or when it has no words.
    func showWords(in rows: inout [TrackRow], of lookup: ProjectLookup) -> String {
        var selectedText = ""
        if FeatureSet.built.contains(.clipText) {
            // A row is written to only where the answer differs, so a row nothing is said about stays the
            // very row that was made.
            if let words = wordsWork.words {
                for row in rows.indices {
                    for index in rows[row].clips.indices {
                        let isWritingOut = words.isWritingOut(rows[row].clips[index].id)
                        if rows[row].clips[index].isWritingOutWords != isWritingOut {
                            rows[row].clips[index].isWritingOutWords = isWritingOut
                        }
                    }
                }
            }
            if selection.clipIDs.count == 1, let id = selection.clipIDs.first {
                selectedText = lookup.clip(id)?.text ?? ""
            }
        }
        return selectedText
    }

    // MARK: The speech model

    /// Hands one clip's sound to the speech model. False when nothing was asked: in an agent's run.
    private func askSpeechModel(for clipID: UUID, sound samples: [Float]) -> Bool {
        let work = wordsWork
        guard !LaunchOptions.current.isSilent else {
            if !work.saidModelIsNotLoaded {
                work.saidModelIsNotLoaded = true
                Self.tellAgentAboutWords("did not write out the words of a clip: with -silent the speech model is never loaded")
            }
            return false
        }
        guard !work.isShutDown else { return false }
        let language = settings[.speechLanguage]
        do {
            try SpeechModel.for(language).checkPresence()
        } catch {
            sayModelIsMissing(error)
            return false
        }
        if work.requests == nil {
            let transcriber = Transcriber(language: language, report: Self.wordsReport(to: self))
            let (requests, line) = AsyncStream.makeStream(of: WordsRequest.self)
            Self.pass(requests, to: transcriber)
            work.transcriber = transcriber
            work.requests = line
        }
        work.requests?.yield(WordsRequest(clipID: clipID, samples: samples, language: language))
        return true
    }

    /// Once in a run: the window's message says why clips get no words and how to put it right,
    /// and so does a line on standard error. A message that is already showing is left alone,
    /// and this one leaves again after `missingModelSeconds`.
    private func sayModelIsMissing(_ error: SpeechModelError) {
        let work = wordsWork
        guard !work.saidModelIsMissing else { return }
        work.saidModelIsMissing = true
        let message = "No words on clips: \(error.localizedDescription)"
        Self.tellAgentAboutWords("did not write out the words of a clip: \(error.localizedDescription)")
        guard windowState.content.message == nil else { return }
        windowState.content.message = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.missingModelSeconds))
            guard let self, self.windowState.content.message == message else { return }
            self.windowState.content.message = nil
        }
    }

    /// How long the message about a missing speech model stays, in seconds: long enough to read
    /// the command in it.
    private static let missingModelSeconds = 12.0

    /// Hands the requests to the speech model one after the other, in the order they were made.
    /// A newer request for a clip replaces the older one, so the order must be kept.
    private nonisolated static func pass(_ requests: AsyncStream<WordsRequest>, to transcriber: Transcriber) {
        Task {
            for await request in requests {
                await transcriber.choose(request.language)
                await transcriber.request(clipID: request.clipID, samples: request.samples)
            }
        }
    }

    /// What the speech model calls when it has finished with a clip. It calls from a thread of
    /// its own, so this is made here, outside the main actor, and only passes the answer on to
    /// the model.
    private nonisolated static func wordsReport(to model: WordsModel) -> TranscriptionQueue.Report {
        { [weak model] result in
            await model?.wordsArrived(result)
        }
    }

    /// The speech model has finished with a clip, or `-clipText` stands in for it. `ClipWords`
    /// drops the answer when the clip is gone or was cut in the meantime.
    private func wordsArrived(_ result: Transcription) {
        wordsWork.words?.arrived(result)
    }

    /// Whether the speech model was used in this run, so quitting has to close it first.
    var hasSpeechModelToShutDown: Bool {
        wordsWork.transcriber != nil
    }

    /// Before Lockstep quits: stops the clip that is being written out, waits for it to end and
    /// frees the speech model. The process must not end before this returns, or it fails on its
    /// way out while the model is still loaded. Clips that were waiting get no words now, and are
    /// written out the next time their project is opened.
    func shutDownWords() async {
        let work = wordsWork
        work.isShutDown = true
        work.requests?.finish()
        await work.transcriber?.shutDown()
    }

    // MARK: For agents

    /// Puts the words given with `-clipText` on the first clip of the first track, once the
    /// first project is open and the takes given with `-addTake` are in it, and says so on
    /// standard error. The words take the same way in as an answer of the speech model, which an
    /// agent's run never loads.
    func setLaunchClipText() {
        let work = wordsWork
        guard !work.launchTextTaken, let text = LaunchOptions.current.clipText else { return }
        work.launchTextTaken = true
        Task {
            // Until the takes are added the project has no clip to put words on.
            await takeStatus.ended()
            guard let clipID = store.project.tracks.first?.clips.first?.id else {
                Self.tellAgentAboutWords("could not set the words of a clip: the first track has no clip")
                return
            }
            wordsArrived(Transcription(clipID: clipID, outcome: .success(text)))
            let now = store.project.clip(clipID)?.text ?? ""
            Self.tellAgentAboutWords("set the words of the first clip of the first track to \"\(now)\"")
        }
    }

    /// One line on standard error, for the agent that started Lockstep.
    private static func tellAgentAboutWords(_ line: String) {
        FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
    }
}

/// One clip's sound on its way to the speech model.
struct WordsRequest: Sendable {
    var clipID: UUID
    /// The clip's sound at 48,000 samples a second.
    var samples: [Float]
    /// The language chosen in Settings when the clip was handed over.
    var language: SpeechLanguage
}

/// What the model keeps for the words of clips.
@MainActor
final class WordsWork {
    /// Which words go on which clip. Made once, by `startWords`.
    var words: ClipWords?
    /// The speech model, from the first clip that is written out. Nil in an agent's run.
    var transcriber: Transcriber?
    /// The way requests reach the speech model, in order.
    var requests: AsyncStream<WordsRequest>.Continuation?
    /// True once Lockstep is quitting and the speech model was told to stop.
    var isShutDown = false
    /// True once an agent's run has said that it does not load the speech model.
    var saidModelIsNotLoaded = false
    /// True once the run has said that the speech model is not installed.
    var saidModelIsMissing = false
    /// True once the words given with `-clipText` were set, or could not be.
    var launchTextTaken = false
}

extension AppModel {
    /// Gives `words` its closures. `wire()` calls it once, when every part is made.
    func wireWords() {
        words.showClips = { [weak self] project in self?.clips.showClips(of: project) }
    }
}

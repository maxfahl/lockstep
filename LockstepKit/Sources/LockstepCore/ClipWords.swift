import Foundation

/// One stretch of a recording that a clip plays: what the speech model hears of it. Where the stretch lies in
/// the song and how loud it is played do not change the words in it, so they are not part of this.
public struct SpokenPart: Hashable, Sendable {
    public var recordingID: UUID
    public var inSample: Int
    public var outSample: Int
}

extension Clip {
    /// Everything of the recordings that the clip plays, in order. Two clips with the same parts hold the same
    /// words. A clip that was cut has other parts than before, and one that was only moved has the same.
    public var spokenParts: [SpokenPart] {
        segments.map { SpokenPart(recordingID: $0.recordingID, inSample: $0.inSample, outSample: $0.outSample) }
    }
}

extension Project {
    /// Every clip of the project, the waiting takes included.
    var allClips: [Clip] {
        tracks.flatMap(\.clips)
    }

    /// Takes the words away from every clip that does not play what it played in `before`: the pieces a split
    /// or a cut left. Their old words belong to more sound, or to other sound, than they now play. A clip that
    /// plays what it did keeps its words, wherever it was moved.
    ///
    /// Call it on the changed project before it goes into `ProjectStore.edit`, so the cut and the loss of the
    /// words are one undo step, and Undo brings the old clip back with its old words.
    ///
    /// - Parameter copies: clips this edit made as copies of others (`ProjectCopies.swift`), as they were made.
    ///   They were not in `before`, and keep their words as long as they play what they were made to play.
    /// - Returns: the ids of those clips, in the order of the tracks, for `ClipWords.writeOut`.
    @discardableResult
    public mutating func clearWordsOfCutClips(since before: Project, copies: [Clip] = []) -> [Clip.ID] {
        let old = Dictionary((before.allClips + copies).map { ($0.id, $0.spokenParts) }, uniquingKeysWith: { first, _ in first })
        var cut: [Clip.ID] = []
        for track in tracks.indices {
            for clip in tracks[track].clips.indices where old[tracks[track].clips[clip].id] != tracks[track].clips[clip].spokenParts {
                tracks[track].clips[clip].text = nil
                cut.append(tracks[track].clips[clip].id)
            }
        }
        return cut
    }

    /// Sets the words of one clip. False, with nothing changed, when the project has no such clip.
    @discardableResult
    mutating func setText(_ text: String?, ofClip id: Clip.ID) -> Bool {
        for track in tracks.indices {
            if let clip = tracks[track].clips.firstIndex(where: { $0.id == id }) {
                tracks[track].clips[clip].text = text
                return true
            }
        }
        return false
    }
}

/// Keeps the words of the open project's clips: asks for them, and puts each answer on its clip.
///
/// The speech model answers a few seconds after it was asked, and by then the project may look different. So
/// this type remembers what it asked for and looks again when the answer comes:
///
/// - A clip that is gone (deleted, or taken away by Undo) gets nothing. The answer is dropped.
/// - A clip that no longer plays what was sent (it was cut, or Undo put the uncut clip back) gets nothing
///   either. Those words are for other sound.
/// - Otherwise the words are put on the clip with `ProjectStore.setDerived`: saved with the project, and no
///   undo step.
///
/// The app makes one for its one store and gives it the way to ask the speech model:
///
///     let words = ClipWords(store: store, sounds: { sounds }) { clipID, samples in
///         transcriber.request(clipID: clipID, samples: samples)   // true when an answer will come
///     }
///     words.changed = { showClips() }
///     words.writeOut([clipID])                 // a new recording, or Write Out Words Again
///     words.arrived(transcription)             // from the speech model's report, on the main actor
///
/// Phase 17.
@MainActor
public final class ClipWords {
    /// Hands a clip's sound (48,000 samples a second) to the speech model. It answers true when a report for
    /// that clip will come back through `arrived`, and false when nothing was asked.
    public typealias Ask = @MainActor (_ clipID: Clip.ID, _ samples: [Float]) -> Bool

    private let store: ProjectStore
    private let sounds: @MainActor () -> [UUID: [Float]]
    private let ask: Ask

    /// Called when a clip's words arrived or failed to, and when clips started to wait for theirs, so the window
    /// can be drawn again. Not called by `fillIn`, which runs while the store is changing its project.
    public var changed: (@MainActor () -> Void)?

    /// The clips an answer is awaited for, each with what was sent of it.
    private var awaited: [Clip.ID: [SpokenPart]] = [:]
    /// The words of everything that was written out while the app ran, by what was heard. Undo can put back
    /// a copy of the project from before some words arrived, and they are then found here instead of running
    /// the speech model once more.
    private var known: [[SpokenPart]: String] = [:]

    /// - Parameters:
    ///   - store: the open project.
    ///   - sounds: the sound of every recording of the open project, by recording id, as it is right now.
    ///   - ask: hands one clip's sound to the speech model.
    public init(store: ProjectStore, sounds: @escaping @MainActor () -> [UUID: [Float]], ask: @escaping Ask) {
        self.store = store
        self.sounds = sounds
        self.ask = ask
    }

    /// Whether the words of this clip are being worked out right now.
    public func isWritingOut(_ id: Clip.ID) -> Bool {
        awaited[id] != nil
    }

    /// Asks for the words of these clips of the open project. A clip keeps the words it has until the new
    /// ones arrive, so a run that fails takes nothing away. Ids of clips that are gone are skipped.
    public func writeOut(_ ids: some Sequence<Clip.ID>) {
        let recordings = sounds()
        var asked = false
        for id in ids {
            guard let clip = store.project.clip(id) else { continue }
            asked = request(clip, from: recordings) || asked
        }
        if asked { changed?() }
    }

    /// For a copy of the project that is about to be put in place: when it is opened, and after Undo and Redo,
    /// whose copy can be older than words that arrived later. A clip without words gets the ones that were
    /// written out for the same sound earlier, if there are any.
    ///
    /// - Parameter askingForTheRest: whether the clips that are still without words are then written out.
    public func fillIn(_ project: inout Project, askingForTheRest: Bool) {
        let recordings = sounds()
        for track in project.tracks.indices {
            for index in project.tracks[track].clips.indices where project.tracks[track].clips[index].text == nil {
                let clip = project.tracks[track].clips[index]
                if let text = known[clip.spokenParts] {
                    project.tracks[track].clips[index].text = text
                } else if askingForTheRest, awaited[clip.id] != clip.spokenParts {
                    request(clip, from: recordings)
                }
            }
        }
    }

    /// The speech model has finished with a clip. Its words are put on the clip, unless the clip is gone or
    /// no longer plays what was sent. A run that failed leaves the clip as it is.
    public func arrived(_ result: Transcription) {
        let sent = awaited.removeValue(forKey: result.clipID)
        defer { changed?() }
        guard let text = result.text else { return }
        // The words are for what was sent, whatever became of the clip since.
        if let sent { known[sent] = text }
        guard let clip = store.project.clip(result.clipID), sent == nil || sent == clip.spokenParts else { return }
        guard clip.text != text else { return }
        store.setDerived { $0.setText(text, ofClip: result.clipID) }
    }

    @discardableResult
    private func request(_ clip: Clip, from recordings: [UUID: [Float]]) -> Bool {
        guard ask(clip.id, clip.speechSamples(from: recordings)) else { return false }
        awaited[clip.id] = clip.spokenParts
        return true
    }
}

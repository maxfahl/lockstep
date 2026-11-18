import Foundation
import Testing
@testable import LockstepCore

/// The words on clips, from asking for them to their place in the project, with a stand-in for the speech
/// model behind the real queue.
@MainActor
@Suite("Words on clips")
struct ClipWordsTests {
    /// Stands in for the speech model. It answers "words N" for a sound of N samples (at 16 kHz), so a test
    /// tells the clips apart by their length.
    private actor StandInEngine: SpeechEngine {
        /// The length of every sound it was given, in order.
        var heard: [Int] = []
        private var holding = false

        /// From now on every call waits until `release()`.
        func hold() { holding = true }
        func release() { holding = false }

        func text(for samples16k: [Float]) async throws -> String {
            heard.append(samples16k.count)
            while holding { try await Task.sleep(for: .milliseconds(1)) }
            return "words \(samples16k.count)"
        }

        func unload() async throws {}
    }

    /// Holds the `ClipWords` for the queue's report, which is made before it.
    @MainActor
    private final class Desk {
        var words: ClipWords?
        var reports = 0
    }

    /// A twenty-second song in a store, with the queue and a stand-in engine behind `words`.
    @MainActor
    private struct Setup {
        let store = ProjectStore(project: Project(songLengthSamples: 960_000))
        let engine = StandInEngine()
        let desk = Desk()
        let words: ClipWords
        /// The sound of every recording made with `record`.
        let sounds = Sounds()
        /// The clips that were asked for, in order.
        let asked = Asked()

        final class Sounds { var all: [UUID: [Float]] = [:] }
        final class Asked { var clips: [UUID] = [] }

        init() {
            let queue = TranscriptionQueue(engine: engine) { [desk] result in
                await MainActor.run {
                    desk.reports += 1
                    desk.words?.arrived(result)
                }
            }
            // The requests reach the queue in the order they were made.
            let (requests, line) = AsyncStream.makeStream(of: (UUID, [Float]).self)
            Task {
                for await (clipID, samples) in requests {
                    await queue.request(clipID: clipID, samples: samples)
                }
            }
            words = ClipWords(store: store, sounds: { [sounds] in sounds.all }) { [asked] clipID, samples in
                asked.clips.append(clipID)
                line.yield((clipID, samples))
                return true
            }
            desk.words = words
        }

        /// Records a clip that begins `start` seconds into the song, as one edit. The engine sees it as
        /// `samples16k` samples.
        @discardableResult
        func record(at start: Double, samples16k: Int) -> UUID {
            let recording = Recording(lengthSamples: samples16k * 3, rawStart: start)
            sounds.all[recording.id] = [Float](repeating: 0.5, count: recording.lengthSamples)
            var id: UUID?
            store.edit("Record Clip") { project in
                id = project.addRecording(
                    recording, samples: 0..<recording.lengthSamples, asClipOn: project.tracks[0].id, voices: .none
                )
            }
            return id!
        }

        func text(of id: UUID) -> String? {
            store.project.clip(id)?.text
        }
    }

    /// Waits until something is true, for at most five seconds.
    private func until(_ what: Comment, _ condition: () async -> Bool) async throws {
        for _ in 0..<5_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("never happened: \(what)")
    }

    @Test func theWordsArriveOnTheClipTheyWereAskedFor() async throws {
        let setup = Setup()
        let first = setup.record(at: 1, samples16k: 8_000)
        let second = setup.record(at: 5, samples16k: 12_000)
        setup.words.writeOut([first, second])
        #expect(setup.words.isWritingOut(first))
        #expect(setup.words.isWritingOut(second))
        try await until("both clips have words") { setup.text(of: first) != nil && setup.text(of: second) != nil }
        #expect(setup.text(of: first) == "words 8000")
        #expect(setup.text(of: second) == "words 12000")
        #expect(!setup.words.isWritingOut(first))
        #expect(!setup.words.isWritingOut(second))
    }

    @Test func wordsThatArriveAreNoUndoStepAndUndoStillWorks() async throws {
        let setup = Setup()
        let clip = setup.record(at: 1, samples16k: 8_000)
        setup.store.edit("Mute Clip") { $0.setClips([clip], muted: true) }
        setup.words.writeOut([clip])
        try await until("the clip has words") { setup.text(of: clip) != nil }
        #expect(setup.store.undoTitle == "Undo Mute Clip")
        #expect(setup.store.redoTitle == nil)
        setup.store.undo()
        #expect(setup.store.undoTitle == "Undo Record Clip")
        #expect(setup.store.project.clip(clip)?.muted == false)
    }

    @Test func aLateAnswerForADeletedClipIsDropped() async throws {
        let setup = Setup()
        let gone = setup.record(at: 1, samples16k: 8_000)
        let kept = setup.record(at: 5, samples16k: 12_000)
        await setup.engine.hold()
        setup.words.writeOut([gone])
        try await until("the engine has the clip") { await setup.engine.heard == [8_000] }
        setup.store.edit("Delete Clip") { $0.removeClips([gone]) }
        let before = setup.store.project
        await setup.engine.release()
        try await until("the answer came") { setup.desk.reports == 1 }
        #expect(setup.store.project == before)
        #expect(setup.text(of: kept) == nil)
        #expect(!setup.words.isWritingOut(gone))
    }

    @Test func aSplitAsksForBothPiecesAndUndoBringsTheOldWordsBack() async throws {
        let setup = Setup()
        let whole = setup.record(at: 2, samples16k: 16_000)
        setup.words.writeOut([whole])
        try await until("the whole clip has words") { setup.text(of: whole) == "words 16000" }

        // Cut a quarter of a second in: 4,000 of the 16,000 samples the engine sees are before the cut.
        var changed = setup.store.project
        guard let pieces = changed.splitClip(whole, at: 2.25, voices: .none) else {
            Issue.record("the clip was not split")
            return
        }
        let cut = changed.clearWordsOfCutClips(since: setup.store.project)
        #expect(cut == [pieces.first, pieces.second])
        await setup.engine.hold()
        setup.store.edit("Split at Playhead") { $0 = changed }
        // Until the new words arrive, the first piece does not show the words of the whole clip.
        #expect(setup.text(of: pieces.first) == nil)
        setup.asked.clips = []
        setup.words.writeOut(cut)
        #expect(setup.asked.clips == [pieces.first, pieces.second])

        // Undo while the pieces are still being written out: the whole clip is back with its own words, and
        // the answer for the first piece, which has the same id, does not replace them.
        try await until("the engine has the first piece") { await setup.engine.heard.last == 4_000 }
        setup.store.undo()
        #expect(setup.text(of: whole) == "words 16000")
        await setup.engine.release()
        try await until("both answers came") { setup.desk.reports == 3 }
        #expect(setup.text(of: whole) == "words 16000")
        #expect(setup.store.project.clip(pieces.second) == nil)

        // Redo puts the pieces back from a copy made before their words arrived. Both get them from memory,
        // without the engine.
        let heard = await setup.engine.heard
        var restored = changed
        setup.words.fillIn(&restored, askingForTheRest: true)
        #expect(restored.clip(pieces.first)?.text == "words 4000")
        #expect(restored.clip(pieces.second)?.text == "words 12000")
        let heardAfter = await setup.engine.heard
        #expect(heardAfter == heard)
    }

    @Test func aProjectThatIsPutInPlaceGetsTheMissingWordsOnlyWhenAsked() async throws {
        let setup = Setup()
        let silentOnPurpose = setup.record(at: 1, samples16k: 8_000)
        setup.store.setDerived { $0.setText("", ofClip: silentOnPurpose) }
        let missing = setup.record(at: 5, samples16k: 12_000)

        var copy = setup.store.project
        setup.words.fillIn(&copy, askingForTheRest: false)
        #expect(setup.asked.clips.isEmpty)

        // A clip with empty words was written out and held nothing. Only the clip without any is asked for.
        setup.words.fillIn(&copy, askingForTheRest: true)
        #expect(setup.asked.clips == [missing])
        // Asking twice for the same sound while the first answer is awaited does nothing.
        setup.words.fillIn(&copy, askingForTheRest: true)
        #expect(setup.asked.clips == [missing])
        try await until("the clip has words") { setup.text(of: missing) == "words 12000" }
    }

    @Test func joinedClipsHaveTheirPartsWordsAndNeedNoSpeechRun() async throws {
        let setup = Setup()
        let first = setup.record(at: 1, samples16k: 8_000)
        let second = setup.record(at: 5, samples16k: 12_000)
        setup.words.writeOut([second, first])
        try await until("both clips have words") { setup.text(of: first) != nil && setup.text(of: second) != nil }

        var changed = setup.store.project
        let made = changed.joinClips([first, second], voices: .none)
        let joined = try #require(made)
        setup.store.edit("Join Clips") { $0 = changed }
        #expect(setup.text(of: joined) == "words 8000 words 12000")
        setup.asked.clips = []
        var copy = setup.store.project
        setup.words.fillIn(&copy, askingForTheRest: true)
        #expect(setup.asked.clips.isEmpty)
    }

    @Test func aRunThatWasNotAskedLeavesNoClipWaiting() {
        let store = ProjectStore(project: Project(songLengthSamples: 960_000))
        let recording = Recording(lengthSamples: 48_000, rawStart: 1)
        var id: UUID?
        store.edit("Record Clip") {
            id = $0.addRecording(recording, samples: 0..<48_000, asClipOn: $0.tracks[0].id, voices: .none)
        }
        let words = ClipWords(store: store, sounds: { [:] }) { _, _ in false }
        words.writeOut([id!])
        #expect(!words.isWritingOut(id!))
    }
}

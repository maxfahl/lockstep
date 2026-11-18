import Foundation
import Testing
@testable import LockstepCore

/// The queue that writes out clips, with a stand-in for the speech engine and a clock the tests control.
@Suite("Transcription queue")
struct TranscriptionQueueTests {
    private struct Refused: Error {}

    /// Stands in for the speech model. It answers "words N" for a sound of N samples (at 16 kHz), so a test
    /// tells the jobs apart by their length.
    private actor StandInEngine: SpeechEngine {
        /// The length of every sound it was given, in order.
        var heard: [Int] = []
        var unloads = 0
        /// How many calls were stopped before they answered.
        var stopped = 0
        /// The most calls that were ever inside at the same time. More than one is a broken queue.
        var mostAtOnce = 0
        private var inside = 0
        private var holding = false
        private var refused: Set<Int> = []

        /// From now on every call waits until `release()`.
        func hold() { holding = true }
        func release() { holding = false }
        /// Sounds of these lengths get an error instead of words.
        func refuse(_ lengths: Int...) { refused.formUnion(lengths) }

        func text(for samples16k: [Float]) async throws -> String {
            heard.append(samples16k.count)
            inside += 1
            mostAtOnce = max(mostAtOnce, inside)
            defer { inside -= 1 }
            do {
                while holding { try await Task.sleep(for: .milliseconds(1)) }
            } catch {
                stopped += 1
                throw error
            }
            if refused.contains(samples16k.count) { throw Refused() }
            return "words \(samples16k.count)"
        }

        func unload() async throws {
            unloads += 1
        }
    }

    /// A clock that stands still until the test lets one wait pass.
    private actor TestClock {
        /// Every wait that was asked for.
        var asked: [Duration] = []
        private var passes = 0

        func wait(_ time: Duration) async throws {
            asked.append(time)
            while passes == 0 { try await Task.sleep(for: .milliseconds(1)) }
            passes -= 1
        }

        /// Lets the wait in progress end as if its time had passed.
        func pass() { passes += 1 }
    }

    private actor Reports {
        var all: [Transcription] = []
        func add(_ report: Transcription) { all.append(report) }
        var clips: [UUID] { all.map(\.clipID) }
        var texts: [String?] { all.map(\.text) }
    }

    private struct Setup {
        let engine = StandInEngine()
        let clock = TestClock()
        let reports = Reports()
        let queue: TranscriptionQueue

        init() {
            queue = TranscriptionQueue(
                engine: engine,
                wait: { [clock] in try await clock.wait($0) },
                report: { [reports] in await reports.add($0) }
            )
        }
    }

    /// Sound at 48 kHz that the engine will see as `length` samples.
    private func sound(_ length: Int) -> [Float] {
        [Float](repeating: 0.5, count: length * 3)
    }

    /// Waits until something is true, for at most five seconds.
    private func until(_ what: Comment, _ condition: () async -> Bool) async throws {
        for _ in 0..<5_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("never happened: \(what)")
    }

    @Test func jobsRunOneAtATimeOldestFirst() async throws {
        let setup = Setup()
        let (a, b, c) = (UUID(), UUID(), UUID())
        await setup.engine.hold()
        await setup.queue.request(clipID: a, samples: sound(10))
        await setup.queue.request(clipID: b, samples: sound(20))
        await setup.queue.request(clipID: c, samples: sound(30))
        try await until("the first job starts") { await setup.engine.heard == [10] }
        await setup.engine.release()
        try await until("three reports") { await setup.reports.all.count == 3 }

        #expect(await setup.reports.clips == [a, b, c])
        #expect(await setup.reports.texts == ["words 10", "words 20", "words 30"])
        #expect(await setup.engine.heard == [10, 20, 30])
        #expect(await setup.engine.mostAtOnce == 1)
        await setup.queue.shutDown()
    }

    @Test func aNewerRequestReplacesTheWaitingOneAndKeepsItsPlace() async throws {
        let setup = Setup()
        let (a, b, c) = (UUID(), UUID(), UUID())
        await setup.engine.hold()
        await setup.queue.request(clipID: a, samples: sound(10))
        try await until("the first job starts") { await setup.engine.heard == [10] }
        await setup.queue.request(clipID: b, samples: sound(20))
        await setup.queue.request(clipID: c, samples: sound(30))
        await setup.queue.request(clipID: b, samples: sound(40))
        await setup.engine.release()
        try await until("three reports") { await setup.reports.all.count == 3 }

        #expect(await setup.reports.clips == [a, b, c])
        #expect(await setup.reports.texts == ["words 10", "words 40", "words 30"])
        #expect(await setup.engine.heard == [10, 40, 30])
        await setup.queue.shutDown()
    }

    @Test func aNewerRequestStopsTheRunningJobForItsClip() async throws {
        let setup = Setup()
        let a = UUID()
        await setup.engine.hold()
        await setup.queue.request(clipID: a, samples: sound(10))
        try await until("the job starts") { await setup.engine.heard == [10] }
        await setup.queue.request(clipID: a, samples: sound(20))
        try await until("the old job is stopped") { await setup.engine.stopped == 1 }
        await setup.engine.release()
        try await until("a report") { await !setup.reports.all.isEmpty }

        // One report, for the newer sound. The old job said nothing.
        #expect(await setup.reports.clips == [a])
        #expect(await setup.reports.texts == ["words 20"])
        #expect(await setup.engine.heard == [10, 20])
        await setup.queue.shutDown()
    }

    @Test func theModelIsUnloadedAfterTheIdleTimeAndLoadedAgainForANewJob() async throws {
        let setup = Setup()
        await setup.queue.request(clipID: UUID(), samples: sound(10))
        try await until("the queue waits") { await setup.clock.asked == [.seconds(30)] }
        #expect(await setup.reports.all.count == 1)
        #expect(await setup.engine.unloads == 0)

        await setup.clock.pass()
        try await until("the unload") { await setup.engine.unloads == 1 }

        // A new job is taken as usual, and the idle time starts again after it.
        await setup.queue.request(clipID: UUID(), samples: sound(20))
        try await until("the queue waits again") { await setup.clock.asked.count == 2 }
        #expect(await setup.reports.texts == ["words 10", "words 20"])
        #expect(await setup.engine.unloads == 1)
        await setup.clock.pass()
        try await until("the second unload") { await setup.engine.unloads == 2 }
        await setup.queue.shutDown()
        // Nothing was loaded any more, so quitting had nothing to unload.
        #expect(await setup.engine.unloads == 2)
    }

    @Test func aRequestDuringTheIdleTimeKeepsTheModel() async throws {
        let setup = Setup()
        await setup.queue.request(clipID: UUID(), samples: sound(10))
        try await until("the queue waits") { await setup.clock.asked.count == 1 }
        await setup.queue.request(clipID: UUID(), samples: sound(20))
        // The first wait was cut short, and a whole new one starts after the second job.
        try await until("the queue waits again") { await setup.clock.asked.count == 2 }
        #expect(await setup.reports.texts == ["words 10", "words 20"])
        #expect(await setup.engine.unloads == 0)
        await setup.queue.shutDown()
        #expect(await setup.engine.unloads == 1)
    }

    /// With the real clock, as the app runs it. This once crashed the process.
    @Test func aSecondRequestDuringTheRealIdleWaitIsWrittenOut() async throws {
        let engine = StandInEngine()
        let reports = Reports()
        let queue = TranscriptionQueue(engine: engine) { [reports] in await reports.add($0) }
        await queue.request(clipID: UUID(), samples: sound(10))
        try await until("the first clip is written out") { await reports.texts == ["words 10"] }
        // Long enough for the queue to have started its idle wait.
        try await Task.sleep(for: .milliseconds(50))
        await queue.request(clipID: UUID(), samples: sound(20))
        try await until("the second clip is written out") { await reports.texts == ["words 10", "words 20"] }
        #expect(await engine.unloads == 0)
        await queue.shutDown()
        #expect(await engine.unloads == 1)
    }

    @Test func anErrorInOneJobDoesNotBlockTheNext() async throws {
        let setup = Setup()
        let (a, b) = (UUID(), UUID())
        await setup.engine.refuse(10)
        await setup.queue.request(clipID: a, samples: sound(10))
        await setup.queue.request(clipID: b, samples: sound(20))
        try await until("two reports") { await setup.reports.all.count == 2 }

        #expect(await setup.reports.clips == [a, b])
        #expect(await setup.reports.texts == [nil, "words 20"])
        let first = await setup.reports.all[0]
        #expect(throws: Refused.self) { try first.outcome.get() }
        await setup.queue.shutDown()
    }

    @Test func shuttingDownStopsTheRunningJobDropsTheRestAndUnloads() async throws {
        let setup = Setup()
        await setup.engine.hold()
        await setup.queue.request(clipID: UUID(), samples: sound(10))
        await setup.queue.request(clipID: UUID(), samples: sound(20))
        try await until("the first job starts") { await setup.engine.heard == [10] }

        await setup.queue.shutDown()

        // By the time shutDown returns the running job has ended and the model is unloaded.
        #expect(await setup.engine.stopped == 1)
        #expect(await setup.engine.unloads == 1)
        #expect(await setup.engine.heard == [10])
        #expect(await setup.reports.all.isEmpty)

        // Nothing is taken after that.
        await setup.engine.release()
        await setup.queue.request(clipID: UUID(), samples: sound(30))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await setup.engine.heard == [10])
        #expect(await setup.reports.all.isEmpty)
    }

    @Test func emptyAndSilentSoundGiveEmptyTextWithoutTheModel() async throws {
        let setup = Setup()
        let (a, b) = (UUID(), UUID())
        await setup.queue.request(clipID: a, samples: [])
        await setup.queue.request(clipID: b, samples: [Float](repeating: 0, count: 48_000))
        try await until("two reports") { await setup.reports.all.count == 2 }

        #expect(await setup.reports.clips == [a, b])
        #expect(await setup.reports.texts == ["", ""])
        #expect(await setup.engine.heard.isEmpty)
        // The model was never loaded, so there is no idle time to wait and nothing to unload.
        await setup.queue.shutDown()
        #expect(await setup.clock.asked.isEmpty)
        #expect(await setup.engine.unloads == 0)
    }
}

/// The sound a clip gives the speech model.
@Suite("Speech audio")
struct SpeechAudioTests {
    @Test func aClipsSoundIsItsSegmentsInOrderWithoutTheGaps() {
        let (first, second, missing) = (UUID(), UUID(), UUID())
        let recordings: [UUID: [Float]] = [
            first: (0..<10).map(Float.init),
            second: (100..<110).map(Float.init),
        ]
        let clip = Clip(
            segments: [
                Segment(recordingID: first, inSample: 2, outSample: 4, gainDb: 6),
                // Moved far away in the song: the gap is not in the sound.
                Segment(recordingID: second, inSample: 0, outSample: 3, offsetSamples: 96_000),
                // A recording the project does not have.
                Segment(recordingID: missing, inSample: 0, outSample: 5),
                // Reaches past the end of its recording.
                Segment(recordingID: first, inSample: 8, outSample: 50),
            ],
            gainDb: -12
        )
        #expect(clip.speechSamples(from: recordings) == [2, 3, 100, 101, 102, 8, 9])
    }

    private func tone(_ hertz: Double, seconds: Double = 0.5) -> [Float] {
        (0..<Int(seconds * 48_000)).map { Float(sin(2 * .pi * hertz * Double($0) / 48_000)) }
    }

    /// The level of the middle of a sound, away from where the filter runs in and out.
    private func level(_ samples: [Float]) -> Float {
        let middle = samples[(samples.count / 4)..<(samples.count * 3 / 4)]
        return (middle.reduce(0) { $0 + $1 * $1 } / Float(middle.count)).squareRoot()
    }

    @Test func resamplingGivesAThirdOfTheSamples() {
        #expect(SpeechAudio.resampledTo16k(tone(440)).count == 8_000)
        #expect(SpeechAudio.resampledTo16k([]).isEmpty)
        #expect(SpeechAudio.resampledTo16k([0.5, 0.5]).isEmpty)
    }

    @Test func resamplingKeepsAVoiceToneAndItsPitch() {
        let out = SpeechAudio.resampledTo16k(tone(1_000))
        // A sine at full level has the level 0.707.
        #expect(abs(level(out) - 0.7071) < 0.01)
        // Still 1,000 Hz: at 16 kHz that is 16 samples a turn.
        for index in 2_000..<2_100 {
            #expect(abs(out[index] - out[index + 16]) < 0.01)
        }
    }

    @Test func resamplingRemovesWhatSixteenKilohertzCannotHold() {
        // Unfiltered, 10 kHz would come out as a 6 kHz tone at full level.
        #expect(level(SpeechAudio.resampledTo16k(tone(10_000))) < 0.001)
        #expect(level(SpeechAudio.resampledTo16k(tone(15_000))) < 0.001)
    }

    @Test func silenceIsRecognised() {
        #expect(SpeechAudio.isSilent([]))
        #expect(SpeechAudio.isSilent([0, 0.00005, -0.00005]))
        #expect(!SpeechAudio.isSilent([0, 0, -0.01]))
    }
}

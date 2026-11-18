import Foundation

/// What came of writing out one clip: its words, or why there are none.
public struct Transcription: Sendable {
    public var clipID: UUID
    /// The words, or the error that stopped them (model missing, engine busy, the model failing).
    /// Silence gives empty text, not an error.
    public var outcome: Result<String, any Error>

    public init(clipID: UUID, outcome: Result<String, any Error>) {
        self.clipID = clipID
        self.outcome = outcome
    }

    /// The words, or nil when the clip could not be written out. Such a clip simply has no text.
    public var text: String? {
        try? outcome.get()
    }
}

/// Writes out clips one at a time, oldest request first, and frees the speech model when there has been
/// nothing to do for a while.
///
/// The speech model takes over a gigabyte while it is loaded and does one thing at a time. So every use of
/// the engine goes through this one queue: writing out and unloading can never run into each other.
///
/// Every request ends in exactly one report for its clip, with two exceptions: a request that a newer one
/// for the same clip replaced (the newer one reports), and whatever is left when `shutDown()` is called.
///
/// The logic is here in LockstepCore so that it is tested with a stand-in engine. The app uses it through
/// `Transcriber` in `LockstepSpeech`, which gives it the real engine. Phase 17.
public actor TranscriptionQueue {
    /// How long the queue stays empty before the model is unloaded.
    public static let idleTime: Duration = .seconds(30)

    /// Waits for a length of time, and throws when its task is cancelled. The clock of the queue.
    public typealias Wait = @Sendable (Duration) async throws -> Void
    /// Receives the outcome of each job.
    public typealias Report = @Sendable (Transcription) async -> Void

    private struct Job {
        var clipID: UUID
        var samples: [Float]
    }

    private let engine: any SpeechEngine
    private let idleTime: Duration
    /// The clock handed in, or nil for the real one, which is then read where the wait is made (`work`).
    ///
    /// The real clock is not a default value of `wait` on purpose. As one (`wait: @escaping Wait =
    /// { try await Task.sleep(for: $0) }`), the process crashed the first time a request cut the idle wait
    /// short ("freed pointer was not the last allocation"), which is the second clip written out within
    /// half a minute of the first. Seen with Swift 6.2.4 on 13 November 2026, and kept away by the test
    /// `aSecondRequestDuringTheRealIdleWaitIsWrittenOut`.
    private let wait: Wait?
    private let report: Report

    /// The jobs not started yet, oldest first. At most one for each clip.
    private var waiting: [Job] = []
    /// The job that the engine is working on.
    private var running: (clipID: UUID, work: Task<String, any Error>)?
    /// True when a newer request arrived for the clip of the running job, whose result is then not reported.
    private var replaced = false
    /// The wait before unloading, while the queue is empty.
    private var pause: Task<Void, any Error>?
    /// The one task that takes the jobs in turn. Nil when there is nothing to do and nothing loaded.
    private var worker: Task<Void, Never>?
    /// True from the first time the engine was given sound until it was unloaded.
    private var modelMayBeLoaded = false
    private var closed = false

    /// - Parameters:
    ///   - engine: what writes out the words. Nothing else may use it while the queue lives.
    ///   - idleTime: how long the queue stays empty before the model is unloaded.
    ///   - wait: the clock. Tests hand in one they control. It must throw when its task is cancelled. Left
    ///     out, time is real.
    ///   - report: called once for each finished job, in the order the jobs ran.
    public init(
        engine: any SpeechEngine,
        idleTime: Duration = TranscriptionQueue.idleTime,
        wait: Wait? = nil,
        report: @escaping Report
    ) {
        self.engine = engine
        self.idleTime = idleTime
        self.wait = wait
        self.report = report
    }

    /// Asks for the words of a clip.
    ///
    /// A newer request for a clip replaces the older one: one still waiting gets the new sound and keeps its
    /// place, and one the engine is working on is stopped and its result thrown away.
    ///
    /// - Parameters:
    ///   - clipID: the clip the words are for.
    ///   - samples: the clip's sound at 48,000 samples a second (`Clip.speechSamples(from:)`).
    public func request(clipID: UUID, samples: [Float]) {
        guard !closed else { return }
        if running?.clipID == clipID {
            replaced = true
            running?.work.cancel()
        }
        if let place = waiting.firstIndex(where: { $0.clipID == clipID }) {
            waiting[place].samples = samples
        } else {
            waiting.append(Job(clipID: clipID, samples: samples))
        }
        pause?.cancel()
        if worker == nil {
            worker = Task { await self.work() }
        }
    }

    /// For when the app quits: drops the jobs that wait, stops the one in progress, waits for it to end and
    /// unloads the model. Nothing more is reported, and later requests are ignored.
    ///
    /// The app must wait for this before the process ends. With the model still loaded, the process fails on
    /// its way out, while Metal shuts down.
    public func shutDown() async {
        closed = true
        waiting.removeAll()
        running?.work.cancel()
        pause?.cancel()
        await worker?.value
        if modelMayBeLoaded {
            try? await engine.unload()
            modelMayBeLoaded = false
        }
    }

    /// Takes the jobs in turn. When there are none it waits the idle time and unloads the model, unless a
    /// request arrives first. Only this task and `shutDown()`, which waits for it, ever call the engine.
    private func work() async {
        while !closed {
            if !waiting.isEmpty {
                await run(waiting.removeFirst())
            } else if modelMayBeLoaded {
                let pause = Task { [wait, idleTime] in
                    if let wait { try await wait(idleTime) } else { try await Task.sleep(for: idleTime) }
                }
                self.pause = pause
                let ended = await pause.result
                self.pause = nil
                // A request or the shutdown cuts the wait short. Then the model stays.
                guard case .success = ended, waiting.isEmpty, !closed else { continue }
                // If unloading fails the model counts as loaded, and it is tried again after another wait.
                if (try? await engine.unload()) != nil {
                    modelMayBeLoaded = false
                }
            } else {
                break
            }
        }
        worker = nil
    }

    private func run(_ job: Job) async {
        let outcome: Result<String, any Error>
        if SpeechAudio.isSilent(job.samples) {
            // Nothing to hear: no reason to load the model.
            outcome = .success("")
        } else {
            modelMayBeLoaded = true
            replaced = false
            let work = Task { [engine] in try await Self.words(in: job.samples, by: engine) }
            running = (job.clipID, work)
            outcome = await work.result
            running = nil
            // A stopped job says nothing: the newer request for its clip will, or the app is quitting.
            if replaced || closed { return }
        }
        await report(Transcription(clipID: job.clipID, outcome: outcome))
    }

    /// The work of one job. Not on the queue's own thread, so requests are taken while it runs.
    private nonisolated static func words(in samples48k: [Float], by engine: any SpeechEngine) async throws -> String {
        let samples16k = SpeechAudio.resampledTo16k(samples48k)
        try Task.checkCancellation()
        return try await engine.text(for: samples16k)
    }
}

import Foundation
import LockstepCore

/// The three settings of beat finding. The app makes this value from what Settings says
/// (`AppSettings`); left alone, each is the starting value of its setting.
public struct BeatSettings: Sendable, Equatable {
    /// The longest run of missing beats that is filled in with estimated ones (`beats.maxGapBeats`).
    public var maxGapBeats: Int
    /// How many beats the smooth tempo curve looks at around each beat (`beats.smoothingBeats`).
    public var smoothingBeats: Int
    /// How sure the beat model must be of a beat (`beats.certaintyLimit`). 0 is "more sure than not".
    public var certaintyLimit: Double

    public static let defaults = BeatSettings()

    public init(
        maxGapBeats: Int = SettingKey<Int>.maxGapBeats.defaultValue,
        smoothingBeats: Int = SettingKey<Int>.smoothingBeats.defaultValue,
        certaintyLimit: Double = SettingKey<Double>.certaintyLimit.defaultValue
    ) {
        self.maxGapBeats = maxGapBeats
        self.smoothingBeats = smoothingBeats
        self.certaintyLimit = certaintyLimit
    }
}

/// What beat finding works out once per song and every refit starts from: the beat model's raw
/// answer and the onset curve. Making them takes seconds; fitting the grid from them takes
/// milliseconds.
///
/// It is kept in memory with the open song and in the project's `cache/` folder (`write(to:)`
/// and `read(from:)` in `BeatCacheFiles.swift`).
public struct BeatCache: Sendable, Equatable {
    public let model: BeatModelOutput
    public let onsets: OnsetCurve
    /// The song time of every value of `onsets`, worked out once because every refit needs it.
    let onsetTimes: [Double]

    public init(model: BeatModelOutput, onsets: OnsetCurve) {
        self.model = model
        self.onsets = onsets
        onsetTimes = onsets.times
    }
}

/// Finds the beats of a song: runs the front end, the beat model, the one-level forcing, the
/// onset curve, the refining and the bar starts, in that order.
///
///     let found = try await BeatFinder.findBeats(in: song) { progress in ... }
///     found.grid     // the beats, as the project keeps them
///     found.cache    // keep it: `refit` rebuilds the grid from it after every correction
public enum BeatFinder {
    /// What is being done right now. `name` is what the window shows.
    public enum Phase: Sendable, Equatable {
        /// Turning the song into what the model reads.
        case listening
        /// Running the model.
        case findingBeats
        /// Moving the beats onto the drum hits.
        case liningUp

        public var name: String {
            switch self {
            case .listening: "Listening"
            case .findingBeats: "Finding beats"
            case .liningUp: "Lining up"
            }
        }
    }

    /// How far the work has come: `fraction` rises from 0 to 1 over all three phases.
    public struct Progress: Sendable, Equatable {
        public var phase: Phase
        public var fraction: Double

        public init(phase: Phase, fraction: Double) {
            self.phase = phase
            self.fraction = fraction
        }
    }

    public struct Found: Sendable, Equatable {
        public var grid: Grid
        public var cache: BeatCache
    }

    /// The share of the whole work that is done when the model starts and when it has finished.
    private static let modelShare = 0.1...0.9

    /// Finds the beats of a song. The work never runs on the main thread.
    ///
    /// `progress` is called from the working thread. Cancelling the surrounding task stops the
    /// work and throws `CancellationError`. A missing model throws `BeatModelError.notInstalled`.
    /// A song in which the model hears no beat gives a grid without beats.
    @concurrent
    public static func findBeats(
        in song: ImportedSong,
        modelURL: URL = BeatModel.installedURL,
        settings: BeatSettings = .defaults,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Found {
        progress(Progress(phase: .listening, fraction: 0))
        let model = try await BeatModel(url: modelURL)
        try Task.checkCancellation()
        let mono = OnsetStrength.monoMix(of: song)
        // The onset curve is only needed at the end, so it is measured while the model runs.
        async let onsets = onsetCurve(of: mono)
        let spectrogram = BeatFrontEnd.spectrogram(of: mono, sampleRate: Lockstep.sampleRate)
        try Task.checkCancellation()

        progress(Progress(phase: .findingBeats, fraction: modelShare.lowerBound))
        let output = try await BeatModelRunner.run(spectrogram, model: model) { done in
            let fraction = modelShare.lowerBound + done * (modelShare.upperBound - modelShare.lowerBound)
            progress(Progress(phase: .findingBeats, fraction: fraction))
        }

        progress(Progress(phase: .liningUp, fraction: modelShare.upperBound))
        let cache = BeatCache(model: output, onsets: await onsets)
        try Task.checkCancellation()
        let grid = refit(cache: cache, settings: settings, anchors: [], tempoLevel: .normal, beatOne: nil)
        progress(Progress(phase: .liningUp, fraction: 1))
        return Found(grid: grid, cache: cache)
    }

    @concurrent
    private static func onsetCurve(of mono: [Float]) async -> OnsetCurve {
        OnsetStrength.curve(of: mono)
    }

    /// Rebuilds the grid from what was kept, without running the model.
    ///
    /// The result depends on these five things and nothing else, so a refit can never lose a
    /// correction: the dragged beats, the tempo level and Max's choice of beat 1 are applied
    /// again every time. The steps: pick the beats from the model's values (less strictly where
    /// that leaves a stretch without beats) and keep one beat level, move the beats onto the drum
    /// hits along the smooth curve (through the anchors), find the bar starts, then halve or double.
    public static func refit(
        cache: BeatCache,
        settings: BeatSettings,
        anchors: [Anchor],
        tempoLevel: TempoLevel,
        beatOne: Double?
    ) -> Grid {
        let picked = cache.model.picked(limit: settings.certaintyLimit, maxGapBeats: settings.maxGapBeats)
        let refined = BeatRefiner.refine(
            beats: picked.beats,
            onsetValues: cache.onsets.values,
            onsetTimes: cache.onsetTimes,
            anchors: anchors,
            smoothingBeats: settings.smoothingBeats,
            loosened: picked.loosened
        )
        var grid = Grid(beats: refined.beats, anchors: anchors, beatOne: beatOne)
        grid.setBarStart(fromModelBarStarts: cache.model.barStarts)
        grid = grid.applying(tempoLevel: tempoLevel)
        if tempoLevel == .doubled {
            placeHalfwayAnchors(anchors, in: &grid)
        }
        return grid
    }

    /// How many of the beats picked from what was kept were below the limit and were taken
    /// because they keep the tempo. For a check from outside: such beats look like every other
    /// uncertain beat in the project.
    public static func loosenedBeatCount(cache: BeatCache, settings: BeatSettings) -> Int {
        cache.model.picked(limit: settings.certaintyLimit, maxGapBeats: settings.maxGapBeats).loosened.count
    }

    /// Puts the halfway beats Max dragged where he dragged them.
    ///
    /// At double tempo every second beat is a new one, halfway between two fitted beats. The
    /// fitting above does not know these beats, so an anchor on one of them matched nothing
    /// there. Here such a beat is moved to its anchor. Its neighbours are fitted beats on their
    /// own drum hits and stay where they are, and it keeps a quarter of their distance to each.
    static func placeHalfwayAnchors(_ anchors: [Anchor], in grid: inout Grid) {
        for anchor in anchors where anchor.from.isFinite && anchor.to.isFinite {
            guard let nearest = grid.beat(nearest: anchor.from), !nearest.number.isMultiple(of: 2),
                let index = grid.beats.firstIndex(where: { $0.number == nearest.number }),
                index > 0, index + 1 < grid.beats.count
            else { continue }
            let (before, after) = (grid.beats[index - 1].time, grid.beats[index + 1].time)
            let quarter = (after - before) / 4
            // The same rule as for every other anchor: it belongs to a beat only when it was
            // dragged from within a quarter of a beat period of it.
            guard quarter > 0, abs(nearest.time - anchor.from) <= quarter / 2 else { continue }
            grid.beats[index].time = min(max(anchor.to, before + quarter), after - quarter)
            grid.beats[index].estimated = false
        }
    }
}

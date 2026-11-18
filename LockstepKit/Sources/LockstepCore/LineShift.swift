/// Finds how far a whole line should slide, earlier or later, to sit on the beat. There are two answers, for
/// two uses.
///
/// What is heard: a line slides so that its first syllable lands on the sub-beat nearest to it. Max asked for
/// this rule on 13 November 2026, because it can be seen and predicted: the line starts on the beat.
///
///     let slide = LineShift.toFirstSyllable(
///         markerTimes: times,               // song seconds of the line's syllables, where the clip is now
///         grid: grid,
///         perBeat: 4                        // 4 for sixteenths, 6 for triplets
///     )
///     // seconds: negative slides the line earlier, positive later, 0 leaves it where it is
///
/// What is judged: `best` finds the slide after which all the syllables together fit the sub-beats best. The
/// Auto choice of a clip still uses it, to tell whether a clip is in sixteenths or triplets (`Feel`). It moves no
/// sound any more.
///
///     let shift = LineShift.best(
///         markerTimes: times,
///         grid: grid,
///         perBeat: 4,
///         maxShiftMs: 80,                   // the setting `timing.maxLineShiftMs`
///         deliberatePercent: 35             // the setting `timing.deliberatePercent`
///     )
///
/// In `best` every syllable is measured against its nearest sub-beat after the slide. A syllable that stays
/// far off whatever happens counts as "far off" and no more, so one stray syllable cannot drag the line away
/// from where the others fit.
public enum LineShift {
    /// The furthest a line may slide, in milliseconds, until the setting `timing.maxLineShiftMs` says otherwise.
    public static let defaultMaxShiftMs: Double = 80
    /// A slide that fits only this much better than a smaller one is not worth making, in milliseconds per
    /// syllable. The smallest slide within this distance of the best fit is the one chosen, so a line that
    /// already sits well does not move.
    public static let toleranceMs: Double = 0.5
    /// The first search tries a slide every millisecond.
    static let coarseStepMs = 1
    /// The second search, around the best of the first, tries one every tenth of a millisecond.
    static let stepsPerMs = 10

    /// The slide that puts a line's first syllable on the sub-beat nearest to it, in seconds. Negative is
    /// earlier, positive is later.
    ///
    /// The answer is 0, the line stays, when there is nothing to go by: no syllable, or a first syllable
    /// where the song has no beats.
    ///
    /// - Parameters:
    ///   - markerTimes: when each syllable of the line sounds, in song seconds. Leave out the ones Max has
    ///     excluded from timing fixes: the earliest that is left is the one that counts as the first.
    ///   - grid: the beats of the song.
    ///   - perBeat: how many sub-beats a beat has: 4 for sixteenths, 6 for triplets.
    public static func toFirstSyllable(markerTimes: [Double], grid: Grid, perBeat: Int = 4) -> Double {
        guard let first = markerTimes.min(),
              let nearest = MarkerDistance.nearestSubBeat(to: first, grid: grid, perBeat: perBeat)
        else { return 0 }
        return nearest.subBeatTime - first
    }

    /// How far a line slides toward what its clip is held against, in seconds. Negative is earlier.
    ///
    /// - Against sub-beats: the slide that puts its first syllable on the sub-beat nearest to it
    ///   (`toFirstSyllable`), exactly as before a clip could aim at anything else.
    /// - Against the syllables of another track: the one distance that suits most of its syllables
    ///   (`SyllableMatch.slide`), so the line as a whole sits on the lead.
    ///
    /// - Parameters:
    ///   - markerTimes: when each syllable of the line sounds, in song seconds. Leave out the ones Max has
    ///     excluded from timing fixes.
    ///   - targets: what the clip is held against.
    ///   - reachMs: against another track, how far away one of its syllables may be and still count, in
    ///     milliseconds: the furthest slide plus the furthest move of a syllable. Not used against sub-beats.
    public static func slide(
        markerTimes: [Double],
        targets: TimingTargets,
        reachMs: Double = defaultMaxShiftMs + SyllableMoves.defaultMaxMoveMs
    ) -> Double {
        switch targets {
        case let .subBeats(grid, perBeat):
            toFirstSyllable(markerTimes: markerTimes, grid: grid, perBeat: perBeat)
        case let .times(lead):
            SyllableMatch.slide(of: markerTimes, onto: lead, reach: reachMs / 1_000)
        }
    }

    /// The slide after which the syllables of a line, all together, fit the sub-beats best, in seconds.
    /// Negative is earlier, positive is later. Only `Feel` asks for it: a line that is heard slides by
    /// `toFirstSyllable`.
    ///
    /// The answer is 0, the line stays, when there is nothing to go by: fewer than two syllables that have
    /// beats around them, a stretch of the song with no beats, or a limit of 0.
    ///
    /// - Parameters:
    ///   - markerTimes: when each syllable of the line sounds, in song seconds. Leave out the ones Max has
    ///     excluded from timing fixes.
    ///   - grid: the beats of the song.
    ///   - perBeat: how many sub-beats a beat has: 4 for sixteenths, 6 for triplets.
    ///   - maxShiftMs: the furthest the line may slide, either way, in milliseconds.
    ///   - deliberatePercent: how far from a sub-beat counts as meant to be off, as a percentage of the sub-beat
    ///     spacing. No syllable costs more than this, however far off it is.
    public static func best(
        markerTimes: [Double],
        grid: Grid,
        perBeat: Int = 4,
        maxShiftMs: Double = defaultMaxShiftMs,
        deliberatePercent: Double = MarkerDistance.defaultDeliberatePercent
    ) -> Double {
        let share = max(deliberatePercent, 0) / 100
        // A syllable where the song has no beats says nothing about where the line belongs. For the others,
        // the most they can cost is remembered, for a slide that would take them off the beats.
        let syllables: [(time: Double, most: Double)] = markerTimes.compactMap { time in
            MarkerDistance.nearestSubBeat(to: time, grid: grid, perBeat: perBeat).map { (time, $0.spacing * share) }
        }
        let limit = (maxShiftMs * Double(stepsPerMs)).rounded(.down)
        guard syllables.count >= 2, limit.isFinite, limit >= 1 else { return 0 }
        let furthest = Int(min(limit, 1e6))

        // Slides are counted in steps of a tenth of a millisecond, so "no slide" is exactly 0.
        func seconds(_ steps: Int) -> Double {
            Double(steps) / Double(stepsPerMs * 1_000)
        }
        /// How badly the line fits after sliding: the mean distance of its syllables from their nearest
        /// sub-beats, in seconds, none counted as more than "far off".
        func cost(_ steps: Int) -> Double {
            var sum = 0.0
            for syllable in syllables {
                let moved = syllable.time + seconds(steps)
                if let nearest = MarkerDistance.nearestSubBeat(to: moved, grid: grid, perBeat: perBeat) {
                    sum += min(abs(moved - nearest.subBeatTime), nearest.spacing * share)
                } else {
                    sum += syllable.most
                }
            }
            return sum / Double(syllables.count)
        }

        // First every millisecond from one limit to the other, then every tenth around the best of those.
        let coarseStep = coarseStepMs * stepsPerMs
        var tried: [Int: Double] = [:]
        for steps in stride(from: 0, through: furthest, by: coarseStep) {
            tried[steps] = cost(steps)
            tried[-steps] = cost(-steps)
        }
        tried[furthest] = cost(furthest)
        tried[-furthest] = cost(-furthest)
        let coarseBest = Self.smallest(in: tried, within: 0)
        for steps in max(coarseBest - coarseStep, -furthest)...min(coarseBest + coarseStep, furthest)
        where tried[steps] == nil {
            tried[steps] = cost(steps)
        }
        return seconds(Self.smallest(in: tried, within: toleranceMs / 1_000))
    }

    /// Of the slides that were tried, the smallest one whose cost is within `tolerance` of the lowest cost.
    /// Of an earlier and a later slide of the same size, the one that fits better.
    private static func smallest(in tried: [Int: Double], within tolerance: Double) -> Int {
        let lowest = tried.values.min() ?? 0
        return tried
            .filter { $0.value <= lowest + tolerance }
            .min { (abs($0.key), $0.value, $0.key) < (abs($1.key), $1.value, $1.key) }?
            .key ?? 0
    }
}

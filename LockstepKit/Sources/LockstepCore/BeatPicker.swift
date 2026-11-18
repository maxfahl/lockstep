/// Picks the beats out of the beat model's values, and tries again less strictly where that
/// left a stretch of the song without beats.
///
/// The model gives one value for every 20 ms of the song. Above 0 it is more sure than not
/// that a beat is there. A beat is taken where the value is above the limit and is the
/// largest around. Where that leaves no beats (the whole song, or a hole too long to fill)
/// the limit is lowered a step at a time, in that stretch only, and a weaker beat is taken
/// only when it keeps the tempo.
///
///     let picked = BeatPicker.pick(values: values, framesPerSecond: 50)
///     picked.beats       // numbered, as `BeatLevel.force` gives them
///     picked.loosened    // the numbers of the beats found below the limit
public enum BeatPicker {
    // MARK: The steps and the floor

    /// How much lower the limit is at each new try. Small, because the weak beats of a true
    /// pulse are stronger than the wobbles around them by little more than this: a step that takes
    /// in the beats and not yet the wobbles is the one that shows the pulse.
    static let stepDown: Float = 0.25
    /// How many times the limit is lowered below the one that was asked for.
    static let stepCount = 6
    /// The lowest limit there is, for a new try and for the setting alike. Where the model
    /// does not know, its values wobble between about -0.5 and 0, and the weakest true beats
    /// measured in such a stretch were at -1.25. Below this there are only wobbles.
    public static let floor: Float = -1.5

    /// The limits that are tried one after the other where a limit left no beats.
    static func loosenedLimits(below limit: Float) -> [Float] {
        (1...stepCount).map { limit - stepDown * Float($0) }.filter { $0 >= floor }
    }

    // MARK: What counts as keeping the tempo

    /// How far a weaker beat may sit from where the tempo puts it, in seconds: two of the
    /// model's 20 ms steps. The weak beats of a true pulse were measured within that, and the
    /// wobbles of a stretch without a pulse come every 0.2 seconds or so, so a wider reach
    /// would catch one of them at almost every place.
    static let reach = 0.04
    /// How many places in a row may be without a weaker beat before the pulse counts as lost.
    static let mostMissesInARow = 2
    /// The fewest weaker beats that are taken together inside a hole.
    static let shortestRun = 8
    /// The fewest weaker beats that are taken as the pulse of a song with no surer beats.
    static let shortestPulse = 16
    /// The share of the places along a run that must have a weaker beat.
    static let placesFilled = 0.75
    /// The share of all weaker peaks along a run that must be on it. This is what tells a
    /// pulse from chance: a stretch without a pulse is full of peaks, and in made-up noise
    /// the best run never held more than 0.52 of them, while a true weak pulse held 0.89.
    static let peaksOnTheRun = 2.0 / 3
    /// The beat spacings looked for in a song with no surer beats, in seconds: 180 to 40 beats a minute.
    static let pulsePeriods = (1.0 / 3)...1.5
    /// How many beat spacings next to a hole give the tempo there.
    static let spacingsForTempo = 8

    // MARK: Peaks

    /// A peak must be the largest value within this many steps either side (60 ms).
    static let peakReach = 3

    /// A place where the model's values are largest.
    public struct Peak: Sendable, Equatable {
        /// Counted in the model's steps from the start of the song. Two equal neighbours give half a step.
        public var position: Double
        /// The model's value there.
        public var strength: Float
    }

    /// The peaks in one row of the model's values (one value per 20 ms step).
    ///
    /// A step is a peak when its value is above the limit and is the largest within 3 steps
    /// either side. Peaks on neighbouring steps become one at their mean position.
    public static func peaks(in values: [Float], above limit: Float = 0) -> [Peak] {
        var peaks: [Peak] = []
        // The running mean of the group of neighbouring peaks being gathered, and its size.
        var group: (mean: Double, count: Int, strength: Float)?
        for step in values.indices where values[step] > limit {
            let around = max(step - peakReach, 0)...min(step + peakReach, values.count - 1)
            guard values[around].allSatisfy({ $0 <= values[step] }) else { continue }
            if let current = group, Double(step) - current.mean <= 1 {
                let count = current.count + 1
                group = (current.mean + (Double(step) - current.mean) / Double(count), count, current.strength)
            } else {
                if let current = group { peaks.append(Peak(position: current.mean, strength: current.strength)) }
                group = (Double(step), 1, values[step])
            }
        }
        if let current = group { peaks.append(Peak(position: current.mean, strength: current.strength)) }
        return peaks
    }

    // MARK: Picking

    public struct Picked: Sendable, Equatable {
        /// The beats at one beat level, numbered, as `BeatLevel.force` gives them.
        public var beats: [Beat]
        /// The numbers of the beats that were below the limit and were taken because they keep the tempo.
        public var loosened: Set<Int>

        public init(beats: [Beat], loosened: Set<Int> = []) {
            self.beats = beats
            self.loosened = loosened
        }
    }

    /// - Parameters:
    ///   - values: the model's beat value for every step of the song.
    ///   - framesPerSecond: how many steps make a second (50).
    ///   - limit: how sure the model must be of a beat (setting `beats.certaintyLimit`). 0 is
    ///     "more sure than not".
    ///   - maxGapBeats: the longest run of missing beats that is filled in (setting `beats.maxGapBeats`).
    public static func pick(
        values: [Float],
        framesPerSecond: Double,
        limit: Float = 0,
        maxGapBeats: Int = SettingKey<Int>.maxGapBeats.defaultValue
    ) -> Picked {
        let limits = loosenedLimits(below: limit)
        let all = peaks(in: values, above: min(limit, limits.last ?? limit))
            .map { (time: $0.position / framesPerSecond, strength: $0.strength) }
        var raw = all.filter { $0.strength > limit }.map(\.time)
        var beats = BeatLevel.force(raw, maxGapBeats: maxGapBeats)
        var weaker: Set<Double> = []

        for lower in limits {
            let noTempo = beats.count < 2
            guard noTempo || zip(beats, beats.dropFirst()).contains(where: { $1.number != $0.number + 1 }) else { break }
            let candidates = all
                .filter { $0.strength > lower && $0.strength <= limit && !weaker.contains($0.time) }
                .map(\.time)
            let found = noTempo ? pulse(in: candidates) : inTempo(candidates, inTheHolesOf: beats)
            guard !found.isEmpty else { continue }
            weaker.formUnion(found)
            raw += found
            beats = BeatLevel.force(raw, maxGapBeats: maxGapBeats)
        }
        return Picked(beats: beats, loosened: Set(beats.filter { weaker.contains($0.time) }.map(\.number)))
    }

    // MARK: Weaker beats that keep the tempo

    /// The weaker peaks inside the holes of `beats` that carry on the tempo of the beats next
    /// to the hole: first from the beat before it, then back from the beat after it.
    static func inTempo(_ candidates: [Double], inTheHolesOf beats: [Beat]) -> [Double] {
        var found: [Double] = []
        for index in beats.indices.dropLast() where beats[index + 1].number != beats[index].number + 1 {
            let (before, after) = (beats[index], beats[index + 1])
            let inside = candidates.filter { $0 > before.time && $0 < after.time }
            guard inside.count >= shortestRun else { continue }
            // With no neighbours to measure, the hole's own length and its count of missing beats give the tempo.
            let across = (after.time - before.time) / Double(after.number - before.number)

            let onwards = run(
                in: inside, from: before.time,
                period: period(nextTo: index, towardsEarlier: true, in: beats) ?? across,
                forwards: true, until: after.time
            )
            let reached = onwards.last ?? before.time
            let back = run(
                in: inside.filter { $0 > reached }, from: after.time,
                period: period(nextTo: index + 1, towardsEarlier: false, in: beats) ?? across,
                forwards: false, until: reached
            )
            found += onwards + back
        }
        return found
    }

    /// The pulse that the weaker peaks of a song with no surer beats agree on: the longest
    /// run of evenly spaced peaks, tried from every two peaks a beat apart. Empty when the
    /// peaks do not agree, as in a song without a beat.
    static func pulse(in candidates: [Double]) -> [Double] {
        guard candidates.count >= shortestPulse, let end = candidates.last else { return [] }
        var best: [Double] = []
        for first in candidates.indices where candidates.count - first > best.count {
            for second in candidates.indices[(first + 1)...] {
                let period = candidates[second] - candidates[first]
                if period < pulsePeriods.lowerBound { continue }
                if period > pulsePeriods.upperBound { break }
                let followed = follow(candidates, from: candidates[second], period: period, forwards: true, until: end + period)
                let hits = [candidates[first], candidates[second]] + followed.hits
                if hits.count > best.count,
                    keepsTempo(hits, places: followed.places + 2, among: candidates, atLeast: shortestPulse)
                {
                    best = hits
                }
            }
        }
        return best
    }

    /// The weaker peaks that carry on a tempo from a beat, or none when they do not keep it.
    private static func run(
        in candidates: [Double], from start: Double, period: Double, forwards: Bool, until bound: Double
    ) -> [Double] {
        let followed = follow(candidates, from: start, period: period, forwards: forwards, until: bound)
        guard keepsTempo(followed.hits, places: followed.places, among: candidates, atLeast: shortestRun) else { return [] }
        return followed.hits.sorted()
    }

    /// Walks from `start` one beat period at a time, forwards or backwards, and takes the
    /// peak nearest to each place when it is within `reach`. The period follows the peaks
    /// that are taken, as a drifting tempo needs. The walk ends at `bound`, or when more
    /// places in a row than `mostMissesInARow` have no peak.
    ///
    /// `places` counts the places walked up to the last peak taken.
    static func follow(
        _ candidates: [Double], from start: Double, period: Double, forwards: Bool, until bound: Double
    ) -> (hits: [Double], places: Int) {
        // A period shorter than this could take the same peak twice.
        guard period > 2 * reach else { return ([], 0) }
        var period = period
        var last = start
        var misses = 0
        var hits: [Double] = []
        var places = 0
        while misses <= mostMissesInARow {
            let stride = Double(misses + 1) * period
            let target = forwards ? last + stride : last - stride
            // The last place is the one a beat away from the bound, which is itself a beat or the song's end.
            if forwards ? target > bound - period / 2 : target < bound + period / 2 { break }
            guard let peak = nearest(to: target, in: candidates), abs(peak - target) <= reach else {
                misses += 1
                continue
            }
            period += BeatLevel.periodGain * (abs(peak - last) / Double(misses + 1) - period)
            places += misses + 1
            hits.append(peak)
            last = peak
            misses = 0
        }
        return (hits, places)
    }

    /// Whether a run of peaks is a pulse and not chance: it is long enough, most of its
    /// places have a peak, and most of the peaks along it are on it.
    static func keepsTempo(_ hits: [Double], places: Int, among candidates: [Double], atLeast shortest: Int) -> Bool {
        guard hits.count >= shortest, Double(hits.count) >= placesFilled * Double(places),
            let earliest = hits.min(), let latest = hits.max()
        else { return false }
        let along = candidates.count { $0 >= earliest && $0 <= latest }
        return Double(hits.count) >= peaksOnTheRun * Double(along)
    }

    /// The beat period next to a hole: the median of the beat spacings that lead up to it
    /// from one side. Nil when the beat at the hole's edge stands alone on that side.
    static func period(nextTo edge: Int, towardsEarlier: Bool, in beats: [Beat]) -> Double? {
        var spacings: [Double] = []
        var index = edge
        while spacings.count < spacingsForTempo {
            let (earlier, later) = towardsEarlier ? (index - 1, index) : (index, index + 1)
            guard earlier >= 0, later < beats.count, beats[later].number == beats[earlier].number + 1 else { break }
            spacings.append(beats[later].time - beats[earlier].time)
            index += towardsEarlier ? -1 : 1
        }
        return spacings.isEmpty ? nil : BeatLevel.median(spacings)
    }

    /// The value of a sorted list that is closest to `target`.
    private static func nearest(to target: Double, in sorted: [Double]) -> Double? {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < target { low = middle + 1 } else { high = middle }
        }
        let around = [low - 1, low].filter { sorted.indices.contains($0) }.map { sorted[$0] }
        return around.min { abs($0 - target) < abs($1 - target) }
    }
}

import Foundation

/// Moves numbered beats onto the measured drum hits and evens them out along
/// the song's slow tempo drift.
///
/// The beat model only knows a beat to the nearest 20 ms. The onset curve says
/// where new sound begins to a fraction of a millisecond. Each beat first takes
/// the strongest onset near it; then a smooth curve of beat time against beat
/// number is drawn through those hits, ignoring the ones that do not fit, and
/// the final beats are read off that curve.
public enum BeatRefiner {
    public struct Result: Sendable, Equatable {
        /// The beats that went in, with the same numbers, at their final times.
        /// `estimated` is true for a beat that was filled in, had no clear
        /// onset, or whose onset did not fit the curve.
        public var beats: [Beat]
        /// Stretches the app is unsure about: see `uncertainRanges(in:)`.
        public var uncertainRanges: [ClosedRange<Double>]
    }

    /// How far from the model's beat the first search looks, in seconds.
    static let firstReach = 0.035
    /// How far from the smooth curve the second search looks.
    static let secondReach = 0.020
    /// How often hits that do not fit are thrown out and the curve redrawn.
    static let fitRounds = 5
    /// A hit this close to the curve is never thrown out, in seconds.
    static let outlierFloor = 0.005
    /// An onset weaker than this share of the song's typical beat onset is no hit.
    static let weakHitShare = 0.1
    /// Over how many beats an anchor's pull fades out on a side with no other anchor.
    static let anchorFade = 8
    /// Two anchors at most this many beats apart pull the beats between them in a straight line.
    static let anchorSpan = 16
    /// A beat may not come closer to the one before it than this share of the local period.
    static let closestSpacing = 0.5

    /// - Parameters:
    ///   - beats: numbered beats from `BeatLevel.force`, sorted by time.
    ///   - onsetValues: the onset-strength curve, one value per hop.
    ///   - onsetTimes: the song time of each value, ascending.
    ///   - anchors: beats Max dragged. The result passes through each exactly.
    ///   - smoothingBeats: the smoothing window in beats (setting
    ///     `beats.smoothingBeats`). Smaller follows each hit more closely.
    ///   - loosened: the numbers of the beats the model was less sure of than the limit
    ///     asks (`BeatPicker.Picked.loosened`). They look for their drum hit like every
    ///     beat the model reported, and come out marked `estimated` whatever they find.
    public static func refine<Strength: BinaryFloatingPoint>(
        beats: [Beat],
        onsetValues: [Strength],
        onsetTimes: [Double],
        anchors: [Anchor] = [],
        smoothingBeats: Int = SettingKey<Int>.smoothingBeats.defaultValue,
        loosened: Set<Int> = []
    ) -> Result {
        guard !beats.isEmpty else { return Result(beats: [], uncertainRanges: []) }
        let onsets = OnsetCurve(values: onsetValues, times: onsetTimes)

        // First pass: the strongest onset near each beat the model reported.
        let firstHits = beats.map { beat in
            beat.estimated ? nil : onsets.strongest(around: beat.time, within: firstReach)
        }
        let weakest = weakHitShare * BeatLevel.median(firstHits.compactMap { $0?.strength })

        var curve = beats.map(\.time)
        var accepted = [Bool](repeating: false, count: beats.count)
        // Across a gap that was left empty, each side is fitted on its own.
        for run in runs(of: beats) {
            let modelTimes = Array(curve[run])
            let first = fit(
                observed: firstHits[run].map { hit in hit.flatMap { $0.strength >= weakest ? $0.time : nil } },
                fallback: modelTimes,
                window: smoothingBeats
            )
            // Second pass: search again close to the curve, so a beat cannot
            // jump to a neighbouring hi-hat.
            let secondHits = run.map { index -> Double? in
                guard !beats[index].estimated,
                    let hit = onsets.strongest(around: first.curve[index - run.lowerBound], within: secondReach),
                    hit.strength >= weakest
                else { return nil }
                return hit.time
            }
            let second = fit(observed: secondHits, fallback: first.curve, window: smoothingBeats)
            curve.replaceSubrange(run, with: second.curve)
            accepted.replaceSubrange(run, with: second.accepted)
        }

        let periods = localPeriods(of: curve, beats: beats)
        let pulls = anchorPulls(anchors, curve: curve, periods: periods, numbers: beats.map(\.number))
        var result = beats
        for index in beats.indices {
            result[index].estimated = beats[index].estimated || !accepted[index]
                || loosened.contains(beats[index].number)
            result[index].time = curve[index] + correction(forNumber: beats[index].number, pulls: pulls)
        }
        for pull in pulls {
            // Max placed this beat himself: it is exactly there and it is not a guess.
            result[pull.index].time = pull.target
            result[pull.index].estimated = false
        }
        for index in result.indices.dropFirst() {
            let earliest = result[index - 1].time + closestSpacing * periods[index]
            if result[index].time < earliest { result[index].time = earliest }
        }
        return Result(beats: result, uncertainRanges: uncertainRanges(in: result))
    }

    /// Stretches the app is unsure about: runs of three or more estimated beats
    /// with consecutive numbers, each from its first to its last beat, in song seconds.
    public static func uncertainRanges(in beats: [Beat]) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        var start = 0
        var length = 0
        func closeRun() {
            if length >= 3 {
                ranges.append(beats[start].time...max(beats[start].time, beats[start + length - 1].time))
            }
        }
        for (index, beat) in beats.enumerated() {
            if beat.estimated, length > 0, beat.number == beats[index - 1].number + 1 {
                length += 1
            } else {
                closeRun()
                start = index
                length = beat.estimated ? 1 : 0
            }
        }
        closeRun()
        return ranges
    }

    // MARK: - Onsets

    struct OnsetCurve<Strength: BinaryFloatingPoint> {
        let values: [Strength]
        let times: [Double]
        let count: Int

        init(values: [Strength], times: [Double]) {
            self.values = values
            self.times = times
            count = min(values.count, times.count)
        }

        /// The strongest onset within `reach` seconds of `centre`, or nil when
        /// the curve has nothing there or is flat there.
        func strongest(around centre: Double, within reach: Double) -> (time: Double, strength: Double)? {
            var low = 0
            var high = count
            while low < high {
                let middle = (low + high) / 2
                if times[middle] < centre - reach { low = middle + 1 } else { high = middle }
            }
            guard low < count, times[low] <= centre + reach else { return nil }
            var best = low
            var lowest = values[low]
            var index = low
            while index < count, times[index] <= centre + reach {
                if values[index] > values[best] { best = index }
                if values[index] < lowest { lowest = values[index] }
                index += 1
            }
            guard values[best] > lowest else { return nil }
            return (times[best], Double(values[best]))
        }
    }

    // MARK: - The smooth curve

    /// Index ranges of beats whose numbers follow each other without a skip.
    static func runs(of beats: [Beat]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start = 0
        for index in 1..<max(beats.count, 1) where beats[index].number != beats[index - 1].number + 1 {
            runs.append(start..<index)
            start = index
        }
        runs.append(start..<beats.count)
        return runs
    }

    /// Draws the smooth curve through the hits of one run of beats.
    ///
    /// `observed` has the hit time of each beat, or nil when it has none. A hit
    /// further from the curve than three robust standard deviations (and more
    /// than `outlierFloor`) is left out and the curve is drawn again.
    static func fit(observed: [Double?], fallback: [Double], window: Int) -> (curve: [Double], accepted: [Bool]) {
        var accepted = observed.map { $0 != nil }
        guard accepted.filter({ $0 }).count >= 2 else {
            return (savitzkyGolay(fallback, window: window), observed.map { _ in false })
        }
        var curve = fallback
        for _ in 0..<fitRounds {
            curve = savitzkyGolay(bridged(observed, accepted: accepted), window: window)
            let residuals = observed.indices.map { index in observed[index].map { $0 - curve[index] } }
            let kept = residuals.indices.compactMap { accepted[$0] ? residuals[$0] : nil }
            let middle = BeatLevel.median(kept)
            let spread = 1.48 * BeatLevel.median(kept.map { abs($0 - middle) })
            let limit = max(3 * spread, outlierFloor)
            let next = residuals.map { residual in residual.map { abs($0) < limit } ?? false }
            guard next.filter({ $0 }).count >= 2 else { break }
            accepted = next
        }
        return (curve, accepted)
    }

    /// The accepted hits, with every other beat placed on the straight line
    /// between its accepted neighbours. Before the first and after the last
    /// accepted hit the line carries on at the local beat period.
    static func bridged(_ observed: [Double?], accepted: [Bool]) -> [Double] {
        let known = observed.indices.filter { accepted[$0] && observed[$0] != nil }
        guard known.count >= 2 else { return observed.map { $0 ?? 0 } }
        func value(_ index: Int) -> Double { observed[index] ?? 0 }
        func slope(_ a: Int, _ b: Int) -> Double { (value(b) - value(a)) / Double(b - a) }

        // The period at an end is measured over several beats, so that one
        // slightly late hit does not tilt the whole line.
        let reach = min(known.count - 1, 8)
        let leading = slope(known[0], known[reach])
        let trailing = slope(known[known.count - 1 - reach], known[known.count - 1])

        var result = [Double](repeating: 0, count: observed.count)
        var next = 0
        for index in observed.indices {
            while next < known.count, known[next] < index { next += 1 }
            if next == 0 {
                result[index] = value(known[0]) - leading * Double(known[0] - index)
            } else if next == known.count {
                let last = known[known.count - 1]
                result[index] = value(last) + trailing * Double(index - last)
            } else if known[next] == index {
                result[index] = value(index)
            } else {
                let before = known[next - 1]
                result[index] = value(before) + slope(before, known[next]) * Double(index - before)
            }
        }
        return result
    }

    /// Savitzky-Golay smoothing of evenly numbered values: each value is
    /// replaced by a parabola fitted to the `window` values around it.
    ///
    /// Near an end the parabola of the first or last full window is used. With
    /// fewer values than the window, the window shrinks to the largest odd
    /// count that fits; fewer than three values are returned unchanged.
    static func savitzkyGolay(_ values: [Double], window: Int) -> [Double] {
        var width = min(max(window, 3) | 1, values.count)
        if width % 2 == 0 { width -= 1 }
        guard width >= 3 else { return values }
        let half = width / 2

        var sumX2 = 0.0
        var sumX4 = 0.0
        for step in 1...half {
            let square = Double(step * step)
            sumX2 += 2 * square
            sumX4 += 2 * square * square
        }
        let size = Double(width)
        let determinant = size * sumX4 - sumX2 * sumX2

        var result = values
        for index in values.indices {
            let centre = min(max(index, half), values.count - 1 - half)
            // Measured from the centre value, so seconds deep into a song lose no precision.
            let base = values[centre]
            var sumY = 0.0
            var sumXY = 0.0
            var sumX2Y = 0.0
            for step in -half...half {
                let x = Double(step)
                let y = values[centre + step] - base
                sumY += y
                sumXY += x * y
                sumX2Y += x * x * y
            }
            let level = (sumX4 * sumY - sumX2 * sumX2Y) / determinant
            let slope = sumXY / sumX2
            let bend = (size * sumX2Y - sumX2 * sumY) / determinant
            let x = Double(index - centre)
            result[index] = base + level + slope * x + bend * x * x
        }
        return result
    }

    /// The beat period at each beat: the curve's spacing to the beat before it
    /// in the same run, or to the beat after it for the first of a run.
    static func localPeriods(of curve: [Double], beats: [Beat]) -> [Double] {
        var periods = [Double](repeating: 0, count: curve.count)
        for run in runs(of: beats) where run.count >= 2 {
            for index in run.dropFirst() {
                periods[index] = curve[index] - curve[index - 1]
            }
            periods[run.lowerBound] = periods[run.lowerBound + 1]
        }
        let typical = BeatLevel.median(periods.filter { $0 > 0 })
        return periods.map { $0 > 0 ? $0 : typical }
    }

    // MARK: - Anchors

    struct Pull {
        /// Index of the anchored beat.
        var index: Int
        /// Its beat number.
        var number: Int
        /// Where Max put it.
        var target: Double
        /// How far that is from the smooth curve.
        var amount: Double
    }

    /// Finds the beat each anchor belongs to: the one the curve puts nearest
    /// to where the anchor was dragged from. An anchor that is not within a
    /// quarter period of any beat belongs to none and is left out.
    static func anchorPulls(_ anchors: [Anchor], curve: [Double], periods: [Double], numbers: [Int]) -> [Pull] {
        var byIndex: [Int: Pull] = [:]
        for anchor in anchors where anchor.from.isFinite && anchor.to.isFinite {
            guard let index = curve.indices.min(by: { abs(curve[$0] - anchor.from) < abs(curve[$1] - anchor.from) }),
                abs(curve[index] - anchor.from) <= BeatLevel.tolerance * periods[index]
            else { continue }
            byIndex[index] = Pull(index: index, number: numbers[index], target: anchor.to, amount: anchor.to - curve[index])
        }
        return byIndex.values.sorted { $0.index < $1.index }
    }

    /// How far the beat with this number is moved by the anchors around it.
    static func correction(forNumber number: Int, pulls: [Pull]) -> Double {
        let before = pulls.last { $0.number <= number }
        let after = pulls.first { $0.number >= number }
        if let before, let after, after.number - before.number <= anchorSpan {
            guard after.number > before.number else { return before.amount }
            let share = Double(number - before.number) / Double(after.number - before.number)
            return before.amount + (after.amount - before.amount) * share
        }
        func faded(_ pull: Pull?) -> Double {
            guard let pull else { return 0 }
            let distance = abs(number - pull.number)
            guard distance < anchorFade else { return 0 }
            return pull.amount * 0.5 * (1 + cos(Double.pi * Double(distance) / Double(anchorFade)))
        }
        return faded(before) + faded(after)
    }
}

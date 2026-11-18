/// Turns the beat model's raw beat times into one numbered row of beats.
///
/// The model sometimes reports twice as many beats for a stretch, and reports
/// none where the drums stop. `force` keeps one beat level throughout and fills
/// a hole only between real beats and only when it is short enough.
public enum BeatLevel {
    /// How far a reported beat may sit from the expected place and still be
    /// that beat, as a share of the local beat period.
    static let tolerance = 0.25
    /// How much one new spacing changes the local beat period.
    static let periodGain = 0.1

    /// - Parameters:
    ///   - rawBeats: beat times from the model, in song seconds.
    ///   - maxGapBeats: the longest run of missing beats that is filled in
    ///     (setting `beats.maxGapBeats`). 0 fills nothing.
    /// - Returns: beats sorted by time and numbered from 0. Every beat is one
    ///   the model reported, or an estimated one placed evenly between two
    ///   reported beats. Numbers skip across a gap that was left empty, as if
    ///   it had been filled.
    public static func force(_ rawBeats: [Double], maxGapBeats: Int = SettingKey<Int>.maxGapBeats.defaultValue) -> [Beat] {
        let raw = sortedDistinct(rawBeats)
        guard let first = raw.first else { return [] }
        var out = [Beat(number: 0, time: first, estimated: false)]
        guard raw.count > 1 else { return out }

        var period = median(zip(raw.dropFirst(), raw).map { $0 - $1 })
        // Index of the first reported beat that has not been used or passed.
        var next = 1

        while next < raw.count {
            let last = out[out.count - 1]
            let target = last.time + period
            let quarter = period * tolerance

            // Beats that come too soon are the extra ones of a double-time stretch.
            while next < raw.count, raw[next] < target - quarter { next += 1 }
            guard next < raw.count else { break }

            var best = next
            while best + 1 < raw.count, abs(raw[best + 1] - target) < abs(raw[best] - target) {
                best += 1
            }
            if abs(raw[best] - target) <= quarter {
                out.append(Beat(number: last.number + 1, time: raw[best], estimated: false))
                period += periodGain * (raw[best] - last.time - period)
                next = best + 1
                continue
            }

            // The expected beat is missing. The next reported beat decides what
            // happens: where it sits tells how many beats are missing before it.
            func place(_ time: Double) -> (steps: Int, inStep: Bool) {
                let steps = max(1, Int(((time - last.time) / period).rounded()))
                return (steps, abs(time - last.time - Double(steps) * period) <= quarter)
            }
            var resume = next
            if !place(raw[next]).inStep, next + 1 < raw.count,
                raw[next + 1] - raw[next] < period * (1 - tolerance),
                place(raw[next + 1]).inStep
            {
                // An extra beat right before a beat that is in its expected place.
                resume = next + 1
            }
            let time = raw[resume]
            let (steps, inStep) = place(time)
            let missing = steps - 1

            if inStep, missing >= 1, missing <= maxGapBeats {
                let spacing = (time - last.time) / Double(steps)
                for step in 1...missing {
                    out.append(Beat(
                        number: last.number + step,
                        time: last.time + spacing * Double(step),
                        estimated: true
                    ))
                }
                period += periodGain * (spacing - period)
            }
            // Otherwise the stretch stays empty: it is too long, or the music
            // starts again out of step with what came before it.
            out.append(Beat(number: last.number + steps, time: time, estimated: false))
            next = resume + 1
        }
        return out
    }

    static func sortedDistinct(_ times: [Double]) -> [Double] {
        var result: [Double] = []
        for time in times.filter(\.isFinite).sorted() where time != result.last {
            result.append(time)
        }
        return result
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

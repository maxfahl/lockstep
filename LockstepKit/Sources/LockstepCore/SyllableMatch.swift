/// Says which syllable of a lead each syllable of a double belongs to.
///
/// Max records a double of a line on another track and aims its correction at the lead. The double's
/// syllables are then moved onto the lead's and not onto the sub-beats, so the two voices sound like one.
/// Both lists are in the order of the song, in song seconds.
///
///     // 1. How far the whole line of the double slides: the one distance that suits most of its syllables.
///     let slide = SyllableMatch.slide(of: times, onto: lead, reach: settings.partnerReach)
///
///     // 2. Who is paired with whom, measured where the slide put the double.
///     let partners = SyllableMatch.partners(
///         of: times.map { $0 + slide }, among: lead, within: settings.maxSyllableMoveMs / 1_000
///     )
///     partners[2]                 // the place in `lead` of the third syllable's partner, or nil
///
/// The slide is the middle value of the distances from each syllable to the lead syllable nearest to it.
/// The middle value, not the mean: a syllable that is far off, or that the lead does not have, then cannot
/// drag the line away from where the others fit.
///
/// The pairing keeps three rules: a lead syllable has one partner at most, pairs never cross (the double's
/// third syllable is never paired with an earlier lead syllable than its second), and a partner is never
/// further away than the furthest a syllable may move. Among the pairings that keep them, the one with the
/// most pairs wins, and among those the one with the least distance in all. So a syllable the lead does not
/// have is left without a partner, and of two syllables near one lead syllable the nearer one has it.
///
/// `SyllableMoves` then moves each paired syllable onto its partner, and `MarkerDistance.measure` colours a
/// marker by its distance to its partner.
public enum SyllableMatch {
    /// How long a syllable must last to count as a held note, in milliseconds. Where a syllable of the double
    /// and its partner are both held, the end of the double's note is matched as well (`SyllableMoves`).
    public static let heldNoteMs: Double = 250

    /// What two distances may differ by and still count as the same, in seconds: far less than a sample. A
    /// syllable that is exactly as far away as the limit allows is then not lost to a rounding error.
    static let sameSeconds = 1e-9

    /// How far a line slides as a whole to sit on the lead, in seconds: the middle value of the distances
    /// from each of its syllables to the lead syllable nearest to it. Negative is earlier.
    ///
    /// A syllable with no lead syllable within `reach` does not count: it could never be paired, so it says
    /// nothing about where the line belongs. 0 when no syllable counts, and the line stays: a line the lead
    /// does not have at all, such as an ad-lib.
    ///
    /// The answer is not held to the furthest slide. Whoever slides the line does that, after the strength
    /// (`ClipTightening.lines`).
    ///
    /// - Parameters:
    ///   - times: when each syllable of the line is heard, in song seconds. Leave out the ones Max excluded.
    ///   - targets: the lead's syllables, earliest first.
    ///   - reach: how far away a lead syllable may be and still count, in seconds: the furthest slide plus
    ///     the furthest move of a syllable (`TightenSettings.partnerReach`).
    public static func slide(of times: [Double], onto targets: [TimingTargets.Target], reach: Double) -> Double {
        guard reach.isFinite else { return 0 }
        let distances = times.compactMap { time -> Double? in
            guard let nearest = nearest(to: time, in: targets) else { return nil }
            let distance = targets[nearest].time - time
            return abs(distance) <= reach + sameSeconds ? distance : nil
        }.sorted()
        guard !distances.isEmpty else { return 0 }
        let middle = distances.count / 2
        return distances.count % 2 == 1 ? distances[middle] : (distances[middle - 1] + distances[middle]) / 2
    }

    /// The partner of each syllable: its place in `targets`, or nil for a syllable that has none. The answer
    /// has one entry for every time, in the order they were given.
    ///
    /// - Parameters:
    ///   - times: when each syllable of the double is heard after its line has slid, in song seconds. Leave
    ///     out the ones Max excluded: they take no partner.
    ///   - targets: the lead's syllables, earliest first.
    ///   - reach: the furthest a partner may be away, in seconds: the furthest a syllable may move.
    public static func partners(
        of times: [Double],
        among targets: [TimingTargets.Target],
        within reach: Double
    ) -> [Int?] {
        var partners = [Int?](repeating: nil, count: times.count)
        guard reach.isFinite, reach >= 0, !times.isEmpty, !targets.isEmpty else { return partners }
        // The syllables in the order of the song, whatever order they came in.
        let order = times.indices.filter { times[$0].isFinite }.sorted { times[$0] < times[$1] }
        guard let earliest = order.first, let latest = order.last else { return partners }
        // Only the lead syllables near these syllables can be a partner. A line is a few syllables and a
        // lead is a whole clip of them, so the rest are left out of the search.
        let near = reach + sameSeconds
        guard let from = targets.firstIndex(where: { $0.time >= times[earliest] - near }),
              let through = targets.lastIndex(where: { $0.time <= times[latest] + near }),
              from <= through
        else { return partners }
        let targets = targets[from...through]

        // The best that can be done with the first `row` syllables and the first `column` lead syllables:
        // how many pairs, and how much distance they add up to. Each answer is built from the three before
        // it: this syllable goes without, this lead syllable goes without, or the two are a pair.
        struct Best {
            var pairs = 0
            var distance = 0.0

            func beats(_ other: Best) -> Bool {
                pairs != other.pairs ? pairs > other.pairs : distance < other.distance - SyllableMatch.sameSeconds
            }
        }
        enum Step: UInt8 { case start, syllableAlone, leadAlone, pair }
        let columns = targets.count + 1
        var best = [Best](repeating: Best(), count: (order.count + 1) * columns)
        var steps = [Step](repeating: .start, count: best.count)
        for row in 1...order.count {
            let time = times[order[row - 1]]
            steps[row * columns] = .syllableAlone
            for column in 1..<columns {
                let cell = row * columns + column
                // A pair is taken wherever it is as good as going without, so two voices that fit are
                // paired syllable for syllable.
                var chosen = best[cell - columns]
                var step = Step.syllableAlone
                let distance = abs(targets[from + column - 1].time - time)
                if distance <= reach + sameSeconds {
                    var paired = best[cell - columns - 1]
                    paired.pairs += 1
                    paired.distance += distance
                    if !chosen.beats(paired) {
                        chosen = paired
                        step = .pair
                    }
                }
                if best[cell - 1].beats(chosen) {
                    chosen = best[cell - 1]
                    step = .leadAlone
                }
                best[cell] = chosen
                steps[cell] = step
            }
        }

        // Back from the end along the steps that were chosen.
        var row = order.count
        var column = targets.count
        while row > 0 {
            switch steps[row * columns + column] {
            case .pair:
                partners[order[row - 1]] = from + column - 1
                row -= 1
                column -= 1
            case .leadAlone:
                column -= 1
            case .syllableAlone, .start:
                row -= 1
            }
        }
        return partners
    }

    /// Where the note of each syllable ends, in samples of the recording: where the pause after it starts,
    /// or, when it runs into the next syllable, where that one starts. The last one is measured up to `end`.
    /// The answer has one entry for every marker.
    ///
    /// What a pause is, is the rule of `SyllablePauses`: at least 30 ms at or below the level that counts as
    /// sound, and of several before the next syllable the longest.
    ///
    /// The app asks this for the lead, to say where each of its notes ends (`TimingTargets.Target.noteEnd`).
    /// The end of a note of the double is found by the same rule, inside `SyllableMoves`.
    ///
    /// - Parameters:
    ///   - markers: the sample positions of the syllables, earliest first.
    ///   - end: where the stretch that holds them ends: one past its last sample.
    ///   - levels: how loud the recording is.
    public static func noteEnds(of markers: [Int], until end: Int, levels: VoiceLevels) -> [Int] {
        zip(markers, markers.dropFirst() + [end]).map { marker, next in
            guard next > marker else { return marker }
            return SyllablePauses.longest(in: marker..<next, levels: levels)?.lowerBound ?? next
        }
    }

    /// The place in `targets` of the syllable nearest to a time, the earlier of two that are equally near.
    /// Nil when there is none.
    static func nearest(to time: Double, in targets: [TimingTargets.Target]) -> Int? {
        guard time.isFinite, !targets.isEmpty else { return nil }
        // The first that is not before the time, by halving.
        var low = 0
        var high = targets.count
        while low < high {
            let middle = (low + high) / 2
            if targets[middle].time < time { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return 0 }
        guard low < targets.count else { return targets.count - 1 }
        return time - targets[low - 1].time <= targets[low].time - time ? low - 1 : low
    }
}

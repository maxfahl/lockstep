/// How a syllable sits on the beat: counted as on it, a little off, or so far off that it
/// must be meant that way.
public enum MarkerClass: Sendable, Equatable, CaseIterable {
    /// Within a tenth of the sub-beat spacing.
    case onBeat
    /// Further off than that, but not so far that it looks meant.
    case slightlyOff
    /// So far from any sub-beat that it counts as meant to be off. It is shown in a
    /// neutral colour and is not an error.
    case deliberate
}

/// Measures a moment of the song, such as a syllable marker, against the sub-beats: the
/// beats and the evenly spaced steps between two neighbouring beats.
///
///     if let nearest = MarkerDistance.nearestSubBeat(to: marker.songTime, grid: grid) {
///         let offset = marker.songTime - nearest.subBeatTime          // seconds, positive is late
///         MarkerDistance.classify(offset: offset, spacing: nearest.spacing)   // .slightlyOff
///         MarkerDistance.readout(offset: offset)                              // "23 ms late"
///     }
///
/// Where the grid has no beats there is nothing to measure against, and the answer is nil.
public enum MarkerDistance {
    /// How far from a sub-beat still counts as on the beat, as a percentage of the
    /// sub-beat spacing. It is fixed: it is not one of Max's settings.
    public static let onBeatPercent: Double = 10
    /// How far from a sub-beat a syllable must be to count as meant that way, as a
    /// percentage of the sub-beat spacing, until the setting says otherwise.
    public static let defaultDeliberatePercent: Double = 35

    /// The sub-beat closest to a moment of the song, and how far apart the sub-beats are
    /// there, both in seconds.
    ///
    /// Sub-beats divide the stretch between two neighbouring beats into `perBeat` equal
    /// parts (4 for sixteenths, 6 for triplets), so the spacing follows the tempo where
    /// the moment is. Halfway between two sub-beats either may be given.
    ///
    /// Nil where the grid has no beats: before the first beat, after the last, and inside
    /// a gap that was left empty. A moment less than half a sub-beat outside such an edge
    /// still belongs to the beat at the edge, so a syllable that comes a little early for
    /// the first beat after a gap is measured against that beat.
    public static func nearestSubBeat(
        to time: Double,
        grid: Grid,
        perBeat: Int = 4
    ) -> (subBeatTime: Double, spacing: Double)? {
        let beats = grid.beats
        guard perBeat >= 1, !beats.isEmpty, time.isFinite else { return nil }
        guard let before = grid.lastIndex(atOrBefore: time) else {
            return edge(at: 0, near: time, grid: grid, perBeat: perBeat)
        }
        if before + 1 < beats.count, grid.follows(before) {
            // Between two neighbouring beats: the steps are counted from the earlier one.
            let start = beats[before].time
            let spacing = (beats[before + 1].time - start) / Double(perBeat)
            guard spacing > 0 else { return nil }
            let step = min(((time - start) / spacing).rounded(), Double(perBeat))
            return (step == Double(perBeat) ? beats[before + 1].time : start + step * spacing, spacing)
        }
        // After a beat that nothing follows. Past it lies the end of the beats, or an
        // empty gap with the next beat on its far side.
        if let found = edge(at: before, near: time, grid: grid, perBeat: perBeat) { return found }
        guard before + 1 < beats.count else { return nil }
        return edge(at: before + 1, near: time, grid: grid, perBeat: perBeat)
    }

    /// Which class a syllable falls in.
    ///
    /// - Parameters:
    ///   - offset: its distance from the nearest sub-beat in seconds, early or late.
    ///   - spacing: how far apart the sub-beats are there, in seconds.
    ///   - deliberatePercent: how far off, as a percentage of the spacing, counts as meant.
    public static func classify(
        offset: Double,
        spacing: Double,
        deliberatePercent: Double = defaultDeliberatePercent
    ) -> MarkerClass {
        guard spacing > 0 else { return .deliberate }
        let percent = abs(offset) / spacing * 100
        if percent <= onBeatPercent { return .onBeat }
        return percent <= deliberatePercent ? .slightlyOff : .deliberate
    }

    /// How far from its partner a syllable of a double still counts as on it, in milliseconds. Against
    /// another voice there is no sub-beat spacing to take a tenth of. Two voices this close are heard as one.
    public static let onPartnerMs: Double = 10

    /// How one syllable sits against what its clip is held against.
    public struct Measure: Sendable, Equatable {
        /// Its distance in seconds, positive when it is late: from the nearest sub-beat, or from its partner
        /// for a clip that is held against another track. Nil when there is nothing to measure against:
        /// where the song has no beats, or a syllable without a partner.
        public var offset: Double?
        /// The class its marker is coloured by. A syllable with nothing to measure against is `deliberate`,
        /// the neutral colour.
        public var kind: MarkerClass

        public init(offset: Double?, kind: MarkerClass) {
            self.offset = offset
            self.kind = kind
        }
    }

    /// How the syllables of a clip sit against what the clip is held against, one answer for every time in
    /// the order they were given.
    ///
    ///     let measured = MarkerDistance.measure(times: shownTimes, against: inputs.targets, settings: settings)
    ///     measured[0].kind                  // .slightlyOff
    ///     measured[0].offset                // 0.023, or nil where there is no distance to read
    ///
    /// Against sub-beats each syllable is measured by `nearestSubBeat` and `classify`, as it always was.
    ///
    /// Against the syllables of another track, a syllable is judged by its distance to its partner: on it
    /// within 10 ms (`onPartnerMs`), a little off beyond that. One without a partner is neutral and has no
    /// distance. The partners are found the way the correction finds them, with the times taken as one line:
    /// first the slide that suits most of them (`SyllableMatch.slide`, held to the furthest slide), then the
    /// pairing where that slide would put them (`SyllableMatch.partners`). So a double that is 60 ms late all
    /// through shows every syllable 60 ms late, which is what the correction would take away, and a syllable
    /// shown neutral is one the correction leaves alone. The distance itself is always measured from where
    /// the syllable is heard, not from where a slide would put it.
    ///
    /// - Parameters:
    ///   - times: when each syllable is heard, in song seconds, in any order.
    ///   - excluded: the places in `times` of the syllables Max excluded. Against another track they take no
    ///     partner, as in the correction. Against sub-beats they are measured like the others.
    ///   - targets: what the clip is held against.
    ///   - settings: how far off counts as meant, the furthest slide and the furthest move of a syllable.
    public static func measure(
        times: [Double],
        excluded: Set<Int> = [],
        against targets: TimingTargets,
        settings: TightenSettings = TightenSettings()
    ) -> [Measure] {
        switch targets {
        case let .subBeats(grid, perBeat):
            return times.map { time in
                guard let nearest = nearestSubBeat(to: time, grid: grid, perBeat: perBeat) else {
                    return Measure(offset: nil, kind: .deliberate)
                }
                let offset = time - nearest.subBeatTime
                return Measure(
                    offset: offset,
                    kind: classify(
                        offset: offset, spacing: nearest.spacing, deliberatePercent: settings.deliberatePercent
                    )
                )
            }
        case let .times(lead):
            var measured = [Measure](repeating: Measure(offset: nil, kind: .deliberate), count: times.count)
            let counted = times.indices.filter { !excluded.contains($0) && times[$0].isFinite }
            let furthest = max(settings.maxLineShiftMs, 0) / 1_000
            let slide = min(
                max(SyllableMatch.slide(of: counted.map { times[$0] }, onto: lead, reach: settings.partnerReach), -furthest),
                furthest
            )
            let partners = SyllableMatch.partners(
                of: counted.map { times[$0] + slide },
                among: lead,
                within: max(settings.maxSyllableMoveMs, 0) / 1_000
            )
            for (place, partner) in zip(counted, partners) {
                guard let partner else { continue }
                let offset = times[place] - lead[partner].time
                measured[place] = Measure(
                    offset: offset,
                    kind: abs(offset) * 1_000 <= onPartnerMs ? .onBeat : .slightlyOff
                )
            }
            return measured
        }
    }

    /// The distance in words: "23 ms late", "8 ms early", or "on the beat" when it is
    /// under a millisecond. A positive offset is late.
    public static func readout(offset: Double) -> String {
        let milliseconds = abs(offset) * 1000
        guard milliseconds.isFinite, milliseconds >= 1 else { return "on the beat" }
        return "\(Int(milliseconds.rounded())) ms \(offset > 0 ? "late" : "early")"
    }

    /// The beat at `index` as the sub-beat for a moment on the side of it where the grid
    /// has no beats. The spacing is that of the neighbouring beats on its other side.
    /// Nil when the moment is more than half a sub-beat away, or the beat stands alone.
    private static func edge(
        at index: Int,
        near time: Double,
        grid: Grid,
        perBeat: Int
    ) -> (subBeatTime: Double, spacing: Double)? {
        let beats = grid.beats
        let beat = beats[index].time
        let length: Double
        if time >= beat, index > 0, grid.follows(index - 1) {
            length = beat - beats[index - 1].time
        } else if time < beat, index + 1 < beats.count, grid.follows(index) {
            length = beats[index + 1].time - beat
        } else {
            return nil
        }
        let spacing = length / Double(perBeat)
        guard spacing > 0, abs(time - beat) <= spacing / 2 else { return nil }
        return (beat, spacing)
    }
}

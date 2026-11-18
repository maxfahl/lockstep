/// Works out how far each syllable of one line moves toward its nearest sub-beat, and gives the answer as the
/// line's time map.
///
/// It comes after the slide of the line: the line has already slid as a whole (`LineShift`), and each syllable
/// is measured where it sits after that slide.
///
/// The first syllable of a line is the one exception to "inside the line". It has no sound before it that
/// could give or take a move, so its own move is made by the whole line (`ClipTightening.lines`), and the
/// plan is told how much that was (`carriedSamples`). Every syllable is then measured where the slide alone
/// put it, and what the line already went on by is taken off what the syllable asks for. So all syllables of
/// a line, the first included, end up the same share of the way from where the slide put them to their
/// sub-beats.
///
///     let map = SyllableMoves.plan(
///         line: line.line,                       // a `ClipTightening.Line`
///         shiftSamples: line.shiftSamples,       // how far the whole line slid
///         songStart: line.songStart,
///         grid: inputs.grid,
///         perBeat: inputs.perBeat,               // 4 for sixteenths, 6 for triplets
///         strength: clip.syllableStrength,       // 0 moves nothing, 1 moves all the way
///         excluded: recording.excludedSamples(among: markers),
///         levels: levels                         // how loud the recording is, so the pauses are known
///     )
///     map.result(ofSource: marker) - marker      // how far that syllable ends up from where it was recorded
///
/// What each syllable asks for:
/// - Nothing, when Max excluded it, when it is further from its sub-beat than counts as meant that way, or
///   when the song has no beats there.
/// - Otherwise `strength` times its distance to the sub-beat, and never more than the syllable limit.
///
/// What it gets is that or less, never more and never the other way, because the line has to stay natural:
/// - The line's first and last sample stay where the move of the line as a whole put them, so nothing outside
///   the line is touched.
/// - Two neighbouring syllables keep at least 20 ms between them, so none reaches or passes another.
/// - Where two neighbours (the line's start, each syllable, the line's end) run together, the sound between
///   them is never made longer than `1 + p` times its length nor shorter than `1 / (1 + p)` times it, where
///   `p` is the stretch limit: 0.8 to 1.25 at 25 %.
/// - Where a pause lies between two neighbours, nothing is stretched there: the pause gets longer or shorter
///   instead, so the stretch limit does not hold the two back. The pause does: a plan leaves 21 ms of it.
///   What a pause is, is written in `SyllablePauses`, and the code that builds the sound asks there too.
///
/// With the stretch limit at 0 nothing is stretched at all. Syllables that run together then move only as
/// one block, all by the same amount, and a block moves by changing the pauses on its two sides. That is what
/// a clip with Stretch off gets, whatever the setting says (`ClipTightening.Inputs(correcting:)`).
///
/// A clip that aims at another track is held against that track's syllables in place of the sub-beats
/// (`TimingTargets.times`). Then:
/// - A syllable asks for `strength` times its distance to its partner, the lead syllable it is paired with
///   (`SyllableMatch.partners`). One without a partner asks for nothing, as does one Max excluded.
/// - "Meant to be off" is not asked: a double is meant to sit on the lead.
/// - Everything that holds a move back is the same as against sub-beats.
/// - With a stretch limit above 0, the end of a held note is matched too (`noteEnds`).
///
///     let map = SyllableMoves.plan(
///         line: line.line, shiftSamples: line.shiftSamples, carriedSamples: line.carriedSamples,
///         songStart: line.songStart,
///         targets: inputs.targets,               // the sub-beats, or the lead's syllables
///         strength: clip.syllableStrength, excluded: excluded, levels: levels
///     )
public enum SyllableMoves {
    /// The furthest a syllable may move, in milliseconds, until the setting `timing.maxSyllableMoveMs` says
    /// otherwise.
    public static let defaultMaxMoveMs: Double = 40
    /// The most the sound between two syllables may be stretched or squeezed, as a percentage, until the
    /// setting `timing.maxStretchPercent` says otherwise.
    public static let defaultMaxStretchPercent: Double = 25
    /// How much time two neighbouring syllables always keep between them, in milliseconds. Two that were
    /// recorded closer than this keep the distance they have.
    public static let minimumGapMs: Double = 20

    /// The numbers that hold the moves back. They start as the values below and become Max's settings.
    public struct Limits: Sendable, Equatable {
        /// How far from a sub-beat counts as meant to be off, as a percentage of the sub-beat spacing: the
        /// setting `timing.deliberatePercent`. A syllable further off than this is left alone.
        public var deliberatePercent: Double
        /// The furthest a syllable may move, in milliseconds: the setting `timing.maxSyllableMoveMs`.
        public var maxMoveMs: Double
        /// The most the sound between two syllables may be stretched or squeezed, as a percentage: the setting
        /// `timing.maxStretchPercent`. At 0 nothing is stretched and only pauses change: syllables that run
        /// together move as one block, and a line with no pause in it does not change.
        public var maxStretchPercent: Double

        public init(
            deliberatePercent: Double = MarkerDistance.defaultDeliberatePercent,
            maxMoveMs: Double = SyllableMoves.defaultMaxMoveMs,
            maxStretchPercent: Double = SyllableMoves.defaultMaxStretchPercent
        ) {
            self.deliberatePercent = deliberatePercent
            self.maxMoveMs = maxMoveMs
            self.maxStretchPercent = maxStretchPercent
        }
    }

    /// The time map of one line with its syllables moved.
    ///
    /// The map has one pair for the line's first sample, one for every syllable marker strictly inside the
    /// line, and one for the line's end, in that order. What whoever builds the sound can rely on:
    /// - The sources rise from pair to pair, and so do the results: nothing crosses.
    /// - The first and the last pair move by `shiftSamples` exactly, so the line is as long as it was.
    /// - A pair in between moves by `shiftSamples` plus that syllable's own move, which is 0 for a syllable
    ///   that stays. With `carriedSamples`, a syllable that stays where the slide put it moves back by that
    ///   much inside the line, where its neighbours let it.
    /// - Between two neighbouring pairs with no pause between them, `result` length divided by `source`
    ///   length is within the stretch limit, and the two results are at least `minimumGapMs` apart unless the
    ///   sources are closer than that, in which case they are no closer than the sources.
    /// - Between two neighbouring pairs with a pause between them (`SyllablePauses`), the `result` length is
    ///   the `source` length made longer by any amount, or shorter by no more than the pause can give while
    ///   keeping 21 ms. `LineRenderer.quantized` builds that by changing the pause alone, when it is given
    ///   the same `levels`.
    ///
    /// - Parameters:
    ///   - line: the line, in samples of its recording.
    ///   - shiftSamples: how far the line has moved as a whole, in samples.
    ///   - carriedSamples: how much of `shiftSamples` is the first syllable's own move, which the whole line
    ///     made with it, in samples (`ClipTightening.Line.carriedSamples`). The rest is the slide.
    ///   - songStart: when the line's first sample sounds in the song as it was recorded, before the slide,
    ///     in song seconds.
    ///   - grid: the beats of the song.
    ///   - perBeat: how many sub-beats a beat has: 4 for sixteenths, 6 for triplets.
    ///   - strength: how much of the way each syllable goes, from 0 to 1.
    ///   - excluded: the sample positions of the markers Max excluded. They do not move.
    ///   - levels: how loud the line's recording is, the same that is handed to `LineRenderer.quantized`.
    ///     From it the pauses inside the line are found. Left out, the line is taken to have no pause, and
    ///     the stretch limit holds between all neighbours.
    public static func plan(
        line: VoiceLine,
        shiftSamples: Int = 0,
        carriedSamples: Int = 0,
        songStart: Double,
        grid: Grid,
        perBeat: Int = 4,
        strength: Double,
        excluded: Set<Int> = [],
        limits: Limits = Limits(),
        levels: VoiceLevels? = nil
    ) -> TimeMap {
        plan(
            line: line,
            shiftSamples: shiftSamples,
            carriedSamples: carriedSamples,
            songStart: songStart,
            targets: .subBeats(grid: grid, perBeat: perBeat),
            strength: strength,
            excluded: excluded,
            limits: limits,
            levels: levels
        )
    }

    /// The time map of one line with its syllables moved toward what its clip is held against: the
    /// sub-beats, or the syllables of another track. Everything written for the plan against sub-beats above
    /// holds, and against sub-beats the answer is the same.
    ///
    /// Against another track, with a stretch limit above 0 and `levels` handed in, the map can have one more
    /// pair after a syllable: the end of its note (`noteEnds`). Its source is where the pause after the
    /// syllable starts, so it is no marker of the line. The promises about neighbouring pairs hold for it as
    /// for any other pair.
    ///
    /// - Parameter targets: what the clip is held against.
    public static func plan(
        line: VoiceLine,
        shiftSamples: Int = 0,
        carriedSamples: Int = 0,
        songStart: Double,
        targets: TimingTargets,
        strength: Double,
        excluded: Set<Int> = [],
        limits: Limits = Limits(),
        levels: VoiceLevels? = nil
    ) -> TimeMap {
        guard line.lengthSamples > 0 else { return TimeMap(line: line, shiftSamples: shiftSamples) }
        // A marker on the line's very first sample cannot move, because the line's start does not, and it
        // would be a second pair for the same sample. So it is not one of the points.
        let markers = Set(line.markers.filter { $0 > line.startSample && $0 < line.endSample }).sorted()
        let points = [line.startSample] + markers + [line.endSample]
        // Each syllable is measured where the slide alone put it. What it asks for from there, it has
        // already got as much of as the whole line went on by.
        let slide = shiftSamples - carriedSamples
        let wanted = wanted(
            of: line,
            slideSamples: slide,
            songStart: songStart,
            targets: targets,
            strength: strength,
            excluded: excluded,
            limits: limits
        )
        let asked = [0] + markers.map { (wanted.moves[$0] ?? 0) - carriedSamples } + [0]
        let moves = held(
            asked,
            points: points,
            maxStretchPercent: limits.maxStretchPercent,
            pauses: levels.map { SyllablePauses.lengths(between: points, levels: $0) } ?? []
        )
        var pairs = zip(points, moves).map { point, move in
            TimeMap.Pair(source: point, result: point + shiftSamples + move)
        }
        if let levels, !wanted.partners.isEmpty {
            let ends = noteEnds(
                points: points,
                moves: moves,
                partners: wanted.partners,
                // Where a sample of the recording is heard after the slide alone, as the syllables are
                // measured.
                time: { songStart + Double($0 - line.startSample + slide) / Lockstep.sampleRate },
                carriedSamples: carriedSamples,
                strength: strength,
                maxStretchPercent: limits.maxStretchPercent,
                levels: levels
            )
            // From the last to the first, so the places of the ones still to come do not move.
            for end in ends.reversed() {
                pairs.insert(
                    TimeMap.Pair(source: end.sample, result: end.sample + shiftSamples + end.move),
                    at: end.after + 1
                )
            }
        }
        return TimeMap(pairs: pairs)
    }

    /// What the syllables of a line ask for, before their neighbours are looked at.
    struct Wanted: Equatable {
        /// How far each syllable would like to move from where the slide alone put it, in samples, by its
        /// sample position. A syllable Max excluded is not in here.
        var moves: [Int: Int] = [:]
        /// Against another track: the lead syllable each paired syllable is held against, by the syllable's
        /// sample position. Empty against sub-beats.
        var partners: [Int: TimingTargets.Target] = [:]
    }

    /// What every syllable of a line asks for. `plan` asks this for the line's map, and `ClipTightening.lines`
    /// asks it for the first syllable, whose move the whole line makes. Both get the same pairing, because
    /// both ask here with the same slide.
    ///
    /// - Parameters:
    ///   - slideSamples: how far the line has slid as a line, in samples: its shift without what it goes on
    ///     with its first syllable.
    ///   - strength: how much of the way each syllable goes, from 0 to 1. At 0 nothing is asked for, but the
    ///     partners are still found.
    static func wanted(
        of line: VoiceLine,
        slideSamples: Int,
        songStart: Double,
        targets: TimingTargets,
        strength: Double,
        excluded: Set<Int> = [],
        limits: Limits = Limits()
    ) -> Wanted {
        let markers = Set(line.markers.filter { $0 >= line.startSample && $0 < line.endSample })
            .subtracting(excluded)
            .sorted()
        func time(_ marker: Int) -> Double {
            songStart + Double(marker - line.startSample + slideSamples) / Lockstep.sampleRate
        }
        var wanted = Wanted()
        switch targets {
        case let .subBeats(grid, perBeat):
            for marker in markers {
                wanted.moves[marker] = wantedMove(
                    at: time(marker), grid: grid, perBeat: perBeat, strength: strength, limits: limits
                )
            }
        case let .times(lead):
            let times = markers.map(time)
            let reach = max(limits.maxMoveMs, 0) / 1_000
            let partners = SyllableMatch.partners(of: times, among: lead, within: reach)
            for (index, marker) in markers.enumerated() {
                guard let partner = partners[index] else {
                    wanted.moves[marker] = 0
                    continue
                }
                wanted.partners[marker] = lead[partner]
                wanted.moves[marker] = wantedMove(
                    from: times[index], to: lead[partner].time, strength: strength, limits: limits
                )
            }
        }
        return wanted
    }

    /// How far a syllable that sounds at `time` would like to move to sit on its partner, in samples.
    /// Negative is earlier. Whether it is far off is not asked: the pairing has already said that the
    /// partner is within reach.
    static func wantedMove(from time: Double, to partner: Double, strength: Double, limits: Limits) -> Int {
        guard strength.isFinite, strength > 0 else { return 0 }
        let furthest = wholeSamples(milliseconds: limits.maxMoveMs)
        let wanted = (min(strength, 1) * (partner - time) * Lockstep.sampleRate).rounded()
        guard wanted.isFinite else { return 0 }
        return Int(min(max(wanted, Double(-furthest)), Double(furthest)))
    }

    /// The end of one held note, as one more pair of a line's map.
    struct NoteEnd: Equatable {
        /// The place, in the list of points, of the syllable whose note it ends. The pair goes after it.
        var after: Int
        /// Where the note ends, in samples of the recording: where the pause after the syllable starts.
        var sample: Int
        /// How far it moves inside the line, in samples.
        var move: Int
    }

    /// The ends of held notes that move onto the ends of the lead's notes: for sung doubles, where two
    /// voices that start a note together should also let go of it together.
    ///
    /// A note end is matched where all of this is true:
    /// - The stretch limit is above 0. With Stretch off no note is stretched, so none ends elsewhere.
    /// - The syllable has a partner, and it is known where the partner's note ends.
    /// - Both notes are held: longer than 250 ms (`SyllableMatch.heldNoteMs`).
    /// - The double's note ends at a pause (`SyllablePauses`), with unbroken sound up to it. A note that runs
    ///   into the next syllable ends where that syllable starts, and that one has a partner of its own.
    ///
    /// The end asks for `strength` times its distance to the end of the lead's note. What it gets is held to
    /// what the moves of the syllables, which are already settled, leave free: the note is stretched or
    /// squeezed within the stretch limit, and the pause after it keeps what a plan leaves of a pause. So a
    /// note end never holds a syllable back. The pause after the note takes up the change.
    ///
    /// The last note of a line can be made shorter by any amount the stretch limit allows, but hardly
    /// longer: the line keeps its length, and only the 30 ms of quiet at its end can give.
    ///
    /// - Parameters:
    ///   - points: the line's start, its markers and its end.
    ///   - moves: the move each point gets, from `held`.
    ///   - partners: the lead syllable of each paired syllable, by sample position.
    ///   - time: when a sample of the recording is heard after the line's slide alone, in song seconds.
    static func noteEnds(
        points: [Int],
        moves: [Int],
        partners: [Int: TimingTargets.Target],
        time: (Int) -> Double,
        carriedSamples: Int,
        strength: Double,
        maxStretchPercent: Double,
        levels: VoiceLevels
    ) -> [NoteEnd] {
        guard strength.isFinite, strength > 0, maxStretchPercent.isFinite, maxStretchPercent > 0,
              points.count >= 3
        else { return [] }
        let held = wholeSamples(milliseconds: SyllableMatch.heldNoteMs)
        var ends: [NoteEnd] = []
        for index in 1..<points.count - 1 {
            let (marker, next) = (points[index], points[index + 1])
            guard let partner = partners[marker], let leadEnd = partner.noteEnd,
                  leadEnd - partner.time > SyllableMatch.heldNoteMs / 1_000,
                  let pause = SyllablePauses.longest(in: marker..<next, levels: levels),
                  pause.lowerBound - marker > held,
                  SyllablePauses.longest(in: marker..<pause.lowerBound, levels: levels) == nil
            else { continue }
            let end = pause.lowerBound
            let asked = (min(strength, 1) * (leadEnd - time(end)) * Lockstep.sampleRate).rounded()
            guard asked.isFinite, abs(asked) < 1e9 else { continue }
            // What the note may change by, from its syllable, and what the pause after it can give.
            let note = room(length: end - marker, pause: nil, maxStretchPercent: maxStretchPercent)
            let lowest = moves[index] + note.lowerBound
            let highest = min(
                moves[index] + note.upperBound,
                moves[index + 1] + SyllablePauses.mostAPlanTakes(from: pause.count)
            )
            guard lowest <= highest else { continue }
            let move = min(max(Int(asked) - carriedSamples, lowest), highest)
            // An end that goes where its syllable goes needs no pair: it does that anyway.
            guard move != moves[index] else { continue }
            ends.append(NoteEnd(after: index, sample: end, move: move))
        }
        return ends
    }

    /// How far a syllable that sounds at `time` would like to move, in samples, before its neighbours are
    /// looked at. Negative is earlier.
    static func wantedMove(at time: Double, grid: Grid, perBeat: Int, strength: Double, limits: Limits) -> Int {
        guard strength.isFinite, strength > 0,
              let nearest = MarkerDistance.nearestSubBeat(to: time, grid: grid, perBeat: perBeat)
        else { return 0 }
        // Moving by this much would land the syllable on its sub-beat.
        let distance = nearest.subBeatTime - time
        // "Meant to be off" is decided by the same function that colours the marker, so a syllable shown in
        // the neutral colour is exactly one that stays.
        let kind = MarkerDistance.classify(
            offset: distance,
            spacing: nearest.spacing,
            deliberatePercent: limits.deliberatePercent
        )
        guard kind != .deliberate else { return 0 }
        let furthest = wholeSamples(milliseconds: limits.maxMoveMs)
        let wanted = (min(strength, 1) * distance * Lockstep.sampleRate).rounded()
        guard wanted.isFinite else { return 0 }
        return Int(min(max(wanted, Double(-furthest)), Double(furthest)))
    }

    /// The moves the points really get: what they asked for, made smaller wherever the sound between two
    /// neighbours would otherwise be stretched or squeezed too much, two points would come too close, or a
    /// pause between them would be left too short.
    ///
    /// How much the distance between two neighbours may change:
    /// - With a pause between them it may grow by any amount, and shrink by what the pause can give
    ///   (`SyllablePauses.mostAPlanTakes`). The stretch limit plays no part, because nothing is stretched.
    /// - Without one it may change by what the stretch limit allows, and 20 ms always stay between the two.
    ///   With the limit at 0 it may not change at all, so the two move by the same amount or not at all.
    ///
    /// Where the change between two neighbours is not allowed, their moves are made smaller, just enough for
    /// it to be allowed:
    /// - When both move the same way, or one of them stays, only the one that moves further is cut back, to
    ///   what the other gets plus what is allowed. So two syllables that run together and may not be
    ///   stretched both get the smaller of their two moves, and move as one block.
    /// - When they move in opposite directions, toward each other or apart, both are made smaller by the same
    ///   share.
    ///
    /// That is done again until every change is allowed. A move only ever gets smaller and never changes
    /// direction, so this ends: each round takes at least one sample off some move, and with no moves at all
    /// every change is allowed.
    ///
    /// - Parameters:
    ///   - asked: the move each point asks for, in samples. The first and the last point never move, whatever
    ///     is asked.
    ///   - points: the line's start, its markers and its end, as rising sample positions.
    ///   - pauses: how long the pause between each point and the next one is, in samples, or nil where there
    ///     is none: `SyllablePauses.lengths`. Left out, there are no pauses.
    static func held(_ asked: [Int], points: [Int], maxStretchPercent: Double, pauses: [Int?] = []) -> [Int] {
        precondition(asked.count == points.count, "Every point needs its move.")
        guard points.count >= 2 else { return asked.map { _ in 0 } }
        var moves = asked
        moves[0] = 0
        moves[moves.count - 1] = 0

        // How much the distance between two neighbours may change, in samples: from the most it may lose to
        // the most it may gain. Rounded inward, so a whole number of samples never oversteps the limit.
        let room: [ClosedRange<Int>] = zip(points, points.dropFirst()).enumerated().map { index, pair in
            Self.room(
                length: max(pair.1 - pair.0, 0),
                pause: pauses.indices.contains(index) ? pauses[index] : nil,
                maxStretchPercent: maxStretchPercent
            )
        }

        var settled = false
        while !settled {
            settled = true
            for index in room.indices {
                let (earlier, later) = (moves[index], moves[index + 1])
                let change = later - earlier
                let allowed = min(max(change, room[index].lowerBound), room[index].upperBound)
                guard allowed != change else { continue }
                if (earlier > 0 && later < 0) || (earlier < 0 && later > 0) {
                    // Whole-number division drops the fraction, which makes a move smaller, never larger.
                    // Done with fractions instead, a rounding error could leave the change one sample over
                    // what is allowed.
                    moves[index] = earlier * allowed / change
                    moves[index + 1] = later * allowed / change
                } else if abs(later) > abs(earlier) {
                    moves[index + 1] = earlier + allowed
                } else {
                    moves[index] = later - allowed
                }
                settled = false
            }
        }
        return moves
    }

    /// How much the distance between two neighbouring points may change, in samples: from the most it may
    /// lose to the most it may gain. Rounded inward, so a whole number of samples never oversteps the limit.
    ///
    /// - Parameters:
    ///   - length: how far apart the two points are, in samples.
    ///   - pause: how long the pause between them is, or nil when they run together.
    static func room(length: Int, pause: Int?, maxStretchPercent: Double) -> ClosedRange<Int> {
        if let pause {
            // The pause takes up the change, and it can only give what it has. It lies between the two
            // points, so what it gives is less than the distance between them, and they cannot cross.
            return -SyllablePauses.mostAPlanTakes(from: min(pause, length))...Int.max
        }
        let percent = maxStretchPercent.isFinite ? min(max(maxStretchPercent, 0), 10_000) : 0
        let most = 1 + percent / 100
        let gap = wholeSamples(milliseconds: minimumGapMs)
        let shortest = max(Int((Double(length) / most).rounded(.up)), min(gap, length))
        let longest = Int((Double(length) * most).rounded(.down))
        return (min(shortest, length) - length)...(max(longest, length) - length)
    }

    /// So many milliseconds as whole samples, rounded down. Nothing for a number that is no length.
    private static func wholeSamples(milliseconds: Double) -> Int {
        let samples = (milliseconds * Lockstep.sampleRate / 1_000).rounded(.down)
        guard samples.isFinite, samples > 0, samples < 1e9 else { return 0 }
        return Int(samples)
    }
}

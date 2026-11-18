// The sound of one line with single syllables moved.
//
// `SyllableMoves.plan` says where every syllable of a line goes. This file builds the sound that puts them
// there, and touches as little of the voice as it can:
//
//     let map = SyllableMoves.plan(line: line, shiftSamples: shift, songStart: start, grid: grid, strength: 0.6)
//     if let moved = LineRenderer.quantized(
//         line: line, map: map, recording: samples, levels: levels, stretcher: stretcher
//     ) {
//         // `moved` is the line's own sound, as long as the line, with its syllables at their new places
//         // inside it. `LineRenderer.render` lays it down where the line slides to (`quantized:`).
//     }
//
// How the sound is built:
// 1. The line is cut into runs. A run is a stretch of the line's sound with no pause in it. Two neighbouring
//    syllables are in different runs when a pause of at least 30 ms lies between them.
// 2. A pause between two runs takes up the change. Each run is laid at its new place, and the pause between
//    them gets longer (filled with its own room sound, mirrored) or shorter (its middle is left out), over a
//    10 ms crossfade. Not one sample of the syllables on either side is changed.
// 3. A run whose syllables all move by the same amount, within half a millisecond, moves as one block,
//    untouched.
// 4. Any other run goes through the stretcher once, with a key frame at each of its syllables.
// 5. The line's first and last sample count as syllables that stay, so the line keeps its length and begins
//    and ends with the samples that were recorded.
//
// A pause can only get so short: it keeps at least 20 ms. A pause that would have to give up more than that
// is not treated as a pause, and the sound around it is stretched instead. That does not happen with a map
// from `SyllableMoves.plan` that was given the same loudness: what a pause is and what it can take up is
// written once, in `SyllablePauses`, and the planner asks there too.

extension LineRenderer {
    /// How long a pause inside a line must be to take up a change, in milliseconds. Shorter ones are part of
    /// the sound around them. The number is `SyllablePauses.atLeastMs`.
    public static let syllablePauseMs: Double = SyllablePauses.atLeastMs
    /// How much of a pause is always kept when it is made shorter, in milliseconds. The number is
    /// `SyllablePauses.shortestMs`.
    public static let shortestPauseMs: Double = SyllablePauses.shortestMs
    /// Syllables of one run whose moves differ by no more than this, in milliseconds, move as one block.
    /// The number is `SyllablePauses.sameMoveMs`.
    public static let sameMoveMs: Double = SyllablePauses.sameMoveMs

    /// The sound of one line with its syllables moved as its map says, or nil when the line is used as it was
    /// recorded.
    ///
    /// The answer has exactly as many samples as the line, and its first sample is the line's first. The slide
    /// of the line as a whole is not in it: it holds only what changes inside the line.
    ///
    /// Nil when no syllable moves inside the line, when the map is not one `SyllableMoves.plan` gives for this
    /// line, when the recording does not hold the whole line, or when the stretcher gives an answer of the
    /// wrong length.
    ///
    /// - Parameters:
    ///   - line: the line, in samples of its recording.
    ///   - map: where its syllables go, from `SyllableMoves.plan`.
    ///   - recording: the recording's samples: mono, 48,000 Hz, sample 0 first.
    ///   - levels: how loud the recording is, to find the pauses inside the line.
    ///   - stretcher: what stretches the runs that cannot be moved as a block.
    ///   - fadeMs: the length of every crossfade, in milliseconds.
    public static func quantized(
        line: VoiceLine,
        map: TimeMap,
        recording: [Float],
        levels: VoiceLevels,
        stretcher: any TimeStretcher,
        fadeMs: Double = crossfadeMs
    ) -> [Float]? {
        guard let points = controlPoints(of: line, map: map),
              line.startSample >= 0, line.endSample <= recording.count
        else { return nil }
        let sound = Array(recording[line.startSample..<line.endSample])
        let fade = EdgeFade.samples(milliseconds: fadeMs)
        let runs = runs(of: line, points: points, levels: levels)

        var result: [Float] = []
        result.reserveCapacity(sound.count)
        for (index, run) in runs.enumerated() {
            if run.isStretched {
                let input = Array(sound[run.source])
                let length = input.count + run.endMove - run.startMove
                // The run's own start and end are not listed: they hold by themselves.
                let keyFrames = points[run.points].compactMap { point -> (source: Int, target: Int)? in
                    guard point.place > run.source.lowerBound, point.place < run.source.upperBound else { return nil }
                    let source = point.place - run.source.lowerBound
                    return (source: source, target: source + point.move - run.startMove)
                }
                var stretched = stretcher.stretch(input, keyFrames: keyFrames, outputLength: length)
                guard stretched.count == length else { return nil }
                // Both ends of the run are faded into the recorded sound, so the run begins and ends with
                // the samples that were recorded and meets what lies next to it without a jump. The fade
                // stays inside the part before the run's first syllable and after its last, which only
                // moved and was not stretched, when there is such a part.
                let lead = points[run.points.lowerBound].place - run.source.lowerBound
                let tail = run.source.upperBound - points[run.points.upperBound - 1].place
                let room = min(fade, length / 2, input.count / 2)
                let rising = lead > 0 ? min(room, lead) : room
                for step in 0..<rising {
                    let weight = Float(step) / Float(rising)
                    stretched[step] = weight * stretched[step] + (1 - weight) * input[step]
                }
                let falling = tail > 0 ? min(room, tail) : room
                for step in 0..<falling {
                    let weight = Float(step) / Float(falling)
                    stretched[length - 1 - step] = weight * stretched[length - 1 - step]
                        + (1 - weight) * input[input.count - 1 - step]
                }
                result += stretched
            } else {
                result += sound[run.source]
            }
            if index + 1 < runs.count {
                let next = runs[index + 1]
                result += resized(
                    Array(sound[run.source.upperBound..<next.source.lowerBound]),
                    by: next.startMove - run.endMove,
                    fade: fade
                )
            }
        }
        guard result.count == sound.count else { return nil }
        return result
    }

    // MARK: The line as points that move

    /// One moment of a line that has a place of its own in the map: the line's start, a syllable, or the
    /// line's end.
    struct ControlPoint: Equatable {
        /// Where it is, in samples from the line's first sample.
        var place: Int
        /// How far it moves inside the line, in samples. The slide of the whole line is not in it.
        var move: Int
    }

    /// The points of a line's map, or nil when nothing moves inside the line or the map is not one that
    /// sound can be built from: it must begin on the line's first sample and end on its end, both of which
    /// stay, and neither the places nor the new places may cross.
    static func controlPoints(of line: VoiceLine, map: TimeMap) -> [ControlPoint]? {
        guard line.lengthSamples > 0, map.pairs.count >= 3,
              let first = map.pairs.first, let last = map.pairs.last,
              first.source == line.startSample, last.source == line.endSample
        else { return nil }
        let shift = first.result - first.source
        let points = map.pairs.map {
            ControlPoint(place: $0.source - line.startSample, move: $0.result - $0.source - shift)
        }
        guard points[points.count - 1].move == 0, points.contains(where: { $0.move != 0 }) else { return nil }
        for (earlier, later) in zip(points, points.dropFirst()) {
            guard later.place > earlier.place, later.place + later.move > earlier.place + earlier.move else {
                return nil
            }
        }
        return points
    }

    // MARK: Runs and the pauses between them

    /// A stretch of a line's sound with no pause in it, and how it moves.
    struct Run: Equatable {
        /// Which of the line's points lie in it, as places in the list of points.
        var points: Range<Int>
        /// Its sound, in samples from the line's first sample. The pause before it ends where this starts,
        /// and the pause after it starts where this ends.
        var source: Range<Int>
        /// How far its first sample moves, and its last. They are the same for a run that moves as a block.
        var startMove: Int
        var endMove: Int
        /// Whether it goes through the stretcher. If not, it moves as a block.
        var isStretched: Bool
    }

    /// The runs of a line, earliest first. Together with the pauses between them they cover the whole line.
    ///
    /// What a pause is, and how short one may get, is the rule in `SyllablePauses`. A pause first counts
    /// when it is at least 30 ms of sound below the threshold between two neighbouring points. It then has
    /// to take up the difference between the moves of the runs on its two sides. When that would leave less
    /// than 20 ms of it, it does not count after all, the two runs become one, and the question is asked
    /// again for the runs there are now. Pauses only ever stop counting, so this ends.
    static func runs(of line: VoiceLine, points: [ControlPoint], levels: VoiceLevels) -> [Run] {
        let length = line.lengthSamples
        let same = SyllablePauses.sameMoveSamples
        // The pause after each point that has one, in samples from the line's first sample.
        var pauses: [Int: Range<Int>] = [:]
        let found = SyllablePauses.between(points.map { line.startSample + $0.place }, levels: levels)
        for (index, pause) in found.enumerated() {
            guard let pause else { continue }
            pauses[index] = pause.lowerBound - line.startSample..<pause.upperBound - line.startSample
        }

        while true {
            var runs: [Run] = []
            var firstPoint = 0
            var start = 0
            for lastPoint in pauses.keys.sorted() + [points.count - 1] {
                let moves = points[firstPoint...lastPoint].map(\.move)
                let lowest = moves.min() ?? 0
                let highest = moves.max() ?? 0
                let isStretched = highest - lowest > same
                // A block that holds the line's start or end stays with it. Any other block goes to the
                // middle of what its syllables ask for, so none of them is more than a quarter of a
                // millisecond from its place.
                let holdsAnEdge = firstPoint == 0 || lastPoint == points.count - 1
                let block = holdsAnEdge ? 0 : (lowest + highest) / 2
                runs.append(Run(
                    points: firstPoint..<lastPoint + 1,
                    source: start..<(pauses[lastPoint]?.lowerBound ?? length),
                    startMove: isStretched ? points[firstPoint].move : block,
                    endMove: isStretched ? points[lastPoint].move : block,
                    isStretched: isStretched
                ))
                firstPoint = lastPoint + 1
                start = pauses[lastPoint]?.upperBound ?? length
            }
            let tooShort = zip(runs, runs.dropFirst()).first { earlier, later in
                let pause = later.source.lowerBound - earlier.source.upperBound
                return !SyllablePauses.canTake(later.startMove - earlier.endMove, length: pause)
            }
            guard let tooShort else { return runs }
            pauses[tooShort.0.points.upperBound - 1] = nil
        }
    }

    // MARK: A pause that takes up a change

    /// A pause made longer or shorter by `change` samples. It begins and ends with its own samples, so the
    /// sound on either side of it meets what it met before.
    ///
    /// - Shorter: the middle is left out. The first part fades into the last over a crossfade.
    /// - Longer: the pause is opened in the middle, and the gap is filled with its own room sound. From the
    ///   first half the sound is read backwards, away from the gap's start, and from the second half it is
    ///   read forwards, toward the gap's end, so there is no jump at either side of the gap. In the middle of
    ///   the gap the one fades into the other.
    static func resized(_ pause: [Float], by change: Int, fade: Int) -> [Float] {
        let length = max(pause.count + change, 0)
        guard change != 0, !pause.isEmpty else { return pause }
        if change < 0 {
            let overlap = min(max(fade, 0), length / 2)
            // The first part and the last part of the pause that are kept. They share `overlap` samples.
            let head = (length + overlap + 1) / 2
            let skipped = pause.count - length
            return (0..<length).map { index in
                if index < head - overlap { return pause[index] }
                if index >= head { return pause[index + skipped] }
                let weight = (Float(index - (head - overlap)) + 0.5) / Float(overlap)
                return (1 - weight) * pause[index] + weight * pause[index + skipped]
            }
        }
        let half = pause.count / 2
        guard half > 0 else { return pause + [Float](repeating: 0, count: change) }
        let overlap = min(max(fade, 0), change)
        let fadeStart = (change - overlap) / 2
        var result = Array(pause[..<half])
        result.reserveCapacity(length)
        for step in 0..<change {
            let before = pause[half - 1 - mirrored(step, within: half)]
            let after = pause[half + mirrored(change - 1 - step, within: pause.count - half)]
            if step < fadeStart {
                result.append(before)
            } else if step >= fadeStart + overlap {
                result.append(after)
            } else {
                let weight = (Float(step - fadeStart) + 0.5) / Float(overlap)
                result.append((1 - weight) * before + weight * after)
            }
        }
        result += pause[half...]
        return result
    }

    /// Step `step` of a walk over `length` samples that turns around at either end: 0, 1, ..., `length - 1`,
    /// `length - 1`, ..., 1, 0, 0, 1 and so on. Room sound read this way never jumps from one sample to an
    /// unrelated one.
    private static func mirrored(_ step: Int, within length: Int) -> Int {
        let turn = step % (2 * length)
        return turn < length ? turn : 2 * length - 1 - turn
    }
}

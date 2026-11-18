import Testing
@testable import LockstepCore

@Suite("SyllableMoves")
struct SyllableMovesTests {
    /// Beats from 2 s on, evenly spaced. At 0.5 s a beat (120 beats a minute) a sixteenth is 125 ms, and at
    /// 1 s a beat it is 250 ms.
    private func steadyGrid(beat: Double = 0.5, count: Int = 40) -> Grid {
        Grid(beats: (0..<count).map { Beat(number: $0, time: 2 + Double($0) * beat) })
    }

    /// The line's first sample in its recording. Not 0, so a mix-up of recording samples and song time shows.
    private let firstSample = 10_000

    /// A line that sounds from `start` to `end` in the song, with syllables at the given song seconds.
    private func line(from start: Double, to end: Double, markers: [Double]) -> VoiceLine {
        func sample(_ time: Double) -> Int { firstSample + Int(((time - start) * 48_000).rounded()) }
        return VoiceLine(startSample: sample(start), endSample: sample(end), markers: markers.map(sample))
    }

    /// How far each pair of the map moves, in samples.
    private func moves(_ map: TimeMap) -> [Int] {
        map.pairs.map { $0.result - $0.source }
    }

    private func samples(ms: Double) -> Int { Int((ms * 48).rounded()) }

    /// How loud the recording of a line from `line(from:to:markers:)` is, one value for every millisecond:
    /// sound all through, except for quiet between the song seconds given. Each quiet stretch is exactly as
    /// many whole milliseconds long as asked, and starts within a millisecond after the time given.
    private func levels(of line: VoiceLine, from start: Double, quiet: [ClosedRange<Double>]) -> VoiceLevels {
        func hop(_ time: Double) -> Int { (firstSample + Int(((time - start) * 48_000).rounded()) + 47) / 48 }
        var values = [Float](repeating: -20, count: line.endSample / 48 + 1)
        for stretch in quiet {
            for index in hop(stretch.lowerBound)..<hop(stretch.upperBound) { values[index] = -70 }
        }
        return VoiceLevels(values: values, threshold: -58, hopSamples: 48)
    }

    // MARK: Strength

    @Test func strengthZeroGivesTheIdentity() {
        let line = line(from: 2.9, to: 3.6, markers: [3.02, 3.11, 3.27, 3.39])
        let map = SyllableMoves.plan(line: line, songStart: 2.9, grid: steadyGrid(), strength: 0)
        #expect(map.pairs.map(\.source) == [line.startSample] + line.markers + [line.endSample])
        #expect(moves(map) == [0, 0, 0, 0, 0, 0])
        // On a line that has slid, every moment keeps the slide and nothing more.
        let slid = SyllableMoves.plan(line: line, shiftSamples: 480, songStart: 2.9, grid: steadyGrid(), strength: 0)
        #expect(moves(slid) == [480, 480, 480, 480, 480, 480])
    }

    @Test func strengthOnePutsASyllableTwentyMillisecondsOffExactlyOnItsSubBeat() {
        // Sixteenths at 3.0, 3.125, 3.25, 3.375 and 3.5. The second syllable is 20 ms late for 3.125 and the
        // fourth 20 ms early for 3.375. The others are on the beat.
        let line = line(from: 2.9, to: 3.7, markers: [3.0, 3.145, 3.25, 3.355, 3.5])
        let map = SyllableMoves.plan(line: line, songStart: 2.9, grid: steadyGrid(), strength: 1)
        #expect(moves(map) == [0, 0, -960, 0, 960, 0, 0])
        // Where they land is the sub-beat itself, to the sample.
        #expect(map.pairs[2].result == firstSample + samples(ms: 225))
        #expect(map.pairs[4].result == firstSample + samples(ms: 475))
    }

    @Test func halfStrengthGoesHalfTheWay() {
        let line = line(from: 2.9, to: 3.6, markers: [3.0, 3.145, 3.25, 3.375])
        let map = SyllableMoves.plan(line: line, songStart: 2.9, grid: steadyGrid(), strength: 0.5)
        #expect(moves(map) == [0, 0, -480, 0, 0, 0])
    }

    // MARK: Syllables that stay

    @Test func aSyllableSixtyMillisecondsOffAtSixteenthsOfOneTwentyDoesNotMove() {
        // 35 % of 125 ms is 43.75 ms. 60 ms off is meant that way.
        let far = line(from: 2.5, to: 4.0, markers: [3.185])
        #expect(moves(SyllableMoves.plan(line: far, songStart: 2.5, grid: steadyGrid(), strength: 1)) == [0, 0, 0])
        // 40 ms off is not, and moves. With the limit for "meant that way" at 30 % (37.5 ms) it stays too.
        let near = line(from: 2.5, to: 4.0, markers: [3.165])
        #expect(moves(SyllableMoves.plan(line: near, songStart: 2.5, grid: steadyGrid(), strength: 1)) == [0, -1_920, 0])
        let stricter = SyllableMoves.Limits(deliberatePercent: 30)
        #expect(
            moves(SyllableMoves.plan(line: near, songStart: 2.5, grid: steadyGrid(), strength: 1, limits: stricter))
                == [0, 0, 0]
        )
    }

    @Test func nothingMovesWhereTheSongHasNoBeats() {
        let line = line(from: 2.9, to: 3.6, markers: [3.02, 3.145, 3.27])
        #expect(moves(SyllableMoves.plan(line: line, songStart: 2.9, grid: Grid(), strength: 1)) == [0, 0, 0, 0, 0])
        // The same line a second and a half before the first beat.
        #expect(moves(SyllableMoves.plan(line: line, songStart: 0.4, grid: steadyGrid(), strength: 1)) == [0, 0, 0, 0, 0])
    }

    @Test func anExcludedSyllableStaysAndItsNeighbourRespectsTheStretchLimitAroundIt() {
        // Sixteenths are 250 ms apart here, one of them at 3.0. The first syllable is 40 ms early and the
        // second 60 ms late, 100 ms after the first.
        let grid = steadyGrid(beat: 1)
        let line = line(from: 2.5, to: 4.0, markers: [2.96, 3.06])
        // Both free: each is pulled toward 3.0, and together they may take only 20 ms out of the 100.
        let free = SyllableMoves.plan(line: line, songStart: 2.5, grid: grid, strength: 1)
        #expect(moves(free) == [0, 480, -480, 0])
        // The first excluded: it stays, and the second may still take no more than those 20 ms.
        let excluded = SyllableMoves.plan(
            line: line, songStart: 2.5, grid: grid, strength: 1, excluded: [line.markers[0]]
        )
        #expect(moves(excluded) == [0, 0, -960, 0])
        let between = Double(excluded.pairs[2].result - excluded.pairs[1].result)
            / Double(excluded.pairs[2].source - excluded.pairs[1].source)
        #expect(between >= 0.8)
    }

    // MARK: Limits

    @Test func aMoveIsCappedAtFortyMilliseconds() {
        // Sixteenths 250 ms apart: 60 ms off is within reach (the limit for "meant that way" is 87.5 ms).
        let grid = steadyGrid(beat: 1)
        let late = line(from: 2.5, to: 4.0, markers: [3.06])
        #expect(moves(SyllableMoves.plan(line: late, songStart: 2.5, grid: grid, strength: 1)) == [0, -1_920, 0])
        let early = line(from: 2.5, to: 4.0, markers: [2.94])
        #expect(moves(SyllableMoves.plan(line: early, songStart: 2.5, grid: grid, strength: 1)) == [0, 1_920, 0])
        // The setting decides the cap.
        let tighter = SyllableMoves.Limits(maxMoveMs: 15)
        #expect(
            moves(SyllableMoves.plan(line: late, songStart: 2.5, grid: grid, strength: 1, limits: tighter))
                == [0, -720, 0]
        )
        let none = SyllableMoves.Limits(maxMoveMs: 0)
        #expect(
            moves(SyllableMoves.plan(line: late, songStart: 2.5, grid: grid, strength: 1, limits: none)) == [0, 0, 0]
        )
    }

    @Test func twoSyllablesSixtyMillisecondsApartPulledTowardEachOtherStayTwentyApart() {
        // 30 ms either side of the sixteenth at 3.0: at full strength both would land on it.
        let grid = steadyGrid(beat: 1)
        let line = line(from: 2.5, to: 4.0, markers: [2.97, 3.03])
        // With the stretch limit out of the way, the 20 ms between syllables are what stops them.
        let loose = SyllableMoves.Limits(maxStretchPercent: 1_000)
        let map = SyllableMoves.plan(line: line, songStart: 2.5, grid: grid, strength: 1, limits: loose)
        #expect(moves(map) == [0, 960, -960, 0])
        #expect(map.pairs[2].result - map.pairs[1].result == samples(ms: 20))
        // At the usual 25 % the stretch limit stops them sooner: the 60 ms between them become 48.
        let usual = SyllableMoves.plan(line: line, songStart: 2.5, grid: grid, strength: 1)
        let apart = usual.pairs[2].result - usual.pairs[1].result
        #expect(apart >= samples(ms: 48))
        #expect(apart <= samples(ms: 48) + 2)
    }

    @Test func withTheStretchLimitAtZeroNoSyllableMovesInALineWithoutPauses() {
        let line = line(from: 2.9, to: 3.6, markers: [3.0, 3.145, 3.23, 3.375])
        let limits = SyllableMoves.Limits(maxStretchPercent: 0)
        // Not told where the pauses are, the planner takes the line to have none.
        let map = SyllableMoves.plan(line: line, songStart: 2.9, grid: steadyGrid(), strength: 1, limits: limits)
        #expect(moves(map) == [0, 0, 0, 0, 0, 0])
        // Told that the line is sound from end to end, it gives the same answer.
        let noPauses = SyllableMoves.plan(
            line: line, songStart: 2.9, grid: steadyGrid(), strength: 1, limits: limits,
            levels: levels(of: line, from: 2.9, quiet: [])
        )
        #expect(moves(noPauses) == [0, 0, 0, 0, 0, 0])
    }

    // MARK: Pauses

    @Test func withTheStretchLimitAtZeroASyllableAfterAPauseMoves() {
        // Sixteenths at 3.0, 3.125, 3.25 and 3.375. The first syllable is on its sixteenth, and the two
        // after the pause are each 20 ms late. The line is quiet from 3.1 to 3.2 and for its last 100 ms.
        let line = line(from: 2.9, to: 3.7, markers: [3.0, 3.27, 3.395])
        let limits = SyllableMoves.Limits(maxStretchPercent: 0)
        let map = SyllableMoves.plan(
            line: line, songStart: 2.9, grid: steadyGrid(), strength: 1, limits: limits,
            levels: levels(of: line, from: 2.9, quiet: [3.1...3.2, 3.6...3.7])
        )
        // Both go all the way, by the same amount: the pause before them gets 20 ms shorter and the one
        // after them 20 ms longer.
        #expect(moves(map) == [0, 0, -960, -960, 0])
        // Without the quiet at the line's end they run together with the line's end, which never moves.
        let held = SyllableMoves.plan(
            line: line, songStart: 2.9, grid: steadyGrid(), strength: 1, limits: limits,
            levels: levels(of: line, from: 2.9, quiet: [3.1...3.2])
        )
        #expect(moves(held) == [0, 0, 0, 0, 0])
    }

    @Test func twoSyllablesThatRunTogetherGetOneCommonMoveAtLimitZero() {
        let limits = SyllableMoves.Limits(maxStretchPercent: 0)
        func planned(_ line: VoiceLine, excluded: Set<Int> = []) -> [Int] {
            moves(SyllableMoves.plan(
                line: line, songStart: 2.9, grid: steadyGrid(), strength: 1, excluded: excluded, limits: limits,
                levels: levels(of: line, from: 2.9, quiet: [3.1...3.2, 3.6...3.7])
            ))
        }
        // After the pause, one syllable is 20 ms late and the next 10 ms late. Nothing may be stretched, so
        // both get the smaller move: neither goes further than it asked, and neither past its sixteenth.
        let sameWay = line(from: 2.9, to: 3.7, markers: [3.0, 3.27, 3.385])
        #expect(planned(sameWay) == [0, 0, -480, -480, 0])
        // One 20 ms late and the next 10 ms early: no common move is right for both, so both stay.
        let apart = line(from: 2.9, to: 3.7, markers: [3.0, 3.27, 3.365])
        #expect(planned(apart) == [0, 0, 0, 0, 0])
        // A syllable Max excluded stays, and so does the one it runs together with.
        #expect(planned(sameWay, excluded: [sameWay.markers[2]]) == [0, 0, 0, 0, 0])
    }

    @Test func besideAPauseASyllableIsHeldBackByThePauseAndNotByTheStretchLimit() {
        // A beat every 0.4 s, so sixteenths at 3.0 and 3.1. The first syllable is on 3.0 and the second is
        // 30 ms late, 130 ms after the first.
        let grid = steadyGrid(beat: 0.4)
        let late = line(from: 2.9, to: 3.6, markers: [3.0, 3.13])
        // Run together, they may come 20 % closer at the usual limit of 25 %: 26 ms.
        let together = SyllableMoves.plan(line: late, songStart: 2.9, grid: grid, strength: 1)
        #expect(moves(together) == [0, 0, -1_248, 0])
        // With a pause of 60 ms between them the second goes its whole 30 ms, and the pause is 30 ms long.
        let paused = SyllableMoves.plan(
            line: late, songStart: 2.9, grid: grid, strength: 1,
            levels: levels(of: late, from: 2.9, quiet: [3.04...3.1])
        )
        #expect(moves(paused) == [0, 0, -1_440, 0])
        // A pause of 40 ms can give 19 ms and keep 21, so that is how far the second goes.
        let short = SyllableMoves.plan(
            line: late, songStart: 2.9, grid: grid, strength: 1,
            levels: levels(of: late, from: 2.9, quiet: [3.05...3.09])
        )
        #expect(moves(short) == [0, 0, -912, 0])
        // Quiet for 25 ms is no pause: the stretch limit holds as if the two ran together.
        let tooShort = SyllableMoves.plan(
            line: late, songStart: 2.9, grid: grid, strength: 1,
            levels: levels(of: late, from: 2.9, quiet: [3.05...3.075])
        )
        #expect(moves(tooShort) == [0, 0, -1_248, 0])

        // A pause can grow as far as it has to. The second syllable is 30 ms early for 3.1, 70 ms after the
        // first. Run together, the 70 ms may grow by a quarter, 17.5 ms. With a pause of 40 ms between them
        // it goes its whole 30 ms.
        let early = line(from: 2.9, to: 3.6, markers: [3.0, 3.07])
        #expect(moves(SyllableMoves.plan(line: early, songStart: 2.9, grid: grid, strength: 1)) == [0, 0, 840, 0])
        let grown = SyllableMoves.plan(
            line: early, songStart: 2.9, grid: grid, strength: 1,
            levels: levels(of: early, from: 2.9, quiet: [3.02...3.06])
        )
        #expect(moves(grown) == [0, 0, 1_440, 0])
    }

    @Test func syllablesGoingTheSameWayAreCutBackOnlyAsFarAsNeeded() {
        // A beat every 0.4 s, so sixteenths at 3.0 and 3.1. The first syllable is 30 ms late for 3.0 and the
        // second 10 ms late for 3.1, so they are 80 ms apart and ask to come 20 ms further apart. At a limit
        // of 10 % the 80 ms may grow by 8.
        let grid = steadyGrid(beat: 0.4)
        let line = line(from: 2.5, to: 3.6, markers: [3.03, 3.11])
        let limits = SyllableMoves.Limits(maxStretchPercent: 10)
        let map = SyllableMoves.plan(line: line, songStart: 2.5, grid: grid, strength: 1, limits: limits)
        // The one that goes less far gets all it asked for. The other is cut back to 8 ms more than that.
        #expect(moves(map) == [0, -864, -480, 0])
    }

    @Test func theLineStartAndEndNeverMove() {
        // The first syllable is 30 ms into the line and 30 ms late, the last is 40 ms before the line's end
        // and 30 ms early. Each can go only as far as the sound between it and the edge may be stretched.
        let line = line(from: 3.0, to: 3.385, markers: [3.03, 3.125, 3.25, 3.345])
        let map = SyllableMoves.plan(line: line, songStart: 3.0, grid: steadyGrid(), strength: 1)
        #expect(map.pairs.first == TimeMap.Pair(source: line.startSample, result: line.startSample))
        #expect(map.pairs.last == TimeMap.Pair(source: line.endSample, result: line.endSample))
        #expect(moves(map)[1] < 0)
        #expect(moves(map)[1] >= -samples(ms: 6))        // 30 ms may shrink to 24
        #expect(moves(map)[4] > 0)
        #expect(moves(map)[4] <= samples(ms: 8))         // 40 ms may shrink to 32

        // After a slide of the line, both edges have moved by the slide and nothing else.
        let slid = SyllableMoves.plan(line: line, shiftSamples: -300, songStart: 3.0, grid: steadyGrid(), strength: 1)
        #expect(slid.pairs.first == TimeMap.Pair(source: line.startSample, result: line.startSample - 300))
        #expect(slid.pairs.last == TimeMap.Pair(source: line.endSample, result: line.endSample - 300))
        #expect(slid.shiftSamples == -300)
    }

    // MARK: What is measured

    @Test func syllablesAreMeasuredWhereTheLineSitsAfterItsSlide() {
        // Every syllable 20 ms late as recorded. Tighten lines has slid the line 20 ms earlier, so they are
        // on the beat already and get nothing more.
        let line = line(from: 2.9, to: 3.6, markers: [3.02, 3.145, 3.27, 3.395])
        let map = SyllableMoves.plan(line: line, shiftSamples: -960, songStart: 2.9, grid: steadyGrid(), strength: 1)
        #expect(moves(map) == [-960, -960, -960, -960, -960, -960])
        // A slide of 10 ms leaves each 10 ms late: the syllables go the rest of the way themselves.
        let half = SyllableMoves.plan(line: line, shiftSamples: -480, songStart: 2.9, grid: steadyGrid(), strength: 1)
        #expect(moves(half) == [-480, -960, -960, -960, -960, -480])
    }

    @Test func theSubBeatsPerBeatDecideWhereASyllableGoes() {
        // 10 ms after the first third of a beat. For triplets that third is a sub-beat. For sixteenths the
        // nearest sub-beat is 51.7 ms away, which is meant that way.
        let line = line(from: 2.5, to: 4.0, markers: [3 + 0.5 / 3 + 0.010])
        let triplets = SyllableMoves.plan(line: line, songStart: 2.5, grid: steadyGrid(), perBeat: 6, strength: 1)
        #expect(abs(moves(triplets)[1] + 480) <= 1)
        let sixteenths = SyllableMoves.plan(line: line, songStart: 2.5, grid: steadyGrid(), perBeat: 4, strength: 1)
        #expect(moves(sixteenths) == [0, 0, 0])
    }

    @Test func aMarkerOnTheLinesFirstSampleGetsNoPairOfItsOwn() {
        var line = line(from: 2.9, to: 3.6, markers: [3.145, 3.25])
        line.markers = [line.startSample, line.markers[0], line.markers[0], line.markers[1]]
        let map = SyllableMoves.plan(line: line, songStart: 2.9, grid: steadyGrid(), strength: 1)
        #expect(map.pairs.map(\.source) == [line.startSample, line.markers[1], line.markers[3], line.endSample])
        // A line with no sound in it gives the plain map of a line that only slides.
        let empty = VoiceLine(startSample: 500, endSample: 500)
        #expect(
            SyllableMoves.plan(line: empty, shiftSamples: 7, songStart: 3, grid: steadyGrid(), strength: 1)
                == TimeMap(line: empty, shiftSamples: 7)
        )
    }

    // MARK: Every result

    /// The same made-up numbers on every run.
    private struct Numbers: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    @Test func everyResultKeepsEveryPromise() {
        var numbers = Numbers(state: 20)
        var moved = 0
        var heldBack = 0
        for _ in 0..<600 {
            // A made-up line: up to fourteen syllables, 25 to 400 ms apart, somewhere among the beats.
            let grid = steadyGrid(beat: Double.random(in: 0.35...1.2, using: &numbers), count: 60)
            let songStart = Double.random(in: 3...8, using: &numbers)
            var position = firstSample
            var markers: [Int] = []
            for _ in 0..<Int.random(in: 1...14, using: &numbers) {
                position += Int.random(in: 1_200...19_200, using: &numbers)
                markers.append(position)
            }
            let line = VoiceLine(
                startSample: firstSample,
                endSample: position + Int.random(in: 1_200...19_200, using: &numbers),
                markers: markers
            )
            let shift = Int.random(in: -3_840...3_840, using: &numbers)
            let strength = Double.random(in: 0...1, using: &numbers)
            let excluded = Set(markers.filter { _ in Int.random(in: 0..<5, using: &numbers) == 0 })
            let limits = SyllableMoves.Limits(
                deliberatePercent: [20, 35, 50].randomElement(using: &numbers)!,
                maxMoveMs: [0, 20, 40, 80].randomElement(using: &numbers)!,
                maxStretchPercent: [0, 10, 25, 40].randomElement(using: &numbers)!
            )
            let perBeat = [4, 6].randomElement(using: &numbers)!

            let map = SyllableMoves.plan(
                line: line, shiftSamples: shift, songStart: songStart, grid: grid, perBeat: perBeat,
                strength: strength, excluded: excluded, limits: limits
            )

            // One pair for the start, each syllable and the end, in order, and the edges only slide.
            #expect(map.pairs.map(\.source) == [line.startSample] + markers + [line.endSample])
            #expect(map.pairs.first?.result == line.startSample + shift)
            #expect(map.pairs.last?.result == line.endSample + shift)

            let most = 1 + limits.maxStretchPercent / 100
            for (earlier, later) in zip(map.pairs, map.pairs.dropFirst()) {
                let before = later.source - earlier.source
                let after = later.result - earlier.result
                // Nothing crosses, nothing is stretched or squeezed too much, and 20 ms are kept.
                #expect(after > 0)
                #expect(Double(after) <= Double(before) * most + 1e-6)
                #expect(Double(after) >= Double(before) / most - 1e-6)
                #expect(after >= min(before, 960))
            }

            for (index, marker) in markers.enumerated() {
                let own = map.pairs[index + 1].result - marker - shift
                let asked = SyllableMoves.wantedMove(
                    at: songStart + Double(marker - line.startSample + shift) / 48_000,
                    grid: grid, perBeat: perBeat, strength: strength, limits: limits
                )
                // Never further than the syllable limit, never more than asked, never the other way.
                #expect(abs(own) <= samples(ms: limits.maxMoveMs))
                #expect(abs(own) <= abs(asked))
                #expect(own == 0 || (own > 0) == (asked > 0))
                if excluded.contains(marker) { #expect(own == 0) }
                if own != 0 { moved += 1 }
                if !excluded.contains(marker), own != asked { heldBack += 1 }
            }
        }
        // The made-up lines really did exercise both parts: syllables that moved, and moves that were cut back.
        #expect(moved > 500)
        #expect(heldBack > 200)
    }

    @Test func everyResultKeepsEveryPromiseWhenTheLineHasPauses() {
        var numbers = Numbers(state: 21)
        var moved = 0
        var heldBack = 0
        var freed = 0
        var movedAtLimitZero = 0
        for _ in 0..<600 {
            // A made-up line as above, sound all through, with a quiet stretch of 5 to 90 ms between some of
            // its neighbouring points. Only those of 30 ms or more are pauses.
            let grid = steadyGrid(beat: Double.random(in: 0.35...1.2, using: &numbers), count: 60)
            let songStart = Double.random(in: 3...8, using: &numbers)
            var position = firstSample
            var markers: [Int] = []
            for _ in 0..<Int.random(in: 1...14, using: &numbers) {
                position += Int.random(in: 1_200...19_200, using: &numbers)
                markers.append(position)
            }
            let line = VoiceLine(
                startSample: firstSample,
                endSample: position + Int.random(in: 1_200...19_200, using: &numbers),
                markers: markers
            )
            let points = [line.startSample] + markers + [line.endSample]
            var values = [Float](repeating: -20, count: line.endSample / 48 + 1)
            var pauses: [Int?] = []
            for (earlier, later) in zip(points, points.dropFirst()) {
                // The quiet lies whole milliseconds of the recording strictly between the two points.
                let first = (earlier + 47) / 48 + 1
                let room = later / 48 - 1 - first
                guard room >= 5, Int.random(in: 0..<3, using: &numbers) > 0 else {
                    pauses.append(nil)
                    continue
                }
                let length = Int.random(in: 5...min(90, room), using: &numbers)
                let from = first + Int.random(in: 0...room - length, using: &numbers)
                for index in from..<from + length { values[index] = -70 }
                pauses.append(length >= 30 ? length * 48 : nil)
            }
            let levels = VoiceLevels(values: values, threshold: -58, hopSamples: 48)
            // What the test knows of the pauses is what the shared rule finds.
            #expect(SyllablePauses.lengths(between: points, levels: levels) == pauses)

            let shift = Int.random(in: -3_840...3_840, using: &numbers)
            let strength = Double.random(in: 0...1, using: &numbers)
            let excluded = Set(markers.filter { _ in Int.random(in: 0..<5, using: &numbers) == 0 })
            let limits = SyllableMoves.Limits(
                deliberatePercent: [20, 35, 50].randomElement(using: &numbers)!,
                maxMoveMs: [0, 20, 40, 80].randomElement(using: &numbers)!,
                maxStretchPercent: [0, 0, 10, 25, 40].randomElement(using: &numbers)!
            )
            let perBeat = [4, 6].randomElement(using: &numbers)!

            let map = SyllableMoves.plan(
                line: line, shiftSamples: shift, songStart: songStart, grid: grid, perBeat: perBeat,
                strength: strength, excluded: excluded, limits: limits, levels: levels
            )

            #expect(map.pairs.map(\.source) == points)
            #expect(map.pairs.first?.result == line.startSample + shift)
            #expect(map.pairs.last?.result == line.endSample + shift)

            let most = 1 + limits.maxStretchPercent / 100
            for (index, (earlier, later)) in zip(map.pairs, map.pairs.dropFirst()).enumerated() {
                let before = later.source - earlier.source
                let after = later.result - earlier.result
                #expect(after > 0)
                if let pause = pauses[index] {
                    // The pause takes the whole change, and 21 ms of it are left.
                    #expect(pause + after - before >= 1_008)
                    if Double(after) > Double(before) * most || Double(after) < Double(before) / most { freed += 1 }
                } else {
                    // Nothing is stretched or squeezed too much, and 20 ms are kept.
                    #expect(Double(after) <= Double(before) * most + 1e-6)
                    #expect(Double(after) >= Double(before) / most - 1e-6)
                    #expect(after >= min(before, 960))
                }
            }

            for (index, marker) in markers.enumerated() {
                let own = map.pairs[index + 1].result - marker - shift
                let asked = SyllableMoves.wantedMove(
                    at: songStart + Double(marker - line.startSample + shift) / 48_000,
                    grid: grid, perBeat: perBeat, strength: strength, limits: limits
                )
                // Never further than the syllable limit, never more than asked, never the other way.
                #expect(abs(own) <= samples(ms: limits.maxMoveMs))
                #expect(abs(own) <= abs(asked))
                #expect(own == 0 || (own > 0) == (asked > 0))
                if excluded.contains(marker) { #expect(own == 0) }
                if own != 0 { moved += 1 }
                if own != 0, limits.maxStretchPercent == 0 { movedAtLimitZero += 1 }
                if !excluded.contains(marker), own != asked { heldBack += 1 }
            }
        }
        // The made-up lines really did exercise every part: syllables that moved, moves that were cut back,
        // pauses that took more than the stretch limit would have allowed, and moves with the limit at 0.
        #expect(moved > 500)
        #expect(heldBack > 200)
        #expect(freed > 50)
        #expect(movedAtLimitZero > 50)
    }
}

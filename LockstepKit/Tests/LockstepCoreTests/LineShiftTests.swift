import Testing
@testable import LockstepCore

@Suite("LineShift")
struct LineShiftTests {
    /// Beats from 2 s on, evenly spaced. At 0.5 s a beat (120 beats a minute) a sixteenth is 125 ms.
    private func steadyGrid(beat: Double = 0.5, count: Int = 40) -> Grid {
        Grid(beats: (0..<count).map { Beat(number: $0, time: 2 + Double($0) * beat) })
    }

    /// Sixteenths of the steady grid, from its third beat on: 3.0, 3.125, 3.25 and so on at 120 beats a minute.
    private func sixteenths(_ count: Int, beat: Double = 0.5) -> [Double] {
        (0..<count).map { 2 + 2 * beat + Double($0) * beat / 4 }
    }

    private func milliseconds(_ seconds: Double) -> Double { seconds * 1_000 }

    // MARK: The slide that is heard: the first syllable to its nearest sub-beat

    @Test func theFirstSyllableDecidesHowFarALineSlides() {
        // The first syllable is 40 ms late and the five after it are 10 ms early. The best fit of all six
        // would slide the line about 10 ms later. The first syllable alone says 40 ms earlier.
        var times = sixteenths(6).map { $0 - 0.010 }
        times[0] = sixteenths(1)[0] + 0.040
        let slide = LineShift.toFirstSyllable(markerTimes: times, grid: steadyGrid())
        #expect(abs(milliseconds(slide) + 40) < 1e-6)
        // After the slide the first syllable stands on its sixteenth.
        #expect(abs(times[0] + slide - 3.0) < 1e-9)
    }

    @Test func anEarlyFirstSyllableSlidesTheLineLater() {
        let times = sixteenths(4).map { $0 - 0.025 }
        #expect(abs(milliseconds(LineShift.toFirstSyllable(markerTimes: times, grid: steadyGrid())) - 25) < 1e-6)
    }

    @Test func theFirstSyllableGoesToTheNearestSubBeatOfTheClipsOwnGrid() {
        // 50 ms after a beat: the sixteenth at 125 ms is further away than the beat, so the line slides 50 ms
        // earlier. In triplets (six to the beat) the sub-beat at 83.3 ms is the nearest, 33.3 ms later.
        let grid = steadyGrid()
        #expect(abs(milliseconds(LineShift.toFirstSyllable(markerTimes: [3.050, 3.3], grid: grid, perBeat: 4)) + 50) < 1e-6)
        #expect(abs(milliseconds(LineShift.toFirstSyllable(markerTimes: [3.050, 3.3], grid: grid, perBeat: 6)) - 33.333) < 1e-2)
    }

    @Test func anExcludedFirstSyllableDoesNotCountAsTheFirst() {
        // Whoever asks leaves out the syllables Max excluded. With the first one left out, the second is the
        // first: 12 ms late, where the excluded one was 40 ms late.
        let all = [3.040, 3.137, 3.25, 3.375]
        #expect(abs(milliseconds(LineShift.toFirstSyllable(markerTimes: all, grid: steadyGrid())) + 40) < 1e-6)
        let counted = Array(all.dropFirst())
        #expect(abs(milliseconds(LineShift.toFirstSyllable(markerTimes: counted, grid: steadyGrid())) + 12) < 1e-6)
        // The earliest syllable is the first, in whatever order they are handed in.
        #expect(LineShift.toFirstSyllable(markerTimes: counted.reversed(), grid: steadyGrid())
            == LineShift.toFirstSyllable(markerTimes: counted, grid: steadyGrid()))
    }

    @Test func aLineWithOneSyllableSlidesByIt() {
        #expect(abs(milliseconds(LineShift.toFirstSyllable(markerTimes: [4.030], grid: steadyGrid())) + 30) < 1e-6)
    }

    @Test func aLineWithoutSyllablesOrWithoutBeatsDoesNotSlide() {
        let grid = steadyGrid()
        // No syllables.
        #expect(LineShift.toFirstSyllable(markerTimes: [], grid: grid) == 0)
        // A first syllable where the song has no beats: before the first beat, and a song with no beats at all.
        #expect(LineShift.toFirstSyllable(markerTimes: [0.53, 0.66, 0.78], grid: grid) == 0)
        #expect(LineShift.toFirstSyllable(markerTimes: sixteenths(4).map { $0 + 0.030 }, grid: Grid()) == 0)
    }

    @Test func aFirstSyllableOnItsSubBeatLeavesTheLineWhereItIs() {
        // The others are off, and the line still stays: only the first one is asked.
        var times = sixteenths(5).map { $0 + 0.030 }
        times[0] = sixteenths(1)[0]
        #expect(LineShift.toFirstSyllable(markerTimes: times, grid: steadyGrid()) == 0)
    }

    // MARK: The best fit, which the song's Auto choice judges a clip with

    @Test func markersAllThirtyMillisecondsLateSlideThirtyEarlier() {
        let shift = LineShift.best(markerTimes: sixteenths(6).map { $0 + 0.030 }, grid: steadyGrid())
        #expect(abs(milliseconds(shift) + 30) <= 1)
    }

    @Test func markersOnTheGridDoNotMove() {
        #expect(LineShift.best(markerTimes: sixteenths(6), grid: steadyGrid()) == 0)
    }

    @Test func aStraySyllableDoesNotDragTheLine() {
        // Five syllables 20 ms early and one 60 ms late. The mean of the six would ask for 7 ms later, and
        // the stray alone for 60 ms earlier. The five that agree decide.
        var times = sixteenths(6).map { $0 - 0.020 }
        times[3] += 0.080
        let shift = LineShift.best(markerTimes: times, grid: steadyGrid())
        #expect(abs(milliseconds(shift) - 20) <= 1)
    }

    @Test func aLineFarOffSlidesNoFurtherThanTheLimit() {
        // A slow song, 375 ms between sixteenths, and a line 150 ms late: the limit of 80 ms is all it gets.
        let grid = steadyGrid(beat: 1.5)
        let times = sixteenths(4, beat: 1.5).map { $0 + 0.150 }
        let shift = LineShift.best(markerTimes: times, grid: grid, maxShiftMs: 80)
        #expect(milliseconds(shift) >= -80)
        #expect(milliseconds(shift) <= -79)
        // A tighter limit holds it back further.
        let tighter = LineShift.best(markerTimes: times, grid: grid, maxShiftMs: 45)
        #expect(milliseconds(tighter) >= -45)
        #expect(milliseconds(tighter) <= -44)
    }

    @Test func withTheLimitAtZeroNothingShifts() {
        let times = sixteenths(6).map { $0 + 0.030 }
        #expect(LineShift.best(markerTimes: times, grid: steadyGrid(), maxShiftMs: 0) == 0)
    }

    @Test func aLineAlreadyNearlyInPlaceDoesNotMove() {
        // Syllables scattered a few milliseconds either side of the beat, a little more of them late. Sliding
        // one millisecond earlier would fit a third of a millisecond better, which is not worth a slide.
        let offsets = [0.004, 0.003, 0.005, 0.001, -0.004, -0.005]
        let times = zip(sixteenths(6), offsets).map { $0 + $1 }
        #expect(LineShift.best(markerTimes: times, grid: steadyGrid()) == 0)
    }

    @Test func earlyLinesSlideLater() {
        let shift = LineShift.best(markerTimes: sixteenths(5).map { $0 - 0.042 }, grid: steadyGrid())
        #expect(abs(milliseconds(shift) - 42) <= 1)
    }

    @Test func tooLittleToGoByGivesNoShift() {
        let grid = steadyGrid()
        // No syllables, and one syllable.
        #expect(LineShift.best(markerTimes: [], grid: grid) == 0)
        #expect(LineShift.best(markerTimes: [4.030], grid: grid) == 0)
        // A stretch of the song with no beats: before the first beat, and a song with no beats at all.
        #expect(LineShift.best(markerTimes: [0.53, 0.66, 0.78, 0.91], grid: grid) == 0)
        #expect(LineShift.best(markerTimes: sixteenths(6).map { $0 + 0.030 }, grid: Grid()) == 0)
    }

    @Test func theSubBeatsPerBeatDecideWhatOnTheBeatMeans() {
        // A syllable a third of the way into each of four beats: on the beat for triplets (six to the beat),
        // and 41.7 ms after the sixteenth at 125 ms.
        let times = (0..<4).map { 3 + Double($0) * 0.5 + 0.5 / 3 }
        #expect(LineShift.best(markerTimes: times, grid: steadyGrid(), perBeat: 6) == 0)
        let asSixteenths = LineShift.best(markerTimes: times, grid: steadyGrid(), perBeat: 4, deliberatePercent: 50)
        #expect(abs(milliseconds(asSixteenths) + 41.7) <= 1)
    }
}

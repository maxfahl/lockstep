import Testing
@testable import LockstepCore

@Suite("MarkerDistance")
struct MarkerDistanceTests {
    /// 120 beats a minute from 2 s on: a beat every 0.5 s, a sub-beat every 125 ms.
    private func steadyGrid(_ count: Int = 40) -> Grid {
        Grid(beats: (0..<count).map { Beat(number: $0, time: 2 + Double($0) * 0.5) })
    }

    /// Beats 0 to 9, an empty gap, then beats 20 to 29, all half a second apart.
    private func gridWithAGap() -> Grid {
        let numbers = Array(0..<10) + Array(20..<30)
        return Grid(beats: numbers.map { Beat(number: $0, time: 2 + Double($0) * 0.5) })
    }

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    /// The class of a moment of the song, or nil where there is nothing to measure against.
    private func classOf(_ time: Double, in grid: Grid, deliberatePercent: Double = 35) -> MarkerClass? {
        MarkerDistance.nearestSubBeat(to: time, grid: grid).map {
            MarkerDistance.classify(
                offset: time - $0.subBeatTime, spacing: $0.spacing, deliberatePercent: deliberatePercent
            )
        }
    }

    @Test func tenThirtyAndFiftyMillisecondsLateAreTheThreeClasses() throws {
        let grid = steadyGrid()
        // The sub-beat at 3.125 s, the first sixteenth after the beat at 3 s.
        let subBeat = 3.125
        for late in [0.010, 0.030, 0.050] {
            let nearest = try #require(MarkerDistance.nearestSubBeat(to: subBeat + late, grid: grid))
            #expect(near(nearest.subBeatTime, subBeat))
            #expect(near(nearest.spacing, 0.125))
        }
        #expect(classOf(subBeat + 0.010, in: grid) == .onBeat)
        #expect(classOf(subBeat + 0.030, in: grid) == .slightlyOff)
        #expect(classOf(subBeat + 0.050, in: grid) == .deliberate)
        // The same distances early.
        #expect(classOf(subBeat - 0.010, in: grid) == .onBeat)
        #expect(classOf(subBeat - 0.030, in: grid) == .slightlyOff)
        #expect(classOf(subBeat - 0.050, in: grid) == .deliberate)
        // A stricter setting makes 30 ms count as meant.
        #expect(classOf(subBeat + 0.030, in: grid, deliberatePercent: 20) == .deliberate)
    }

    @Test func theLimitsAreSharesOfTheSpacing() {
        // 10 % and 35 % of 125 ms are 12.5 ms and 43.75 ms.
        #expect(MarkerDistance.classify(offset: 0.012, spacing: 0.125) == .onBeat)
        #expect(MarkerDistance.classify(offset: -0.013, spacing: 0.125) == .slightlyOff)
        #expect(MarkerDistance.classify(offset: 0.043, spacing: 0.125) == .slightlyOff)
        #expect(MarkerDistance.classify(offset: -0.045, spacing: 0.125) == .deliberate)
        // At half the tempo the limits are twice as far out: 25 ms and 87.5 ms.
        #expect(MarkerDistance.classify(offset: 0.024, spacing: 0.25) == .onBeat)
        #expect(MarkerDistance.classify(offset: 0.050, spacing: 0.25) == .slightlyOff)
        #expect(MarkerDistance.classify(offset: 0.090, spacing: 0.25) == .deliberate)
    }

    @Test func halfwayPicksEitherSubBeatWithTheRightSign() throws {
        let time = 3.1875
        let nearest = try #require(MarkerDistance.nearestSubBeat(to: time, grid: steadyGrid()))
        let offset = time - nearest.subBeatTime
        if offset > 0 {
            #expect(near(nearest.subBeatTime, 3.125))
            #expect(near(offset, 0.0625))
        } else {
            #expect(near(nearest.subBeatTime, 3.25))
            #expect(near(offset, -0.0625))
        }
    }

    @Test func aBeatItselfIsASubBeat() throws {
        let grid = steadyGrid()
        // Just before a beat the nearest sub-beat is that beat, at exactly its time.
        let early = try #require(MarkerDistance.nearestSubBeat(to: 3.49, grid: grid))
        #expect(early.subBeatTime == 3.5)
        let late = try #require(MarkerDistance.nearestSubBeat(to: 3.51, grid: grid))
        #expect(late.subBeatTime == 3.5)
        let on = try #require(MarkerDistance.nearestSubBeat(to: 3.5, grid: grid))
        #expect(on.subBeatTime == 3.5)
    }

    @Test func thereIsNothingToMeasureAgainstWhereThereAreNoBeats() throws {
        let grid = gridWithAGap()
        // Inside the gap, between beat 9 at 6.5 s and beat 20 at 12 s.
        #expect(MarkerDistance.nearestSubBeat(to: 9, grid: grid) == nil)
        #expect(MarkerDistance.nearestSubBeat(to: 6.6, grid: grid) == nil)
        #expect(MarkerDistance.nearestSubBeat(to: 11.9, grid: grid) == nil)
        // Before the first beat and after the last.
        #expect(MarkerDistance.nearestSubBeat(to: 1.9, grid: grid) == nil)
        #expect(MarkerDistance.nearestSubBeat(to: 16.6, grid: grid) == nil)
        #expect(MarkerDistance.nearestSubBeat(to: 1, grid: Grid()) == nil)
        #expect(MarkerDistance.nearestSubBeat(to: 1, grid: Grid(beats: [Beat(number: 0, time: 1)])) == nil)

        // Less than half a sub-beat outside an edge still belongs to the beat at the edge.
        let afterTheEdge = try #require(MarkerDistance.nearestSubBeat(to: 6.52, grid: grid))
        #expect(afterTheEdge.subBeatTime == 6.5)
        #expect(near(afterTheEdge.spacing, 0.125))
        let beforeTheEdge = try #require(MarkerDistance.nearestSubBeat(to: 11.97, grid: grid))
        #expect(beforeTheEdge.subBeatTime == 12)
        #expect(near(beforeTheEdge.spacing, 0.125))
        #expect(MarkerDistance.nearestSubBeat(to: 1.98, grid: grid)?.subBeatTime == 2)
        #expect(MarkerDistance.nearestSubBeat(to: 16.53, grid: grid)?.subBeatTime == 16.5)
    }

    @Test func driftingTempoUsesTheSpacingWhereTheMarkerIs() throws {
        let grid = Grid(beats: [0, 0.5, 1.1, 1.76].enumerated().map { Beat(number: $0.offset, time: $0.element) })
        // Between the beats at 0.5 and 1.1 a sub-beat is 150 ms: 0.5, 0.65, 0.8, 0.95, 1.1.
        let slow = try #require(MarkerDistance.nearestSubBeat(to: 0.7, grid: grid))
        #expect(near(slow.subBeatTime, 0.65))
        #expect(near(slow.spacing, 0.15))
        // Just before the beat at 1.1 the spacing is still that of the stretch before it.
        let beforeBeat = try #require(MarkerDistance.nearestSubBeat(to: 1.08, grid: grid))
        #expect(beforeBeat.subBeatTime == 1.1)
        #expect(near(beforeBeat.spacing, 0.15))
        // Just after it, the spacing is that of the slower stretch that follows: 165 ms.
        let afterBeat = try #require(MarkerDistance.nearestSubBeat(to: 1.12, grid: grid))
        #expect(afterBeat.subBeatTime == 1.1)
        #expect(near(afterBeat.spacing, 0.165))
        // 50 ms late counts as meant in the first stretch, where a sub-beat is 125 ms, and
        // as slightly off in the last, where a sub-beat is 165 ms.
        #expect(classOf(0.125 + 0.050, in: grid) == .deliberate)
        #expect(classOf(1.1 + 0.165 + 0.050, in: grid) == .slightlyOff)
    }

    @Test func tripletsDivideTheBeatInSix() throws {
        let time = 3 + 0.5 / 6 + 0.01
        let nearest = try #require(MarkerDistance.nearestSubBeat(to: time, grid: steadyGrid(), perBeat: 6))
        #expect(near(nearest.subBeatTime, 3 + 0.5 / 6))
        #expect(near(nearest.spacing, 0.5 / 6))
    }

    @Test func theReadoutGivesMillisecondsAndEarlyOrLate() {
        #expect(MarkerDistance.readout(offset: 0.023) == "23 ms late")
        #expect(MarkerDistance.readout(offset: -0.008) == "8 ms early")
        #expect(MarkerDistance.readout(offset: 0.0004) == "on the beat")
        #expect(MarkerDistance.readout(offset: -0.0009) == "on the beat")
        #expect(MarkerDistance.readout(offset: 0) == "on the beat")
        #expect(MarkerDistance.readout(offset: 0.001) == "1 ms late")
        #expect(MarkerDistance.readout(offset: -0.0626) == "63 ms early")
    }
}

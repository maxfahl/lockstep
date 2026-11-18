import Testing
@testable import LockstepCore

@Suite("GridBeats")
struct GridBeatsTests {
    /// A grid with one beat every `period` seconds, numbered from 0.
    func steadyGrid(_ count: Int, period: Double = 0.5, from start: Double = 2, barStartNumber: Int = 0) -> Grid {
        Grid(
            beats: (0..<count).map { Beat(number: $0, time: start + Double($0) * period, estimated: false) },
            barStartNumber: barStartNumber
        )
    }

    /// Beats 0 to 9, an empty gap, then beats 20 to 29, all half a second apart.
    func gridWithAGap() -> Grid {
        let numbers = Array(0..<10) + Array(20..<30)
        return Grid(beats: numbers.map { Beat(number: $0, time: 2 + Double($0) * 0.5, estimated: false) })
    }

    // MARK: - Tempo

    @Test func aGridAtExactly120BPMReports120() {
        let grid = steadyGrid(40)
        for seconds in [2.0, 2.1, 2.25, 7.3, 21.5] {
            #expect(grid.tempo(at: seconds) == 120.0)
        }
    }

    @Test func tempoIsTheMeanOfTheTwoSpacingsAroundTheNearestBeat() {
        let grid = Grid(beats: [0, 0.5, 1.1, 1.76].enumerated().map { Beat(number: $0.offset, time: $0.element) })
        // Around the beat at 0.5 the spacings are 0.5 and 0.6: 60 / 0.55.
        #expect(grid.tempo(at: 0.5) == 109.1)
        #expect(grid.tempo(at: 0.7) == 109.1)
        // Around the beat at 1.1 they are 0.6 and 0.66: 60 / 0.63.
        #expect(grid.tempo(at: 0.9) == 95.2)
        // The first and the last beat have one spacing only.
        #expect(grid.tempo(at: 0) == 120.0)
        #expect(grid.tempo(at: 1.76) == 90.9)
    }

    @Test func thereIsNoTempoWhereThereAreNoBeats() {
        let grid = gridWithAGap()
        #expect(grid.tempo(at: 1.99) == nil)
        #expect(grid.tempo(at: 16.51) == nil)
        // Inside the gap, between beat 9 at 6.5 s and beat 20 at 12 s.
        #expect(grid.tempo(at: 9) == nil)
        // On the beats at the gap's edges there is one.
        #expect(grid.tempo(at: 6.5) == 120.0)
        #expect(grid.tempo(at: 12) == 120.0)
        #expect(Grid().tempo(at: 1) == nil)
        #expect(Grid(beats: [Beat(number: 0, time: 1)]).tempo(at: 1) == nil)
    }

    // MARK: - Bar starts

    @Test func oneWrongVoteInFiveDoesNotChangeTheBarStart() {
        var grid = steadyGrid(40)
        // Four reported bar starts near beats 2, 6, 14 and 22, one near beat 11.
        let reported = [2, 6, 11, 14, 22].map { 2 + Double($0) * 0.5 + 0.015 }
        grid.setBarStart(fromModelBarStarts: reported)
        #expect(grid.barStartNumber == 2)
        #expect(grid.isBarStart(2) && grid.isBarStart(6) && grid.isBarStart(38))
        #expect(!grid.isBarStart(3) && !grid.isBarStart(11))
    }

    @Test func aReportedBarStartFarFromAnyBeatDoesNotVote() {
        var grid = steadyGrid(40)
        // Three halfway between beats (as on a dropped double-time beat), two on beats 1 and 5.
        let reported = [2.25, 4.25, 6.25, 2.5, 4.5]
        grid.setBarStart(fromModelBarStarts: reported)
        #expect(grid.barStartNumber == 1)
    }

    @Test func withoutReportedBarStartsTheFirstBeatStartsABar() {
        var grid = Grid(beats: (5..<20).map { Beat(number: $0, time: Double($0)) }, barStartNumber: 3)
        grid.setBarStart(fromModelBarStarts: [])
        #expect(grid.barStartNumber == 5)
    }

    @Test func theChosenBeatOneWinsOverTheVote() {
        var grid = steadyGrid(40)
        // Max chose the beat at 5.5 s, number 7. The model says beats 0, 4, 8.
        grid.beatOne = 5.52
        grid.setBarStart(fromModelBarStarts: [2, 4, 6, 8])
        #expect(grid.barStartNumber == 7)
        #expect(grid.isBarStart(3) && grid.isBarStart(11))
    }

    @Test func setBeatOneMakesThatBeatABarStartAndRemembersItsTime() {
        var grid = steadyGrid(40)
        grid.setBeatOne(at: 9)
        #expect(grid.barStartNumber == 9)
        #expect(grid.beatOne == 6.5)
        #expect(grid.isBarStart(1) && grid.isBarStart(9) && grid.isBarStart(13))

        let before = grid
        grid.setBeatOne(at: 400)
        #expect(grid == before)
    }

    // MARK: - Half and double tempo

    @Test func halvingThenDoublingASteadyGridGivesTheSameBeatTimes() {
        let grid = steadyGrid(41)
        let halved = grid.applying(tempoLevel: .halved)
        #expect(halved.tempoLevel == .halved)
        #expect(halved.beats.count == 21)
        #expect(halved.tempo(at: 10) == 60.0)

        let back = halved.applying(tempoLevel: .doubled)
        #expect(back.beats.map(\.time) == grid.beats.map(\.time))
        #expect(back.beats.map(\.number) == grid.beats.map(\.number))
        #expect(back.tempo(at: 10) == 120.0)
    }

    @Test func halvingCountsFromABarStartSoBarStartsSurvive() {
        // Bars start on beats 1, 5, 9, ...
        let grid = steadyGrid(40, barStartNumber: 1)
        let halved = grid.applying(tempoLevel: .halved)

        #expect(halved.beats.map(\.time) == grid.beats.filter { $0.number % 2 == 1 }.map(\.time))
        #expect(halved.beats.map(\.number) == Array(0..<20))
        // Every old bar start is still a beat, and every new bar start was one.
        let oldBarStarts = Set(grid.beats.filter { grid.isBarStart($0.number) }.map(\.time))
        #expect(oldBarStarts.isSubset(of: Set(halved.beats.map(\.time))))
        let newBarStarts = halved.beats.filter { halved.isBarStart($0.number) }
        #expect(newBarStarts.count == 5)
        #expect(newBarStarts.allSatisfy { oldBarStarts.contains($0.time) })
        #expect(newBarStarts.first?.time == grid.beats[1].time)
    }

    @Test func halvingKeepsAnEmptyGapEmpty() {
        let halved = gridWithAGap().applying(tempoLevel: .halved)
        #expect(halved.beats.map(\.number) == Array(0..<5) + Array(10..<15))
        #expect(halved.tempo(at: 9) == nil)
    }

    @Test func doublingAddsABeatHalfwayButNotAcrossAnEmptyGap() {
        var grid = gridWithAGap()
        grid.beats[3].estimated = true
        grid.beats[4].estimated = true
        grid.barStartNumber = 1
        let doubled = grid.applying(tempoLevel: .doubled)

        #expect(doubled.tempoLevel == .doubled)
        #expect(doubled.beats.count == 19 + 19)
        #expect(doubled.beats.map(\.number) == Array(0...18) + Array(40...58))
        #expect(doubled.beats[1].time == 2.25)
        // Nothing was put into the gap between 6.5 s and 12 s.
        #expect(!doubled.beats.contains { $0.time > 6.5 && $0.time < 12 })
        // Only the beat between two estimated beats is estimated itself.
        #expect(doubled.beats.filter(\.estimated).map(\.number) == [6, 7, 8])
        // Old bar starts are still bar starts.
        #expect(doubled.barStartNumber == 2)
        #expect(doubled.isBarStart(2) && doubled.isBarStart(10))
        #expect(doubled.tempo(at: 4) == 240.0)
    }

    @Test func theChosenBeatOneSurvivesHalvingAndDoubling() {
        var grid = steadyGrid(40)
        grid.setBeatOne(at: 7)
        let chosenTime = grid.beats[7].time

        let halved = grid.applying(tempoLevel: .halved)
        let kept = halved.beats.first { $0.time == chosenTime }
        #expect(kept != nil)
        #expect(kept.map { halved.isBarStart($0.number) } == true)
        #expect(halved.beatOne == chosenTime)

        let doubled = grid.applying(tempoLevel: .doubled)
        #expect(doubled.barStartNumber == 14)

        // In the doubled grid Max can also choose one of the new halfway beats.
        grid.beatOne = 5.75
        let doubledOnHalfBeat = grid.applying(tempoLevel: .doubled)
        #expect(doubledOnHalfBeat.beats.first { $0.number == doubledOnHalfBeat.barStartNumber }?.time == 5.75)
    }

    @Test func theNormalLevelLeavesTheBeatsAlone() {
        var grid = steadyGrid(12, barStartNumber: 3)
        grid.anchors = [Anchor(from: 3, to: 3.01)]
        #expect(grid.applying(tempoLevel: .normal) == grid)
        #expect(grid.applying(tempoLevel: .halved).anchors == grid.anchors)
    }

    // MARK: - Sub-beats

    @Test func subBeatsOfAHalfSecondBeatAtFourPerBeatAreAnEighthApart() {
        let grid = steadyGrid(10)
        let times = grid.subBeats(perBeat: 4, in: 2...4)
        #expect(times == stride(from: 2.0, through: 4.0, by: 0.125).map { $0 })
    }

    @Test func sixPerBeatAndTheRangeAreRespected() {
        let grid = steadyGrid(10, period: 0.6, from: 0)
        let times = grid.subBeats(perBeat: 6, in: 0.65...1.25)
        #expect(times.count == 6)
        for (time, expected) in zip(times, [0.7, 0.8, 0.9, 1.0, 1.1, 1.2]) {
            #expect(abs(time - expected) < 1e-9)
        }
    }

    @Test func thereAreNoSubBeatsWhereThereAreNoBeats() {
        let grid = gridWithAGap()
        // Before the first beat, across the gap, and after the last beat.
        #expect(grid.subBeats(perBeat: 4, in: 0...2.2) == [2, 2.125])
        #expect(grid.subBeats(perBeat: 4, in: 6.3...12.2) == [6.375, 6.5, 12, 12.125])
        #expect(grid.subBeats(perBeat: 4, in: 16.3...30) == [16.375, 16.5])
        #expect(Grid().subBeats(perBeat: 4, in: 0...10) == [])
    }

    // MARK: - Lookups

    @Test func theNearestBeatAtTheEdgesAndBetween() {
        let grid = steadyGrid(10)
        #expect(grid.beat(nearest: -5)?.number == 0)
        #expect(grid.beat(nearest: 2)?.number == 0)
        #expect(grid.beat(nearest: 2.2)?.number == 0)
        #expect(grid.beat(nearest: 2.3)?.number == 1)
        #expect(grid.beat(nearest: 6.5)?.number == 9)
        #expect(grid.beat(nearest: 100)?.number == 9)
        #expect(Grid().beat(nearest: 1) == nil)
    }

    @Test func theBarStartAtOrBeforeATime() {
        // Bars start on beats 2 and 6, at 3 s and 5 s.
        let grid = steadyGrid(10, barStartNumber: 2)
        #expect(grid.barStart(atOrBefore: 1) == nil)
        #expect(grid.barStart(atOrBefore: 2.9) == nil)
        #expect(grid.barStart(atOrBefore: 3)?.number == 2)
        #expect(grid.barStart(atOrBefore: 4.99)?.number == 2)
        #expect(grid.barStart(atOrBefore: 5)?.number == 6)
        #expect(grid.barStart(atOrBefore: 100)?.number == 6)
        #expect(Grid().barStart(atOrBefore: 1) == nil)
    }
}

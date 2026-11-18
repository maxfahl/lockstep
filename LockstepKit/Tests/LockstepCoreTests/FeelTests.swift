import Testing
@testable import LockstepCore

@Suite("Feel")
struct FeelTests {
    /// Beats from 2 s on, evenly spaced. At 0.5 s a beat (120 beats a minute) a sixteenth is 125 ms and a
    /// sixth of a beat 83 ms.
    private func steadyGrid(beat: Double = 0.5, count: Int = 60) -> Grid {
        Grid(beats: (0..<count).map { Beat(number: $0, time: 2 + Double($0) * beat) })
    }

    /// Syllables at the given places within each beat (0 is the beat, 0.5 halfway to the next), beat after
    /// beat from the third beat on, until there are `count` of them.
    private func syllables(_ count: Int, at places: [Double], beat: Double = 0.5) -> [Double] {
        (0..<count).map { (index: Int) -> Double in
            let beatsIn: Double = 2 + Double(index / places.count) + places[index % places.count]
            return 2 + beatsIn * beat
        }
    }

    /// The same numbers every run, so a test with scattered syllables cannot fail one day and pass the next.
    private struct Scatter {
        var state: UInt64

        /// Evenly spread from 0 up to 1.
        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }

        /// Each time moved by up to `milliseconds`, earlier or later.
        mutating func jittered(_ times: [Double], milliseconds: Double) -> [Double] {
            times.map { $0 + (unit() * 2 - 1) * milliseconds / 1_000 }
        }
    }

    private let sixteenthPlaces = [0, 0.25, 0.5, 0.75]
    private let tripletPlaces = [0, 1.0 / 3, 2.0 / 3]

    @Test func theTwoGridsHaveFourAndSixSubBeats() {
        #expect(SubBeatGrid.sixteenths.perBeat == 4)
        #expect(SubBeatGrid.triplets.perBeat == 6)
    }

    @Test func markersOnSixteenthsChooseSixteenths() {
        let times = syllables(16, at: sixteenthPlaces)
        #expect(Feel.detect(markerTimes: times, grid: steadyGrid()) == .sixteenths)
        #expect(Feel.score(markerTimes: times, grid: steadyGrid(), subBeats: .sixteenths) > 0.99)
        #expect(Feel.score(markerTimes: times, grid: steadyGrid(), subBeats: .triplets) < 0.01)
    }

    @Test func markersOnTripletsChooseTriplets() {
        let times = syllables(12, at: tripletPlaces)
        #expect(Feel.detect(markerTimes: times, grid: steadyGrid()) == .triplets)
        #expect(Feel.score(markerTimes: times, grid: steadyGrid(), subBeats: .triplets) > 0.99)
        #expect(Feel.score(markerTimes: times, grid: steadyGrid(), subBeats: .sixteenths) < 0.01)
    }

    @Test func sixSyllablesToABeatAreTripletsToo() {
        let times = syllables(18, at: (0..<6).map { Double($0) / 6 })
        #expect(Feel.detect(markerTimes: times, grid: steadyGrid()) == .triplets)
    }

    @Test func fifteenMillisecondsOfJitterDoNotChangeTheChoice() {
        // Several different scatterings, at two tempos, so the answer does not hang on one lucky draw.
        for seed in 1...20 {
            var scatter = Scatter(state: UInt64(seed))
            for beat in [0.5, 0.43] {
                let grid = steadyGrid(beat: beat)
                let onSixteenths = scatter.jittered(syllables(16, at: sixteenthPlaces, beat: beat), milliseconds: 15)
                #expect(Feel.detect(markerTimes: onSixteenths, grid: grid) == .sixteenths)
                let onTriplets = scatter.jittered(syllables(12, at: tripletPlaces, beat: beat), milliseconds: 15)
                #expect(Feel.detect(markerTimes: onTriplets, grid: grid) == .triplets)
            }
        }
    }

    @Test func aLateTripletClipIsStillTriplets() {
        let times = syllables(12, at: tripletPlaces).map { $0 + 0.035 }
        #expect(Feel.detect(markerTimes: times, grid: steadyGrid()) == .triplets)
    }

    @Test func markersOnEighthNotesChooseSixteenths() {
        // Eighth notes lie on both grids, so neither wins and sixteenths stay.
        let times = syllables(12, at: [0, 0.5])
        #expect(Feel.detect(markerTimes: times, grid: steadyGrid()) == .sixteenths)
        #expect(Feel.score(markerTimes: times, grid: steadyGrid(), subBeats: .triplets) > 0.99)
        #expect(Feel.score(markerTimes: times, grid: steadyGrid(), subBeats: .sixteenths) > 0.99)
    }

    @Test func randomMarkersChooseSixteenths() {
        // 400 clips of syllables that fall anywhere. Chance makes a few of them look a little like triplets:
        // at most one in twenty-five may be taken for them.
        var scatter = Scatter(state: 7)
        var taken = 0
        for round in 0..<400 {
            let count = 6 + round % 30
            let times = (0..<count).map { _ in 3 + scatter.unit() * 12 }
            if Feel.detect(markerTimes: times, grid: steadyGrid()) == .triplets { taken += 1 }
        }
        #expect(taken <= 16)
    }

    @Test func fewerThanFourMarkersAreSixteenths() {
        #expect(Feel.detect(markerTimes: syllables(3, at: tripletPlaces), grid: steadyGrid()) == .sixteenths)
        #expect(Feel.detect(markerTimes: syllables(4, at: tripletPlaces), grid: steadyGrid()) == .triplets)
        #expect(Feel.detect(markerTimes: [], grid: steadyGrid()) == .sixteenths)
    }

    @Test func withoutBeatsTheAnswerIsSixteenths() {
        let times = syllables(12, at: tripletPlaces)
        #expect(Feel.detect(markerTimes: times, grid: Grid()) == .sixteenths)
        #expect(Feel.score(markerTimes: times, grid: Grid(), subBeats: .triplets) == 0)
    }
}

import Foundation
import Testing
@testable import LockstepCore

@Suite("BeatLevel")
struct BeatLevelTests {
    /// 100 BPM.
    let period = 0.6

    func steady(_ count: Int, from start: Double = 1) -> [Double] {
        (0..<count).map { start + Double($0) * period }
    }

    func spacings(_ beats: [Beat]) -> [Double] {
        zip(beats.dropFirst(), beats).map { $0.time - $1.time }
    }

    /// The model's own output for "Weighted Silence", kept from the start of the project.
    func weightedSilenceRawBeats() throws -> [Double] {
        struct File: Decodable { var beats: [Double] }
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/weighted-silence-raw-beats.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).beats
    }

    @Test func weightedSilenceGives313BeatsAtOneLevel() throws {
        let raw = try weightedSilenceRawBeats()
        #expect(raw.count == 361)

        let beats = BeatLevel.force(raw)
        #expect(beats.count == 313)
        for spacing in spacings(beats) {
            #expect(spacing > 0.6199 && spacing < 0.7401)
        }
        // The model left no hole in this song, so nothing is filled in:
        // every beat is one it reported and no number is skipped.
        #expect(beats.allSatisfy { !$0.estimated })
        #expect(beats.map(\.number) == Array(0..<313))
        #expect(beats.allSatisfy { raw.contains($0.time) })
        #expect(beats.first?.time == raw.first)
        #expect(beats.last?.time == raw.last)
    }

    @Test func aStretchAtDoubleRateIsThinnedToTheSteadyList() {
        let main = steady(60)
        var raw = main
        for index in 20..<35 {
            raw.append(main[index] + period / 2)
        }
        let beats = BeatLevel.force(raw.sorted())
        #expect(beats.map(\.time) == main)
        #expect(beats.map(\.number) == Array(0..<60))
        #expect(beats.allSatisfy { !$0.estimated })
    }

    @Test func aBeatMissingInsideADoubleRateStretchIsFilledNotReplacedByAnExtra() {
        // The stretch is short enough that most spacings are still whole beats.
        let main = steady(80)
        var raw = main
        for index in 10..<25 {
            raw.append(main[index] + period / 2)
        }
        raw.removeAll { $0 == main[18] }

        let beats = BeatLevel.force(raw.sorted())
        #expect(beats.filter(\.estimated).map(\.number) == [18])
        #expect(beats.count == 80)
        for (beat, time) in zip(beats, main) {
            #expect(abs(beat.time - time) < 1e-9)
        }
    }

    @Test func threeRemovedBeatsComeBackEstimatedAndEvenlyPlaced() {
        let main = steady(40)
        let removed = 17...19
        let raw = main.enumerated().filter { !removed.contains($0.offset) }.map(\.element)

        let beats = BeatLevel.force(raw)
        #expect(beats.count == 40)
        #expect(beats.map(\.number) == Array(0..<40))
        for (index, beat) in beats.enumerated() {
            #expect(beat.estimated == removed.contains(index))
            #expect(abs(beat.time - main[index]) < 1e-9)
        }
    }

    @Test func removedBeatsInSeparatePlacesComeBackToo() {
        let main = steady(40)
        let removed: Set<Int> = [5, 18, 31]
        let raw = main.enumerated().filter { !removed.contains($0.offset) }.map(\.element)

        let beats = BeatLevel.force(raw)
        #expect(beats.count == 40)
        #expect(beats.enumerated().filter { $0.element.estimated }.map(\.offset) == [5, 18, 31])
        for (index, beat) in beats.enumerated() {
            #expect(abs(beat.time - main[index]) < 1e-9)
        }
    }

    @Test func aHoleLongerThanTheLimitStaysEmptyAndTheCountCarriesOn() {
        let main = steady(60)
        // Beats 20 to 29 are missing: ten in a row, with a limit of eight.
        let raw = Array(main[..<20]) + Array(main[30...])

        let beats = BeatLevel.force(raw, maxGapBeats: 8)
        #expect(beats.count == 50)
        #expect(beats.allSatisfy { !$0.estimated })
        #expect(beats.map(\.time) == raw)
        #expect(beats[19].number == 19)
        #expect(beats[20].number == 30)
        #expect(beats.last?.number == 59)
    }

    @Test func aHoleExactlyAtTheLimitIsFilled() {
        let main = steady(60)
        let raw = Array(main[..<20]) + Array(main[30...])

        let beats = BeatLevel.force(raw, maxGapBeats: 10)
        #expect(beats.count == 60)
        #expect(beats.filter(\.estimated).map(\.number) == Array(20..<30))
    }

    @Test func withALimitOfZeroNothingIsEverFilled() {
        let main = steady(40)
        let removed: Set<Int> = [5, 18, 19, 31]
        let raw = main.enumerated().filter { !removed.contains($0.offset) }.map(\.element)

        let beats = BeatLevel.force(raw, maxGapBeats: 0)
        #expect(beats.map(\.time) == raw)
        #expect(beats.allSatisfy { !$0.estimated })
        // The numbers still leave room for the beats that are not there.
        #expect(beats.map(\.number) == (0..<40).filter { !removed.contains($0) })
    }

    @Test(arguments: [0, 3, 32])
    func noBeatIsEarlierThanTheFirstOrLaterThanTheLastReported(maxGapBeats: Int) throws {
        let ragged = Array(steady(30)[..<12]) + steady(9, from: 14.47) + [27.0, 27.31, 40.2]
        for raw in [try weightedSilenceRawBeats(), ragged] {
            let beats = BeatLevel.force(raw, maxGapBeats: maxGapBeats)
            #expect(beats.first?.time == raw.first)
            #expect(beats.allSatisfy { $0.time >= raw[0] && $0.time <= raw[raw.count - 1] })
            #expect(zip(beats.dropFirst(), beats).allSatisfy { $0.time > $1.time && $0.number > $1.number })
        }
    }

    @Test func musicThatStartsAgainOutOfStepIsNotBridgedWithInventedBeats() {
        // A break of about four and a half beats: the second part is off the first part's places.
        let firstPart = steady(16)
        let secondPart = steady(16, from: firstPart[15] + period * 4.45)

        let beats = BeatLevel.force(firstPart + secondPart)
        #expect(beats.map(\.time) == firstPart + secondPart)
        #expect(beats.allSatisfy { !$0.estimated })
        #expect(beats[16].number == 15 + 4)
    }

    @Test func theLocalPeriodFollowsASlowChangeOfTempo() {
        // From 90 to 110 BPM over 200 beats: far from the median spacing at both ends.
        var raw: [Double] = [0.5]
        for index in 1..<200 {
            raw.append(raw[index - 1] + 60 / (90 + 20 * Double(index) / 199))
        }
        let beats = BeatLevel.force(raw)
        #expect(beats.map(\.time) == raw)
        #expect(beats.map(\.number) == Array(0..<200))
    }

    @Test func emptyAndSingleInputs() {
        #expect(BeatLevel.force([]) == [])
        #expect(BeatLevel.force([2.5]) == [Beat(number: 0, time: 2.5, estimated: false)])
    }
}

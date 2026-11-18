import Foundation
import Testing
@testable import LockstepCore

@Suite("BeatRefiner")
struct BeatRefinerTests {
    /// The onset curve's step: 32 samples at 48 kHz, two thirds of a millisecond.
    static let hop = 32.0 / 48_000

    /// The same "random" numbers on every run.
    struct Dice {
        var state: UInt64
        /// A number from -1 up to 1.
        mutating func roll() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 52) - 1
        }
    }

    /// An onset curve that is flat except for a sharp peak at each given time.
    func onsetCurve(
        length: Double,
        peaks: [(time: Double, height: Float)],
        noise: Float = 0
    ) -> (values: [Float], times: [Double]) {
        let count = Int(length / Self.hop)
        var dice = Dice(state: 7)
        var values = (0..<count).map { _ in noise * Float(abs(dice.roll())) }
        for peak in peaks {
            let centre = Int((peak.time / Self.hop).rounded())
            for (offset, share) in [(-2, Float(0.2)), (-1, 0.5), (0, 1), (1, 0.5), (2, 0.2)] {
                let index = centre + offset
                guard values.indices.contains(index) else { continue }
                values[index] = max(values[index], peak.height * share)
            }
        }
        return (values, (0..<count).map { Double($0) * Self.hop })
    }

    /// What the model would report for these true beat times: the nearest 20 ms step.
    func modelBeats(_ times: [Double]) -> [Beat] {
        times.enumerated().map { Beat(number: $0.offset, time: ($0.element / 0.02).rounded() * 0.02, estimated: false) }
    }

    func steady(_ count: Int, period: Double = 0.6, from start: Double = 1) -> [Double] {
        (0..<count).map { start + Double($0) * period }
    }

    /// Beat times of a tempo that slides evenly from one BPM to another.
    func sliding(_ count: Int, from first: Double, to last: Double) -> [Double] {
        var times = [1.0]
        for index in 1..<count {
            times.append(times[index - 1] + 60 / (first + (last - first) * Double(index) / Double(count - 1)))
        }
        return times
    }

    @Test func beatsLandWithinThreeMillisecondsOfADriftingSongsDrumHits() {
        let truth = sliding(160, from: 90, to: 92)
        var dice = Dice(state: 42)
        var peaks: [(time: Double, height: Float)] = []
        for (index, time) in truth.enumerated() {
            peaks.append((time + 0.002 * dice.roll(), 1))
            if index % 5 == 0 {
                // A louder hit that is not the beat, such as a grace note 12 ms early.
                peaks.append((time - 0.012, 1.5))
            }
        }
        let onsets = onsetCurve(length: truth[truth.count - 1] + 2, peaks: peaks)

        let result = BeatRefiner.refine(beats: modelBeats(truth), onsetValues: onsets.values, onsetTimes: onsets.times)

        #expect(result.beats.count == truth.count)
        #expect(result.beats.map(\.number) == Array(0..<truth.count))
        for (beat, time) in zip(result.beats, truth) {
            #expect(abs(beat.time - time) < 0.003)
        }
        // The beats with a false peak have no clean hit, and they are the only ones.
        #expect(result.beats.filter(\.estimated).map(\.number) == Array(stride(from: 0, to: truth.count, by: 5)))
        #expect(result.uncertainRanges.isEmpty)
    }

    @Test func tenBeatsWithoutDrumHitsFollowTheCurveAndAreMarkedEstimated() {
        let truth = steady(80)
        let silent = 30..<40
        let peaks = truth.enumerated().filter { !silent.contains($0.offset) }.map { (time: $0.element, height: Float(1)) }
        let onsets = onsetCurve(length: truth[truth.count - 1] + 2, peaks: peaks, noise: 0.03)

        let result = BeatRefiner.refine(beats: modelBeats(truth), onsetValues: onsets.values, onsetTimes: onsets.times)

        #expect(result.beats.filter(\.estimated).map(\.number) == Array(silent))
        for (beat, time) in zip(result.beats, truth) {
            #expect(abs(beat.time - time) < 0.001)
        }
        for index in 30...40 {
            let spacing = result.beats[index].time - result.beats[index - 1].time
            #expect(abs(spacing - 0.6) < 0.0005)
        }
        #expect(result.uncertainRanges == [result.beats[30].time...result.beats[39].time])
    }

    @Test func anAnchorHoldsItsBeatAndItsNeighboursFollowSmoothly() {
        let truth = sliding(80, from: 90, to: 92)
        let onsets = onsetCurve(length: truth[truth.count - 1] + 2, peaks: truth.map { ($0, 1) })
        let beats = modelBeats(truth)

        let plain = BeatRefiner.refine(beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times).beats
        let anchor = Anchor(from: plain[40].time, to: plain[40].time + 0.025)
        let moved = BeatRefiner.refine(
            beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times, anchors: [anchor]
        ).beats

        #expect(moved[40].time == anchor.to)
        for index in moved.indices where index <= 32 || index >= 48 {
            #expect(moved[index] == plain[index])
        }
        let shift = moved.indices.map { moved[$0].time - plain[$0].time }
        for index in 33..<40 {
            #expect(shift[index] > 0)
            #expect(shift[index] > shift[index - 1])
        }
        for index in 41..<48 {
            #expect(shift[index] > 0)
            #expect(shift[index] > shift[index + 1])
        }
    }

    @Test func twoAnchorsCloseTogetherCarryTheBeatsBetweenThem() {
        let truth = steady(80)
        let onsets = onsetCurve(length: truth[truth.count - 1] + 2, peaks: truth.map { ($0, 1) })
        let beats = modelBeats(truth)
        let plain = BeatRefiner.refine(beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times).beats

        let moved = BeatRefiner.refine(
            beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times,
            anchors: [
                Anchor(from: plain[40].time, to: plain[40].time + 0.02),
                Anchor(from: plain[48].time, to: plain[48].time + 0.01),
            ]
        ).beats

        for index in 40...48 {
            let expected = 0.02 - 0.01 * Double(index - 40) / 8
            #expect(abs(moved[index].time - plain[index].time - expected) < 1e-9)
        }
        #expect(moved[32].time == plain[32].time)
        #expect(moved[56].time == plain[56].time)
    }

    @Test func anAnchorOnAnUnsureBeatMakesItSure() {
        let truth = steady(40)
        let peaks = truth.enumerated().filter { !(10..<16).contains($0.offset) }.map { (time: $0.element, height: Float(1)) }
        let onsets = onsetCurve(length: truth[truth.count - 1] + 2, peaks: peaks)
        let beats = modelBeats(truth)
        let plain = BeatRefiner.refine(beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times).beats
        #expect(plain[12].estimated)

        let moved = BeatRefiner.refine(
            beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times,
            anchors: [Anchor(from: plain[12].time, to: plain[12].time - 0.015)]
        ).beats
        #expect(!moved[12].estimated)
        #expect(moved[11].estimated && moved[13].estimated)
    }

    @Test func anAnchorThatBelongsToNoBeatChangesNothing() {
        let truth = steady(40)
        let onsets = onsetCurve(length: truth[truth.count - 1] + 2, peaks: truth.map { ($0, 1) })
        let beats = modelBeats(truth)
        let plain = BeatRefiner.refine(beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times)

        // Halfway between two beats, as a beat of a doubled grid would be.
        let halfway = (plain.beats[20].time + plain.beats[21].time) / 2
        let moved = BeatRefiner.refine(
            beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times,
            anchors: [Anchor(from: halfway, to: halfway + 0.02)]
        )
        #expect(moved == plain)
    }

    @Test func beatsStayInOrderWhenAnchorsWouldCross() {
        let truth = steady(40)
        let onsets = onsetCurve(length: truth[truth.count - 1] + 2, peaks: truth.map { ($0, 1) })
        let beats = modelBeats(truth)
        let plain = BeatRefiner.refine(beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times).beats

        let moved = BeatRefiner.refine(
            beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times,
            anchors: [
                Anchor(from: plain[20].time, to: plain[20].time + 0.5),
                Anchor(from: plain[21].time, to: plain[21].time - 0.5),
            ]
        ).beats
        for index in moved.indices.dropFirst() {
            #expect(moved[index].time - moved[index - 1].time >= 0.29)
        }
    }

    @Test func aSmallerWindowFollowsASuddenStepMoreClosely() {
        let truth = steady(100)
        // From beat 50 on, every drum hit is 10 ms late.
        let hits = truth.enumerated().map { $0.offset < 50 ? $0.element : $0.element + 0.01 }
        let onsets = onsetCurve(length: hits[hits.count - 1] + 2, peaks: hits.map { ($0, 1) })

        func distance(window: Int) -> Double {
            let beats = BeatRefiner.refine(
                beats: modelBeats(truth), onsetValues: onsets.values, onsetTimes: onsets.times, smoothingBeats: window
            ).beats
            return zip(beats, hits).map { abs($0.time - $1) }.reduce(0, +)
        }
        #expect(distance(window: 9) < distance(window: 17))
        #expect(distance(window: 17) < distance(window: 33))
    }

    @Test func eachSideOfAnEmptyGapIsFittedOnItsOwn() {
        // The music stops and starts again a third of a beat out of step, a little faster.
        let firstPart = steady(30)
        let secondPart = steady(30, period: 0.58, from: firstPart[29] + 0.6 * 12.33)
        let truth = firstPart + secondPart
        var beats = modelBeats(truth)
        for index in 30..<60 {
            beats[index].number = index + 11
        }
        let onsets = onsetCurve(length: truth[truth.count - 1] + 2, peaks: truth.map { ($0, 1) })

        let result = BeatRefiner.refine(beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times)
        #expect(result.beats.map(\.number) == beats.map(\.number))
        #expect(result.beats.allSatisfy { !$0.estimated })
        for (beat, time) in zip(result.beats, truth) {
            #expect(abs(beat.time - time) < 0.0005)
        }
    }

    @Test func filledInBeatsStayEstimatedEvenWhereADrumHits() {
        let truth = steady(40)
        var beats = modelBeats(truth)
        beats[20].estimated = true
        let onsets = onsetCurve(length: truth[truth.count - 1] + 2, peaks: truth.map { ($0, 1) })

        let result = BeatRefiner.refine(beats: beats, onsetValues: onsets.values, onsetTimes: onsets.times)
        #expect(result.beats.filter(\.estimated).map(\.number) == [20])
        #expect(abs(result.beats[20].time - truth[20]) < 0.0005)
    }

    @Test func loosenedBeatsFindTheirDrumHitsAndAreStillMarkedEstimated() {
        // The drums play 7 ms after every 20 ms step, so a beat that finds its hit has moved.
        let truth = steady(40).map { $0 + 0.007 }
        let onsets = onsetCurve(length: truth[truth.count - 1] + 2, peaks: truth.map { ($0, 1) })
        let loosened = Set(15..<25)

        let result = BeatRefiner.refine(
            beats: modelBeats(truth), onsetValues: onsets.values, onsetTimes: onsets.times, loosened: loosened
        )

        #expect(Set(result.beats.filter(\.estimated).map(\.number)) == loosened)
        for (beat, time) in zip(result.beats, truth) {
            #expect(abs(beat.time - time) < 0.001)
        }
        #expect(result.uncertainRanges == [result.beats[15].time...result.beats[24].time])
        // A loosened beat Max dragged is where he put it, and is no guess any more.
        let anchor = Anchor(from: result.beats[20].time, to: result.beats[20].time + 0.02)
        let anchored = BeatRefiner.refine(
            beats: modelBeats(truth), onsetValues: onsets.values, onsetTimes: onsets.times,
            anchors: [anchor], loosened: loosened
        )
        #expect(anchored.beats[20].time == anchor.to)
        #expect(!anchored.beats[20].estimated)
        #expect(anchored.beats[19].estimated && anchored.beats[21].estimated)
    }

    @Test func withoutAnOnsetCurveTheModelsBeatsAreSmoothedAndAllEstimated() {
        let truth = steady(40)
        let result = BeatRefiner.refine(beats: modelBeats(truth), onsetValues: [Float](), onsetTimes: [])
        #expect(result.beats.count == 40)
        #expect(result.beats.allSatisfy { $0.estimated })
        for (beat, time) in zip(result.beats, truth) {
            #expect(abs(beat.time - time) < 0.011)
        }
        #expect(result.uncertainRanges == [result.beats[0].time...result.beats[39].time])
    }

    @Test func uncertainRangesNeedThreeEstimatedBeatsInARow() {
        func beat(_ number: Int, _ estimated: Bool) -> Beat {
            Beat(number: number, time: Double(number) * 0.5, estimated: estimated)
        }
        let beats = [
            beat(0, false), beat(1, true), beat(2, true), beat(3, false),
            beat(4, true), beat(5, true), beat(6, true), beat(7, false),
            // Two before an empty gap and two after it are not one run of four.
            beat(8, true), beat(9, true), beat(20, true), beat(21, true), beat(22, false),
            beat(23, true), beat(24, true), beat(25, true), beat(26, true),
        ]
        #expect(BeatRefiner.uncertainRanges(in: beats) == [2.0...3.0, 11.5...13.0])
        #expect(BeatRefiner.uncertainRanges(in: []) == [])
    }

    @Test func smoothingLeavesAParabolaAsItIs() {
        let values: [Double] = (0..<40).map { index in
            let x = Double(index)
            return 3 + 0.6 * x + 0.001 * x * x
        }
        for window in [3, 9, 17, 33, 99] {
            let smoothed = BeatRefiner.savitzkyGolay(values, window: window)
            for (smooth, value) in zip(smoothed, values) {
                #expect(abs(smooth - value) < 1e-9)
            }
        }
    }

    @Test func smoothingCopesWithVeryFewValues() {
        #expect(BeatRefiner.savitzkyGolay([], window: 17) == [])
        #expect(BeatRefiner.savitzkyGolay([1], window: 17) == [1])
        #expect(BeatRefiner.savitzkyGolay([1, 2.5], window: 17) == [1, 2.5])
        // Three and four values have room for a window of three only, which a parabola fits exactly.
        #expect(BeatRefiner.savitzkyGolay([1, 5, 2], window: 17) == [1, 5, 2])
        // An even window is widened to the next odd one.
        let line = (0..<20).map { Double($0) }
        #expect(BeatRefiner.savitzkyGolay(line, window: 8) == BeatRefiner.savitzkyGolay(line, window: 9))
    }

    @Test func smoothingEvensOutScatter() {
        var dice = Dice(state: 3)
        let line = (0..<200).map { 0.6 * Double($0) }
        let noisy = line.map { $0 + 0.004 * dice.roll() }
        let smoothed = BeatRefiner.savitzkyGolay(noisy, window: 17)
        func error(_ values: [Double]) -> Double {
            zip(values, line).map { abs($0 - $1) }.reduce(0, +) / Double(line.count)
        }
        #expect(error(smoothed) < error(noisy) / 2)
    }
}

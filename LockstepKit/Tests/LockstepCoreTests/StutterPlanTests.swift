import Foundation
import Testing
@testable import LockstepCore

@Suite struct StutterPlanTests {
    /// The beats of a song whose tempo drifts, as samples of a clip's dry sound: the first beat lies before
    /// the sound, and each beat is `change` times as long as the one before, from half a second.
    private static func driftingBeats(change: Double = 0.98, count: Int = 24) -> [Double] {
        var beats: [Double] = []
        var place = -6_000.0
        var length = 24_000.0
        for _ in 0..<count {
            beats.append(place)
            place += length
            length *= change
        }
        return beats
    }

    /// Where sub-beat `part` of `perBeat` after beat `index` lies, as a whole sample.
    private static func subBeat(_ part: Int, of perBeat: Int, after index: Int, in beats: [Double]) -> Int {
        let whole = index + part / perBeat
        let rest = Double(part % perBeat) / Double(perBeat)
        return Int((beats[whole] + rest * (beats[whole + 1] - beats[whole])).rounded())
    }

    /// Whether a repeat starts on a sub-beat. The stretch starts on a whole sample, up to half a sample from
    /// its beat, and every repeat keeps that distance, so a repeat may be one sample from the sub-beat's own
    /// whole sample.
    private static func isOn(_ start: Int, _ subBeat: Int) -> Bool {
        abs(start - subBeat) <= 1
    }

    @Test func inSixteenthsEveryRepeatStartsOnASubBeatOfASongThatSpeedsUp() {
        let beats = Self.driftingBeats()
        // From the third beat, two and a half beats long.
        let start = Int(beats[2].rounded())
        let stretch = start..<Int(((beats[4] + beats[5]) / 2).rounded())

        let plan = StutterPlan(stretch: stretch, beats: beats, perBeat: 4)

        #expect(plan.repeats.count == 10)
        for (number, one) in plan.repeats.enumerated() {
            #expect(Self.isOn(one.start, Self.subBeat(number, of: 4, after: 2, in: beats)))
        }
        // The first sub-beat's length of the stretch is what is repeated.
        #expect(Self.isOn(start + plan.sliceLength, Self.subBeat(1, of: 4, after: 2, in: beats)))
        // The song speeds up, so the sub-beats come closer and a repeat is cut where the next starts. The
        // four sub-beats of one beat are the same length, give or take the one sample of whole places.
        #expect(plan.repeats.allSatisfy { $0.length <= plan.sliceLength })
        for (one, next) in zip(plan.repeats, plan.repeats.dropFirst()) {
            #expect(one.start + one.length <= next.start)
            #expect(one.start + one.length >= next.start - 1)
        }
        // By the third beat of the stretch a sub-beat is clearly shorter than the piece.
        #expect(plan.repeats[8].length < plan.sliceLength - 100)
        #expect(plan.repeats[9].start + plan.repeats[9].length == stretch.upperBound)
    }

    @Test func inASongThatSlowsDownEveryRepeatIsTheWholeSliceAndStillOnItsSubBeat() {
        let beats = Self.driftingBeats(change: 1.02)
        let start = Int(beats[2].rounded())
        let stretch = start..<Int(beats[4].rounded())

        let plan = StutterPlan(stretch: stretch, beats: beats, perBeat: 4)

        #expect(plan.repeats.count == 8)
        for (number, one) in plan.repeats.enumerated() {
            #expect(Self.isOn(one.start, Self.subBeat(number, of: 4, after: 2, in: beats)))
        }
        // The sub-beats grow, so no repeat reaches the next and every repeat of the second beat is the
        // whole piece.
        for (one, next) in zip(plan.repeats, plan.repeats.dropFirst()) {
            #expect(one.start + one.length <= next.start)
        }
        #expect(plan.repeats[4...].allSatisfy { $0.length == plan.sliceLength })
    }

    @Test func inTripletsThereAreSixRepeatsToABeat() {
        let beats = Self.driftingBeats()
        let start = Int(beats[3].rounded())
        let stretch = start..<Int(beats[5].rounded())

        let plan = StutterPlan(stretch: stretch, beats: beats, perBeat: 6)

        #expect(plan.repeats.count == 12)
        for (number, one) in plan.repeats.enumerated() {
            #expect(Self.isOn(one.start, Self.subBeat(number, of: 6, after: 3, in: beats)))
        }
        #expect(Self.isOn(start + plan.sliceLength, Self.subBeat(1, of: 6, after: 3, in: beats)))
    }

    @Test func aStretchThatStartsBetweenTwoSubBeatsKeepsThatPlaceBetweenThem() {
        // Steady beats of 24,000 samples, so a sub-beat is 6,000. The stretch starts 1,000 after one.
        let beats = (0..<12).map { Double($0 * 24_000) }
        let stretch = 31_000..<50_000

        let plan = StutterPlan(stretch: stretch, beats: beats, perBeat: 4)

        #expect(plan.repeats.map(\.start) == [31_000, 37_000, 43_000, 49_000])
        #expect(plan.sliceLength == 6_000)
        #expect(plan.repeats.map(\.length) == [6_000, 6_000, 6_000, 1_000])
    }

    @Test func withoutBeatsTheSlicesAre125Milliseconds() {
        let plan = StutterPlan(stretch: 10_000..<25_000, beats: [], perBeat: 4)

        #expect(plan.sliceLength == 6_000)
        #expect(plan.repeats.map(\.start) == [10_000, 16_000, 22_000])
        #expect(plan.repeats.map(\.length) == [6_000, 6_000, 3_000])
    }

    @Test func aStretchWhereTheSongHasNoBeatsGets125MillisecondSlices() {
        let beats = (0..<8).map { Double($0 * 20_000) }
        // After the last beat.
        let after = StutterPlan(stretch: 150_000..<165_000, beats: beats, perBeat: 4)
        #expect(after.repeats.map(\.start) == [150_000, 156_000, 162_000])

        // In a stretch of the song that was left without beats: two beats far further apart than the others.
        var gapped = beats
        for index in 4..<8 { gapped[index] += 200_000 }
        let inGap = StutterPlan(stretch: 100_000..<115_000, beats: gapped, perBeat: 4)
        #expect(inGap.repeats.map(\.start) == [100_000, 106_000, 112_000])
    }

    @Test func whereTheBeatsEndInsideTheStretchItGoesOnInSlicesOfTheSameLength() {
        let beats = (0..<4).map { Double($0 * 24_000) }
        // From the third beat to well after the last.
        let plan = StutterPlan(stretch: 48_000..<90_000, beats: beats, perBeat: 4)

        #expect(plan.sliceLength == 6_000)
        #expect(plan.repeats.map(\.start) == [48_000, 54_000, 60_000, 66_000, 72_000, 78_000, 84_000])
        #expect(plan.repeats.last?.length == 6_000)
    }

    @Test func aStretchShorterThanASubBeatIsOneRepeatOfAllOfIt() {
        let beats = (0..<12).map { Double($0 * 24_000) }

        let plan = StutterPlan(stretch: 24_000..<26_000, beats: beats, perBeat: 4)

        #expect(plan.sliceLength == 2_000)
        #expect(plan.repeats == [StutterPlan.Repeat(start: 24_000, length: 2_000)])
    }

    @Test func anEmptyStretchHasNoRepeats() {
        let plan = StutterPlan(stretch: 500..<500, beats: [0, 24_000, 48_000], perBeat: 4)

        #expect(plan.repeats.isEmpty)
        #expect(plan.sliceLength == 0)
    }
}

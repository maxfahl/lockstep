import Testing
@testable import LockstepCore

/// Who is paired with whom when a double is held against its lead: the slide of a line, the partners of its
/// syllables, and where a note ends.
@Suite("SyllableMatch")
struct SyllableMatchTests {
    /// The lead's syllables at these song seconds, with no note ends.
    private func lead(_ times: [Double]) -> [TimingTargets.Target] {
        times.map { TimingTargets.Target(time: $0) }
    }

    /// The furthest slide and the furthest move of the settings as they start, in seconds: 80 ms and 40 ms.
    private let reach = 0.12
    private let furthestMove = 0.04

    // MARK: The slide of a line

    @Test func aDoubleThatIsEvenlyThirtyMillisecondsLateSlidesThirtyEarlierAndThenSitsOnTheLead() {
        let leadTimes = [1.0, 1.2, 1.35, 1.6]
        let double = leadTimes.map { $0 + 0.03 }
        let slide = SyllableMatch.slide(of: double, onto: lead(leadTimes), reach: reach)
        #expect(abs(slide + 0.03) < 1e-9)
        // After the slide every syllable has the lead syllable it was sung to, and nothing is left to move.
        let slid = double.map { $0 + slide }
        let partners = SyllableMatch.partners(of: slid, among: lead(leadTimes), within: furthestMove)
        #expect(partners == [0, 1, 2, 3])
        for (time, partner) in zip(slid, leadTimes) {
            #expect(abs(time - partner) < 1e-9)
        }
    }

    @Test func oneStraySyllableDoesNotDragTheLine() {
        // Four syllables 30 ms late and one 70 ms late: the middle value is the 30.
        let leadTimes = [1.0, 1.2, 1.4, 1.6, 1.8]
        let double = [1.03, 1.23, 1.47, 1.63, 1.83]
        #expect(abs(SyllableMatch.slide(of: double, onto: lead(leadTimes), reach: reach) + 0.03) < 1e-9)
    }

    @Test func withAnEvenNumberOfSyllablesTheSlideLiesBetweenTheTwoMiddleDistances() {
        // 10 ms late and 30 ms late: 20 ms earlier.
        let slide = SyllableMatch.slide(of: [1.01, 1.23], onto: lead([1.0, 1.2]), reach: reach)
        #expect(abs(slide + 0.02) < 1e-9)
    }

    @Test func aLineWithNoLeadSyllableNearItStays() {
        // An ad-lib where the lead is silent: the nearest lead syllable is half a second away.
        #expect(SyllableMatch.slide(of: [3.0, 3.2, 3.4], onto: lead([1.0, 1.2, 2.5]), reach: reach) == 0)
        #expect(SyllableMatch.slide(of: [3.0, 3.2], onto: [], reach: reach) == 0)
        #expect(SyllableMatch.slide(of: [], onto: lead([1.0]), reach: reach) == 0)
    }

    @Test func aSyllableWithNoLeadSyllableNearItDoesNotCountForTheSlide() {
        // Two syllables 20 ms early, and an ad-lib after them that the lead does not have.
        let slide = SyllableMatch.slide(of: [0.98, 1.18, 1.9], onto: lead([1.0, 1.2]), reach: reach)
        #expect(abs(slide - 0.02) < 1e-9)
    }

    // MARK: Partners

    @Test func anExtraSyllableInTheDoubleIsLeftAloneAndTheRestStillPairInOrder() {
        // The second syllable of the double is one the lead does not have.
        let partners = SyllableMatch.partners(
            of: [1.005, 1.1, 1.195, 1.41], among: lead([1.0, 1.2, 1.4]), within: furthestMove
        )
        #expect(partners == [0, nil, 1, 2])
    }

    @Test func aSyllableTheDoubleLeftOutLeavesItsLeadSyllableFree() {
        let partners = SyllableMatch.partners(of: [1.005, 1.41], among: lead([1.0, 1.2, 1.4]), within: furthestMove)
        #expect(partners == [0, 2])
    }

    @Test func twoSyllablesNearOneLeadSyllableDoNotBothTakeIt() {
        // The nearer one gets it, whichever comes first.
        #expect(SyllableMatch.partners(of: [0.97, 1.005], among: lead([1.0]), within: furthestMove) == [nil, 0])
        #expect(SyllableMatch.partners(of: [0.995, 1.03], among: lead([1.0]), within: furthestMove) == [0, nil])
    }

    @Test func twoSyllablesShareTwoLeadSyllablesInOrderRatherThanOneGoingWithout() {
        // The second is nearer to the first lead syllable than the first is, but taking it would leave the
        // first without a partner. In order, both have one within the limit.
        #expect(SyllableMatch.partners(of: [1.0, 1.03], among: lead([1.02, 1.068]), within: furthestMove) == [0, 1])
    }

    @Test func aSyllableFurtherAwayThanTheLimitHasNoPartner() {
        #expect(SyllableMatch.partners(of: [1.05], among: lead([1.0]), within: furthestMove) == [nil])
        #expect(SyllableMatch.partners(of: [1.03], among: lead([1.0]), within: furthestMove) == [0])
        // The limit is the setting, not a fixed number.
        #expect(SyllableMatch.partners(of: [1.05], among: lead([1.0]), within: 0.06) == [0])
        #expect(SyllableMatch.partners(of: [1.03], among: lead([1.0]), within: 0) == [nil])
    }

    @Test func withoutALeadNobodyHasAPartner() {
        #expect(SyllableMatch.partners(of: [1.0, 1.2], among: [], within: furthestMove) == [nil, nil])
        #expect(SyllableMatch.partners(of: [], among: lead([1.0]), within: furthestMove).isEmpty)
    }

    @Test func noLeadSyllableIsTakenTwiceAndNoPairsCrossInALongLine() {
        // Thirty syllables with small errors, three of them extra, against a lead of twenty-seven.
        var state: UInt64 = 7
        func jitter() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(state >> 40) / Double(1 << 24) - 0.5) * 0.05
        }
        let leadTimes = (0..<27).map { 2 + Double($0) * 0.15 }
        var double = leadTimes.map { $0 + jitter() }
        double += [2.07, 3.13, 4.52]
        double.sort()
        let partners = SyllableMatch.partners(of: double, among: lead(leadTimes), within: furthestMove)
        let taken = partners.compactMap { $0 }
        #expect(taken == taken.sorted())
        #expect(Set(taken).count == taken.count)
        #expect(taken.count == 27)
        for (time, partner) in zip(double, partners) {
            guard let partner else { continue }
            #expect(abs(time - leadTimes[partner]) <= furthestMove)
        }
    }

    // MARK: Where a note ends

    /// Sound all through, one value a millisecond, except for quiet over these milliseconds.
    private func levels(lengthMs: Int, quiet: [Range<Int>]) -> VoiceLevels {
        var values = [Float](repeating: -20, count: lengthMs)
        for stretch in quiet {
            for index in stretch { values[index] = -70 }
        }
        return VoiceLevels(values: values, threshold: -58, hopSamples: 48)
    }

    @Test func aNoteEndsWhereThePauseAfterItStartsOrOnTheNextSyllable() {
        // Syllables at 100, 300 and 700 ms. Quiet from 500 to 650 ms and from 900 ms on.
        let levels = levels(lengthMs: 1_000, quiet: [500..<650, 900..<1_000])
        let ends = SyllableMatch.noteEnds(of: [100 * 48, 300 * 48, 700 * 48], until: 1_000 * 48, levels: levels)
        // The first runs into the second, the second is held to the pause, the third until the sound dies.
        #expect(ends == [300 * 48, 500 * 48, 900 * 48])
    }

    @Test func aNoteWithNothingAfterItEndsWhereTheStretchEnds() {
        let levels = levels(lengthMs: 1_000, quiet: [])
        #expect(SyllableMatch.noteEnds(of: [100 * 48], until: 800 * 48, levels: levels) == [800 * 48])
        #expect(SyllableMatch.noteEnds(of: [], until: 800 * 48, levels: levels).isEmpty)
    }
}

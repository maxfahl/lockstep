import Foundation
import Testing
@testable import LockstepCore

@Suite("LoopInOut")
struct LoopInOutTests {
    /// What is left of a song from 10 s to 90 s.
    private let song: ClosedRange<Double> = 10...90

    @Test func anInWithoutAnOutReachesToTheEndOfTheSong() {
        let marks = LoopInOut().setting(.in, at: 30.25, in: song)
        #expect(marks == LoopInOut(inTime: 30.25))
        #expect(marks?.range(in: song) == 30.25...90)
    }

    @Test func anOutWithoutAnInReachesFromTheStartOfTheSong() {
        let marks = LoopInOut().setting(.out, at: 40, in: song)
        #expect(marks?.range(in: song) == 10...40)
    }

    @Test func theOtherEndStaysWhereItWas() {
        let marks = LoopInOut(inTime: 20, outTime: 60)
        #expect(marks.setting(.out, at: 50.123, in: song) == LoopInOut(inTime: 20, outTime: 50.123))
        #expect(marks.setting(.in, at: 33, in: song) == LoopInOut(inTime: 33, outTime: 60))
    }

    @Test func anEndThatIsPassedIsLetGo() {
        let marks = LoopInOut(inTime: 20, outTime: 60)
        #expect(marks.setting(.in, at: 70, in: song) == LoopInOut(inTime: 70))
        #expect(marks.setting(.out, at: 15, in: song) == LoopInOut(outTime: 15))
        // Reaching it is passing it: nothing would be left between them.
        #expect(marks.setting(.in, at: 60, in: song) == LoopInOut(inTime: 60))
    }

    @Test func anEndOutsideTheSongGoesToItsEdge() {
        #expect(LoopInOut().setting(.in, at: 2, in: song) == LoopInOut(inTime: 10))
        #expect(LoopInOut().setting(.out, at: 95, in: song) == LoopInOut(outTime: 90))
    }

    @Test func aPressThatLeavesNothingChangesNothing() {
        #expect(LoopInOut().setting(.in, at: 90, in: song) == nil)
        #expect(LoopInOut().setting(.out, at: 10, in: song) == nil)
        #expect(LoopInOut().setting(.in, at: .nan, in: song) == nil)
    }

    @Test func aCutShortensThem() {
        let marks = LoopInOut(inTime: 20, outTime: 60)
        #expect(marks.kept(inside: 30...90) == LoopInOut(inTime: 30, outTime: 60))
        #expect(marks.kept(inside: 10...50) == LoopInOut(inTime: 20, outTime: 50))
        // A cut that does not reach them leaves them as they are.
        #expect(marks.kept(inside: 10...80) == marks)
    }

    @Test func aCutThatLeavesNothingOfThemTakesThemAway() {
        #expect(LoopInOut(inTime: 20, outTime: 60).kept(inside: 60...90) == nil)
        #expect(LoopInOut(inTime: 70).kept(inside: 10...65) == nil)
        #expect(LoopInOut(outTime: 15).kept(inside: 20...90) == nil)
        #expect(LoopInOut().kept(inside: song) == nil)
    }

    @Test func aMissingEndFollowsACut() {
        let marks = LoopInOut(inTime: 40)
        #expect(marks.kept(inside: 10...70) == marks)
        #expect(marks.kept(inside: 10...70)?.range(in: 10...70) == 40...70)
    }
}

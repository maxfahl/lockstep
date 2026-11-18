import Testing
@testable import LockstepCore

@Suite("TimelineScale")
struct TimelineScaleTests {
    /// A three-minute song.
    let song: ClosedRange<Double> = 0...180
    let viewWidth: Double = 1200

    @Test(arguments: [0.0, 1.5, 42.25, 179.9, -3])
    func xAndSecondsAreInverses(seconds: Double) {
        let scale = TimelineScale(pointsPerSecond: 37.5, scrollOffsetSeconds: 12.3)
        #expect(abs(scale.seconds(forX: scale.x(for: seconds)) - seconds) < 1e-9)
        let x = seconds * 10
        #expect(abs(scale.x(for: scale.seconds(forX: x)) - x) < 1e-9)
    }

    @Test func theLeftEdgeIsTheScrollOffset() {
        let scale = TimelineScale(pointsPerSecond: 100, scrollOffsetSeconds: 20)
        #expect(scale.x(for: 20) == 0)
        #expect(scale.x(for: 21) == 100)
        #expect(scale.seconds(forX: 250) == 22.5)
    }

    @Test(arguments: [2.0, 0.5, 1.25, 8])
    func zoomKeepsTheGivenTimeInPlace(factor: Double) {
        var scale = TimelineScale(pointsPerSecond: 20, scrollOffsetSeconds: 30)
        let kept = 52.0
        let before = scale.x(for: kept)
        scale.zoom(by: factor, keepingSeconds: kept, viewWidth: viewWidth)
        #expect(scale.pointsPerSecond == 20 * factor)
        #expect(abs(scale.x(for: kept) - before) < 1e-9)
    }

    @Test func zoomStopsAtFiveHundredPointsPerSecond() {
        var scale = TimelineScale(pointsPerSecond: 300, scrollOffsetSeconds: 10)
        let before = scale.x(for: 11)
        scale.zoom(by: 4, keepingSeconds: 11, viewWidth: viewWidth)
        #expect(scale.pointsPerSecond == 500)
        #expect(abs(scale.x(for: 11) - before) < 1e-9)
    }

    @Test func zoomAroundATimeOffScreenKeepsTheNearestEdge() {
        var scale = TimelineScale(pointsPerSecond: 10, scrollOffsetSeconds: 0)
        // 200 s would sit at x = 2000, right of the 1200-point view.
        scale.zoom(by: 2, keepingSeconds: 200, viewWidth: viewWidth)
        #expect(abs(scale.seconds(forX: viewWidth) - 120) < 1e-9)
    }

    @Test func clampNeverScrollsBeforeTheStart() {
        var scale = TimelineScale(pointsPerSecond: 50, scrollOffsetSeconds: -5)
        scale.clamp(range: song, viewWidth: viewWidth)
        #expect(scale.scrollOffsetSeconds == 0)
    }

    @Test func clampNeverScrollsPastTheEnd() {
        var scale = TimelineScale(pointsPerSecond: 50, scrollOffsetSeconds: 175)
        scale.clamp(range: song, viewWidth: viewWidth)
        // 1200 points at 50 per second show 24 s, so the view ends at 180.
        #expect(scale.scrollOffsetSeconds == 156)
        #expect(scale.seconds(forX: viewWidth) == 180)
    }

    @Test func clampLeavesAPositionInsideTheRangeAlone() {
        var scale = TimelineScale(pointsPerSecond: 50, scrollOffsetSeconds: 60)
        scale.clamp(range: song, viewWidth: viewWidth)
        #expect(scale == TimelineScale(pointsPerSecond: 50, scrollOffsetSeconds: 60))
    }

    @Test func clampNeverZoomsOutPastTheWholeRangeFitting() {
        var scale = TimelineScale(pointsPerSecond: 1, scrollOffsetSeconds: 40)
        scale.clamp(range: song, viewWidth: viewWidth)
        #expect(scale.pointsPerSecond == viewWidth / 180)
        #expect(scale.scrollOffsetSeconds == 0)
        #expect(abs(scale.x(for: 180) - viewWidth) < 1e-9)
    }

    @Test func clampNeverZoomsInPastFiveHundredPointsPerSecond() {
        var scale = TimelineScale(pointsPerSecond: 2000, scrollOffsetSeconds: 10)
        scale.clamp(range: song, viewWidth: viewWidth)
        #expect(scale.pointsPerSecond == 500)
        #expect(scale.scrollOffsetSeconds == 10)
    }

    @Test func aRangeShorterThanTheViewAtTheWidestZoomIsLeftAligned() {
        // Half a second at 500 points per second is 250 points, less than the view.
        var scale = TimelineScale(pointsPerSecond: 100, scrollOffsetSeconds: 3)
        scale.clamp(range: 10...10.5, viewWidth: viewWidth)
        #expect(scale.pointsPerSecond == 500)
        #expect(scale.scrollOffsetSeconds == 10)
        #expect(scale.x(for: 10) == 0)
    }

    @Test func aShortRangeAwayFromTheSongStartWorks() {
        // The takes panel covers only a few seconds in the middle of the song.
        let takes: ClosedRange<Double> = 64...70
        var scale = TimelineScale(pointsPerSecond: 10, scrollOffsetSeconds: 0)
        scale.clamp(range: takes, viewWidth: 600)
        #expect(scale.pointsPerSecond == 100)
        #expect(scale.scrollOffsetSeconds == 64)
        #expect(scale.x(for: 64) == 0)
        #expect(scale.x(for: 70) == 600)

        scale.zoom(by: 2, keepingSeconds: 67, viewWidth: 600)
        #expect(scale.x(for: 67) == 300)
        scale.clamp(range: takes, viewWidth: 600)
        #expect(scale.scrollOffsetSeconds == 65.5)
        #expect(scale.x(for: 67) == 300)
    }
}

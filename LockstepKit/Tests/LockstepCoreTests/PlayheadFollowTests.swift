import Testing
@testable import LockstepCore

@Suite("PlayheadFollow")
struct PlayheadFollowTests {
    /// A three-minute song.
    let song: ClosedRange<Double> = 0...180
    /// 1,200 points at 20 points per second show one minute.
    let viewWidth: Double = 1200
    /// Shows 60 s to 120 s.
    let shown = TimelineScale(pointsPerSecond: 20, scrollOffsetSeconds: 60)

    private func follow(
        playhead: Double,
        isPlaying: Bool = false,
        glideDuration: Double = 0.2,
        showing: TimelineScale? = nil
    ) -> TimelineScale? {
        PlayheadFollow.scale(
            showing: showing ?? shown,
            viewWidth: viewWidth,
            range: song,
            playhead: playhead,
            isPlaying: isPlaying,
            glideDuration: glideDuration
        )
    }

    @Test(arguments: [60.0, 61, 90, 119.5, 120])
    func aPlayheadInViewLeavesTheTimelineWhereItIs(playhead: Double) {
        #expect(follow(playhead: playhead) == nil)
        #expect(follow(playhead: playhead, isPlaying: true) == nil)
    }

    @Test func outToTheLeftItLandsInTheMiddle() throws {
        let target = try #require(follow(playhead: 45))
        #expect(target.pointsPerSecond == 20)
        #expect(abs(target.x(for: 45) - viewWidth / 2) < 1e-9)
    }

    @Test func outToTheRightItLandsInTheMiddle() throws {
        let target = try #require(follow(playhead: 130))
        #expect(target.pointsPerSecond == 20)
        #expect(abs(target.x(for: 130) - viewWidth / 2) < 1e-9)
    }

    @Test func whilePlayingItAimsAtWhereThePlayheadWillBeWhenTheGlideEnds() throws {
        let target = try #require(follow(playhead: 120.01, isPlaying: true, glideDuration: 0.2))
        // The playhead has played on for the length of the glide by then.
        #expect(abs(target.x(for: 120.21) - viewWidth / 2) < 1e-9)
    }

    @Test func whilePlayingWithoutAGlideItAimsAtWhereThePlayheadStands() throws {
        let target = try #require(follow(playhead: 120.01, isPlaying: true, glideDuration: 0))
        #expect(abs(target.x(for: 120.01) - viewWidth / 2) < 1e-9)
    }

    @Test func nearTheStartItStopsAtTheStart() throws {
        // The middle would need the timeline to start 20 s before the song.
        let target = try #require(follow(playhead: 10))
        #expect(target.scrollOffsetSeconds == 0)
        #expect(PlayheadFollow.isInView(10, of: target, viewWidth: viewWidth))
    }

    @Test func nearTheEndItStopsAtTheEnd() throws {
        let target = try #require(follow(playhead: 170, isPlaying: true))
        // The last minute of the song.
        #expect(target.scrollOffsetSeconds == 120)
        #expect(PlayheadFollow.isInView(170, of: target, viewWidth: viewWidth))
    }

    @Test func atItsLimitItStaysWhenThePlayheadIsOutsideTheRange() {
        // The timeline's 00:00 can lie inside the song, with the playhead before it.
        let fromTen: ClosedRange<Double> = 10...180
        let atStart = TimelineScale(pointsPerSecond: 20, scrollOffsetSeconds: 10)
        #expect(PlayheadFollow.scale(
            showing: atStart, viewWidth: viewWidth, range: fromTen,
            playhead: 5, isPlaying: false, glideDuration: 0.2
        ) == nil)
    }

    @Test func aTimelineThatStillFitsTheWholeSongStays() {
        #expect(follow(playhead: 130, showing: TimelineScale(pointsPerSecond: 0)) == nil)
    }
}

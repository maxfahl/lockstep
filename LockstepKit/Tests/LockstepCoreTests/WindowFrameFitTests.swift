import Testing
@testable import LockstepCore

@Suite("WindowFrameFit")
struct WindowFrameFitTests {
    /// The main screen's usable area.
    let main = FrameRect(x: 0, y: 0, width: 1440, height: 860)
    /// A larger screen to the left of and a little below the main one.
    let left = FrameRect(x: -1920, y: -200, width: 1920, height: 1055)

    func fit(_ saved: FrameRect, into screens: [FrameRect],
             minimumWidth: Double = 900, minimumHeight: Double = 592) -> FrameRect? {
        WindowFrameFit.fit(saved, into: screens,
                           minimumWidth: minimumWidth, minimumHeight: minimumHeight)
    }

    @Test func frameInsideAScreenIsUnchanged() {
        let saved = FrameRect(x: 100, y: 100, width: 1200, height: 720)
        #expect(fit(saved, into: [main, left]) == saved)
    }

    @Test func frameInsideAScreenWithNegativeCoordinatesIsUnchanged() {
        let saved = FrameRect(x: -1800, y: -150, width: 1200, height: 720)
        #expect(fit(saved, into: [main, left]) == saved)
    }

    @Test func frameOnAScreenThatIsGoneLandsOnTheRemainingScreen() {
        let saved = FrameRect(x: 2000, y: 50, width: 1200, height: 720)
        #expect(fit(saved, into: [main]) == FrameRect(x: 240, y: 50, width: 1200, height: 720))
    }

    @Test func frameHangingOverTheLeftEdgeMovesByTheOverhang() {
        let saved = FrameRect(x: -30, y: 100, width: 1200, height: 720)
        #expect(fit(saved, into: [main]) == FrameRect(x: 0, y: 100, width: 1200, height: 720))
    }

    @Test func frameHangingOverTheTopEdgeMovesByTheOverhang() {
        let saved = FrameRect(x: 100, y: 200, width: 1200, height: 720)
        #expect(fit(saved, into: [main]) == FrameRect(x: 100, y: 140, width: 1200, height: 720))
    }

    @Test func frameHangingOverTheBottomEdgeOfALowerScreenMovesByTheOverhang() {
        let saved = FrameRect(x: -1800, y: -260, width: 1200, height: 720)
        #expect(fit(saved, into: [left]) == FrameRect(x: -1800, y: -200, width: 1200, height: 720))
    }

    @Test func frameWiderThanTheScreenGetsTheScreensWidth() {
        let saved = FrameRect(x: 0, y: 100, width: 2000, height: 600)
        #expect(fit(saved, into: [main]) == FrameRect(x: 0, y: 100, width: 1440, height: 600))
    }

    @Test func frameTallerThanTheScreenGetsTheScreensHeight() {
        let saved = FrameRect(x: 100, y: 0, width: 1000, height: 1200)
        #expect(fit(saved, into: [main]) == FrameRect(x: 100, y: 0, width: 1000, height: 860))
    }

    @Test func theScreenThatKeepsTheSizeWinsOverANearerOne() {
        // The main screen is nearer but would have to make the window narrower.
        let saved = FrameRect(x: 3000, y: 100, width: 1600, height: 700)
        let far = FrameRect(x: -5000, y: 0, width: 1920, height: 1055)
        #expect(fit(saved, into: [main, far]) == FrameRect(x: -4680, y: 100, width: 1600, height: 700))
    }

    @Test func withEqualSizeTheNearerScreenWins() {
        let saved = FrameRect(x: 1300, y: 100, width: 1000, height: 600)
        let right = FrameRect(x: 1500, y: 0, width: 1440, height: 860)
        // 860 to the left onto the main screen, or 200 to the right onto the other.
        #expect(fit(saved, into: [main, right]) == FrameRect(x: 1500, y: 100, width: 1000, height: 600))
    }

    @Test func withEqualSizeAndDistanceTheFirstScreenWins() {
        let saved = FrameRect(x: 970, y: 100, width: 1000, height: 600)
        let right = FrameRect(x: 1500, y: 0, width: 1440, height: 860)
        // 530 either way.
        #expect(fit(saved, into: [main, right]) == FrameRect(x: 440, y: 100, width: 1000, height: 600))
        #expect(fit(saved, into: [right, main]) == FrameRect(x: 1500, y: 100, width: 1000, height: 600))
    }

    @Test func screenSmallerThanTheMinimumGivesTheMinimumAtItsLeftAndTopEdges() {
        let small = FrameRect(x: 0, y: 0, width: 800, height: 500)
        let saved = FrameRect(x: 100, y: 100, width: 1200, height: 720)
        let fitted = fit(saved, into: [small])
        #expect(fitted == FrameRect(x: 0, y: -92, width: 900, height: 592))
        // The top edge is the screen's top edge.
        #expect(fitted.map { $0.y + $0.height } == 500)
    }

    @Test func noScreensGivesNil() {
        let saved = FrameRect(x: 100, y: 100, width: 1200, height: 720)
        #expect(fit(saved, into: []) == nil)
    }
}

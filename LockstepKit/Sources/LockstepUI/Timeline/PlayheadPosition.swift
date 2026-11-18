import LockstepCore
import Observation
import SwiftUI

/// Where the playhead is, in song seconds. The owner of playback changes
/// `seconds` (many times a second while playing) and every timeline on screen
/// is handed the same object, so they all show the same playhead.
///
/// Only the timeline's small playhead view reads `seconds`. Do not read it in
/// a view that holds a timeline or in a lane: that view would then be worked
/// out again on every frame of playback.
@MainActor
@Observable
public final class PlayheadPosition {
    /// Song seconds.
    public var seconds: Double
    /// How long it is until the song starts, in seconds, while a count-in that began
    /// before the song is being played: before its first sample, or before the start
    /// of what is left of it when its beginning is cut away. The playhead then waits
    /// at that start (`seconds`) and the time readout shows the time the count-in
    /// has reached, with a minus sign while that is before 00:00.
    /// Zero at every other time, and then nothing is shown differently.
    public var secondsBeforeSong: Double = 0
    /// Which moment of the song stands at the timeline's 00:00. The time
    /// readout shows the playhead's time counted from there. The playhead
    /// itself stands at `seconds`, which stays song seconds.
    public var place = SongPlace()

    public init(seconds: Double = 0) {
        self.seconds = seconds
    }
}

/// The playhead: a line through the ruler and all rows, with a small head in
/// the ruler. This is the only view of a timeline that reads the position, so
/// it is the only one that is worked out again while the song plays.
struct TimelinePlayheadView: View {
    @Environment(\.timelinePalette) private var palette

    let position: PlayheadPosition
    let scale: TimelineScale
    /// The width of the lane bodies. The playhead is hidden outside it.
    let width: CGFloat
    /// The height of the ruler above the rows, or nil when there is no ruler.
    /// The head sits at the bottom of the ruler; without a ruler there is no head.
    let rulerHeight: CGFloat?

    var body: some View {
        let x = CGFloat(scale.x(for: position.seconds))
        let headWidth = DesignTokens.Sizes.playheadHeadWidth
        let headHeight = DesignTokens.Sizes.playheadHeadHeight
        // Outside the lane bodies the playhead is made invisible, not taken
        // away: taking it out of the window and putting it back, as it leaves
        // the screen and comes back while the timeline is dragged, held the
        // window still for a fifth of a second each time.
        let isShown = x >= 0 && x <= width
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                if rulerHeight != nil {
                    PlayheadHead()
                        .fill(palette.playhead)
                        .frame(width: headWidth, height: headHeight)
                }
                Rectangle()
                    .fill(palette.playhead)
                    .frame(width: DesignTokens.Lines.playheadWidth)
            }
            .frame(width: headWidth)
            .padding(.top, rulerHeight.map { max($0 - headHeight, 0) } ?? 0)
            .offset(x: isShown ? x - headWidth / 2 : 0)
            .opacity(isShown ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// The head of the playhead: a small triangle that points down at the line.
private struct PlayheadHead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

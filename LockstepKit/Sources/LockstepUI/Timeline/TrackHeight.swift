import Foundation

/// The height of the vocal track rows of the main timeline, in points. All
/// track rows have the same height, and it can be changed: Shift and scroll
/// over the timeline, or a step at a time from a menu.
///
///     @State private var trackHeight = TrackHeight.standard
///
///     MainTimeline(content: content, scale: $scale, trackHeight: $trackHeight, playhead: playhead)
///
///     trackHeight = TrackHeight.stepped(trackHeight, taller: true)   // a menu command
///
/// The height is kept as it was worked out, with its fraction, so that slow
/// scrolling adds up. The rows are drawn at the nearest whole point
/// (`TrackHeight.shown(_:)`).
public enum TrackHeight {
    /// The height the rows start with.
    public static let standard = DesignTokens.Sizes.trackLaneHeight

    /// The lowest and the tallest the rows can be made.
    public static let range = DesignTokens.Sizes.trackLaneMinimumHeight...DesignTokens.Sizes.trackLaneMaximumHeight

    /// How much one step from a menu changes the height. Two steps halve or
    /// double it, so the steps from the starting height end exactly on the
    /// lowest and the tallest height.
    private static let step = CGFloat(2).squareRoot()

    /// How much scrolling one point changes the height: 1 % of what it is.
    private static let growthPerScrolledPoint: CGFloat = 0.01

    /// The height after scrolling this many points with Shift held: positive
    /// makes the rows taller, negative lower. It grows by a share of what it
    /// is, so the scrolling feels the same on low rows and on tall ones.
    public static func scrolled(_ height: CGFloat, by points: CGFloat) -> CGFloat {
        clamped(height * exp(points * growthPerScrolledPoint))
    }

    /// The height one step taller or lower.
    public static func stepped(_ height: CGFloat, taller: Bool) -> CGFloat {
        let stepped = clamped(taller ? height * step : height / step)
        // The ends are reached exactly, so a menu can tell that no step is left.
        if abs(stepped - range.lowerBound) < 0.5 { return range.lowerBound }
        if abs(stepped - range.upperBound) < 0.5 { return range.upperBound }
        return stepped
    }

    /// The height kept between the lowest and the tallest.
    public static func clamped(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return standard }
        return min(max(height, range.lowerBound), range.upperBound)
    }

    /// The height the rows are drawn with: on a whole point, so their edges
    /// are sharp.
    public static func shown(_ height: CGFloat) -> CGFloat {
        clamped(height).rounded()
    }
}

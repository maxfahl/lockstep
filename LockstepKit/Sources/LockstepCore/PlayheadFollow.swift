/// The one rule for following the playhead: when the playhead is outside what
/// the timeline shows, to the left or to the right, the timeline goes to where
/// the playhead stands in the middle of its width. A playhead that is in view
/// leaves the timeline where it is.
///
///     if let target = PlayheadFollow.scale(
///         showing: scale, viewWidth: 1200, range: 0...180,
///         playhead: 95, isPlaying: true, glideDuration: 0.2
///     ) {
///         // glide to `target` over 0.2 seconds
///     }
///
/// It keeps nothing: everything it needs is handed in.
public enum PlayheadFollow {
    /// Whether a place in the song is inside what the timeline shows. A place
    /// exactly on the left or the right edge is in view.
    ///
    /// - Parameters:
    ///   - seconds: The place, in song seconds.
    ///   - shown: What the timeline shows.
    ///   - viewWidth: The width of the timeline's rows, in points.
    public static func isInView(_ seconds: Double, of shown: TimelineScale, viewWidth: Double) -> Bool {
        let x = shown.x(for: seconds)
        return x >= 0 && x <= viewWidth
    }

    /// Where the timeline goes so that the playhead stands in the middle of
    /// its width, or nil when the timeline stays where it is: the playhead is
    /// in view, or the timeline is already as near as its limits let it come.
    ///
    /// While the song plays, the playhead goes on during the glide, one song
    /// second per second. The glide is then aimed at where the playhead will
    /// be when it ends, so the playhead stands in the middle at that moment. A
    /// glide of no length (animations turned off) aims at where it stands now.
    ///
    /// Near the start and the end of the range the middle cannot be reached.
    /// The timeline then stops at its limit.
    ///
    /// - Parameters:
    ///   - shown: What the timeline shows, or what it will show once a move
    ///     under way is over. The zoom is kept.
    ///   - viewWidth: The width of the timeline's rows, in points.
    ///   - range: The song seconds the timeline can show.
    ///   - playhead: Where the playhead stands, in song seconds.
    ///   - isPlaying: Whether the playhead moves on while the timeline glides.
    ///   - glideDuration: How long the glide takes, in seconds.
    public static func scale(
        showing shown: TimelineScale,
        viewWidth: Double,
        range: ClosedRange<Double>,
        playhead: Double,
        isPlaying: Bool,
        glideDuration: Double
    ) -> TimelineScale? {
        // A scale without a zoom still means "fit the whole range": all of it is in view.
        guard viewWidth > 0, shown.pointsPerSecond.isFinite, shown.pointsPerSecond > 0 else { return nil }
        guard !isInView(playhead, of: shown, viewWidth: viewWidth) else { return nil }
        // The playhead never plays past the end of the range.
        let ahead = isPlaying ? max(glideDuration, 0) : 0
        let landing = min(playhead + ahead, max(range.upperBound, playhead))
        var target = shown
        target.scrollOffsetSeconds = landing - viewWidth / 2 / shown.pointsPerSecond
        target.clamp(range: range, viewWidth: viewWidth)
        return target == shown ? nil : target
    }
}

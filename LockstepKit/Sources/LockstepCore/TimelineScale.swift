/// Converts between song seconds and horizontal points on a timeline.
///
/// x = 0 is the left edge of the lanes. The scale knows nothing about songs:
/// it works for any time range, such as a whole song or a few seconds of takes.
public struct TimelineScale: Sendable, Equatable {
    /// The closest zoom: 2 ms per point.
    public static let maximumPointsPerSecond: Double = 500

    public var pointsPerSecond: Double
    /// Song time at the left edge of the lanes.
    public var scrollOffsetSeconds: Double

    public init(pointsPerSecond: Double, scrollOffsetSeconds: Double = 0) {
        self.pointsPerSecond = pointsPerSecond
        self.scrollOffsetSeconds = scrollOffsetSeconds
    }

    public func x(for seconds: Double) -> Double {
        (seconds - scrollOffsetSeconds) * pointsPerSecond
    }

    public func seconds(forX x: Double) -> Double {
        scrollOffsetSeconds + x / pointsPerSecond
    }

    /// Multiplies the zoom by `factor` and keeps `keepingSeconds` at the x it had.
    ///
    /// When that time is outside the view, the nearest view edge is kept in place
    /// instead, so zooming never throws the view far away. The zoom never goes
    /// closer than `maximumPointsPerSecond`; the range limits come from `clamp`.
    public mutating func zoom(by factor: Double, keepingSeconds: Double, viewWidth: Double) {
        guard factor.isFinite, factor > 0 else { return }
        let anchorX = min(max(x(for: keepingSeconds), 0), max(viewWidth, 0))
        let anchorSeconds = seconds(forX: anchorX)
        pointsPerSecond = min(pointsPerSecond * factor, Self.maximumPointsPerSecond)
        scrollOffsetSeconds = anchorSeconds - anchorX / pointsPerSecond
    }

    /// Keeps the zoom and the scroll position inside `range`.
    ///
    /// The widest zoom shows the whole range across `viewWidth`, the closest is
    /// `maximumPointsPerSecond`. A range that is still narrower than the view at
    /// the closest zoom starts at the left edge.
    public mutating func clamp(range: ClosedRange<Double>, viewWidth: Double) {
        let width = max(viewWidth, 0)
        let duration = range.upperBound - range.lowerBound
        let widest = duration > 0
            ? min(width / duration, Self.maximumPointsPerSecond)
            : Self.maximumPointsPerSecond

        if pointsPerSecond.isFinite, pointsPerSecond > 0 {
            pointsPerSecond = min(max(pointsPerSecond, widest), Self.maximumPointsPerSecond)
        } else {
            pointsPerSecond = widest
        }
        // A zero-width view of a zero-length range has nothing to show.
        guard pointsPerSecond > 0 else {
            scrollOffsetSeconds = range.lowerBound
            return
        }

        let lastOffset = range.upperBound - width / pointsPerSecond
        if lastOffset <= range.lowerBound || !scrollOffsetSeconds.isFinite {
            scrollOffsetSeconds = range.lowerBound
        } else {
            scrollOffsetSeconds = min(max(scrollOffsetSeconds, range.lowerBound), lastOffset)
        }
    }
}

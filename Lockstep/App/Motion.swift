import AppKit
import LockstepCore

/// How long the app's own animations take: a zoom from the menu, the timeline gliding to
/// the playhead, and later a clip that appears. The system's animations (popovers, sheets) are not asked
/// about here and stay as macOS makes them.
///
///     let seconds = Motion.duration(settings)   // 0.2, 0.1 or 0
///
/// Zero means "no animation: show the result at once".
@MainActor
enum Motion {
    /// How long an animation takes at normal speed, in seconds.
    static let baseDuration = 0.2

    /// The length of an animation right now: the base length times the animation speed
    /// from Settings (normal 1, fast 0.5, off 0). When the Mac has Reduce Motion on, it
    /// is zero whatever the setting says.
    static func duration(_ settings: AppSettings) -> Double {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return 0 }
        return baseDuration * settings[.animationSpeed].factor
    }
}

/// The timeline on its way from one zoom and scroll position to another.
///
///     let glide = ScaleGlide(from: scale, to: zoomed, startedAt: CACurrentMediaTime(), duration: 0.2)
///     scale = glide.scale(at: CACurrentMediaTime())   // once per frame, until `isOver`
///
/// It starts and ends gently. A change of zoom goes around the one moment of the song
/// that stands at the same place before and after, so that moment never moves on the
/// way: for a zoom from the menu that is the playhead.
struct ScaleGlide {
    let from: TimelineScale
    let to: TimelineScale
    /// On the clock of `CACurrentMediaTime()`.
    let startedAt: Double
    /// Seconds.
    let duration: Double

    func isOver(at time: Double) -> Bool {
        time - startedAt >= duration
    }

    func scale(at time: Double) -> TimelineScale {
        guard !isOver(at: time), from.pointsPerSecond > 0, to.pointsPerSecond > 0 else { return to }
        let part = max((time - startedAt) / duration, 0)
        let eased = part * part * (3 - 2 * part)
        let zoom = to.pointsPerSecond / from.pointsPerSecond
        guard abs(zoom - 1) > 1e-6 else {
            // The zoom stays: the timeline only moves sideways.
            let moved = from.scrollOffsetSeconds + (to.scrollOffsetSeconds - from.scrollOffsetSeconds) * eased
            return TimelineScale(pointsPerSecond: to.pointsPerSecond, scrollOffsetSeconds: moved)
        }
        let stillSeconds = (from.scrollOffsetSeconds * from.pointsPerSecond - to.scrollOffsetSeconds * to.pointsPerSecond)
            / (from.pointsPerSecond - to.pointsPerSecond)
        let stillX = from.x(for: stillSeconds)
        let pointsPerSecond = from.pointsPerSecond * pow(zoom, eased)
        return TimelineScale(
            pointsPerSecond: pointsPerSecond,
            scrollOffsetSeconds: stillSeconds - stillX / pointsPerSecond
        )
    }
}

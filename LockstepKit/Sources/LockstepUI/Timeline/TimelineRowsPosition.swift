import Observation
import SwiftUI

/// How far the rows of a timeline that scroll up and down are scrolled, for an owner
/// that keeps it, such as the app keeping the view of a project across a restart.
///
///     let rows = TimelineRowsPosition()
///     MainTimeline(...).keepsRowsPosition(rows)
///
///     rows.y                 // how far they are scrolled now, in points
///     rows.scroll(to: 240)   // once the rows are on screen, they are scrolled there
///
/// The timeline writes `y` as the rows scroll; reading it draws nothing again. A place
/// asked for with `scroll(to:)` is reached the next time the timeline lays its rows
/// out, so it can be asked for before the rows of a newly opened project are there. A
/// place further down than the rows reach goes as far down as they do.
@MainActor
@Observable
public final class TimelineRowsPosition {
    /// How far the rows are scrolled down now, in points. Zero with the first row at the top.
    @ObservationIgnored public internal(set) var y: CGFloat = 0
    /// The place asked for that the timeline has not scrolled to yet.
    var requestedY: CGFloat?

    public init() {}

    /// Scrolls the rows down to `y` points, as soon as the timeline can.
    public func scroll(to y: CGFloat) {
        requestedY = y.isFinite ? max(y, 0) : 0
    }
}

import AppKit
import QuartzCore
import SwiftUI

/// What scrolling over a timeline, or dragging it with the middle mouse
/// button, asks for. The keys held while scrolling decide, the way they do on
/// the Fairlight page of DaVinci Resolve.
enum TimelineScroll: Equatable {
    /// Move along the song by this many points: positive moves the rows to
    /// the right, towards the start of the song. Two fingers moved sideways,
    /// or any scrolling with Command held.
    case sideways(CGFloat)
    /// Zoom in time around the pointer, with Option held: how far was
    /// scrolled, in points, positive to zoom in, and the x of the pointer in
    /// the catcher's own coordinates.
    case zoom(CGFloat, atX: CGFloat)
    /// Make the rows taller or lower, with Shift held: how far was scrolled,
    /// in points, positive for taller.
    case rowHeight(CGFloat)
    /// Move what the timeline shows by as far as the pointer moved with the
    /// middle mouse button held, in points: a positive width moves the rows
    /// to the right, towards the start of the song, and a positive height
    /// moves them down. `isFirst` is true for the first move after the button
    /// went down.
    case dragged(by: CGSize, isFirst: Bool)
}

/// Hears scrolling while the pointer is over the view it lies behind, and
/// a drag with the middle mouse button that starts over it. SwiftUI has no way
/// of its own to hear scrolling outside a scroll view, and its gestures hear
/// only the left button, so this listens to the app's events.
///
///     someView.background {
///         TimelineScrollCatcher(takesRowHeight: true) { scroll in ... }
///     }
///
/// What it takes, so that nothing else gets it:
/// - scrolling that goes more sideways than up or down, with no key held
///   (`sideways`). Plain scrolling up or down is left alone, so a scroll view
///   under the pointer still gets it;
/// - any scrolling with Command held (`sideways`), so a mouse wheel can move
///   along the song;
/// - any scrolling with Option held (`zoom`);
/// - any scrolling with Shift held (`rowHeight`), when `takesRowHeight` is
///   on. macOS turns a mouse wheel's up and down into sideways while Shift is
///   held, so both directions are read. Without `takesRowHeight` Shift is
///   like no key.
///
/// For a zoom and a row height, up is more: fingers or a wheel moved up, away
/// from Max, zoom in and make the rows taller, whichever way the Mac is set
/// to scroll. The glide that follows a flick on the trackpad moves along the
/// song but does not go on zooming.
///
/// The middle mouse button: a press over this view and everything the button
/// does until it is let go is taken, so nothing under the pointer reacts. Every
/// move of the pointer meanwhile is reported as `dragged`, also when the
/// pointer has left the view. A press that is let go without a move reports
/// nothing.
///
/// It draws nothing and takes no clicks of the left or the right button.
struct TimelineScrollCatcher: NSViewRepresentable {
    /// Whether scrolling with Shift held is reported as `rowHeight`.
    var takesRowHeight = false
    let onScroll: (TimelineScroll) -> Void

    func makeNSView(context: Context) -> TimelineScrollView {
        TimelineScrollView()
    }

    func updateNSView(_ view: TimelineScrollView, context: Context) {
        view.takesRowHeight = takesRowHeight
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: TimelineScrollView, coordinator: ()) {
        view.stopListening()
    }
}

final class TimelineScrollView: NSView {
    var takesRowHeight = false
    var onScroll: ((TimelineScroll) -> Void)?

    /// What AppKit gave back when the listening started, needed to stop it.
    private var monitor: Any?

    /// What the keys held asked for when the fingers last moved. The glide
    /// after a flick is the same scrolling still, whatever is held by then.
    private var lastKind = Kind.plain

    /// Where the pointer was when the drag with the middle button was last
    /// heard of, on the screen. Nil while that button is not held from a press
    /// over this view.
    private var dragLocation: NSPoint?
    /// Whether the pointer has moved since the middle button went down.
    private var dragHasMoved = false
    /// How far the pointer has moved with the middle button held since the
    /// timeline was last told, and what tells it once per display frame.
    private var waitingDrag = CGSize.zero
    private var dragFrames: CADisplayLink?

    /// The number AppKit gives the middle mouse button.
    private static let middleButton = 2

    /// What scrolling means with the keys that are held.
    private enum Kind {
        /// No key: sideways moves along the song, up and down is left alone.
        case plain
        /// Command: every direction moves along the song.
        case along
        /// Option.
        case zoom
        /// Shift.
        case rowHeight
    }

    /// A mouse wheel without a trackpad's fine steps reports lines. One line
    /// counts as this many points.
    private static let pointsPerLine: CGFloat = 10

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopListening()
        guard window != nil else { return }
        Self.live.add(self)
        // AppKit calls this on the main thread, before the event reaches any view.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .otherMouseDown, .otherMouseDragged, .otherMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            let isTaken = event.type == .scrollWheel ? self.take(event) : self.takeMiddleButton(event)
            return isTaken ? nil : event
        }
    }

    func stopListening() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        dragLocation = nil
        stopDragFrames()
    }

    /// Clicks go to the SwiftUI views in front of this one.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Passes scrolling over this view on, and says whether it did.
    private func take(_ event: NSEvent) -> Bool {
        guard let onScroll, let window, event.window === window else { return false }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return false }

        let isGlide = !event.momentumPhase.isEmpty
        if !isGlide {
            lastKind = kind(for: event.modifierFlags)
        }
        let unit = event.hasPreciseScrollingDeltas ? 1 : Self.pointsPerLine
        let sideways = event.scrollingDeltaX * unit
        let upOrDown = event.scrollingDeltaY * unit
        // With a key held, whichever direction was scrolled the most counts.
        let most = abs(sideways) > abs(upOrDown) ? sideways : upOrDown

        switch lastKind {
        case .plain:
            guard abs(sideways) > abs(upOrDown) else { return false }
            onScroll(.sideways(sideways))
        case .along:
            // An event that moved nothing only says that the fingers came
            // down or were lifted. A scroll view under the pointer may need it.
            guard most != 0 else { return false }
            onScroll(.sideways(most))
        case .zoom, .rowHeight:
            // The glide is kept from the scroll view, and does nothing here.
            guard !isGlide else { return true }
            guard most != 0 else { return false }
            // As the fingers or the wheel moved, not as the content would:
            // up is more, also on a Mac set to scroll the other way.
            let up = event.isDirectionInvertedFromDevice ? -most : most
            onScroll(lastKind == .zoom ? .zoom(up, atX: location.x) : .rowHeight(up))
        }
        return true
    }

    /// Follows the middle mouse button from a press over this view until it
    /// is let go, passes every move of the pointer on, and says whether the
    /// event was taken.
    private func takeMiddleButton(_ event: NSEvent) -> Bool {
        guard event.buttonNumber == Self.middleButton else { return false }
        return takeMiddleButton(event.type, in: event.window, at: event.locationInWindow)
    }

    /// What `takeMiddleButton(_:)` does with an event of the middle button, from
    /// what the event says: its kind, its window and where in that window the
    /// pointer was. `TimelineMiddleDrag` comes in here too.
    fileprivate func takeMiddleButton(
        _ type: NSEvent.EventType, in eventWindow: NSWindow?, at locationInWindow: NSPoint
    ) -> Bool {
        // On the screen, because the pointer may leave the window on the way.
        let location = eventWindow?.convertPoint(toScreen: locationInWindow) ?? locationInWindow
        switch type {
        case .otherMouseDown:
            dragLocation = nil
            guard onScroll != nil, let window, eventWindow === window,
                  bounds.contains(convert(locationInWindow, from: nil))
            else { return false }
            dragLocation = location
            dragHasMoved = false
            return true
        case .otherMouseDragged:
            guard let last = dragLocation else { return false }
            dragLocation = location
            // The screen's y grows upwards, the rows' downwards.
            let moved = CGSize(width: location.x - last.x, height: last.y - location.y)
            guard moved != .zero else { return true }
            // A mouse reports its moves up to a thousand times a second, far
            // more often than the screen shows a picture, and every move told
            // to the timeline makes it work itself out again. So the moves are
            // added up and told once per frame of the display, the way two
            // fingers on the trackpad are reported.
            waitingDrag.width += moved.width
            waitingDrag.height += moved.height
            startDragFrames()
            return true
        case .otherMouseUp:
            guard dragLocation != nil else { return false }
            dragLocation = nil
            // The last moves before the button was let go still count.
            tellWaitingDrag()
            stopDragFrames()
            return true
        default:
            return false
        }
    }

    /// Tells the timeline how far the pointer moved since it was last told.
    private func tellWaitingDrag() {
        guard waitingDrag != .zero else { return }
        let moved = waitingDrag
        waitingDrag = .zero
        onScroll?(.dragged(by: moved, isFirst: !dragHasMoved))
        dragHasMoved = true
        TimelineMiddleDrag.timelineWasTold?()
    }

    /// Calls `dragFrame` once per frame of the display the view is on, from
    /// the next frame on, while the middle button is held.
    private func startDragFrames() {
        guard dragFrames == nil else { return }
        let link = displayLink(target: self, selector: #selector(dragFrame(_:)))
        link.add(to: .main, forMode: .common)
        dragFrames = link
    }

    private func stopDragFrames() {
        dragFrames?.invalidate()
        dragFrames = nil
        waitingDrag = .zero
    }

    @objc private func dragFrame(_ link: CADisplayLink) {
        guard dragLocation != nil else { return stopDragFrames() }
        tellWaitingDrag()
    }

    /// Every catcher that is in a window, for `TimelineMiddleDrag`.
    fileprivate static let live = NSHashTable<TimelineScrollView>.weakObjects()

    private func kind(for flags: NSEvent.ModifierFlags) -> Kind {
        let held = flags.intersection([.command, .option, .shift, .control])
        if held == .option { return .zoom }
        if held == .command { return .along }
        if held == .shift, takesRowHeight { return .rowHeight }
        return .plain
    }
}

/// A drag with the middle mouse button, or two fingers moved sideways, handed
/// to the widest timeline in the key window as if they came from the mouse or
/// the trackpad, for a run that measures how the timeline keeps up (Lockstep's
/// `-middleDrag`): an agent cannot move the pointer.
///
/// The drag goes through the same code as the events of the button, from where
/// the catcher has read them on. The press is in the middle of the timeline.
///
///     guard TimelineMiddleDrag.press() else { return }
///     TimelineMiddleDrag.move(by: CGSize(width: -3, height: 0))
///     TimelineMiddleDrag.release()
@MainActor
public enum TimelineMiddleDrag {
    /// The catcher the drag going on was pressed on, and where the pointer is
    /// in its window.
    private static var dragged: (view: TimelineScrollView, location: NSPoint)?

    /// Called every time a timeline was told how far the middle button was
    /// dragged, which is once per frame of the display at most, whether the
    /// drag came from the mouse or from here. For measuring; nil otherwise.
    public static var timelineWasTold: (() -> Void)?

    /// The middle button goes down in the middle of the widest timeline that
    /// listens for it. False when there is none in the key window, or none that took it.
    public static func press() -> Bool {
        dragged = nil
        guard let view = widest() else { return false }
        let middle = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard view.takeMiddleButton(.otherMouseDown, in: view.window, at: middle) else { return false }
        dragged = (view, middle)
        return true
    }

    /// The pointer moves with the button held: a positive width to the right, a
    /// positive height down, as in `TimelineScroll.dragged`.
    public static func move(by distance: CGSize) {
        guard var drag = dragged else { return }
        // A window's y grows upwards.
        drag.location.x += distance.width
        drag.location.y -= distance.height
        dragged = drag
        _ = drag.view.takeMiddleButton(.otherMouseDragged, in: drag.view.window, at: drag.location)
    }

    /// The button is let go.
    public static func release() {
        guard let drag = dragged else { return }
        dragged = nil
        _ = drag.view.takeMiddleButton(.otherMouseUp, in: drag.view.window, at: drag.location)
    }

    /// Two fingers moved sideways on the trackpad, over the same timeline:
    /// what the catcher reports for such scrolling. A positive distance moves
    /// the rows to the right. False when there is no timeline that listens.
    public static func scroll(sideways points: CGFloat) -> Bool {
        guard let view = widest(), let onScroll = view.onScroll else { return false }
        onScroll(.sideways(points))
        return true
    }

    private static func widest() -> TimelineScrollView? {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
        return TimelineScrollView.live.allObjects
            .filter { $0.window != nil && $0.window === window && $0.onScroll != nil }
            .max { $0.bounds.width < $1.bounds.width }
    }
}


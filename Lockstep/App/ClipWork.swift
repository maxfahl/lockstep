import AppKit
import LockstepCore
import LockstepUI

/// What the model keeps while a clip is dragged by its bar, while a clip's name is
/// typed, and while a stretch of a track is marked by dragging. The functions that use
/// it are in `ClipEditingModel+Moves.swift` and `ClipEditingModel.swift`.
///
/// It is an object of its own, and nothing in the window watches it: the window is
/// drawn from `WindowState.content`, which those functions change.
@MainActor
final class ClipWork {
    /// The drag that is going on, or nil.
    var drag: ClipDrag?
    /// What the window last said about the drag that is going on.
    var lastReport: ClipBarDrag?
    /// A drag that was given up while the button was still down: with Escape, or because
    /// it could not start. What the window goes on saying about it is not listened to.
    var givenUp: ClipBarDrag?
    /// Shift was held the last time the drag was worked out.
    var locksTime = false

    /// Runs once per display frame while a clip is dragged: the timeline scrolls when the
    /// pointer rests near its edge, and Shift is noticed without the pointer moving.
    let frames = FrameTicker()
    /// When the last frame came, on the clock of `CACurrentMediaTime()`.
    var lastFrameAt: Double?
    /// Hears Escape while a clip is dragged.
    let escape = EscapeWatch()

    /// The clip whose name is being typed in its bar, or nil.
    var renamedClipID: UUID?

    // Trimming a clip by one of its edges. The functions that use these are in
    // `ClipEditingModel+Trims.swift`. `escape` above hears Escape for this drag too: only one
    // drag goes on at a time.

    /// The drag of an edge that is going on, or nil.
    var trim: ClipTrim?
    /// What the window last said about that drag.
    var trimReport: ClipEdgeDrag?
    /// A drag of an edge that was given up while the button was still down: with Escape, or
    /// because it could not start. What the window goes on saying about it is not listened to.
    var trimGivenUp: ClipEdgeDrag?
    /// Runs once per display frame while an edge is dragged: the timeline scrolls when the
    /// pointer rests near its edge.
    let trimFrames = FrameTicker()
    /// When the last of those frames came, on the clock of `CACurrentMediaTime()`.
    var trimLastFrameAt: Double?

    // Marking a stretch by dragging across a track's row. The functions that use these
    // are in `ClipEditingModel.swift`.

    /// What the window last said about the stretch that is being marked, or nil when none is.
    var stretchReport: StretchDrag?
    /// A marking that was given up while the button was still down: with Escape, or
    /// because it could not start. What the window goes on saying about it is not listened to.
    var stretchGivenUp: StretchDrag?
    /// The clip the marked stretch belongs to, when it is the stretch of one of that clip's effects whose
    /// row in the panel was clicked. Such a stretch stays while that clip alone is selected. Nil for a
    /// stretch that was marked by dragging, which never stays with a selected clip.
    var stretchClipID: UUID?
    /// Runs once per display frame while a stretch is marked: the timeline scrolls when
    /// the pointer rests near its edge.
    let stretchFrames = FrameTicker()
    /// When the last of those frames came, on the clock of `CACurrentMediaTime()`.
    var stretchLastFrameAt: Double?
    /// The clips that were selected when the drag that is going on started. A stretch empties the selected
    /// clips and a rectangle selects its own, so this is what a rectangle started with Shift adds to.
    var stretchSelectedBefore: Set<UUID> = []
    /// Shift was held when the drag that is going on started: a rectangle adds to what was selected.
    var stretchAddsToSelection = false
    /// The rectangle the drag is right now, with the clips it selects, while the pointer is in another
    /// track's row. Nil while the drag is a stretch, and when no drag is going on.
    var stretchRectangle: SelectionDrag.Rectangle?
    /// True once the drag that is going on has been a stretch at its last report.
    var stretchIsMarking = false
    /// The lookup table of the project, kept for the drag that is going on, so a move of the pointer
    /// searches none of the project's lists. Made again when the project's tracks or recordings change.
    var stretchLookup: ProjectLookup?
    /// For the line a finished rectangle writes to the log: how many times it was worked out, how many of
    /// those changed which clips are selected, and how long the slowest of them took, in seconds.
    var rectangleMoves = 0
    var rectangleReselections = 0
    var rectangleSlowestMove = 0.0
    /// The time stamp of the mouse event that ended the last marking. The same release
    /// can also arrive as a click, and that click must not clear what was just marked.
    var stretchEndEventTime: TimeInterval?

    /// Where the playhead stood when `ClipEditingModel.refreshSplitAtPlayhead` last looked, in song
    /// seconds. A clip's right-click menu reads this and not the playhead itself, so the
    /// menus of the clips are not worked out again on every frame while the song plays.
    var playheadSeconds = 0.0
}

/// Hears the Escape key while it is running, before anything else in the app gets it,
/// and keeps it: a menu command or a popover that also acts on Escape does not.
///
///     watch.onEscape = { giveUpTheDrag() }
///     watch.start()
///     ...
///     watch.stop()
@MainActor
final class EscapeWatch {
    var onEscape: (() -> Void)?

    /// What AppKit gave back when the listening started, needed to stop it.
    private var monitor: Any?

    /// The number of the Escape key on every Mac keyboard.
    private static let escapeKeyCode: UInt16 = 53

    func start() {
        guard monitor == nil else { return }
        // AppKit calls this on the main thread, before the key reaches a window.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode, let onEscape = self?.onEscape else { return event }
            onEscape()
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

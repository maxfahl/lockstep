import AppKit

// Holding Command turns snapping the other way for as long as it is held (`SnapKey` in LockstepCore).
// The places that snap ask the timeline's view (`TimelineViewModel`):
//
//     snappingHolds        moving a clip, an Option-drag copy, the playhead, the song's edges
//     snapTolerance        moving a clip and trimming an edge, as the snap distance in seconds
//
// Both are read at every movement. Pressing or letting go of Command moves no pointer, so `SnapKeyWatch`
// hears it and whatever is being dragged follows at once (`followSnappingDrags` on `AppModel`), as it does
// when N switches the setting in the middle of a drag. A click (Command-click on a clip adds it to the
// selection) is not a drag and is not touched.

/// Hears Command go down and come up, and hands the change on. The key itself goes on to the window
/// untouched.
@MainActor
final class SnapKeyWatch {
    static let app = SnapKeyWatch()

    /// Told when Command was pressed or let go.
    var onChange: (() -> Void)?

    /// What AppKit gave back when the listening started.
    private var monitor: Any?
    /// Whether Command was held at the last change of the modifier keys.
    private var commandHeld = false

    func start() {
        guard monitor == nil else { return }
        // AppKit calls this on the main thread, before the change reaches a window.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.contains(.command)
            if let self, held != commandHeld {
                commandHeld = held
                onChange?()
            }
            return event
        }
    }
}

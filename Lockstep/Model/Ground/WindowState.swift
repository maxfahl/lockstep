import LockstepUI
import Observation

/// What the window shows: the content of the main layout, and the alert.
///
/// It is ground: `AppModel` makes one, and every part that shows something is handed it and
/// writes `content` itself, the fields it owns, only when a value changes.
///
/// What may change many times a second (the playhead, in `PlayheadPosition`) is kept out of
/// `content`, so the whole window is not drawn again on every frame.
@MainActor
@Observable
final class WindowState {
    /// What the window draws. It changes when a song is opened and when playing
    /// starts or stops, never on every frame while a song plays.
    var content = MainLayoutContent.empty {
        // Counted for `Scripts/same-behaviour.sh` (`RunCounts`). Keep this line with `content` when it moves.
        didSet { RunCounts.shared.contentWritten() }
    }

    /// What the alert says. It keeps its words while the alert closes.
    var alert = MessageAlert(title: "")
    /// Whether the alert is open.
    var showsAlert = false

    /// Shows an alert with these words.
    func showAlert(_ message: MessageAlert) {
        alert = message
        showsAlert = true
    }
}

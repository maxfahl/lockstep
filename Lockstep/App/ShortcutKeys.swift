import AppKit
import LockstepCore

/// Carries out Lockstep's shortcuts before any control in a window sees the key.
///
/// Without it a key reaches the control that has the keyboard first, and the menu bar
/// only gets what the control leaves: Space presses the focused button and an arrow key
/// moves the focused slider, and the song neither plays nor does the playhead move. Max
/// asked for Space to mean Play or Stop always, whatever was clicked last.
///
///     let keys = ShortcutKeys(canPerform: { model.canPerform($0) }, perform: { model.perform($0) })
///     keys.start()
///
/// It watches every key press of the app, in every Lockstep window, and looks the key up
/// in the store the menus show their shortcuts from. So a shortcut changed in Settings is
/// in force here at once.
///
/// - A key whose command can act is carried out, and nothing else sees the key.
/// - A key whose command cannot act right now does nothing at all. It is not handed on
///   to the focused control either, so Space never presses a button. Copy and Paste are
///   the exception: with no clips to act on they go on to the menu, which hands them to text.
/// - A field that is being typed in gets its keys: a clip or track name, a text field in
///   Settings or a sheet, the shortcut recorder, and the open and save panels
///   (`TypingWatch.isTyping(in:)`). The menu bar still acts on a shortcut that text has
///   no use for, such as Command-O, as it always did.
/// - Return, Escape and Tab stay with a sheet, an alert and a popover, which answer to
///   them themselves. Anywhere else they are passed on when their command cannot act, so
///   Escape still closes what it closes when no stretch is marked.
/// - Escape during a drag is the drag's own key, which gives the drag up.
/// - A key that is held down repeats a step of the playhead and a zoom. Every other
///   command is carried out once for each press.
/// - A key that is no Lockstep shortcut is left alone.
@MainActor
final class ShortcutKeys {
    private let shortcuts: ShortcutStore
    private let canPerform: (AppCommand) -> Bool
    private let perform: (AppCommand) -> Void

    /// What AppKit gave back when the watching started.
    private var monitor: Any?
    /// The key whose press was last kept here. Only its repeats are kept as well: the
    /// repeats of a key that went somewhere else go there too.
    private var heldKey: UInt16?

    /// - Parameters:
    ///   - shortcuts: the shortcut in force for each command. Left out, it is the app's own store.
    ///   - canPerform: whether a command can act right now (`AppModel.canPerform`).
    ///   - perform: carries a command out (`AppModel.perform`).
    init(
        shortcuts: ShortcutStore = .app,
        canPerform: @escaping (AppCommand) -> Bool,
        perform: @escaping (AppCommand) -> Void
    ) {
        self.shortcuts = shortcuts
        self.canPerform = canPerform
        self.perform = perform
    }

    func start() {
        guard monitor == nil else { return }
        // AppKit calls this block on the main thread and nowhere else, before the key
        // reaches a window or the menu bar.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    /// Looks at one key press. Returns it to let it go on, or nil to keep it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let window = event.window ?? NSApplication.shared.keyWindow
        // A window that stops the whole app until it is answered owns the keyboard.
        guard NSApplication.shared.modalWindow == nil, !TypingWatch.isTyping(in: window),
              let shortcut = ShortcutRecorderField.shortcut(from: event),
              let command = shortcuts.command(for: shortcut)
        else {
            if !event.isARepeat {
                heldKey = nil
            }
            return event
        }
        if event.isARepeat {
            guard event.keyCode == heldKey else { return event }
            if command.repeatsWhileHeld, canPerform(command) {
                performSoon(command)
            }
            return nil
        }
        heldKey = nil
        if shortcut.isDialogKey, Self.answersToDialogKeys(window) {
            return event
        }
        if shortcut.key == Shortcut.escape, NSEvent.pressedMouseButtons != 0 {
            return event
        }
        if !canPerform(command), shortcut.isDialogKey {
            return event
        }
        // Copy and Paste with no clips to act on are the text's, such as a timecode selected to be copied.
        if !canPerform(command), command.isAlsoTextCommand {
            return event
        }
        // Kept from here on, with its repeats, whether or not the command can act.
        heldKey = event.keyCode
        if canPerform(command) {
            performSoon(command)
        }
        return nil
    }

    /// Carries a command out as soon as AppKit is done with the key, and not in the middle
    /// of its handling of it: Open... shows a panel and waits there for the answer.
    private func performSoon(_ command: AppCommand) {
        Task { @MainActor in
            self.perform(command)
        }
    }

    /// True for a sheet, an alert and a popover: windows that hang on another window and
    /// answer to Return, Escape and Tab themselves.
    private static func answersToDialogKeys(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.sheetParent != nil || window.parent != nil || window is NSPanel
    }
}

extension AppCommand {
    /// True for a command that is carried out again and again while its key is held down:
    /// a step of the playhead, a zoom and a step of the tracks' height. Holding Space must
    /// not start and stop the song thirty times a second.
    fileprivate var repeatsWhileHeld: Bool {
        playheadStep != nil || self == .zoomIn || self == .zoomOut
            || self == .tallerTracks || self == .lowerTracks
    }
}

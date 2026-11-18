import AppKit
import LockstepCore
import SwiftUI

/// A field that shows the shortcut of one command and takes a new one from the keyboard.
///
///     ShortcutField(
///         shortcut: store.shortcut(for: .playStop),
///         onRecord: { pressed in store.set(pressed, for: .playStop) },
///         onClear: { store.set(nil, for: .playStop) }
///     )
///
/// - It shows `shortcut` as the menus write it ("⇧⌘K", "Space"), or "None".
/// - A click makes it wait: it shows "Type shortcut", and the next key press is handed
///   to `onRecord`. A plain key such as Space or R counts. A press of only Command,
///   Option, Control or Shift does not, and the field goes on waiting.
/// - While it waits, every key comes to it before the window and the menu bar see it.
/// - Escape, a click anywhere else and the window losing the keyboard end the waiting,
///   and nothing is changed. Tab ends it too and moves on to the next control.
/// - Delete while it waits, or a click on the button with the cross, calls `onClear`.
///
/// The field keeps nothing itself. After `onRecord` it shows `shortcut` again, which is
/// the old shortcut until whoever uses the field has accepted the new one.
///
/// Apple has no ready-made field for this. This one is the system's search field without
/// its magnifying glass, so macOS draws it, its focus ring and its text in the current look.
struct ShortcutField: NSViewRepresentable {
    /// The shortcut in force, or nil when the command has none.
    let shortcut: Shortcut?
    let onRecord: (Shortcut) -> Void
    let onClear: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        ShortcutRecorderField()
    }

    func updateNSView(_ field: ShortcutRecorderField, context: Context) {
        field.onRecord = onRecord
        field.onClear = onClear
        field.shortcut = shortcut
    }
}

/// The AppKit view behind `ShortcutField`.
///
/// It waits for a key exactly as long as it is the window's first responder, which a
/// click makes it. Being a text field, it then has the window's text editor, and the
/// system draws the focus ring around it. Nothing can be typed into it: while it waits,
/// it watches the app's key presses and clicks and takes every key press for itself.
final class ShortcutRecorderField: NSSearchField {
    var shortcut: Shortcut? {
        didSet { showShortcut() }
    }

    var onRecord: ((Shortcut) -> Void)?
    var onClear: (() -> Void)?

    /// Every field is this wide, so the fields of a list line up.
    private static var width: CGFloat { 130 }
    /// The distance of the clear button from the field's right edge.
    private static var clearInset: CGFloat { 6 }

    private static var emptyText: String { "None" }
    private static var waitingText: String { "Type shortcut" }

    private let clearButton = NSButton()
    /// True from the click that starts the waiting until a key, Escape, or a click elsewhere.
    private var isWaiting = false
    /// The watch on the app's key presses and clicks. It is there while the field waits,
    /// and after a key was taken until that key is let go.
    private var watch: Any?
    /// The key that was just taken as a shortcut and is still held down.
    private var heldKey: UInt16?
    /// The colour of the text editor's caret before the field hid it.
    private var caretColor: NSColor?

    init() {
        super.init(frame: .zero)
        alignment = .center
        toolTip = "Click, then press the keys for this command. Delete removes the shortcut."
        if let cell = cell as? NSSearchFieldCell {
            // No magnifying glass. The search field's own cross is left out as well,
            // because it clears the text by itself, without asking anyone.
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .vertical)

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove shortcut")
        clearButton.title = ""
        clearButton.imagePosition = .imageOnly
        clearButton.isBordered = false
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.refusesFirstResponder = true
        clearButton.toolTip = "Remove the shortcut"
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.clearInset),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        showShortcut()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShortcutRecorderField is made in code")
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = Self.width
        return size
    }

    /// Only a click starts the waiting. Otherwise the first field of the pane would
    /// wait for a key as soon as the settings window opens.
    override var canBecomeKeyView: Bool { false }

    private func showShortcut() {
        guard !isWaiting else { return }
        stringValue = shortcut?.shownText ?? ""
        placeholderString = Self.emptyText
        clearButton.isHidden = shortcut == nil
    }

    // MARK: Waiting for a key

    override func becomeFirstResponder() -> Bool {
        // Emptied, so the field says that it waits in place of the shortcut it has.
        stringValue = ""
        placeholderString = Self.waitingText
        clearButton.isHidden = true
        guard super.becomeFirstResponder() else {
            showShortcut()
            return false
        }
        isWaiting = true
        // Nothing is typed here, so no caret blinks.
        if let editor = currentEditor() as? NSTextView {
            caretColor = editor.insertionPointColor
            editor.insertionPointColor = .clear
        }
        startWatching()
        return true
    }

    /// No text gets in by another way than the keys either: Paste from a menu, or text
    /// dragged in.
    override func textShouldBeginEditing(_ textObject: NSText) -> Bool {
        false
    }

    /// The field is no longer the first responder: the waiting is over, however it ended.
    override func textDidEndEditing(_ notification: Notification) {
        giveBackCaret(to: notification.object as? NSText)
        super.textDidEndEditing(notification)
        endWaiting()
    }

    /// Ends the waiting without a change.
    private func stopWaiting() {
        guard isWaiting else { return }
        window?.makeFirstResponder(nil)
        // Normally the line above has ended it by way of `textDidEndEditing`.
        if isWaiting {
            giveBackCaret(to: currentEditor())
            abortEditing()
            endWaiting()
        }
    }

    private func endWaiting() {
        isWaiting = false
        if heldKey == nil {
            stopWatching()
        }
        showShortcut()
    }

    /// The window's text editor is shared with the window's other fields.
    private func giveBackCaret(to editor: NSText?) {
        if let editor = editor as? NSTextView, let caretColor {
            editor.insertionPointColor = caretColor
        }
        caretColor = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        if let window {
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        if let newWindow {
            center.addObserver(
                self,
                selector: #selector(windowLostKeyboard),
                name: NSWindow.didResignKeyNotification,
                object: newWindow
            )
        } else {
            // The pane is gone, for example because another pane was chosen.
            stopWaiting()
            stopWatching()
        }
    }

    @objc private func windowLostKeyboard(_ notification: Notification) {
        stopWaiting()
    }

    @objc private func clearClicked() {
        stopWaiting()
        onClear?()
    }

    // MARK: Taking the keys

    /// Starts watching every key press and click of the app. The watch sees them before
    /// the window and the menu bar do, and what it keeps for itself never reaches them.
    /// That is why Space is taken as a shortcut here and does not start the song, and
    /// why Command-O does not open the file panel.
    private func startWatching() {
        stopWatching()
        // AppKit calls this block on the main thread and nowhere else, so it may use the field.
        watch = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func stopWatching() {
        if let watch {
            NSEvent.removeMonitor(watch)
        }
        watch = nil
        heldKey = nil
    }

    /// Looks at one event of the app. Returns it to let it go on, or nil to keep it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        if let heldKey {
            // The key was taken as a shortcut and is still down. Its repeats are dropped,
            // or a held Return would press the button of the question that follows.
            if event.type == .keyDown, event.isARepeat, event.keyCode == heldKey {
                return nil
            }
            stopWatching()
            return event
        }
        switch event.type {
        case .keyDown:
            take(event)
            return nil
        case .keyUp:
            return event
        default:
            // A click anywhere but in the field ends the waiting. The click itself
            // goes on to what was clicked.
            let isInField = event.window === window && bounds.contains(convert(event.locationInWindow, from: nil))
            if !isInField {
                stopWaiting()
            }
            return event
        }
    }

    /// Acts on a key pressed while the field waits.
    private func take(_ event: NSEvent) {
        guard !event.isARepeat, let shortcut = Self.shortcut(from: event) else {
            // Not a key that can be a shortcut. The field goes on waiting.
            return
        }
        let modifiers = shortcut.modifiers
        switch shortcut.key {
        case Shortcut.tab where modifiers.isEmpty:
            stopWaiting()
            window?.selectKeyView(following: self)
        case Shortcut.tab where modifiers == [.shift]:
            stopWaiting()
            window?.selectKeyView(preceding: self)
        case Shortcut.escape where modifiers.isEmpty:
            stopWaiting()
        case Shortcut.delete where modifiers.isEmpty, Shortcut.forwardDelete where modifiers.isEmpty:
            stopWaiting()
            onClear?()
        default:
            heldKey = event.keyCode
            stopWaiting()
            onRecord?(shortcut)
        }
    }

    /// The shortcut a key press stands for, or nil for a key that cannot be one.
    ///
    ///     R                 Shortcut("r")
    ///     Shift-Command-K   Shortcut("k", modifiers: [.shift, .command])
    ///     Shift-Space       Shortcut("space", modifiers: [.shift])
    ///     Shift-1           Shortcut("!")      on a keyboard where that gives "!"
    ///
    /// `ShortcutKeys` reads every key press with this too, so a key is carried out as
    /// exactly the shortcut it was recorded as.
    static func shortcut(from event: NSEvent) -> Shortcut? {
        let held = event.modifierFlags
        // The character as the keyboard gives it with Shift alone. Command, Option and
        // Control would turn it into another character.
        guard let typed = event.characters(byApplyingModifiers: held.intersection(.shift)), typed.count == 1 else {
            return nil
        }
        var modifiers: [Shortcut.Modifier] = []
        if held.contains(.control) { modifiers.append(.control) }
        if held.contains(.option) { modifiers.append(.option) }
        if held.contains(.command) { modifiers.append(.command) }
        var shortcut = Shortcut(typed, modifiers: modifiers)
        if held.contains(.shift) {
            // A letter and a key with a name keep Shift: Shift-M, Shift-Space. A sign
            // the keyboard only gives with Shift is that sign by itself, without Shift.
            let isLetter = typed.lowercased() != typed.uppercased()
            let hasName = Shortcut.keyNames.contains(shortcut.key)
            if isLetter || hasName || event.characters(byApplyingModifiers: []) == typed {
                shortcut = Shortcut(typed, modifiers: modifiers + [.shift])
            }
        }
        return shortcut.canBeShown ? shortcut : nil
    }
}

extension Shortcut {
    /// The shortcut as the menus write it: the signs of the modifier keys, then the key.
    ///
    ///     Shortcut("k", modifiers: [.shift, .command]).shownText   // "⇧⌘K"
    ///     Shortcut(Shortcut.space).shownText                       // "Space"
    ///     Shortcut(Shortcut.down, modifiers: [.option]).shownText  // "⌥↓"
    var shownText: String {
        modifiers.map(\.sign).joined() + keyText
    }

    private var keyText: String {
        switch key {
        case Shortcut.space: "Space"
        case Shortcut.return: "↩"
        case Shortcut.tab: "⇥"
        case Shortcut.escape: "⎋"
        case Shortcut.delete: "⌫"
        case Shortcut.forwardDelete: "⌦"
        case Shortcut.up: "↑"
        case Shortcut.down: "↓"
        case Shortcut.left: "←"
        case Shortcut.right: "→"
        case Shortcut.home: "↖"
        case Shortcut.end: "↘"
        case Shortcut.pageUp: "⇞"
        case Shortcut.pageDown: "⇟"
        // A letter, a sign, or a function key: "K", "+", "F5".
        default: key.uppercased()
        }
    }

    /// False for a key the Mac has no name or sign for, such as Enter on a number pad
    /// or Help. Such a key could not be shown in the field or in a menu.
    fileprivate var canBeShown: Bool {
        if Shortcut.keyNames.contains(key) {
            return true
        }
        guard key.count == 1 else { return false }
        return key.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned,
                 .spaceSeparator, .lineSeparator, .paragraphSeparator:
                false
            default:
                true
            }
        }
    }
}

extension Shortcut.Modifier {
    /// The sign of the modifier key, as it is printed on the keyboard and in the menus.
    fileprivate var sign: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }
}

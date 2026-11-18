import AppKit
import Observation

/// Knows whether key presses are going into text right now.
///
/// The menu bar reads `isTyping` and takes the shortcuts without Command, Option or
/// Control off its items while it is true. Otherwise a menu would act on Space or R
/// before the text field ever saw the key.
///
/// Typing is going on when the window that has the keyboard is
/// - editing text: a text field that is being typed in hands the keyboard to the
///   window's text editor, so the window's first responder is an `NSText`;
/// - or an open or save panel. Its search field and name field belong to another
///   program and cannot be looked at, so the whole panel counts.
///
/// It looks again whenever another window gets the keyboard, and whenever the keyboard
/// moves to another control inside that window.
@MainActor
@Observable
final class TypingWatch {
    /// The app's one watch. The menu bar uses it.
    static let app = TypingWatch()

    private(set) var isTyping = false

    /// The window that has the keyboard, and the watch on where in it the keyboard is.
    @ObservationIgnored private weak var watchedWindow: NSWindow?
    @ObservationIgnored private var responderWatch: NSKeyValueObservation?
    @ObservationIgnored private var windowWatches: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowWatches.append(
                center.addObserver(forName: name, object: nil, queue: .main, using: Self.keyWindowChanged(self))
            )
        }
        look()
    }

    private func look() {
        let window = NSApplication.shared.keyWindow
        if window !== watchedWindow {
            watchedWindow = window
            responderWatch = window?.observe(\.firstResponder, changeHandler: Self.responderChanged(self))
        }
        let typing = Self.isTyping(in: window)
        // Written only when it changes, so the menus are not drawn again for nothing.
        if typing != isTyping {
            isTyping = typing
        }
    }

    /// Whether key presses in this window go into text at this very moment. `isTyping` hears
    /// of a change a moment later, which is soon enough for the menus. Whoever decides about
    /// a key that was just pressed asks here.
    static func isTyping(in window: NSWindow?) -> Bool {
        window.map { $0 is NSSavePanel || $0.firstResponder is NSText } ?? false
    }

    // The two blocks below are called by the system, so they are made outside the main
    // actor and only pass the news on to it. The watch lives as long as the app, so
    // they may hold on to it.

    private nonisolated static func keyWindowChanged(_ watch: TypingWatch) -> @Sendable (Notification) -> Void {
        { _ in
            Task { @MainActor in watch.look() }
        }
    }

    private nonisolated static func responderChanged(
        _ watch: TypingWatch
    ) -> @Sendable (NSWindow, NSKeyValueObservedChange<NSResponder?>) -> Void {
        { _, _ in
            Task { @MainActor in watch.look() }
        }
    }
}

import AppKit

/// Takes out of the menu bar what macOS puts there by itself and Lockstep has no use for.
///
/// macOS adds items to the Edit menu of every app, for writing documents: AutoFill,
/// Writing Tools, Start Dictation and Emoji & Symbols. Lockstep's only text is the name
/// of a track or a clip. Two of them can be switched off with a setting (see
/// `switchOffTextHelpers`). The others have no switch, so they are hidden once they are
/// in the menu. macOS puts them back whenever the menus are built again, so the cleaner
/// looks again every time an item is added to a menu.
///
/// A dividing line that is left first, last or next to another line is hidden too, and
/// shown again when it is needed.
///
///     MenuCleaner.switchOffTextHelpers()   // before the app's menus exist
///     MenuCleaner.app.start()
@MainActor
final class MenuCleaner {
    /// The app's one cleaner.
    static let app = MenuCleaner()

    /// The items that are hidden, by what they do. Their titles could be in another language.
    private static let unwantedActions: Set<String> = ["startDictation:", "orderFrontCharacterPalette:"]
    /// The items that are hidden by title, because they are submenus and do nothing themselves.
    private static let unwantedTitles: Set<String> = ["AutoFill", "Writing Tools"]

    private var watches: [any NSObjectProtocol] = []
    /// True from the first news of a change until the menus are looked at, so many
    /// changes in a row are answered by one look.
    private var isWaiting = false
    /// The dividing lines this cleaner hid, so it can show them again.
    private let hiddenLines = NSHashTable<NSMenuItem>.weakObjects()

    /// Tells macOS not to add Start Dictation and Emoji & Symbols to the Edit menu, and
    /// not to offer window tabs, which add Show Tab Bar and Show All Tabs to the View
    /// menu and four more items to the Window menu.
    ///
    /// The two settings are given as starting values for this run only. Nothing is
    /// written to Max's settings.
    static func switchOffTextHelpers() {
        UserDefaults.standard.register(defaults: [
            "NSDisabledDictationMenuItem": true,
            "NSDisabledCharacterPaletteMenuItem": true,
        ])
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func start() {
        guard watches.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSMenu.didAddItemNotification, NSApplication.didFinishLaunchingNotification] {
            watches.append(center.addObserver(forName: name, object: nil, queue: .main, using: Self.menusChanged(self)))
        }
    }

    // Called by the system, so the block is made outside the main actor and only passes
    // the news on to it. The cleaner lives as long as the app, so it may hold on to it.
    private nonisolated static func menusChanged(_ cleaner: MenuCleaner) -> @Sendable (Notification) -> Void {
        { _ in
            Task { @MainActor in cleaner.lookSoon() }
        }
    }

    private func lookSoon() {
        guard !isWaiting else { return }
        isWaiting = true
        Task { @MainActor in
            self.isWaiting = false
            self.look()
        }
    }

    private func look() {
        guard let menuBar = NSApplication.shared.mainMenu else { return }
        for menu in menuBar.items.compactMap(\.submenu) {
            for item in menu.items where !item.isHidden && Self.isUnwanted(item) {
                item.isHidden = true
            }
            tidyLines(in: menu)
        }
        // Lockstep has no help pages, and the one item macOS puts in the Help menu is not
        // Lockstep's. Max asked for the menu to go.
        let help = NSApplication.shared.helpMenu
        for item in menuBar.items where !item.isHidden && (item.submenu === help && help != nil || item.title == "Help") {
            item.isHidden = true
        }
    }

    private static func isUnwanted(_ item: NSMenuItem) -> Bool {
        if let action = item.action, unwantedActions.contains(NSStringFromSelector(action)) {
            return true
        }
        return item.hasSubmenu && unwantedTitles.contains(item.title)
    }

    /// Hides each dividing line with nothing above it, nothing below it or another line
    /// right above it, and shows the ones hidden earlier that are needed again.
    private func tidyLines(in menu: NSMenu) {
        // What is shown, counting the lines this cleaner hid as still there.
        let shown = menu.items.filter { !$0.isHidden || hiddenLines.contains($0) }
        var unneeded: Set<ObjectIdentifier> = []
        var lastKept: NSMenuItem?
        for item in shown {
            if item.isSeparatorItem, lastKept?.isSeparatorItem ?? true {
                unneeded.insert(ObjectIdentifier(item))
            } else {
                lastKept = item
            }
        }
        if let lastKept, lastKept.isSeparatorItem {
            unneeded.insert(ObjectIdentifier(lastKept))
        }
        for line in shown where line.isSeparatorItem {
            let hide = unneeded.contains(ObjectIdentifier(line))
            if hide, !line.isHidden {
                line.isHidden = true
                hiddenLines.add(line)
            } else if !hide, hiddenLines.contains(line) {
                line.isHidden = false
                hiddenLines.remove(line)
            }
        }
    }
}

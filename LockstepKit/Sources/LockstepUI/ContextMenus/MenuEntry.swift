import SwiftUI

/// One line of a right-click menu: a command, a submenu or a divider.
///
/// Each menu (`ClipMenu`, `TrackMenu`, `BeatMenu`, `SongMenu`) describes its
/// lines once, as a list of these. The same list becomes the real menu
/// (`MenuEntries`) and the plain picture of it (`MenuListing`), so the two
/// never differ.
public enum MenuEntry: Sendable {
    case command(MenuCommandItem)
    case submenu(title: String, entries: [MenuEntry])
    case divider

    /// A command that can be chosen. `action` is called when it is chosen in
    /// the real menu. Left out, choosing it does nothing.
    public static func command(
        _ title: String,
        shortcut: MenuShortcut? = nil,
        isChecked: Bool? = nil,
        isEnabled: Bool = true,
        action: (@MainActor () -> Void)? = nil
    ) -> MenuEntry {
        .command(MenuCommandItem(
            title: title,
            shortcut: shortcut,
            isChecked: isChecked,
            isEnabled: isEnabled,
            action: action
        ))
    }
}

/// A command in a right-click menu, with the fake values the design shows.
public struct MenuCommandItem: Sendable {
    /// The title, exactly as the list of commands writes it.
    public var title: String
    /// The default shortcut, or nil for a command without one.
    public var shortcut: MenuShortcut?
    /// Nil for a command that is never ticked. True or false for one that can
    /// be, such as Mute Clip or a feel.
    public var isChecked: Bool?
    /// False greys the command out, as when it does not apply right now.
    public var isEnabled: Bool
    /// Called when the command is chosen in the real menu. Nil for a command
    /// that does nothing yet, which is every command in the design lab.
    public var action: (@MainActor () -> Void)?

    public init(
        title: String,
        shortcut: MenuShortcut? = nil,
        isChecked: Bool? = nil,
        isEnabled: Bool = true,
        action: (@MainActor () -> Void)? = nil
    ) {
        self.title = title
        self.shortcut = shortcut
        self.isChecked = isChecked
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// A default shortcut, as a menu shows it on the right of a command.
public struct MenuShortcut: Sendable {
    public var key: KeyEquivalent
    public var modifiers: EventModifiers

    public init(_ key: KeyEquivalent, modifiers: EventModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The shortcut written the way the Mac writes it, such as "⇧⌘D".
    public var text: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .delete: text += "⌫"
        case .return: text += "↩"
        case .escape: text += "⎋"
        case .space: text += "Space"
        default: text += String(key.character).uppercased()
        }
        return text
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(key, modifiers: modifiers)
    }
}

/// The lines of a menu as the system's own menu items. Put it inside
/// `contextMenu { }` or `Menu { }`. Choosing a command calls its `action`,
/// and does nothing when it has none.
public struct MenuEntries: View {
    private let entries: [MenuEntry]

    public init(_ entries: [MenuEntry]) {
        self.entries = entries
    }

    public var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .command(let item):
                MenuCommandView(item: item)
            case .submenu(let title, let entries):
                // A menu inside a menu names its own type, so it is wrapped
                // to keep the type from referring to itself.
                Menu(title) { AnyView(MenuEntries(entries)) }
            case .divider:
                Divider()
            }
        }
    }
}

/// One command as a system menu item: a tick item when it can be ticked, a
/// plain item otherwise.
private struct MenuCommandView: View {
    let item: MenuCommandItem

    var body: some View {
        Group {
            if let isChecked = item.isChecked {
                // The tick shows what it is told. Choosing the command only
                // reports it, and the owner then changes what is ticked.
                Toggle(item.title, isOn: Binding(get: { isChecked }, set: { _ in item.action?() }))
            } else {
                Button(item.title) { item.action?() }
            }
        }
        .keyboardShortcut(item.shortcut?.keyboardShortcut)
        .disabled(!item.isEnabled)
    }
}

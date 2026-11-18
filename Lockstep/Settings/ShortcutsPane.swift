import LockstepCore
import SwiftUI

/// The Shortcuts pane: every command that can have a shortcut, under the name of its
/// menu and in the order of the menus, each with a field for its shortcut.
///
/// A command gets its row by being in `AppCommand` with a finished feature. A later
/// phase adds its commands there and nothing here.
///
/// The pane changes nothing by itself. It hands every wish to the store the menus read
/// from, and asks Max when the store says no:
/// - the shortcut belongs to another command: "⌘O is used by Open." with Replace and Cancel;
/// - the shortcut belongs to macOS: "⌘Q is used by macOS.", and nothing is saved.
///
/// Undo, Redo, Copy, Paste and Quit are the system's own menu items. They are not in
/// `AppCommand`, so they have no row.
struct ShortcutsPane: View {
    var shortcuts: ShortcutStore = .app

    /// What the pane asks or tells Max, when it does.
    enum Prompt {
        /// `shortcut` was wanted for `command`, and `holder` has it.
        case taken(Shortcut, wantedFor: AppCommand, holder: AppCommand)
        /// macOS or a standard menu uses the shortcut.
        case reserved(Shortcut)
        /// "Restore Defaults" was clicked.
        case restoreAll
    }

    /// The last thing asked. It stays after the answer, so the alert keeps its words
    /// while it fades away.
    @State private var prompt: Prompt?
    @State private var isAsking = false

    /// The list scrolls when it is taller than this. With every planned command it
    /// would otherwise be taller than a laptop's screen.
    private static var tallestList: CGFloat { 560 }

    var body: some View {
        SettingsPaneForm(tallestForm: Self.tallestList, restoreDefaults: { ask(.restoreAll) }) {
            ForEach(LockstepCore.CommandMenu.allCases, id: \.self) { menu in
                let commands = shortcuts.commands.filter { $0.menu == menu }
                if !commands.isEmpty {
                    Section(menu.title) {
                        ForEach(commands, id: \.self) { command in
                            ShortcutRow(command: command, shortcuts: shortcuts, ask: ask)
                        }
                    }
                }
            }
        }
        .alert(prompt?.title ?? "", isPresented: $isAsking, presenting: prompt) { prompt in
            switch prompt {
            case let .taken(shortcut, command, holder):
                Button("Replace") {
                    shortcuts.set(shortcut, for: command, replacing: holder)
                }
                Button("Cancel", role: .cancel) {}
            case .reserved:
                Button("OK", role: .cancel) {}
            case .restoreAll:
                Button("Restore Defaults", role: .destructive) {
                    shortcuts.resetAll()
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    private func ask(_ prompt: Prompt) {
        self.prompt = prompt
        isAsking = true
    }
}

/// One command: its title, the button that gives it its default shortcut back, shown
/// only while it has another one, and the field with its shortcut.
private struct ShortcutRow: View {
    let command: AppCommand
    let shortcuts: ShortcutStore
    let ask: (ShortcutsPane.Prompt) -> Void

    var body: some View {
        // Read here, so the row is drawn again when the shortcut changes.
        let shortcut = shortcuts.shortcut(for: command)
        LabeledContent(command.title) {
            HStack(spacing: 6) {
                if !shortcuts.hasDefault(command) {
                    Button(action: reset) {
                        Label(resetTitle, systemImage: "arrow.counterclockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(resetTitle)
                }
                ShortcutField(
                    shortcut: shortcut,
                    onRecord: record,
                    onClear: { shortcuts.set(nil, for: command) }
                )
                .fixedSize()
            }
        }
    }

    private var resetTitle: String {
        if let usual = command.defaultShortcut {
            "Back to \(usual.shownText)"
        } else {
            "Back to no shortcut"
        }
    }

    /// A key was pressed in the field. The store says whether the command may have it.
    private func record(_ shortcut: Shortcut) {
        switch shortcuts.set(shortcut, for: command) {
        case .saved:
            break
        case .conflict(let holder):
            ask(.taken(shortcut, wantedFor: command, holder: holder))
        case .reserved:
            ask(.reserved(shortcut))
        }
    }

    /// The default can be in use by now, because Max gave it to another command. Then
    /// he is asked the same question as for any other shortcut that is taken.
    private func reset() {
        if case .conflict(let holder) = shortcuts.reset(command), let usual = command.defaultShortcut {
            ask(.taken(usual, wantedFor: command, holder: holder))
        }
    }
}

extension ShortcutsPane.Prompt {
    fileprivate var title: String {
        switch self {
        case let .taken(shortcut, _, holder): "\(shortcut.shownText) is used by \(holder.name)."
        case .reserved(let shortcut): "\(shortcut.shownText) is used by macOS."
        case .restoreAll: "Restore all shortcuts to their defaults?"
        }
    }

    fileprivate var message: String {
        switch self {
        case let .taken(_, command, holder): "Replace gives it to \(command.name) and leaves \(holder.name) without a shortcut."
        case .reserved: "Choose another shortcut."
        case .restoreAll: "Every shortcut you changed goes back to what it started as."
        }
    }
}

extension AppCommand {
    /// The command's title inside a sentence: without the three dots some titles end with.
    fileprivate var name: String {
        title.hasSuffix("...") ? String(title.dropLast(3)) : title
    }
}

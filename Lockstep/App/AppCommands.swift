import AppKit
import LockstepCore
import SwiftUI

/// The menu bar's Lockstep commands, built from the list in `AppCommand`.
///
/// It knows nothing about the app's model. It is given what each command does
/// and whether it can act right now, and the set of finished features. A
/// command whose feature is not finished is not in its menu.
///
/// Each item shows the shortcut that `shortcuts` has for its command, and is drawn
/// again when Max changes it in Settings. While `typing` says that key presses are
/// going into text, an item whose shortcut the text field uses itself
/// (`Shortcut.isTextKey`: a key without Command, Option or Control, and the arrows and
/// Delete with any of them) shows and has no shortcut, so the key goes to the text
/// instead of starting the command. The item itself can still be chosen from the menu.
///
/// The shortcuts are also carried out by `ShortcutKeys`, which sees a key before any
/// control does. The menu items act on what it leaves: the keys pressed while text is
/// typed, and Return, Escape and Tab.
///
///     .commands {
///         AppCommands(
///             built: .built,
///             store: model.store,
///             recent: model.recentProjects,
///             openRecent: { model.open($0) },
///             perform: { model.perform($0) },
///             isEnabled: { model.canPerform($0) },
///             canUndo: { !model.isTakeGoing },
///             mergeTargets: { model.mergeTargets },
///             mergeInto: { model.mergeSelectedTrack(into: $0) },
///             aimTargets: { model.correction.aimTargets },
///             aimIsChosen: { model.correction.aimIsChosen($0) },
///             aimAt: { model.aimSelectedClips(at: $0) }
///         )
///     }
///
/// Undo and Redo are not in `AppCommand`: they are the Edit menu's own two
/// items, and here they act on the project's store. `canUndo` greys both out
/// while it answers false, as during a take.
struct AppCommands: Commands {
    var built: FeatureSet
    var store: ProjectStore
    /// The projects under File > Open Recent, and what choosing one does.
    var recent: RecentProjects
    var openRecent: @MainActor (URL) -> Void
    var perform: @MainActor (AppCommand) -> Void
    var isEnabled: @MainActor (AppCommand) -> Bool
    /// Whether what a command switches is on right now, for a command that is a switch
    /// (`AppCommand.isToggle`). Its item is ticked while this answers true. Left out,
    /// no item is ticked.
    var isOn: @MainActor (AppCommand) -> Bool = { _ in false }
    /// The title of a command's menu item right now, for a command whose title depends on
    /// what it would act on, as Delete's does. Left out, it is the command's own title.
    var title: @MainActor (AppCommand) -> String = { $0.title }
    /// False while Undo and Redo must not act, whatever there is to undo. Left out, they always may.
    var canUndo: @MainActor () -> Bool = { true }
    /// What Undo and Redo do. Left out, they act on the store as they are. The app hands in the same
    /// with a stopwatch around it, so an Undo leaves a line in the Mac's log like every other edit.
    var undo: (@MainActor () -> Void)?
    var redo: (@MainActor () -> Void)?
    /// The shortcut in force for each command. Left out, it is the app's own store.
    var shortcuts: ShortcutStore = .app
    /// Whether key presses are going into text right now.
    var typing: TypingWatch = .app
    /// The tracks under Track > Merge Into, from top to bottom, and what choosing one
    /// does. Left out, the submenu is empty.
    var mergeTargets: @MainActor () -> [MergeTarget] = { [] }
    var mergeInto: @MainActor (UUID) -> Void = { _ in }
    /// The tracks under Clip > Correction > Aim at, from top to bottom, whether the selected clips
    /// aim at one of them, which ticks its line, and what choosing one does. Left out, the submenu
    /// is empty.
    var aimTargets: @MainActor () -> [MergeTarget] = { [] }
    var aimIsChosen: @MainActor (UUID) -> Bool = { _ in false }
    var aimAt: @MainActor (UUID) -> Void = { _ in }
    /// Debug > Add Test Clips. Only a debug build has the menu, and only when this is set.
    var addTestClips: (@MainActor () -> Void)?

    var body: some Commands {
        // File, Edit and View are menus the system already makes, so their commands
        // are put into them. Transport, Song, Track and Clip are Lockstep's own menus.
        CommandGroup(replacing: .newItem) {
            items(in: .file)
        }
        // In place of the system's Undo and Redo, which act on the window that
        // has the keyboard. These act on the project from every window, so
        // Command-Z also works from a popover, a sheet or a panel.
        CommandGroup(replacing: .undoRedo) {
            UndoRedoItems(store: store, canUndo: canUndo, undo: undo, redo: redo)
        }
        // In place of the system's Cut, Copy, Paste, Delete and Select All. The system's
        // Delete only removes selected text, which the Delete key does anyway, and it stood
        // in the menu next to Lockstep's own Delete, which removes clips. The other four are
        // put back, for text fields and for the open and save panels.
        CommandGroup(replacing: .pasteboard) {
            TextEditItems(
                typing: typing,
                shortcuts: shortcuts,
                clipsBuilt: built.isSuperset(of: AppCommand.copyClips.feature),
                perform: perform,
                isEnabled: isEnabled
            )
            if AppCommand.commands(in: .edit, built: built).contains(where: { !$0.isAlsoTextCommand }) {
                Divider()
                items(in: .edit)
            }
        }
        // Lockstep has no help pages, so "Lockstep Help" could only say that there are none.
        CommandGroup(replacing: .help) {}
        CommandGroup(before: .toolbar) {
            items(in: .view)
            if !AppCommand.commands(in: .view, built: built).isEmpty {
                Divider()
            }
        }
        if !AppCommand.commands(in: .transport, built: built).isEmpty {
            CommandMenu(LockstepCore.CommandMenu.transport.title) {
                items(in: .transport)
            }
        }
        if !AppCommand.commands(in: .song, built: built).isEmpty {
            CommandMenu(LockstepCore.CommandMenu.song.title) {
                items(in: .song)
            }
        }
        if !AppCommand.commands(in: .track, built: built).isEmpty {
            CommandMenu(LockstepCore.CommandMenu.track.title) {
                items(in: .track)
            }
        }
        if !AppCommand.commands(in: .clip, built: built).isEmpty {
            CommandMenu(LockstepCore.CommandMenu.clip.title) {
                items(in: .clip)
            }
        }
        #if DEBUG
        // For trying the window on a heavy project. Not a command of the app: it is in
        // no release build, has no shortcut and no row in Settings.
        if let addTestClips {
            CommandMenu("Debug") {
                Button("Add Test Clips") { addTestClips() }
            }
        }
        #endif
    }

    private func items(in menu: LockstepCore.CommandMenu) -> some View {
        // Copy and Paste of clips are the Copy and Paste items of `TextEditItems`.
        ForEach(AppCommand.commands(in: menu, built: built).filter { !$0.isAlsoTextCommand }, id: \.self) { command in
            if command == .openRecent {
                OpenRecentMenu(recent: recent, open: openRecent)
                    .disabled(!isEnabled(command))
            } else if command == .mergeInto {
                MergeIntoMenu(targets: mergeTargets, choose: mergeInto, isEnabled: isEnabled)
            } else if let submenu = command.submenu {
                // The commands of one submenu stand together in the list. The first of them brings the
                // submenu with all of them in it, and the others bring nothing more.
                let inSubmenu = AppCommand.commands(in: menu, built: built).filter { $0.submenu?.title == submenu.title }
                if inSubmenu.first == command {
                    Menu(submenu.title) {
                        // In the order of the list of commands. A command that stands in a submenu of its
                        // own inside this one (Effects > Double) brings that submenu where the first of
                        // them stands, so Track > Effects has "Double" above its three other lines.
                        ForEach(inSubmenu, id: \.self) { choice in
                            if let inner = choice.innerSubmenu {
                                let inInner = inSubmenu.filter { $0.innerSubmenu == inner }
                                if inInner.first == choice {
                                    Menu(inner) {
                                        ForEach(inInner, id: \.self) { innerChoice in
                                            AppCommandItem(
                                                command: innerChoice,
                                                shortcuts: shortcuts,
                                                typing: typing,
                                                perform: perform,
                                                isEnabled: isEnabled,
                                                isOn: isOn,
                                                title: { $0.submenu?.itemTitle ?? $0.title }
                                            )
                                        }
                                    }
                                }
                            } else {
                                if choice.startsGroupInSubmenu {
                                    Divider()
                                }
                                if choice == .aimAt {
                                    AimAtMenu(targets: aimTargets, isChosen: aimIsChosen, choose: aimAt, isEnabled: isEnabled)
                                } else {
                                    AppCommandItem(
                                        command: choice,
                                        shortcuts: shortcuts,
                                        typing: typing,
                                        perform: perform,
                                        isEnabled: isEnabled,
                                        isOn: isOn,
                                        title: { $0.submenu?.itemTitle ?? $0.title }
                                    )
                                }
                            }
                        }
                    }
                }
            } else {
                AppCommandItem(
                    command: command,
                    shortcuts: shortcuts,
                    typing: typing,
                    perform: perform,
                    isEnabled: isEnabled,
                    isOn: isOn,
                    title: title
                )
            }
        }
    }
}

/// File > Open Recent: the projects opened last, newest first, then Clear Menu. A view
/// of its own, so the list is read in its own body and the menu is drawn again when a
/// project is opened.
private struct OpenRecentMenu: View {
    let recent: RecentProjects
    let open: @MainActor (URL) -> Void

    var body: some View {
        Menu(AppCommand.openRecent.title) {
            ForEach(recent.urls, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) { open(url) }
            }
            if !recent.urls.isEmpty {
                Divider()
            }
            Button("Clear Menu") { recent.clear() }
                .disabled(recent.urls.isEmpty)
        }
    }
}

/// A track the selected track can be merged into: a line of Track > Merge Into.
struct MergeTarget: Identifiable {
    let id: UUID
    let name: String
}

/// Track > Merge Into: every track but the selected one, by name, from top to bottom.
/// Choosing one merges the selected track into it. A view of its own, so the tracks
/// and the selection are read in its own body and the list is drawn again when
/// either changes. The choices are not commands and have no shortcuts.
private struct MergeIntoMenu: View {
    let targets: @MainActor () -> [MergeTarget]
    let choose: @MainActor (UUID) -> Void
    let isEnabled: @MainActor (AppCommand) -> Bool

    var body: some View {
        Menu(AppCommand.mergeInto.title) {
            ForEach(targets()) { target in
                Button(target.name) { choose(target.id) }
            }
        }
        .disabled(!isEnabled(.mergeInto))
    }
}

/// Clip > Correction > Aim at: every track the selected clips are not on, by name, from top to
/// bottom, with the one they all aim at ticked. Choosing one aims them at it. "Aim at the Beat"
/// stands above it as a command of its own. A view of its own, so the tracks and the selection
/// are read in its own body and the list is drawn again when either changes. The choices are not
/// commands and have no shortcuts.
private struct AimAtMenu: View {
    let targets: @MainActor () -> [MergeTarget]
    let isChosen: @MainActor (UUID) -> Bool
    let choose: @MainActor (UUID) -> Void
    let isEnabled: @MainActor (AppCommand) -> Bool

    var body: some View {
        Menu(AppCommand.aimAt.submenu?.itemTitle ?? AppCommand.aimAt.title) {
            ForEach(targets()) { target in
                let isChosenNow = isChosen(target.id)
                Toggle(target.name, isOn: Binding(get: { isChosenNow }, set: { _ in choose(target.id) }))
            }
        }
        .disabled(!isEnabled(.aimAt))
    }
}

/// One command as a menu item. It is a view of its own so that it asks
/// "can this act now?" and "what is my shortcut now?" in its own body, and is
/// drawn again when either answer changes.
private struct AppCommandItem: View {
    let command: AppCommand
    let shortcuts: ShortcutStore
    let typing: TypingWatch
    let perform: @MainActor (AppCommand) -> Void
    let isEnabled: @MainActor (AppCommand) -> Bool
    let isOn: @MainActor (AppCommand) -> Bool
    let title: @MainActor (AppCommand) -> String

    var body: some View {
        let shortcut = shortcutNow
        item
            .keyboardShortcut(shortcut?.keyboardShortcut)
            .disabled(!isEnabled(command))
            // A new shortcut makes a new menu item, so the menu cannot go on showing
            // the old one. SwiftUI has not always updated the shortcut of an item it keeps.
            .id(shortcut)
    }

    /// A command that switches something on and off is an item with a tick while it is
    /// on. Choosing it performs the command, like any other item.
    @ViewBuilder private var item: some View {
        if command.isToggle {
            // Asked here, in the item's own body, so the tick is drawn again when it changes.
            let isOnNow = isOn(command)
            Toggle(title(command), isOn: Binding(get: { isOnNow }, set: { _ in perform(command) }))
        } else {
            // Asked here, in the item's own body, so the title is drawn again when it changes.
            Button(title(command)) { perform(command) }
        }
    }

    /// The shortcut the item has at this moment: the one in force, or none while its
    /// key would be taken away from text that is being typed.
    private var shortcutNow: Shortcut? {
        guard let shortcut = shortcuts.shortcut(for: command) else { return nil }
        if shortcut.isTextKey, typing.isTyping {
            return nil
        }
        return shortcut
    }
}

/// Edit > Undo and Edit > Redo, named after the edit they act on ("Undo Move
/// Beat"). A view of its own, so the titles are read in its own body and the
/// items are drawn again after every edit, undo and redo.
private struct UndoRedoItems: View {
    let store: ProjectStore
    let canUndo: @MainActor () -> Bool
    let undo: (@MainActor () -> Void)?
    let redo: (@MainActor () -> Void)?

    var body: some View {
        let mayAct = canUndo()
        Button(store.undoTitle ?? "Undo") { undo?() ?? store.undo() }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(store.undoTitle == nil || !mayAct)
        Button(store.redoTitle ?? "Redo") { redo?() ?? store.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(store.redoTitle == nil || !mayAct)
    }
}

/// Edit > Cut, Copy, Paste and Select All. Each is sent to whatever has the keyboard,
/// in any window, exactly as the system's own items are. Cut and Paste are greyed out
/// while no text is being typed. Copy and Select All stay, because text that can only
/// be read, such as the timecode in the Send to DaVinci panel, can be selected and copied.
///
/// Copy and Paste are also Copy and Paste of clips (`AppCommand.copyClips`, `.pasteClips`),
/// with the shortcuts Settings has for them. While text is typed they act on the text, as
/// before. Otherwise they act on the clips when they can, and on selected text when they
/// cannot, so the timecode can still be copied.
private struct TextEditItems: View {
    let typing: TypingWatch
    let shortcuts: ShortcutStore
    /// Whether copying clips is a finished feature. Without it Copy and Paste are only the text's.
    let clipsBuilt: Bool
    let perform: @MainActor (AppCommand) -> Void
    let isEnabled: @MainActor (AppCommand) -> Bool

    var body: some View {
        // Read here, so the items are drawn again when typing starts or stops.
        let isTyping = typing.isTyping
        Button("Cut") { send(#selector(NSText.cut(_:))) }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(!isTyping)
        let copyShortcut = shortcut(for: .copyClips)
        Button("Copy") { textOrClips(#selector(NSText.copy(_:)), .copyClips) }
            .keyboardShortcut(copyShortcut?.keyboardShortcut)
            .id(copyShortcut)
        let pasteShortcut = shortcut(for: .pasteClips)
        Button("Paste") { textOrClips(#selector(NSText.paste(_:)), .pasteClips) }
            .keyboardShortcut(pasteShortcut?.keyboardShortcut)
            .disabled(!isTyping && !(clipsBuilt && isEnabled(.pasteClips)))
            .id(pasteShortcut)
        Button("Select All") { send(#selector(NSText.selectAll(_:))) }
            .keyboardShortcut("a", modifiers: .command)
    }

    /// The shortcut of Copy or Paste: the one Settings has for the clips' command, or the
    /// system's own when copying clips is not built.
    private func shortcut(for command: AppCommand) -> Shortcut? {
        clipsBuilt ? shortcuts.shortcut(for: command) : command.defaultShortcut
    }

    /// Sends the text's action while text is typed, or when the clips' command cannot act
    /// now, and carries out the command otherwise. Whether text is typed is asked at this
    /// moment, since `typing` hears of it a moment later.
    private func textOrClips(_ action: Selector, _ command: AppCommand) {
        let isTyping = TypingWatch.isTyping(in: NSApplication.shared.keyWindow)
        if clipsBuilt, !isTyping, isEnabled(command) {
            perform(command)
        } else {
            send(action)
        }
    }

    private func send(_ action: Selector) {
        NSApplication.shared.sendAction(action, to: nil, from: nil)
    }
}

extension Shortcut {
    /// The shortcut in the form SwiftUI menus take.
    var keyboardShortcut: KeyboardShortcut? {
        guard let keyEquivalent else { return nil }
        var eventModifiers: EventModifiers = []
        for modifier in modifiers {
            switch modifier {
            case .control: eventModifiers.insert(.control)
            case .option: eventModifiers.insert(.option)
            case .shift: eventModifiers.insert(.shift)
            case .command: eventModifiers.insert(.command)
            }
        }
        return KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch key {
        case Shortcut.space: return .space
        case Shortcut.home: return .home
        case Shortcut.end: return .end
        case Shortcut.pageUp: return .pageUp
        case Shortcut.pageDown: return .pageDown
        case Shortcut.return: return .return
        case Shortcut.tab: return .tab
        case Shortcut.escape: return .escape
        case Shortcut.delete: return .delete
        case Shortcut.forwardDelete: return .deleteForward
        case Shortcut.up: return .upArrow
        case Shortcut.down: return .downArrow
        case Shortcut.left: return .leftArrow
        case Shortcut.right: return .rightArrow
        default: break
        }
        if let number = (1...Shortcut.functionKeyCount).first(where: { Shortcut.functionKey($0) == key }),
           let scalar = Unicode.Scalar(UInt32(NSF1FunctionKey + number - 1)) {
            return KeyEquivalent(Character(scalar))
        }
        return key.count == 1 ? KeyEquivalent(Character(key)) : nil
    }
}

extension ShortcutStore {
    /// The app's one store of shortcuts. The menu bar and the Shortcuts pane both use
    /// it. It keeps Max's changes in the app's settings: his own, or a scratch
    /// folder's when an agent checks the app.
    static let app = ShortcutStore(settings: LaunchOptions.current.settings)
}

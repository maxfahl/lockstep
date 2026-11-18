import Foundation
import Observation

/// Keeps the shortcuts Max chose and says which shortcut is in force for each command.
///
/// A command Max never touched has its default from `AppCommand`. Only what he changed is
/// kept, so a default that a later version changes still reaches the commands he left alone.
///
///     let store = ShortcutStore(settings: settings)
///     store.shortcut(for: .playStop)                       // Space, the default
///     store.set(Shortcut("p"), for: .playStop)             // .saved
///     store.set(Shortcut("p"), for: .clickOnOff)           // .conflict(with: .playStop)
///     store.set(Shortcut("p"), for: .clickOnOff, replacing: .playStop)
///     store.shortcut(for: .playStop)                       // nil, it was taken away
///     store.set(Shortcut("q", modifiers: [.command]), for: .playStop)   // .reserved
///     store.set(nil, for: .zoomIn)                         // no shortcut at all
///     store.reset(.playStop)                               // Space again
///
/// Views that read `shortcut(for:)` are drawn again when a shortcut changes, which is how
/// the menu bar always shows the shortcut in force.
///
/// Kept in the settings under the key `shortcuts`, as a dictionary from the command's
/// name in `AppCommand` to `Shortcut.savedText`, or to "none" for a command whose
/// shortcut was taken away:
///
///     shortcuts = { playStop = "p"; zoomIn = "none"; createClickTrack = "option+command+k"; }
///
/// Only commands whose feature is built, and that can have a shortcut, take part. A
/// shortcut held by a command that is not built yet blocks nothing.
@MainActor
@Observable
public final class ShortcutStore {
    /// What became of an attempt to give a command a shortcut.
    public enum SetResult: Equatable, Sendable {
        /// It is kept and in force.
        case saved
        /// Another command has this shortcut. Nothing was changed.
        case conflict(with: AppCommand)
        /// macOS or one of the standard menus uses this shortcut. Nothing was changed.
        case reserved
    }

    /// The key in the settings under which the changed shortcuts are kept.
    public nonisolated static let settingsKey = "shortcuts"
    /// What is kept for a command whose shortcut was taken away.
    public nonisolated static let noShortcut = "none"

    /// The shortcuts of macOS and of the standard menus. No Lockstep command can have one.
    public nonisolated static let reserved: Set<Shortcut> = [
        Shortcut("q", modifiers: [.command]),
        Shortcut("w", modifiers: [.command]),
        Shortcut("h", modifiers: [.command]),
        Shortcut("m", modifiers: [.command]),
        Shortcut(",", modifiers: [.command]),
        Shortcut("z", modifiers: [.command]),
        Shortcut("z", modifiers: [.shift, .command]),
        Shortcut("x", modifiers: [.command]),
        Shortcut("c", modifiers: [.command]),
        Shortcut("v", modifiers: [.command]),
        Shortcut("a", modifiers: [.command]),
        // Hide Others in the Lockstep menu and Enter Full Screen in the View menu.
        Shortcut("h", modifiers: [.option, .command]),
        Shortcut("f", modifiers: [.control, .command]),
    ]

    /// The commands that can have a shortcut in this version of the app, in the order
    /// of the list in `AppCommand`.
    public let commands: [AppCommand]

    /// The shortcut in force for every command that has one.
    private var inForce: [AppCommand: Shortcut]
    /// What Max changed, as it is kept in the settings.
    @ObservationIgnored private var changes: [String: String]
    @ObservationIgnored private let settings: UserDefaults

    /// - Parameters:
    ///   - settings: where the changes are kept. The app passes its own settings store, a
    ///     test a throwaway one.
    ///   - built: the finished features. Commands of other features are left out.
    public init(settings: UserDefaults, built: FeatureSet = .built) {
        self.settings = settings
        let commands = AppCommand.allCases.filter { $0.takesShortcut && built.isSuperset(of: $0.feature) }
        self.commands = commands
        let changes = (settings.dictionary(forKey: Self.settingsKey) ?? [:]).compactMapValues { $0 as? String }
        self.changes = changes
        inForce = Self.resolve(changes, for: commands)
    }

    /// The shortcut in force: Max's choice, or the default, or nil when the command has none.
    public func shortcut(for command: AppCommand) -> Shortcut? {
        inForce[command]
    }

    /// The command that has this shortcut right now, or nil when none has. A shortcut belongs to one
    /// command at most.
    public func command(for shortcut: Shortcut) -> AppCommand? {
        inForce.first { $0.value == shortcut }?.key
    }

    /// True when the command has the shortcut it started with.
    public func hasDefault(_ command: AppCommand) -> Bool {
        shortcut(for: command) == command.defaultShortcut
    }

    /// Gives a command a shortcut, or none at all with nil.
    @discardableResult
    public func set(_ shortcut: Shortcut?, for command: AppCommand) -> SetResult {
        change(shortcut, for: command, replacing: nil)
    }

    /// Gives a command a shortcut that `other` has, and leaves `other` without one. For
    /// the "Replace" answer after `set(_:for:)` reported a conflict.
    @discardableResult
    public func set(_ shortcut: Shortcut, for command: AppCommand, replacing other: AppCommand) -> SetResult {
        change(shortcut, for: command, replacing: other)
    }

    /// Gives a command its default back. When another command has that shortcut by now,
    /// the answer is the conflict and nothing changes. `set(_:for:replacing:)` with the
    /// default then takes it back.
    @discardableResult
    public func reset(_ command: AppCommand) -> SetResult {
        change(command.defaultShortcut, for: command, replacing: nil)
    }

    /// Gives every command its default back.
    public func resetAll() {
        keep([:])
    }

    private func change(_ shortcut: Shortcut?, for command: AppCommand, replacing other: AppCommand?) -> SetResult {
        // A submenu takes no shortcut, so there is nothing to keep for it.
        guard command.takesShortcut else { return .saved }
        var changes = self.changes
        if let shortcut {
            if Self.reserved.contains(shortcut) {
                return .reserved
            }
            if let holder = inForce.first(where: { $0.value == shortcut })?.key, holder != command {
                guard holder == other else { return .conflict(with: holder) }
                Self.note(nil, for: holder, in: &changes)
            }
        }
        Self.note(shortcut, for: command, in: &changes)
        keep(changes)
        return .saved
    }

    /// Writes one command's shortcut into the changes. A command that is back on its
    /// default is no longer a change.
    private static func note(_ shortcut: Shortcut?, for command: AppCommand, in changes: inout [String: String]) {
        if shortcut == command.defaultShortcut {
            changes[command.rawValue] = nil
        } else {
            changes[command.rawValue] = shortcut?.savedText ?? noShortcut
        }
    }

    private func keep(_ changes: [String: String]) {
        self.changes = changes
        if changes.isEmpty {
            settings.removeObject(forKey: Self.settingsKey)
        } else {
            settings.set(changes, forKey: Self.settingsKey)
        }
        inForce = Self.resolve(changes, for: commands)
    }

    /// Works out the shortcut in force for each command.
    ///
    /// Max's choices come first. A default that one of his choices already uses is left
    /// out, so a command that arrives in a later version never takes a key away from the
    /// command he gave it to. Kept text that cannot be read, or that names a reserved
    /// shortcut, counts as never changed.
    private static func resolve(_ changes: [String: String], for commands: [AppCommand]) -> [AppCommand: Shortcut] {
        var inForce: [AppCommand: Shortcut] = [:]
        var taken: Set<Shortcut> = []
        var changed: Set<AppCommand> = []
        for command in commands {
            guard let text = changes[command.rawValue] else { continue }
            if text.lowercased() == noShortcut {
                changed.insert(command)
                continue
            }
            guard let shortcut = Shortcut(savedText: text), !reserved.contains(shortcut) else { continue }
            changed.insert(command)
            if taken.insert(shortcut).inserted {
                inForce[command] = shortcut
            }
        }
        for command in commands where !changed.contains(command) {
            if let shortcut = command.defaultShortcut, taken.insert(shortcut).inserted {
                inForce[command] = shortcut
            }
        }
        return inForce
    }
}

import SwiftUI

/// The right-click menu of the song row, with its commands in the order of
/// the list of commands. Choosing "Create Click Track..." or one of the three
/// commands about the beats calls `onCommand`.
///
///     songRow.songMenu(SongMenu.Values())
public struct SongMenu: View {
    /// What the menu ticks, greys out and leaves out. Fake values until the
    /// song works.
    public struct Values: Sendable {
        /// False leaves out "Create Click Track...", as in the real app
        /// before the click works.
        public var showsCreateClickTrack = true
        /// False greys out "Create Click Track...": the beats are not found yet.
        public var canCreateClickTrack = true
        /// False greys out "Halve Tempo": the beats are already at half tempo.
        public var canHalveTempo = true
        /// False greys out "Double Tempo": the beats are already at double tempo.
        public var canDoubleTempo = true

        public init() {}
    }

    /// A command of this menu that reports back when it is chosen.
    public enum Command: Sendable {
        case createClickTrack
        case findBeatsAgain
        case halveTempo
        case doubleTempo
    }

    private let values: Values
    private let onCommand: (@MainActor (Command) -> Void)?

    /// - Parameters:
    ///   - values: What the menu ticks, greys out and leaves out.
    ///   - onCommand: Told which command that reports back was chosen. Left
    ///     out, choosing one does nothing.
    public init(_ values: Values = Values(), onCommand: (@MainActor (Command) -> Void)? = nil) {
        self.values = values
        self.onCommand = onCommand
    }

    /// The lines of the menu, for `MenuListing`.
    public var entries: [MenuEntry] {
        var entries: [MenuEntry] = []
        if values.showsCreateClickTrack {
            entries += [
                .command(
                    "Create Click Track...",
                    shortcut: MenuShortcut("k", modifiers: [.shift, .command]),
                    isEnabled: values.canCreateClickTrack,
                    action: action(.createClickTrack)
                ),
                .divider,
            ]
        }
        entries += [
            .command("Find Beats Again", action: action(.findBeatsAgain)),
            .command("Halve Tempo", isEnabled: values.canHalveTempo, action: action(.halveTempo)),
            .command("Double Tempo", isEnabled: values.canDoubleTempo, action: action(.doubleTempo)),
        ]
        return entries
    }

    private func action(_ command: Command) -> (@MainActor () -> Void)? {
        guard let onCommand else { return nil }
        return { onCommand(command) }
    }

    public var body: some View {
        MenuEntries(entries)
    }
}

extension View {
    /// Opens the song's menu on a right-click. `onCommand` is told which
    /// command about the beats was chosen.
    public func songMenu(
        _ values: SongMenu.Values = SongMenu.Values(),
        onCommand: (@MainActor (SongMenu.Command) -> Void)? = nil
    ) -> some View {
        contextMenu { SongMenu(values, onCommand: onCommand) }
    }
}

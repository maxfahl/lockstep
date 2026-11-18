import LockstepCore
import SwiftUI

/// The menu a track's Sound is chosen from. It opens from the box under the heading "Sound" in the panel on
/// the right (`SoundMenuButton`).
///
/// From the top: None, the six built-in presets, under a line the presets Max saved himself, and under
/// another line "Save as Preset..." and "Delete Preset", which lists his own presets again. The line of the
/// Sound the track has is ticked: None for a track without one.
///
///     Menu { SoundMenu(soundName: "Rap lead", ownPresets: ["My hook"]) { command in ... } } label: { ... }
public struct SoundMenu: View {
    /// What a line of the menu asks for.
    public enum Command: Sendable, Equatable {
        /// The preset with this name was chosen, a built-in one or one of Max's own. Nil is None.
        case chosen(String?)
        /// "Save as Preset..." was chosen: the owner asks for a name and keeps the track's Sound under it.
        case saveAsPreset
        /// Max's own preset with this name was chosen under "Delete Preset".
        case deletePreset(String)
    }

    /// The names of the six built-in presets, in the order of the menu.
    public static let builtInPresets = SoundPreset.builtIn.map(\.name)

    private let soundName: String?
    private let ownPresets: [String]
    private let onCommand: (@MainActor (Command) -> Void)?

    /// - Parameters:
    ///   - soundName: The name of the track's Sound, whose line is ticked. Nil for a track without one.
    ///   - ownPresets: The names of Max's own presets, in the order he saved them.
    ///   - onCommand: Told which line was chosen. Left out, choosing a line does nothing.
    public init(
        soundName: String?,
        ownPresets: [String] = [],
        onCommand: (@MainActor (Command) -> Void)? = nil
    ) {
        self.soundName = soundName
        self.ownPresets = ownPresets
        self.onCommand = onCommand
    }

    /// The lines of the menu, for `MenuListing`.
    public var entries: [MenuEntry] {
        var entries: [MenuEntry] = [
            .command("None", isChecked: soundName == nil, action: action(.chosen(nil))),
        ]
        entries += Self.builtInPresets.map(presetLine)
        entries.append(.divider)
        if !ownPresets.isEmpty {
            entries += ownPresets.map(presetLine)
            entries.append(.divider)
        }
        // There is nothing to save of a track without a Sound.
        entries.append(.command("Save as Preset...", isEnabled: soundName != nil, action: action(.saveAsPreset)))
        if ownPresets.isEmpty {
            entries.append(.command("Delete Preset", isEnabled: false))
        } else {
            entries.append(.submenu(
                title: "Delete Preset",
                entries: ownPresets.map { name in .command(name, action: action(.deletePreset(name))) }
            ))
        }
        return entries
    }

    /// The line of one preset, ticked when the track's Sound has its name, whatever the letters' case.
    private func presetLine(_ name: String) -> MenuEntry {
        let isChosen = soundName.map { $0.compare(name, options: .caseInsensitive) == .orderedSame } ?? false
        return .command(name, isChecked: isChosen, action: action(.chosen(name)))
    }

    private func action(_ command: Command) -> (@MainActor () -> Void)? {
        guard let onCommand else { return nil }
        return { onCommand(command) }
    }

    public var body: some View {
        MenuEntries(entries)
    }
}

import LockstepCore
import SwiftUI

/// The menu a track's Voice is chosen from. It opens from the box under the heading "Voice" in the panel on
/// the right (`VoiceSection`), and its presets are also the submenu "Voice" of a track's right-click menu
/// (`TrackMenu`).
///
/// In the panel, from the top: the three built-in presets, under a line the presets Max saved himself, and
/// under another line "Save as Preset..." and "Delete Preset", which lists his own presets again
/// (`entries`). The line of the preset the track's Voice was chosen as is ticked, and none is for a Voice
/// that reads "Custom". There is no line that takes the Voice away: the switch in the heading's line turns
/// it off and keeps its knobs.
///
/// In a track's menu: "Voice On or Off", ticked while the Voice is on, and under a line every preset
/// (`trackEntries`).
///
///     Menu { VoiceMenu(voice: track.voice, ownPresets: ["Villain"]) { command in ... } } label: { ... }
public struct VoiceMenu: View {
    /// What a line of the menu asks for.
    public enum Command: Sendable, Equatable {
        /// "Voice On or Off" was chosen in a track's menu: the Voice is switched to what it is not. A track
        /// that never had a Voice gets one.
        case onOrOff
        /// The preset with this name was chosen, a built-in one or one of Max's own. The track gets its
        /// knobs, switched on.
        case chosen(String)
        /// "Save as Preset..." was chosen: the owner asks for a name and keeps the track's two knobs under it.
        case saveAsPreset
        /// Max's own preset with this name was chosen under "Delete Preset".
        case deletePreset(String)
    }

    /// The names of the three built-in presets, in the order of the menu.
    public static let builtInPresets = VoicePresets.builtIn.map(\.name)

    private let voice: TrackVoice?
    private let ownPresets: [String]
    private let isEnabled: Bool
    private let onCommand: (@MainActor (Command) -> Void)?

    /// - Parameters:
    ///   - voice: The track's Voice: the line of its preset is ticked. Nil for a track that never had one.
    ///   - ownPresets: The names of Max's own presets, in the order he saved them.
    ///   - isEnabled: False greys out every line, as while a take is going.
    ///   - onCommand: Told which line was chosen. Left out, choosing a line does nothing.
    public init(
        voice: TrackVoice?,
        ownPresets: [String] = [],
        isEnabled: Bool = true,
        onCommand: (@MainActor (Command) -> Void)? = nil
    ) {
        self.voice = voice
        self.ownPresets = ownPresets
        self.isEnabled = isEnabled
        self.onCommand = onCommand
    }

    /// The lines of the menu of the box in the panel, for `MenuListing`.
    public var entries: [MenuEntry] {
        var entries = presetLines
        entries.append(.divider)
        // There is nothing to save of a track that never had a Voice.
        entries.append(.command(
            "Save as Preset...",
            isEnabled: isEnabled && voice != nil,
            action: action(.saveAsPreset)
        ))
        if ownPresets.isEmpty {
            entries.append(.command("Delete Preset", isEnabled: false))
        } else {
            entries.append(.submenu(
                title: "Delete Preset",
                entries: ownPresets.map { name in
                    .command(name, isEnabled: isEnabled, action: action(.deletePreset(name)))
                }
            ))
        }
        return entries
    }

    /// The lines of the submenu "Voice" of a track's menu: the switch as a command, and every preset.
    public var trackEntries: [MenuEntry] {
        [
            .command("Voice On or Off", isChecked: voice?.isOn ?? false, isEnabled: isEnabled, action: action(.onOrOff)),
            .divider,
        ]
            + presetLines
    }

    /// The built-in presets, and under a line Max's own when he has any.
    private var presetLines: [MenuEntry] {
        var lines = Self.builtInPresets.map(presetLine)
        if !ownPresets.isEmpty {
            lines.append(.divider)
            lines += ownPresets.map(presetLine)
        }
        return lines
    }

    /// The line of one preset, ticked when the track's Voice has its name, whatever the letters' case. A
    /// Voice that is switched off keeps its tick, as it keeps its knobs.
    private func presetLine(_ name: String) -> MenuEntry {
        let isChosen = voice.map { $0.name.compare(name, options: .caseInsensitive) == .orderedSame } ?? false
        return .command(name, isChecked: isChosen, isEnabled: isEnabled, action: action(.chosen(name)))
    }

    private func action(_ command: Command) -> (@MainActor () -> Void)? {
        guard let onCommand else { return nil }
        return { onCommand(command) }
    }

    public var body: some View {
        MenuEntries(entries)
    }
}

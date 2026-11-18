import LockstepCore
import SwiftUI

/// The right-click menu of a track's header, with its commands in the order
/// of the list of commands. Choosing one calls `onCommand`. Choosing a kind
/// under Effects, the menu that adds an effect to the track (`EffectsMenu`),
/// calls `onEffect`. Choosing a line under Voice, the track's Voice switched
/// on or off or a preset (`VoiceMenu`), calls `onVoice`.
///
///     TrackHeader(track: track)
///         .trackMenu(TrackMenu.Values(isMuted: track.muted, otherTrackNames: ["Lead"]))
///
/// The real app shows only the commands whose feature is finished
/// (`Values.features`).
public struct TrackMenu: View {
    /// What the menu ticks, lists and greys out. Fake values in the design lab.
    public struct Values: Sendable, Equatable {
        /// Ticks Mute Track.
        public var isMuted: Bool
        /// The other tracks, from top to bottom: the choices of Merge Into.
        /// With none, Merge Into is greyed out.
        public var otherTrackNames: [String]
        /// False greys out Delete Track, as for the last track left.
        public var canDelete: Bool
        /// The ids of the other tracks, in the order of `otherTrackNames`, so
        /// a choice in Merge Into can say which track was chosen. Left empty,
        /// as in the design lab, the choices do nothing.
        public var otherTrackIDs: [UUID] = []
        /// False greys out Copy Sound, as while a take is going. Set it after
        /// making the values.
        public var canCopySound = true
        /// False greys out Paste Sound: no sound was copied yet, or a take is
        /// going. Set it after making the values.
        public var canPasteSound = true
        /// The track's Voice: the submenu Voice ticks "Voice On or Off"
        /// while it is on, and the preset it was chosen as. Nil for a track
        /// that never had one. Set it after making the values.
        public var voice: TrackVoice?
        /// The names of Max's own presets of a Voice, which the submenu
        /// Voice lists under the built-in ones. Set it after making the
        /// values.
        public var ownVoicePresets: [String] = []
        /// False greys out every line of the submenu Voice, as while a take
        /// is going. Set it after making the values.
        public var canChangeVoice = true
        /// The features whose commands are in the menu: Normalize Track comes
        /// with `volume`, the Voice submenu with `trackVoice`, the Effects
        /// submenu with `trackEffects` (and `doubles` or `wordEffects`, for
        /// its lines), Copy Sound and Paste Sound with `soundCopy`. Left
        /// alone, every command is there, as the design shows the menu.
        public var features: FeatureSet = .all

        public init(isMuted: Bool = false, otherTrackNames: [String] = [], canDelete: Bool = true) {
            self.isMuted = isMuted
            self.otherTrackNames = otherTrackNames
            self.canDelete = canDelete
        }
    }

    /// A command of this menu that reports back when it is chosen.
    public enum Command: Sendable, Equatable {
        case rename
        case duplicate
        case duplicateWithClips
        /// Merge Into, with the id of the track that was chosen in its submenu.
        case mergeInto(UUID)
        case mute
        case normalize
        /// Copy Sound: the track's Sound and its effects are copied.
        case copySound
        /// Paste Sound: the track gets the copied sound.
        case pasteSound
        case delete
    }

    private let values: Values
    private let onCommand: (@MainActor (Command) -> Void)?
    private let onEffect: (@MainActor (ClipEffect.Kind) -> Void)?
    private let onVoice: (@MainActor (VoiceMenu.Command) -> Void)?

    /// - Parameters:
    ///   - values: What the menu ticks, lists, greys out and leaves out.
    ///   - onCommand: Told which command was chosen. Left out, choosing one
    ///     does nothing.
    ///   - onEffect: Told which kind was chosen under Effects. It is told
    ///     apart from `onCommand` as in the clip's menu, because the panel
    ///     on the right adds the same kinds. Left out, choosing a kind does
    ///     nothing.
    ///   - onVoice: Told which line was chosen under Voice. It is told apart
    ///     too, because the panel on the right chooses the same presets.
    ///     Left out, choosing a line does nothing.
    public init(
        _ values: Values = Values(),
        onCommand: (@MainActor (Command) -> Void)? = nil,
        onEffect: (@MainActor (ClipEffect.Kind) -> Void)? = nil,
        onVoice: (@MainActor (VoiceMenu.Command) -> Void)? = nil
    ) {
        self.values = values
        self.onCommand = onCommand
        self.onEffect = onEffect
        self.onVoice = onVoice
    }

    /// The lines of the menu, for `MenuListing`.
    public var entries: [MenuEntry] {
        var sound: [MenuEntry] = []
        if values.features.contains(.volume) {
            sound.append(.command(
                "Normalize Track",
                shortcut: MenuShortcut("l", modifiers: [.shift, .command]),
                action: action(.normalize)
            ))
        }
        sound.append(.command(
            "Mute Track",
            shortcut: MenuShortcut("m"),
            isChecked: values.isMuted,
            action: action(.mute)
        ))
        if values.features.contains(.trackVoice) {
            // Before Effects, as in the panel on the right: the voice is changed first, and the effects
            // act on the changed voice.
            sound.append(.submenu(
                title: "Voice",
                entries: VoiceMenu(
                    voice: values.voice,
                    ownPresets: values.ownVoicePresets,
                    isEnabled: values.canChangeVoice,
                    onCommand: onVoice
                ).trackEntries
            ))
        }
        if values.features.contains(.trackEffects), !values.features.isDisjoint(with: EffectsMenu.features) {
            // The lines of the "+" in the track part of the panel on the right, so the two read the same.
            sound.append(.submenu(
                title: "Effects",
                entries: EffectsMenu(features: values.features, target: .track, onChosen: onEffect).entries
            ))
        }
        if values.features.contains(.soundCopy) {
            sound += [
                .divider,
                .command(
                    "Copy Sound",
                    shortcut: MenuShortcut("c", modifiers: [.option, .command]),
                    isEnabled: values.canCopySound,
                    action: action(.copySound)
                ),
                .command(
                    "Paste Sound",
                    shortcut: MenuShortcut("v", modifiers: [.option, .command]),
                    isEnabled: values.canPasteSound,
                    action: action(.pasteSound)
                ),
            ]
        }
        return [
            .command("Rename Track", action: action(.rename)),
            .divider,
            .command("Duplicate Track", shortcut: MenuShortcut("d", modifiers: .command), action: action(.duplicate)),
            .command(
                "Duplicate Track with Clips",
                shortcut: MenuShortcut("d", modifiers: [.shift, .command]),
                action: action(.duplicateWithClips)
            ),
            mergeInto,
            .divider,
        ]
            + sound
            + [
                .divider,
                .command(
                    "Delete Track",
                    shortcut: MenuShortcut(.delete, modifiers: .command),
                    isEnabled: values.canDelete,
                    action: action(.delete)
                ),
            ]
    }

    /// A submenu of the other tracks, or a greyed-out line when there are none.
    private var mergeInto: MenuEntry {
        if values.otherTrackNames.isEmpty {
            return .command("Merge Into", isEnabled: false)
        }
        let ids = values.otherTrackIDs
        return .submenu(title: "Merge Into", entries: values.otherTrackNames.enumerated().map { index, name in
            .command(name, action: ids.indices.contains(index) ? action(.mergeInto(ids[index])) : nil)
        })
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
    /// Opens the track's menu on a right-click. `onCommand` is told which
    /// command was chosen, `onEffect` which kind was chosen under Effects,
    /// and `onVoice` which line was chosen under Voice.
    public func trackMenu(
        _ values: TrackMenu.Values = TrackMenu.Values(),
        onCommand: (@MainActor (TrackMenu.Command) -> Void)? = nil,
        onEffect: (@MainActor (ClipEffect.Kind) -> Void)? = nil,
        onVoice: (@MainActor (VoiceMenu.Command) -> Void)? = nil
    ) -> some View {
        contextMenu { TrackMenu(values, onCommand: onCommand, onEffect: onEffect, onVoice: onVoice) }
    }
}

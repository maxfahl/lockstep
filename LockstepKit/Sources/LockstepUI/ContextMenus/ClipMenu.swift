import LockstepCore
import SwiftUI

/// The right-click menu of a clip, with its commands in the order of the list
/// of commands. Choosing Rename Clip, Split at Playhead, Join Clips, Mute
/// Clip, Normalize, a choice of sub-beats, a line under Aim at, Copy Sound, Paste Sound, Delete Other Takes, Send to
/// DaVinci or Delete calls `onCommand`. Choosing a kind under Effects, the menu that adds an
/// effect to the clip (`EffectsMenu`), calls `onEffect`.
///
///     ClipView(clip: clip, viewport: viewport)
///         .clipMenu(ClipMenu.Values(isMuted: clip.muted))
///
/// The real app shows only the commands whose feature is finished
/// (`Values.features`). Mute Clip and Delete are always there.
public struct ClipMenu: View {
    /// A clip's sub-beats: the grid its lines are measured against. The interface calls it "Sub-beats", in
    /// this menu and in the panel on the right (`ClipSubBeatsChoice`). Each clip chooses for itself: the
    /// song has no sub-beats of its own.
    public enum Feel: CaseIterable, Sendable {
        /// Four parts to a beat. The starting value.
        case sixteenths
        /// Three parts to a beat.
        case triplets
        /// Whichever of the two the clip's own syllables fit.
        case auto

        /// The title of its line in the Sub-beats submenu, and of its part of the choice in the panel.
        public var title: String {
            switch self {
            case .sixteenths: "16ths"
            case .triplets: "Triplets"
            case .auto: "Auto"
            }
        }
    }

    /// What the menu ticks and greys out. Fake values until clips work.
    public struct Values: Sendable {
        /// Ticks Mute Clip.
        public var isMuted: Bool
        /// The feel that is ticked.
        public var feel: Feel
        /// False greys out Split at Playhead, as when the playhead is not
        /// inside the clip.
        public var canSplit: Bool
        /// False greys out Join Clips, as when only one clip is selected.
        public var canJoin: Bool
        /// False greys out Delete Other Takes, as for a clip with one take.
        public var hasOtherTakes: Bool
        /// The track the clip's correction aims at, whose line is ticked in the
        /// Aim at submenu. Nil, which is what the values start with, ticks
        /// "The beat". Set it after making the values.
        public var aimTrackID: UUID?
        /// The tracks the clip can aim at, in the order of the timeline: the
        /// lines of the Aim at submenu under "The beat". Set it after making
        /// the values.
        public var aimTracks: [AimTrack] = []
        /// False greys out Copy Sound, as while a take is going. Set it after
        /// making the values.
        public var canCopySound = true
        /// False greys out Paste Sound: no sound was copied yet, or a take is
        /// going. Set it after making the values.
        public var canPasteSound = true
        /// The features whose commands are in the menu: Rename Clip comes with
        /// `moveClips`, Split and Join with `clipEditing`, Normalize with
        /// `volume`, the Sub-beats submenu with `feel`, the Aim at submenu with
        /// `lockToLead`, Delete Other Takes with
        /// `takes`, Send to DaVinci with `sendToDaVinci`, the Effects submenu
        /// with `doubles` or `wordEffects`, and Copy Sound and Paste Sound
        /// with `soundCopy`. Left alone, every
        /// command is there, as the design shows the menu.
        public var features: FeatureSet = .all

        public init(
            isMuted: Bool = false,
            feel: Feel = .sixteenths,
            canSplit: Bool = true,
            canJoin: Bool = false,
            hasOtherTakes: Bool = false
        ) {
            self.isMuted = isMuted
            self.feel = feel
            self.canSplit = canSplit
            self.canJoin = canJoin
            self.hasOtherTakes = hasOtherTakes
        }
    }

    /// A command of this menu that reports back when it is chosen.
    public enum Command: Sendable {
        case rename
        case splitAtPlayhead
        case joinClips
        case muteClip
        case normalize
        /// A line of the Sub-beats submenu was chosen.
        case feel(Feel)
        /// A line of the Aim at submenu was chosen: the id of a track, or nil
        /// for "The beat".
        case aim(UUID?)
        /// Copy Sound: what the clip is heard with is copied, its track's
        /// Sound with the clip's own knobs and its effects on the whole clip.
        case copySound
        /// Paste Sound: the clip is given the copied sound.
        case pasteSound
        case deleteOtherTakes
        case sendToDaVinci
        case delete
    }

    private let values: Values
    private let onCommand: (@MainActor (Command) -> Void)?
    private let isEnabled: (@MainActor (Command) -> Bool)?
    private let onEffect: (@MainActor (ClipEffect.Kind) -> Void)?

    /// - Parameters:
    ///   - values: What the menu ticks, greys out and leaves out.
    ///   - onCommand: Told which command that reports back was chosen. Left
    ///     out, choosing one does nothing.
    ///   - isEnabled: Asked, when the menu is made, whether Split at Playhead
    ///     and Join Clips can act right now. The answer takes the place of
    ///     `values.canSplit` and `values.canJoin`, which cannot know where
    ///     the playhead is. Left out, the values decide.
    ///   - onEffect: Told which kind was chosen under Effects. It is told
    ///     apart from `onCommand` because the kinds are not commands of this
    ///     menu alone: the panel on the right adds the same ones. Left out,
    ///     choosing a kind does nothing.
    public init(
        _ values: Values = Values(),
        onCommand: (@MainActor (Command) -> Void)? = nil,
        isEnabled: (@MainActor (Command) -> Bool)? = nil,
        onEffect: (@MainActor (ClipEffect.Kind) -> Void)? = nil
    ) {
        self.values = values
        self.onCommand = onCommand
        self.isEnabled = isEnabled
        self.onEffect = onEffect
    }

    /// The lines of the menu, for `MenuListing`. The commands stand in
    /// groups with a divider between two groups, and a group whose features
    /// are all missing is left out with its divider.
    public var entries: [MenuEntry] {
        let features = values.features
        var groups: [[MenuEntry]] = []
        if features.contains(.moveClips) {
            groups.append([.command("Rename Clip", action: action(.rename))])
        }
        if features.contains(.clipEditing) {
            groups.append([
                .command(
                    "Split at Playhead",
                    shortcut: MenuShortcut("b", modifiers: .command),
                    isEnabled: isEnabled?(.splitAtPlayhead) ?? values.canSplit,
                    action: action(.splitAtPlayhead)
                ),
                .command(
                    "Join Clips",
                    shortcut: MenuShortcut("j", modifiers: .command),
                    isEnabled: isEnabled?(.joinClips) ?? values.canJoin,
                    action: action(.joinClips)
                ),
            ])
        }
        var sound: [MenuEntry] = [
            .command(
                "Mute Clip",
                shortcut: MenuShortcut("m", modifiers: .shift),
                isChecked: values.isMuted,
                action: action(.muteClip)
            ),
        ]
        if features.contains(.volume) {
            sound.append(.command(
                "Normalize",
                shortcut: MenuShortcut("l", modifiers: .command),
                action: action(.normalize)
            ))
        }
        if features.contains(.feel) {
            sound.append(.submenu(title: "Sub-beats", entries: Feel.allCases.map { feel in
                .command(feel.title, isChecked: feel == values.feel, action: action(.feel(feel)))
            }))
        }
        if features.contains(.lockToLead) {
            // The lines of the row "Aim at" in the panel on the right, so the two always read the same.
            sound.append(.submenu(
                title: "Aim at",
                entries: AimMenu(
                    aimTrackID: values.aimTrackID,
                    tracks: values.aimTracks,
                    onChosen: onCommand.map { onCommand in { trackID in onCommand(.aim(trackID)) } }
                ).entries
            ))
        }
        if !features.isDisjoint(with: EffectsMenu.features) {
            sound.append(.submenu(title: "Effects", entries: EffectsMenu(features: features, onChosen: onEffect).entries))
        }
        groups.append(sound)
        if features.contains(.soundCopy) {
            groups.append([
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
            ])
        }
        if features.contains(.takes) {
            groups.append([
                .command("Delete Other Takes", isEnabled: values.hasOtherTakes, action: action(.deleteOtherTakes)),
            ])
        }
        if features.contains(.sendToDaVinci) {
            groups.append([
                .command(
                    "Send to DaVinci...",
                    shortcut: MenuShortcut("e", modifiers: .command),
                    action: action(.sendToDaVinci)
                ),
            ])
        }
        groups.append([.command("Delete", shortcut: MenuShortcut(.delete), action: action(.delete))])
        return Array(groups.joined(separator: [.divider]))
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
    /// Opens the clip's menu on a right-click. `onCommand` is told when a
    /// command that reports back was chosen, and `isEnabled` is asked whether
    /// Split at Playhead and Join Clips can act, and `onEffect` is told which
    /// kind was chosen under Effects. See `ClipMenu.init`.
    public func clipMenu(
        _ values: ClipMenu.Values = ClipMenu.Values(),
        onCommand: (@MainActor (ClipMenu.Command) -> Void)? = nil,
        isEnabled: (@MainActor (ClipMenu.Command) -> Bool)? = nil,
        onEffect: (@MainActor (ClipEffect.Kind) -> Void)? = nil
    ) -> some View {
        contextMenu { ClipMenu(values, onCommand: onCommand, isEnabled: isEnabled, onEffect: onEffect) }
    }
}

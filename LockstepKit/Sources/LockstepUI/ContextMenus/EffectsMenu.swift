import LockstepCore
import SwiftUI

/// The menu that adds an effect, to clips or to a track. It opens from the small button in the line of the
/// heading "Effects" in the panel on the right (`AddEffectButton`), and it is the submenu "Effects" of a
/// clip's right-click menu (`ClipMenu`) and of a track's (`TrackMenu`).
///
/// For clips, two submenus: "Double" with the six doubles, and "On Words" with the six effects on words,
/// named as Clip > Effects names them in the menu bar. Each is there only with its feature (`doubles`,
/// `wordEffects`).
///
/// For a track (`Target.track`), the submenu "Double" with the six doubles and under it three lines, "Echo,
/// quarter notes", "Echo, eighth notes" and "Phone", as Track > Effects has them in the menu bar
/// (`ClipEffect.Kind.forTracks`). The three come with `wordEffects`. Stutter, tape stop and swell are not
/// offered for a track: they are for single words.
///
///     Menu { EffectsMenu(features: .all) { kind in ... } } label: { ... }
public struct EffectsMenu: View {
    /// What the chosen effect goes on.
    public enum Target: Sendable, Equatable {
        /// The words marked in a clip, or the whole of the selected clips.
        case clips
        /// A whole track: every clip of it.
        case track
    }

    /// The features that put a line in the menu. With none of them there is no menu to show.
    public static let features: FeatureSet = [.doubles, .wordEffects]

    private let features: FeatureSet
    private let target: Target
    private let onChosen: (@MainActor (ClipEffect.Kind) -> Void)?

    /// - Parameters:
    ///   - features: "Double" comes with `doubles`, "On Words" (for a track: the two echoes and Phone) with
    ///     `wordEffects`. Left alone, both are there.
    ///   - target: What the effect goes on, which decides the lines. Clips, unless said.
    ///   - onChosen: Told which kind was chosen. Left out, choosing a line does nothing.
    public init(
        features: FeatureSet = .all,
        target: Target = .clips,
        onChosen: (@MainActor (ClipEffect.Kind) -> Void)? = nil
    ) {
        self.features = features
        self.target = target
        self.onChosen = onChosen
    }

    /// The lines of the menu, for `MenuListing`.
    public var entries: [MenuEntry] {
        var entries: [MenuEntry] = []
        if features.contains(.doubles) {
            entries.append(.submenu(title: "Double", entries: ClipEffect.Kind.doubles.map(line)))
        }
        if features.contains(.wordEffects) {
            switch target {
            case .clips:
                entries.append(.submenu(title: "On Words", entries: ClipEffect.Kind.onWords.map(line)))
            case .track:
                // The kinds a track has besides the doubles stand in the menu itself: there are only three.
                entries += ClipEffect.Kind.forTracks.filter { !ClipEffect.Kind.doubles.contains($0) }.map(line)
            }
        }
        return entries
    }

    private func line(_ kind: ClipEffect.Kind) -> MenuEntry {
        .command(kind.menuTitle, action: action(kind))
    }

    private func action(_ kind: ClipEffect.Kind) -> (@MainActor () -> Void)? {
        guard let onChosen else { return nil }
        return { onChosen(kind) }
    }

    public var body: some View {
        MenuEntries(entries)
    }
}

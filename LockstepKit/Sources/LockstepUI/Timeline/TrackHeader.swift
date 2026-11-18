import LockstepCore
import SwiftUI

/// The header of a vocal track's row: the track's name, its mute button, and
/// an accent mark down the left edge when this is the selected track, the one
/// recordings go to.
///
/// It fills the header cell it is given. A muted track has its mute button
/// lit and its name a little dimmer. A long name is cut off; the button keeps
/// its size. Pressing the button does nothing, and neither does anything
/// else in the header, unless `actions` says who to tell (`TrackActions`).
///
/// A track that is being recorded to (`TrackRow.recording`) has the mark down
/// its left edge in the record red, and a red dot before its mute button. A
/// track that is being renamed (`TrackRow.isBeingRenamed`) has a text field in
/// place of its name.
public struct TrackHeader: View {
    private let track: TrackRow
    private let menu: TrackMenu.Values?
    private let actions: TrackActions?
    private let onMenuEffect: (@MainActor (ClipEffect.Kind) -> Void)?
    private let onMenuVoice: (@MainActor (VoiceMenu.Command) -> Void)?

    /// - Parameters:
    ///   - track: The track to show.
    ///   - menu: What the track's right-click menu ticks, lists and greys
    ///     out. Nil leaves the header without a menu.
    ///   - actions: Who is told when the mute button is pressed, when the
    ///     name is double-clicked, when the typing of a new name ends and
    ///     when a command is chosen in the menu. Left out, the header is a
    ///     picture.
    ///   - onMenuEffect: Told which kind was chosen under Effects in the
    ///     menu. Left out, choosing a kind does nothing.
    ///   - onMenuVoice: Told which line was chosen under Voice in the menu.
    ///     Left out, choosing a line does nothing.
    public init(
        track: TrackRow,
        menu: TrackMenu.Values? = nil,
        actions: TrackActions? = nil,
        onMenuEffect: (@MainActor (ClipEffect.Kind) -> Void)? = nil,
        onMenuVoice: (@MainActor (VoiceMenu.Command) -> Void)? = nil
    ) {
        self.track = track
        self.menu = menu
        self.actions = actions
        self.onMenuEffect = onMenuEffect
        self.onMenuVoice = onMenuVoice
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            if track.isBeingRenamed {
                TrackNameField(name: track.name, onEnd: renameEnd)
            } else {
                Text(track.name)
                    .font(DesignTokens.Fonts.laneName)
                    .foregroundStyle(
                        track.muted ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textPrimary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Together with the header's own click and drag, so a
                    // single click still selects at once and a drag that
                    // starts on the name still moves the track.
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { actions?.nameDoubleClicked?(track.id) },
                        isEnabled: actions?.nameDoubleClicked != nil
                    )
                Spacer(minLength: 0)
            }
            if track.recording != nil {
                TrackRecordingMark()
            }
            SymbolButton(
                symbol: track.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                name: "Mute",
                font: DesignTokens.Fonts.symbolSmall,
                color: track.muted ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary,
                showsOnFill: track.muted,
                action: { actions?.mutePressed?(track.id) }
            )
        }
        // Every name starts at the same place, with or without the mark.
        .padding(.leading, DesignTokens.Sizes.selectedTrackMarkWidth + DesignTokens.Spacing.headerPadding)
        .padding(.trailing, DesignTokens.Spacing.headerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            // Red while the track is recorded to, whether it is still the
            // selected track or not.
            if track.isSelected || track.recording != nil {
                Rectangle()
                    .fill(
                        track.recording != nil
                            ? DesignTokens.Colors.record
                            : DesignTokens.Colors.selectedTrackMark
                    )
                    .frame(width: DesignTokens.Sizes.selectedTrackMarkWidth)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(track.name)
        .accessibilityAddTraits(track.isSelected ? .isSelected : [])
        // The whole header opens the menu, also where it is empty.
        .contentShape(Rectangle())
        .trackMenu(ifShown: menu, onCommand: menuCommand, onEffect: onMenuEffect, onVoice: onMenuVoice)
    }

    /// What a command chosen in the track's menu reports to.
    private var menuCommand: (@MainActor (TrackMenu.Command) -> Void)? {
        guard let menuCommand = actions?.menuCommand else { return nil }
        let id = track.id
        return { command in menuCommand(command, id) }
    }

    /// What the name field tells when the typing is over, or nil for a field
    /// that is a picture.
    private var renameEnd: (@MainActor (String?) -> Void)? {
        guard let renameEnded = actions?.renameEnded else { return nil }
        let id = track.id
        return { name in renameEnded(id, name) }
    }
}

import LockstepCore
import SwiftUI

/// The menu that says what snapping catches on. It opens from the small
/// arrow beside the snapping button (`SnapToButton`), and Edit > Snap To in
/// the menu bar holds the same lines.
///
/// Four things to snap to, each ticked while it is on: Grid, Clip Edges,
/// Playhead and Recorded Place. Under a dividing line, the unit of the grid:
/// Sub-beats, Half Beats, Beats or Bars, with the one in force ticked.
///
///     Menu { SnapToMenu(choices) { changed in settings.snapChoices = changed } } label: { ... }
public struct SnapToMenu: View {
    private let choices: SnapChoices
    private let onChange: (@MainActor (SnapChoices) -> Void)?

    /// - Parameters:
    ///   - choices: What is ticked.
    ///   - onChange: Told the choices as they are after a line was chosen.
    ///     Left out, choosing a line does nothing.
    public init(_ choices: SnapChoices = SnapChoices(), onChange: (@MainActor (SnapChoices) -> Void)? = nil) {
        self.choices = choices
        self.onChange = onChange
    }

    /// The lines of the menu, for `MenuListing`.
    public var entries: [MenuEntry] {
        var entries: [MenuEntry] = [
            .command("Grid", isChecked: choices.grid, action: action { $0.grid.toggle() }),
            .command("Clip Edges", isChecked: choices.clipEdges, action: action { $0.clipEdges.toggle() }),
            .command("Playhead", isChecked: choices.playhead, action: action { $0.playhead.toggle() }),
            .command(
                "Recorded Place",
                isChecked: choices.recordedPlace,
                action: action { $0.recordedPlace.toggle() }
            ),
            .divider,
        ]
        entries += SnapGridUnit.allCases.map { unit in
            .command(
                "Grid in \(unit.title)",
                isChecked: unit == choices.gridUnit,
                action: action { $0.gridUnit = unit }
            )
        }
        return entries
    }

    /// What choosing a line does: the choices with that one change are reported.
    private func action(_ change: (inout SnapChoices) -> Void) -> (@MainActor () -> Void)? {
        guard let onChange else { return nil }
        var changed = choices
        change(&changed)
        return { onChange(changed) }
    }

    public var body: some View {
        MenuEntries(entries)
    }
}

/// The small arrow beside the snapping button, in the bar at the bottom of
/// the window. A press opens `SnapToMenu`. It looks like the arrow beside
/// the click button.
///
/// Without `onChange` it keeps what it shows itself: choosing a line only
/// changes the ticks, which is how the design lab shows it. With `onChange`
/// it shows `choices` as they are given and tells its owner what was chosen.
/// The owner then keeps the choices and hands in the new ones.
public struct SnapToButton: View {
    @State private var keptChoices: SnapChoices
    private let givenChoices: SnapChoices
    private let onChange: (@MainActor (SnapChoices) -> Void)?

    /// - Parameters:
    ///   - choices: What the menu ticks.
    ///   - onChange: Told the choices as they are after a line was chosen.
    ///     Left out, the button only changes what its menu shows.
    public init(choices: SnapChoices = SnapChoices(), onChange: (@MainActor (SnapChoices) -> Void)? = nil) {
        _keptChoices = State(initialValue: choices)
        givenChoices = choices
        self.onChange = onChange
    }

    public var body: some View {
        Menu {
            SnapToMenu(onChange == nil ? keptChoices : givenChoices) { changed in
                if let onChange {
                    onChange(changed)
                } else {
                    keptChoices = changed
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(DesignTokens.Fonts.symbolSmall)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: DesignTokens.Sizes.popoverArrowWidth, height: DesignTokens.Sizes.transportButton)
                .contentShape(DesignTokens.Shapes.control)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Snap To")
        .accessibilityLabel("Snap To")
    }
}

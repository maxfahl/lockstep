import SwiftUI

/// A menu's contents laid out as a plain list in the window: titles,
/// shortcuts on the right, dividers, ticks on the left, greyed-out commands,
/// and the contents of a submenu indented under its title.
///
/// A real right-click menu is a separate window that opens only on a real
/// right-click, so a picture of the design cannot show it open. This list
/// shows the same lines instead, on a glass panel of its own.
///
///     MenuListing(ClipMenu(values).entries)
public struct MenuListing: View {
    private let entries: [MenuEntry]

    public init(_ entries: [MenuEntry]) {
        self.entries = entries
    }

    public var body: some View {
        MenuListingRows(entries: entries)
            .padding(DesignTokens.Spacing.panelPadding)
            .frame(width: DesignTokens.Sizes.menuListingWidth, alignment: .leading)
            .glassPanel()
    }
}

/// The rows of one level of the list. A submenu's rows sit under its title,
/// moved in by one step.
private struct MenuListingRows: View {
    let entries: [MenuEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                switch entry {
                case .command(let item):
                    MenuListingRow(
                        title: item.title,
                        isChecked: item.isChecked ?? false,
                        isEnabled: item.isEnabled
                    ) {
                        if let shortcut = item.shortcut {
                            Text(shortcut.text)
                        }
                    }
                case .submenu(let title, let entries):
                    MenuListingRow(title: title, isChecked: false, isEnabled: true) {
                        Image(systemName: "chevron.right")
                            .font(DesignTokens.Fonts.symbolSmall)
                    }
                    // A menu inside a menu names its own type, so it is
                    // wrapped to keep the type from referring to itself.
                    AnyView(MenuListingRows(entries: entries))
                        .padding(.leading, DesignTokens.Spacing.xLarge)
                case .divider:
                    Rectangle()
                        .fill(DesignTokens.Colors.separator)
                        .frame(height: DesignTokens.Lines.separatorWidth)
                        .padding(.vertical, DesignTokens.Spacing.small)
                }
            }
        }
    }
}

/// One line of the list: a tick or nothing, the title, and on the right the
/// shortcut or a submenu's arrow.
private struct MenuListingRow<Trailing: View>: View {
    let title: String
    let isChecked: Bool
    let isEnabled: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Group {
                if isChecked {
                    Image(systemName: "checkmark")
                        .font(DesignTokens.Fonts.symbolSmall)
                }
            }
            .frame(width: DesignTokens.Sizes.menuTickColumnWidth, alignment: .leading)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: DesignTokens.Spacing.large)
            trailing()
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
        .font(DesignTokens.Fonts.label)
        .foregroundStyle(isEnabled ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textTertiary)
        .padding(.vertical, DesignTokens.Spacing.tight)
    }
}

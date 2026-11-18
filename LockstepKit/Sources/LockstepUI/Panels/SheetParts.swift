import SwiftUI

// The pieces the two sheets (Calibrate, Send to DaVinci) share, so they look
// like one family. A sheet is shown with the system's `sheet`, which gives it
// its surface and dims the window behind it. The buttons in a sheet are the
// system's own bordered buttons.

/// The title at the top of a sheet, with the name of what the sheet is about
/// at the right when there is one. A long name ends in an ellipsis.
struct SheetTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.large) {
            Text(title)
                .font(DesignTokens.Fonts.sheetTitle)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .fixedSize()
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(DesignTokens.Fonts.label)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

extension View {
    /// The padding, the fixed width and the dark look of a sheet's content.
    /// The height follows the content.
    func sheetFrame() -> some View {
        self
            .padding(DesignTokens.Spacing.xxLarge)
            .frame(width: DesignTokens.Sizes.sheetWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .lockstepLook()
    }

    /// A box inside a sheet that sets one thing apart: the measured delay,
    /// the exported file.
    func sheetBox() -> some View {
        self
            .padding(DesignTokens.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.Colors.controlFill, in: DesignTokens.Shapes.lane)
    }
}

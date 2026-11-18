import SwiftUI

// How a clip looks while its words are being worked out from its sound
// (`ClipBox.isWritingOutWords`). That takes a few seconds after a recording.
// Until it is done the clip has no words, and so no name of its own.

/// The words shown while a clip's text is worked out.
enum WritingOutWords {
    static let text = "Writing out words…"
}

/// What a clip's bar shows where the name will be, while the clip's words are
/// being worked out: three dots that pulse, and after them "Writing out
/// words…" when there is room. It is dimmer than a name, so it is not taken
/// for one. `ClipBarFit` decides whether the words fit.
struct WritingOutWordsMark: View {
    @Environment(\.timelinePalette) private var palette

    /// False shows the dots alone, on a narrow clip.
    let showsText: Bool

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: "ellipsis")
                .font(DesignTokens.Fonts.clipBadge)
                .symbolEffect(.pulse)
            if showsText {
                Text(WritingOutWords.text)
                    .font(DesignTokens.Fonts.clipName)
                    .italic()
                    .lineLimit(1)
            }
        }
        .foregroundStyle(palette.clipBarBadge)
        .fixedSize()
        .help("The words of this clip are being written out")
        .accessibilityHidden(true)
    }
}

/// The line in the inspector where the selected clip's words will stand,
/// while they are being worked out.
struct WritingOutWordsLabel: View {
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.controlGap) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
            Text(WritingOutWords.text)
                .font(DesignTokens.Fonts.label)
                .italic()
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Writing out the words of the clip")
    }
}

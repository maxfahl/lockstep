import SwiftUI

/// How far the finding of a song's beats has come. While
/// `TimelineContent.beatFinding` holds one, the song row shows it under the
/// song's name (`BeatFindingIndicator`), and the row has no beat lines yet.
public struct BeatFindingProgress: Sendable, Equatable {
    /// What is being done right now, in a few words, such as "Finding beats".
    public var phaseName: String
    /// From 0 to 1. Nil when it is not known how far the work has come; the
    /// ring then turns instead of filling.
    public var fraction: Double?

    public init(phaseName: String, fraction: Double? = nil) {
        self.phaseName = phaseName
        self.fraction = fraction
    }
}

/// The progress indicator shown while a song's beats are found: a small ring
/// that fills, and after it the name of what is being done. It is the same
/// ring the inspector shows while a track's clips are re-made.
///
///     BeatFindingIndicator(progress: BeatFindingProgress(phaseName: "Finding beats", fraction: 0.4))
public struct BeatFindingIndicator: View {
    private let progress: BeatFindingProgress

    public init(progress: BeatFindingProgress) {
        self.progress = progress
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Spacing.controlGap) {
            ring
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .tint(DesignTokens.Colors.accent)
            Text(progress.phaseName)
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.phaseName)
        .accessibilityValue(progress.fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
    }

    @ViewBuilder private var ring: some View {
        if let fraction = progress.fraction {
            ProgressView(value: min(max(fraction, 0), 1))
        } else {
            ProgressView()
        }
    }
}

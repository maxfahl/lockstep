import SwiftUI

/// What the window shows before a song is dropped: the words "Drop a song
/// here" in the middle, and nothing else. `MainLayout` shows it in place of
/// the timeline, the capsule and the inspector while its content has no song.
///
/// While a dropped song is being read, the words give way to a small ring
/// that fills, with "Opening song" after it: the same ring the song row shows
/// while beats are found.
public struct EmptyWindow: View {
    private let openingProgress: Double?

    /// - Parameter openingProgress: How far the reading of a dropped song has
    ///   come, from 0 to 1. Nil shows the words "Drop a song here".
    public init(openingProgress: Double? = nil) {
        self.openingProgress = openingProgress
    }

    public var body: some View {
        Group {
            if let openingProgress {
                BeatFindingIndicator(
                    progress: BeatFindingProgress(phaseName: "Opening song", fraction: openingProgress)
                )
            } else {
                Text("Drop a song here")
                    .font(DesignTokens.Fonts.emptyWindowTitle)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

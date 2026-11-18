import SwiftUI

// The controls of the takes list in the panel on the right (`TakesList`). Both
// are borderless, because the panel they stand in is glass.

/// The Play button of one take: it plays that take with the song, the way it
/// would sound if it were the chosen one. While its take plays it shows a
/// stop symbol on a light backing, and pressing it stops the song. Pressing
/// the button calls `action`, and does nothing without one.
public struct PlayTakeButton: View {
    private let takeName: String
    private let isPlaying: Bool
    private let action: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - takeName: The take's name, such as "Take 2", for the help tag.
    ///   - isPlaying: This take is the one that plays right now.
    ///   - action: Called when the button is pressed.
    public init(takeName: String, isPlaying: Bool = false, action: (@MainActor () -> Void)? = nil) {
        self.takeName = takeName
        self.isPlaying = isPlaying
        self.action = action
    }

    public var body: some View {
        SymbolButton(
            symbol: isPlaying ? "stop.fill" : "play.fill",
            name: isPlaying ? "Stop" : "Play \(takeName) with the song",
            font: DesignTokens.Fonts.symbolSmall,
            showsOnFill: isPlaying,
            action: { action?() }
        )
    }
}

/// The "Delete Other Takes" button: it removes every take of the line except
/// the active one. Pressing the button calls `action`, and does nothing
/// without one.
public struct DeleteOtherTakesButton: View {
    private let isAboutToDelete: Bool
    private let action: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - isAboutToDelete: Shows the button the way it looks with the
    ///     pointer on it, lit. The list then also fades the rows of the
    ///     takes that would go.
    ///   - action: Called when the button is pressed.
    public init(isAboutToDelete: Bool = false, action: (@MainActor () -> Void)? = nil) {
        self.isAboutToDelete = isAboutToDelete
        self.action = action
    }

    public var body: some View {
        Button(action: { action?() }) {
            Text("Delete Other Takes")
                .font(DesignTokens.Fonts.label)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.Spacing.medium)
                .frame(height: DesignTokens.Sizes.smallButton)
                .background(
                    isAboutToDelete ? DesignTokens.Colors.controlFillOn : DesignTokens.Colors.controlFill,
                    in: DesignTokens.Shapes.control
                )
                .contentShape(DesignTokens.Shapes.control)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Delete every take except the active one")
        .accessibilityLabel("Delete Other Takes")
    }
}

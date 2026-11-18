import SwiftUI

/// The row under the last track. It holds only the small "+" button,
/// "New Track", at the left of the header column, where the new track's
/// header will appear. It has no background and no beat lines, so the button
/// stands straight on the window.
///
/// `TrackLane.lanes(for:)` adds it. The button sits in the header column, so
/// it is not shown in a timeline without headers.
public struct NewTrackLane: TimelineLane {
    public let id = "Lockstep.Timeline.newTrack"
    private let onPress: (@MainActor () -> Void)?

    /// - Parameter onPress: Told when the button is pressed. Left out, the
    ///   button does nothing.
    public init(onPress: (@MainActor () -> Void)? = nil) {
        self.onPress = onPress
    }

    public var height: CGFloat { DesignTokens.Sizes.newTrackRowHeight }

    public var hasRowSurface: Bool { false }

    public func header() -> some View {
        NewTrackButton(onPress: onPress)
    }

    public func content(in viewport: TimelineViewport) -> some View {
        EmptyView()
    }
}

/// The small "+" button that adds a track. It stands alone on the window, so
/// it is a glass button of its own. Pressing it tells `onPress`, and does
/// nothing without one.
struct NewTrackButton: View {
    var onPress: (@MainActor () -> Void)? = nil

    var body: some View {
        Button(action: { onPress?() }) {
            Image(systemName: "plus")
                .font(DesignTokens.Fonts.symbolSmall)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .help("New Track")
        .accessibilityLabel("New Track")
    }
}

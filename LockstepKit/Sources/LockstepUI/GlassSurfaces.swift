import SwiftUI

// The surfaces of the app: what a bar, a panel, a row or a clip bar is made
// of. All glass is the system's own Liquid Glass. Nothing here imitates glass
// with blur or gradients.
//
// How to use them:
//
// - Chrome (a bar, a strip, a panel, the floating capsule) is always glass:
//   `glassBar()`, `glassPanel()`, `glassCapsule()`.
// - A timeline row and its header are glass too: `laneSurface()`,
//   `laneHeaderSurface()`. Only in a timeline that lies on a glass panel
//   (marked with `timelineOnGlass()`) are they plain and dark. A view calls
//   them the same way in both places.
// - A clip bar is a plain fill, `clipBarSurface(isSelected:)`, because the row
//   under it is glass.
// - A surface draws only the material. Padding and size come from
//   `DesignTokens.Spacing` and `DesignTokens.Sizes`.
// - Glass never lies on glass. A button inside a glass bar or panel uses a
//   borderless style. Only a button that stands alone on a plain background
//   uses the system's `.glass` or `.glassProminent` button style.
// - Several glass shapes that are close together go inside one `GlassGroup`.

extension DesignTokens {

    /// The kinds of glass, and the plain fills that replace glass where it
    /// would lie on glass. Used only by the surfaces in this file; they are
    /// here so the look of every surface can be tuned in one place.
    public enum Surfaces {
        /// Bars, strips, panels and the floating capsule.
        public static var chrome: Glass { .regular }
        /// A timeline row and its header.
        public static var lane: Glass { .regular }
        /// A clip bar. Plain, because the row under it is already glass.
        public static let clipBarPlainFill = Color(hex: 0x3F4390)
        /// The bar of a selected clip. Still dark enough for light text.
        public static let clipBarPlainFillSelected = Color(hex: 0x5A5FC8)
        /// Laid over a clip bar while the pointer is over it, to show that
        /// the bar is the handle the clip is dragged by. It lightens the bar
        /// whether the clip is selected or not.
        public static let clipBarHighlight = Color.white.opacity(0.14)
        /// Behind the take count "3/5" in a clip bar. The backing tells it
        /// is a button; the triplet "3" has only a ring.
        public static let clipBarButtonFill = Color.white.opacity(0.14)
        /// Behind the take count while the pointer is over it.
        public static let clipBarButtonFillHovered = Color.white.opacity(0.32)
        /// The inside of the field in a clip bar that the name is typed in.
        public static let clipNameFieldFill = Color.black.opacity(0.50)
        /// Behind the name in that field when all of it is selected, as it
        /// is when renaming starts.
        public static let clipNameFieldSelection = DesignTokens.Colors.accent.opacity(0.55)
        /// How near two glass shapes in a `GlassGroup` may come before they
        /// melt into one. Zero: rows always keep their own outline.
        public static let groupSpacing: CGFloat = 0
    }
}

extension View {

    // MARK: The whole window

    /// Gives a window's content the Lockstep look: always dark, whatever the
    /// Mac is set to, with the accent colour on the system's controls. Put it
    /// on the outermost view of every window, panel and popover.
    public func lockstepLook() -> some View {
        self
            .tint(DesignTokens.Colors.accent)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
    }

    // MARK: Chrome, always glass

    /// A glass bar or strip: the bar across the top, the strip along the bottom.
    public func glassBar() -> some View {
        darkGlass(DesignTokens.Surfaces.chrome, in: DesignTokens.Shapes.bar)
    }

    /// A glass panel: the inspector, the content of a popover.
    public func glassPanel() -> some View {
        darkGlass(DesignTokens.Surfaces.chrome, in: DesignTokens.Shapes.panel)
    }

    /// A glass capsule: the transport that floats over the timeline.
    public func glassCapsule() -> some View {
        darkGlass(DesignTokens.Surfaces.chrome, in: Capsule(style: .continuous))
    }

    // MARK: Timeline surfaces

    /// The background of a timeline row's body (the song, a track, a take).
    /// Glass, or plain and dark in a timeline that lies on a glass panel. The
    /// row's content is cut to the rounded outline.
    public func laneSurface() -> some View {
        modifier(LaneSurface(plainFill: DesignTokens.Colors.laneBackground))
    }

    /// The background of the header to the left of a timeline row. Glass, or
    /// plain and a little lighter than the row in a timeline on a glass panel.
    public func laneHeaderSurface() -> some View {
        modifier(LaneSurface(plainFill: DesignTokens.Colors.laneHeaderBackground))
    }

    /// The bar on top of a clip: a plain fill, so glass does not lie on the
    /// glass row under it. `isHighlighted` lightens it, for the pointer
    /// being over the bar.
    public func clipBarSurface(isSelected: Bool = false, isHighlighted: Bool = false) -> some View {
        self
            .background(
                isHighlighted ? DesignTokens.Surfaces.clipBarHighlight : Color.clear,
                in: DesignTokens.Shapes.clipBar
            )
            .background(
                isSelected
                    ? DesignTokens.Surfaces.clipBarPlainFillSelected
                    : DesignTokens.Surfaces.clipBarPlainFill,
                in: DesignTokens.Shapes.clipBar
            )
    }

    /// Glass that stays dark even where a window forgot `lockstepLook()`.
    fileprivate func darkGlass(_ glass: Glass, in shape: some Shape) -> some View {
        self
            .glassEffect(glass, in: shape)
            .environment(\.colorScheme, .dark)
    }
}

/// A container for glass shapes that are close together, such as a column of
/// glass rows. The system draws the glass inside one
/// group together, which costs less than drawing each piece alone.
public struct GlassGroup<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        GlassEffectContainer(spacing: DesignTokens.Surfaces.groupSpacing) {
            content
        }
    }
}

private struct LaneSurface: ViewModifier {
    @Environment(\.timelineLiesOnGlass) private var liesOnGlass
    let plainFill: Color

    func body(content: Content) -> some View {
        let shape = DesignTokens.Shapes.lane
        if liesOnGlass {
            content
                .background(plainFill)
                .clipShape(shape)
        } else {
            content
                .clipShape(shape)
                .darkGlass(DesignTokens.Surfaces.lane, in: shape)
        }
    }
}

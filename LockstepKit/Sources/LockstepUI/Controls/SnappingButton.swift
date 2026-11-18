import SwiftUI

/// The button that turns snapping on and off, for the bar at the bottom of
/// the window: two arrows meeting at a line. It is lit in the accent colour
/// while snapping is on, like the click and Loop. Its help tag says that
/// holding Command during a drag turns snapping the other way; the button
/// itself keeps showing the setting while Command is held.
///
/// Without `onPress` it keeps what it shows itself: pressing it only changes
/// how it looks, which is how the design lab shows it. With `onPress` it
/// shows `isOn` as it is given and tells its owner when it is pressed. The
/// owner then changes the setting and hands in the new value.
///
/// `SnappingSwitch` is the same setting as a labelled switch, for a place
/// with room for words.
public struct SnappingButton: View {
    @State private var keptIsOn: Bool
    private let givenIsOn: Bool
    private let onPress: (() -> Void)?

    /// - Parameters:
    ///   - isOn: Whether snapping is on.
    ///   - onPress: Told when the button is pressed. Left out, the button
    ///     only changes how it looks.
    public init(isOn: Bool, onPress: (() -> Void)? = nil) {
        _keptIsOn = State(initialValue: isOn)
        givenIsOn = isOn
        self.onPress = onPress
    }

    private var isOn: Bool {
        onPress == nil ? keptIsOn : givenIsOn
    }

    public var body: some View {
        SymbolButton(
            symbol: "arrow.right.and.line.vertical.and.arrow.left",
            name: "Snapping",
            font: DesignTokens.Fonts.symbol,
            width: DesignTokens.Sizes.transportButton,
            height: DesignTokens.Sizes.transportButton,
            color: isOn ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary,
            showsOnFill: isOn,
            help: "Snapping. Hold Command while dragging to turn it the other way."
        ) {
            if let onPress {
                onPress()
            } else {
                keptIsOn.toggle()
            }
        }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

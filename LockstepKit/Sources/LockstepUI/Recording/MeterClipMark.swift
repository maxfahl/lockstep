import SwiftUI

/// The piece at the right end of the microphone level meter that is lit while
/// the microphone is too loud. `MicLevelMeter` lays it over the end of its bar.
struct MeterClipMark: View {
    var body: some View {
        Capsule()
            .fill(DesignTokens.Colors.meterClipMark)
            .frame(width: DesignTokens.Sizes.meterClipMarkWidth, height: DesignTokens.Sizes.meterHeight)
            .help("The microphone is too loud")
    }
}

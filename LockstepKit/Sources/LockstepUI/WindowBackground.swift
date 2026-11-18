import SwiftUI

/// What a Lockstep window shows behind everything else: the dark window
/// colour, edge to edge. It also makes its window dark, whatever the Mac is
/// set to.
public struct WindowBackground: View {
    public init() {}

    public var body: some View {
        DesignTokens.Colors.windowBackground
            .ignoresSafeArea()
            .lockstepLook()
    }
}

import SwiftUI

/// The right-click menu of a beat line. Choosing its command calls
/// `onThisIsBeatOne`, and does nothing when that is left out.
///
///     BeatLineMenuTarget().beatMenu()
public struct BeatMenu: View {
    private let onThisIsBeatOne: (@MainActor () -> Void)?

    /// - Parameter onThisIsBeatOne: Called when "This Is Beat 1" is chosen.
    public init(onThisIsBeatOne: (@MainActor () -> Void)? = nil) {
        self.onThisIsBeatOne = onThisIsBeatOne
    }

    /// The lines of the menu, for `MenuListing`.
    public var entries: [MenuEntry] {
        [.command("This Is Beat 1", action: onThisIsBeatOne)]
    }

    public var body: some View {
        MenuEntries(entries)
    }
}

extension View {
    /// Opens the beat line's menu on a right-click. `onThisIsBeatOne` is
    /// called when its command is chosen.
    public func beatMenu(onThisIsBeatOne: (@MainActor () -> Void)? = nil) -> some View {
        contextMenu { BeatMenu(onThisIsBeatOne: onThisIsBeatOne) }
    }
}

/// An invisible strip around a beat line, a few points wide, that a
/// right-click can hit. A beat line itself is one point wide. Centre it on the
/// line and give it the row's height.
public struct BeatLineMenuTarget: View {
    public init() {}

    public var body: some View {
        Color.clear
            .frame(width: DesignTokens.Sizes.beatLineMenuTargetWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

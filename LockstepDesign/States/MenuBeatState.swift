import LockstepUI
import SwiftUI

extension LabState {
    /// The right-click menu of a beat line.
    static let menuBeat = LabState("Menu beat") {
        MenuStateSheet(
            hint: "Right-click a beat line in the song row for the real menu. This is what it holds.",
            entries: BeatMenu().entries
        )
    }
}

import LockstepCore
import LockstepUI
import SwiftUI

extension LabState {
    /// The menu of what snapping catches on, as it is at the start: all four
    /// kinds on, and the grid in beats.
    static let menuSnapTo = LabState("Menu snap to") {
        MenuStateSheet(
            hint: "Press the small arrow beside the snapping button, in the bar of Main, for the real menu. This is what it holds.",
            entries: SnapToMenu().entries
        )
    }

    /// The same menu with the grid and the playhead switched off and the
    /// grid's unit on bars, so every kind of line is seen ticked and not.
    static let menuSnapToSomeOff = LabState("Menu snap to, some off") {
        MenuStateSheet(
            hint: "The same menu with Grid and Playhead switched off, and the grid in bars.",
            entries: SnapToMenu(SnapChoices(grid: false, playhead: false, gridUnit: .bars)).entries
        )
    }
}

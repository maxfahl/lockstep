import LockstepUI
import SwiftUI

extension LabState {
    /// The right-click menu of the song row: Create Click Track and the three commands about the beats.
    static let menuSong = LabState("Menu song") {
        MenuStateSheet(
            hint: "Right-click the song row, between the beat lines, for the real menu. This is what it holds.",
            entries: SongMenu(SongMenu.Values()).entries
        )
    }
}

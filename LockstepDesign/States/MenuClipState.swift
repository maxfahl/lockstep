import LockstepUI
import SwiftUI

extension LabState {
    /// The right-click menu of the selected clip, which has five takes.
    static let menuClip = LabState("Menu clip") {
        let rows = SampleContent.make().trackRows
        let clip = rows.flatMap(\.clips).first(where: \.isSelected)
        var values = clip.map(MenuStateSheet.clipValues) ?? ClipMenu.Values()
        // The Aim at submenu lists the tracks the clip is not on, as it does in the app.
        values.aimTracks = rows
            .filter { row in !row.clips.contains { $0.id == clip?.id } }
            .map { AimTrack(id: $0.id, name: $0.name) }
        return MenuStateSheet(
            hint: "Right-click the clip for the real menu. This is what it holds.",
            entries: ClipMenu(values).entries
        )
    }
}

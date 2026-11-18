import LockstepUI
import SwiftUI

extension LabState {
    /// The song is selected and no clip. The song's header has the mark of a
    /// selected track, and the inspector shows the song: its name and its
    /// volume, here turned down to -6 dB. The selected track keeps its mark,
    /// because the next take still goes to it.
    static let songSelected = LabState("The song selected") {
        var content = SampleContent.makeMainLayout()
        for trackIndex in content.timeline.trackRows.indices {
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices {
                content.timeline.trackRows[trackIndex].clips[clipIndex].isSelected = false
            }
        }
        content.timeline.takeRows = []
        content.selectedClipText = ""
        content.selectedClipResolveStart = ""
        content.timeline.songIsSelected = true
        content.songVolumeDB = -6
        return LabMainLayout(content: content, showsInspector: true)
    }
}

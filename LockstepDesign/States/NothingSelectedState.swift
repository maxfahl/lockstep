import LockstepUI
import SwiftUI

extension LabState {
    /// No track and no clip is selected. The inspector says so in its top
    /// part and keeps the delay and Send to DaVinci below.
    static let nothingSelected = LabState("Nothing selected") {
        var content = SampleContent.makeMainLayout()
        for trackIndex in content.timeline.trackRows.indices {
            content.timeline.trackRows[trackIndex].isSelected = false
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices {
                content.timeline.trackRows[trackIndex].clips[clipIndex].isSelected = false
            }
        }
        content.timeline.takeRows = []
        content.selectedClipText = ""
        content.selectedClipResolveStart = ""
        return LabMainLayout(content: content, showsInspector: true)
    }
}

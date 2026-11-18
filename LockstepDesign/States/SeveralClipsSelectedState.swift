import LockstepUI
import SwiftUI

extension LabState {
    /// Three clips are selected, on two tracks, with different volumes (0, +4
    /// and 0 dB). The inspector shows how many and one volume control that
    /// reads "Mixed". Moving it brings the number back. One of the three is
    /// also corrected differently (Lines where the others have All, the
    /// sub-beats on Triplets, Strength at 30 %, Stretch on), so under
    /// "Correction" neither row of buttons has anything chosen, and Strength
    /// and Stretch read "Mixed".
    static let severalClipsSelected = LabState("Several clips selected") {
        var content = SampleContent.makeMainLayout()
        let alsoSelected: Set<String> = ["Writing lines until the morning", "Hook v2"]
        for trackIndex in content.timeline.trackRows.indices {
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices
            where alsoSelected.contains(content.timeline.trackRows[trackIndex].clips[clipIndex].displayName) {
                content.timeline.trackRows[trackIndex].clips[clipIndex].isSelected = true
                if content.timeline.trackRows[trackIndex].clips[clipIndex].displayName == "Hook v2" {
                    content.timeline.trackRows[trackIndex].clips[clipIndex].correction = .lines
                    content.timeline.trackRows[trackIndex].clips[clipIndex].strength = 0.3
                    content.timeline.trackRows[trackIndex].clips[clipIndex].stretches = true
                    content.timeline.trackRows[trackIndex].clips[clipIndex].menuFeel = .triplets
                }
            }
        }
        // Takes, words and a Resolve start time belong to one clip only.
        content.timeline.takeRows = []
        content.selectedClipText = ""
        content.selectedClipResolveStart = ""
        return LabMainLayout(content: content, showsInspector: true)
    }
}

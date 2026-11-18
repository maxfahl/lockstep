import LockstepUI
import SwiftUI

extension LabState {
    /// The pointer is over a beat line in the song row: that line is bright
    /// and three points wide. The arrows beside it stand in for the pointer,
    /// which a picture of the window does not show. Move the real pointer
    /// over another beat line in the song row to see the real thing.
    static let beatHover = LabState("Beat hover") {
        var content = MainLayoutContent.sampleWithoutSelectedClip()
        let beat = content.timeline.beatLines.first { !$0.isBarStart && $0.time >= 21 }
        content.timeline.shownHoveredBeat = beat?.time
        return SmallStateWindow(content: content, zoom: .around(20, pointsPerSecond: 60))
    }

    /// The words of two clips are being worked out. The wide, selected clip
    /// has three dots and "Writing out words…" in its bar where its name
    /// will be. The narrower clip on the track above has the dots alone. The
    /// panel on the right says the same where the clip's words will stand.
    static let writingOutWords = LabState("Writing out words") {
        var content = SampleContent.makeMainLayout()
        // The selected clip, and a shorter clip on the first track.
        let names = ["Told myself I'd make it through", "Streets remember every word I said"]
        for trackIndex in content.timeline.trackRows.indices {
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices
            where names.contains(content.timeline.trackRows[trackIndex].clips[clipIndex].displayName) {
                content.timeline.trackRows[trackIndex].clips[clipIndex].displayName = ""
                content.timeline.trackRows[trackIndex].clips[clipIndex].isWritingOutWords = true
            }
        }
        content.selectedClipText = ""
        return SmallStateWindow(
            content: content,
            zoom: SmallStateWindow.Zoom(pointsPerSecond: 60, startSeconds: 12),
            showsInspector: true
        )
    }
}

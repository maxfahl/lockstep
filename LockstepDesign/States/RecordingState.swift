import LockstepUI
import SwiftUI

extension LabState {
    /// Takes are recorded at 85 % of the song's speed: the bar has the mark
    /// "85 %" right after the Record button. Nothing else differs from Main.
    static let recordSlower = LabState("Record slower") {
        var content = MainLayoutContent.sampleWithoutSelectedClip()
        content.recordSpeedPercent = 85
        return LabMainLayout(content: content)
    }

    /// The run-up: Record was pressed and the song plays the bar before the
    /// place where recording will start. Record is red and filled, and the
    /// selected track has a red line at the starting place, a little to the
    /// right of the playhead.
    static let runningUp = LabState("Running up") {
        var content = MainLayoutContent.sampleWithoutSelectedClip()
        content.startRecording(onTrack: 2, at: 26.5, recordedSeconds: nil)
        content.micLevel = 0.15
        return SmallStateWindow(
            content: content,
            zoom: .around(content.timeline.playheadTime, pointsPerSecond: 40)
        )
    }

    /// Recording: Record red and filled, the level meter high with its
    /// clipping mark lit, and a red clip growing
    /// on the selected track from the starting place up to the playhead.
    static let recording = LabState("Recording") {
        var content = MainLayoutContent.sampleWithoutSelectedClip()
        content.startRecording(onTrack: 2, at: 26.5, recordedSeconds: 3.4)
        content.micLevel = 0.94
        content.micIsClipping = true
        return SmallStateWindow(
            content: content,
            zoom: .around(content.timeline.playheadTime - 4, pointsPerSecond: 40)
        )
    }

    /// The track list in a recording: "Lead" is being recorded to (red
    /// mark and dot), "Lead 2" is muted, "Double" is the selected track
    /// (accent mark) and "Ad-libs" is being renamed (a field with the name
    /// selected).
    static let trackList = LabState("Track list") {
        var content = MainLayoutContent.sampleWithoutSelectedClip()
        content.startRecording(onTrack: 0, at: 16, recordedSeconds: 2.6)
        content.micLevel = 0.6
        content.timeline.trackRows[3].isBeingRenamed = true
        return SmallStateWindow(
            content: content,
            zoom: .around(content.timeline.playheadTime - 4, pointsPerSecond: 40)
        )
    }
}

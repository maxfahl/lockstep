import LockstepUI
import SwiftUI

extension LabState {
    /// A track is selected and no clip. The inspector shows the track: its
    /// name, its volume (here 0.0 dB, where a new track starts), the switch
    /// Mute and the button Normalize Track.
    static let trackSelected = LabState("A track selected") {
        trackSelectedLayout(muted: false)
    }

    /// The same with the selected track muted: the switch is on, as the mute
    /// button in the track's header is lit.
    static let trackSelectedMuted = LabState("A muted track selected") {
        trackSelectedLayout(muted: true)
    }

    /// The same with the selected track turned up to +4.5 dB: the knob of
    /// its volume stands to the right of 0, which the song's volume cannot.
    static let trackSelectedTurnedUp = LabState("A track turned up") {
        trackSelectedLayout(muted: false, volumeDB: 4.5)
    }

    @MainActor private static func trackSelectedLayout(muted: Bool, volumeDB: Double = 0) -> LabMainLayout {
        var content = SampleContent.makeMainLayout()
        for trackIndex in content.timeline.trackRows.indices {
            if content.timeline.trackRows[trackIndex].isSelected {
                content.timeline.trackRows[trackIndex].muted = muted || content.timeline.trackRows[trackIndex].muted
                content.timeline.trackRows[trackIndex].volumeDB = volumeDB
            }
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

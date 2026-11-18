import LockstepUI
import SwiftUI

extension LabState {
    /// The right-click menu of the header of the track "Double", one of four.
    /// The track has the Voice "Darker", switched on, and Max has saved two
    /// presets of his own: under Voice, "Voice On or Off" and "Darker" are
    /// ticked.
    static let menuTrack = LabState("Menu track") {
        let tracks = SampleContent.make().trackRows
        let track = tracks.first(where: \.isSelected) ?? tracks[0]
        var values = TrackMenu.Values(
            isMuted: track.muted,
            otherTrackNames: tracks.filter { $0.id != track.id }.map(\.name),
            canDelete: tracks.count > 1
        )
        values.voice = LabState.darkerVoice
        values.ownVoicePresets = LabState.ownVoicePresets.map(\.name)
        return MenuStateSheet(
            hint: "Right-click the track's header for the real menu. This is what it holds.",
            entries: TrackMenu(values).entries
        )
    }
}

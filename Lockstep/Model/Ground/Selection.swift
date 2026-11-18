import Foundation
import LockstepCore
import LockstepUI
import Observation

/// What is selected in the open project: the clips, the track, the song and the marked stretch.
///
/// It is ground: `AppModel` makes one, and every part that selects something, or acts on
/// what is selected, is handed it.
@MainActor
@Observable
final class Selection {
    /// The open project, to know which tracks it has (`recordingTrackID`).
    @ObservationIgnored private let store: ProjectStore

    /// The clips that are selected. Delete and Mute Clip act on them, and the menus
    /// read it to know whether they can.
    var clipIDs: Set<UUID> = [] {
        didSet {
            if !clipIDs.isEmpty { deselectSong() }
        }
    }
    /// The track recordings go to. Nil means the project's first track. The menu bar
    /// reads it, through `mergeTargets`, to list the other tracks under Merge Into.
    var trackID: UUID? {
        didSet { deselectSong() }
    }
    /// Whether the song is selected (a click on the header of its row). The panel on the right then
    /// shows the song. It takes the panel the way a selected clip does: `trackID` stays, for the
    /// Track menu and for where a take is recorded. Selecting a clip, or selecting a track, by any
    /// way at all, lets go of the song, which is why that is done here and not by each part that
    /// selects something. The song's volume part selects it (`SongVolumeModel.selectSong`).
    var songIsSelected = false
    /// The stretch of one track that is marked, or nil. Delete acts on it, and the menus
    /// read it. There is never a marked stretch and a selected clip at the same time. It
    /// is changed by clip editing (`ClipEditingModel`), and `showClips` draws it.
    var markedStretch: MarkedStretch?

    init(store: ProjectStore) {
        self.store = store
    }

    /// Lets go of the song. Written only when it changes anything, so the window is not worked
    /// out again for every clip and track that is selected while the song is not.
    private func deselectSong() {
        if songIsSelected {
            songIsSelected = false
        }
    }

    /// The track a recording goes to: the selected one, or the first if that is gone.
    var recordingTrackID: UUID? {
        if let trackID, store.project.track(trackID) != nil {
            return trackID
        }
        return store.project.tracks.first?.id
    }
}

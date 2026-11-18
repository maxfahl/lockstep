import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

/// A track's own volume: a part of the app's model.
///
/// It holds turning a track up or down. With a track selected and no clip, the panel on the right
/// shows the track's volume, from -24 to +12 dB (`setTrackVolume`). While the slider is dragged the
/// track's clips are only heard at the new volume, and the project is left alone. Letting go is one
/// edit, "Change Track Volume".
///
/// The volume is `Track.gainDb` of the project's track. The player hears it through the clips: the
/// plan of what is played adds it to every clip of the track (`Project.clipPlaybackPlan`), so a new
/// volume is heard by handing the player the clips again, as a clip's own volume is, also while
/// the song plays. It changes only what is heard while playing and recording: the recordings and
/// what is sent to DaVinci never have it in them. After Undo and Redo, and when a project opens,
/// the clips are handed to the player anyway, and the track's volume with them.
@MainActor
final class TrackVolumeModel {
    // The ground it is handed.
    private let takeStatus: TakeStatus
    private let store: ProjectStore

    // The parts it is handed, and calls directly.
    private let tracks: TracksModel

    /// What is kept while the volume control of a track is dragged.
    private let volumeWork = VolumeWork()
    /// True once the volume asked for with `-trackVolume` was asked to be set.
    private var launchVolumeTaken = false

    // What it asks of code that holds it, or of the model's routing. `wireTrackVolume` sets them.
    /// Lets the player and the window follow the clips of a project (`followClips(of:)`, the clips'
    /// part).
    var followClips: (Project) -> Void = { _ in }

    init(
        takeStatus: TakeStatus,
        store: ProjectStore,
        tracks: TracksModel
    ) {
        self.takeStatus = takeStatus
        self.store = store
        self.tracks = tracks
    }
}

extension TrackVolumeModel {
    // MARK: The volume

    /// The volume control of a track was moved. While it is dragged the track's clips are only heard
    /// at the new volume, and nothing in the project changes. Letting go makes it the track's
    /// volume, as one step that can be undone.
    ///
    /// - Parameters:
    ///   - trackID: the track the control belongs to.
    ///   - volumeDb: from -24 to +12. It is kept to tenths of a dB, which is what the control shows.
    func setTrackVolume(_ trackID: UUID, _ volumeDb: Double, isFinal: Bool) {
        let work = volumeWork
        work.dropWaiting()
        // A new volume is an edit, and nothing is edited while a take is going.
        guard takeStatus.phase == nil, store.project.track(trackID) != nil else { return }
        var changed = store.project
        changed.setTrack(trackID, gainDb: (volumeDb * 10).rounded() / 10)
        guard !isFinal else {
            work.lastHeardAt = nil
            if changed != store.project {
                store.edit("Change Track Volume") { $0 = changed }
            }
            // Also when the slider was put back where it started and nothing was edited.
            followClips(store.project)
            return
        }
        work.hear { [weak self] in self?.followClips(changed) }
    }
}

extension TrackVolumeModel {
    // MARK: A project opens

    /// A song or a project is about to be shown in place of what was open, and the store has not
    /// opened it yet: a volume that was being dragged belonged to a track of the old one, and is
    /// not heard any more.
    func projectWillOpen() {
        volumeWork.dropWaiting()
        volumeWork.lastHeardAt = nil
    }
}

extension TrackVolumeModel {
    // MARK: For an agent's run

    /// Selects the first track and gives it the volume `-trackVolume` asked for, once the first
    /// project is open and the takes given with `-addTake` are in it, and says so on standard
    /// error. An agent that checks the app cannot click the track's header or drag the slider, so
    /// this goes through the same two functions they call.
    func setLaunchTrackVolume() {
        guard !launchVolumeTaken, let volumeDb = LaunchOptions.current.trackVolume else { return }
        launchVolumeTaken = true
        Task { [weak self] in
            // Nothing is edited while a take is being added, and a clip that is added is selected,
            // which would take the panel on the right from the track.
            await self?.takeStatus.ended()
            guard let self, let track = self.store.project.tracks.first else { return }
            self.tracks.selectTrack(track.id)
            self.setTrackVolume(track.id, volumeDb, isFinal: true)
            let now = self.store.project.track(track.id)
            Agent.tell(
                String(
                    format: "set the volume of the track \"%@\" to %.1f dB (asked for %.1f), undo step: %@",
                    now?.name ?? track.name,
                    now?.gainDb ?? 0,
                    volumeDb,
                    self.store.undoTitle ?? "none"
                )
            )
        }
    }
}

extension AppModel {
    /// Gives `trackVolume` its closures. `wire()` calls it once, when every part is made.
    func wireTrackVolume() {
        trackVolume.followClips = { [weak self] project in self?.clips.followClips(of: project) }
    }
}

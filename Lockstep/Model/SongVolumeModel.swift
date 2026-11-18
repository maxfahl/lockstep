import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

/// The song's own volume: a part of the app's model.
///
/// It holds selecting the song and turning it down. A click on the header of the song's row
/// selects the song (`selectSong`), and the panel on the right then shows its volume, from -24 to
/// 0 dB. While the slider is dragged the song is only heard at the new volume, and the project is
/// left alone. Letting go is one edit, "Change Song Volume".
///
/// The volume is `store.project.songGainDb`. It is set on the player and changes only what is
/// heard while playing and recording: the song file, the click file and what is sent to DaVinci
/// never have it in them. `followSongVolume` brings the window and the player in line with a
/// project, when one opens and after Undo and Redo.
@MainActor
final class SongVolumeModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let player: Player
    private let store: ProjectStore

    /// Where the volume slider stands while it is being dragged, in dB. The song is heard at this
    /// volume, and the project gets it when the slider is let go.
    private var heldVolumeDb: Double?
    /// True once the volume asked for with `-songVolume` was set, or could not be.
    private var launchVolumeTaken = false

    // What it asks of code that holds it, or of the model's routing. `wireSongVolume` sets them.
    /// Shows the clips of a project in the window, without telling the player (`showClips(of:)`,
    /// the clips' part): a clip that was selected is drawn as not selected.
    var showClips: (Project) -> Void = { _ in }

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        player: Player,
        store: ProjectStore
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.player = player
        self.store = store
    }
}

extension SongVolumeModel {
    // MARK: Selecting the song

    /// The header of the song's row was clicked: the song is selected, and the panel on the right
    /// shows it. No clip stays selected. The selected track stays, and is still where the next
    /// take goes. A click on a track's header or on a clip lets go of the song again (`Selection`).
    func selectSong() {
        guard loadedSounds.song != nil, !selection.songIsSelected else { return }
        selection.clipIDs = []
        selection.songIsSelected = true
        showClips(store.project)
    }

    // MARK: The volume

    /// The volume control of the selected song was moved. While it is dragged the song is only
    /// heard at the new volume, and nothing in the project changes. Letting go makes it the
    /// song's volume, as one step that can be undone.
    ///
    /// - Parameter volumeDb: from -24 to 0. It is kept to tenths of a dB, which is what the
    ///   control shows.
    func setSongVolume(_ volumeDb: Double, isFinal: Bool) {
        heldVolumeDb = nil
        // A new volume is an edit, and nothing is edited while a take is going. The control is
        // shown only while the song is selected, and tells where it stood as it goes away.
        guard takeStatus.phase == nil, selection.songIsSelected, loadedSounds.song != nil else {
            followSongVolume(of: store.project)
            return
        }
        let volumeDb = Project.songGain(clamped: (volumeDb * 10).rounded() / 10)
        if isFinal {
            if volumeDb != store.project.songGainDb {
                store.edit("Change Song Volume") { $0.songGainDb = volumeDb }
            }
        } else {
            heldVolumeDb = volumeDb
        }
        // Also when the slider was put back where it started and nothing was edited.
        followSongVolume(of: store.project)
    }

    /// Brings the window and the player in line with a project's song volume: the panel on the
    /// right shows it, and the song is heard at it at once, also while it plays.
    ///
    /// The project is handed in, and not read from the store, because this is also called in the
    /// middle of an undo, while the store's project is being changed.
    func followSongVolume(of project: Project) {
        if windowState.content.songVolumeDB != project.songGainDb {
            windowState.content.songVolumeDB = project.songGainDb
        }
        // A slider that is being dragged has the last word on the volume until it is let go.
        var heard = project
        if let heldVolumeDb {
            heard.songGainDb = heldVolumeDb
        }
        player.engine.setSongVolume(heard.songGain)
    }
}

extension SongVolumeModel {
    // MARK: A project opens

    /// A song or a project is about to be shown in place of what was open, and the store has not
    /// opened it yet: the song that was selected is not this one, and neither is a volume that
    /// was being dragged. The store then lets the volume of this project be heard
    /// (`rebuildDerived`).
    func projectWillOpen() {
        heldVolumeDb = nil
        selection.songIsSelected = false
    }
}

extension SongVolumeModel {
    // MARK: For an agent's run

    /// Selects the song and gives it the volume `-songVolume` asked for, once the first project is
    /// open, and says so on standard error. An agent that checks the app cannot click the song's
    /// header or drag the slider, so this goes through the same two functions they call.
    func setLaunchSongVolume() {
        guard !launchVolumeTaken, let volumeDb = LaunchOptions.current.songVolume else { return }
        launchVolumeTaken = true
        selectSong()
        setSongVolume(volumeDb, isFinal: true)
        Agent.tell(
            String(
                format: "set the song's volume to %.1f dB (asked for %.1f), the song is %@, undo step: %@",
                store.project.songGainDb,
                volumeDb,
                selection.songIsSelected ? "selected" : "not selected",
                store.undoTitle ?? "none"
            )
        )
    }
}

extension AppModel {
    /// Gives `songVolume` its closures. `wire()` calls it once, when every part is made.
    func wireSongVolume() {
        songVolume.showClips = { [weak self] project in self?.clips.showClips(of: project) }
    }
}

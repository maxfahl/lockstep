import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

/// Tracks: a part of the app's model.
///
/// It holds the tracks: selecting, adding, naming, muting, moving, duplicating, merging and
/// deleting them.
///
/// Exactly one track is selected, and it is where Record puts the next clip. A click on a
/// track's header or on one of its clips selects it, a new track is selected as it is added, and
/// an opened project starts with its first track selected. The track list in the window reports
/// what is done in it (`trackActions` on `AppModel`): the plus button, the mute button, a
/// double-click on a name, the end of typing a name, and a drag of a header. Each change is one
/// edit that can be undone, made with the functions of `ProjectTracks`. While a name is typed,
/// `renamedTrackID` says which track's header holds the text field.
///
/// Duplicate Track, Duplicate Track with Clips, Merge Into and Delete Track act on the selected
/// track, from the Track menu and from the right-click menu of a header, which selects the track
/// it was opened on first (`trackMenuCommand` on `AppModel`). Afterwards the copy, the track
/// merged into, or the neighbour of the deleted track is the selected one.
@MainActor
final class TracksModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let store: ProjectStore

    // The parts it is handed, and calls directly.
    private let words: WordsModel
    /// A track's Voice: an edit keeps a part as loud as it was heard, in the voice of its track.
    private let voice: VoiceModel

    /// The track whose name is being typed in its header, or nil.
    var renamedTrackID: UUID?

    // What it asks of code that holds it, or of the model's routing. `wireTracks` sets them.
    /// Lets the player and the window follow the clips of a project (`followClips(of:)`, the clips'
    /// part).
    var followClips: (Project) -> Void = { _ in }

    /// Shows the clips of a project in the window, without telling the player (`showClips(of:)`,
    /// the clips' part).
    var showClips: (Project) -> Void = { _ in }

    /// Whether Merge Into may act now (`canPerform(.mergeInto)`, the model's routing).
    var canMerge: () -> Bool = { false }

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore,
        words: WordsModel,
        voice: VoiceModel
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
        self.words = words
        self.voice = voice
    }
}

extension TracksModel {
    // MARK: Tracks

    /// A track's header was clicked: that track is selected, and the next recording goes
    /// to it. Also during a take, which stays on the track it was started on. No clip stays
    /// selected, and neither does the song, so the panel on the right shows the track.
    func selectTrack(_ trackID: UUID) {
        guard store.project.track(trackID) != nil else { return }
        guard selection.trackID != trackID || !selection.clipIDs.isEmpty || selection.songIsSelected else { return }
        selection.trackID = trackID
        selection.clipIDs = []
        showClips(store.project)
    }

    /// New Track: adds an empty track under the last one, as one step that can be undone,
    /// and selects it.
    func addTrack() {
        guard takeStatus.phase == nil, loadedSounds.song != nil else { return }
        var changed = store.project
        let trackID = changed.addTrack()
        store.edit("New Track") { $0 = changed }
        selection.trackID = trackID
        showClips(store.project)
    }

    /// Mute Track: mutes the selected track, or lets it be heard again.
    func muteSelectedTrack() {
        guard let trackID = selection.recordingTrackID else { return }
        toggleMute(ofTrack: trackID)
    }

    /// Mutes a track, or lets it be heard again when it is muted, as one step that can be
    /// undone. While the song plays, the change is heard without the song stopping.
    func toggleMute(ofTrack trackID: UUID) {
        guard takeStatus.phase == nil, let track = store.project.track(trackID) else { return }
        var changed = store.project
        guard changed.setTrackMuted(trackID, !track.muted) else { return }
        store.edit(track.muted ? "Unmute Track" : "Mute Track") { $0 = changed }
        followClips(store.project)
    }

    /// Rename Track: the name of the selected track can be typed.
    func renameSelectedTrack() {
        guard let trackID = selection.recordingTrackID else { return }
        startRenamingTrack(trackID)
    }

    /// Puts a text field in place of a track's name, with the name in it. The typing ends
    /// with `endRenamingTrack`, which the field calls.
    func startRenamingTrack(_ trackID: UUID) {
        // A new name is an edit, and nothing is edited while a take is going.
        guard takeStatus.phase == nil, renamedTrackID != trackID, store.project.track(trackID) != nil else { return }
        renamedTrackID = trackID
        showClips(store.project)
    }

    /// Takes the text field out of the header again. The field reports the name that was
    /// typed as it goes (`endRenamingTrack`), so nothing typed is lost.
    func stopRenamingTrack() {
        guard renamedTrackID != nil else { return }
        renamedTrackID = nil
        showClips(store.project)
    }

    /// The typing of a track's name is over. With a name (Return, or a click elsewhere) the
    /// track gets it, as one step that can be undone. An empty name, the name the track
    /// already has, and Escape (`name` is nil) leave the track as it was and make no step.
    func endRenamingTrack(_ trackID: UUID, as name: String?) {
        if let name, takeStatus.phase == nil {
            var changed = store.project
            if changed.renameTrack(trackID, to: name) {
                store.edit("Rename Track") { $0 = changed }
            }
        }
        if renamedTrackID == trackID {
            renamedTrackID = nil
        }
        showClips(store.project)
    }

    /// A track is being dragged up or down by its header. While it is dragged, the window
    /// shows its header lifted and a line where the track will land. Let go at another
    /// place, the track moves there, as one step that can be undone.
    func trackDragged(_ move: TrackMove) {
        let rows = windowState.content.timeline.trackRows
        guard takeStatus.phase == nil, let from = rows.firstIndex(where: { $0.id == move.trackID }),
            rows.indices.contains(move.toIndex)
        else {
            if windowState.content.timeline.dragging.movedTrack != nil {
                windowState.content.timeline.dragging.movedTrack = nil
            }
            return
        }
        guard !move.isFinished else {
            windowState.content.timeline.dragging.movedTrack = nil
            var changed = store.project
            guard changed.moveTrack(move.trackID, toIndex: move.toIndex) else { return }
            store.edit("Move Track") { $0 = changed }
            showClips(store.project)
            return
        }
        // The line lies on the far side of the track whose place is taken: above it for a
        // track on its way up, below it for one on its way down. A track that would stay
        // where it is has the line above itself.
        let landing: MovedTrack.Landing = move.toIndex > from
            ? .after(rows[move.toIndex].id)
            : .before(rows[move.toIndex].id)
        let moved = MovedTrack(track: rows[from], draggedBy: move.draggedBy, landing: landing)
        if windowState.content.timeline.dragging.movedTrack != moved {
            windowState.content.timeline.dragging.movedTrack = moved
        }
    }

    /// Duplicate Track and Duplicate Track with Clips: a copy of the selected track right
    /// below it, with the same settings, as one step that can be undone. The copy is the
    /// selected track afterwards. With clips, the copies play the same recordings as the
    /// originals, so both are heard until one of the tracks is muted.
    func duplicateSelectedTrack(withClips: Bool) {
        guard takeStatus.phase == nil, let trackID = selection.recordingTrackID else { return }
        var changed = store.project
        guard let copyID = changed.duplicateTrack(trackID, withClips: withClips) else { return }
        let command: AppCommand = withClips ? .duplicateTrackWithClips : .duplicateTrack
        store.edit(command.title) { $0 = changed }
        selection.trackID = copyID
        followClips(store.project)
    }

    /// The tracks the selected track can be merged into: all the others, top to bottom.
    var mergeTargets: [MergeTarget] {
        let selected = selection.recordingTrackID
        return store.project.tracks
            .filter { $0.id != selected }
            .map { MergeTarget(id: $0.id, name: $0.name) }
    }

    /// Merge Into: every clip of the selected track moves to the chosen track, and the
    /// selected track is removed, as one step that can be undone. The chosen track keeps
    /// its name and settings and is the selected track afterwards. A clip that comes to
    /// start where a clip of the chosen track starts becomes a take of it, and is the one
    /// heard. Whatever else a clip that comes covers of the chosen track's clips gives way.
    func mergeSelectedTrack(into targetID: UUID) {
        guard canMerge(), let sourceID = selection.recordingTrackID else { return }
        stopRenamingTrack()
        var changed = store.project
        guard changed.mergeTrack(sourceID, into: targetID, peaks: voice.peaks, voices: voice.heard) else { return }
        // The words of a clip that gave way are for more sound than it now plays.
        let cut = words.clearWordsOfCutClips(in: &changed)
        store.edit("Merge Track") { $0 = changed }
        selection.trackID = targetID
        followClips(store.project)
        words.writeOutWords(ofCutClips: cut)
    }

    /// Delete Track: removes the selected track and its clips, as one step that can be
    /// undone, without asking. The recordings stay in the project until it is closed, so
    /// Undo brings the track back with its sound. The track below takes the selection, or
    /// the one above when the bottom track was deleted. The only track is never deleted.
    func deleteSelectedTrack() {
        guard takeStatus.phase == nil, let trackID = selection.recordingTrackID else { return }
        var changed = store.project
        guard let nextID = changed.deleteTrack(trackID) else { return }
        store.edit(AppCommand.deleteTrack.title) { $0 = changed }
        selection.trackID = nextID
        followClips(store.project)
    }
}

extension TracksModel {
    // MARK: A project opens

    /// A song or a project is about to be shown in place of what was open, and the store has not
    /// opened it yet: a name that was being typed belonged to a track of the old project.
    func projectWillOpen() {
        renamedTrackID = nil
    }
}

extension AppModel {
    /// Gives `tracks` its closures. `wire()` calls it once, when every part is made.
    func wireTracks() {
        tracks.followClips = { [weak self] project in self?.clips.followClips(of: project) }
        tracks.showClips = { [weak self] project in self?.clips.showClips(of: project) }
        tracks.canMerge = { [weak self] in self?.canPerform(.mergeInto) ?? false }
    }
}

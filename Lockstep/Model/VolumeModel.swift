import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

/// The volume of clips: a part of the app's model.
///
/// It holds the volume of clips: Normalize, the volume slider, and whether a clip's volume is
/// held back.
@MainActor
final class VolumeModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let store: ProjectStore
    private let settings: AppSettings

    /// What is kept while the volume control of a clip is dragged.
    private let volumeWork = VolumeWork()

    /// The notes this part has put in the window's message banner (`say`), so it knows its own from
    /// another part's message.
    private var notes: Set<String> = []
    /// Takes the note that is showing away again, `noteSeconds` after it was put there.
    private var noteLeaves: Task<Void, Never>?
    /// How long a note stays in the banner, in seconds: long enough to read one sentence.
    private static let noteSeconds = 5.0

    // What it asks of code that holds it, or of the model's routing. `wireVolume` sets them.
    /// Lets the player and the window follow the clips of a project (`followClips(of:)`, the clips'
    /// part).
    var followClips: (Project) -> Void = { _ in }

    /// Shows the clips of a project in the window, without telling the player (`showClips(of:)`,
    /// the clips' part).
    var showClips: (Project) -> Void = { _ in }

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore,
        settings: AppSettings
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
        self.settings = settings
    }
}

// Evening out the volume of clips.
//
// Normalize (Clip menu, Command-L, and a clip's right-click menu) acts on the selected clips. Normalize Track
// (Track menu, Shift-Command-L, and a track's right-click menu) acts on every clip of the selected track.
// Both include the takes that wait behind a clip, and each is one edit that can be undone. The loudness they
// aim for is the setting `volume.targetLufs`.
//
// A new recording is normalised by itself as it becomes a clip, inside the same "Record Clip" edit, while the
// setting `volume.normalizeNewRecordings` is on (`normalizeNewClip`). So a clip Max records is evened out
// before he ever presses Normalize, and a press then has nothing to change: the window's message says so
// (`nothingChangedMessage`), because a command that does nothing and says nothing looks broken.
//
// A clip's own volume: the volume control in the panel on the right reports every move
// (`setSelectedClipVolume`). While it is dragged, the clips are shown and heard at the new volume and the
// project is left alone. Letting go is one edit, "Change Volume". The control's mark for a clip that the safe
// limit holds back comes from `selectedClipVolumeIsHeldBack`.
extension VolumeModel {
    // MARK: Normalize

    /// Whether Normalize has anything to act on: a clip is selected.
    var canNormalizeSelectedClips: Bool {
        loadedSounds.song != nil && !loadedSounds.isOpening && !selection.clipIDs.isEmpty
    }

    /// Whether Normalize Track has anything to act on: the selected track has a clip.
    var canNormalizeSelectedTrack: Bool {
        guard loadedSounds.song != nil, !loadedSounds.isOpening, let trackID = selection.trackID else { return false }
        return store.project.track(trackID)?.clips.isEmpty == false
    }

    /// Normalize: brings the selected clips to the target loudness, as one step that can be undone.
    func normalizeSelectedClips() {
        normalize(selection.clipIDs, as: AppCommand.normalize.title)
    }

    /// Normalize Track: brings every clip of the selected track to the target loudness, as one step that can
    /// be undone.
    func normalizeSelectedTrack() {
        guard let trackID = selection.trackID, let track = store.project.track(trackID) else { return }
        normalize(Set(track.clips.map(\.id)), as: AppCommand.normalizeTrack.title)
    }

    /// Measures these clips and every other take of their lines, away from the main thread, and then writes
    /// each one's normalising into the project as one edit. While the song plays, the new volumes are heard
    /// without the song stopping.
    private func normalize(_ ids: Set<UUID>, as actionName: String) {
        guard takeStatus.phase == nil else { return }
        let clips = store.project.clipsToNormalize(ids)
        guard !clips.isEmpty else { return }
        let target = settings[.targetLufs]
        let sounds = loadedSounds.sounds
        Task {
            var loudness = await Self.loudness(of: clips, in: sounds)
            // Nothing is edited during a take, and one may have started while the clips were measured.
            guard takeStatus.phase == nil else { return }
            // A clip that was cut or joined in the meantime plays something else than what was measured.
            for clip in clips where store.project.clip(clip.id)?.segments != clip.segments {
                loudness[clip.id] = nil
            }
            var changed = store.project
            guard changed.normalize(clips: Set(clips.map(\.id)), target: target, loudness: loudness) else {
                say(Self.nothingChangedMessage(for: store.project.clips(ids), measured: loudness, target: target))
                return
            }
            // A note about a press that changed nothing is no longer news.
            if windowState.content.message.map(notes.contains) == true {
                windowState.content.message = nil
            }
            store.edit(actionName) { $0 = changed }
            followClips(store.project)
        }
    }

    /// What the window says when Normalize had nothing to change, so that the press is seen to have been
    /// taken. One sentence, as the banner holds.
    ///
    /// - Parameters:
    ///   - chosen: the clips Normalize was asked for: the selected ones, or the ones of the track.
    ///   - measured: how loud each clip, and each other take of its line, was measured to be. A silent clip
    ///     has no loudness.
    ///   - target: the loudness Normalize aims for, in LUFS.
    static func nothingChangedMessage(for chosen: [Clip], measured: [UUID: Double], target: Double) -> String {
        let one = chosen.count == 1
        guard !measured.isEmpty else {
            return one ? "Nothing changed: the clip is silent." : "Nothing changed: these clips are silent."
        }
        // Max turned a clip up or down himself and Normalize keeps that, which is why it still stands out.
        guard chosen.allSatisfy({ $0.gainDb == 0 }) else {
            return one
                ? "Nothing changed: Normalize keeps the Volume you set for the clip."
                : "Nothing changed: Normalize keeps the Volume you set for a clip."
        }
        let lufs = target == target.rounded() ? String(format: "%.0f", target) : String(format: "%.1f", target)
        return one
            ? "Nothing changed: the clip is already evened out to \(lufs) LUFS."
            : "Nothing changed: these clips are already evened out to \(lufs) LUFS."
    }

    /// Shows a note in the window's message banner and takes it away again a few seconds later, unless
    /// something else is said there by then. Another message that is showing is left alone: it is about
    /// something that matters more than a press that changed nothing.
    private func say(_ note: String) {
        guard windowState.content.message == nil || windowState.content.message.map(notes.contains) == true
        else { return }
        notes.insert(note)
        windowState.content.message = note
        noteLeaves?.cancel()
        noteLeaves = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noteSeconds))
            guard !Task.isCancelled, let self, self.windowState.content.message == note else { return }
            self.windowState.content.message = nil
        }
    }

    /// How loud each clip sounds. A long clip takes a moment, so this runs away from the main thread.
    @concurrent
    private nonisolated static func loudness(of clips: [Clip], in sounds: [UUID: [Float]]) async -> [UUID: Double] {
        Project.loudness(of: clips) { sounds[$0] }
    }

    // MARK: New recordings

    /// Normalises a clip that was just made from a new recording, when the setting for that is on. It is
    /// called inside the "Record Clip" edit, so the clip arrives already evened out and one Undo takes away
    /// both. Other takes of the same line keep what they have.
    ///
    /// - Parameter loudness: how loud the clip sounds, measured when the take was looked at
    ///   (`FinishedTake.loudness`). Nil for a silent take, which is left as it is.
    func normalizeNewClip(_ clipID: UUID?, loudness: Double?, in project: inout Project) {
        guard settings[.normalizeNewRecordings], let clipID, let loudness else { return }
        project.normalize(clips: [clipID], target: settings[.targetLufs], loudness: [clipID: loudness])
    }

    // MARK: A clip's own volume

    /// The volume control of the selected clips was moved. While it is dragged the clips are only shown and
    /// heard at the new volume, and nothing in the project changes. Letting go makes it their volume, as one
    /// step that can be undone. Several clips all get the same volume.
    ///
    /// - Parameter volumeDb: from -12 to +12. It is kept to tenths of a dB, which is what the control shows.
    func setSelectedClipVolume(_ volumeDb: Double, isFinal: Bool) {
        let work = volumeWork
        work.dropWaiting()
        // A new volume is an edit, and nothing is edited while a take is going.
        guard takeStatus.phase == nil, !selection.clipIDs.isEmpty else { return }
        var changed = store.project
        changed.setClips(selection.clipIDs, gainDb: (volumeDb * 10).rounded() / 10)
        guard !isFinal else {
            work.lastHeardAt = nil
            if changed != store.project {
                store.edit("Change Volume") { $0 = changed }
            }
            // Also when the slider was put back where it started and nothing was edited.
            followClips(store.project)
            return
        }
        showClips(changed)
        work.hear { [weak self] in self?.followClips(changed) }
    }

    /// Whether the safe limit holds back a selected clip of this project: it is played more quietly than its
    /// volume says, so that its loudest moment does not distort. The volume control then shows its mark.
    ///
    /// On a track with a Voice the limit is asked about the voice the clip is heard in, as the player asks it.
    ///
    /// - Parameters:
    ///   - peaks: the highest sample of a stretch of a sound, recordings and voices alike (`VoiceModel.peaks`).
    ///   - voices: which voice stands in for which recording on which track, as last heard.
    func selectedClipVolumeIsHeldBack(in project: Project, peaks: RecordingPeak, voices: TrackVoices) -> Bool {
        guard !selection.clipIDs.isEmpty else { return false }
        for track in project.tracks {
            for clip in track.clips where selection.clipIDs.contains(clip.id) {
                if clip.appliedGain(peaks: peaks, voices: voices, on: track).isHeldBack { return true }
            }
        }
        return false
    }
}

/// What the model keeps while a volume control is dragged: the one of the selected clips (`VolumeModel`), and
/// the one of a track (`TrackVolumeModel`), each with a `VolumeWork` of its own. Nothing in the window
/// watches it.
///
/// A new volume is heard by handing the player the clips again, which makes their sound anew. A dragged
/// slider reports far more often than that is worth doing, so the moves are paced here.
@MainActor
final class VolumeWork {
    /// How often, at most, the player is handed the clips again while a volume control is dragged, in
    /// seconds. Often enough that the sound follows the hand, seldom enough that the player keeps up.
    private static let dragPace = 0.05

    /// When the player was last handed the clips during a drag of the volume control. Nil between drags.
    var lastHeardAt: Double?
    /// The newest volume of a drag, waiting to be handed to the player.
    private var waiting: Task<Void, Never>?

    /// The slider moved again or was let go: a volume that still waited to be heard is not the newest
    /// any more, and is never heard.
    func dropWaiting() {
        waiting?.cancel()
        waiting = nil
    }

    /// Lets the newest volume of a drag be heard: at once, or a moment later when the player was handed
    /// the clips less than `dragPace` ago. What waits is heard unless the slider moves again or is let go
    /// before that (`dropWaiting`).
    ///
    /// - Parameter hear: hands the player the clips at the new volume.
    func hear(_ hear: @escaping @MainActor () -> Void) {
        let now = Date.timeIntervalSinceReferenceDate
        let wait = lastHeardAt.map { $0 + Self.dragPace - now } ?? 0
        guard wait > 0 else {
            lastHeardAt = now
            hear()
            return
        }
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.waiting = nil
            self.lastHeardAt = Date.timeIntervalSinceReferenceDate
            hear()
        }
    }
}

extension AppModel {
    /// Gives `volume` its closures. `wire()` calls it once, when every part is made.
    func wireVolume() {
        volume.followClips = { [weak self] project in self?.clips.followClips(of: project) }
        volume.showClips = { [weak self] project in self?.clips.showClips(of: project) }
    }
}

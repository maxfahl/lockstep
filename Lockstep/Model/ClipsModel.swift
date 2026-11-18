import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

/// Showing and hearing clips: a part of the app's model.
///
/// It holds what every clip looks and sounds like: it hands the clips of a project to the
/// player (`followClips`) and to the window (`showClips`), asking the parts it holds for their
/// share in a fixed order.
///
/// Clips are heard through the player: `loadedSounds.sounds` holds the sound of every recording
/// of the open project, and `followClips` hands the clips to the player after every change of
/// the project that can change what is heard. The same function shows the clips in the window
/// (`showClips`), each with the waveform of its recording from `loadedSounds.waveforms`.
@MainActor
final class ClipsModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let player: Player
    private let store: ProjectStore
    private let settings: AppSettings

    // The parts it is handed, and calls directly.
    /// A track's Voice: its share of the pass comes first (`voicedClips(of:)`), and it adds the section
    /// "Voice" to the rows (`showVoice(in:of:)`).
    private let voice: VoiceModel
    private let correction: CorrectionModel
    private let sound: SoundModel
    private let words: WordsModel
    private let volume: VolumeModel
    private let tracks: TracksModel
    private let clipEditing: ClipEditingModel
    private let clipEffects: ClipEffectsModel
    private let takes: TakesModel
    private let send: SendModel

    /// Makes the track rows the timeline draws, and remembers what it made.
    var shownClips = ShownClips()
    /// True while the project holds a clip the player has not been handed yet: an attempt
    /// that a restart kept. It is heard from the end of the take on.
    private var clipsWaitForTakeEnd = false

    // What it asks of code that holds it, or of the model's routing. `wireClips` sets them.
    /// The take a take's Play button is playing, which is heard in place of the chosen take of its
    /// line (`takesStretch?.takeID`, the transport, which holds this part).
    var auditionedTake: () -> UUID? = { nil }

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        player: Player,
        store: ProjectStore,
        settings: AppSettings,
        voice: VoiceModel,
        correction: CorrectionModel,
        sound: SoundModel,
        words: WordsModel,
        volume: VolumeModel,
        tracks: TracksModel,
        clipEditing: ClipEditingModel,
        clipEffects: ClipEffectsModel,
        takes: TakesModel,
        send: SendModel
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.player = player
        self.store = store
        self.settings = settings
        self.voice = voice
        self.correction = correction
        self.sound = sound
        self.words = words
        self.volume = volume
        self.tracks = tracks
        self.clipEditing = clipEditing
        self.clipEffects = clipEffects
        self.takes = takes
        self.send = send
    }
}

extension ClipsModel {
    /// Hands the player the clips of a project and shows them in the window, so what is
    /// heard and seen is what the project says: after a new take, a deleted or muted clip,
    /// and after Undo and Redo. While the song plays, the new clips take over without the
    /// song stopping.
    ///
    /// The project is handed in, and not read from the store, because this is also called
    /// in the middle of an undo, while the store's project is being changed.
    ///
    /// During a take the clips are only shown. The player keeps the clips it has, because
    /// the one clip that can arrive then is an attempt a restart just dropped, and that
    /// must not sound in the headphones while the line is recorded again. The player gets
    /// the clips when the take ends (`hearWaitingClips`).
    ///
    /// Clips with Lines or All chosen are heard tightened: `tightenedClips` says which
    /// tightened sounds there are, and keeps them up to date (in `CorrectionModel`). It is asked
    /// before the clips are shown, so they can be drawn the way they are heard.
    ///
    /// Clips on a track with a Sound are heard finished: `finishedClips` says which finished sounds
    /// there are, and keeps them up to date (in `SoundModel`), right after the tightened sounds
    /// they are made from.
    ///
    /// While a take's Play button plays its stretch, the player is handed the project with that
    /// take in the place of the active one of its line (`heardProject`). The window shows the
    /// project as it is.
    ///
    /// One lookup table of the project is made here and handed to every step (`ProjectLookup`), so none of
    /// them searches the project's lists for each clip.
    ///
    /// On a track with a Voice the clips are heard in its voice: `voicedClips` says which voice stands in for
    /// which recording, and keeps the voices up to date (in `VoiceModel`). It comes first, because the
    /// tightened and the finished sounds are made from the voices, and its answer is handed to every step.
    func followClips(of project: Project) {
        let lookup = ProjectLookup(project)
        let voiced = voice.voicedClips(of: lookup)
        let heard = correction.tightenedClips(of: lookup, voiced: voiced)
        let heardProject = heardProject(for: project)
        let finished = sound.finishedClips(of: heardProject, tightened: heard)
        clipEditing.editTiming?.mark("tightened sounds gone through")
        // The player is told before the clips are shown: it works away from the main thread, so an edit
        // is heard while the window is still being worked out, and not after it.
        if takeStatus.flow.isGoing {
            clipsWaitForTakeEnd = true
        } else {
            clipsWaitForTakeEnd = false
            let edgeFadeMs = settings[.edgeFadeMs]
            // A finished sound that takes over fades in as a tightened one does.
            let crossfadeMs = max(heard.crossfadeMs, finished.crossfadeMs)
            player.tell {
                await $0.setClips(
                    of: heardProject,
                    recordings: heard.recordings,
                    tightened: heard.tightened,
                    finished: finished.finished,
                    finishedSamples: finished.samples,
                    edgeFadeMs: edgeFadeMs,
                    crossfadeMs: crossfadeMs, voices: heard.voices
                )
            }
        }
        showClips(of: project, lookup: lookup)
        clipEditing.editTiming?.mark("clips handed to the window")
    }

    /// Hands the player the clips it was not given while a take was going.
    func hearWaitingClips() {
        guard clipsWaitForTakeEnd, !takeStatus.flow.isGoing else { return }
        followClips(of: store.project)
    }

    // MARK: Showing and selecting clips

    /// Gives the timeline the tracks of a project with their clips: each clip at its
    /// place with its waveform, the selected ones marked, and the mark of a take on the
    /// track that is being recorded to. The window is only changed when something it
    /// shows has changed.
    ///
    /// - Parameter lookup: the lookup table of `project`, when the caller has made one. Left out, one is
    ///   made here.
    func showClips(of project: Project, lookup handed: ProjectLookup? = nil) {
        // While an edge of a clip is dragged, the clips are drawn as the trim would leave them.
        let project = clipEditing.projectShownDuringTrim(project)
        // The table that was handed in is of the project as it is, not as a trim would leave it.
        let lookup = (clipEditing.isTrimmingClip ? nil : handed) ?? ProjectLookup(project)
        // A clip that is gone (deleted, or taken away by Undo) cannot stay selected.
        // A selected clip that has become a take that waits (a newer take was recorded
        // over it, another take was chosen, or Undo put an older choice back) is not
        // drawn any more. The selection moves to the take of its line that is.
        let shown = Set(selection.clipIDs.compactMap { id -> UUID? in
            guard let clip = lookup.clip(id) else { return nil }
            // A clip that is drawn stays selected, which is nearly always so.
            if clip.isActiveTake { return id }
            return lookup.takes(of: id).first(where: \.isActiveTake)?.id
        })
        if shown != selection.clipIDs {
            selection.clipIDs = shown
        }
        // The selected track can be gone too (deleted, merged away, or taken away by Undo).
        // One track is always selected, so the first one takes its place.
        let selectedTrack = selection.trackID.flatMap { lookup.track($0)?.id } ?? project.tracks.first?.id
        if selection.trackID != selectedTrack {
            selection.trackID = selectedTrack
        }
        var rows = shownClips.rows(
            of: lookup,
            waveforms: loadedSounds.waveforms,
            selectedTrack: selectedTrack,
            selectedClips: selection.clipIDs,
            peaks: voice.peaks,
            voices: voice.heard,
            sounds: loadedSounds.sounds,
            showsWords: FeatureSet.built.contains(.clipText),
            tightened: { [self] clipID, segment in correction.heardSoundToDraw(ofSegment: segment, of: clipID) },
            tightenedID: { [self] clipID, segment in correction.heardSoundID(ofSegment: segment, of: clipID) }
        )
        // The steps from here on are noted while an edit is timed, so its line says where the time went.
        let timing = clipEditing.editTiming
        timing?.mark("rows made")
        // The small ring under "Correction" in the panel on the right shows while the sound of the selected
        // clips is being made again.
        let progress = correction.remakeProgress(ofClips: selection.clipIDs)
        if windowState.content.clipRemakeProgress != progress {
            windowState.content.clipRemakeProgress = progress
        }
        // The header of the track whose name is being typed holds the text field. No name
        // is typed during a take, and none on a track that is gone.
        if let renamed = tracks.renamedTrackID {
            if !takeStatus.flow.isGoing, let index = rows.firstIndex(where: { $0.id == renamed }) {
                rows[index].isBeingRenamed = true
            } else {
                tracks.renamedTrackID = nil
            }
        }
        if takeStatus.flow.isGoing, let origin = takeStatus.flow.origin,
            let index = rows.firstIndex(where: { $0.id == origin.trackID })
        {
            // The red clip itself grows from `takeStatus.progress`, not from here.
            var recording = TrackRecording(origin: origin.seconds)
            recording.progress = takeStatus.progress
            rows[index].recording = recording
        }
        // The syllable markers of the selected clips.
        correction.showFeels(in: &rows, of: lookup)
        timing?.mark("feels shown")
        correction.showMarkers(in: &rows, of: lookup)
        timing?.mark("markers shown")
        // Each track's Voice and how far its voices have come, for the panel on the right.
        voice.showVoice(in: &rows, of: project)
        // Each track's Sound and each clip's own knobs, for the panel on the right.
        sound.showSounds(in: &rows, of: project)
        // The bar of the clip whose name is being typed holds the text field.
        clipEditing.showClipBeingRenamed(in: &rows)
        // The words of the clips: in the help tag of each bar, and for the panel on the right.
        let selectedClipText = words.showWords(in: &rows, of: lookup)
        if windowState.content.selectedClipText != selectedClipText {
            windowState.content.selectedClipText = selectedClipText
        }
        timing?.mark("words shown")
        // A clip that is being dragged is taken out of its row and drawn lifted above the rows.
        let movedClip = clipEditing.showClipDrag(in: &rows)
        if windowState.content.timeline.dragging.movedClip != movedClip {
            windowState.content.timeline.dragging.movedClip = movedClip
        }
        // A clip whose edge is being dragged has that edge lit, and a snap line when it has snapped.
        let trimmedClip = clipEditing.showClipTrim(in: &rows)
        if windowState.content.timeline.dragging.trimmedClip != trimmedClip {
            windowState.content.timeline.dragging.trimmedClip = trimmedClip
        }
        // The marked stretch is drawn as a band on its track.
        let stretch = clipEditing.shownMarkedStretch(in: project)
        if windowState.content.timeline.dragging.markedStretch != stretch {
            windowState.content.timeline.dragging.markedStretch = stretch
        }
        // The rectangle of a drag that selects clips on several tracks, drawn over the rows it covers.
        let rectangle = clipEditing.shownSelectionRectangle
        if windowState.content.timeline.dragging.selectionRectangle != rectangle {
            windowState.content.timeline.dragging.selectionRectangle = rectangle
        }
        // Each track's and each clip's effects, for the panel on the right, the bands on the clip and the
        // mark in its bar, and the effects several selected clips share.
        // After the marked stretch is settled, because the row of an effect is lit while its stretch is
        // the marked one.
        let sharedEffects = clipEffects.showEffects(in: &rows, of: project)
        if windowState.content.selectedClipsEffects != sharedEffects {
            windowState.content.selectedClipsEffects = sharedEffects
        }
        // The clips or the selection may have changed, and with them what Split at Playhead can cut.
        clipEditing.refreshSplitAtPlayhead(in: project, lookup: lookup)
        if windowState.content.timeline.trackRows != rows {
            windowState.content.timeline.trackRows = rows
        }
        timing?.mark("rows handed to the window")
        // The volume control marks a selected clip that the safe limit holds back.
        let isHeldBack = volume.selectedClipVolumeIsHeldBack(in: project, peaks: voice.peaks, voices: voice.heard)
        if windowState.content.selectedClipVolumeIsHeldBack != isHeldBack {
            windowState.content.selectedClipVolumeIsHeldBack = isHeldBack
        }
        takes.showTakes(of: project, playing: auditionedTake())
        timing?.mark("takes shown")
        // The Resolve start time of the selected clip, which follows every change shown here.
        let resolveStart = send.resolveStartText(of: project)
        if windowState.content.selectedClipResolveStart != resolveStart {
            windowState.content.selectedClipResolveStart = resolveStart
        }
        // The Send to DaVinci panel, while it is open, shows the selected clip as it is now.
        send.followSendPanel(of: project)
        timing?.mark("Send panel followed")
    }

    /// The project as the player is to hear it. While a take's Play button plays its stretch,
    /// that take is the active one of its line here, and only here: the open project, the
    /// window and the undo list know nothing of it. A take that is gone meanwhile changes nothing.
    /// Listening is not choosing, so no clip gives way to the take, here or in the project.
    private func heardProject(for project: Project) -> Project {
        guard let takeID = auditionedTake() else { return project }
        var heard = project
        heard.setActiveTake(takeID)
        return heard
    }
}

extension ClipsModel {
    // MARK: A project opens

    /// A song or a project is about to be shown in place of what was open, and the store has not
    /// opened it yet: the rows that were made for the old project are not this one's.
    func projectWillOpen() {
        shownClips = ShownClips()
    }
}

extension AppModel {
    /// Gives `clips` its closures. `wire()` calls it once, when every part is made.
    func wireClips() {
        clips.auditionedTake = { [weak self] in self?.transport.takesStretch?.takeID }
    }
}

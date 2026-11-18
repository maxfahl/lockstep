import AppKit
import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import Observation
import QuartzCore

/// Editing clips: a part of the app's model.
///
/// It holds the editing of clips: selecting, moving, copying, trimming, renaming, splitting,
/// joining, muting, deleting, copy and paste, the marked stretch, the rectangle that selects clips
/// on several tracks (and `-selectRect`), the timing of an edit (the log
/// line of every edit, `-deleteClip` and `-timeEdits`), and the big test project (`-bigProject`).
///
/// Selecting: a click on a clip selects it and a click beside the clips selects none
/// (`selectClip`). Delete and Mute Clip act on `selection.clipIDs`, one undo step each. A deleted
/// clip keeps its recording, so Undo can bring it back. Recordings that no clip uses are removed
/// when the project is closed (`closeProject`, in the opening part).
///
/// It is one class in eight files. This one has the class, selecting, the marked stretch, the
/// rectangle that selects clips on several tracks, and the commands. What `-selectRect` does is in
/// `ClipEditingModel+SelectRect.swift`. Dragging and naming a clip are in `ClipEditingModel+Moves.swift`, dragging an edge
/// in `ClipEditingModel+Trims.swift`, Copy and Paste in `ClipEditingModel+Copies.swift`, the
/// timing of an edit in `ClipEditingModel+EditTiming.swift`, the list of edits `-timeEdits` makes
/// in `ClipEditingModel+TimeEdits.swift`, and the building of the big test project in
/// `ClipEditingModel+BigProject.swift`.
@MainActor
@Observable
final class ClipEditingModel {
    // The ground it is handed. Not `private`, because the part's other files use it too.
    @ObservationIgnored let windowState: WindowState
    @ObservationIgnored let selection: Selection
    @ObservationIgnored let loadedSounds: LoadedSounds
    @ObservationIgnored let takeStatus: TakeStatus
    @ObservationIgnored let player: Player
    @ObservationIgnored let store: ProjectStore
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let playhead: PlayheadPosition

    // The parts it is handed, and calls directly. Not `private`, for the same reason.
    @ObservationIgnored let timelineView: TimelineViewModel
    @ObservationIgnored let loop: LoopModel
    @ObservationIgnored let words: WordsModel
    @ObservationIgnored let tracks: TracksModel
    /// Only `-bigProject` and `-timeEdits` call it: the syllables of the made-up recordings, whether
    /// every tightened sound is made, and the slider Strength.
    @ObservationIgnored let correction: CorrectionModel

    // What it asks of code that holds it, or of the model's routing. `wireClipEditing` sets them.
    /// Lets the player and the window follow the clips of a project (`followClips(of:)`, the clips'
    /// part).
    @ObservationIgnored var followClips: (Project) -> Void = { _ in }

    /// Shows the clips of a project in the window, without telling the player (`showClips(of:)`,
    /// the clips' part).
    @ObservationIgnored var showClips: (Project) -> Void = { _ in }

    /// Carries out a command the way the menu and the keyboard do (`perform(_:)`, the model's
    /// routing). Only `-pasteClip` and `-deleteClip` call it.
    @ObservationIgnored var perform: (AppCommand) -> Void = { _ in }

    /// Waits until `-tighten` and `-strength` have acted (`launchTightened()`, correction). Only
    /// `-deleteClip` waits for it.
    @ObservationIgnored var launchTightened: () async -> Void = {}

    /// Whether the beats of the song are being found right now (`beatFinding != nil`, the beats).
    /// Only `-bigProject` asks, which lays its clips along a song whose beats are known.
    @ObservationIgnored var beatsAreBeingFound: () -> Bool = { false }

    /// Moves the playhead to a place in the song (`seek(to:)`, the transport). Only `-timeEdits`
    /// calls it, to paste and to split at a place it has chosen.
    @ObservationIgnored var seek: (Double) -> Bool = { _ in false }

    // MARK: What it keeps

    /// What is kept while a clip is dragged by its bar. See `ClipEditingModel+Moves.swift`.
    @ObservationIgnored let clipWork = ClipWork()
    /// Whether Split at Playhead has a clip to cut right now. The menus read this and not
    /// the playhead itself, so they are drawn again only when the answer changes, not on
    /// every frame while the song plays. `refreshSplitAtPlayhead` keeps it right.
    var canSplitAtPlayhead = false
    /// The stopwatch of the edit that is being timed, while it is made: an edit of Max's own, or what
    /// `-deleteClip` and `-timeEdits` measure. Nil at every other time. See `ClipEditingModel+EditTiming.swift`.
    @ObservationIgnored var editTiming: EditTiming?
    /// The stopwatch of the edit that was made last, for as long as its line is being put together: about
    /// a second. A handing over of the clips that comes in that second is noted in it (`timeLaterPass`).
    @ObservationIgnored weak var reportedTiming: EditTiming?
    /// What `-bigProject` asked for, while it is being built and after. See `ClipEditingModel+BigProject.swift`.
    @ObservationIgnored var bigProjectLaunch: Task<Void, Never>?
    /// True once what `-timeEdits` asked for was started.
    @ObservationIgnored var launchTimeEditsTaken = false
    /// True once what `-deleteClip` asked for was started.
    @ObservationIgnored var launchDeleteTaken = false
    /// The clips Edit > Copy copied last, for Edit > Paste. Watched, so Paste is enabled once
    /// something was copied. The rest is in `ClipEditingModel+Copies.swift`.
    var copiedClips = CopiedClips()
    /// True once what `-pasteClip` asked for was started.
    @ObservationIgnored var launchPasteTaken = false
    /// True once what `-selectRect` asked for was started.
    @ObservationIgnored var launchSelectRectTaken = false

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        player: Player,
        store: ProjectStore,
        settings: AppSettings,
        playhead: PlayheadPosition,
        timelineView: TimelineViewModel,
        loop: LoopModel,
        words: WordsModel,
        tracks: TracksModel,
        correction: CorrectionModel
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.player = player
        self.store = store
        self.settings = settings
        self.playhead = playhead
        self.timelineView = timelineView
        self.loop = loop
        self.words = words
        self.tracks = tracks
        self.correction = correction
    }
}

// Selecting several clips and marking a stretch of a track. What it keeps
// between two calls is in `clipWork`, and the stretch itself is
// `Selection.markedStretch`.
//
// Selecting: a click on a clip selects that clip alone. A click with Shift or Command
// adds the clip to the selected ones, or takes it out when it is one of them. A click
// beside the clips selects none (`trackRowClicked`).
//
// Marking: a drag sideways across a track's row, from anywhere but a clip's bar, marks a
// stretch of that track, from where the drag started to where the pointer is, in either
// direction (`stretchDragged`), and never into a part of the song that is cut away. The
// window draws it as a see-through band. There is one
// stretch at most: a new drag replaces it, and Escape (Edit > Clear Marked Stretch) or a
// click beside the clips takes it away. While snapping is on, each edge of the stretch
// catches on a bar start that is near (`snappedToBarStart`), and
// with Command held it is the other way round.
//
// A rectangle: while the pointer of that same drag is in another track's row, the drag is a
// rectangle from the row it started in to the row the pointer is in, and every shown clip it
// touches on those tracks is selected (`SelectionDrag` in LockstepCore is the rule, asked again
// on every report). Back in the first row it is a stretch again. With Shift held when the drag
// starts, the clips are added to what was selected, and without it they take its place. The
// rectangle's edges never snap, and it is drawn only while the button is down
// (`TimelineDragging.selectionRectangle`): when the button is let go the clips stay selected,
// and Delete, a drag by a bar and Copy act on all of them. A move that changes no clip draws
// only the rectangle again and shows no clips (`showStretchDrag`).
//
// One or the other: marking a stretch selects its track and no clip, and selecting a
// clip takes the stretch away. So Delete always knows what it acts on. `shownMarkedStretch`
// keeps that rule, whoever changed the selection. The one exception is the stretch of an
// effect whose row in the panel was clicked (`markStretch(_:ofSelectedClip:)`): it stays
// while that clip alone is selected, so the panel goes on showing the clip and its effects.
// Delete then removes the stretch, as its menu item says.
//
// Neither the selection nor the stretch is part of the project. They are not saved and
// Undo does not bring them back.
//
// The commands: Split at Playhead, Join Clips and Delete, from the Edit menu, from a clip's
// right-click menu and from their shortcuts. Each asks the clip rules of `ProjectClipEdits`
// whether it can be carried out, and makes one edit named after itself, so Undo and Redo
// put back the very clips that were there. A command that is refused changes nothing and
// makes no undo step.
extension ClipEditingModel {
    // MARK: Selecting clips

    /// A track's row was clicked, on a clip or beside one.
    func trackRowClicked(on trackID: UUID, at seconds: Double) {
        // Letting go after marking a stretch can also arrive as a click, before or after
        // the end of the drag is reported. It is the end of the drag and selects nothing.
        if clipWork.stretchReport != nil {
            return
        }
        if let ended = clipWork.stretchEndEventTime, NSApp.currentEvent?.timestamp == ended {
            return
        }
        let held = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        guard held.contains(.shift) || held.contains(.command),
              let clip = store.project.clip(on: trackID, at: seconds)
        else {
            // A plain click, or a click beside the clips: one clip or none is selected.
            selectClip(on: trackID, at: seconds)
            clearMarkedStretch()
            return
        }
        // With Shift or Command the clip joins the selected ones, or leaves them.
        var selected = selection.clipIDs
        if selected.contains(clip.id) {
            selected.remove(clip.id)
        } else {
            selected.insert(clip.id)
        }
        selection.clipIDs = selected
        selection.trackID = trackID
        showClips(store.project)
    }

    /// A plain click in a track's row. A click on a clip selects that clip and its track,
    /// and a click beside the clips selects no clip. `trackRowClicked` calls it, and deals
    /// with Shift, Command and the marked stretch itself.
    func selectClip(on trackID: UUID, at seconds: Double) {
        guard let clip = store.project.clip(on: trackID, at: seconds) else {
            guard !selection.clipIDs.isEmpty else { return }
            selection.clipIDs = []
            showClips(store.project)
            return
        }
        guard selection.clipIDs != [clip.id] || selection.trackID != trackID else { return }
        selection.clipIDs = [clip.id]
        selection.trackID = trackID
        showClips(store.project)
    }

    // MARK: Marking a stretch

    /// A stretch of a track is being marked by dragging across its row, or the button was
    /// just let go.
    func stretchDragged(_ report: StretchDrag) {
        let work = clipWork
        if let givenUp = work.stretchGivenUp {
            if givenUp.isSameDrag(as: report) {
                if report.isFinished {
                    work.stretchGivenUp = nil
                }
                return
            }
            work.stretchGivenUp = nil
        }
        // The end of the last marking was never reported, and this is another one.
        if let last = work.stretchReport, !last.isSameDrag(as: report) {
            forgetStretchDrag()
        }
        var isFirstReport = false
        if work.stretchReport == nil {
            // A stretch is there to be cut out, which is an edit, and nothing is edited
            // while a take is going. A rectangle is not started then either.
            guard FeatureSet.built.contains(.clipEditing), takeStatus.phase == nil, loadedSounds.song != nil,
                  store.project.track(report.trackID) != nil
            else {
                if !report.isFinished {
                    work.stretchGivenUp = report
                }
                return
            }
            // A name that is being typed is kept first, as before any other change.
            tracks.stopRenamingTrack()
            stopRenamingClip()
            // What the drag does to the selected clips is settled on every report (`showStretchDrag`): a
            // stretch empties them and a rectangle selects its own. So what is selected now, and whether
            // Shift is held, is remembered before either changes it.
            work.stretchSelectedBefore = selection.clipIDs
            work.stretchAddsToSelection = NSEvent.modifierFlags.contains(.shift)
            work.stretchRectangle = nil
            work.stretchIsMarking = false
            work.stretchLookup = nil
            work.rectangleMoves = 0
            work.rectangleReselections = 0
            work.rectangleSlowestMove = 0
            // The track the drag started on is the selected one, for a stretch and for a rectangle.
            work.stretchClipID = nil
            selection.trackID = report.trackID
            work.stretchLastFrameAt = nil
            work.stretchFrames.onFrame = { [weak self] in self?.stretchDragFrame() }
            work.stretchFrames.start()
            isFirstReport = true
        }
        work.stretchReport = report
        showStretchDrag(showingAll: isFirstReport)
        if report.isFinished {
            finishStretchDrag()
            work.stretchEndEventTime = NSApp.currentEvent?.timestamp
        }
    }

    /// The button was let go. A stretch stays marked. A rectangle goes and the clips it selected stay
    /// selected, and one line about it goes to the Mac's log, like the line of every edit
    /// (`timeEdit`): how many clips it selected on how many tracks, and how the window kept up with it.
    private func finishStretchDrag() {
        let work = clipWork
        guard let rectangle = work.stretchRectangle else { return forgetStretchDrag() }
        let clips = rectangle.clipIDs.count
        let what = "Selection rectangle, \(clips) \(clips == 1 ? "clip" : "clips") selected on \(rectangle.trackIDs.count) tracks "
            + "(worked out \(work.rectangleMoves) times, \(work.rectangleReselections) of them changed the selected clips, "
            + String(format: "the slowest took %.1f ms)", work.rectangleSlowestMove * 1_000)
        timeEdit(what) {
            forgetStretchDrag()
            editTiming?.mark("rectangle taken away")
        }
    }

    /// Works out the drag from where it started and where the pointer is now, with the timeline as it
    /// is at this moment, and draws it. Also called when Command or N turns snapping the other way
    /// during the drag.
    func followStretchDrag() {
        showStretchDrag(showingAll: false)
    }

    /// Asks the rule what the drag is right now (`SelectionDrag`) and shows that: with the pointer in the
    /// row the drag started in, a stretch of that track, and in another track's row a rectangle that
    /// selects the clips it touches.
    ///
    /// - Parameter showingAll: the clips are shown again whatever the drag changed. For the first report
    ///   of a drag, which has selected its track.
    private func showStretchDrag(showingAll: Bool) {
        let work = clipWork
        guard let report = work.stretchReport, loadedSounds.song != nil else { return }
        let started = CACurrentMediaTime()
        let pointerSeconds = timelineView.scale.seconds(forX: Double(report.x))
        let drag = SelectionDrag(
            in: stretchDragLookup(),
            trackID: report.trackID,
            startSeconds: report.startSeconds,
            pointerSeconds: pointerSeconds,
            rowsDown: report.rowsDown,
            selectedBefore: work.stretchSelectedBefore,
            addsToSelection: work.stretchAddsToSelection
        )
        switch drag {
        case .stretch:
            // The stretch takes the place of the selected clips, and of the rectangle the drag was.
            work.stretchRectangle = nil
            if !selection.clipIDs.isEmpty {
                selection.clipIDs = []
            }
            if !work.stretchIsMarking {
                work.stretchIsMarking = true
                // Loop now loops this stretch, as whole bars, and not the in and out set before it.
                loop.stretchIsNewer = true
            }
            // Both ends catch on a bar start that is near, so a stretch marked to be looped is whole bars.
            let pointer = snappedToBarStart(pointerSeconds)
            let anchor = snappedToBarStart(report.startSeconds)
            // Either direction, and never outside what is left of the song: a drag that starts
            // or ends where the song is cut away marks up to the cut.
            let stretch = store.project.keptPart(of: min(anchor, pointer)...max(anchor, pointer))
                .map { MarkedStretch(trackID: report.trackID, range: $0) }
            if selection.markedStretch != stretch {
                selection.markedStretch = stretch
            }
            showClips(store.project)
        case .rectangle(let rectangle):
            // One or the other: a rectangle selects clips, so no stretch is marked with it. Its edges are
            // where the drag started and where the pointer is. Nothing snaps: it selects clips, not time.
            work.stretchIsMarking = false
            work.stretchRectangle = rectangle
            let wasMarked = selection.markedStretch != nil
            if wasMarked {
                selection.markedStretch = nil
            }
            let reselected = selection.clipIDs != rectangle.clipIDs
            if reselected {
                selection.clipIDs = rectangle.clipIDs
            }
            if reselected || wasMarked || showingAll {
                showClips(store.project)
            } else {
                // Most moves change no clip: only the rectangle is drawn again, and no row is worked out.
                showSelectionRectangle()
            }
            work.rectangleMoves += 1
            work.rectangleReselections += reselected ? 1 : 0
            work.rectangleSlowestMove = max(work.rectangleSlowestMove, CACurrentMediaTime() - started)
        }
    }

    /// The lookup table of the project for the drag that is going on. It is made at the first report and
    /// kept, so a move of the pointer finds the clips a rectangle touches without a search. Something
    /// else can still change the project while the button is down (Undo with its key), and the table is
    /// then made again. Unchanged lists are told at a glance: they are the very lists the table holds.
    private func stretchDragLookup() -> ProjectLookup {
        let project = store.project
        if let kept = clipWork.stretchLookup, kept.project.tracks == project.tracks,
           kept.project.recordings == project.recordings {
            return kept
        }
        let made = ProjectLookup(project)
        clipWork.stretchLookup = made
        return made
    }

    /// The rectangle of the drag that is going on, as the window draws it, or nil. `showClips` writes it
    /// beside the marked stretch.
    var shownSelectionRectangle: SelectionRectangle? {
        guard let rectangle = clipWork.stretchRectangle, let first = rectangle.trackIDs.first,
              let last = rectangle.trackIDs.last
        else { return nil }
        return SelectionRectangle(firstTrackID: first, lastTrackID: last, range: rectangle.range)
    }

    /// Draws the rectangle as it is now, or takes it away, and nothing else: for a move that changed no
    /// clip, and for the end of the drag.
    private func showSelectionRectangle() {
        let rectangle = shownSelectionRectangle
        if windowState.content.timeline.dragging.selectionRectangle != rectangle {
            windowState.content.timeline.dragging.selectionRectangle = rectangle
        }
    }

    /// Where an end of the marked stretch goes while it is dragged: onto a bar start that
    /// is within the snap distance on screen, or where it is when none is, when snapping is
    /// off (or on with Command held, `snappingHolds`), or when the song has no beats.
    func snappedToBarStart(_ seconds: Double) -> Double {
        guard timelineView.snappingHolds, timelineView.scale.pointsPerSecond > 0, let grid = store.project.grid else { return seconds }
        let tolerance = Double(settings[.snapDistancePoints]) / timelineView.scale.pointsPerSecond
        let bars = SnapEngine(sources: [BarStartSource(grid: grid)])
        // The end is a single place, so it is held against the bar starts as both edges of nothing.
        guard let snap = bars.snap(start: seconds, end: seconds, tolerance: tolerance) else { return seconds }
        return seconds + snap.delta
    }

    /// Once per display frame while a stretch is marked. With the pointer near the left or
    /// the right edge of the timeline, the timeline scrolls that way and the stretch grows
    /// with it.
    private func stretchDragFrame() {
        let work = clipWork
        let now = CACurrentMediaTime()
        // A frame that came late does not make the timeline jump.
        let elapsed = min(now - (work.stretchLastFrameAt ?? now), 0.1)
        work.stretchLastFrameAt = now
        guard let report = work.stretchReport else { return }
        if timelineView.scrollTimeline(towardPointerAt: Double(report.x), during: elapsed) {
            followStretchDrag()
        }
    }

    /// Ends the drag that is going on. The stretch that was marked so far stays, and so do the clips a
    /// rectangle selected. The rectangle itself is only there while the button is down, and goes.
    private func forgetStretchDrag() {
        let work = clipWork
        work.stretchReport = nil
        work.stretchFrames.stop()
        work.stretchLookup = nil
        work.stretchRectangle = nil
        showSelectionRectangle()
    }

    /// Clear Marked Stretch (Escape), and a click beside the clips: the marked stretch is
    /// taken away. Nothing in the project changes. During the drag that marks it, the
    /// button is still down, so the rest of that drag is not listened to.
    func clearMarkedStretch() {
        let work = clipWork
        if let report = work.stretchReport {
            work.stretchGivenUp = report
            forgetStretchDrag()
        }
        work.stretchClipID = nil
        guard selection.markedStretch != nil else { return }
        selection.markedStretch = nil
        showClips(store.project)
    }

    /// Marks the stretch of an effect of a selected clip: the row of the effect was clicked in the
    /// panel on the right. The clip stays selected, so the panel goes on showing it, and the stretch
    /// stays until the selection changes, another stretch is marked or it is cleared. Loop then
    /// loops it, and an effect that is added goes on it.
    func markStretch(_ stretch: MarkedStretch, ofSelectedClip clipID: UUID) {
        let work = clipWork
        if let report = work.stretchReport {
            work.stretchGivenUp = report
            forgetStretchDrag()
        }
        work.stretchClipID = clipID
        loop.stretchIsNewer = true
        if selection.markedStretch != stretch {
            selection.markedStretch = stretch
        }
        showClips(store.project)
    }

    /// Called by `showClips`: the marked stretch as the window draws it, or nil.
    ///
    /// Every drawing of the clips goes through `showClips`, and every change of the
    /// selection is followed by one. So this is where the rule "a stretch or selected
    /// clips, never both" is kept, whatever selected the clips: a click, a right-click, a
    /// drag by a bar or the take count. A stretch whose track is gone (deleted, merged
    /// away, or taken away by Undo) goes too.
    func shownMarkedStretch(in project: Project) -> MarkedStretch? {
        guard let stretch = selection.markedStretch else { return nil }
        // The stretch of an effect stays with its clip while that clip alone is selected.
        let staysWithClip = clipWork.stretchClipID.map { selection.clipIDs == [$0] } ?? false
        guard selection.clipIDs.isEmpty || staysWithClip, project.track(stretch.trackID) != nil else {
            selection.markedStretch = nil
            clipWork.stretchClipID = nil
            if let report = clipWork.stretchReport {
                clipWork.stretchGivenUp = report
                forgetStretchDrag()
            }
            return nil
        }
        return stretch
    }

    // MARK: Split at Playhead

    /// The clips Split at Playhead would cut in two with the playhead at a place in the
    /// song: every selected clip that can be split there, or, with no clip selected, the
    /// clip under the playhead on the selected track.
    private func clipsToSplit(in project: Project, at seconds: Double) -> Set<UUID> {
        guard selection.clipIDs.isEmpty else {
            return selection.clipIDs.filter { project.canSplit(clip: $0, at: seconds) }
        }
        guard let trackID = selection.trackID ?? project.tracks.first?.id,
              let clip = project.clip(on: trackID, at: seconds),
              project.canSplit(clip: clip.id, at: seconds)
        else { return [] }
        return [clip.id]
    }

    /// Split at Playhead: cuts those clips in two at the playhead, as one step that can be
    /// undone. Every take of a cut line is cut at the same place. Afterwards the pieces to
    /// the right of the playhead are the selected clips.
    func splitAtPlayhead() {
        guard takeStatus.phase == nil else { return }
        let seconds = playhead.seconds
        let peaks = correction.voice.peaks
        var changed = store.project
        var rightPieces: Set<UUID> = []
        for id in clipsToSplit(in: changed, at: seconds) {
            if let pieces = changed.splitClip(id, at: seconds, peaks: peaks, voices: correction.voice.heard) {
                rightPieces.insert(pieces.second)
            }
        }
        guard !rightPieces.isEmpty else { return }
        // The words of the uncut clip are no longer right for its pieces.
        let pieces = words.clearWordsOfCutClips(in: &changed)
        store.edit(AppCommand.splitAtPlayhead.title) { $0 = changed }
        selection.clipIDs = rightPieces
        // While the song plays, the cut is heard at once, which is to say not at all.
        followClips(store.project)
        words.writeOutWords(ofCutClips: pieces)
    }

    /// Listens for the next move of the playhead, so that Split at Playhead is offered
    /// exactly while it has a clip to cut. Called once at the start, and again after every
    /// move it heard of.
    func followPlayheadForSplitting() {
        withObservationTracking(
            { _ = playhead.seconds },
            onChange: Self.playheadMoveReport(to: self)
        )
    }

    /// What the playhead calls when it is about to move. It is made here, outside the
    /// main actor, and comes back to the model on the main actor a moment later, when the
    /// new place is in.
    private nonisolated static func playheadMoveReport(to model: ClipEditingModel) -> @Sendable () -> Void {
        { [weak model] in
            Task { @MainActor in
                model?.playheadMoved()
            }
        }
    }

    private func playheadMoved() {
        followPlayheadForSplitting()
        refreshSplitAtPlayhead(in: store.project)
    }

    /// Works out again whether Split at Playhead has a clip to cut, and keeps the answer in
    /// `canSplitAtPlayhead` for the menus. Called when the playhead has moved and, by
    /// `showClips`, when the clips or the selection have changed.
    ///
    /// - Parameter lookup: the lookup table of the project, when the caller has one. With many clips
    ///   selected, each of them is asked about.
    func refreshSplitAtPlayhead(in project: Project, lookup: ProjectLookup? = nil) {
        let seconds = playhead.seconds
        clipWork.playheadSeconds = seconds
        let canSplit: Bool
        if let lookup, !selection.clipIDs.isEmpty {
            canSplit = selection.clipIDs.contains { lookup.canSplit(clip: $0, at: seconds) }
        } else {
            canSplit = !clipsToSplit(in: project, at: seconds).isEmpty
        }
        if canSplitAtPlayhead != canSplit {
            canSplitAtPlayhead = canSplit
        }
    }

    // MARK: Join Clips

    /// Join Clips: makes one clip of the selected clips, as one step that can be undone.
    /// Every part stays where it was and as loud as it was, and the joined clip is the
    /// selected one afterwards.
    func joinSelectedClips() {
        guard takeStatus.phase == nil else { return }
        var changed = store.project
        guard let joined = changed.joinClips(selection.clipIDs, peaks: correction.voice.peaks, voices: correction.voice.heard) else { return }
        store.edit(AppCommand.joinClips.title) { $0 = changed }
        selection.clipIDs = [joined]
        followClips(store.project)
    }

    // MARK: Delete

    /// Delete: with a stretch marked, that stretch is removed from the clips of its track,
    /// as one step that can be undone, and the mark goes. A clip the stretch goes through
    /// the middle of becomes two, and nothing after the stretch moves. A stretch that
    /// touches no clip only loses its mark. With no stretch marked, the selected clips are
    /// deleted.
    func deleteMarkedStretchOrClips() {
        guard let stretch = selection.markedStretch else {
            deleteSelectedClips()
            return
        }
        guard takeStatus.phase == nil else { return }
        var changed = store.project
        let range = stretch.range.lowerBound..<stretch.range.upperBound
        var pieces: [UUID] = []
        if changed.cut(range: range, onTrack: stretch.trackID, peaks: correction.voice.peaks, voices: correction.voice.heard) != nil {
            // The words of a clip that lost a stretch are no longer right for what is left of it.
            pieces = words.clearWordsOfCutClips(in: &changed)
            store.edit(Self.deleteMarkedStretchTitle) { $0 = changed }
        }
        clearMarkedStretch()
        followClips(store.project)
        words.writeOutWords(ofCutClips: pieces)
    }

    /// The title Delete has in the Edit menu while a stretch is marked, and the name of
    /// that edit under Undo.
    static let deleteMarkedStretchTitle = "Delete Marked Stretch"

    // MARK: Mute Clip and Delete, of the selected clips

    /// Mute Clip: mutes the selected clips, as one step that can be undone. When all of
    /// them are muted already, they are heard again instead.
    func muteSelectedClips() {
        let ids = selection.clipIDs
        let clips = store.project.clips(ids)
        guard !clips.isEmpty else { return }
        let mute = !clips.allSatisfy(\.muted)
        store.edit(mute ? "Mute Clip" : "Unmute Clip") { $0.setClips(ids, muted: mute) }
        followClips(store.project)
    }

    /// Delete: removes the selected clips, as one step that can be undone. Their
    /// recordings stay in the project, so Undo can bring the clips back.
    func deleteSelectedClips() {
        let ids = selection.clipIDs
        let count = store.project.clips(ids).count
        guard count > 0 else { return }
        // The other takes of the lines that lose a clip. Of each line, one of them
        // comes forward when its active take is gone.
        // Asked of a lookup table, because with many clips selected it is asked for each of them.
        let lookup = ProjectLookup(store.project)
        let otherTakes = Set(ids.flatMap { lookup.takes(of: $0).map(\.id) }).subtracting(ids)
        store.edit(count == 1 ? "Delete Clip" : "Delete Clips") { $0.removeClips(ids) }
        editTiming?.mark("project changed")
        // The take that came forward is selected in place of the deleted one, so the
        // next Delete, or a look at the takes, goes on with the same line.
        selection.clipIDs = Set(store.project.clips(otherTakes).filter(\.isActiveTake).map(\.id))
        followClips(store.project)
    }

    // MARK: Test clips

    #if DEBUG
    /// Debug > Add Test Clips, in debug builds only: fills the open project up to twelve
    /// tracks and adds two hundred clips (`TestClips`), as one step that can be undone, so
    /// scrolling and zooming can be tried on a heavy project. The clips play one short
    /// made-up recording, which is written into the project like a take.
    func addTestClips() {
        guard takeStatus.phase == nil, loadedSounds.song != nil, !loadedSounds.isOpening, let package = store.package else { return }
        tracks.stopRenamingTrack()
        let samples = TestClips.sound()
        let recording = Recording(lengthSamples: samples.count, rawStart: 0)
        do {
            try FileManager.default.createDirectory(at: package.takesFolder, withIntermediateDirectories: true)
            try WavWriter.write(samples, channels: 1, to: package.url.appendingPathComponent(recording.file))
        } catch {
            windowState.alert = MessageAlert(
                title: "Lockstep could not add the test clips.",
                detail: error.localizedDescription
            )
            windowState.showsAlert = true
            return
        }
        loadedSounds.sounds[recording.id] = samples
        loadedSounds.waveforms[recording.id] = WaveformPyramid(interleaved: samples, channelCount: 1)
        store.edit("Add Test Clips") { TestClips.add(to: &$0, playing: recording) }
        followClips(store.project)
    }
    #endif
}

extension AppModel {
    /// Gives `clipEditing` its closures. `wire()` calls it once, when every part is made.
    func wireClipEditing() {
        clipEditing.followClips = { [weak self] project in self?.clips.followClips(of: project) }
        clipEditing.showClips = { [weak self] project in self?.clips.showClips(of: project) }
        clipEditing.perform = { [weak self] command in self?.perform(command) }
        clipEditing.launchTightened = { [weak self] in await self?.correction.launchTightened() }
        clipEditing.beatsAreBeingFound = { [weak self] in self?.beats.beatFinding != nil }
        clipEditing.seek = { [weak self] seconds in self?.transport.seek(to: seconds) ?? false }
    }
}

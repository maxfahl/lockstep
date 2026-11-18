import AppKit
import LockstepCore
import LockstepUI
import QuartzCore

// Trimming a clip by dragging its left or its right edge. It is part of `ClipEditingModel` and
// lives in a file of its own so the part's main file stays readable. What it keeps
// between two calls is in `ClipEditingModel.clipWork`.
//
// The window reports a drag that started on an edge of a clip (`clipEdgeDragged`), on
// every move and when the button is let go. `ClipTrim` works out where the edge would
// be, inside the limits and with snapping, and `showClips` draws the clip with its edge
// there (`projectShownDuringTrim`, `showClipTrim`). Nothing in the project changes until
// the edge is let go. Then the trim is made as one edit, "Trim Clip": only the grabbed
// clip, no sound moved, and its words written out again as after a split. An edge dragged
// outwards over a clip of another line makes that clip give way, in the same edit, and the
// drawing during the drag shows it. Escape gives the drag up. Nothing is trimmed during a take.
extension ClipEditingModel {
    /// The name of the edit under Undo.
    private static let trimClipTitle = "Trim Clip"

    /// A clip is being dragged by one of its edges, or the edge was just let go.
    func clipEdgeDragged(_ report: ClipEdgeDrag) {
        let work = clipWork
        if let givenUp = work.trimGivenUp {
            if givenUp.isSameDrag(as: report) {
                if report.isFinished {
                    work.trimGivenUp = nil
                }
                return
            }
            work.trimGivenUp = nil
        }
        // The end of the last drag was never reported, and this is another one.
        if work.trim != nil, let last = work.trimReport, !last.isSameDrag(as: report) {
            forgetClipTrim()
        }
        if work.trim == nil {
            guard let trim = startClipTrim(report) else {
                if !report.isFinished {
                    work.trimGivenUp = report
                }
                return
            }
            work.trim = trim
            work.trimLastFrameAt = nil
            work.escape.onEscape = { [weak self] in self?.giveUpClipTrim() }
            work.escape.start()
            work.trimFrames.onFrame = { [weak self] in self?.clipTrimFrame() }
            work.trimFrames.start()
        }
        work.trimReport = report
        guard report.isFinished else {
            followClipTrim()
            return
        }
        // Where the pointer is at the very end counts, then the trim is made.
        followClipTrim(showing: false)
        dropClipTrim()
    }

    /// The first report of a drag: the clip whose edge was grabbed is selected, and with
    /// it the track it is on. Nil when nothing may be trimmed right now.
    private func startClipTrim(_ report: ClipEdgeDrag) -> ClipTrim? {
        // A trim is an edit, and nothing is edited while a take is going. While a name is
        // typed, or a clip is dragged by its bar, that comes first.
        guard FeatureSet.built.contains(.clipEditing), takeStatus.phase == nil, loadedSounds.song != nil,
              clipWork.renamedClipID == nil, clipWork.drag == nil,
              let trim = ClipTrim(
                  grabbing: report.clipID,
                  edge: report.edge,
                  grabbedAt: report.startSeconds,
                  in: store.project,
                  playhead: playhead.seconds,
                  snapTo: settings.snapChoices
              )
        else { return nil }
        tracks.stopRenamingTrack()
        // Only the grabbed clip is trimmed, so it is the selected one. A clip that was one
        // of several selected clips leaves the others selected.
        if !selection.clipIDs.contains(report.clipID) {
            selection.clipIDs = [report.clipID]
        }
        selection.trackID = trim.trackID
        return trim
    }

    /// Works out where the dragged edge is now, from where the pointer is and from the
    /// timeline as it is at this moment, and draws the clip with its edge there.
    func followClipTrim(showing: Bool = true) {
        let work = clipWork
        guard var trim = work.trim, let report = work.trimReport else { return }
        // Snapping as it holds right now, with Command turning it the other way (`TimelineViewModel.snapTolerance`).
        trim.follow(pointerSeconds: timelineView.scale.seconds(forX: Double(report.x)), snapTolerance: timelineView.snapTolerance)
        work.trim = trim
        if showing {
            showClips(store.project)
        }
    }

    /// Once per display frame while an edge is dragged. With the pointer near the left or
    /// the right edge of the timeline, the timeline scrolls that way and the edge goes with it.
    private func clipTrimFrame() {
        let work = clipWork
        let now = CACurrentMediaTime()
        // A frame that came late does not make the timeline jump.
        let elapsed = min(now - (work.trimLastFrameAt ?? now), 0.1)
        work.trimLastFrameAt = now
        guard work.trim != nil, let report = work.trimReport else { return }
        if timelineView.scrollTimeline(towardPointerAt: Double(report.x), during: elapsed) {
            followClipTrim()
        }
    }

    /// The edge was let go: the trim is made, as one step that can be undone. An edge let
    /// go where it was grabbed makes no step.
    private func dropClipTrim() {
        guard let trim = clipWork.trim else { return }
        forgetClipTrim()
        var changed = store.project
        guard takeStatus.phase == nil,
              changed.trimClip(trim.clipID, edge: trim.edge, toSongSample: trim.sample, peaks: correction.voice.peaks, voices: correction.voice.heard) != nil
        else {
            showClips(store.project)
            return
        }
        // The words of the clip are for more sound, or for less, than it now plays.
        let cut = words.clearWordsOfCutClips(in: &changed)
        store.edit(Self.trimClipTitle) { $0 = changed }
        // While the song plays, the new edge is heard at once. A tightened sound is made again.
        followClips(store.project)
        words.writeOutWords(ofCutClips: cut)
    }

    /// Escape during a drag: the edge goes back to where it was, and nothing is changed.
    /// The button is still down, so the rest of this drag is not listened to.
    private func giveUpClipTrim() {
        guard clipWork.trim != nil else { return }
        clipWork.trimGivenUp = clipWork.trimReport
        forgetClipTrim()
        showClips(store.project)
    }

    /// Ends the drag without trimming anything and without drawing.
    private func forgetClipTrim() {
        let work = clipWork
        work.trim = nil
        work.trimReport = nil
        work.escape.stop()
        work.trimFrames.stop()
    }

    /// Whether an edge of a clip is being dragged right now, so the clips are drawn as the trim would
    /// leave them and not as the project has them.
    var isTrimmingClip: Bool {
        clipWork.trim != nil
    }

    /// Called by `showClips` with the project it was asked to draw. While an edge is
    /// dragged, the answer is that project with the clip trimmed as the drag has it so far,
    /// so every drawing of the clips during the drag shows the same thing, whoever asked
    /// for it. When the clip is gone or a take has started, the drag ends here.
    func projectShownDuringTrim(_ project: Project) -> Project {
        guard let trim = clipWork.trim else { return project }
        guard takeStatus.phase == nil, let shown = trim.shown(in: project) else {
            // The rest of the drag is not listened to.
            clipWork.trimGivenUp = clipWork.trimReport
            forgetClipTrim()
            return project
        }
        return shown
    }

    /// Called by `showClips` with the rows it is about to draw: the clip whose edge is
    /// dragged has that edge lit, and the snap line is handed back. Nil when no edge is dragged.
    func showClipTrim(in rows: inout [TrackRow]) -> TrimmedClip? {
        guard let trim = clipWork.trim else { return nil }
        for row in rows.indices {
            if let index = rows[row].clips.firstIndex(where: { $0.id == trim.clipID }) {
                rows[row].clips[index].trimmedEdge = trim.edge
            }
        }
        return TrimmedClip(trackID: trim.trackID, snap: trim.snap)
    }
}

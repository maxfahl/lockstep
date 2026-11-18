import AppKit
import LockstepCore
import LockstepUI
import QuartzCore

// Moving clips with the pointer, and naming them. It is part of `ClipEditingModel` and lives in a file of its own
// so the part's main file stays readable. What it keeps between two calls is in
// `ClipEditingModel.clipWork`.
//
// Dragging: the window reports a drag that started on a clip's bar (`clipBarDragged`),
// on every move and when the button is let go. `ClipDrag` works out where the clip would
// land, and `showClips` draws it there: lifted, with a faint mark at its recorded place
// (`showClipDrag`). Nothing in the project changes until the clip is let go. Then the
// move is made as one edit, "Move Clip". Escape gives the drag up.
//
// With Option held when the drag starts, the drag makes copies: the clips stay, copies of
// their shown takes go where the clips would have gone, the pointer is the system's copy
// cursor, and letting go makes the copies as one edit, "Copy Clip"
// (`ProjectCopies.swift`). Pressing or letting go of Option during the drag changes nothing.
//
// Snapping: whether a dragged clip snaps, and how near it must come, are settings of the
// app (`editing.snapping`, `editing.snapDistancePoints`), not of the project. Edit >
// Snapping and the button in the bar switch it (`AppModel.toggleSnapping`). Holding Command turns it
// the other way for as long as it is held (`snapTolerance` in `TimelineViewModel`, `SnapKeyWatch`).
//
// Naming: Clip > Rename Clip, the same line in a clip's right-click menu and a
// double-click on a clip's bar put a text field in the bar (`startRenamingClip`). While
// the name is typed, `clipWork.renamedClipID` says which clip it is. The field reports
// when the typing is over (`endRenamingClip`), and the name is given as one edit,
// "Rename Clip". An empty name takes the name away.
extension ClipEditingModel {
    // MARK: Dragging a clip

    /// A clip is being dragged by its bar, or was just let go.
    func clipBarDragged(_ report: ClipBarDrag) {
        let work = clipWork
        if let givenUp = work.givenUp {
            if givenUp.isSameDrag(as: report) {
                if report.isFinished {
                    work.givenUp = nil
                }
                return
            }
            work.givenUp = nil
        }
        // The end of the last drag was never reported, and this is another one.
        if work.drag != nil, let last = work.lastReport, !last.isSameDrag(as: report) {
            forgetClipDrag()
        }
        if work.drag == nil {
            guard let drag = startClipDrag(report) else {
                if !report.isFinished {
                    work.givenUp = report
                }
                return
            }
            work.drag = drag
            if drag.copies {
                NSCursor.dragCopy.push()
            }
            work.lastFrameAt = nil
            work.escape.onEscape = { [weak self] in self?.giveUpClipDrag() }
            work.escape.start()
            work.frames.onFrame = { [weak self] in self?.clipDragFrame() }
            work.frames.start()
        }
        work.lastReport = report
        guard report.isFinished else {
            followClipDrag()
            return
        }
        // Where the pointer is at the very end counts, then the clip is put down.
        followClipDrag(showing: false)
        timeEdit(work.drag?.copies == true ? "Drop of copied clips" : "Drop of moved clips") { dropClip() }
    }

    /// The first report of a drag: the clip that was grabbed is selected, and with it the
    /// track it is on. Nil when nothing may be dragged right now.
    private func startClipDrag(_ report: ClipBarDrag) -> ClipDrag? {
        // A move is an edit, and nothing is edited while a take is going.
        // While a name is typed its bar is a text field, and a drag there selects text.
        guard FeatureSet.built.contains(.moveClips), takeStatus.phase == nil, loadedSounds.song != nil, clipWork.renamedClipID == nil,
              store.project.track(report.trackID) != nil
        else { return nil }
        // A clip that is grabbed while other clips are selected moves alone and becomes
        // the selected one. A clip that is one of the selected clips takes them along.
        let selected = selection.clipIDs.contains(report.clipID) ? selection.clipIDs : [report.clipID]
        guard let drag = ClipDrag(
            grabbing: report.clipID,
            selected: selected,
            grabbedAt: report.startSeconds,
            in: store.project,
            playhead: playhead.seconds,
            snapTo: settings.snapChoices,
            copying: NSEvent.modifierFlags.contains(.option)
        ) else { return nil }
        tracks.stopRenamingTrack()
        selection.clipIDs = selected
        selection.trackID = report.trackID
        return drag
    }

    /// Works out where the dragged clip is now, from where the pointer is and from the
    /// timeline as it is at this moment, and draws it there.
    func followClipDrag(showing: Bool = true) {
        let work = clipWork
        guard var drag = work.drag, let report = work.lastReport else { return }
        let locksTime = NSEvent.modifierFlags.contains(.shift)
        work.locksTime = locksTime
        drag.follow(
            pointerSeconds: timelineView.scale.seconds(forX: Double(report.x)),
            rowsDown: report.rowsDown,
            locksTime: locksTime,
            snapTolerance: timelineView.snapTolerance
        )
        work.drag = drag
        // The window may have set its own pointer meanwhile.
        if drag.copies {
            NSCursor.dragCopy.set()
        }
        if showing {
            showClips(store.project)
        }
    }

    /// Once per display frame while a clip is dragged. With the pointer near the left or
    /// the right edge of the timeline, the timeline scrolls that way, faster the further
    /// out the pointer is. Pressing or letting go of Shift is noticed here too, because
    /// neither moves the pointer.
    private func clipDragFrame() {
        let work = clipWork
        let now = CACurrentMediaTime()
        // A frame that came late does not make the timeline jump.
        let elapsed = min(now - (work.lastFrameAt ?? now), 0.1)
        work.lastFrameAt = now
        guard work.drag != nil, let report = work.lastReport else { return }

        let locksTime = NSEvent.modifierFlags.contains(.shift)
        var hasChanged = locksTime != work.locksTime
        // With Shift held the clip keeps its time, so there is nowhere to scroll to.
        if !locksTime, timelineView.scrollTimeline(towardPointerAt: Double(report.x), during: elapsed) {
            hasChanged = true
        }
        if hasChanged {
            followClipDrag()
        }
    }

    /// The dragged clip was let go: the move is made, as one step that can be undone. A
    /// clip let go where it was grabbed makes no step. `-timeEdits` calls it too, with a drag it has
    /// made up, which is why it is not private.
    func dropClip() {
        guard let drag = clipWork.drag else { return }
        forgetClipDrag()
        let ids = drag.selected
        // Asked of the project as it is now. It is the project the drag started with,
        // unless something else changed it meanwhile.
        let move = store.project.allowedMove(
            of: ids,
            bySamples: drag.move.samples,
            trackSteps: drag.move.trackSteps
        )
        guard takeStatus.phase == nil, !move.isNothing else {
            showClips(store.project)
            return
        }
        if drag.copies {
            dropCopies(of: drag, by: move)
            return
        }
        // A clip dropped on the start of another becomes a take of it. Whatever else it is dropped on
        // gives way, in the same step, and the words of a clip that gave way are for more sound than
        // it now plays.
        var changed = store.project
        changed.moveClips(ids, bySamples: move.samples, trackSteps: move.trackSteps, peaks: correction.voice.peaks, voices: correction.voice.heard)
        let cut = words.clearWordsOfCutClips(in: &changed)
        store.edit(ids.count == 1 ? "Move Clip" : "Move Clips") { $0 = changed }
        words.writeOutWords(ofCutClips: cut)
        // The grabbed clip stays selected, and its new track is the selected track.
        let grabbedID = drag.grabbedID
        if let landedOn = store.project.tracks.first(where: { track in track.clips.contains { $0.id == grabbedID } }) {
            selection.trackID = landedOn.id
        }
        // While the song plays, the clip is heard at its new place at once.
        followClips(store.project)
    }

    /// A drag with Option held was let go: copies of the clips' shown takes are made where
    /// the clips would have gone, as one step that can be undone, and what they cover gives
    /// way. The copies are selected, and the track the grabbed one landed on.
    private func dropCopies(of drag: ClipDrag, by move: ClipMove) {
        var changed = store.project
        let made = changed.duplicateClips(drag.selected, by: move, newIDs: drag.copyIDs, peaks: correction.voice.peaks, voices: correction.voice.heard)
        guard !made.isEmpty else {
            showClips(store.project)
            return
        }
        let cut = words.clearWordsOfCutClips(in: &changed, copies: made)
        store.edit(made.count == 1 ? "Copy Clip" : "Copy Clips") { $0 = changed }
        words.writeOutWords(ofCutClips: cut)
        selection.clipIDs = Set(made.map(\.id).filter { store.project.clip($0) != nil })
        if let grabbedCopy = drag.copyIDs[drag.grabbedID],
           let landedOn = store.project.tracks.first(where: { track in track.clips.contains { $0.id == grabbedCopy } }) {
            selection.trackID = landedOn.id
        }
        followClips(store.project)
    }

    /// Escape during a drag: the clip goes back to where it was, and nothing is changed.
    /// The button is still down, so the rest of this drag is not listened to.
    private func giveUpClipDrag() {
        guard clipWork.drag != nil else { return }
        clipWork.givenUp = clipWork.lastReport
        forgetClipDrag()
        showClips(store.project)
    }

    /// Ends the drag without moving anything and without drawing.
    private func forgetClipDrag() {
        let work = clipWork
        if work.drag?.copies == true {
            NSCursor.pop()
        }
        work.drag = nil
        work.lastReport = nil
        work.escape.stop()
        work.frames.stop()
    }

    /// Called by `showClips` with the rows as they are when nothing is dragged. While a
    /// clip is dragged, it is taken out of its row here and handed back as the lifted
    /// clip the window draws above the rows. Nil when no clip is dragged.
    ///
    /// Every drawing of the clips goes through `showClips`, so whatever else redraws them
    /// during a drag (a take starting, an undo) keeps the drag's picture right, or ends
    /// the drag when the clip is gone.
    func showClipDrag(in rows: inout [TrackRow]) -> MovedClip? {
        guard let drag = clipWork.drag else { return nil }
        guard takeStatus.phase == nil,
              let box = rows.lazy.flatMap(\.clips).first(where: { $0.id == drag.grabbedID })
        else {
            // The rest of the drag is not listened to.
            clipWork.givenUp = clipWork.lastReport
            forgetClipDrag()
            return nil
        }
        rows = drag.rows(showing: rows)
        return drag.picture(of: box)
    }

    // MARK: Naming a clip

    /// Rename Clip: the name of the selected clip can be typed.
    func renameSelectedClip() {
        guard selection.clipIDs.count == 1, let clipID = selection.clipIDs.first else { return }
        startRenamingClip(clipID)
    }

    /// Puts a text field in a clip's bar, with the clip's name in it. The typing ends with
    /// `endRenamingClip`, which the field calls. The clip is selected, with its track, so
    /// it is clear which clip the name is for.
    func startRenamingClip(_ clipID: UUID) {
        // A new name is an edit, and nothing is edited while a take is going. Only a clip
        // that is drawn has a bar to type in: of several takes that is the active one.
        guard FeatureSet.built.contains(.moveClips), takeStatus.phase == nil, clipWork.drag == nil,
              clipWork.renamedClipID != clipID,
              let clip = store.project.clip(clipID), clip.isActiveTake,
              let track = store.project.tracks.first(where: { track in track.clips.contains { $0.id == clipID } })
        else { return }
        // One name is typed at a time.
        tracks.stopRenamingTrack()
        clipWork.renamedClipID = clipID
        if selection.clipIDs != [clipID] {
            selection.clipIDs = [clipID]
        }
        selection.trackID = track.id
        showClips(store.project)
    }

    /// Takes the text field out of the bar again. The field reports the name that was
    /// typed as it goes (`endRenamingClip`), so nothing typed is lost.
    func stopRenamingClip() {
        guard clipWork.renamedClipID != nil else { return }
        clipWork.renamedClipID = nil
        showClips(store.project)
    }

    /// The typing of a clip's name is over. With a name (Return, or a click elsewhere) the
    /// clip gets it, as one step that can be undone. An empty name takes the clip's name
    /// away, so its bar shows the clip's words again, or nothing. The name the clip
    /// already has, and Escape (`name` is nil), leave the clip as it was and make no step.
    func endRenamingClip(_ clipID: UUID, as name: String?) {
        if let name, takeStatus.phase == nil {
            var changed = store.project
            if changed.renameClip(clipID, to: name) {
                store.edit("Rename Clip") { $0 = changed }
            }
        }
        if clipWork.renamedClipID == clipID {
            clipWork.renamedClipID = nil
        }
        showClips(store.project)
    }

    /// Called by `showClips` with the rows it is about to draw: the clip whose name is
    /// being typed gets its text field. No name is typed during a take, and none on a
    /// clip that is gone or has become a take that waits behind another.
    func showClipBeingRenamed(in rows: inout [TrackRow]) {
        guard let renamed = clipWork.renamedClipID else { return }
        if takeStatus.phase == nil {
            for row in rows.indices {
                if let index = rows[row].clips.firstIndex(where: { $0.id == renamed }) {
                    rows[row].clips[index].isBeingRenamed = true
                    return
                }
            }
        }
        clipWork.renamedClipID = nil
    }
}

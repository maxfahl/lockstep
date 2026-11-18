import Foundation
import LockstepCore

// Copy and Paste of clips: Edit > Copy and Edit > Paste (Command+C and Command+V) while no
// text is typed. It is part of `ClipEditingModel` and lives in a file of its own so the part's main
// file stays readable. The rules are in `ProjectCopies.swift` in LockstepCore, where they are
// tested. What was copied is `ClipEditingModel.copiedClips`, kept for as long as the app runs.
//
// A drag with Option held makes copies as well. It is part of the drag of clips, in
// `ClipEditingModel+Moves.swift`.
//
// In an agent's run, `-pasteClip` copies the first clip of the first track and pastes it at
// the playhead on that track, through these same functions, and says on standard error where
// the copy landed.
extension ClipEditingModel {
    /// Whether Copy has clips to copy.
    var canCopySelectedClips: Bool {
        loadedSounds.song != nil && !loadedSounds.isOpening && !store.project.clips(selection.clipIDs).isEmpty
    }

    /// Whether Paste has copies to put somewhere: copies of recordings the open project has.
    var canPasteClips: Bool {
        loadedSounds.song != nil && !loadedSounds.isOpening && pasteTrackID != nil && store.project.canPaste(copiedClips)
    }

    /// The track Paste puts the copies on: the selected track, or the first track.
    private var pasteTrackID: UUID? {
        if let selectedTrackID = selection.trackID, store.project.track(selectedTrackID) != nil {
            return selectedTrackID
        }
        return store.project.tracks.first?.id
    }

    /// Copy: the shown takes of the selected clips' lines are kept, as they are now, for Paste.
    /// Nothing in the project changes.
    func copySelectedClips() {
        let copies = store.project.copyClips(selection.clipIDs)
        guard !copies.isEmpty else { return }
        copiedClips = copies
    }

    /// Paste: copies of the copied clips go on the selected track, the first one's start at the
    /// playhead, as one step that can be undone. What they cover gives way, and the copies are
    /// selected.
    func pasteCopiedClips() {
        guard takeStatus.phase == nil, let trackID = pasteTrackID else { return }
        let sample = Int((playhead.seconds * Lockstep.sampleRate).rounded())
        var changed = store.project
        let made = changed.paste(copiedClips, onTrack: trackID, atSample: sample, peaks: correction.voice.peaks, voices: correction.voice.heard)
        guard !made.isEmpty else { return }
        // A clip that gave way plays less than its words are for. The copies play what they did.
        let cut = words.clearWordsOfCutClips(in: &changed, copies: made)
        store.edit(made.count == 1 ? "Paste Clip" : "Paste Clips") { $0 = changed }
        words.writeOutWords(ofCutClips: cut)
        if selection.markedStretch != nil {
            selection.markedStretch = nil
        }
        selection.clipIDs = Set(made.map(\.id).filter { store.project.clip($0) != nil })
        // While the song plays, the copies are heard at once.
        followClips(store.project)
    }

    // MARK: An agent's run

    /// Does what `-pasteClip` asks once the first project is open, the takes given with `-addTake`
    /// are in it and the playhead is where `-playhead` put it: selects the first clip of the first
    /// track, copies it and pastes it, as Edit > Copy and Edit > Paste do, and says on standard
    /// error where the copy is and how many clips the track holds afterwards.
    func pasteLaunchClip() {
        guard !launchPasteTaken, LaunchOptions.current.pastesClip else { return }
        launchPasteTaken = true
        Task {
            await takeStatus.ended()
            // The playhead is moved by a task of its own once the takes are in.
            try? await Task.sleep(for: .milliseconds(500))
            let refusal = "could not paste the first clip: "
            guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil else { return Self.tellAgentAboutCopies(refusal + "the song is not ready") }
            guard let track = store.project.tracks.first,
                  let clip = track.clips.first(where: \.isActiveTake)
            else { return Self.tellAgentAboutCopies(refusal + "the first track has no clip") }
            selection.trackID = track.id
            selection.clipIDs = [clip.id]
            perform(.copyClips)
            perform(.pasteClips)
            let pasted = store.project.clips(selection.clipIDs)
            guard let copy = pasted.first, !selection.clipIDs.contains(clip.id),
                  let start = store.project.start(of: copy), let end = store.project.end(of: copy)
            else { return Self.tellAgentAboutCopies(refusal + "Paste made no copy") }
            let count = store.project.track(track.id)?.clips.count ?? 0
            Self.tellAgentAboutCopies(
                "pasted a copy of the first clip on \"\(track.name)\" from "
                    + String(format: "%.3f s to %.3f s", start, end)
                    + ", now \(count) \(count == 1 ? "clip" : "clips") on the track (undo: \(store.undoTitle ?? "none"))"
            )
        }
    }

    private static func tellAgentAboutCopies(_ line: String) {
        FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
    }
}

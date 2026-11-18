import AppKit
import Foundation
import LockstepCore

// A fixed list of edits, timed, in an agent's run: `-timeEdits`. It is part of `ClipEditingModel`, as
// `-deleteClip` is, and uses the same stopwatch (`timed`, in `ClipEditingModel+EditTiming.swift`), so every
// line on standard error reads like a line of `-deleteClip`.
//
// It acts on up to five shown clips on each of up to six tracks, from the first quarter of the song: thirty
// clips on six tracks in the project of `-bigProject`. The list, each edit through the code the pointer and
// the keys use:
//
// 1. a click on one clip (`selectClip`),
// 2. selecting all the chosen clips, as the last Shift-click of thirty does,
// 3. Delete, 4. Undo and 5. Redo of them,
// 6. the drop of a drag that moves them one bar later (`dropClip`),
// 7. Copy and Paste at the playhead, which stands one bar after the first of them,
// 8. Split at Playhead, on the longest of them,
// 9. Strength to 50 % under Correction, or to 80 % for clips that are at 50 %.
//
// The list is gone through three times with the timeline zoomed so a quarter of the song shows, then three
// times with the whole song in the window. The third time of each, the song plays.
//
// Between two edits the project is put back as it was, with Undo, which is not timed. Before each edit it
// waits until no tightened sound is being made, and then leaves the window alone for a moment, so what is
// timed is the edit alone.
extension ClipEditingModel {
    /// How many times the list of edits is gone through at each zoom. The last time, the song plays.
    private static let editRounds = 3

    /// Makes the edits `-timeEdits` asks for, once the first project is open, the takes given with
    /// `-addTake` are in it, what `-tighten` and `-strength` asked for is done, and `-bigProject` has built
    /// its project.
    func timeLaunchEdits() {
        guard !launchTimeEditsTaken, LaunchOptions.current.timesEdits else { return }
        launchTimeEditsTaken = true
        Task {
            await takeStatus.ended()
            await launchTightened()
            await bigProjectLaunch?.value
            await timeEditsForAgent()
        }
    }

    /// A clip the edits are made on, with its track and where it lies in the song.
    private struct ChosenClip {
        var id: UUID
        var trackID: UUID
        var start: Double
        var end: Double
    }

    /// Up to five shown clips on each of up to six tracks. In a project with more than eight tracks that
    /// have clips, the first two are left out, so the clips are not all at the top of the window. Clips that
    /// start in the first quarter of the song are taken first, because that quarter is what the window
    /// shows when it is zoomed in.
    private func clipsToEdit() -> [ChosenClip] {
        let project = store.project
        let kept = project.keptSeconds
        let quarterEnd = kept.lowerBound + (kept.upperBound - kept.lowerBound) / 4
        let withClips = project.tracks.filter { $0.clips.contains(where: \.isActiveTake) }
        var chosen: [ChosenClip] = []
        for track in withClips.dropFirst(withClips.count > 8 ? 2 : 0).prefix(6) {
            let shown = track.clips.filter(\.isActiveTake).compactMap { clip -> ChosenClip? in
                guard let start = project.start(of: clip), let end = project.end(of: clip) else { return nil }
                return ChosenClip(id: clip.id, trackID: track.id, start: start, end: end)
            }.sorted { $0.start < $1.start }
            let inQuarter = shown.filter { $0.start < quarterEnd }
            chosen += (inQuarter.count >= 5 ? inQuarter : shown).prefix(5)
        }
        return chosen
    }

    private func timeEditsForAgent() async {
        let refusal = "could not time the edits: "
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil else {
            return Self.tellAgentAboutEdit(refusal + "the song is not ready")
        }
        let chosen = clipsToEdit()
        guard let first = chosen.first, let longest = chosen.max(by: { $0.end - $0.start < $1.end - $1.start }) else {
            return Self.tellAgentAboutEdit(refusal + "the project has no clip")
        }
        let inUse = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Measuring how fast edits are"
        )
        defer { ProcessInfo.processInfo.endActivity(inUse) }
        let ids = Set(chosen.map(\.id))
        let trackCount = Set(chosen.map(\.trackID)).count
        let clips = "\(ids.count) \(ids.count == 1 ? "clip" : "clips")"
        let onTracks = "\(clips) on \(trackCount) \(trackCount == 1 ? "track" : "tracks")"
        // One bar at the tempo the first clip is in, or two seconds where the song has no beats.
        let bar = store.project.grid?.tempo(at: first.start).map { 4 * 60 / $0 } ?? 2
        let songStart = store.project.keptSeconds.lowerBound

        for zoom in ["a quarter of the song", "the whole song"] {
            // The whole song first, then four times closer around the playhead at the song's start.
            _ = seek(songStart)
            perform(.zoomToFit)
            try? await Task.sleep(for: .seconds(1))
            if zoom == "a quarter of the song" {
                timelineView.zoom(by: 4)
                try? await Task.sleep(for: .seconds(1.5))
            }
            let isVisible = NSApplication.shared.windows.contains { $0.occlusionState.contains(.visible) }
            Self.tellAgentAboutEdit(
                "will time edits of \(onTracks), with \(zoom) in the window "
                    + String(format: "(%.1f points a second, ", timelineView.scale.pointsPerSecond)
                    + "window \(isVisible ? "visible" : "hidden")), \(Self.editRounds) times. \(projectSize)"
            )
            for round in 1...Self.editRounds {
                if round == Self.editRounds, round > 1 {
                    _ = seek(songStart)
                    perform(.playStop)
                }
                let isPlaying = windowState.content.isPlaying
                let count = "(\(round) of \(Self.editRounds)\(isPlaying ? ", while the song plays" : ""))"

                // 1. As a click on the clip, with none selected before.
                select([], on: first.trackID)
                await time("selected one clip", count, "selected") { selectClip(on: first.trackID, at: first.start) }

                // 2. As the Shift-click that makes them thirty: the selection is set and the clips are shown.
                select([], on: first.trackID)
                await time("selected \(onTracks)", count, "selected") {
                    selection.clipIDs = ids
                    selection.trackID = first.trackID
                    showClips(store.project)
                }

                // 3 to 5. As the Delete key, Edit > Undo and Edit > Redo.
                await time("deleted \(onTracks)", count, "Delete done") { perform(.delete) }
                await time("brought \(clips) back with Undo", count, "Undo done") { store.undo() }
                await time("deleted \(clips) again with Redo", count, "Redo done") { store.redo() }
                store.undo()

                // 6. As letting go of a drag that took the clips one bar to the right.
                select(ids, on: first.trackID)
                var drag = ClipDrag(
                    grabbing: first.id, selected: ids, grabbedAt: first.start, in: store.project,
                    playhead: playhead.seconds, snapTo: settings.snapChoices, copying: false
                )
                drag?.follow(pointerSeconds: first.start + bar, rowsDown: 0, locksTime: false, snapTolerance: nil)
                await time(String(format: "moved \(onTracks) by %.3f s", bar), count, "drop done") {
                    clipWork.drag = drag
                    dropClip()
                }

                // 7. As Edit > Copy and Edit > Paste, the copies one bar after the clips, on their tracks.
                select(ids, on: first.trackID)
                _ = seek(first.start + bar)
                await time("copied and pasted \(onTracks) at the playhead", count, "Copy and Paste done") {
                    perform(.copyClips)
                    perform(.pasteClips)
                }

                // 8. As Edit > Split at Playhead, with the playhead inside the longest clip. While the song
                // plays, the playhead moves on for as long as the window is left alone before the edit.
                select([longest.id], on: longest.trackID)
                let middle = (longest.start + longest.end) / 2
                _ = seek(isPlaying ? max(longest.start, middle - 1.7) : middle)
                if await !time("split a clip at the playhead", count, "Split done", { perform(.splitAtPlayhead) }) {
                    Self.tellAgentAboutEdit("the split \(count) cut nothing: the playhead was not inside the clip")
                }

                // 9. As letting go of the slider Strength.
                select(ids, on: first.trackID)
                let isAtHalf = store.project.clips(ids).allSatisfy { $0.strength == 0.5 }
                await time("set Strength to \(isAtHalf ? 80 : 50) % on \(onTracks)", count, "Strength done") {
                    correction.setSelectedClipsStrength(isAtHalf ? 0.8 : 0.5)
                }
            }
            if windowState.content.isPlaying {
                perform(.playStop)
            }
        }
        let isVisible = NSApplication.shared.windows.contains { $0.occlusionState.contains(.visible) }
        Self.tellAgentAboutEdit("timed the edits (window \(isVisible ? "visible" : "hidden") at the end)")
    }

    /// Selects clips and their track and shows them, without timing it.
    private func select(_ ids: Set<UUID>, on trackID: UUID) {
        selection.clipIDs = ids
        selection.trackID = trackID
        showClips(store.project)
    }

    /// Makes one edit of the list and says on standard error how long each step of it took. Afterwards the
    /// project is put back as it was before the edit, with Undo, when the edit changed it and is not one of
    /// Delete, Undo and Redo, which follow each other.
    ///
    /// - Returns: whether the edit changed the project.
    @discardableResult
    private func time(_ what: String, _ count: String, _ doneStep: String, _ edit: () -> Void) async -> Bool {
        _ = await soundsSettle(within: 120)
        let before = store.project
        let line = await timed(doneStep, edit)
        Self.tellAgentAboutEdit("\(what) \(count): " + line)
        let hasChanged = store.project != before
        let isOwnStep = ["Delete done", "Undo done", "Redo done"].contains(doneStep)
        if !isOwnStep, hasChanged {
            store.undo()
        }
        return hasChanged
    }
}

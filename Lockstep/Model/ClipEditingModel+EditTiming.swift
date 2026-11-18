import AppKit
import Foundation
import LockstepCore
import os

/// How fast an edit is, measured by the app itself. On 13 November 2026 Max saw a selected clip take about a
/// second to go after he pressed Delete. An agent's run could not show that second: there the clip was gone
/// from the window in about a thirtieth of a second. So there are two ways to measure.
///
/// **In every run, Max's own included:** every edit that shows the clips again writes one line to the Mac's
/// log (`timeEdit`): every command of the menus and the keys, a click and a Shift-click on a clip, the drop
/// of a move and of an Option-drag, Undo, Redo, a track's mute button, and Strength and Stretch under
/// Correction. It counts from the moment the key went down, when a key asked for it, so it also holds what
/// an agent's run cannot have: how long the key waited for the main thread, and how long the menu bar took
/// to choose the command. The line ends with how big the project is, so Max's real size can be read from
/// his log without opening his folder. Read the lines with
///
///     log show --last 1h --info --predicate 'subsystem == "se.maxfahl.lockstep" AND category == "EditTiming"'
///
/// **In an agent's run:** `-deleteClip` selects the first clip, deletes it and brings it back with Undo,
/// three times, and says the same on standard error (`deleteLaunchClip`). `-timeEdits` does it for a list
/// of edits (`ClipEditingModel+TimeEdits.swift`). An agent cannot select a clip and cannot press a key.
///
/// What a line holds, in milliseconds from the start (the key press, or in an agent's run the call):
/// - "key taken up" and "command reached": only after a real key press. The first is the wait for the
///   main thread, the rest of the second is the menu bar.
/// - "project changed": the store has the project without the clip, and the undo step. Delete only.
/// - "tightened sounds gone through" and "clips handed to the window": the two halves of `followClips`.
/// - Between those two, the steps of `showClips`: "rows made", "feels shown", "markers shown", "words
///   shown", "rows handed to the window", "takes shown" and "Send panel followed". An edit that shows the
///   clips more than once has them more than once.
/// - "done": the command has returned. In an agent's run it is named after the edit, as in "Delete done".
/// - "window drawn": the main thread has come to rest for the first time, so the window has been laid out,
///   drawn and handed to the screen. This is what Max sees.
/// - "player has the clips": the player has taken the clips over, which is when the clip stops being heard.
/// - "later pass for remade sounds started" and "later pass done", with the steps of `followClips` between
///   them: an edit that gives a clip another sound has that sound made away from the main thread, and
///   when it is done all the clips are handed to the window and the player once more (`timeLaterPass`).
///   Only the passes of the second after the window was drawn are in the line.
///
/// After those, the line says how long the main thread worked in the second that followed, and the longest
/// stretch of it: work there is the window standing still after the edit.
extension ClipEditingModel {
    private static let editLog = Logger(subsystem: "se.maxfahl.lockstep", category: "EditTiming")

    // MARK: Every run

    /// Makes an edit and times it, from the key press that asked for it when there is one. One line about
    /// it goes to the Mac's log, once the window has been drawn and a second more has passed. Nothing is
    /// written to standard error, so what an agent's run prints stays as it was.
    ///
    /// An edit that is made inside one that is being timed is part of that one. An edit that neither showed
    /// nor handed over the clips (a zoom, Play, a click that selected nothing new) leaves no line.
    ///
    ///     timeEdit("Paste Clips") { pasteCopiedClips() }
    func timeEdit(_ what: String, _ edit: () -> Void) {
        guard editTiming == nil else { return edit() }
        let size = projectSize
        let timing: EditTiming
        if let key = KeyPressWatch.app.started() {
            timing = EditTiming(startedAgo: key.pressedAgo)
            timing.mark("key taken up", ago: key.takenUpAgo)
        } else {
            timing = EditTiming()
        }
        timing.mark("command reached")
        let before = timing.markCount
        editTiming = timing
        edit()
        editTiming = nil
        guard timing.markCount > before else { return timing.giveUp() }
        timing.mark("done")
        reportedTiming = timing
        Task {
            let line = await timing.report { await self.player.hasDoneItsOrders() }
            Self.editLog.notice("\(what, privacy: .public): \(line, privacy: .public). \(size, privacy: .public)")
        }
    }

    /// How big the project is right now, as every line in the log ends: the tracks, the clips that are
    /// shown, all the clips with the takes that wait, the clips with a timing fix (waiting takes counted),
    /// and the selected clips.
    var projectSize: String {
        var shown = 0
        var all = 0
        var fixed = 0
        for track in store.project.tracks {
            for clip in track.clips {
                all += 1
                if clip.isActiveTake { shown += 1 }
                if clip.hasTimingFix { fixed += 1 }
            }
        }
        return "Project: \(store.project.tracks.count) tracks, \(shown) clips shown of \(all) with waiting takes, "
            + "\(fixed) with a timing fix, \(selection.clipIDs.count) selected"
    }

    /// Runs a handing over of the clips that a remade tightened sound asked for (`followTighteningSoon`,
    /// correction). While the line of the edit before it is still being put together, the pass is noted in
    /// that line with its own steps: it is the window standing still again after the edit.
    func timeLaterPass(_ pass: () -> Void) {
        guard editTiming == nil, let timing = reportedTiming else { return pass() }
        timing.mark("later pass for remade sounds started")
        editTiming = timing
        pass()
        editTiming = nil
        timing.mark("later pass done")
    }

    // MARK: An agent's run

    /// How long the window is left alone before each thing that is timed, so nothing from opening the
    /// project, or from the step before, is still going on.
    private static let quietBeforeEdit = Duration.seconds(1.5)

    /// How many times the clip is deleted. Between two of them Undo brings it back.
    private static let deleteCount = 3

    /// Deletes the first clip of the first track, once the first project is open, the takes given with
    /// `-addTake` are in it and what `-tighten` and `-strength` asked for is done, and says on standard error
    /// how long it took. Of several takes of a line, the first clip is the one that is drawn.
    func deleteLaunchClip() {
        guard !launchDeleteTaken, LaunchOptions.current.deletesClip else { return }
        launchDeleteTaken = true
        Task {
            await takeStatus.ended()
            await launchTightened()
            // With `-bigProject` the clip is deleted from the big project.
            await bigProjectLaunch?.value
            await deleteFirstClipForAgent()
        }
    }

    /// Does what `-deleteClip` asks, and says how it went: one line on standard error for each time the clip
    /// was selected, deleted or brought back, or one that says why it was not.
    ///
    /// It is done three times, because one number says little on a Mac that is busy with other things. The
    /// last time, the song plays: the window then moves the playhead for every picture the screen shows, and
    /// the player takes the clips over while it plays. While it measures, the app tells the system that it is
    /// in use, so an app that was started behind the other windows is not slowed down the way a resting app is.
    private func deleteFirstClipForAgent() async {
        let refusal = "could not delete the first clip: "
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil else { return Self.tellAgentAboutEdit(refusal + "the song is not ready") }
        guard let track = store.project.tracks.first,
              let clip = track.clips.first(where: \.isActiveTake),
              let start = store.project.start(of: clip)
        else { return Self.tellAgentAboutEdit(refusal + "the first track has no clip") }
        let inUse = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Measuring how fast Delete is"
        )
        defer { ProcessInfo.processInfo.endActivity(inUse) }
        let clipCount = store.project.tracks.reduce(0) { $0 + $1.clips.count }
        let tightened = store.project.tracks.filter { $0.clips.contains(where: \.hasTimingFix) }.count
        let isVisible = NSApplication.shared.windows.contains { $0.occlusionState.contains(.visible) }
        Self.tellAgentAboutEdit(
            "will delete the first clip of \(clipCount) clips on "
                + "\(store.project.tracks.count) \(store.project.tracks.count == 1 ? "track" : "tracks") "
                + "(\(tightened) with a timing fix, window \(isVisible ? "visible" : "hidden")) \(Self.deleteCount) times"
        )
        for round in 1...Self.deleteCount {
            if round == Self.deleteCount, round > 1 {
                perform(.playStop)
            }
            let count = "(\(round) of \(Self.deleteCount)\(windowState.content.isPlaying ? ", while the song plays" : ""))"
            // As a click on the clip.
            let selecting = await timed("selected") { selectClip(on: track.id, at: start) }
            guard selection.clipIDs == [clip.id] else { return Self.tellAgentAboutEdit(refusal + "it could not be selected") }
            Self.tellAgentAboutEdit("selected the clip \(count): " + selecting)
            // As the Delete key.
            let deleting = await timed("Delete done") { perform(.delete) }
            guard store.project.clip(clip.id) == nil else {
                return Self.tellAgentAboutEdit(refusal + "Delete did not take it away")
            }
            Self.tellAgentAboutEdit("deleted the clip \(count): " + deleting)
            if round < Self.deleteCount {
                // As Edit > Undo.
                let undoing = await timed("Undo done") { store.undo() }
                Self.tellAgentAboutEdit("brought the clip back with Undo \(count): " + undoing)
            }
        }
        if windowState.content.isPlaying {
            perform(.playStop)
        }
    }

    /// Does one thing to the project or the selection, after leaving the window alone for a moment, and
    /// gives how long each step of it took (`EditTiming.report`).
    func timed(_ doneStep: String, _ edit: () -> Void) async -> String {
        try? await Task.sleep(for: Self.quietBeforeEdit)
        await player.hasDoneItsOrders()
        let timing = EditTiming()
        editTiming = timing
        edit()
        timing.mark(doneStep)
        editTiming = nil
        reportedTiming = timing
        return await timing.report { await self.player.hasDoneItsOrders() }
    }

    /// One line on standard error, for the agent that started Lockstep. It goes to the Mac's log as well,
    /// where the lines of Max's own run are.
    static func tellAgentAboutEdit(_ line: String) {
        FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
        editLog.notice("\(line, privacy: .public)")
    }
}

import AppKit
import Foundation
import LockstepCore
import LockstepUI

// The drag that selects clips on several tracks, in an agent's run: `-selectRect <start>,<end>,<tracks>`.
// It is part of `ClipEditingModel`, as `-pasteClip` is. An agent cannot drag, so the drag is made up
// here and handed to `stretchDragged`, the function the window reports the real drag to: a first report on
// the first track where the drag starts, two dozen moves to where it ends that many rows down, and the
// report of the button let go at the same place. What is selected afterwards is what the pointer would have
// selected, and one line on standard error says what that is.
extension ClipEditingModel {
    /// Makes the drag `-selectRect` asks for, once the first project is open, the takes given with
    /// `-addTake` are in it, what `-tighten` and `-strength` asked for is done, and `-bigProject` has built
    /// its project.
    func selectLaunchRectangle() {
        guard !launchSelectRectTaken, let asked = LaunchOptions.current.selectRect else { return }
        launchSelectRectTaken = true
        Task {
            await takeStatus.ended()
            await launchTightened()
            await bigProjectLaunch?.value
            Self.tellAgentAboutEdit(await selectRectangleForAgent(from: asked.start, to: asked.end, tracks: asked.tracks))
        }
    }

    /// In how many moves the made-up pointer goes from where the drag starts to where it ends.
    private static let selectRectMoves = 24

    /// Does what `-selectRect` asks and gives the line that says how it went.
    private func selectRectangleForAgent(from start: Double, to end: Double, tracks: Int) async -> String {
        let refusal = "could not drag a rectangle: "
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil else {
            return refusal + "the song is not ready"
        }
        guard let first = store.project.tracks.first else { return refusal + "the project has no track" }
        // The window says where the pointer is in points from the left edge of the rows, so the drag waits
        // until the window has laid the timeline out and its zoom is known.
        for _ in 0..<40 where timelineView.scale.pointsPerSecond <= 0 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard timelineView.scale.pointsPerSecond > 0 else { return refusal + "the timeline is not laid out" }
        // As the pointer makes it: a first report in the row the drag starts in, then the way to the far
        // corner in small moves, one display frame apart, and the button let go there. Every move says
        // where the pointer is with the zoom of that moment, as the window does.
        func report(share: Double, isFinished: Bool) -> StretchDrag {
            StretchDrag(
                trackID: first.id,
                startSeconds: start,
                x: CGFloat(timelineView.scale.x(for: start + (end - start) * share)),
                rowsDown: Int((Double(tracks - 1) * share).rounded(.down)),
                isFinished: isFinished
            )
        }
        stretchDragged(report(share: 0, isFinished: false))
        for move in 1...Self.selectRectMoves {
            try? await Task.sleep(for: .milliseconds(16))
            stretchDragged(report(share: Double(move) / Double(Self.selectRectMoves), isFinished: false))
        }
        stretchDragged(report(share: 1, isFinished: true))
        let project = store.project
        let asked = String(format: "%.3f s to %.3f s", start, end)
        if let stretch = selection.markedStretch {
            let name = project.track(stretch.trackID)?.name ?? "a track that is gone"
            return "the drag from \(asked) stayed on \"\(name)\" and marked a stretch of it from "
                + String(format: "%.3f s to %.3f s", stretch.range.lowerBound, stretch.range.upperBound)
                + ", \(selection.clipIDs.count) clips selected"
        }
        // The tracks the rectangle covered, and how many of the selected clips each holds.
        let covered = project.tracks(from: first.id, rowsDown: tracks - 1)
        guard covered.count > 1 else { return refusal + "the drag from \(asked) started no stretch and no rectangle" }
        let selected = selection.clipIDs
        let counts = covered.compactMap { project.track($0) }.map { track in
            (name: track.name, count: track.clips.filter { selected.contains($0.id) }.count)
        }
        let perTrack = counts.map { "\"\($0.name)\" \($0.count)" }
        // With Shift held, clips that were selected before stay selected, wherever they are.
        let elsewhere = selected.count - counts.reduce(0) { $0 + $1.count }
        return "selected \(selected.count) \(selected.count == 1 ? "clip" : "clips") on \(covered.count) tracks "
            + "with a rectangle from \(asked): " + perTrack.joined(separator: ", ")
            + (elsewhere == 0 ? "" : ", and \(elsewhere) on other tracks")
            + (windowState.content.timeline.dragging.selectionRectangle == nil ? "" : ", the rectangle is still drawn")
    }
}

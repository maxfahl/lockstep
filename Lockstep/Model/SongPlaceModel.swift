import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

/// The song's place: a part of the app's model.
///
/// It holds the song's cut and its place on the timeline: dragging the song and its ends, and
/// keeping the loop, its in and out and the marked stretch inside what is left of the song.
///
/// Its `init` is final. It has no closures of its own, because everything it calls it is handed.
@MainActor
final class SongPlaceModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let loopState: LoopState
    private let player: Player
    private let store: ProjectStore
    private let settings: AppSettings
    private let playhead: PlayheadPosition

    // The parts it is handed, and calls directly.
    private let timelineView: TimelineViewModel
    private let click: ClickModel
    private let send: SendModel
    private let clips: ClipsModel
    private let calibration: CalibrationModel

    // MARK: What it keeps

    /// What a drag of the song, or of one of its edges, started with (`songDragged`).
    private let songDragWork = SongDragWork()

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        loopState: LoopState,
        player: Player,
        store: ProjectStore,
        settings: AppSettings,
        playhead: PlayheadPosition,
        timelineView: TimelineViewModel,
        click: ClickModel,
        send: SendModel,
        clips: ClipsModel,
        calibration: CalibrationModel
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.loopState = loopState
        self.player = player
        self.store = store
        self.settings = settings
        self.playhead = playhead
        self.timelineView = timelineView
        self.click = click
        self.send = send
        self.clips = clips
        self.calibration = calibration
    }
}

// Cutting the start or the end of the song away, and moving the song along the timeline.
//
// The song row reports a drag of one of the song's edges, or of the song itself (`SongDrag`).
// `songDragged` works out the place the drag has reached from the place it started with and
// how far the pointer has gone, lets `SongPlace` hold it inside its limits, and shows it at
// once (`showSongPlace`). When the button is let go it becomes one edit, "Trim Song" or "Move
// Song", that Undo takes back and that is saved with the project.
//
// An edge: what lies outside it is not drawn and not played, and has no beat lines and no
// click. Dragging it back brings all of that again, because the song file and the beats are
// never changed.
//
// The song: every position inside the app is song seconds, so the beats and the clips stay on
// the song. Moving it only changes which moment of the song stands at the timeline's 00:00.
// While it is dragged the timeline keeps the time it shows at its left edge, so the song, its
// beats and every clip go with the pointer together. Dragged left with its start at 00:00,
// the song goes on and its beginning passes 00:00, where it is cut away like a beginning cut
// with the edge. Dragged right from there the beginning comes back (`SongPlace.moved`).
//
// With snapping on (or off with Command held), a dragged edge catches on what is chosen in
// Snap To, the way a trimmed edge of a clip does: the lines of the grid in its unit, the
// edges of the clips and the playhead, within the snap distance on screen. A moved song
// catches with one of those places on 00:00. The recorded place is a clip's own and means nothing here.
//
// The same place can be typed in the Send to DaVinci panel as the timecode the song starts at
// (`setSongPlace`).
//
// The loop, its in and out and the marked stretch lie in what is left of the song. A cut that
// leaves part of one outside shortens it to what is left, or takes it away when nothing is
// left (`keepLoopAndStretch`). None of them is part of the project, so Undo cannot put them
// back by itself: what a cut changed is remembered here (`ShortenedByCut`), and Undo of that
// cut brings them back as they were, in the same step.

/// What a drag of the song, or of one of its edges, started with. It is kept in an object
/// that no view watches, so remembering it draws nothing again.
@MainActor
final class SongDragWork {
    /// The song's place and the timeline's zoom and scroll position when the button went
    /// down, and the places the drag catches on, made once: the beats, the clips and the
    /// choices in Snap To do not change during a drag. Nil between drags.
    var start: (place: SongPlace, scale: TimelineScale, snaps: SnapEngine)?
    /// What the window last said about the drag that is going on, so it can be followed again
    /// when Command or N turns snapping the other way without the pointer moving.
    var lastDrag: SongDrag?
    /// The place of the song the loop and the marked stretch were last held inside. Nil
    /// until a project has opened.
    var followedPlace: SongPlace?
    /// What the cuts of the open song shortened, the latest last. Undo of a cut takes its
    /// own entry off again.
    var shortened: [ShortenedByCut] = []
}

/// What a change of the song's cut did to the loop and to the marked stretch, so that Undo
/// of that change can bring them back.
struct ShortenedByCut {
    /// The song's place before the change. When the project has it again, the change was undone.
    var placeBefore: SongPlace
    /// The loop before and after, when the change shortened it or took it away (`after` nil).
    var loop: (before: LoopRegion, after: LoopRegion?)?
    /// The same for the loop's in and out.
    var inOut: (before: LoopInOut, after: LoopInOut?)?
    /// The same for the marked stretch.
    var stretch: (before: MarkedStretch, after: MarkedStretch?)?
}

extension SongPlaceModel {
    // MARK: The song's cut and its place

    /// Shows a cut and a place of the song in the window: the song row draws what is left,
    /// the timeline starts at its 00:00, and the time readout counts from there. While an
    /// edge of the song, or the song, is dragged, this is what the drag has reached, which
    /// is not in the project until the button is let go.
    func showSongPlace(_ place: SongPlace) {
        if windowState.content.timeline.songPlace != place {
            windowState.content.timeline.songPlace = place
        }
        if playhead.place != place {
            playhead.place = place
        }
    }

    /// Brings the window and the player in line with the cut of a project: when it opens,
    /// after the cut was changed, and after Undo and Redo. The player keeps only what is
    /// left of the song, a loop or a marked stretch that reaches outside it is shortened
    /// to it, and the playhead is held inside it. The click and the clips are handed over
    /// by their own functions (`followClick`, `followClips`), which lay them out for what
    /// is left.
    func followSongPlace(of project: Project) {
        showSongPlace(project.songPlace)
        let keptSamples = project.keptSamples
        player.tell { await $0.keepSong(keptSamples) }
        keepLoopAndStretch(inside: project)
        let kept = project.keptSeconds
        let held = min(max(playhead.seconds, kept.lowerBound), kept.upperBound)
        if held != playhead.seconds {
            playhead.seconds = held
            player.tell { try await $0.seek(to: held) }
        }
    }

    /// The cut or the place of the open song was changed by an edit. Everything that is laid
    /// out for what is left of the song follows: the player's song, the click, and the clips
    /// with the Resolve times the window shows for them.
    func songPlaceChanged() {
        let project = store.project
        followSongPlace(of: project)
        click.followClick(of: project)
        clips.followClips(of: project)
    }
}

extension SongPlaceModel {
    /// An edge of the song, or the song, was dragged: the pointer moved with the button
    /// down, or the button was let go.
    func songDragged(_ drag: SongDrag) {
        let work = songDragWork
        // While a take is going nothing may change the project or move the song.
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil,
              calibration.calibrationSheet == nil, send.sendSheet == nil
        else {
            if work.start != nil {
                work.start = nil
                showSongPlace(store.project.songPlace)
            }
            return
        }
        let project = store.project
        if work.start == nil {
            guard timelineView.scale.pointsPerSecond > 0 else { return }
            let choices = settings.snapChoices
            let snaps = SnapEngine(sources: choices.sources(
                forTrimmingIn: project,
                playheadAt: playhead.seconds,
                grid: SnapGrid(grid: project.grid, unit: choices.gridUnit)
            ))
            work.start = (project.songPlace, timelineView.scale, snaps)
        }
        guard let start = work.start else { return }
        work.lastDrag = drag

        let length = project.songLengthSamples
        let draggedBy = Double(drag.x - drag.startX) / start.scale.pointsPerSecond
        let kept = start.place.keptSeconds(ofLength: length)
        var place: SongPlace
        switch drag.part {
        case .start:
            let edge = snapped(kept.lowerBound + draggedBy, by: start.snaps, at: start.scale)
            place = start.place.cuttingStart(at: Self.sample(edge), ofLength: length)
        case .end:
            let edge = snapped(kept.upperBound + draggedBy, by: start.snaps, at: start.scale)
            place = start.place.cuttingEnd(at: Self.sample(edge), ofLength: length)
        case .song:
            // Moved right, the song's later moments stay where they are and an earlier one
            // comes to stand at 00:00. With snapping on, that moment catches like an edge.
            let zero = snapped(start.place.zeroSeconds - draggedBy, by: start.snaps, at: start.scale)
            place = start.place.moved(bySamples: start.place.zeroSample - Self.sample(zero), ofLength: length)
            // The timeline keeps the time it shows at its left edge, so everything on the
            // song goes with the pointer.
            var moved = start.scale
            moved.scrollOffsetSeconds += place.zeroSeconds - start.place.zeroSeconds
            timelineView.moveTimelineWithSong(to: moved)
        }
        showSongPlace(place)

        guard drag.isFinished else { return }
        work.start = nil
        work.lastDrag = nil
        setSongPlace(place, drag.part == .song ? "Move Song" : "Trim Song")
    }

    /// The drag of the song that is going on, followed again as the window last reported it,
    /// because Command or N turned snapping the other way without the pointer moving.
    func followSongDrag() {
        let work = songDragWork
        guard work.start != nil, let drag = work.lastDrag, !drag.isFinished else { return }
        songDragged(drag)
    }

    /// Changes what is cut away of the open song, or where its 00:00 lies, as one step that
    /// Undo takes back. A place that is the project's own already changes nothing.
    func setSongPlace(_ place: SongPlace, _ actionName: String) {
        guard loadedSounds.song != nil, takeStatus.phase == nil else { return }
        guard store.project.songPlace != place else {
            showSongPlace(place)
            return
        }
        store.edit(actionName) { $0.songPlace = place }
        songPlaceChanged()
    }

    /// Holds the loop, its in and out and the marked stretch inside what is left of the
    /// song, whenever the model follows the song's place: after a cut or a move, after Undo
    /// and Redo, and when a project opens. One that reaches outside is shortened, and one with nothing left
    /// is taken away. `followClips` draws the stretch afterwards.
    ///
    /// When the place is the one a cut started from, that cut was undone: what it shortened
    /// comes back as it was, unless Max has changed it since.
    func keepLoopAndStretch(inside project: Project) {
        let work = songDragWork
        let place = project.songPlace
        defer { work.followedPlace = place }
        if let cut = work.shortened.last, cut.placeBefore == place {
            work.shortened.removeLast()
            if let loop = cut.loop, loopState.region == loop.after {
                loopState.region = loop.before
            }
            // A loop that came back has brought its ends back already.
            if let inOut = cut.inOut, loopState.inOut == inOut.after {
                loopState.inOut = inOut.before
            }
            if let stretch = cut.stretch, selection.markedStretch == stretch.after {
                selection.markedStretch = stretch.before
            }
            return
        }
        var cut = ShortenedByCut(placeBefore: work.followedPlace ?? place)
        // A shortened loop moves its in and out with it, so they are compared afterwards.
        let inOutBefore = loopState.inOut
        if let loop = loopState.region {
            let left = loop.shortened(to: project.keptSamples)
            if left != loop {
                cut.loop = (loop, left)
                loopState.region = left
            }
        }
        if let inOut = loopState.inOut {
            loopState.inOut = inOut.kept(inside: project.keptSeconds)
        }
        if let inOutBefore, loopState.inOut != inOutBefore {
            cut.inOut = (inOutBefore, loopState.inOut)
        }
        if let stretch = selection.markedStretch {
            let left = project.keptPart(of: stretch.range).map { MarkedStretch(trackID: stretch.trackID, range: $0) }
            if left != stretch {
                cut.stretch = (stretch, left)
                selection.markedStretch = left
            }
        }
        if cut.loop != nil || cut.inOut != nil || cut.stretch != nil {
            work.shortened.append(cut)
        }
    }

    /// Another song is opened: what the cuts of the old one shortened is not this one's.
    func forgetShortenedByCut() {
        songDragWork.shortened = []
        songDragWork.followedPlace = nil
    }

    /// Where a dragged edge, or the moment that comes to stand at 00:00, goes: onto the
    /// nearest of the places the drag catches on when one is within the snap distance on
    /// screen, and where it is when none is or when snapping does not hold (`snappingHolds`).
    private func snapped(_ seconds: Double, by snaps: SnapEngine, at scale: TimelineScale) -> Double {
        guard timelineView.snappingHolds, scale.pointsPerSecond > 0 else { return seconds }
        let tolerance = Double(settings[.snapDistancePoints]) / scale.pointsPerSecond
        // A single place, held against the points as both edges of nothing.
        guard let snap = snaps.snap(start: seconds, end: seconds, tolerance: tolerance) else {
            return seconds
        }
        return seconds + snap.delta
    }

    private static func sample(_ seconds: Double) -> Int {
        Int((seconds * Lockstep.sampleRate).rounded())
    }
}

extension AppModel {
    /// Gives `songPlace` its closures: it has none, because everything it calls it is handed.
    /// `wire()` calls it once, when every part is made.
    func wireSongPlace() {}
}

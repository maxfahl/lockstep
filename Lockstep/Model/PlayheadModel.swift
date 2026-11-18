import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import QuartzCore

/// Moving the playhead: a part of the app's model.
///
/// It holds moving the playhead by hand: dragging in the ruler, Go Back, stepping by beats,
/// jumping to a clip, and `-playhead`.
@MainActor
final class PlayheadModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let store: ProjectStore
    private let settings: AppSettings
    private let playhead: PlayheadPosition

    // The parts it is handed, and calls directly.
    private let timelineView: TimelineViewModel
    private let clips: ClipsModel
    private let transport: TransportModel

    // What it asks of code that holds it, or of the model's routing. `wirePlayhead` sets them.
    /// Carries out a command the way the menu and the keyboard do (`perform(_:)`, the model's
    /// routing). A drag in the ruler stops the song with it and starts it again.
    var perform: (AppCommand) -> Void = { _ in }

    // MARK: What it keeps

    /// What is kept while the playhead is dragged in the ruler. See `rulerDragged`.
    private let playheadDrag = PlayheadDragWork()
    /// True once the playhead was sent where `-playhead` asked.
    private var launchPlayheadTaken = false

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore,
        settings: AppSettings,
        playhead: PlayheadPosition,
        timelineView: TimelineViewModel,
        clips: ClipsModel,
        transport: TransportModel
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
        self.settings = settings
        self.playhead = playhead
        self.timelineView = timelineView
        self.clips = clips
        self.transport = transport
    }
}

// Moving the playhead with the keys and by dragging in the ruler.
//
// Go Back (Return): the playhead goes to where the last take started in the song, which is
// the place Record aimed at and not the start of its count-in. When it already stands there,
// or no take was started since the project was opened, it goes to the start of the song.
// Go to Start (Shift+Return) goes there at once.
//
// Previous Screen and Next Screen (Option+Left and Option+Right): the playhead moves by the
// width the timeline shows, and the timeline glides along by the same distance, so the
// playhead keeps its place on screen (`jumpScreen`, which is the transport's).
//
// The six steps (the Left and Right arrows, with Command, and with Shift and Command): the
// playhead goes to the nearest sub-beat, half beat or beat before or after it
// (`Grid.stepPlace`). A sub-beat is a sixteenth, four to a beat.
//
// The four jumps between clips (A, D, W and S): the playhead goes to the start of the clip
// before or after it on the selected track, or to the nearest clip on the track above or
// below (`Project.clipJump`). The clip landed on becomes the selected clip.
//
// All of them move the playhead the way a click in the ruler does: while the song plays it
// plays on from the new place, and during a take nothing moves. A new place that is outside
// what the timeline shows is brought to the middle of it (`jump`).
//
// Dragging (`rulerDragged`): a press in the ruler puts the playhead under the pointer, and
// it follows the pointer for as long as the button is down, wherever the pointer goes. A
// song that was playing is stopped for the length of the drag, so nothing is heard, and
// plays on from where the pointer is let go. Near the left or the right edge of the
// timeline the timeline scrolls, as it does while a clip is dragged. A click is a drag that
// did not move. With snapping on, a click or a drag puts the playhead on the grid or on a
// near clip edge, as Snap To says (`snappedPlayheadPlace`). Command held turns that the
// other way.
//
// Nothing else is dragged in the ruler. The loop region drawn there is switched with the
// Loop command, and a stretch is marked by dragging in a track's row, which is another
// view with its own drag: the two are told apart by where the button goes down.

/// What the model keeps while the playhead is dragged in the ruler.
@MainActor
final class PlayheadDragWork {
    /// What the window last said about the drag that is going on, or nil when none is.
    var report: TimelineRulerDrag?
    /// A drag that could not start, because a take was going. What the window goes on
    /// saying about it is not listened to. It is the place its button went down at.
    var givenUpStartX: CGFloat?
    /// True when the song was playing when the button went down. It plays on from where
    /// the pointer is let go.
    var resumes = false
    /// Runs once per display frame while the playhead is dragged: the timeline scrolls
    /// when the pointer rests near its edge.
    let frames = FrameTicker()
    /// When the last of those frames came, on the clock of `CACurrentMediaTime()`.
    var lastFrameAt: Double?
}

extension PlayheadModel {
    /// How near the place of the last take the playhead must stand to count as standing on
    /// it, in seconds. The player reports a place to the nearest sample.
    private static let goBackReach = 0.001
    /// While the song plays, the playhead leaves the place at once. Go Back pressed again
    /// within this many seconds of song still counts as standing there, so two presses in a
    /// row reach the start of the song also then.
    private static let goBackReachWhilePlaying = 1.0

    /// Go Back: to where the last take started, or from there to the start of the song.
    func goBack() {
        guard let place = takeStatus.lastTakeStart else {
            transport.jump(to: 0)
            return
        }
        let past = playhead.seconds - place
        let isThere = windowState.content.isPlaying
            ? past > -Self.goBackReach && past < Self.goBackReachWhilePlaying
            : abs(past) < Self.goBackReach
        transport.jump(to: isThere ? 0 : place)
    }

    /// Whether the step commands have anything to step along: an open song whose beats are found.
    var canStepPlayhead: Bool {
        loadedSounds.song != nil && !loadedSounds.isOpening && !(store.project.grid?.beats.isEmpty ?? true)
    }

    /// Carries out one of the six step commands. Any other command does nothing here.
    func stepPlayhead(_ command: AppCommand) {
        guard let (direction, step) = command.playheadStep, let song = loadedSounds.song,
              let grid = store.project.grid
        else { return }
        transport.jump(to: grid.stepPlace(
            direction,
            from: playhead.seconds,
            perBeat: step.perBeat,
            songLength: song.duration
        ))
    }
}

extension PlayheadModel {
    // MARK: Dragging the playhead in the ruler

    /// The ruler was pressed, the pointer was moved with the button down, or the button was
    /// let go.
    func rulerDragged(_ report: TimelineRulerDrag) {
        let work = playheadDrag
        if let givenUp = work.givenUpStartX {
            if givenUp == report.startX {
                if report.isFinished {
                    work.givenUpStartX = nil
                }
                return
            }
            work.givenUpStartX = nil
        }
        // The end of the last drag was never reported, and this is another one.
        if let last = work.report, last.startX != report.startX {
            endPlayheadDrag()
        }
        if work.report == nil {
            // A take is tied to the place the song is at, so the playhead stays put during one.
            guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil else {
                if !report.isFinished {
                    work.givenUpStartX = report.startX
                }
                return
            }
            // Nothing is heard while dragging: a song that plays is stopped until the end of the drag.
            work.resumes = windowState.content.isPlaying
            if work.resumes {
                perform(.playStop)
            }
            work.lastFrameAt = nil
            work.frames.onFrame = { [weak self] in self?.playheadDragFrame() }
            work.frames.start()
        }
        work.report = report
        followPlayheadDrag()
        if report.isFinished {
            endPlayheadDrag()
        }
    }

    /// Puts the playhead under the pointer, with the timeline as it is at this moment. Also
    /// called when Command or N turns snapping the other way during the drag.
    func followPlayheadDrag() {
        guard let report = playheadDrag.report, timelineView.scale.pointsPerSecond > 0 else { return }
        _ = transport.seek(to: snappedPlayheadPlace(timelineView.scale.seconds(forX: Double(report.x))))
    }

    /// Where a click or a drag in the ruler puts the playhead while snapping is on: on the
    /// edge of a shown clip within the snap distance on screen, when Clip Edges is chosen,
    /// or else on the nearest line of the grid in the chosen unit, when Grid is chosen, the
    /// way a moved clip goes in steps of it. Before the first beat and after the last there
    /// are no lines, and the playhead stays under the pointer. So does it with snapping off,
    /// or with snapping on and Command held (`snappingHolds`).
    func snappedPlayheadPlace(_ seconds: Double) -> Double {
        guard timelineView.snappingHolds, timelineView.scale.pointsPerSecond > 0 else { return seconds }
        let choices = settings.snapChoices
        if choices.clipEdges {
            let tolerance = Double(settings[.snapDistancePoints]) / timelineView.scale.pointsPerSecond
            let edges = SnapEngine(sources: [ClipEdgeSource(project: store.project)])
            // The playhead is a single place, so it is held against the edges as both ends of nothing.
            if let hit = edges.snap(start: seconds, end: seconds, tolerance: tolerance) {
                return seconds + hit.delta
            }
        }
        guard choices.grid else { return seconds }
        let grid = SnapGrid(grid: store.project.grid, unit: choices.gridUnit)
        guard let first = grid.lines.first, let last = grid.lines.last, seconds >= first, seconds <= last,
              let line = grid.nearestLine(to: seconds)
        else { return seconds }
        return line
    }

    /// Once per display frame while the playhead is dragged. With the pointer near the left
    /// or the right edge of the timeline, the timeline scrolls that way and the playhead
    /// goes with the pointer.
    private func playheadDragFrame() {
        let work = playheadDrag
        let now = CACurrentMediaTime()
        // A frame that came late does not make the timeline jump.
        let elapsed = min(now - (work.lastFrameAt ?? now), 0.1)
        work.lastFrameAt = now
        guard let report = work.report else { return }
        if timelineView.scrollTimeline(towardPointerAt: Double(report.x), during: elapsed) {
            followPlayheadDrag()
        }
    }

    /// The drag is over. A song that was playing when it began plays on from where the
    /// playhead now stands, unless something else has started or stopped it meanwhile, a
    /// take has begun, or the playhead was left at the very end of the song.
    private func endPlayheadDrag() {
        let work = playheadDrag
        work.report = nil
        work.frames.stop()
        guard work.resumes else { return }
        work.resumes = false
        if loadedSounds.song != nil, takeStatus.phase == nil, !windowState.content.isPlaying,
           playhead.seconds < store.project.keptSeconds.upperBound {
            perform(.playStop)
        }
    }
}

extension PlayheadModel {
    // MARK: Jumping between clips

    /// While the song plays, the playhead leaves a clip's start at once. Previous Clip pressed
    /// again within this many seconds of song still counts as standing on that start, so two
    /// presses in a row reach the clip before also then.
    private static let clipStartReachWhilePlaying = 1.0

    /// Carries out one of the four jumps between clips. Any other command does nothing here.
    ///
    /// The clip landed on is selected alone, with its track, so the keys that act on a clip
    /// can follow straight after. A jump up or down to a track without clips selects that
    /// track and leaves the playhead where it is.
    func jumpToClip(_ command: AppCommand) {
        guard let jump = command.clipJump, loadedSounds.song != nil, !loadedSounds.isOpening,
              takeStatus.phase == nil
        else { return }
        let project = store.project
        guard let selected = selection.trackID.flatMap({ project.track($0)?.id }) ?? project.tracks.first?.id,
              let landing = project.clipJump(
                  jump,
                  from: playhead.seconds,
                  selectedTrack: selected,
                  reach: windowState.content.isPlaying ? Self.clipStartReachWhilePlaying : Grid.stepTolerance
              )
        else { return }
        let clips: Set<UUID> = landing.clip.map { [$0.id] } ?? []
        if selection.trackID != landing.trackID || selection.clipIDs != clips {
            selection.trackID = landing.trackID
            selection.clipIDs = clips
            self.clips.showClips(of: project)
        }
        guard let place = landing.clip?.place else { return }
        transport.jump(to: place)
    }
}

extension PlayheadModel {
    // MARK: For an agent's run

    /// Puts the playhead where `-playhead` asked, once the first project is open and the
    /// takes given with `-addTake` are in it, and says so on standard error. An agent that
    /// checks the app cannot click in the timeline, and Split at Playhead needs the
    /// playhead inside a clip.
    func moveToLaunchPlayhead() {
        guard !launchPlayheadTaken, let seconds = LaunchOptions.current.playhead else { return }
        launchPlayheadTaken = true
        Task {
            // Until the takes are added the song cannot be moved.
            await takeStatus.ended()
            guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil else {
                Agent.tell("could not move the playhead: the song is not ready")
                return
            }
            transport.jump(to: seconds)
            Agent.tell(String(format: "moved the playhead to %.3f s", playhead.seconds))
        }
    }
}

extension AppModel {
    /// Gives `playheadModel` its closures. `wire()` calls it once, when every part is made.
    func wirePlayhead() {
        playheadModel.perform = { [weak self] command in self?.perform(command) }
    }
}

import AppKit
import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import Observation
import os
import QuartzCore
import struct SwiftUI.Binding
import Synchronization

/// The timeline's view: a part of the app's model.
///
/// It holds how the timeline is shown: the zoom and the scroll, gliding, the height of the
/// tracks, following the playhead, scrolling at the edge during a drag, whether snapping holds, the
/// memory of how a project was shown (`view.json`), and the measuring of `-middleDrag`.
@MainActor
@Observable
final class TimelineViewModel {
    // The ground it is handed.
    @ObservationIgnored private let windowState: WindowState
    @ObservationIgnored private let selection: Selection
    @ObservationIgnored private let loadedSounds: LoadedSounds
    @ObservationIgnored private let takeStatus: TakeStatus
    @ObservationIgnored private let loopState: LoopState
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let playhead: PlayheadPosition

    // What it asks of code that holds it, or of the model's routing. `wireTimelineView` sets them.
    /// Moves the playhead to a place in the song (`seek(to:)`, the transport, which holds this
    /// part). Only opening a project that remembers its playhead calls it.
    @ObservationIgnored var seek: (Double) -> Bool = { _ in false }

    /// Carries out a command the way the menu and the keyboard do (`perform(_:)`, the model's
    /// routing). Only the measuring of `-middleDrag` calls it.
    @ObservationIgnored var perform: (AppCommand) -> Void = { _ in }

    /// Adds the 12 tracks and 200 clips of Debug > Add Test Clips (`addTestClips()`, clip editing,
    /// which holds this part). Only the measuring of `-middleDrag` calls it, in Debug builds.
    @ObservationIgnored var addTestClips: () -> Void = {}

    /// Whether the beats of the song are being found right now (`beatFinding != nil`, the beats).
    /// Only the measuring of `-middleDrag` asks.
    @ObservationIgnored var beatsAreBeingFound: () -> Bool = { false }

    // MARK: What it keeps

    /// The zoom and the sideways scroll position of the timeline. Zero points per
    /// second means "fit the whole song to the width"; the timeline writes the real
    /// value back.
    ///
    /// The window writes it when Max pinches or scrolls. The model itself moves the
    /// timeline only with `moveScale(to:)`, so the two can be told apart: what comes
    /// from the window ends a move of the model's own that is under way, and makes
    /// following the playhead wait.
    var scale = TimelineScale(pointsPerSecond: 0) {
        didSet {
            guard !isMovingScale, scale != oldValue else { return }
            stopGlide()
            scaleMovedByHandAt = CACurrentMediaTime()
        }
    }

    /// `scale` as a binding for the window, made once. A binding holds the value it had when it was made,
    /// and SwiftUI compares bindings by that value: one made in the window's `body` would make the whole
    /// window work itself out again on every move of the timeline. This one never changes, so only the
    /// timeline, which reads the scale through it, follows a move.
    @ObservationIgnored private(set) lazy var scaleBinding = Binding<TimelineScale>(
        get: { [unowned self] in scale },
        set: { [unowned self] in scale = $0 }
    )

    /// The height of the rows of all vocal tracks, in points. The window writes it when
    /// Max scrolls with Shift held, and View > Taller Tracks and Lower Tracks change it a
    /// step at a time. Like the zoom it is kept here and nowhere else: it lasts while
    /// Lockstep runs. Opening another song leaves it as it is.
    var trackHeight = TrackHeight.standard
    /// How far the track rows are scrolled down. The timeline keeps it up to date, and a
    /// project that is opened again is scrolled where it was (`restore`).
    let rowsPosition = TimelineRowsPosition()
    /// What is kept between two writes of the open project's view (`writeViewIfChanged`).
    @ObservationIgnored private let viewMemory = ViewMemoryWork()

    /// The width of the timeline's rows in points, as the window reports it. Zero
    /// before the timeline is on screen.
    @ObservationIgnored var timelineWidth: Double = 0

    /// True while the model itself changes `scale`.
    @ObservationIgnored private var isMovingScale = false
    /// When the window last changed `scale`, on the clock of `CACurrentMediaTime()`.
    @ObservationIgnored private var scaleMovedByHandAt = -Double.infinity
    /// The zoom from the menu or the glide to the playhead that is under way, or nil.
    @ObservationIgnored private var scaleGlide: ScaleGlide?
    /// Moves the timeline along `scaleGlide`, once per frame, while there is one.
    @ObservationIgnored private let glideFrames = FrameTicker()
    /// True once the drags `-middleDrag` asked for were started. See `dragLaunchTimeline`.
    @ObservationIgnored private var launchDragTaken = false

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        loopState: LoopState,
        store: ProjectStore,
        settings: AppSettings,
        playhead: PlayheadPosition
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.loopState = loopState
        self.store = store
        self.settings = settings
        self.playhead = playhead
        // A glide moves on once per display frame.
        glideFrames.onFrame = { [weak self] in self?.stepGlide() }
    }
}

extension TimelineViewModel {
    // MARK: Zooming and moving the timeline

    /// How much one Zoom In or Zoom Out changes the zoom.
    static let zoomStep = 1.5

    /// Zooms around the playhead, between "the whole song fits" and 2 ms per point.
    /// (A pinch zooms around the pointer; the timeline does that itself.)
    func zoom(by factor: Double) {
        guard loadedSounds.song != nil, timelineWidth > 0 else { return }
        // What the timeline holds: from its 00:00, which can lie inside the song.
        let whole = timelineRange
        // From where the timeline is heading, so two quick presses zoom two steps.
        var zoomed = restingScale
        // Right after a song is opened the scale may still mean "fit the song".
        zoomed.clamp(range: whole, viewWidth: timelineWidth)
        zoomed.zoom(by: factor, keepingSeconds: playhead.seconds, viewWidth: timelineWidth)
        zoomed.clamp(range: whole, viewWidth: timelineWidth)
        glide(to: zoomed)
    }

    /// Shows everything the timeline holds across its width: from its 00:00 to the end of the song.
    func zoomToFit() {
        guard loadedSounds.song != nil, timelineWidth > 0 else { return }
        // Zero points per second means "fit": the limits then give the zoom that does.
        var fitted = TimelineScale(pointsPerSecond: 0)
        fitted.clamp(range: timelineRange, viewWidth: timelineWidth)
        glide(to: fitted)
    }

    /// Whether Taller Tracks or Lower Tracks has a step left to take. The rows are there
    /// once a song is open, and stop at the lowest and the tallest height.
    func canStepTrackHeight(_ command: AppCommand) -> Bool {
        guard loadedSounds.song != nil else { return false }
        return command == .tallerTracks
            ? trackHeight < TrackHeight.range.upperBound
            : trackHeight > TrackHeight.range.lowerBound
    }

    /// Where the timeline is, or where it will be once the move under way is over.
    var restingScale: TimelineScale {
        scaleGlide?.to ?? scale
    }

    /// Changes the zoom or the scroll position as the model's own doing. Every change
    /// the model makes goes through here; what the window writes does not.
    func moveScale(to moved: TimelineScale) {
        guard moved != scale else { return }
        isMovingScale = true
        scale = moved
        isMovingScale = false
    }

    /// Takes the timeline to another zoom or scroll position over the length of one
    /// animation (`Motion`), or at once when animations are off.
    func glide(to target: TimelineScale) {
        let duration = Motion.duration(settings)
        // A scale that still means "fit the song" has no place to start from.
        guard duration > 0, scale.pointsPerSecond > 0, target != scale else {
            stopGlide()
            moveScale(to: target)
            return
        }
        scaleGlide = ScaleGlide(from: scale, to: target, startedAt: CACurrentMediaTime(), duration: duration)
        glideFrames.start()
    }

    /// Once per display frame while the timeline is on its way: the next step.
    private func stepGlide() {
        guard let glide = scaleGlide, loadedSounds.song != nil else {
            stopGlide()
            return
        }
        let now = CACurrentMediaTime()
        var shown = glide.scale(at: now)
        // Inside the same limits as the timeline keeps, so it has nothing to correct.
        shown.clamp(range: timelineRange, viewWidth: timelineWidth)
        if glide.isOver(at: now) {
            stopGlide()
        }
        moveScale(to: shown)
    }

    func stopGlide() {
        scaleGlide = nil
        glideFrames.stop()
    }

    /// The song seconds the timeline covers: from its 00:00 to the end of the song file.
    /// Every zoom and every scroll the model makes is held inside it, as the window holds
    /// its own.
    var timelineRange: ClosedRange<Double> {
        store.project.songPlace.shownSeconds(ofLength: store.project.songLengthSamples)
    }

    /// Moves the timeline with the song while the song is dragged: the model's own doing,
    /// like a glide to the playhead, so following the playhead does not wait for it.
    func moveTimelineWithSong(to moved: TimelineScale) {
        stopGlide()
        moveScale(to: moved)
    }
}

extension TimelineViewModel {
    // MARK: Following the playhead

    // One rule (`PlayheadFollow`): when the playhead is outside what the timeline shows, to
    // the left or to the right, the timeline glides so that the playhead stands in the
    // middle of its width when the glide ends. A playhead that is in view leaves the
    // timeline where it is.
    //
    // A command brings the playhead to the middle whatever Settings says: the steps, Go
    // Back, the jumps between clips, Play, the start and the restart of a take, and
    // `-playhead`. While the song plays by itself, the rule holds with "To the middle"
    // chosen in Settings > General > "Follow the playhead" (`followPlayheadOutOfView`),
    // and with "Off" the timeline stays.
    //
    // The hand wins. Scrolling and zooming by hand never move the playhead, and a
    // playhead that is out of view because Max moved the timeline away is left alone
    // while the song plays, until a command moves it or it has come into view again.

    /// Brings a place of the playhead to the middle of the timeline when it is outside what
    /// the timeline shows, or what it will show once a move under way is over. Near the
    /// start and the end the timeline stops at its limit. With animations off it jumps.
    ///
    /// - Parameters:
    ///   - seconds: Where the playhead stands, in song seconds.
    ///   - moving: Whether the playhead plays on while the timeline glides. The glide is
    ///     then aimed at where the playhead will be when it ends.
    func bringToMiddle(_ seconds: Double, moving: Bool) {
        guard loadedSounds.song != nil, let target = PlayheadFollow.scale(
            showing: restingScale,
            viewWidth: timelineWidth,
            range: timelineRange,
            playhead: seconds,
            isPlaying: moving,
            glideDuration: Motion.duration(settings)
        ) else { return }
        glide(to: target)
    }

    /// While the song plays: the playhead was in view a frame ago and is not now, because
    /// it passed the right edge or a loop came round. The timeline comes to it. A playhead
    /// that was out of view already (Max scrolled away) is left alone.
    func followPlayheadOutOfView(from before: Double, to now: Double) {
        guard PlayheadFollow.isInView(before, of: restingScale, viewWidth: timelineWidth) else { return }
        bringToMiddle(now, moving: true)
    }

    /// Where the playhead stands while it is followed smoothly: this share of the
    /// timeline's width, counted from the left.
    private static let smoothFollowPlace = 0.4
    /// How long after Max last scrolled or zoomed by hand the smooth following waits,
    /// in seconds, so it does not pull the timeline back while he is still moving it.
    private static let handPause = 0.5

    /// Follows the playhead smoothly: the playhead stays at its place and the song
    /// moves under it.
    ///
    /// Only a playhead that is on screen is followed. One that Max scrolled away from
    /// is left alone until it is on screen again, and so is the timeline while he is
    /// scrolling or zooming by hand. A playhead to the left of its place walks there
    /// by itself. One to the right of it (after a click further on, or after Max
    /// scrolled) is caught up with over a few frames, not in one jump.
    func scrollUnderPlayhead(from before: Double, to now: Double) {
        guard loadedSounds.song != nil, timelineWidth > 0, scale.pointsPerSecond > 0 else { return }
        // A zoom from the menu finishes first.
        guard scaleGlide == nil, CACurrentMediaTime() - scaleMovedByHandAt >= Self.handPause else { return }
        let place = timelineWidth * Self.smoothFollowPlace
        let x = scale.x(for: now)
        guard x > place, x <= timelineWidth else { return }

        // How far the timeline has to move, in song seconds, and how far the song
        // itself moved on since the last frame.
        let behind = (x - place) / scale.pointsPerSecond
        let step = max(now - before, 0)
        let duration = Motion.duration(settings)
        var moved = scale
        if duration > 0, (behind - step) * scale.pointsPerSecond > 0.5 {
            // Further behind than one frame of playing: keep up with the song and close
            // part of the rest.
            moved.scrollOffsetSeconds += step + (behind - step) * (1 - exp(-step / duration))
        } else {
            moved.scrollOffsetSeconds += behind
        }
        moved.clamp(range: timelineRange, viewWidth: timelineWidth)
        moveScale(to: moved)
    }
}

extension TimelineViewModel {
    // MARK: Scrolling at the edge during a drag

    /// How near an edge of the timeline the pointer must be for the timeline to scroll
    /// during a drag, in points.
    private static let dragScrollMargin = 40.0
    /// How fast the timeline scrolls when the pointer is right at its edge, in points a second.
    private static let dragScrollSpeed = 700.0
    /// How many times that speed the scrolling reaches at most, with the pointer well
    /// outside the timeline.
    private static let dragScrollTopPull = 2.5

    /// During a drag, with the pointer near the left or the right edge of the timeline:
    /// scrolls the timeline that way, faster the further out the pointer is. Called once
    /// per display frame by whatever is being dragged (a clip, or the end of a stretch
    /// that is being marked).
    ///
    /// - Parameters:
    ///   - x: where the pointer is, in points from the left edge of the rows.
    ///   - elapsed: how long ago the last frame was, in seconds.
    /// - Returns: true when the timeline moved, so the caller draws what it drags again.
    func scrollTimeline(towardPointerAt x: Double, during elapsed: Double) -> Bool {
        guard loadedSounds.song != nil, timelineWidth > 0, scale.pointsPerSecond > 0 else { return false }
        let margin = Self.dragScrollMargin
        var pull = 0.0
        if x < margin {
            pull = (x - margin) / margin
        } else if x > timelineWidth - margin {
            pull = (x - (timelineWidth - margin)) / margin
        }
        pull = min(max(pull, -Self.dragScrollTopPull), Self.dragScrollTopPull)
        guard pull != 0 else { return false }
        var moved = scale
        moved.scrollOffsetSeconds += pull * Self.dragScrollSpeed * elapsed / moved.pointsPerSecond
        moved.clamp(range: timelineRange, viewWidth: timelineWidth)
        guard moved != scale else { return false }
        // Written like a scroll by hand, so following the playhead waits.
        scale = moved
        return true
    }
}

extension TimelineViewModel {
    // MARK: Whether snapping holds

    /// Whether snapping holds right now: the setting `editing.snapping`, turned the other way while Command
    /// is held. The setting itself, and the snapping button that shows it, stay as they are.
    var snappingHolds: Bool {
        settings.snappingHolds(commandHeld: NSEvent.modifierFlags.contains(.command))
    }

    /// How near a dragged clip or edge must come to catch, in song seconds at the current zoom, or nil
    /// when snapping does not hold right now. The snap distance is a distance on screen, so snapping
    /// feels the same at every zoom.
    var snapTolerance: Double? {
        let pointsPerSecond = scale.pointsPerSecond
        guard snappingHolds, pointsPerSecond > 0 else { return nil }
        return Double(settings[.snapDistancePoints]) / pointsPerSecond
    }
}

// Keeping the view of a project across a restart.
//
// How the open project is shown (the zoom and the place in the timeline, how far the
// track rows are scrolled down, their height, the playhead, the selection and the loop's in
// and out) is kept in
// `view.json` inside the project's folder (`ProjectView`). It is not part of the project:
// writing it is no undo step and does not make the project count as changed. It is
// written once a second when it has changed, and when the project is left, so a crash
// loses at most the last second. Opening the project again brings it back; the launch
// arguments act after that, so `-playhead` and the others win.
//
// Whether the inspector is open belongs to the window and not to a project. It is kept in
// the settings (`inspectorShown`), like the window's size and place.

/// What is kept between two writes of the view.
@MainActor
final class ViewMemoryWork {
    /// The project whose view is kept, or nil before one is open.
    var package: ProjectPackage?
    /// The view as it was last written or read, so an unchanged view is not written again.
    var written: ProjectView?
    /// Writes the view once a second while a project is open.
    var ticks: Task<Void, Never>?
}

extension TimelineViewModel {
    /// How often a changed view is written.
    private static let viewWriteInterval = Duration.seconds(1)
    /// Where the settings keep whether the inspector is open.
    private static let inspectorShownKey = "inspectorShown"

    /// The view of the open project as it is now.
    private var currentView: ProjectView {
        ProjectView(
            pointsPerSecond: scale.pointsPerSecond,
            scrollOffsetSeconds: scale.scrollOffsetSeconds,
            rowsScrollPoints: Double(rowsPosition.y),
            trackHeight: Double(trackHeight),
            playheadSeconds: playhead.seconds,
            selectedTrackID: selection.trackID,
            selectedClipIDs: Array(selection.clipIDs),
            loopInOut: loopState.inOut
        )
    }

    /// Brings back what `show` does not set itself from a kept view: the height of the
    /// rows, how far they are scrolled, the loop's in and out and the playhead. Call it
    /// once the project is in the store. The playhead is moved a moment later, once the
    /// opening is over, the way a click in the ruler moves it; a `-playhead` asked for at
    /// launch comes after. Loop itself starts off.
    func restore(_ view: ProjectView) {
        trackHeight = TrackHeight.clamped(CGFloat(view.trackHeight))
        rowsPosition.scroll(to: CGFloat(view.rowsScrollPoints))
        // Held inside what is left of the song, in case the file was written by hand.
        loopState.inOut = view.loopInOut?.kept(inside: store.project.keptSeconds)
        Task {
            _ = seek(view.playheadSeconds)
        }
    }

    /// From now on the view of `package` is kept. `kept` is what it was opened with, so
    /// nothing is written until something changes.
    func keepView(of package: ProjectPackage, openedWith kept: ProjectView?) {
        viewMemory.package = package
        viewMemory.written = kept
        guard viewMemory.ticks == nil else { return }
        viewMemory.ticks = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.viewWriteInterval)
                self?.writeViewIfChanged()
            }
        }
    }

    /// Writes the view of the open project if it has changed since it was last written.
    /// Call it before another project is shown and when Lockstep quits. A view that
    /// cannot be written is let go: it is tried again a second later, and nothing of the
    /// project depends on it.
    func writeViewIfChanged() {
        guard let package = viewMemory.package, loadedSounds.song != nil else { return }
        let view = currentView
        guard view != viewMemory.written else { return }
        do {
            try package.write(view)
            viewMemory.written = view
        } catch {
            // The project's own saving says so when the folder cannot be written to.
        }
    }

    /// Whether the inspector was open when Lockstep was last left, or nil when Max never
    /// chose: the width of the window then decides, as before.
    var keptInspectorChoice: Bool? {
        LaunchOptions.current.settings.object(forKey: Self.inspectorShownKey) as? Bool
    }

    /// Max opened or hid the inspector. The next start opens the window the same way.
    func inspectorChosen(_ isShown: Bool) {
        LaunchOptions.current.settings.set(isShown, forKey: Self.inspectorShownKey)
    }
}

/// How well the timeline keeps up with a drag with the middle mouse button, measured by the app itself
/// (`-middleDrag`). On 14 November 2026 Max found that drag laggy. An agent cannot move the pointer, so the
/// drags are made up: a clock away from the main thread makes the pointer's moves at the rate a mouse
/// reports them, and they reach the timeline's catcher the way events do (`TimelineMiddleDrag`). Moves
/// that are made while the main thread is busy wait and are handed over together, as AppKit hands over the
/// mouse's moves that queued up as one.
///
/// Before the drags the project gets the twelve tracks and two hundred clips of Debug > Add Test Clips, and
/// the timeline is zoomed in, so there is room to move along the song and up and down through the tracks.
/// Each drag says on standard error:
/// - how many moves the mouse made, how many reached the timeline's catcher, how often the timeline was told
///   of them and drawn with them, and how long the catcher took over one move on the main thread;
/// - how long a drawing took, from the moment the timeline was told to the end of that turn of the main
///   thread's run loop, where the window is laid out and drawn (`CommitWatch`);
/// - the lag: from the moment a move was made to the end of the turn that drew it;
/// - how many frames of the display the main thread had time for, of how many there were, and the
///   longest gap between two;
/// - how much of the time the main thread worked, and the longest stretch of it;
/// - how far along the song the timeline moved, and how far the pointer moved, both in song seconds: one
///   to one, they are the same unless the edge of the song stopped the drag.
extension TimelineViewModel {
    /// Makes the drags `-middleDrag` asks for, once the first project is open, the takes given with
    /// `-addTake` are in it and the beats are found.
    func dragLaunchTimeline() {
        guard !launchDragTaken, LaunchOptions.current.dragsTimeline else { return }
        launchDragTaken = true
        Task {
            await takeStatus.ended()
            await dragTimelineForAgent()
        }
    }

    /// One drag that is measured: how fast the pointer goes, sideways and up or down, in points a second,
    /// how often the mouse reports a move, and for how long.
    private struct MeasuredDrag {
        var name: String
        var sideways: Double
        var upOrDown: Double = 0
        /// Points the pointer wavers up and down by while it goes sideways, as a hand does.
        var waver: Double = 0
        var rate: Double = 1_000
        var seconds: Double = 1.5
        /// Two fingers on the trackpad instead of the middle button: only sideways, at the display's rate.
        var isTrackpad = false
        var whilePlaying = false
    }

    private static let measuredDrags = [
        MeasuredDrag(name: "sideways", sideways: -600),
        MeasuredDrag(name: "sideways, wavering up and down", sideways: 600, waver: 3),
        MeasuredDrag(name: "up and down", sideways: 0, upOrDown: 300),
        MeasuredDrag(name: "sideways, a mouse that reports 125 times a second", sideways: -600, rate: 125),
        MeasuredDrag(name: "two fingers on the trackpad, for comparison", sideways: 600, rate: 120, isTrackpad: true),
        MeasuredDrag(name: "sideways while the song plays", sideways: -600, whilePlaying: true),
    ]

    private func dragTimelineForAgent() async {
        let refusal = "could not drag the timeline: "
        // The beats are drawn in every row, so the drags wait for them.
        for _ in 0..<240 where store.project.grid == nil || beatsAreBeingFound() {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil, store.project.grid != nil
        else { return Self.tellAgentAboutDrag(refusal + "the song is not ready") }
        #if DEBUG
        addTestClips()
        #endif
        // Zoomed in, about eight times, around the playhead at the start.
        for _ in 0..<5 {
            perform(.zoomIn)
        }
        try? await Task.sleep(for: .seconds(2))
        let inUse = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Measuring how the timeline follows a drag"
        )
        defer { ProcessInfo.processInfo.endActivity(inUse) }
        let clipCount = store.project.tracks.reduce(0) { $0 + $1.clips.count }
        let isVisible = NSApplication.shared.windows.contains { $0.occlusionState.contains(.visible) }
        Self.tellAgentAboutDrag(
            "will drag the timeline with \(clipCount) clips on \(store.project.tracks.count) tracks, "
                + String(format: "%.0f points a second, ", scale.pointsPerSecond)
                + "window \(isVisible ? "visible" : "hidden")"
        )
        for drag in Self.measuredDrags {
            if drag.whilePlaying, !windowState.content.isPlaying {
                perform(.playStop)
            }
            try? await Task.sleep(for: .seconds(1.5))
            guard let line = await measure(drag) else {
                return Self.tellAgentAboutDrag(refusal + "no timeline took the middle button")
            }
            Self.tellAgentAboutDrag("dragged \(drag.name): " + line)
        }
        if windowState.content.isPlaying {
            perform(.playStop)
        }
    }

    /// Makes one drag and says how the timeline kept up. Nil when no timeline took the press.
    private func measure(_ drag: MeasuredDrag) async -> String? {
        guard drag.isTrackpad || TimelineMiddleDrag.press() else { return nil }
        let pointsPerSecond = scale.pointsPerSecond
        let startOffset = scale.scrollOffsetSeconds
        let watch = MainThreadWatch()
        let commits = CommitWatch()
        let frames = FrameTicker()
        var frameTimes: [ContinuousClock.Instant] = []
        frames.onFrame = { frameTimes.append(.now) }
        frames.start()
        let feed = DragFeed()
        var fed: [(made: ContinuousClock.Instant, fedAt: ContinuousClock.Instant, took: Duration)] = []
        var pointerWidth: Double = 0
        // When the timeline was told of the moves: once per display frame for the middle button, which adds
        // them up (`TimelineScrollCatcher`), at once for the trackpad.
        var told: [ContinuousClock.Instant] = []
        TimelineMiddleDrag.timelineWasTold = { told.append(.now) }
        defer { TimelineMiddleDrag.timelineWasTold = nil }
        let started = ContinuousClock.now
        feed.onMoves = { distance, firstMade in
            let before = ContinuousClock.now
            if drag.isTrackpad {
                _ = TimelineMiddleDrag.scroll(sideways: distance.width)
            } else {
                TimelineMiddleDrag.move(by: distance)
            }
            let after = ContinuousClock.now
            if drag.isTrackpad {
                told.append(after)
            }
            fed.append((firstMade, before, after - before))
            pointerWidth += Double(distance.width)
        }
        let path = DragFeed.Path(
            sideways: drag.sideways, upOrDown: drag.upOrDown, waver: drag.waver,
            rate: drag.rate, seconds: drag.seconds
        )
        let made = await feed.run(path)
        if !drag.isTrackpad {
            TimelineMiddleDrag.release()
        }
        let ended = ContinuousClock.now
        // The last moves are drawn in the frames after.
        try? await Task.sleep(for: .milliseconds(200))
        frames.stop()
        watch.stop()
        commits.stop()

        // A turn of the main thread's run loop ends either in a rest or, while events keep coming, in leaving
        // the loop to take the next one up. The window is laid out and drawn at both.
        let turnEnds = commits.moments(after: started)
        // A move is drawn at the end of the turn in which the timeline was first told of it after it arrived.
        let drawn = fed.compactMap { move -> (move: ContinuousClock.Instant, told: ContinuousClock.Instant, drawn: Int)? in
            guard let toldAt = told.first(where: { $0 >= move.fedAt }),
                  let turn = turnEnds.firstIndex(where: { $0 >= toldAt })
            else { return nil }
            return (move.made, toldAt, turn)
        }
        let lags = drawn.map { turnEnds[$0.drawn] - $0.move }.sorted()
        let works = drawn.map { turnEnds[$0.drawn] - $0.told }.sorted()
        let drawnTurns = Set(drawn.map(\.drawn)).count
        let tooks = fed.map(\.took)
        let duringDrag = frameTimes.filter { $0 <= ended }
        let gaps = zip(duringDrag.dropFirst(), duringDrag).map { $0 - $1 }
        let screen = NSApp.windows.first { $0.isVisible }?.screen ?? NSScreen.main
        let displayRate = Double(screen?.maximumFramesPerSecond ?? 60)
        let length = ended - started
        let work = watch.allWork(after: started, before: ended)
        let movedSeconds = scale.scrollOffsetSeconds - startOffset
        let pointerSeconds = pointsPerSecond > 0 ? -pointerWidth / pointsPerSecond : 0

        func ms(_ duration: Duration) -> String {
            String(format: "%.1f", Self.milliseconds(duration))
        }
        func percentile(_ list: [Duration], _ share: Double) -> Duration {
            guard !list.isEmpty else { return .zero }
            return list[min(Int(Double(list.count) * share), list.count - 1)]
        }
        let average = tooks.isEmpty ? Duration.zero : tooks.reduce(.zero, +) / tooks.count
        return "\(made) moves made, \(fed.count) reached the catcher, the timeline was told \(told.count) times and drawn \(drawnTurns) times with them, "
            + "taking \(ms(average)) ms on average and \(ms(tooks.max() ?? .zero)) ms at the longest; "
            + "a drawing took \(ms(percentile(works, 0.5))) ms in the middle, \(ms(works.last ?? .zero)) ms at the longest; "
            + "lag to the window drawn \(ms(percentile(lags, 0.5))) ms in the middle, "
            + "\(ms(percentile(lags, 0.95))) ms for 95 in 100, \(ms(lags.last ?? .zero)) ms at the longest; "
            + "\(duringDrag.count) frames of \(Int((Self.milliseconds(length) / 1_000 * displayRate).rounded())), "
            + "\(ms(gaps.max() ?? .zero)) ms the longest gap; "
            + String(format: "the main thread worked %.0f %% of the time, ", Self.milliseconds(work) / Self.milliseconds(length) * 100)
            + "\(ms(watch.longestWork(after: started, before: ended))) ms at the longest; "
            + String(format: "moved %.3f s along the song, the pointer %.3f s", movedSeconds, pointerSeconds)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static let dragLog = Logger(subsystem: "se.maxfahl.lockstep", category: "EditTiming")

    /// One line on standard error, for the agent that started Lockstep, and in the Mac's log.
    private static func tellAgentAboutDrag(_ line: String) {
        FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
        dragLog.notice("\(line, privacy: .public)")
    }
}

/// The made-up mouse of `-middleDrag`: a clock on a thread of its own makes the pointer's moves at the
/// mouse's rate, whatever the main thread is doing, and they are handed to `onMoves` on the main thread.
/// Moves made while the main thread had no time wait and are handed over as one, summed, with the moment
/// the first of them was made.
@MainActor
final class DragFeed {
    /// Where the pointer goes: straight on at a speed, sideways and up or down, in points a second, with a
    /// waver up and down, its reports `rate` times a second for `seconds`.
    struct Path: Sendable {
        var sideways: Double
        var upOrDown: Double
        var waver: Double
        var rate: Double
        var seconds: Double

        /// Where the pointer is, from where it started, so long after the start.
        func place(at time: Double) -> CGSize {
            CGSize(
                width: sideways * time,
                height: upOrDown * time + waver * sin(2 * .pi * 3 * time)
            )
        }
    }

    var onMoves: ((CGSize, ContinuousClock.Instant) -> Void)?

    /// What was made and not handed over yet, kept behind a lock: the clock's thread adds to it.
    private final class Waiting: Sendable {
        struct Moves {
            var distance = CGSize.zero
            var firstMade: ContinuousClock.Instant?
            var isHandingOver = false
        }

        let moves = Mutex(Moves())
    }

    private let waiting = Waiting()

    /// Makes the moves of a path and hands them over, and returns how many moves were made when the last
    /// one has been handed over.
    func run(_ path: Path) async -> Int {
        let count = Int((path.seconds * path.rate).rounded())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Self.startClock(path, count: count, waiting: waiting, handOver: { [weak self] in
                self?.handOver()
            }, done: { done.resume() })
        }
        handOver()
        return count
    }

    /// Takes everything that waits and hands it to `onMoves`.
    private func handOver() {
        let moves = waiting.moves.withLock { moves in
            defer { moves = Waiting.Moves() }
            return moves
        }
        guard let first = moves.firstMade, moves.distance != .zero else { return }
        onMoves?(moves.distance, first)
    }

    /// The clock, made outside the main actor as every block the system calls is. It runs on a queue of
    /// its own and touches only what the lock protects; it reaches the main thread through its run loop,
    /// in every mode, the way events do.
    private nonisolated static func startClock(
        _ path: Path,
        count: Int,
        waiting: Waiting,
        handOver: @escaping @MainActor @Sendable () -> Void,
        done: @escaping @Sendable () -> Void
    ) {
        let queue = DispatchQueue(label: "se.maxfahl.lockstep.dragfeed", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let state = Mutex((made: 0, last: CGSize.zero))
        timer.schedule(deadline: .now(), repeating: 1 / path.rate, leeway: .microseconds(100))
        timer.setEventHandler { @Sendable in
            let (index, step) = state.withLock { state -> (Int, CGSize) in
                state.made += 1
                let place = path.place(at: Double(state.made) / path.rate)
                let step = CGSize(width: place.width - state.last.width, height: place.height - state.last.height)
                state.last = place
                return (state.made, step)
            }
            let needsHandOver = waiting.moves.withLock { moves in
                moves.distance.width += step.width
                moves.distance.height += step.height
                if moves.firstMade == nil {
                    moves.firstMade = .now
                }
                defer { moves.isHandingOver = true }
                return !moves.isHandingOver
            }
            if needsHandOver {
                let main = CFRunLoopGetMain()
                CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { @Sendable in
                    MainActor.assumeIsolated { handOver() }
                }
                CFRunLoopWakeUp(main)
            }
            if index >= count {
                timer.cancel()
                done()
            }
        }
        timer.resume()
    }
}

/// Notes the end of every turn of the main thread's run loop: when it goes to rest, and when it leaves the
/// loop to take up the next event. AppKit lays out, draws and hands the window to the screen at both, so for
/// `-middleDrag` these are the moments the window can show a move.
@MainActor
final class CommitWatch {
    private final class Seen: Sendable {
        let moments = Mutex<[ContinuousClock.Instant]>([])
    }

    private let seen = Seen()
    private let observer: CFRunLoopObserver

    init() {
        observer = Self.makeObserver(telling: seen)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Made outside the main actor, as every block the system calls is, and touching only what the lock
    /// protects. It runs after everything else at those moments, the drawing of the window included.
    private nonisolated static func makeObserver(telling seen: Seen) -> CFRunLoopObserver {
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        return CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { @Sendable _, _ in
            let now = ContinuousClock.now
            seen.moments.withLock { $0.append(now) }
        }
    }

    func stop() {
        CFRunLoopObserverInvalidate(observer)
    }

    func moments(after moment: ContinuousClock.Instant) -> [ContinuousClock.Instant] {
        seen.moments.withLock { moments in moments.filter { $0 >= moment } }
    }
}

extension TimelineViewModel {
    // MARK: A project opens

    /// A song or a project is about to be shown in place of what was open, and the store has not
    /// opened it yet: a move of the timeline that is under way stops, and the timeline takes the
    /// zoom and the place the project was left with. Gives back how the project was last shown
    /// (its `view.json`), or nil for a new song and for a project that has none.
    func projectWillOpen(in package: ProjectPackage) -> ProjectView? {
        stopGlide()
        // A project opened again comes back as it was left; a new song fits the window.
        let keptView = package.readView()
        moveScale(to: TimelineScale(
            pointsPerSecond: keptView?.pointsPerSecond ?? 0,
            scrollOffsetSeconds: keptView?.scrollOffsetSeconds ?? 0
        ))
        return keptView
    }

    /// The store has opened the project: the rest of its kept view comes back (`restore`), and
    /// its view is kept from now on.
    func projectOpened(in package: ProjectPackage, with keptView: ProjectView?) {
        if let keptView {
            restore(keptView)
        }
        keepView(of: package, openedWith: keptView)
    }
}

extension AppModel {
    /// Gives `timelineView` its closures. `wire()` calls it once, when every part is made.
    func wireTimelineView() {
        timelineView.seek = { [weak self] seconds in self?.transport.seek(to: seconds) ?? false }
        timelineView.perform = { [weak self] command in self?.perform(command) }
        #if DEBUG
        timelineView.addTestClips = { [weak self] in self?.clipEditing.addTestClips() }
        #endif
        timelineView.beatsAreBeingFound = { [weak self] in self?.beats.beatFinding != nil }
    }
}

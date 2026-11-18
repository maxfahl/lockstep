import AppKit
import LockstepCore
import LockstepUI
import QuartzCore
import SwiftUI

// Measuring how fast the window draws.
//
//     open -g -n "Lockstep Design.app" --args -state Stress \
//         -measureOutput /some/file.txt -measure
//
// - `-state Stress` shows the state with the heavy content: 12 tracks and
//   200 clips (`StressState.swift`). Any state that shows the whole window
//   (`LabMainLayout`) can be measured.
// - `-measure` plays the script below, prints the figures, writes them to the
//   file after `-measureOutput` and quits the app.
//
// The script takes 17 seconds: the playhead moves at playing speed the whole
// time, first with nothing else happening, then while the timeline zooms from
// the whole song to the closest zoom and back, then while it scrolls sideways
// from the start of the song to its end.
//
// A frame time is the time from one frame to the next, taken from the screen's
// own frame clock. It is always a whole number of screen frames, so on a
// 240 Hz screen it is 4.2 ms, 8.3 ms, 12.5 ms and so on. A part of the window
// has to be in view. If the window is covered completely, the run moves it to
// a corner of a screen where a part shows; the result says whether one did.

/// What the launch arguments ask of the lab.
enum LabArguments {
    /// The name after `-state`: the design state shown first. It may hold
    /// spaces, as in `-state "Clip selected"`.
    static let stateName = value(after: "-state")
    static let isMeasuring = ProcessInfo.processInfo.arguments.contains("-measure")
    static let measureOutput = value(after: "-measureOutput")

    private static func value(after name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

/// One measured run: it plays the script, keeps the time of every frame and
/// quits the app with the figures.
@MainActor
final class MeasureRun: NSObject {
    /// The parts of the script, in order.
    private enum Phase: String, CaseIterable {
        case playing = "playing only"
        case zoomIn = "zoom in"
        case zoomOut = "zoom out"
        case scroll = "scroll"

        var seconds: Double {
            self == .playing ? 2 : 5
        }
    }

    /// The window is given this size, so every run draws the same amount.
    private static let windowSize = NSSize(width: 1200, height: 720)
    /// The zoom of the scroll part: a clip of four seconds is 240 points wide,
    /// so its bar shows its name.
    private static let scrollPointsPerSecond: Double = 60
    /// The target: a frame every 16.7 ms.
    private static let targetMilliseconds = 16.7
    /// A run that has not finished by then gives up and says why. The whole
    /// run is 19 seconds, or up to 23 when the window has to be moved first.
    private static let giveUpAfterSeconds: Double = 27

    /// The run in progress. It is kept here so it lives until the app quits.
    private static var current: MeasureRun?

    /// Starts the run on the window whose zoom, playhead and content these
    /// are. `LabMainLayout` calls it after `-measure`.
    static func start(scale: Binding<TimelineScale>, playhead: PlayheadPosition, content: TimelineContent) {
        guard current == nil else { return }
        let run = MeasureRun(scale: scale, playhead: playhead, content: content)
        current = run
        run.prepare()
    }

    /// After `-measure` with a state that does not show the whole window,
    /// nothing starts a run. This says so in the output file and quits,
    /// instead of leaving the app open and the caller waiting.
    static func giveUpUnlessStarted() async {
        try? await Task.sleep(for: .seconds(3))
        guard current == nil else { return }
        let text = "state: \(stateName)\nfailed: this state has no timeline to measure.\n"
        print(text, terminator: "")
        if let path = LabArguments.measureOutput {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        exit(1)
    }

    /// The name of the state that is measured, for the output.
    private static var stateName: String {
        LabArguments.stateName ?? LabState.all[0].name
    }

    private let scale: Binding<TimelineScale>
    private let playhead: PlayheadPosition
    private let content: TimelineContent

    private var window: NSWindow?
    /// Where the window was before the run, to put it back at the end.
    private var frameBeforeRun: NSRect?
    private var link: CADisplayLink?
    private var idleObserver: CFRunLoopObserver?
    /// The zoom that shows the whole song, and the width of the rows.
    private var fitPointsPerSecond: Double = 0
    private var bodyWidth: Double = 0

    private var firstTimestamp: Double?
    private var previousTimestamp: Double = 0
    private var previousPhase: Phase = .playing
    /// When the frame being worked on began, until the app is idle again.
    private var frameBegan: Double?
    private var frameTimes: [(phase: Phase, seconds: Double)] = []
    private var workTimes: [(phase: Phase, seconds: Double)] = []
    /// The time of day the script began, so a profile taken from outside can
    /// be matched to the parts of the script.
    private var scriptBegan = Date()
    private var wasVisibleAtStart = false
    private var isFinished = false

    private init(scale: Binding<TimelineScale>, playhead: PlayheadPosition, content: TimelineContent) {
        self.scale = scale
        self.playhead = playhead
        self.content = content
    }

    // MARK: Before the script

    private func prepare() {
        Task {
            try? await Task.sleep(for: .seconds(Self.giveUpAfterSeconds))
            giveUp("the run did not finish in \(Int(Self.giveUpAfterSeconds)) seconds, after \(frameTimes.count) frames. The window is probably hidden completely behind other windows.")
        }
        Task {
            // The window needs a moment to appear, and the timeline another
            // one to fit the song to its new width.
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: \.isVisible) else {
                giveUp("the app has no window on screen.")
                return
            }
            self.window = window
            frameBeforeRun = window.frame
            window.setContentSize(Self.windowSize)
            guard await moveIntoView(window) else {
                giveUp("no part of the window can be seen. Uncover a corner of a screen and run it again.")
                return
            }
            scale.wrappedValue = TimelineScale(pointsPerSecond: 0)
            try? await Task.sleep(for: .seconds(1))

            fitPointsPerSecond = scale.wrappedValue.pointsPerSecond
            bodyWidth = fitPointsPerSecond * content.songLength
            guard fitPointsPerSecond > 0, content.songLength > 0 else {
                giveUp("this state has no timeline to measure.")
                return
            }
            wasVisibleAtStart = window.occlusionState.contains(.visible)

            let idleObserver = Self.makeIdleObserver()
            CFRunLoopAddObserver(CFRunLoopGetMain(), idleObserver, .commonModes)
            self.idleObserver = idleObserver
            let link = window.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    /// Makes sure a part of the window can be seen. The app is started behind
    /// the other windows, and macOS slows a window down to a couple of frames
    /// a second while it is covered completely, which would make the figures
    /// worthless. A covered window is tried in each corner of each screen
    /// until a part of it shows. It stays behind the other windows.
    private func moveIntoView(_ window: NSWindow) async -> Bool {
        if window.occlusionState.contains(.visible) {
            return true
        }
        let screens = [window.screen].compactMap { $0 } + NSScreen.screens.filter { $0 != window.screen }
        for screen in screens {
            let area = screen.visibleFrame
            let size = window.frame.size
            for x in [area.maxX - size.width, area.minX] {
                for y in [area.minY, area.maxY - size.height] {
                    window.setFrameOrigin(NSPoint(x: x, y: y))
                    // macOS needs a moment to notice what covers the window.
                    try? await Task.sleep(for: .milliseconds(400))
                    if window.occlusionState.contains(.visible) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Tells the run each time the app has finished its work for a frame and
    /// goes idle, which gives the time the app itself spent on the frame.
    private nonisolated static func makeIdleObserver() -> CFRunLoopObserver {
        CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { @Sendable _, _ in
            MainActor.assumeIsolated {
                MeasureRun.current?.frameWorkEnded()
            }
        }
    }

    private func frameWorkEnded() {
        guard let began = frameBegan else { return }
        workTimes.append((previousPhase, CACurrentMediaTime() - began))
        frameBegan = nil
    }

    // MARK: The script

    @objc private func frame(_ link: CADisplayLink) {
        guard !isFinished else { return }
        let now = link.timestamp
        guard let first = firstTimestamp else {
            firstTimestamp = now
            previousTimestamp = now
            scriptBegan = Date()
            return
        }
        // The time since the frame before belongs to what that frame showed.
        frameTimes.append((previousPhase, now - previousTimestamp))
        previousTimestamp = now
        frameBegan = CACurrentMediaTime()

        var elapsed = now - first
        playhead.seconds = content.playheadTime + elapsed
        for phase in Phase.allCases {
            if elapsed < phase.seconds {
                previousPhase = phase
                show(phase, progress: elapsed / phase.seconds)
                return
            }
            elapsed -= phase.seconds
        }
        finish()
    }

    private func show(_ phase: Phase, progress: Double) {
        var next: TimelineScale
        switch phase {
        case .playing:
            return
        case .zoomIn:
            next = zoomed(by: progress)
        case .zoomOut:
            next = zoomed(by: 1 - progress)
        case .scroll:
            let secondsOnScreen = bodyWidth / Self.scrollPointsPerSecond
            next = TimelineScale(
                pointsPerSecond: Self.scrollPointsPerSecond,
                scrollOffsetSeconds: progress * (content.songLength - secondsOnScreen)
            )
        }
        // Kept inside the song here, so the timeline does not have to correct
        // it with a second update in the same frame.
        next.clamp(range: 0...content.songLength, viewWidth: bodyWidth)
        if next != scale.wrappedValue {
            scale.wrappedValue = next
        }
    }

    /// The zoom at a point between the whole song (0) and the closest zoom
    /// (1), in even steps for the eye, with the playhead a third of the way in
    /// from the left so it stays on screen.
    private func zoomed(by amount: Double) -> TimelineScale {
        let closest = TimelineScale.maximumPointsPerSecond
        let pointsPerSecond = fitPointsPerSecond * pow(closest / fitPointsPerSecond, amount)
        return TimelineScale(
            pointsPerSecond: pointsPerSecond,
            scrollOffsetSeconds: playhead.seconds - bodyWidth / 3 / pointsPerSecond
        )
    }

    // MARK: The result

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        link?.invalidate()

        let all = frameTimes.map(\.seconds)
        guard let first = firstTimestamp, !all.isEmpty else {
            giveUp("no frame was drawn.")
            return
        }
        let isVisible = wasVisibleAtStart && (window?.occlusionState.contains(.visible) ?? false)
        let size = window?.contentLayoutRect.size ?? .zero
        let framesPerSecond = window?.screen?.maximumFramesPerSecond ?? 0
        var lines = [
            "state: \(Self.stateName)",
            "content: \(content.trackRows.count) tracks, "
                + "\(content.trackRows.reduce(0) { $0 + $1.clips.count }) clips, \(Int(content.songLength)) s",
            "window: \(Int(size.width)) x \(Int(size.height)), on screen: \(isVisible ? "yes" : "NO, the figures are not real"), "
                + "screen: \(framesPerSecond) Hz",
            "frames: \(all.count) in \(Self.text(previousTimestamp - first, digits: 1)) s, "
                + "begun at \(scriptBegan.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(1))))",
            "frame time, whole run: \(Self.summary(of: all))",
        ]
        for phase in Phase.allCases {
            let times = frameTimes.filter { $0.phase == phase }.map(\.seconds)
            lines.append("frame time, \(phase.rawValue): \(Self.summary(of: times))")
        }
        // The app's own share of each frame: from the start of a frame until
        // the app has nothing left to do for it.
        lines.append("app's own work per frame, whole run: \(Self.summary(of: workTimes.map(\.seconds)))")
        for phase in Phase.allCases {
            let times = workTimes.filter { $0.phase == phase }.map(\.seconds)
            lines.append("app's own work per frame, \(phase.rawValue): \(Self.summary(of: times))")
        }
        write(lines.joined(separator: "\n") + "\n")
        leaveWindowAsFound()
        NSApp.terminate(nil)
    }

    /// "worst 12.5 ms, 95th percentile 4.2 ms, within 16.7 ms: 100.0 %"
    private static func summary(of seconds: [Double]) -> String {
        guard !seconds.isEmpty else { return "no frames" }
        let sorted = seconds.sorted()
        let worst = sorted[sorted.count - 1] * 1000
        // The smallest time that 95 % of the frames stay within.
        let percentile = sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1] * 1000
        let within = Double(sorted.count { $0 * 1000 <= targetMilliseconds }) / Double(sorted.count) * 100
        return "worst \(text(worst, digits: 1)) ms, 95th percentile \(text(percentile, digits: 1)) ms, "
            + "within \(targetMilliseconds) ms: \(text(within, digits: 1)) %"
    }

    private static func text(_ number: Double, digits: Int) -> String {
        number.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    private func giveUp(_ reason: String) {
        guard !isFinished else { return }
        isFinished = true
        link?.invalidate()
        write("state: \(Self.stateName)\nfailed: \(reason)\n")
        leaveWindowAsFound()
        exit(1)
    }

    /// macOS remembers where a window was when the app quit. The run may have
    /// moved and resized it, so it is put back first.
    private func leaveWindowAsFound() {
        if let window, let frameBeforeRun {
            window.setFrame(frameBeforeRun, display: false)
        }
    }

    private func write(_ text: String) {
        print(text, terminator: "")
        if let path = LabArguments.measureOutput {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

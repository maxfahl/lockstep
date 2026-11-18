import AppKit
import Foundation
import Synchronization

/// A stopwatch for one edit: how long after it was started each step of the edit was done, when the window
/// had been drawn with the result, and how long the main thread went on working afterwards.
/// `ClipEditingModel.editTiming` holds one while an edit is timed, and `followClips` marks its steps there.
///
///     let timing = EditTiming()
///     editTiming = timing
///     perform(.delete)                 // `followClips` marks its steps on the way
///     timing.mark("Delete done")
///     editTiming = nil
///     await timing.report { await player.hasDoneItsOrders() }
///     // "project changed after 0.4 ms, ..., Delete done after 3.1 ms, window drawn after 30.2 ms, ..."
@MainActor
final class EditTiming {
    private let start: ContinuousClock.Instant
    private var marks: [(step: String, after: Duration)] = []
    private let watch = MainThreadWatch()

    /// - Parameter startedAgo: how long ago the edit was started, when that was before now: the age of the
    ///   key press that asked for it. Every step is then counted from the key press.
    init(startedAgo: Duration = .zero) {
        start = ContinuousClock.now - startedAgo
    }

    /// Notes that a step is done now.
    func mark(_ step: String) {
        marks.append((step, ContinuousClock.now - start))
    }

    /// Notes a step that was done some time ago.
    func mark(_ step: String, ago: Duration) {
        marks.append((step, ContinuousClock.now - ago - start))
    }

    /// How many steps were noted so far. An edit during which none was noted showed and changed nothing.
    var markCount: Int {
        marks.count
    }

    /// Stops the stopwatch without a report, for an edit that turned out to do nothing. Without it the watch
    /// of the main thread would stay switched on.
    func giveUp() {
        watch.stop()
    }

    /// Waits until the window has been drawn, the player has taken the edit over and a second more has
    /// passed, and gives every step with the milliseconds from the start, and how long the main thread
    /// worked in that last second: work there is the window standing still after the edit.
    ///
    /// - Parameter playerIsDone: waits until the player has done what the edit told it.
    func report(afterWaitingFor playerIsDone: () async -> Void) async -> String {
        let rested = await watch.nextRest()
        marks.append(("window drawn", rested - start))
        await playerIsDone()
        mark("player has the clips")
        try? await Task.sleep(for: .seconds(1))
        watch.stop()
        return marks.map { "\($0.step) after \(Self.milliseconds($0.after)) ms" }.joined(separator: ", ")
            + ". In the second after, the main thread worked "
            + "\(Self.milliseconds(watch.allWork(after: rested))) ms, "
            + "\(Self.milliseconds(watch.longestWork(after: rested))) ms at the longest"
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        return String(format: "%.1f", Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
    }
}

/// Notes when each key press was taken off the app's queue, so an edit that a key started can say how long
/// the key waited for the main thread, and how long the menu bar then took to choose its command.
///
/// A key press carries the moment the key went down. The app takes it up when the main thread is free, and
/// the menu bar then looks for the item that has the key and chooses it. `started()` gives both ages for the
/// press that is being handled right now.
@MainActor
final class KeyPressWatch {
    static let app = KeyPressWatch()

    /// The key press taken up last: the moment it carries, and when it was taken up, both in seconds on
    /// the clock of `ProcessInfo.systemUptime`.
    private var last: (pressed: TimeInterval, takenUp: TimeInterval)?
    private var monitor: Any?

    /// Starts noting key presses. They are handed on untouched.
    func start() {
        guard monitor == nil else { return }
        // AppKit calls this on the main thread, before the key reaches a window or the menu bar.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.last = (event.timestamp, ProcessInfo.processInfo.systemUptime)
            return event
        }
    }

    /// For a command that is being carried out right now: how long ago the key that started it went down,
    /// and how long ago the app took the key up. Nil when no key press is being handled, as when the command
    /// was chosen in a menu with the pointer.
    func started() -> (pressedAgo: Duration, takenUpAgo: Duration)? {
        guard let event = NSApplication.shared.currentEvent, event.type == .keyDown,
              let last, last.pressed == event.timestamp
        else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        // A press older than this is not what started the command.
        guard now >= last.pressed, now - last.pressed < 30 else { return nil }
        return (.seconds(now - last.pressed), .seconds(now - last.takenUp))
    }
}

/// Watches when the main thread works and when it rests, for `EditTiming`.
///
/// The window is laid out, drawn and handed to the screen at the end of a turn of the main thread's run
/// loop, just before the thread goes to rest. So the first rest after an edit is the moment the window
/// shows the edit, and a long stretch of work after it is a stretch in which the window does not answer.
///
///     let watch = MainThreadWatch()
///     // ... the edit ...
///     let rested = await watch.nextRest()        // the window has been drawn
///     try? await Task.sleep(for: .seconds(1))
///     watch.stop()
///     watch.longestWork(after: rested)           // the longest the window stood still afterwards
@MainActor
final class MainThreadWatch {
    /// What was seen, kept behind a lock: the system calls the observer without saying on which thread.
    private final class Seen: Sendable {
        private struct Notes {
            /// When the stretch of work that is going on started, or nil while the thread rests.
            var workStart: ContinuousClock.Instant? = ContinuousClock.now
            var work: [(start: ContinuousClock.Instant, length: Duration)] = []
            var waiting: [CheckedContinuation<ContinuousClock.Instant, Never>] = []
        }

        private let notes = Mutex(Notes())

        func note(_ activity: CFRunLoopActivity, at moment: ContinuousClock.Instant) {
            let resumed: [CheckedContinuation<ContinuousClock.Instant, Never>] = notes.withLock { notes in
                if activity == .afterWaiting {
                    notes.workStart = moment
                    return []
                }
                if let start = notes.workStart {
                    notes.work.append((start, moment - start))
                    notes.workStart = nil
                }
                defer { notes.waiting = [] }
                return notes.waiting
            }
            for continuation in resumed {
                continuation.resume(returning: moment)
            }
        }

        func nextRest() async -> ContinuousClock.Instant {
            await withCheckedContinuation { continuation in
                notes.withLock { $0.waiting.append(continuation) }
            }
        }

        func work(after moment: ContinuousClock.Instant) -> [Duration] {
            notes.withLock { notes in notes.work.filter { $0.start >= moment }.map(\.length) }
        }

        func stretches(after moment: ContinuousClock.Instant) -> [(start: ContinuousClock.Instant, length: Duration)] {
            notes.withLock { notes in notes.work.filter { $0.start >= moment } }
        }
    }

    private let seen = Seen()
    private let observer: CFRunLoopObserver

    /// Starts watching. The thread counts as working from now on, because the caller is.
    init() {
        observer = Self.makeObserver(telling: seen)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// The observer is made outside the main actor, as every block the system calls is: it runs on the main
    /// thread, but the system does not say so, and it touches only what the lock protects. It is asked to run
    /// after everything else that runs before a rest, the drawing of the window included.
    private nonisolated static func makeObserver(telling seen: Seen) -> CFRunLoopObserver {
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        return CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { @Sendable _, activity in
            seen.note(activity, at: ContinuousClock.now)
        }
    }

    /// Waits for the next time the main thread goes to rest, and gives the moment it did.
    func nextRest() async -> ContinuousClock.Instant {
        await seen.nextRest()
    }

    /// Stops watching.
    func stop() {
        CFRunLoopObserverInvalidate(observer)
    }

    /// The longest stretch the main thread worked without a rest, of those that started after a moment.
    func longestWork(after moment: ContinuousClock.Instant) -> Duration {
        seen.work(after: moment).max() ?? .zero
    }

    /// How long the main thread worked in all, in the stretches that started after a moment.
    func allWork(after moment: ContinuousClock.Instant) -> Duration {
        seen.work(after: moment).reduce(.zero, +)
    }

    /// How long the main thread worked in all, and the longest stretch, of the stretches that started
    /// between two moments. For `-middleDrag`, which measures while the drag goes on.
    func allWork(after moment: ContinuousClock.Instant, before end: ContinuousClock.Instant) -> Duration {
        seen.stretches(after: moment).filter { $0.start < end }.map(\.length).reduce(.zero, +)
    }

    func longestWork(after moment: ContinuousClock.Instant, before end: ContinuousClock.Instant) -> Duration {
        seen.stretches(after: moment).filter { $0.start < end }.map(\.length).max() ?? .zero
    }
}

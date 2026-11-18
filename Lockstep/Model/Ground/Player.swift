import LockstepAudio
import LockstepCore
import LockstepUI

/// The player: what plays the song, the click and the clips, and the line of everything it is
/// told to do.
///
/// The player works away from the main thread, so the order is kept here: each thing it is told
/// waits for the one before it (`tell`). When nothing is left to do, `nothingLeft` is called,
/// which is when the window is brought in line with the player. While something is still to do
/// (`ordersInFlight`), what the player says about itself is old.
///
/// It is ground: `AppModel` makes one, and every part that plays, records or changes what is
/// heard is handed it.
@MainActor
final class Player {
    /// The player itself, for the few calls that go past the line because they act at once: the
    /// click's switch and volume, a sound played once, and the click handed over when it has
    /// been laid out. Everything that has to keep its order goes through `tell`.
    let engine = PlaybackEngine(silent: LaunchOptions.current.isSilent)
    /// Calls its `onFrame` once per display frame while the song plays.
    let frames = FrameTicker()
    /// Everything the player was told, in order.
    private let line = OrderLine()

    /// Called when the player has done everything it was told and nothing is left to do.
    var nothingLeft: (@MainActor () -> Void)? {
        get { line.nothingLeft }
        set { line.nothingLeft = newValue }
    }

    /// - Parameter windowState: where the alert goes when the player could not do what it was told.
    init(windowState: WindowState) {
        line.orderFailed = { [windowState] _ in
            windowState.showAlert(
                MessageAlert(
                    title: "Lockstep could not play the song.",
                    detail: "Check that the Mac has a sound output, then try again."
                )
            )
        }
    }

    /// How many things the player was told and has not done yet.
    var ordersInFlight: Int { line.ordersInFlight }

    /// Hands the player something to do. The player works away from the main thread,
    /// so the order is kept here: each thing waits for the one before it. When the
    /// player has nothing left to do, the window is brought in line with it.
    func tell(_ order: @escaping @Sendable (PlaybackEngine) async throws -> Void) {
        // Counted for `Scripts/same-behaviour.sh` (`RunCounts`). Keep this line with `tell` when it moves.
        RunCounts.shared.playerTold()
        line.tell { [engine] in try await order(engine) }
    }

    /// Waits until the player has done everything it was told so far.
    func hasDoneItsOrders() async {
        await line.allDone()
    }

    /// Where the player is and whether it plays, right now. It never waits.
    func snapshot() -> PlaybackSnapshot {
        engine.snapshot()
    }

    /// Takes a turn in line with everything else the player is told, for work that needs the
    /// player (and the microphone) to itself and has something to say when it is over: the
    /// start, the restart and the end of a take, and the measuring of the delay.
    ///
    /// The work starts when everything the player was told before is done. When it is over it
    /// is counted as done, and then its result is handed to `beforeNothingLeft`, `nothingLeft`
    /// is called if nothing else waits, and its result is handed to `afterNothingLeft`, all in
    /// one go. See `OrderLine.turn`, which this is.
    ///
    /// - Returns: The turn's own task. What `afterNothingLeft` gives back is what it gives, and
    ///   cancelling it reaches the work.
    @discardableResult
    func takeTurn<Found: Sendable, Given: Sendable>(
        _ work: @escaping @MainActor () async -> Found,
        beforeNothingLeft: @escaping @MainActor (Found) -> Void = { _ in },
        afterNothingLeft: @escaping @MainActor (Found) -> Given
    ) -> Task<Given, Never> {
        line.turn(work, beforeNothingLeft: beforeNothingLeft, afterNothingLeft: afterNothingLeft)
    }
}

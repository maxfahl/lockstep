import LockstepCore
import LockstepUI
import Observation

/// The loop: the stretch that repeats while Loop is on, and its in and out.
///
/// It is written from several sides (the loop commands, a cut of the song, the view's memory,
/// opening a project), so it belongs to none of them. Whoever writes it, the window and the
/// player follow from here.
///
/// It is ground: `AppModel` makes one, and every part that reads or changes the loop is handed
/// it.
@MainActor
@Observable
final class LoopState {
    /// The window, which shows the loop in the ruler and on the Loop button.
    @ObservationIgnored private let windowState: WindowState
    /// The player, which loops the stretch.
    @ObservationIgnored private let player: Player

    /// Says whether the stretch of a take is going round right now (a take's Play button with
    /// Loop on). The player then keeps that stretch, and is not told of a new loop until the
    /// stretch is over.
    @ObservationIgnored var takesStretchGoesRound: () -> Bool = { false }

    /// The stretch of the song that repeats while Loop is on, or nil while Loop is off. Only the
    /// loop commands change it (Loop, Set Loop In and Out, Clear Loop In and Out, in
    /// `LoopModel`), so selecting, Escape and Delete leave a
    /// loop alone. The Loop button and the ruler show it, and the player loops it. It is not
    /// part of the project and is not saved. While it is set, the in and out are its ends.
    var region: LoopRegion? {
        didSet {
            guard region != oldValue else { return }
            if windowState.content.isLooping != (region != nil) { windowState.content.isLooping = region != nil }
            windowState.content.timeline.dragging.loopRange = region?.range
            if let region {
                inOut = LoopInOut(inTime: region.start, outTime: region.end)
            }
            // While a take's stretch goes round, the player keeps that stretch.
            guard !takesStretchGoesRound() || region == nil else { return }
            let loop = region
            player.tell { await $0.setLoop(loop) }
        }
    }
    /// The loop's in and out, or nil when neither is set: what Loop plays, and while Loop is
    /// off what the ruler shows of it. Only the loop commands change it, and a cut of the
    /// song (`keepLoopAndStretch`); Option+X takes it away. It is kept in `view.json`.
    var inOut: LoopInOut? {
        didSet {
            guard inOut != oldValue else { return }
            windowState.content.timeline.dragging.loopInOut = inOut
        }
    }

    init(windowState: WindowState, player: Player) {
        self.windowState = windowState
        self.player = player
    }
}

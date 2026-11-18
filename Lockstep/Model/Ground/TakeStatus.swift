import LockstepCore
import LockstepUI
import Observation

/// Whether a take is going, and how far it has come.
///
/// Most edits and commands ask it before they act: while a take is going nothing else may
/// change the project or move the song. Only the code that records writes it.
///
/// It is ground: `AppModel` makes one, and every part that must know of a take is handed it.
@MainActor
@Observable
final class TakeStatus {
    /// Where the take that is going was started from, and how far it has come. It also
    /// says whether Record, a restart and Stop may act right now. The menus read
    /// its phase, and the window shows it: Record is lit while running up and while recording.
    var flow = TakeFlow() {
        didSet {
            guard flow.phase != oldValue.phase else { return }
            phaseChanged?()
        }
    }
    /// How far the take has come, or nil when no take is going.
    var phase: TakePhase? { flow.phase }

    /// Called when `phase` has changed, with the new phase already in place: the code that
    /// records then lets the window follow (the Record button's light, the mark on the track,
    /// the empty meter).
    @ObservationIgnored var phaseChanged: (() -> Void)?

    /// Where the last take started in the song, in song seconds: the place Record aimed at, not
    /// the start of its count-in. Nil until a take was started in the open project. Go Back
    /// (`goBack`) moves the playhead there.
    @ObservationIgnored var lastTakeStart: Double?

    /// How far the take that is being recorded has come. Only the red clip on the track reads
    /// it, so changing it on every frame draws nothing else again. The code that records
    /// writes it, and the code that shows the clips hands it to the red clip.
    @ObservationIgnored let progress = RecordingProgress()

    /// The ending of the take that is being finished: what was recorded is being made into
    /// clips. Quit waits for it, and so does everything an agent's launch arguments do to the
    /// clips (the sound files of `-addTake` are added as such an ending).
    @ObservationIgnored var ending: Task<Void, Never>?

    /// Waits until the take that is being finished has become clips. Returns at once when
    /// none is.
    func ended() async {
        await ending?.value
    }
}

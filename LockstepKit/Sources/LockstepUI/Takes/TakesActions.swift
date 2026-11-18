import SwiftUI

/// What the take count on a clip and the takes list in the panel on the right
/// tell their owner.
///
/// The design lab leaves it out: there the count and the list are pictures and
/// nothing in them works. The real app hands one to `MainLayout` in
/// `MainLayoutActions.takes`.
///
///     var takes = TakesActions()
///     takes.countPressed = { clipID in model.selectClip(withTakeCount: clipID) }
///     takes.rowPressed = { number in model.chooseTake(number) }
///     takes.playPressed = { number in model.playOrStopTake(number) }
///     takes.deleteOtherTakesPressed = { model.deleteOtherTakes() }
///     actions.takes = takes
public struct TakesActions {
    /// The take count in the bar of the clip with this id ("3/5") was pressed.
    /// The owner selects that clip, so its takes show in the panel on the
    /// right. `MainLayout` opens the panel when it is hidden.
    public var countPressed: (@MainActor (UUID) -> Void)?

    /// A take's row in the list was clicked, beside its Play button: the
    /// take's number, counted from 1. The owner makes it the chosen take.
    public var rowPressed: (@MainActor (Int) -> Void)?

    /// The Play button of a take was pressed, while it shows the play symbol
    /// or the stop symbol: the take's number, counted from 1. The owner plays
    /// that take with the song, or stops it, and says which take plays in
    /// `TakeRow.isPlaying`.
    public var playPressed: (@MainActor (Int) -> Void)?

    /// "Delete Other Takes" was pressed in the list.
    public var deleteOtherTakesPressed: (@MainActor () -> Void)?

    public init() {}
}

extension EnvironmentValues {
    /// Who is told when a clip's take count is pressed.
    /// `MainLayout` sets it when its owner listens for the takes
    /// (`MainLayoutActions.takes`), so the timeline between the window and the
    /// clip need not know about takes. Nil everywhere else, which leaves the
    /// take count a button that does nothing.
    @Entry var takeCountListener: TakeCountListener?
}

/// Who is told when a clip's take count is pressed: the id of the clip.
///
/// It is an object and not the closure itself, because the closure is made
/// anew every time the window is worked out. A new closure in the environment
/// looks like a change to every view that reads it, and every track's row
/// would then be worked out again after every edit. The object stays the
/// same, and what it tells is read when the count is pressed.
@MainActor
final class TakeCountListener {
    var pressed: (@MainActor (UUID) -> Void)?
}

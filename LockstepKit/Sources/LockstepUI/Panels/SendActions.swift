import Foundation

/// What the Send to DaVinci button and panel tell their owner. The owner answers by changing
/// `MainLayoutContent.send`, which is what the panel shows, and by taking it away to close the panel:
///
///     var send = SendActions()
///     send.buttonPressed = { model.openSendPanel() }
///     send.copyPressed = { clipID in model.copySendTimecode(of: clipID) }
///     send.fileToDrag = { clipID in model.sendFileOnDisk(of: clipID) }
///     send.closed = { model.closeSendPanel() }
///     actions.send = send
///
/// The layout itself exports nothing and keeps nothing. Without these the button does nothing and no panel is
/// opened, as in the design lab.
public struct SendActions {
    /// The Send to DaVinci button in the panel on the right was pressed.
    public var buttonPressed: (@MainActor () -> Void)?

    /// Copy was pressed beside the timecode of this clip (`SendContent.Clip.id`).
    public var copyPressed: (@MainActor (UUID) -> Void)?

    /// Show in Finder was pressed. It is about every exported file the panel shows.
    public var showInFinderPressed: (@MainActor () -> Void)?

    /// Asked for the exported file of this clip (`SendContent.Clip.id`) at the moment a drag of it begins. The
    /// owner makes sure the file is on disk right then and answers where it is, or nil when there is none to
    /// hand over. Nil here leaves every file a picture that cannot be dragged.
    public var fileToDrag: (@MainActor (UUID) -> URL?)?

    /// Another timeline start was typed, and Return was pressed or the field was left. The text is as typed.
    /// The owner answers through `SendContent.timelineStart`, which the field then shows.
    public var timelineStartChanged: (@MainActor (String) -> Void)?

    /// Another frame rate was chosen: one of `SendContent.frameRates`.
    public var frameRateChosen: (@MainActor (String) -> Void)?

    /// Another timecode for the start of the song was typed, and Return was pressed or the field was left.
    public var songStartChanged: (@MainActor (String) -> Void)?

    /// Asked with the text of the timeline start or song start field while it is typed in. The answer is a
    /// sentence that says how a timecode is written, while the text is not one, and nil while it is. The panel
    /// shows the sentence under the fields until the text is a timecode or the field is left. Without this
    /// nothing is shown, as in the design lab.
    public var timecodeHint: (@MainActor (String) -> String?)?

    /// The switch "With sound" was switched: what it was switched to. The owner then writes the files again
    /// and answers through `SendContent.withSound` and `SendContent.Clip.isSentWithSound`. Nil leaves the
    /// switch changing only what the panel shows.
    public var withSoundChanged: (@MainActor (Bool) -> Void)?

    /// Done was pressed, or the panel was closed with the Escape key.
    public var closed: (@MainActor () -> Void)?

    public init() {}
}

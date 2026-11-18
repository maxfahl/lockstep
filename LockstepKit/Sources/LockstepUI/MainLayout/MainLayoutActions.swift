import LockstepCore
import SwiftUI

/// What `MainLayout` tells its owner when a control in the window is used.
///
/// The design lab leaves it empty: its window is a picture and nothing in it
/// works. The real app fills in an action for each control whose feature works:
///
///     var actions = MainLayoutActions()
///     actions.transport = { button in model.pressed(button) }
///     actions.seek = { seconds in model.seek(to: seconds) }
///     actions.rulerDragged = { drag in model.rulerDragged(drag) }
///     actions.timeFollowsPlayhead = true
///     actions.timelinePinchesAndScrolls = true
///
///     MainLayout(content: content, features: .built, scale: $scale, playhead: playhead, actions: actions)
///
/// A later phase adds the action of its own control here, left out by default.
public struct MainLayoutActions {
    /// A transport button was pressed: Play, Record or Loop.
    public var transport: ((TransportButtonKind) -> Void)?

    /// The ruler or the song row was clicked, at these song seconds. A drag is
    /// not a click and is not reported.
    public var seek: ((Double) -> Void)?

    /// The ruler was pressed, the pointer was moved with the button down, or
    /// the button was let go. The owner moves the playhead to the pointer.
    /// With it, a click in the ruler is told here, as a drag that did not
    /// move, and not to `seek`. Nil leaves the ruler with clicks only, told
    /// to `seek`.
    public var rulerDragged: ((TimelineRulerDrag) -> Void)?

    /// A track's row was clicked, on a clip or beside one: the id of the
    /// track and the song seconds under the pointer. The owner decides what
    /// that selects. Nil listens for no clicks in track rows.
    public var trackTapped: ((UUID, Double) -> Void)?

    /// Something in the track list was used: a track's header, its mute
    /// button, its name, or the "New Track" button, or a track was dragged
    /// by its header. Nil leaves the track list a picture, as in the design
    /// lab. See `TrackActions`.
    public var tracks: TrackActions?

    /// A clip was dragged by its bar. Nil leaves the clips pictures, as in
    /// the design lab. See `ClipActions`.
    public var clips: ClipActions?

    /// Rename Clip, Split at Playhead, Join Clips, Mute Clip, a feel, Delete Other Takes or Delete was
    /// chosen in the right-click menu of the clip with this id. Nil leaves them doing nothing.
    public var clipCommand: (@MainActor (ClipMenu.Command, UUID) -> Void)?

    /// Asked whether Split at Playhead and Join Clips can act right now, for
    /// the clip with this id, when its right-click menu is made. Nil leaves
    /// it to what the content says, as in the design lab.
    public var clipCommandIsEnabled: (@MainActor (ClipMenu.Command, UUID) -> Bool)?

    /// The take count on a clip was pressed, or something was done in the
    /// takes list in the panel on the right: a take was clicked, a take's
    /// Play button or Delete Other Takes was pressed. A press on a take count
    /// also opens the panel on the right when it is hidden. Nil leaves the
    /// take count and the list pictures, as in the design lab.
    public var takes: TakesActions?

    /// The width of the timeline's rows, without the header column, in points.
    /// Told at the start and whenever it changes. Whoever changes the scale
    /// from outside needs it to know which part of the song is on screen.
    public var timelineWidthChanged: ((CGFloat) -> Void)?

    /// The time in the bar shows where the playhead is and follows it while
    /// the song plays, without the rest of the window being worked out again.
    /// When false, the time is the text in `content.timeline.timeText`.
    public var timeFollowsPlayhead = false

    /// The tempo in the bar shows what this says and changes with it, without
    /// the rest of the window being worked out again. Nil shows the text in
    /// `content.timeline.tempoText`.
    public var tempo: TempoReading?

    /// The microphone level in the bar shows what this says and moves with
    /// it, without the rest of the window being worked out again. Nil shows
    /// `content.micLevel` and `content.micIsClipping`.
    public var micLevel: MicLevelReading?

    /// A beat line of the song row was dragged and let go: where it stood
    /// and where it was let go, in song seconds. Nil leaves the beat lines
    /// where they are: nothing happens on a drag.
    public var beatMoved: (@MainActor (BeatLineMove) -> Void)?
    /// Told when an edge of the song, or the song itself, is dragged in the
    /// song row: on every move and when it is let go (`SongDrag`). Nil
    /// leaves the song as it is.
    public var songDragged: (@MainActor (SongDrag) -> Void)?

    /// "This Is Beat 1" was chosen in the right-click menu of the beat line
    /// at these song seconds.
    public var beatOneChosen: (@MainActor (Double) -> Void)?

    /// "Create Click Track...", Find Beats Again, Halve Tempo or Double
    /// Tempo was chosen in the song row's right-click menu.
    public var songCommand: (@MainActor (SongMenu.Command) -> Void)?

    /// The message at the top of the timeline was closed with its button.
    /// The owner then takes the message out of the content, so the same
    /// sentence shows again the next time it is needed. Nil leaves it to the
    /// layout, which hides the message until the content brings another one.
    public var messageClosed: (@MainActor () -> Void)?

    /// The click button was pressed, or a sound, a volume or a division was
    /// chosen in the click popover. Nil leaves the click control as the
    /// design lab shows it: it changes only what it shows.
    public var click: ClickActions?

    /// The delay readout was pressed, or a button of the calibrate sheet. With
    /// it the delay readout is a button, and the layout shows
    /// `MainLayoutContent.calibration` as a sheet over the window while there
    /// is one. Nil leaves the readout a text and opens no sheet. See
    /// `CalibrationActions`.
    public var calibration: CalibrationActions?

    /// The Send to DaVinci button was pressed, or something was done in the
    /// Send to DaVinci panel. With it the layout shows
    /// `MainLayoutContent.send` as a sheet over the window while there is
    /// one. Nil leaves the button doing nothing and opens no panel. See
    /// `SendActions`.
    public var send: SendActions?

    /// The snapping button in the bar was pressed. The owner then changes
    /// `content.snappingIsOn`. Nil leaves the button as the design lab shows
    /// it: it changes only what it shows.
    public var snappingPressed: (() -> Void)?

    /// A line was chosen in the menu beside the snapping button: what
    /// snapping catches on, as it is after the choice. The owner then changes
    /// `content.snapChoices`. Nil leaves the menu as the design lab shows it:
    /// it changes only its own ticks.
    public var snapChoicesChanged: (@MainActor (SnapChoices) -> Void)?

    /// The volume control of the selected clips was moved: the volume it
    /// stands at, in dB. `isFinal` is false while the slider is still being
    /// moved and true once it is let go, so one drag can be one change. The
    /// owner then changes `ClipBox.volumeDB` of the selected clips. Nil
    /// leaves the control as the design lab shows it: it changes only what
    /// it shows.
    public var clipVolumeChanged: (@MainActor (_ volumeDB: Double, _ isFinal: Bool) -> Void)?

    /// The header of the song row was clicked. The owner then sets
    /// `TimelineContent.songIsSelected`, so the panel on the right shows the
    /// song. Nil leaves the header a picture, as in the design lab.
    public var songHeaderPressed: (@MainActor () -> Void)?

    /// The volume control of the selected song was moved: the volume it
    /// stands at, in dB. `isFinal` is false while the slider is still being
    /// moved and true once it is let go, so one drag can be one change. The
    /// owner then changes `MainLayoutContent.songVolumeDB`. Nil leaves the
    /// control as the design lab shows it: it changes only what it shows.
    public var songVolumeChanged: (@MainActor (_ volumeDB: Double, _ isFinal: Bool) -> Void)?

    /// A control under "Correction" in the panel on the right was used, for the
    /// selected clips. Nil leaves the controls as the design lab shows them:
    /// they change only what they show. See `TightenActions`.
    public var tighten: TightenActions?

    /// The Sound menu of a track or a knob under "Sound" in the panel on the
    /// right was used. Nil leaves them as the design lab shows them: they
    /// change only what they show. See `SoundActions`.
    public var sound: SoundActions?

    /// The switch, the menu or a knob under "Voice" in the panel on the
    /// right was used, or a line of the submenu "Voice" of a track's
    /// right-click menu was chosen. Nil leaves the section as the design lab
    /// shows it: it changes only what it shows. See `VoiceActions`.
    public var voice: VoiceActions?

    /// An effect was added, from the menu under "Effects" in the panel on
    /// the right or in a clip's right-click menu, or something was done in
    /// the list of a clip's effects: a level was moved, an effect was
    /// removed or a row was clicked. Nil leaves them as the design lab shows
    /// them: they change only what they show. See `EffectsActions`.
    public var effects: EffectsActions?

    /// A pinch on the trackpad zooms the timeline around the pointer, and two
    /// fingers moved sideways scroll along the song. Scrolling with Option
    /// held zooms too, and with Command held it moves along the song. The
    /// timeline changes the scale it was handed. Scrolling with Shift held
    /// changes the height of the track rows, when `MainLayout` was handed
    /// one (`trackHeight`). When false, it listens for none of them.
    public var timelinePinchesAndScrolls = false

    /// Told how far the track rows are scrolled down, and asked to scroll them, so the
    /// owner can keep the place across a restart. Nil leaves it to the timeline.
    public var rowsPosition: TimelineRowsPosition?

    /// The inspector was opened (`true`) or hidden (`false`) with its button, or
    /// opened by a press on a take count, so the owner can open the window the
    /// same way next time with `showsInspector`. Nil tells nobody.
    public var inspectorChosen: ((Bool) -> Void)?

    public init() {}
}

/// What the controls under "Correction" in the panel on the right tell their
/// owner. Each is about every selected clip at once, and the owner then
/// changes those clips, so the window shows the new values.
///
///     var tighten = TightenActions()
///     tighten.correctionChosen = { correction in model.setSelectedClipsCorrection(correction) }
///     actions.tighten = tighten
public struct TightenActions {
    /// One of Off, Lines and All was pressed.
    public var correctionChosen: (@MainActor (ClipCorrection) -> Void)?
    /// One of 16ths, Triplets and Auto was pressed in the choice of sub-beats.
    public var subBeatsChosen: (@MainActor (ClipMenu.Feel) -> Void)?
    /// The slider "Strength" was let go: the value it stands at, from 0 to 1.
    public var strengthChanged: (@MainActor (Double) -> Void)?
    /// The switch "Stretch" was switched: what it was switched to.
    public var stretchChanged: (@MainActor (Bool) -> Void)?
    /// A line was chosen in the menu of the row "Aim at": the id of the track the selected clips are to aim
    /// at, or nil for "The beat".
    public var aimChosen: (@MainActor (_ trackID: UUID?) -> Void)?

    public init() {}
}

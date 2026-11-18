import Foundation
import LockstepCore

/// Everything `MainLayout` draws: the timeline's content, and the values of
/// the controls around it. Like `TimelineContent` it is a plain display type.
/// The design lab fills it with made-up values (`SampleContent.makeMainLayout`),
/// the real app fills it from the project and the audio engine.
///
/// A design state that needs the window to show something new adds a value
/// here, with a default that leaves every other state as it was.
public struct MainLayoutContent: Sendable, Equatable {
    /// The song, its beats, the tracks with their clips, the takes of the
    /// selected clip, and the time and tempo texts.
    public var timeline: TimelineContent

    // The bar at the bottom.

    public var isPlaying: Bool
    public var isRecording: Bool
    /// The song is playing the bars before the place where recording will
    /// start. Record is lit, as while recording.
    public var isRunningUp = false
    /// The speed takes are recorded at, in percent of the song's speed. Below
    /// 100 the percent stands beside the Record button. Nil or 100 shows
    /// nothing: takes are recorded at the song's own speed.
    public var recordSpeedPercent: Int?
    public var isLooping: Bool
    /// The microphone level, from 0 to 1.
    public var micLevel: Double
    /// The microphone is too loud right now: the end of the level meter lights up.
    public var micIsClipping = false
    public var clickIsOn: Bool
    /// What the click popover shows: the sound, the volume and how often it
    /// clicks.
    public var clickSettings = ClickSettings()
    /// Snapping is on: a clip that is moved snaps to the edges of other
    /// clips, to the playhead and to the place it was recorded.
    public var snappingIsOn: Bool
    /// What snapping catches on, as the menu beside the snapping button
    /// ticks it. Everything is on, with beats as the grid's unit, until it
    /// is set.
    public var snapChoices = SnapChoices()

    // The inspector: the selected clips.

    /// How far the sound of the selected clips has come in being made again
    /// after a timing change, from 0 to 1. Nil when nothing is being made.
    /// What the controls under "Correction" show comes from the selected
    /// clips themselves (`ClipBox.correction`, `ClipBox.strength`,
    /// `ClipBox.stretches`, `ClipBox.menuFeel`).
    public var clipRemakeProgress: Double?

    /// The words of the selected clip. Empty when it has none yet.
    public var selectedClipText: String
    /// The selected clip's start on the DaVinci Resolve timeline, such as
    /// "01:00:16:00". Empty when it is not known.
    public var selectedClipResolveStart: String
    /// The selected clip is played more quietly than its volume says, so its
    /// loudest moment stays under the safe limit.
    public var selectedClipVolumeIsHeldBack: Bool

    // The inspector: the Sound of the selected track or clips.

    /// The names of Max's own presets, in the order he saved them, which the
    /// Sound menu of a track lists under the six built-in ones.
    public var ownSoundPresets: [String] = []
    /// How far the finished sounds of what the panel shows have come in
    /// being made, from 0 to 1, after a Sound was chosen or a knob was
    /// turned. Nil when nothing is being made.
    public var soundRemakeProgress: Double?

    // The inspector: the Voice of the selected track.

    /// Max's own presets of a Voice, in the order he saved them, which the
    /// Voice menu of a track lists under the three built-in ones, in the
    /// panel and in the track's right-click menu.
    public var ownVoicePresets: [VoicePreset] = []
    /// False dims the section "Voice" and greys out the submenu "Voice" of
    /// a track's right-click menu: a take is going or counting in, and no
    /// voice is made meanwhile.
    public var canChangeVoice = true

    // The inspector: the effects of several selected clips.

    /// The effects several selected clips share, one row each, which the
    /// panel lists under "Effects" while more than one clip is selected: an
    /// effect each of them has on the whole clip, its own or its track's.
    /// A row has an id of its own, by which a moved level and a press on its
    /// button are reported, `isMixed` where the clips' levels differ, and
    /// `ofTrack` when it is the track's effect on every one of them. Empty
    /// when they share none, and while one clip or none is selected.
    public var selectedClipsEffects: [ClipEffectMark] = []

    // The right-click menus of a clip and of a track.

    /// False greys out "Copy Sound" in the right-click menus of a clip and
    /// of a track, as while a take is going.
    public var canCopySound = true
    /// False greys out "Paste Sound" in the same menus: no sound was copied
    /// yet, or a take is going.
    public var canPasteSound = true

    // The inspector: the selected song.

    /// The song's own volume in dB, from -24 to 0. 0 plays the song as its
    /// file is. Shown while the song is selected
    /// (`TimelineContent.songIsSelected`).
    public var songVolumeDB: Double = 0

    // The inspector: the part that is always there.

    /// The measured delay, or nil when the delay has not been calibrated.
    public var delayMilliseconds: Int?
    /// What the calibrate sheet shows, or nil while it is closed. The sheet
    /// is opened only for an owner that listens to it
    /// (`MainLayoutActions.calibration`).
    public var calibration: CalibrationContent?
    /// What the Send to DaVinci panel shows, or nil while it is closed. The
    /// panel is opened only for an owner that listens to it
    /// (`MainLayoutActions.send`).
    public var send: SendContent?
    /// False greys out the Send to DaVinci button: no clip is selected to send.
    public var canSendToDaVinci = true

    // The song's right-click menu.

    /// False greys out "Create Click Track..." in the song's right-click
    /// menu: the beats are not found yet.
    public var canCreateClickTrack = true
    /// False greys out "Halve Tempo" in the song's right-click menu: the
    /// beats are already at half tempo.
    public var canHalveTempo = true
    /// False greys out "Double Tempo": the beats are already at double tempo.
    public var canDoubleTempo = true

    // The takes list in the inspector.

    /// Draws the takes list as if the pointer were somewhere on it. The
    /// design lab uses it for pictures. In a window that works the real
    /// pointer decides.
    public var takesPointer = TakesListPointer()

    // Messages.

    /// A message shown at the top of the window, over the timeline, such as
    /// "Lockstep could not read this file." Nil shows none.
    public var message: String?

    // Opening a song.

    /// How far the reading of a dropped song has come, from 0 to 1. While it
    /// is set and the window has no song, a ring that fills takes the place
    /// of the words "Drop a song here". Nil most of the time.
    public var openingProgress: Double?

    /// False before a song is dropped. The window then shows only the words
    /// "Drop a song here".
    public var hasSong: Bool { timeline.songLength > 0 }

    /// The content of a window that has no song yet.
    public static let empty = MainLayoutContent(timeline: .empty)

    public init(
        timeline: TimelineContent,
        isPlaying: Bool = false,
        isRecording: Bool = false,
        isLooping: Bool = false,
        micLevel: Double = 0,
        clickIsOn: Bool = false,
        selectedClipText: String = "",
        selectedClipResolveStart: String = "",
        delayMilliseconds: Int? = nil,
        clipRemakeProgress: Double? = nil,
        selectedClipVolumeIsHeldBack: Bool = false,
        snappingIsOn: Bool = true
    ) {
        self.timeline = timeline
        self.isPlaying = isPlaying
        self.isRecording = isRecording
        self.isLooping = isLooping
        self.micLevel = micLevel
        self.clickIsOn = clickIsOn
        self.selectedClipText = selectedClipText
        self.selectedClipResolveStart = selectedClipResolveStart
        self.delayMilliseconds = delayMilliseconds
        self.clipRemakeProgress = clipRemakeProgress
        self.selectedClipVolumeIsHeldBack = selectedClipVolumeIsHeldBack
        self.snappingIsOn = snappingIsOn
    }
}

extension SampleContent {
    /// Made-up content for the whole window: the fake song of `make()`, or the
    /// heavy one of `makeStress()`, with the control values the design shows.
    /// A design state starts from this and changes what it needs:
    ///
    ///     var content = SampleContent.makeMainLayout()
    ///     content.isRecording = true
    public static func makeMainLayout(stress: Bool = false) -> MainLayoutContent {
        var timeline = stress ? makeStress() : make()
        // Every clip is corrected the same way: All at 70 %, so its lines
        // slide and its syllables move 70 % of the way, with Stretch off.
        for row in timeline.trackRows.indices {
            for clip in timeline.trackRows[row].clips.indices {
                timeline.trackRows[row].clips[clip].correction = .all
                timeline.trackRows[row].clips[clip].strength = 0.7
            }
        }
        return MainLayoutContent(
            timeline: timeline,
            micLevel: 0.6,
            clickIsOn: true,
            selectedClipText: "Told myself I'd make it through, so I learned to stand alone.",
            selectedClipResolveStart: "01:00:16:00",
            delayMilliseconds: 12
        )
    }
}

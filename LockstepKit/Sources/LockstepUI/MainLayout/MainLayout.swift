import LockstepCore
import SwiftUI

/// The layout of the Lockstep window, the one Max chose (layout B of phase 2):
/// the timeline fills the window, right under the window's title. The
/// transport floats over the bottom of the timeline as a glass capsule
/// (`TransportCapsule`), and a glass panel on the right, the inspector
/// (`Inspector`), holds everything about the selected track, the selected clip
/// and the song.
///
///     @State private var scale = TimelineScale(pointsPerSecond: 0)
///     @State private var playhead = PlayheadPosition(seconds: content.timeline.playheadTime)
///
///     MainLayout(content: content, features: .all, scale: $scale, playhead: playhead)
///
/// This is the only place where the window is laid out. The design lab hosts
/// it with made-up content and `FeatureSet.all`. The real app hosts the same
/// view with `FeatureSet.built`. Put it on `WindowBackground()` and give the
/// window `lockstepLook()`.
///
/// Features: a control is shown only when its feature is in `features`, and
/// is left out completely otherwise (never greyed out).
/// - Always there: the song row, Play and the time.
/// - `beats`: beat lines and the tempo.
/// - `recording`: Record, the microphone level and the track rows.
/// - `tracks`: the track rows and the "New Track" row.
/// - `loop`: Loop. `click`: the click control. `moveClips`: the snapping button.
/// - The right-click menus: the clip's with `recording` or `clipEditing`,
///   holding the commands of the features that are there, the track's with
///   `tracks`, the song's and the beat line's with `beats` (`TimelineMenus`).
/// - The inspector's parts are listed at `Inspector`. With none of its
///   features the inspector and its button are not there at all.
///
/// Before a song is dropped (`content.hasSong` is false) none of this is
/// shown, whatever the features: the window holds only the words "Drop a song
/// here" (`EmptyWindow`), or a ring that fills while a dropped song is being
/// read (`content.openingProgress`). A message (`content.message`) floats at the top of
/// the timeline, under the ruler (`MessageBanner`).
///
/// The inspector can be hidden with the button at the right end of the
/// capsule. Until that button is pressed, the inspector is open in a wide
/// window and hidden in a narrow one.
///
/// Making it work: the design lab only shows the window, so by itself nothing
/// in it does anything. The real app hands in `actions` (`MainLayoutActions`),
/// which is told when a control is used.
///
/// Widths, with the window's inset of 8 on every side: the inspector takes
/// 240 and a gap of 8. In the smallest window, 900 wide, that leaves the
/// timeline 884 points with the inspector hidden and 636 with it open. The
/// capsule needs about 560, so it fits in both.
public struct MainLayout: View {
    /// The inspector opens by itself only when the timeline beside it still
    /// gets at least the width it has alone in the smallest window.
    private static let windowWidthThatShowsInspector = DesignTokens.Sizes.minimumWindowWidth
        + DesignTokens.Sizes.inspectorWidth
        + DesignTokens.Spacing.windowInset

    /// The empty room under the last row of the timeline, so that every row
    /// can be scrolled up to above the capsule that floats over the bottom.
    private static let roomUnderRows = DesignTokens.Sizes.floatingBarHeight
        + DesignTokens.Spacing.windowInset

    private let content: MainLayoutContent
    private let features: FeatureSet
    /// Inside a `TimelineScaleLink`, so a change of the scale does not make
    /// the whole window work itself out again: only the `Timeline` reads it.
    private let scaleLink: TimelineScaleLink
    private var scale: Binding<TimelineScale> { scaleLink.binding }
    private let trackHeight: Binding<CGFloat>?
    private let playhead: PlayheadPosition
    /// What was chosen with the inspector button. Nil until it is pressed;
    /// until then the width of the window decides.
    @State private var inspectorChoice: Bool?
    private let showsClickSettings: Binding<Bool>?
    private let actions: MainLayoutActions
    /// The message that was closed with its button, so it stays away until
    /// the content brings a different one. Used only when nobody is told of
    /// the closing (`actions.messageClosed`).
    @State private var closedMessage: String?
    /// What the calibrate sheet last showed. The sheet keeps showing it while
    /// it slides away, when the content has already let go of it.
    @State private var lastCalibration: CalibrationContent?
    /// What the Send to DaVinci panel last showed, kept for the same reason.
    @State private var lastSend: SendContent?
    /// Hands the press on a clip's take count down the timeline without putting a new closure in the
    /// environment every time the window is worked out. See `TakeCountListener`.
    @State private var takeCountListener = TakeCountListener()

    /// - Parameters:
    ///   - content: Everything the window draws.
    ///   - features: The features whose controls are shown. See "Features" above.
    ///   - scale: The zoom and the sideways scroll position of the timeline.
    ///     `TimelineScale(pointsPerSecond: 0)` fits the whole song to the width.
    ///   - trackHeight: The height of every track row. With it, and with
    ///     `actions.timelinePinchesAndScrolls`, scrolling with Shift held
    ///     over the timeline changes it (`TrackHeight`). Nil keeps the rows
    ///     at `DesignTokens.Sizes.trackLaneHeight`, as most design states do.
    ///   - playhead: Where the playhead is. The main timeline and the takes in
    ///     the inspector show the same one.
    ///   - showsInspector: Opens (`true`) or hides (`false`) the inspector from
    ///     the start, as if its button had been pressed. Nil lets the width of
    ///     the window decide. A design state uses it to show the same thing at
    ///     every window size.
    ///   - showsClickSettings: Whether the click popover is open, kept by the
    ///     caller. Nil leaves it to the click control: closed until its arrow
    ///     is pressed. A design state uses it to show the popover open.
    ///   - actions: What is told when a control is used. Left out, nothing in
    ///     the window does anything and the time shows `content.timeline.timeText`,
    ///     which is how the design lab shows it.
    public init(
        content: MainLayoutContent,
        features: FeatureSet,
        scale: Binding<TimelineScale>,
        trackHeight: Binding<CGFloat>? = nil,
        playhead: PlayheadPosition,
        showsInspector: Bool? = nil,
        showsClickSettings: Binding<Bool>? = nil,
        actions: MainLayoutActions = MainLayoutActions()
    ) {
        self.content = content
        self.features = features
        self.scaleLink = TimelineScaleLink(binding: scale)
        self.trackHeight = trackHeight
        self.playhead = playhead
        self._inspectorChoice = State(initialValue: showsInspector)
        self.showsClickSettings = showsClickSettings
        self.actions = actions
    }

    public var body: some View {
        Group {
            if content.hasSong {
                windowWithSong
            } else {
                EmptyWindow(openingProgress: content.openingProgress)
            }
        }
        // The calibrate sheet lies over the window, with or without a song,
        // while the content has one and somebody listens to its buttons.
        .sheet(isPresented: showsCalibrateSheet) {
            if let calibration = content.calibration ?? lastCalibration {
                CalibrateSheet(
                    content: calibration,
                    onStart: actions.calibration?.startPressed,
                    onClose: { actions.calibration?.closed?() }
                )
            }
        }
        .onChange(of: content.calibration, initial: true) { _, calibration in
            if let calibration {
                lastCalibration = calibration
            }
        }
        // The Send to DaVinci panel lies over the window the same way.
        .sheet(isPresented: showsSendSheet) {
            if let send = content.send ?? lastSend {
                SendSheet(content: send, actions: actions.send, onClose: { actions.send?.closed?() })
            }
        }
        .onChange(of: content.send, initial: true) { _, send in
            if let send {
                lastSend = send
            }
        }
    }

    /// Whether the Send to DaVinci panel is open. Closing it any other way
    /// than with Done, with the Escape key for one, is reported like Done.
    private var showsSendSheet: Binding<Bool> {
        Binding(
            get: { content.send != nil && actions.send != nil },
            set: { shows in
                if !shows, content.send != nil {
                    actions.send?.closed?()
                }
            }
        )
    }

    /// Whether the calibrate sheet is open. Closing it any other way than
    /// with its buttons, with the Escape key for one, is reported like Close.
    private var showsCalibrateSheet: Binding<Bool> {
        Binding(
            get: { content.calibration != nil && actions.calibration != nil },
            set: { shows in
                if !shows, content.calibration != nil {
                    actions.calibration?.closed?()
                }
            }
        )
    }

    /// The window once it has a song: the timeline, the capsule and the inspector.
    private var windowWithSong: some View {
        GeometryReader { proxy in
            let showsInspector = Inspector.hasContent(for: features)
                && (inspectorChoice ?? (proxy.size.width >= Self.windowWidthThatShowsInspector))
            HStack(spacing: DesignTokens.Spacing.windowInset) {
                let _ = takeCountListener.pressed = takeCountPressed
                timeline(showsInspector: showsInspector)
                    .environment(\.takeCountListener, takeCountPressed == nil ? nil : takeCountListener)
                if showsInspector {
                    Inspector(
                        content: content,
                        features: features,
                        playhead: playhead,
                        onDelayPressed: actions.calibration?.readoutPressed,
                        onSendPressed: actions.send?.buttonPressed,
                        onClipVolumeChanged: actions.clipVolumeChanged,
                        onSongVolumeChanged: actions.songVolumeChanged,
                        tighten: actions.tighten,
                        takes: actions.takes,
                        tracks: actions.tracks,
                        voice: actions.voice,
                        sound: actions.sound,
                        effects: actions.effects
                    )
                        .frame(width: DesignTokens.Sizes.inspectorWidth)
                }
            }
            .padding(DesignTokens.Spacing.windowInset)
            // The timeline gets narrower when the inspector opens. It would
            // keep its zoom, and the end of the song could fall outside the
            // window. So the song is fitted to the new width.
            .onChange(of: showsInspector) {
                scale.wrappedValue = TimelineScale(pointsPerSecond: 0)
            }
        }
    }

    /// The timeline's content with what the features leave out taken away:
    /// no beat lines before beats are found, no track rows before recording.
    private var shownTimeline: TimelineContent {
        var timeline = content.timeline
        if !features.contains(.beats) {
            timeline.beatLines = []
            timeline.uncertainRanges = []
            timeline.unfilledGaps = []
        }
        if features.isDisjoint(with: [.recording, .tracks]) {
            timeline.trackRows = []
        }
        return timeline
    }

    /// The right-click menus the features give, with what the content says
    /// they grey out and with what their commands report to.
    private var menus: TimelineMenus {
        var menus = TimelineMenus(features: features)
        menus.song?.canCreateClickTrack = content.canCreateClickTrack
        menus.song?.canHalveTempo = content.canHalveTempo
        menus.song?.canDoubleTempo = content.canDoubleTempo
        menus.onSongCommand = actions.songCommand
        menus.onBeatOne = actions.beatOneChosen
        menus.onClipCommand = actions.clipCommand
        menus.clipCommandIsEnabled = actions.clipCommandIsEnabled
        menus.onClipEffect = actions.effects?.addChosenInClipMenu
        menus.onTrackEffect = actions.effects?.trackAddChosen
        menus.onTrackVoice = actions.voice?.menuCommand
        menus.ownVoicePresets = content.ownVoicePresets.map(\.name)
        menus.canChangeVoice = content.canChangeVoice
        menus.canCopySound = content.canCopySound
        menus.canPasteSound = content.canPasteSound
        return menus
    }

    /// What a press on a clip's take count does, or nil when nobody listens
    /// for the takes: the count then does nothing, as in the design lab. The
    /// owner selects the clip, and the inspector opens if it was hidden,
    /// because the takes are listed there.
    private var takeCountPressed: (@MainActor (UUID) -> Void)? {
        guard let countPressed = actions.takes?.countPressed else { return nil }
        return { clipID in
            countPressed(clipID)
            if Inspector.hasContent(for: features) {
                chooseInspector(true)
            }
        }
    }

    /// Opens or hides the inspector as Max chose, and tells the owner, who can open
    /// the window the same way next time.
    private func chooseInspector(_ isShown: Bool) {
        inspectorChoice = isShown
        actions.inspectorChosen?(isShown)
    }

    /// The timeline with the capsule floating over its bottom edge, centred
    /// on the timeline so it never reaches in under the inspector.
    private func timeline(showsInspector: Bool) -> some View {
        MainTimeline(
            content: shownTimeline,
            scale: scale,
            trackHeight: trackHeight,
            playhead: playhead,
            showsNewTrackRow: features.contains(.tracks),
            menus: menus,
            onSeek: actions.seek,
            onRulerDrag: actions.rulerDragged,
            onBodyWidthChange: actions.timelineWidthChanged,
            pinchesAndScrolls: actions.timelinePinchesAndScrolls,
            onBeatMove: actions.beatMoved,
            onTrackTap: actions.trackTapped,
            trackActions: actions.tracks,
            clipActions: actions.clips
        )
        .onSongDrag(actions.songDragged)
        .onSongHeaderTap(actions.songHeaderPressed)
        .keepsRowsPosition(actions.rowsPosition)
        .contentMargins(.bottom, Self.roomUnderRows, for: .scrollContent)
        .overlay(alignment: .bottom) {
            TransportCapsule(
                content: content,
                features: features,
                showsInspector: Binding(
                    get: { showsInspector },
                    set: { chooseInspector($0) }
                ),
                showsClickSettings: showsClickSettings,
                livePlayhead: actions.timeFollowsPlayhead ? playhead : nil,
                liveTempo: actions.tempo,
                onTransport: actions.transport,
                clickActions: actions.click,
                liveMicLevel: actions.micLevel,
                onSnapping: actions.snappingPressed,
                onSnapChoices: actions.snapChoicesChanged
            )
        }
        .overlay(alignment: .top) {
            if let message = content.message, message != closedMessage {
                MessageBanner(message) {
                    // An owner that is told takes the message away itself.
                    // Remembering the sentence here as well would keep the
                    // same sentence hidden the next time it is needed.
                    if let messageClosed = actions.messageClosed {
                        messageClosed()
                    } else {
                        closedMessage = message
                    }
                }
                    .padding(.top, DesignTokens.Sizes.rulerHeight + DesignTokens.Spacing.windowInset)
            }
        }
    }
}

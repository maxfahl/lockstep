import LockstepCore
import SwiftUI

/// The glass capsule of `MainLayout` that floats over the bottom of the
/// timeline: transport, time, tempo, microphone level and click, and at its
/// right end the button that shows or hides the inspector.
///
/// A control is shown only when its feature is in `features`: Record and the
/// microphone level with `recording`, Loop with `loop`, the tempo with
/// `beats`, the click with `click`, snapping with `moveClips`, and the
/// inspector button when the inspector has anything to show. Play and the
/// time are always there.
///
/// Snapping has its button here and not in the inspector, because it is not
/// about the selected track or clip, and it must be in reach while a clip is
/// dragged, also when the inspector is folded away. The small arrow right
/// beside it opens the menu of what to snap to (`SnapToButton`).
///
/// While takes are recorded slower than the song
/// (`content.recordSpeedPercent` below 100), the percent stands right after
/// the Record button, so a slow take never comes as a surprise.
///
/// It is as wide as its content and never shrinks. With everything shown its
/// width is about 540 points: transport 102, time and tempo about 95, level
/// about 90, click 46, snapping 30 and its arrow 14, the inspector button 30, five gaps of 20
/// between the groups and 12 of padding at each end. The mark of a slower
/// recording speed adds about 28. The narrowest place `MainLayout`
/// gives it is 636 points (a 900 point window with the inspector open), so it
/// always fits.
public struct TransportCapsule: View {
    private let content: MainLayoutContent
    private let features: FeatureSet
    @Binding private var showsInspector: Bool
    private let showsClickSettings: Binding<Bool>?
    private let livePlayhead: PlayheadPosition?
    private let liveTempo: TempoReading?
    private let liveMicLevel: MicLevelReading?
    private let onTransport: ((TransportButtonKind) -> Void)?
    private let clickActions: ClickActions?
    private let onSnapping: (() -> Void)?
    private let onSnapChoices: (@MainActor (SnapChoices) -> Void)?

    /// - Parameters:
    ///   - showsClickSettings: Whether the click popover is open, kept by the
    ///     caller. Nil leaves it to the click control: closed until its arrow
    ///     is pressed.
    ///   - livePlayhead: When given, the time shows where this playhead is
    ///     and follows it. Nil shows `content.timeline.timeText`.
    ///   - liveTempo: When given, the tempo shows what this reading says and
    ///     changes with it. Nil shows `content.timeline.tempoText`.
    ///   - liveMicLevel: When given, the microphone level shows what this
    ///     reading says and moves with it. Nil shows `content.micLevel` and
    ///     `content.micIsClipping`.
    ///   - onTransport: Told which transport button was pressed. Nil leaves
    ///     the buttons doing nothing.
    ///   - clickActions: Told when the click control or its popover is used.
    ///     Nil leaves the click control changing only what it shows.
    ///   - onSnapping: Called when the snapping button is pressed. Nil leaves
    ///     the button changing only what it shows.
    ///   - onSnapChoices: Told what snapping catches on after a line was
    ///     chosen in the menu beside the snapping button. Nil leaves the menu
    ///     changing only its own ticks.
    public init(
        content: MainLayoutContent,
        features: FeatureSet,
        showsInspector: Binding<Bool>,
        showsClickSettings: Binding<Bool>? = nil,
        livePlayhead: PlayheadPosition? = nil,
        liveTempo: TempoReading? = nil,
        onTransport: ((TransportButtonKind) -> Void)? = nil,
        clickActions: ClickActions? = nil,
        liveMicLevel: MicLevelReading? = nil,
        onSnapping: (() -> Void)? = nil,
        onSnapChoices: (@MainActor (SnapChoices) -> Void)? = nil
    ) {
        self.content = content
        self.features = features
        self._showsInspector = showsInspector
        self.showsClickSettings = showsClickSettings
        self.livePlayhead = livePlayhead
        self.liveTempo = liveTempo
        self.liveMicLevel = liveMicLevel
        self.onTransport = onTransport
        self.clickActions = clickActions
        self.onSnapping = onSnapping
        self.onSnapChoices = onSnapChoices
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Spacing.groupGap) {
            TransportControls(
                isPlaying: content.isPlaying,
                isRecording: content.isRecording || content.isRunningUp,
                isLooping: content.isLooping,
                kinds: transportKinds,
                recordSpeedPercent: content.recordSpeedPercent,
                onPress: onTransport
            )
            HStack(spacing: DesignTokens.Spacing.large) {
                if let livePlayhead {
                    PlayheadTimeReadout(playhead: livePlayhead)
                } else {
                    TimeReadout(content.timeline.timeText)
                }
                // Before the beats are found there is no tempo to show.
                if features.contains(.beats) {
                    if let liveTempo {
                        PlayheadTempoReadout(reading: liveTempo)
                    } else if !content.timeline.tempoText.isEmpty {
                        TempoReadout(content.timeline.tempoText)
                    }
                }
            }
            if features.contains(.recording) {
                if let liveMicLevel {
                    LiveMicLevelMeter(reading: liveMicLevel)
                } else {
                    MicLevelMeter(level: content.micLevel, isClipping: content.micIsClipping)
                }
            }
            if features.contains(.click) {
                ClickControl(
                    isOn: content.clickIsOn,
                    settings: content.clickSettings,
                    showsSettings: showsClickSettings,
                    actions: clickActions
                )
            }
            if features.contains(.moveClips) {
                // The arrow that opens the menu of what to snap to stands
                // as close to its button as the click's arrow does.
                HStack(spacing: DesignTokens.Spacing.tight) {
                    SnappingButton(isOn: content.snappingIsOn, onPress: onSnapping)
                    SnapToButton(choices: content.snapChoices, onChange: onSnapChoices)
                }
            }
            if Inspector.hasContent(for: features) {
                inspectorButton
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.barPadding)
        .frame(height: DesignTokens.Sizes.floatingBarHeight)
        .fixedSize()
        .glassCapsule()
    }

    private var transportKinds: [TransportButtonKind] {
        TransportButtonKind.allCases.filter { kind in
            switch kind {
            case .play: true
            case .record: features.contains(.recording)
            case .loop: features.contains(.loop)
            }
        }
    }

    /// Shows or hides the inspector. It sits in the capsule because the
    /// layout has no bar across the top, and the capsule is always on screen.
    /// It is drawn like the other symbol buttons: flat, and lit in the accent
    /// colour while the inspector is open.
    private var inspectorButton: some View {
        let name = showsInspector ? "Hide Inspector" : "Show Inspector"
        return Button {
            showsInspector.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
                .font(DesignTokens.Fonts.symbol)
                .foregroundStyle(
                    showsInspector ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary
                )
                .frame(
                    width: DesignTokens.Sizes.transportButton,
                    height: DesignTokens.Sizes.transportButton
                )
                .background(
                    showsInspector ? DesignTokens.Colors.controlFillOn : Color.clear,
                    in: DesignTokens.Shapes.control
                )
                .contentShape(DesignTokens.Shapes.control)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(showsInspector ? .isSelected : [])
    }
}

import SwiftUI

/// What is happening to a take's row.
public enum TakeRowState: Sendable, Equatable {
    /// Nothing.
    case normal
    /// The pointer rests on the row. A click would make this take the active one.
    case hovered
    /// The take is about to be deleted: the row is faded and its header shows
    /// a bin where the check mark of the active take would be.
    case aboutToBeDeleted
}

/// The row of one take in the small takes timeline of `TakesList`: in the
/// header the take's Play button, its number and a check mark when it is the
/// chosen take, and in the row the take's words above its waveform.
///
///     Timeline(
///         lanes: TakeLane.lanes(for: content.takeRows, range: clipRange, showsText: true),
///         scale: $takesScale,
///         range: clipRange,
///         beats: content.beats,
///         playhead: playhead,
///         options: TimelineOptions(showsRuler: false, headerWidth: DesignTokens.Sizes.headerWidthNarrow)
///     )
///     .fixedSize(horizontal: false, vertical: true)
///
/// `range` is the stretch of the song the takes cover: the time of the clip
/// they belong to (`ClipBox.timeRange`). A take that has a range of its own
/// (`TakeRow.range`) is drawn there instead. The takes timeline has a scale of
/// its own, so it can show those few seconds across its whole width while the
/// main timeline shows the whole song.
///
/// The row of the active take is tinted like a clip and its waveform has the
/// clip colour. The other takes have a dimmer waveform on the plain row.
///
/// With `showsText` the row is taller (`takeLaneHeightWithText`) and shows the
/// take's words on a line above the waveform, as in `TakesList`. Every row of
/// one timeline should get the same value, so the waveforms keep one height.
///
/// The Play button shows a stop symbol while its take plays
/// (`TakeRow.isPlaying`). A press on it is told to `onPlay`, and a click on
/// the rest of the header to `onPress`. A click on the waveform is the
/// timeline's to report (`Timeline.onLaneTap`).
public struct TakeLane: TimelineLane {
    private let take: TakeRow
    private let range: ClosedRange<Double>
    private let state: TakeRowState
    private let showsText: Bool
    private let onHover: (@MainActor (Part, Bool) -> Void)?
    private let onPlay: (@MainActor () -> Void)?
    private let onPress: (@MainActor () -> Void)?

    /// The two parts of a take's row.
    public enum Part: Sendable {
        /// The number at the left.
        case header
        /// The waveform.
        case body
    }

    /// - Parameters:
    ///   - take: The take to show.
    ///   - range: The stretch of the song the take's levels are spread over,
    ///     in song seconds, unless the take has a range of its own.
    ///   - state: Whether the pointer rests on the row, or the take is about
    ///     to be deleted.
    ///   - showsText: Shows the take's words above the waveform, in a taller row.
    ///   - onHover: Told when the pointer comes onto a part of the row
    ///     (true) and when it leaves it (false). Left out, the row does not
    ///     follow the pointer. The row never lights up by itself: whoever is
    ///     told hands back `state`.
    ///   - onPlay: Told when the take's Play button is pressed, while it
    ///     shows the play symbol or the stop symbol. Left out, the button
    ///     does nothing.
    ///   - onPress: Told when the header is clicked beside the Play button.
    ///     Left out, the header listens for no click.
    public init(
        _ take: TakeRow,
        range: ClosedRange<Double>,
        state: TakeRowState = .normal,
        showsText: Bool = false,
        onHover: (@MainActor (Part, Bool) -> Void)? = nil,
        onPlay: (@MainActor () -> Void)? = nil,
        onPress: (@MainActor () -> Void)? = nil
    ) {
        self.take = take
        self.range = range
        self.state = state
        self.showsText = showsText
        self.onHover = onHover
        self.onPlay = onPlay
        self.onPress = onPress
    }

    public var id: Int { take.id }

    public var height: CGFloat {
        showsText ? DesignTokens.Sizes.takeLaneHeightWithText : DesignTokens.Sizes.takeLaneHeight
    }

    /// A pinned row is laid out without a scroll view of its own. The takes
    /// never scroll by themselves: the panel they lie in does, and a scroll
    /// view inside it would catch the scrolling meant for the panel.
    public var isPinned: Bool { true }

    public func header() -> some View {
        TakeHeader(take: take, state: state, onPlay: onPlay, onPress: onPress)
            .modifier(HoverReport(part: .header, onHover: onHover))
    }

    public func content(in viewport: TimelineViewport) -> some View {
        TakeLaneBody(
            take: take,
            range: take.range ?? range,
            viewport: viewport,
            state: state,
            showsText: showsText
        )
        .modifier(HoverReport(part: .body, onHover: onHover))
    }

    /// The rows for a list of takes, from top to bottom.
    ///
    /// - Parameters:
    ///   - showsText: See `init`.
    ///   - hovered: The number of the take the pointer rests on, if any.
    ///   - aboutToBeDeleted: The numbers of the takes that are about to be deleted.
    ///   - onHover: Told the number of a take, the part of its row and
    ///     whether the pointer came onto it or left it. See `init`.
    ///   - onPlay: Told the number of the take whose Play button was pressed.
    ///   - onPress: Told the number of the take whose header was clicked
    ///     beside the Play button.
    public static func lanes(
        for takes: [TakeRow],
        range: ClosedRange<Double>,
        showsText: Bool = false,
        hovered: Int? = nil,
        aboutToBeDeleted: Set<Int> = [],
        onHover: (@MainActor (Int, Part, Bool) -> Void)? = nil,
        onPlay: (@MainActor (Int) -> Void)? = nil,
        onPress: (@MainActor (Int) -> Void)? = nil
    ) -> [AnyTimelineLane] {
        takes.map { take -> AnyTimelineLane in
            let state: TakeRowState = if aboutToBeDeleted.contains(take.number) {
                .aboutToBeDeleted
            } else if hovered == take.number {
                .hovered
            } else {
                .normal
            }
            let number = take.number
            var report: (@MainActor (Part, Bool) -> Void)?
            if let onHover {
                report = { part, isOver in onHover(number, part, isOver) }
            }
            var play: (@MainActor () -> Void)?
            if let onPlay {
                play = { onPlay(number) }
            }
            var press: (@MainActor () -> Void)?
            if let onPress {
                press = { onPress(number) }
            }
            return AnyTimelineLane(TakeLane(
                take,
                range: range,
                state: state,
                showsText: showsText,
                onHover: report,
                onPlay: play,
                onPress: press
            ))
        }
    }
}

/// Tells of the pointer coming onto a part of a take's row and leaving it.
/// Without anybody to tell, the part is left as it is.
private struct HoverReport: ViewModifier {
    let part: TakeLane.Part
    let onHover: (@MainActor (TakeLane.Part, Bool) -> Void)?

    func body(content: Content) -> some View {
        if let onHover {
            content.onHover { onHover(part, $0) }
        } else {
            content
        }
    }
}

/// The header of a take's row: its Play button, its number, and a check mark
/// when it is the chosen take. A take that is about to be deleted shows a bin
/// instead.
private struct TakeHeader: View {
    let take: TakeRow
    let state: TakeRowState
    let onPlay: (@MainActor () -> Void)?
    let onPress: (@MainActor () -> Void)?

    private var isLeaving: Bool { state == .aboutToBeDeleted }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            PlayTakeButton(takeName: take.displayName, isPlaying: take.isPlaying, action: onPlay)
            nameAndMark
        }
        .padding(.leading, DesignTokens.Spacing.small)
        .padding(.trailing, DesignTokens.Spacing.headerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background { TakeRowBacking(isActive: take.isActive, state: state) }
    }

    /// The number and the mark after it. A click here chooses the take. The
    /// Play button beside it keeps its own clicks.
    private var nameAndMark: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Text("\(take.number)")
                .font(DesignTokens.Fonts.laneName)
                .foregroundStyle(
                    take.isActive ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary
                )
                .opacity(isLeaving ? DesignTokens.Opacity.aboutToBeDeleted : 1)
            Spacer(minLength: 0)
            if isLeaving {
                Image(systemName: "trash")
                    .font(DesignTokens.Fonts.symbolSmall)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            } else if take.isActive {
                Image(systemName: "checkmark")
                    .font(DesignTokens.Fonts.symbolSmall)
                    .foregroundStyle(DesignTokens.Colors.accent)
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .modifier(PressReport(onPress: onPress))
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenName)
        .accessibilityAddTraits(take.isActive ? .isSelected : [])
    }

    private var helpText: String {
        if isLeaving { return "\(take.displayName), about to be deleted" }
        return take.isActive ? "\(take.displayName), the chosen take" : "\(take.displayName). Click to choose it."
    }

    private var spokenName: String {
        var parts = [take.displayName]
        if take.isActive { parts.append("active") }
        if isLeaving { parts.append("about to be deleted") }
        if !take.text.isEmpty { parts.append(take.text) }
        return parts.joined(separator: ", ")
    }
}

/// Tells of a click on a part of a take's header. Without anybody to tell, the
/// part listens for no click.
private struct PressReport: ViewModifier {
    let onPress: (@MainActor () -> Void)?

    func body(content: Content) -> some View {
        if let onPress {
            content.onTapGesture { onPress() }
        } else {
            content
        }
    }
}

/// The waveform of one take, with the take's words on a line above it when
/// the row shows them.
private struct TakeLaneBody: View {
    @Environment(\.timelinePalette) private var palette

    let take: TakeRow
    /// Where the take lies in the song, in song seconds.
    let range: ClosedRange<Double>
    let viewport: TimelineViewport
    let state: TakeRowState
    let showsText: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsText {
                // The line is kept also for a take without words, so every
                // waveform of the timeline has the same height.
                Text(take.text)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(
                        take.isActive ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, DesignTokens.Spacing.controlGap)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    .frame(height: DesignTokens.Sizes.takeTextLineHeight, alignment: .bottom)
                    // The row is narrow in the panel, so a line is often cut
                    // off. The pointer brings up all of it.
                    .help(take.text)
            }
            WaveformShape(levels: take.levels, range: range, viewport: viewport)
                .fill(take.isActive ? palette.clipWaveform : palette.inactiveTakeWaveform)
                .padding(.top, showsText ? 0 : DesignTokens.Spacing.small)
                .padding(.bottom, DesignTokens.Spacing.small)
        }
        .opacity(state == .aboutToBeDeleted ? DesignTokens.Opacity.aboutToBeDeleted : 1)
        .background { TakeRowBacking(isActive: take.isActive, state: state) }
    }
}

/// What lies behind a take's header and its row, on top of the row's own
/// background: the clip tint for the active take, and a faint light tint
/// while the pointer rests on the row.
private struct TakeRowBacking: View {
    @Environment(\.timelinePalette) private var palette

    let isActive: Bool
    let state: TakeRowState

    var body: some View {
        ZStack {
            if isActive {
                palette.clipFill
            }
            if state == .hovered {
                DesignTokens.Colors.rowHover
            }
        }
    }
}

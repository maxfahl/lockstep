import LockstepCore
import SwiftUI

/// What the takes list is drawn doing, besides its takes. The design lab sets
/// it for pictures. In a list that works (`TakesActions`) the real pointer
/// decides, and this is left as it starts.
public struct TakesListPointer: Sendable, Equatable {
    /// The number of the take the pointer rests on, if any.
    public var hoveredTakeNumber: Int?
    /// The pointer is on "Delete Other Takes": the button is lit, and every
    /// take except the chosen one is shown about to be deleted.
    public var isOnDeleteOthers: Bool

    public init(hoveredTakeNumber: Int? = nil, isOnDeleteOthers: Bool = false) {
        self.hoveredTakeNumber = hoveredTakeNumber
        self.isOnDeleteOthers = isOnDeleteOthers
    }
}

/// The takes of the selected clip's line, in the panel on the right: a small
/// timeline with one row per take (`TakeLane`), under the heading "Takes" with
/// which one is chosen ("3 of 5"), and "Delete Other Takes" under the rows.
///
///     TakesList(
///         takes: content.timeline.takeRows,
///         clipRange: clip.timeRange,
///         songLength: content.timeline.songLength,
///         beats: content.timeline.beats,
///         playhead: playhead,
///         actions: actions.takes
///     )
///
/// Each row has the take's Play button, its number, a tick on the chosen
/// take, the take's words on one line and its waveform. The chosen take is in
/// the accent tone, the others are neutral. The rows lie in the shared
/// `Timeline`: the same beat lines as the main timeline and the same playhead
/// through every row, so a take that is played can be followed by eye.
///
/// Size: it fills the width it is given and is as tall as its rows. It never
/// scrolls by itself. With more takes than fit, the panel it lies in scrolls.
///
/// The surface: it draws none. Its rows are plain and dark, because they lie
/// on the glass of the panel.
///
/// Making it work: by itself nothing in the list does anything, which is how
/// the design lab shows it. With `actions` a click on a take's row is reported
/// (`TakesActions.rowPressed`), and so is a press on a take's Play button
/// (`TakesActions.playPressed`) and on "Delete Other Takes". The list then
/// also follows the pointer: the row under it is shown as the one a click
/// would choose, and with the pointer on "Delete Other Takes" the takes that
/// would go are shown about to be deleted.
public struct TakesList: View {
    /// How much is added before the first take and after the last one, as a
    /// share of the time the takes cover, so no waveform touches the edge.
    private static let marginShare = 0.04

    private static let timelineOptions = TimelineOptions(
        showsRuler: false,
        headerWidth: DesignTokens.Sizes.headerWidthNarrow
    )

    private let takes: [TakeRow]
    private let clipRange: ClosedRange<Double>
    private let songLength: Double
    private let beats: TimelineBeats
    private let playhead: PlayheadPosition
    private let pointer: TakesListPointer
    private let actions: TakesActions?

    /// The list has a scale of its own: it shows only the few seconds of the
    /// takes across its width.
    @State private var scale = TimelineScale(pointsPerSecond: 0)

    /// The numbers of the takes whose header and whose waveform the pointer
    /// is on. Followed only in a list that works (`actions`).
    @State private var hoveredHeader: Int?
    @State private var hoveredBody: Int?
    /// The pointer is on "Delete Other Takes". Followed only in a list that works.
    @State private var isPointerOnDeleteOthers = false

    /// - Parameters:
    ///   - takes: The takes of the line, in the order they were recorded.
    ///   - clipRange: The time of the clip the takes belong to, in song
    ///     seconds. A take without a range of its own lies here.
    ///   - songLength: Seconds. The list never shows time beyond the end of
    ///     the song.
    ///   - beats: The beat grid of the song, the one the main timeline draws.
    ///   - playhead: Where the playhead is: the same `PlayheadPosition` as
    ///     the main timeline has.
    ///   - pointer: Draws the list as if the pointer were somewhere on it.
    ///     The design lab uses it for pictures.
    ///   - actions: What is told when something in the list is used. Left
    ///     out, nothing in the list does anything.
    public init(
        takes: [TakeRow],
        clipRange: ClosedRange<Double>,
        songLength: Double,
        beats: TimelineBeats,
        playhead: PlayheadPosition,
        pointer: TakesListPointer = TakesListPointer(),
        actions: TakesActions? = nil
    ) {
        self.takes = takes
        self.clipRange = clipRange
        self.songLength = songLength
        self.beats = beats
        self.playhead = playhead
        self.pointer = pointer
        self.actions = actions
    }

    /// The numbers of every take except the chosen one: what "Delete Other
    /// Takes" removes.
    private var otherTakeNumbers: Set<Int> {
        Set(takes.filter { !$0.isActive }.map(\.number))
    }

    /// Where the pointer is drawn to be: as handed in, and in a list that
    /// works where the real pointer is.
    private var shownPointer: TakesListPointer {
        guard actions != nil else { return pointer }
        return TakesListPointer(
            hoveredTakeNumber: hoveredBody ?? hoveredHeader,
            isOnDeleteOthers: isPointerOnDeleteOthers
        )
    }

    /// The stretch of the song the rows show: from the earliest start to the
    /// latest end of the takes, with a small margin on both sides, and never
    /// beyond the song.
    private var shownRange: ClosedRange<Double> {
        var lower = clipRange.lowerBound
        var upper = clipRange.upperBound
        for take in takes {
            guard let range = take.range else { continue }
            lower = min(lower, range.lowerBound)
            upper = max(upper, range.upperBound)
        }
        let margin = (upper - lower) * Self.marginShare
        return max(lower - margin, 0)...min(upper + margin, max(songLength, upper))
    }

    /// The pointer came onto a part of a take's row, or left it. The two
    /// parts are kept apart, because leaving one and coming onto the other
    /// are told in no fixed order.
    private func pointer(onTake number: Int, part: TakeLane.Part, isOver: Bool) {
        switch part {
        case .header:
            if isOver { hoveredHeader = number } else if hoveredHeader == number { hoveredHeader = nil }
        case .body:
            if isOver { hoveredBody = number } else if hoveredBody == number { hoveredBody = nil }
        }
    }

    /// What the rows tell of the pointer, in a list that works.
    private var hoverReport: (@MainActor (Int, TakeLane.Part, Bool) -> Void)? {
        guard actions != nil else { return nil }
        return { number, part, isOver in
            pointer(onTake: number, part: part, isOver: isOver)
        }
    }

    public var body: some View {
        let pointer = shownPointer
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            heading
            rows(pointer)
                .fixedSize(horizontal: false, vertical: true)
                .timelineOnGlass()
            DeleteOtherTakesButton(
                isAboutToDelete: pointer.isOnDeleteOthers,
                action: actions?.deleteOtherTakesPressed
            )
            .onHover { isOver in
                if actions != nil { isPointerOnDeleteOthers = isOver }
            }
        }
        // A take that is deleted takes its row away from under the pointer,
        // and the rows after it get new numbers.
        .onChange(of: takes.count) {
            hoveredHeader = nil
            hoveredBody = nil
            isPointerOnDeleteOthers = false
        }
    }

    /// "Takes", and at the right which one is chosen: "3 of 5". The same
    /// line as the headings of the panel it lies in.
    private var heading: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Text("Takes")
                .font(DesignTokens.Fonts.panelTitle)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .fixedSize()
            Spacer(minLength: 0)
            if let chosen = takes.first(where: \.isActive) {
                Text("\(chosen.number) of \(takes.count)")
                    .font(DesignTokens.Fonts.label)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
                    .help("\(chosen.displayName) is the chosen take")
            }
        }
    }

    /// The takes in the shared timeline. A click on a row is listened for only
    /// when somebody is told of it.
    private func rows(_ pointer: TakesListPointer) -> some View {
        let lanes = TakeLane.lanes(
            for: takes,
            range: clipRange,
            showsText: true,
            hovered: pointer.hoveredTakeNumber,
            aboutToBeDeleted: pointer.isOnDeleteOthers ? otherTakeNumbers : [],
            onHover: hoverReport,
            onPlay: actions?.playPressed,
            onPress: actions?.rowPressed
        )
        var timeline = Timeline(
            lanes: lanes,
            scale: $scale,
            range: shownRange,
            beats: beats,
            playhead: playhead,
            options: Self.timelineOptions
        )
        if let rowPressed = actions?.rowPressed {
            timeline = timeline.onLaneTap { tap in
                // A take's row has the take's number for its id.
                guard let number = tap.laneID.base as? Int else { return }
                rowPressed(number)
            }
        }
        return timeline
    }
}

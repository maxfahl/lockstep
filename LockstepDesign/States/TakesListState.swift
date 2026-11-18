import LockstepCore
import LockstepUI
import SwiftUI

extension LabState {
    /// The takes list of the panel on the right in every state it can be in,
    /// side by side, each on a glass panel as wide as the real one:
    ///
    /// - five takes, the third one chosen, and the pointer resting on the second,
    /// - the second take being played with the song: its Play button shows Stop,
    /// - the pointer on "Delete Other Takes": the button is lit and every take
    ///   except the chosen one is shown about to be deleted,
    /// - twelve takes. In the window the panel then scrolls.
    ///
    /// "One clip selected" shows the same list where it lives, under the
    /// controls of the clip.
    static let takesList = LabState("Takes list") {
        TakesListSheet()
    }
}

/// The takes list in its states, each with its name under it, on the plain
/// window background.
private struct TakesListSheet: View {
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xxLarge) {
                TakesListPanel(name: "Pointer on a take", takeCount: 5, pointer: TakesListPointer(hoveredTakeNumber: 2))
                TakesListPanel(name: "A take being played", takeCount: 5, playingTake: 2)
                TakesListPanel(
                    name: "Pointer on Delete Other Takes",
                    takeCount: 5,
                    pointer: TakesListPointer(isOnDeleteOthers: true)
                )
                TakesListPanel(name: "Twelve takes", takeCount: 12)
            }
            .padding(DesignTokens.Spacing.xxLarge)
        }
    }
}

/// One takes list on a glass panel of the inspector's width, with the name of
/// its state under it.
private struct TakesListPanel: View {
    private let name: String
    private let timeline: TimelineContent
    private let clipRange: ClosedRange<Double>
    private let pointer: TakesListPointer

    @State private var playhead: PlayheadPosition

    /// - Parameters:
    ///   - name: What the state is, written under the panel.
    ///   - takeCount: How many takes the line has.
    ///   - playingTake: The number of the take that is being played, if any.
    ///   - pointer: Where the pointer is drawn to be.
    init(name: String, takeCount: Int, playingTake: Int? = nil, pointer: TakesListPointer = TakesListPointer()) {
        var timeline = TakesListContent.make(takeCount: takeCount).timeline
        if let playingTake, let index = timeline.takeRows.firstIndex(where: { $0.number == playingTake }) {
            timeline.takeRows[index].isPlaying = true
        }
        self.name = name
        self.timeline = timeline
        self.clipRange = timeline.trackRows.flatMap(\.clips).first(where: \.isSelected)?.timeRange ?? 0...1
        self.pointer = pointer
        _playhead = State(initialValue: PlayheadPosition(seconds: timeline.playheadTime))
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.medium) {
            TakesList(
                takes: timeline.takeRows,
                clipRange: clipRange,
                songLength: timeline.songLength,
                beats: timeline.beats,
                playhead: playhead,
                pointer: pointer
            )
            .padding(DesignTokens.Spacing.panelPadding)
            .frame(width: DesignTokens.Sizes.inspectorWidth)
            .glassPanel()
            Text(name)
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
    }
}

/// The made-up content of the takes list: the window of the "Main" state, with
/// the selected clip given as many takes as asked for. Each take lies at a
/// slightly different place in the song and has its own words, the way real
/// takes of one line do.
private enum TakesListContent {
    /// The chosen take, as in `SampleContent.make()`.
    static let activeTake = 3

    /// How much earlier or later than the clip each take starts and ends, in
    /// seconds.
    static let startShifts: [Double] = [-0.08, 0.05, 0, -0.03, 0.10, 0.02, -0.06, 0.07, -0.02, 0.04, -0.05, 0.09]
    static let endShifts: [Double] = [-0.12, 0.11, 0, -0.06, 0.20, 0.03, -0.09, 0.14, 0.05, -0.04, 0.08, -0.02]

    /// The words of the takes. The empty one is a take that has not been
    /// written out yet.
    static let texts = [
        "Told myself I'd make it through, so I learned to stand alone.",
        "Told myself I'd make it through, so I learned to stand.",
        "Told myself I'd make it through, so I learned to stand alone.",
        "Told myself I'd make it, so I learned to stand alone.",
        "",
        "Told myself I'd make it through, I learned to stand alone.",
    ]

    static func make(takeCount: Int) -> MainLayoutContent {
        var content = SampleContent.makeMainLayout()
        var timeline = content.timeline
        let clips = timeline.trackRows.flatMap(\.clips)
        guard let clipRange = clips.first(where: \.isSelected)?.timeRange else { return content }

        // More takes than the made-up song has: the waveforms of its other
        // long clips stand in for the extra ones.
        let spareLevels = clips
            .filter { !$0.isSelected }
            .flatMap(\.segments)
            .filter { $0.range.upperBound - $0.range.lowerBound >= 2 }
            .map(\.levels)
        let levels = timeline.takeRows.map(\.levels) + spareLevels
        guard !levels.isEmpty, takeCount > 0 else { return content }

        timeline.takeRows = (1...takeCount).map { number in
            let index = number - 1
            let isActive = number == activeTake
            let start = clipRange.lowerBound + startShifts[index % startShifts.count]
            let end = clipRange.upperBound + endShifts[index % endShifts.count]
            return TakeRow(
                number: number,
                displayName: "Take \(number)",
                levels: levels[index % levels.count],
                isActive: isActive,
                // The chosen take is the clip itself, so it lies at the clip's time.
                range: isActive ? nil : start...end,
                text: isActive ? content.selectedClipText : texts[index % texts.count]
            )
        }

        // The playhead is inside the takes, so it shows in the list.
        timeline.playheadTime = 17.4
        timeline.timeText = "0:17"
        content.timeline = timeline
        return content
    }
}

import LockstepCore
import SwiftUI

/// The row that shows the song: its waveform, with the song's name in the
/// header. It stays pinned under the ruler while the track rows scroll.
///
///     Timeline(lanes: [AnyTimelineLane(SongLane(content: content)), ...], ...)
///
/// The timeline already draws the beats of an uncertain stretch dashed. This
/// row adds a faint light band behind such a stretch, so it can be found at a
/// glance even when zoomed far out.
///
/// A selected song (`isSelected`) has the accent mark down the left edge of
/// its header that a selected track has. A click on the header is reported
/// by the timeline, like a click on any row's header.
///
/// While the song's beats are being found, the header shows a progress ring
/// and what is being done under the song's name. Once there are beats, the
/// beat line under the pointer lights up, because beat lines are dragged in
/// this row. Dragging one, and the commands of the two right-click menus,
/// are reported to `onBeatMove`, `onSongCommand` and `onBeatOne`.
///
/// The song has edges like a clip: only `kept`, the part of it that is left
/// after cutting, is drawn, with an edge where something is cut away. Either
/// end lights up under the pointer and can be dragged, and so can the song
/// itself. The row only reports the drag (`onDrag`, see `SongDrag`): the
/// owner cuts or moves the song and hands the row its new `kept`.
public struct SongLane: TimelineLane {
    public let id: String
    /// The song's name, shown in the header.
    public var name: String
    /// The song is selected: its header has the mark of a selected track.
    public var isSelected = false
    /// The song's loudness blocks, spread over `range`.
    public var levels: WaveformLevels
    /// The song's waveform at every level of detail. When set, the row draws
    /// from it at the level that fits the zoom, in place of `levels`.
    public var waveform: SongWaveform?
    /// The stretch of the timeline the song covers, in song seconds.
    public var range: ClosedRange<Double>
    /// The part of the song that is left after cutting, in song seconds.
    /// Nil, which is what a row starts with, is the whole of `range`.
    public var kept: ClosedRange<Double>?
    /// Draws this edge as if the pointer were over it, for pictures.
    public var shownHoveredEdge: SongDrag.Part?
    /// Told when an edge of the song, or the song itself, is dragged: on
    /// every move and when it is let go. Nil leaves the song where it is.
    public var onDrag: (@MainActor (SongDrag) -> Void)?
    /// Stretches of the beat grid the app is unsure about, in song seconds.
    public var uncertainRanges: [ClosedRange<Double>]
    /// What the song's right-click menu ticks. Nil leaves the row without
    /// that menu.
    public var menu: SongMenu.Values?
    /// The beats, in song seconds, whose lines open the beat line's menu on
    /// a right-click in this row. Empty leaves the row without that menu.
    public var beatMenuTimes: [Double] = []
    /// Set while the song's beats are being found: the header shows the
    /// progress under the song's name.
    public var beatFinding: BeatFindingProgress?
    /// The beat lines that can be dragged in this row. The one under the
    /// pointer lights up (`beatLineHover`). Empty when there are none.
    public var beats: TimelineBeats = .none
    /// Draws this beat line as if the pointer were over it, for pictures.
    public var shownHoveredBeat: Double?
    /// Told where a beat line was dragged from and to, when it is let go.
    /// Nil leaves the beat lines where they are: nothing happens on a drag.
    public var onBeatMove: (@MainActor (BeatLineMove) -> Void)?
    /// Told which command about the beats was chosen in the song's menu.
    public var onSongCommand: (@MainActor (SongMenu.Command) -> Void)?
    /// Told the song seconds of the beat line whose "This Is Beat 1" was chosen.
    public var onBeatOne: (@MainActor (Double) -> Void)?

    public var height: CGFloat { DesignTokens.Sizes.songLaneHeight }

    public var isPinned: Bool { true }

    public init(
        id: String = "song",
        name: String,
        levels: WaveformLevels,
        range: ClosedRange<Double>,
        uncertainRanges: [ClosedRange<Double>] = []
    ) {
        self.id = id
        self.name = name
        self.levels = levels
        self.range = range
        self.uncertainRanges = uncertainRanges
    }

    /// The song row of some timeline content, covering the whole song.
    public init(content: TimelineContent) {
        self.init(
            name: content.songName,
            levels: content.songLevels,
            range: 0...max(content.songLength, 0),
            uncertainRanges: content.uncertainRanges
        )
        isSelected = content.songIsSelected
        waveform = content.songWaveform
        kept = content.keptRange
        beatFinding = content.beatFinding
        beats = content.beats
        shownHoveredBeat = content.shownHoveredBeat
        shownHoveredEdge = content.shownHoveredSongEdge
    }

    public func header() -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text(name)
                .font(DesignTokens.Fonts.laneName)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let beatFinding {
                BeatFindingIndicator(progress: beatFinding)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.headerPadding)
        // The whole header cell opens the menu, not only the name.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(DesignTokens.Colors.selectedTrackMark)
                    .frame(width: DesignTokens.Sizes.selectedTrackMarkWidth)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contentShape(Rectangle())
        .songMenu(ifShown: menu, onCommand: onSongCommand)
    }

    public func content(in viewport: TimelineViewport) -> some View {
        let kept = kept ?? range
        return SongLaneBody(
            levels: levels,
            waveform: waveform,
            range: range,
            kept: kept,
            uncertainRanges: uncertainRanges,
            viewport: viewport
        )
            .contentShape(Rectangle())
            .songMenu(ifShown: menu, onCommand: onSongCommand)
            .overlay(alignment: .topLeading) {
                BeatLineMenuTargets(times: beatMenuTimes, viewport: viewport, onBeatOne: onBeatOne)
            }
            .beatLineHover(beats: beats, viewport: viewport, shownBeat: shownHoveredBeat, onMove: onBeatMove)
            .songEdgeHover(kept: kept, viewport: viewport, shownEdge: shownHoveredEdge, onDrag: onDrag)
    }
}

/// What is drawn inside the song row: the bands behind the uncertain
/// stretches, and the waveform on top of them, both only where the song is
/// kept. Where its beginning or its end is cut away, the song ends in an edge.
private struct SongLaneBody: View {
    @Environment(\.timelinePalette) private var palette

    let levels: WaveformLevels
    let waveform: SongWaveform?
    let range: ClosedRange<Double>
    let kept: ClosedRange<Double>
    let uncertainRanges: [ClosedRange<Double>]
    let viewport: TimelineViewport

    var body: some View {
        Canvas { context, size in
            // Nothing of the song is drawn where it is cut away.
            let keptLeft = viewport.x(for: kept.lowerBound)
            let keptRight = viewport.x(for: kept.upperBound)
            guard keptRight > keptLeft else { return }
            let edgeWidth = DesignTokens.Lines.songEdgeWidth
            var edges = Path()
            // Less than a sample of difference is a song that is not cut, whose ends get no edge.
            let sample = 1 / Lockstep.sampleRate
            if kept.lowerBound > range.lowerBound + sample {
                edges.addRect(CGRect(x: keptLeft, y: 0, width: edgeWidth, height: size.height))
            }
            if kept.upperBound < range.upperBound - sample {
                edges.addRect(CGRect(x: keptRight - edgeWidth, y: 0, width: edgeWidth, height: size.height))
            }
            context.fill(edges, with: .color(palette.songWaveform))
            context.clip(to: Path(CGRect(x: keptLeft, y: 0, width: keptRight - keptLeft, height: size.height)))

            for stretch in uncertainRanges where stretch.overlaps(viewport.visibleRange) {
                let left = viewport.x(for: max(stretch.lowerBound, viewport.visibleRange.lowerBound))
                let right = viewport.x(for: min(stretch.upperBound, viewport.visibleRange.upperBound))
                context.fill(
                    Path(CGRect(x: left, y: 0, width: right - left, height: size.height)),
                    with: .color(palette.uncertainBand)
                )
            }

            let inset = DesignTokens.Spacing.small
            let box = CGRect(x: 0, y: inset, width: size.width, height: max(size.height - 2 * inset, 0))
            let shape: WaveformShape
            if let waveform {
                // The blocks that fit this zoom, and only those on screen.
                guard let shown = waveform.levels(in: viewport) else { return }
                shape = WaveformShape(levels: shown.levels, range: shown.range, viewport: viewport)
            } else {
                shape = WaveformShape(levels: levels, range: range, viewport: viewport)
            }
            context.fill(shape.path(in: box), with: .color(palette.songWaveform))
        }
    }
}

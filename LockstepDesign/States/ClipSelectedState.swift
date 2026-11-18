import LockstepCore
import LockstepUI
import SwiftUI

extension LabState {
    /// One clip is selected and the timeline is zoomed in on it, so its
    /// timing marks can be read: a marker at every syllable, in all three
    /// timing colours, two of them hollow (excluded), and the sub-beat lines
    /// between the beat lines, four to a beat. The readout "23 ms late" is
    /// shown at the third marker, as if the pointer were there.
    static let clipSelected = LabState("Clip selected") {
        ClipSelectedWindow(
            content: ClipSelectedContent.make(subBeatsPerBeat: 4, syllables: ClipSelectedContent.sixteenthLine)
        )
    }

    /// The same clip with its lines in triplets: six sub-beats to a beat
    /// across the clip, and the ringed "3" in its bar. The readout is shown
    /// at the hollow marker, so it also says "excluded".
    static let clipSelectedTriplets = LabState("Clip selected, triplets") {
        ClipSelectedWindow(
            content: ClipSelectedContent.make(subBeatsPerBeat: 6, syllables: ClipSelectedContent.tripletLine)
        )
    }

    /// The first state with the whole song in view, as "Main" starts. There
    /// is no room for dots or sub-beat lines, so the markers are thin ticks.
    static let clipSelectedZoomedOut = LabState("Clip selected, zoomed out") {
        LabMainLayout(
            content: ClipSelectedContent.make(subBeatsPerBeat: 4, syllables: ClipSelectedContent.sixteenthLine),
            showsInspector: true
        )
    }

    /// The first state with the track rows as low as Shift and scroll makes
    /// them, half the usual height. A clip still shows its bar, a strip of
    /// waveform and its markers, which are smaller here: less room around
    /// them and a shorter tick. The readout has no room under the tick, so
    /// it stands beside its marker.
    static let tracksLow = LabState("Tracks low") {
        ClipSelectedWindow(
            content: ClipSelectedContent.make(subBeatsPerBeat: 4, syllables: ClipSelectedContent.sixteenthLine),
            trackHeight: TrackHeight.range.lowerBound
        )
    }

    /// The same with the track rows as tall as they get, four times the
    /// usual height. The waveform fills the height. The bar and the markers
    /// keep their size and stay at the top of the clip.
    static let tracksTall = LabState("Tracks tall") {
        ClipSelectedWindow(
            content: ClipSelectedContent.make(subBeatsPerBeat: 4, syllables: ClipSelectedContent.sixteenthLine),
            trackHeight: TrackHeight.range.upperBound
        )
    }
}

// MARK: - The window

/// The whole window with the inspector open, zoomed in so that the selected
/// clip fills the timeline from side to side, at any window size. With
/// `trackHeight` the track rows have that height in place of the usual one.
/// The states of a clip's effects use it too (`EffectsStates.swift`).
struct ClipSelectedWindow: View {
    private let content: MainLayoutContent
    private let trackHeight: CGFloat?
    /// The place in the song of the clip that is shown: the selected one, unless the state says another.
    private let clipRange: ClosedRange<Double>?

    @State private var scale: TimelineScale
    @State private var playhead: PlayheadPosition

    /// The empty stretch of the song shown before and after the clip, in seconds.
    private static let roomAroundClip = 0.3
    /// The width of the lab's window when it opens.
    private static let startingWindowWidth: CGFloat = 1200

    /// - Parameter zoomOn: the stretch of the song to show, for a state in which no clip is selected. Left
    ///   out, the selected clip's.
    init(content: MainLayoutContent, trackHeight: CGFloat? = nil, zoomOn: ClosedRange<Double>? = nil) {
        let clipRange = zoomOn ?? content.timeline.trackRows.flatMap(\.clips).first(where: \.isSelected)?.timeRange
        self.content = content
        self.trackHeight = trackHeight
        self.clipRange = clipRange
        _scale = State(initialValue: Self.zoom(on: clipRange, windowWidth: Self.startingWindowWidth))
        _playhead = State(initialValue: PlayheadPosition(seconds: content.timeline.playheadTime))
    }

    var body: some View {
        GeometryReader { proxy in
            MainLayout(
                content: content,
                features: .lab,
                scale: $scale,
                trackHeight: trackHeight.map { .constant($0) },
                playhead: playhead,
                showsInspector: true
            )
                .onChange(of: proxy.size.width, initial: true) { _, width in
                    // A moment later, so that this zoom is set after the
                    // timeline has checked the zoom it started with.
                    Task { @MainActor in
                        scale = Self.zoom(on: clipRange, windowWidth: width)
                    }
                }
        }
    }

    /// The zoom that shows the clip with a little room on both sides. The
    /// width of the row bodies is worked out from the design values: the
    /// window without its insets, the inspector and the header column.
    private static func zoom(on clipRange: ClosedRange<Double>?, windowWidth: CGFloat) -> TimelineScale {
        let inset = DesignTokens.Spacing.windowInset
        let bodyWidth = windowWidth - 2 * inset
            - DesignTokens.Sizes.inspectorWidth - inset
            - DesignTokens.Sizes.headerWidth - DesignTokens.Spacing.laneGap
        guard let clipRange, bodyWidth > 0 else { return TimelineScale(pointsPerSecond: 0) }
        let shownSeconds = clipRange.upperBound - clipRange.lowerBound + 2 * roomAroundClip
        return TimelineScale(
            pointsPerSecond: Double(bodyWidth) / shownSeconds,
            scrollOffsetSeconds: clipRange.lowerBound - roomAroundClip
        )
    }
}

// MARK: - The made-up content

/// One made-up syllable of the selected clip.
struct FakeSyllable {
    /// How many sub-beats after the syllable before it this one is meant for.
    let step: Int
    /// How far from that sub-beat it starts, in milliseconds. Late is positive.
    let offset: Double
    var isExcluded = false
    /// The readout is shown at this syllable's marker.
    var showsReadout = false
}

/// The window of the "Main" state, with timing marks on its selected clip.
///
/// The syllables are made up first, each a chosen distance from a sub-beat
/// of the sample song. The clip's waveform is then made from them, with a
/// burst of sound starting at every syllable, so the markers stand where the
/// waveform rises, as they will on a real recording.
enum ClipSelectedContent {
    /// A line in sixteenths. A sub-beat is about 164 ms long here, so up to
    /// 16 ms counts as on the beat and more than 57 ms as deliberate. It has
    /// all four kinds of marker: on the beat, slightly off, deliberate (68
    /// late, 72 early), and two excluded ones.
    static let sixteenthLine = [
        FakeSyllable(step: 0, offset: 3),
        FakeSyllable(step: 1, offset: -8),
        FakeSyllable(step: 1, offset: 23, showsReadout: true),
        FakeSyllable(step: 1, offset: 5),
        FakeSyllable(step: 2, offset: -12),
        FakeSyllable(step: 1, offset: 41),
        FakeSyllable(step: 1, offset: 2),
        FakeSyllable(step: 1, offset: -31, isExcluded: true),
        FakeSyllable(step: 2, offset: 9),
        FakeSyllable(step: 1, offset: 68),
        FakeSyllable(step: 1, offset: -4),
        FakeSyllable(step: 1, offset: 28),
        FakeSyllable(step: 2, offset: -6, isExcluded: true),
        FakeSyllable(step: 1, offset: 14),
        FakeSyllable(step: 1, offset: -72),
        FakeSyllable(step: 2, offset: 1),
        FakeSyllable(step: 1, offset: 36),
    ]

    /// A line in triplets: most syllables on every second of the six
    /// sub-beats of a beat. A sub-beat is about 110 ms long here, so up to
    /// 11 ms counts as on the beat and more than 38 ms as deliberate.
    static let tripletLine = [
        FakeSyllable(step: 0, offset: 2),
        FakeSyllable(step: 2, offset: -6),
        FakeSyllable(step: 2, offset: 19),
        FakeSyllable(step: 2, offset: 4),
        FakeSyllable(step: 2, offset: -9),
        FakeSyllable(step: 4, offset: 27),
        FakeSyllable(step: 2, offset: 1),
        FakeSyllable(step: 1, offset: -3),
        FakeSyllable(step: 1, offset: 8),
        FakeSyllable(step: 2, offset: -24, isExcluded: true, showsReadout: true),
        FakeSyllable(step: 2, offset: 47),
        FakeSyllable(step: 2, offset: 5),
        FakeSyllable(step: 2, offset: -2),
        FakeSyllable(step: 2, offset: 15),
        FakeSyllable(step: 4, offset: 3),
    ]

    /// The limits of the three kinds of timing, as shares of the distance
    /// between two sub-beats. These are the values the app started with.
    private static let onBeatShare = 0.10
    private static let deliberateShare = 0.35

    /// The first syllable starts at least this long after the clip does, and
    /// the last one at least `roomAfterLast` before the clip ends. Seconds.
    private static let roomBeforeFirst = 0.08
    private static let roomAfterLast = 0.2

    static func make(subBeatsPerBeat: Int, syllables: [FakeSyllable]) -> MainLayoutContent {
        var content = SampleContent.makeMainLayout()
        var timeline = content.timeline
        guard let trackIndex = timeline.trackRows.firstIndex(where: { $0.clips.contains(where: \.isSelected) }),
              let clipIndex = timeline.trackRows[trackIndex].clips.firstIndex(where: \.isSelected),
              let range = timeline.trackRows[trackIndex].clips[clipIndex].timeRange
        else { return content }

        let grid = subBeats(of: timeline.beatLines.map(\.time), perBeat: subBeatsPerBeat)
            .filter { range.contains($0.time) }
        guard var slot = grid.firstIndex(where: { $0.time >= range.lowerBound + roomBeforeFirst }) else {
            return content
        }

        var markers: [LockstepUI.SyllableMarker] = []
        var shownReadout: UUID?
        for (number, syllable) in syllables.enumerated() {
            slot += syllable.step
            guard slot < grid.count else { break }
            let time = grid[slot].time + syllable.offset / 1000
            guard time <= range.upperBound - roomAfterLast else { break }

            let share = abs(syllable.offset) / 1000 / grid[slot].spacing
            let marker = LockstepUI.SyllableMarker(
                id: uuid(number),
                time: time,
                offsetMilliseconds: syllable.offset,
                timing: share <= onBeatShare ? .onBeat : share <= deliberateShare ? .slightlyOff : .deliberate,
                isExcluded: syllable.isExcluded
            )
            markers.append(marker)
            if syllable.showsReadout {
                shownReadout = marker.id
            }
        }

        let levels = voiceLevels(syllableStarts: markers.map(\.time), range: range)
        var clip = timeline.trackRows[trackIndex].clips[clipIndex]
        clip.segments = [ClipSegment(range: range, levels: levels)]
        clip.isTriplet = subBeatsPerBeat == 6
        clip.timingMarks = ClipTimingMarks(
            markers: markers,
            subBeatTimes: grid.filter { !$0.isBeat }.map(\.time),
            shownReadout: shownReadout
        )
        timeline.trackRows[trackIndex].clips[clipIndex] = clip
        // The inspector shows the takes of the clip. The take that plays is
        // the one on the clip, so it gets the same waveform.
        if let activeTake = timeline.takeRows.firstIndex(where: \.isActive) {
            timeline.takeRows[activeTake].levels = levels
        }
        content.timeline = timeline
        return content
    }

    /// One point of the grid: a beat, or a sub-beat between two beats.
    private struct GridPoint {
        let time: Double
        let isBeat: Bool
        /// The distance to the next point, in seconds.
        let spacing: Double
    }

    /// Every beat with the sub-beats after it, spaced evenly up to the next beat.
    private static func subBeats(of beatTimes: [Double], perBeat: Int) -> [GridPoint] {
        zip(beatTimes, beatTimes.dropFirst()).flatMap { beat, nextBeat in
            let spacing = (nextBeat - beat) / Double(perBeat)
            return (0..<perBeat).map { number in
                GridPoint(time: beat + spacing * Double(number), isBeat: number == 0, spacing: spacing)
            }
        }
    }

    /// A waveform with a burst of sound for every syllable. A burst rises
    /// quickly and dies away until the next syllable, or sooner when a pause
    /// follows. The sound begins a moment before the syllable's marker, which
    /// stands in the steep part of the rise. The states of a clip's aim use
    /// it too, for the lead's clip (`AimStates.swift`).
    static func voiceLevels(syllableStarts: [Double], range: ClosedRange<Double>) -> WaveformLevels {
        let blocksPerSecond = 400.0
        let leadIn = 0.012
        let longestBurst = 0.3
        let fade = 0.05
        let count = max(Int((range.upperBound - range.lowerBound) * blocksPerSecond), 1)
        var minimums = [Float](repeating: 0, count: count)
        var maximums = [Float](repeating: 0, count: count)
        for block in 0..<count {
            let time = range.lowerBound + (Double(block) + 0.5) / blocksPerSecond
            var burst = 0.0
            if let index = syllableStarts.lastIndex(where: { $0 - leadIn <= time }) {
                let start = syllableStarts[index] - leadIn
                let next = index + 1 < syllableStarts.count ? syllableStarts[index + 1] - leadIn : .infinity
                let progress = (time - start) / min(next - start, longestBurst)
                if progress < 1 {
                    burst = sin(.pi * pow(progress, 0.6))
                }
            }
            let edge = min(time - range.lowerBound, range.upperBound - time, fade) / fade
            let level = (0.05 + 0.62 * burst) * edge * (0.8 + 0.2 * roughness(block))
            maximums[block] = Float(level)
            minimums[block] = Float(-level * (0.85 + 0.15 * roughness(block + 7919)))
        }
        return WaveformLevels(minimums: minimums, maximums: maximums)
    }

    /// A number from 0 to 1 that looks random and is the same every time.
    private static func roughness(_ number: Int) -> Double {
        let value = sin(Double(number) * 12.9898) * 43758.5453
        return value - value.rounded(.down)
    }

    /// A fixed identity made from a small number, so a marker keeps its id.
    private static func uuid(_ number: Int) -> UUID {
        UUID(uuid: (0x51, 0x11, 0xAB, 0x1E, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, UInt8(number & 0xFF)))
    }
}

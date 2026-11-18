import LockstepCore
import LockstepUI
import SwiftUI

extension LabState {
    /// Every state a clip and its bar can be in, side by side, each at three
    /// zooms: zoomed in, and twice with a whole song in view, where clips are
    /// narrow.
    static let clips = LabState("Clips") {
        ClipsSheet()
    }
}

// MARK: - The sheet

/// Every clip example with its name under it, on the plain window background.
/// Each example sits in real track rows, so it has the row's glass under it
/// and the beat lines over it, as in the main window.
private struct ClipsSheet: View {
    @State private var examples = ClipExamples()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xLarge) {
                Text(
                    """
                    Every state three times, from left to right: zoomed in, with the whole sample song \
                    in view (the zoom Main starts at), and with a whole three-minute song in view. \
                    The open hand over a bar, the pointing hand over a take count and the resize \
                    pointer at an edge show only under the real pointer.
                    """
                )
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(minimum: ExampleRow.cellWidth, maximum: ExampleRow.cellWidth),
                        spacing: DesignTokens.Spacing.xxLarge,
                        alignment: .topLeading
                    )],
                    alignment: .leading,
                    spacing: DesignTokens.Spacing.xLarge
                ) {
                    ForEach(examples.all) { example in
                        cell(for: example)
                    }
                }
            }
            .padding(DesignTokens.Spacing.xxLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One example: its rows side by side, and its name under them.
    private func cell(for example: ClipExample) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            HStack(spacing: ExampleRow.gap) {
                ForEach(example.rows) { row in
                    ClipExampleRow(example: example, row: row, beats: examples.beats)
                }
            }
            Text(example.name)
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .lineLimit(1)
        }
        .frame(width: ExampleRow.cellWidth, alignment: .leading)
    }
}

/// One track row of an example at one zoom: a real timeline with that one row,
/// without a ruler and without headers, showing just the few seconds around
/// the example's clips.
private struct ClipExampleRow: View {
    let example: ClipExample
    let row: ExampleRow
    let beats: TimelineBeats

    /// Far before the song, so no playhead is drawn through the row.
    @State private var playhead = PlayheadPosition(seconds: -1000)

    var body: some View {
        Timeline(
            lanes: [AnyTimelineLane(StillTrackLane(
                lane: TrackLane(example.track, shownPointers: example.shownPointers)
            ))],
            // A zoom of zero means "fit the range to the width", and the range
            // is cut so that this gives the row's zoom.
            scale: .constant(TimelineScale(pointsPerSecond: 0)),
            range: example.range(shownIn: row),
            beats: beats,
            playhead: playhead,
            options: TimelineOptions(showsRuler: false, showsHeaders: false)
        )
        .frame(width: row.width, height: DesignTokens.Sizes.trackLaneHeight)
    }
}

/// A track row that stays where it is. A timeline puts the rows that can
/// scroll up and down in a scroll view of its own, and that one would catch
/// the scrolling of this sheet whenever the pointer is over a row.
private struct StillTrackLane: TimelineLane {
    let lane: TrackLane

    var id: UUID { lane.id }
    var height: CGFloat { lane.height }
    var isPinned: Bool { true }

    func content(in viewport: TimelineViewport) -> some View {
        lane.content(in: viewport)
    }
}

// MARK: - The examples

/// One row an example is shown in: how far it is zoomed in and how wide it is.
private struct ExampleRow: Identifiable {
    /// The zoom.
    let pointsPerSecond: Double
    /// The width of the row in points.
    let width: CGFloat
    /// How many seconds of empty row come before the first clip. Nil puts the
    /// example's middle in the middle of the row.
    var lead: Double?

    var id: Double { pointsPerSecond }

    /// Zoomed in: a line of two and a half seconds is about 130 points wide.
    static let zoomedIn = 56.0
    /// The whole sample song (64 seconds) in view in a window of the starting
    /// size. This is the zoom the state "Main" starts at.
    static let wholeSampleSong = 12.0
    /// A whole song of three and a half minutes in view.
    static let wholeLongSong = 4.0

    /// Between two rows of one example.
    static let gap = DesignTokens.Spacing.medium
    /// The width of one example. Four of them fit beside each other in the
    /// lab's window at its starting size.
    static let cellWidth: CGFloat = 270

    /// The three rows of most examples. With the two gaps they fill a cell.
    static let standard = [
        ExampleRow(pointsPerSecond: zoomedIn, width: 170),
        ExampleRow(pointsPerSecond: wholeSampleSong, width: 56),
        ExampleRow(pointsPerSecond: wholeLongSong, width: 28),
    ]
}

/// One state of a clip, or of a few clips together: what is on the track and
/// what the example is called.
private struct ClipExample: Identifiable {
    let name: String
    let track: TrackRow
    /// Clips drawn as if the pointer were over a part of them.
    let shownPointers: [UUID: ClipPart]
    /// The song time put in the middle of a row.
    let focus: Double
    let rows: [ExampleRow]

    var id: String { name }

    /// The stretch of the song a row shows.
    func range(shownIn row: ExampleRow) -> ClosedRange<Double> {
        let length = Double(row.width) / row.pointsPerSecond
        let firstStart = track.clips.compactMap(\.timeRange).map(\.lowerBound).min() ?? focus
        let start = row.lead.map { firstStart - $0 } ?? focus - length / 2
        return start...(start + length)
    }
}

/// The list of examples, made once. The waveforms and the beats are taken
/// from the sample song, so the clips look like the ones in "Main".
private struct ClipExamples {
    let beats: TimelineBeats
    private(set) var all: [ClipExample] = []

    /// The waveforms of the sample song's clips, to cut new clips from.
    private let voices: [WaveformLevels]
    private var clipCount = 0

    /// The sample clips have this many loudness blocks for a second of sound.
    private static let blocksPerSecond = 100.0
    /// Where an ordinary example line lies in the song: two and a half seconds.
    private static let line = 10.0...12.4

    init() {
        let sample = SampleContent.make()
        beats = sample.beats
        voices = sample.trackRows.flatMap(\.clips).flatMap(\.segments).map(\.levels)
        let line = Self.line

        add("Normal", [clip("Cold concrete under my shoes", [line])])
        add("Pointer over the clip", [clip("Cold concrete under my shoes", [line])], pointer: .body)
        add("Selected", [clip("Cold concrete under my shoes", [line], isSelected: true)])
        add("Several selected", [
            clip("Verse 1a", [10.0...10.9], isSelected: true),
            clip("Verse 1b", [10.95...11.85], isSelected: true),
            clip("Verse 1c", [11.9...12.8]),
        ])
        add("Muted", [clip("Nobody knows where we are going", [line], muted: true)])
        add("On a muted track", [clip("Clock keeps ticking but I hold my ground", [line])], trackMuted: true)
        add("Long name, cut off", [clip("Told myself I'd make it through", [10.5...11.9])])
        add("Typed name", [clip("Hook v2", [line])])
        add("No name and no words yet (just recorded)", [clip("", [line])])
        add("With takes", [clip("Told myself I'd make it through", [line], takeCount: 5, activeTake: 3)])
        add(
            "Pointer over the take count",
            [clip("Told myself I'd make it through", [line], takeCount: 5, activeTake: 3)],
            pointer: .takeCount
        )
        add("Triplets", [clip("Every bar another step ahead", [line], isTriplet: true)])
        add("Turned up", [clip("Writing lines until the morning", [line], volumeDB: 4)])
        add("Turned down", [clip("Writing lines until the morning", [line], volumeDB: -6)])
        add("Very short", [clip("Ja", [11.1...11.35])])
        // The row shows the end of the clip. Its start is far off to the left.
        add("Very long", [clip("Keep the rhythm till the sun comes up", [2.0...22.0])], focus: 21)
        add("Joined, with a gap", [clip("Building something out of nothing", [10.0...10.9, 11.5...12.4])])
        // Two rows instead of three, so the field of the narrow clip has
        // room to reach out to the right.
        add(
            "Being renamed",
            [clip("Hook v2", [10.0...12.2], isSelected: true, isBeingRenamed: true)],
            rows: [
                ExampleRow(pointsPerSecond: ExampleRow.zoomedIn, width: 138),
                ExampleRow(pointsPerSecond: ExampleRow.wholeSampleSong, width: 124, lead: 0.25),
            ]
        )
        // They share half a second, less than half of either, so they are
        // not takes of each other.
        add(
            "Overlapping a little",
            [
                clip("Streets remember every word I said", [10.0...12.0], takeCount: 3, activeTake: 2),
                clip("Every bar another step ahead", [11.5...13.1]),
            ],
            rows: [
                ExampleRow(pointsPerSecond: ExampleRow.zoomedIn, width: 190),
                ExampleRow(pointsPerSecond: ExampleRow.wholeSampleSong, width: 44),
                ExampleRow(pointsPerSecond: ExampleRow.wholeLongSong, width: 20),
            ]
        )
        add("Pointer over the bar, the drag handle", [clip("Cold concrete under my shoes", [line])], pointer: .bar)
        add("Pointer at the start edge, the trim handle", [clip("Cold concrete under my shoes", [line])], pointer: .startEdge)
        add(
            "Pointer at the end edge of a selected clip",
            [clip("Cold concrete under my shoes", [line], isSelected: true)],
            pointer: .endEdge
        )
        add("Every mark at once", [clip(
            "Subway lights are flickering below",
            [10.0...12.7],
            muted: true,
            takeCount: 5,
            activeTake: 3,
            volumeDB: 4,
            isTriplet: true
        )])
    }

    /// Adds one example. `pointer` draws its first clip as if the pointer
    /// were over that part. Without a `focus` the middle of the clips is in
    /// the middle of each row.
    private mutating func add(
        _ name: String,
        _ clips: [ClipBox],
        trackMuted: Bool = false,
        pointer: ClipPart? = nil,
        focus: Double? = nil,
        rows: [ExampleRow] = ExampleRow.standard
    ) {
        var shownPointers: [UUID: ClipPart] = [:]
        if let pointer, let first = clips.first {
            shownPointers[first.id] = pointer
        }
        let times = clips.compactMap(\.timeRange)
        let start = times.map(\.lowerBound).min() ?? 0
        let end = times.map(\.upperBound).max() ?? 0
        all.append(ClipExample(
            name: name,
            track: TrackRow(id: Self.uuid(all.count + 1, kind: 1), name: name, muted: trackMuted, clips: clips),
            shownPointers: shownPointers,
            focus: focus ?? (start + end) / 2,
            rows: rows
        ))
    }

    /// A made-up clip. Each of its pieces gets a waveform of its own.
    private mutating func clip(
        _ name: String,
        _ ranges: [ClosedRange<Double>],
        muted: Bool = false,
        isSelected: Bool = false,
        takeCount: Int = 1,
        activeTake: Int = 1,
        volumeDB: Double = 0,
        isTriplet: Bool = false,
        isBeingRenamed: Bool = false
    ) -> ClipBox {
        clipCount += 1
        var segments: [ClipSegment] = []
        for (index, range) in ranges.enumerated() {
            segments.append(ClipSegment(
                range: range,
                levels: voice(seconds: range.upperBound - range.lowerBound, number: clipCount + index)
            ))
        }
        return ClipBox(
            id: Self.uuid(clipCount, kind: 2),
            displayName: name,
            segments: segments,
            muted: muted,
            isSelected: isSelected,
            takeCount: takeCount,
            activeTakeNumber: activeTake,
            volumeDB: volumeDB,
            isTriplet: isTriplet,
            isBeingRenamed: isBeingRenamed
        )
    }

    /// A waveform of the given length, cut from one of the sample clips and
    /// started over where the sample is shorter.
    private func voice(seconds: Double, number: Int) -> WaveformLevels {
        let empty = WaveformLevels(minimums: [0], maximums: [0])
        let source = voices.isEmpty ? empty : voices[number % voices.count]
        let sourceCount = min(source.minimums.count, source.maximums.count)
        guard sourceCount > 0 else { return empty }
        let count = max(Int(seconds * Self.blocksPerSecond), 1)
        return WaveformLevels(
            minimums: (0..<count).map { source.minimums[$0 % sourceCount] },
            maximums: (0..<count).map { source.maximums[$0 % sourceCount] }
        )
    }

    /// A fixed identity made from a small number, so the same example keeps
    /// its id and the pointer's place survives a redraw.
    private static func uuid(_ number: Int, kind: UInt8) -> UUID {
        let low = UInt8(number & 0xFF)
        let high = UInt8((number >> 8) & 0xFF)
        return UUID(uuid: (0xC1, 0x1B, kind, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, high, low))
    }
}

import LockstepCore
import LockstepUI
import SwiftUI

// The states of dragging. Each shows a drag frozen at one moment. Nothing can
// be dragged yet.
//
// They all start from the made-up song of "Main" and keep the inspector
// folded away, so the timeline has the whole width of the window.

extension LabState {
    /// The selected clip of "Double" has been taken by its bar and is over
    /// the track "Ad-libs", a few seconds later in the song. It is drawn a
    /// little raised, with a shadow and a lit bar. A faint dashed mark stays
    /// where it was recorded. It has not snapped to anything.
    static let draggingClip = LabState("Dragging clip") {
        DraggingStates.window(DraggingStates.movingClip(toStart: 20.9, snap: nil))
    }

    /// The moved clip has snapped with its start to the end of the clip
    /// "Streets remember every word I said" on "Lead". A thin line in the
    /// accent colour runs from that clip's row down to the moved clip.
    static let snapped = LabState("Snapped") {
        let edge = DraggingStates.edgeOfOtherClip
        return DraggingStates.window(DraggingStates.movingClip(
            toStart: edge.time,
            snap: SnapMark(time: edge.time, kind: .clipEdge(trackID: edge.trackID))
        ))
    }

    /// The moved clip has snapped with its start to the playhead. The snap
    /// line lies behind the playhead and shows as a coloured edge on both
    /// sides of it, from the song row down to the moved clip.
    static let snappedToPlayhead = LabState("Snapped to playhead") {
        let playhead = SampleContent.make().playheadTime
        return DraggingStates.window(DraggingStates.movingClip(
            toStart: playhead,
            snap: SnapMark(time: playhead, kind: .playhead)
        ))
    }

    /// The clip has been moved to another track and has snapped back to the
    /// time it was recorded at, so its timing is unchanged. The snap line
    /// joins the mark at the recorded place and the moved clip.
    static let snappedToRecordedPlace = LabState("Snapped to recorded position") {
        let recorded = DraggingStates.recordedStart
        return DraggingStates.window(DraggingStates.movingClip(
            toStart: recorded,
            snap: SnapMark(time: recorded, kind: .recordedPlace)
        ))
    }

    /// The same as "Dragging clip" with snapping switched off: its button in
    /// the bar at the bottom is not lit.
    static let snappingOff = LabState("Snapping off") {
        var content = DraggingStates.movingClip(toStart: 20.9, snap: nil)
        content.snappingIsOn = false
        return DraggingStates.window(content)
    }

    /// The end of the clip "Hook v2" on "Ad-libs" has been taken by its edge
    /// and dragged inwards. The clip is shorter from that side, the sound
    /// that is left has not moved, and the held edge is a thin bright bar.
    /// It has not snapped to anything.
    static let trimmingClip = LabState("Trimming clip") {
        DraggingStates.window(DraggingStates.trimmingHook(edge: .end, to: 28.3, snap: nil))
    }

    /// The start of the same clip has been dragged outwards, so more of its
    /// recording is heard, and has snapped to the end of "Building something
    /// out of nothing" on "Double". The snap line runs from that clip's row
    /// down to the trimmed clip.
    static let trimmingSnapped = LabState("Trimming, snapped") {
        let content = SampleContent.makeMainLayout()
        guard let other = DraggingStates.track(named: "Double", in: content),
              other.clips.count > 1,
              let edge = other.clips[1].timeRange?.upperBound
        else { return DraggingStates.window(content) }
        return DraggingStates.window(DraggingStates.trimmingHook(
            edge: .start,
            to: edge,
            snap: SnapMark(time: edge, kind: .clipEdge(trackID: other.id))
        ))
    }

    /// A stretch of the track "Double" is marked: a see-through band in the
    /// accent colour with a thin edge at each end. It goes through the middle
    /// of a clip and over the empty row beside it.
    static let markedStretch = LabState("Marked stretch") {
        var content = SampleContent.makeMainLayout()
        if let track = DraggingStates.track(named: "Double", in: content) {
            content.timeline.dragging.markedStretch = MarkedStretch(trackID: track.id, range: 21.2...24.8)
        }
        return DraggingStates.window(content)
    }

    /// A drag that started in the row of "Double" has gone down into the row
    /// of "Ad-libs", so it is a rectangle over both: one band with the look of
    /// the marked stretch and a thin edge on every side, over the gap between
    /// the rows too. The two clips it touches are selected, the one on
    /// "Ad-libs" although only its start is inside. The track the drag started
    /// on is the selected one.
    static let selectionRectangle = LabState("Selection rectangle") {
        DraggingStates.window(DraggingStates.selecting(from: "Double", to: "Ad-libs", range: 21.0...27.4))
    }

    /// The drag started on the first track and has reached the last one: the
    /// rectangle covers every track, and a clip on each of them is selected.
    static let selectionRectangleAllTracks = LabState("Selection rectangle over all tracks") {
        DraggingStates.window(DraggingStates.selecting(from: "Lead", to: "Ad-libs", range: 8.0...24.6))
    }

    /// The drag started on the lowest track, "Ad-libs", and has gone up two
    /// rows, to "Lead 2". It looks the same as one that goes down. Only the
    /// selected track tells where it started.
    static let selectionRectangleUpwards = LabState("Selection rectangle, upwards") {
        DraggingStates.window(DraggingStates.selecting(from: "Ad-libs", to: "Lead 2", range: 33.0...45.5))
    }

    /// Loop is switched on for a marked stretch of two bars. The stretch is
    /// drawn on the track and also in the ruler, and the Loop button is lit.
    static let loop = LabState("Loop") {
        var content = SampleContent.makeMainLayout()
        let range = DraggingStates.twoBars(in: content)
        if let track = DraggingStates.track(named: "Double", in: content) {
            content.timeline.dragging.markedStretch = MarkedStretch(trackID: track.id, range: range)
        }
        content.timeline.dragging.loopRange = range
        content.isLooping = true
        return DraggingStates.window(content)
    }

    /// The loop's in and out are set with I and O, two bars apart, and Loop
    /// is off. Only the ruler shows them: a faint band with a bracket at each
    /// end, and nothing over the rows. The Loop button is not lit.
    static let loopInAndOut = LabState("Loop in and out, Loop off") {
        var content = SampleContent.makeMainLayout()
        let range = DraggingStates.twoBars(in: content)
        content.timeline.dragging.loopInOut = LoopInOut(inTime: range.lowerBound, outTime: range.upperBound)
        return DraggingStates.window(content)
    }

    /// Only the in is set, and Loop is off. The band reaches from the in to
    /// the end of the song, with a bracket at the in only.
    static let loopInOnly = LabState("Loop in only, Loop off") {
        var content = SampleContent.makeMainLayout()
        let range = DraggingStates.twoBars(in: content)
        content.timeline.dragging.loopInOut = LoopInOut(inTime: range.lowerBound)
        return DraggingStates.window(content)
    }

    /// Only the out is set, and Loop is off. The band reaches from the start
    /// of the song to the out, with a bracket at the out only.
    static let loopOutOnly = LabState("Loop out only, Loop off") {
        var content = SampleContent.makeMainLayout()
        let range = DraggingStates.twoBars(in: content)
        content.timeline.dragging.loopInOut = LoopInOut(outTime: range.upperBound)
        return DraggingStates.window(content)
    }

    /// The header of the last track, "Ad-libs", has been dragged up. It is
    /// drawn lifted, with a shadow, over the rows it has reached. Its own row
    /// is dimmed, and a line in the accent colour between "Lead" and
    /// "Lead 2" shows where the track will land.
    static let reordering = LabState("Reordering") {
        var content = SampleContent.makeMainLayout()
        if let moved = DraggingStates.track(named: "Ad-libs", in: content),
           let below = DraggingStates.track(named: "Lead 2", in: content) {
            let rowStep = DesignTokens.Sizes.trackLaneHeight + DesignTokens.Spacing.laneGap
            content.timeline.dragging.movedTrack = MovedTrack(
                track: moved,
                // Two rows up and a little more, so the header lies across
                // the gap the track will land in.
                draggedBy: -2 * rowStep - DesignTokens.Sizes.trackLaneHeight / 3,
                landing: .before(below.id)
            )
        }
        return DraggingStates.window(content)
    }
}

/// What the dragging states are made from.
@MainActor
private enum DraggingStates {
    /// The whole window with the inspector folded away.
    static func window(_ content: MainLayoutContent) -> some View {
        LabMainLayout(content: content, showsInspector: false)
    }

    static func track(named name: String, in content: MainLayoutContent) -> TrackRow? {
        content.timeline.trackRows.first { $0.name == name }
    }

    /// Where the selected clip of the made-up song was recorded.
    static var recordedStart: Double {
        SampleContent.make().trackRows.flatMap(\.clips).first(where: \.isSelected)?
            .timeRange?.lowerBound ?? 0
    }

    /// The end of the second clip on "Lead", an edge for the moved clip
    /// to snap to.
    static var edgeOfOtherClip: (time: Double, trackID: UUID) {
        let content = SampleContent.makeMainLayout()
        guard let track = track(named: "Lead", in: content),
              track.clips.count > 1,
              let end = track.clips[1].timeRange?.upperBound
        else { return (0, UUID()) }
        return (end, track.id)
    }

    /// The window with the selected clip of "Double" taken out of its track
    /// and held over "Ad-libs", starting at `start`.
    static func movingClip(toStart start: Double, snap: SnapMark?) -> MainLayoutContent {
        var content = SampleContent.makeMainLayout()
        guard let fromIndex = content.timeline.trackRows.firstIndex(where: { $0.name == "Double" }),
              let over = track(named: "Ad-libs", in: content),
              let clipIndex = content.timeline.trackRows[fromIndex].clips.firstIndex(where: \.isSelected)
        else { return content }

        var clip = content.timeline.trackRows[fromIndex].clips.remove(at: clipIndex)
        guard let recorded = clip.timeRange else { return content }
        let moveBy = start - recorded.lowerBound
        for index in clip.segments.indices {
            let range = clip.segments[index].range
            clip.segments[index].range = (range.lowerBound + moveBy)...(range.upperBound + moveBy)
        }
        content.timeline.dragging.movedClip = MovedClip(
            clip: clip,
            fromTrackID: content.timeline.trackRows[fromIndex].id,
            overTrackID: over.id,
            recordedRange: recorded,
            snap: snap
        )
        return content
    }

    /// The window with one edge of the clip "Hook v2" on "Ad-libs" held and
    /// dragged to `time`, inwards or outwards. The clip is drawn in its row
    /// with that edge there. The waveform that was there stays where it
    /// was: blocks are taken away at the held edge, or made-up ones added.
    static func trimmingHook(edge: ClipEdge, to time: Double, snap: SnapMark?) -> MainLayoutContent {
        var content = SampleContent.makeMainLayout()
        guard let row = content.timeline.trackRows.firstIndex(where: { $0.name == "Ad-libs" }),
              let index = content.timeline.trackRows[row].clips.firstIndex(where: { $0.displayName == "Hook v2" }),
              let segment = content.timeline.trackRows[row].clips[index].segments.first,
              edge == .start ? time < segment.range.upperBound : time > segment.range.lowerBound
        else { return content }
        let whole = segment.range.upperBound - segment.range.lowerBound
        var minimums = segment.levels.minimums
        var maximums = segment.levels.maximums
        let count = min(minimums.count, maximums.count)
        // How far the edge has gone, in blocks of the waveform. Above zero is outwards.
        let outwards = edge == .start ? segment.range.lowerBound - time : time - segment.range.upperBound
        let blocks = min(Int(abs(outwards) / whole * Double(count)), count)
        switch (edge, outwards > 0) {
        case (.start, true):
            minimums.insert(contentsOf: minimums.suffix(blocks), at: 0)
            maximums.insert(contentsOf: maximums.suffix(blocks), at: 0)
        case (.start, false):
            minimums.removeFirst(blocks)
            maximums.removeFirst(blocks)
        case (.end, true):
            minimums.append(contentsOf: minimums.prefix(blocks))
            maximums.append(contentsOf: maximums.prefix(blocks))
        case (.end, false):
            minimums.removeLast(blocks)
            maximums.removeLast(blocks)
        }
        content.timeline.trackRows[row].clips[index].segments = [ClipSegment(
            range: edge == .start ? time...segment.range.upperBound : segment.range.lowerBound...time,
            levels: WaveformLevels(minimums: minimums, maximums: maximums)
        )]
        content.timeline.trackRows[row].clips[index].trimmedEdge = edge
        // The held clip is the selected one.
        for other in content.timeline.trackRows.indices {
            content.timeline.trackRows[other].isSelected = other == row
            for clip in content.timeline.trackRows[other].clips.indices {
                content.timeline.trackRows[other].clips[clip].isSelected = other == row && clip == index
            }
        }
        var trimmed = TrimmedClip(trackID: content.timeline.trackRows[row].id)
        trimmed.snap = snap
        content.timeline.dragging.trimmedClip = trimmed
        return content
    }

    /// The window in the middle of a drag that selects clips with a
    /// rectangle: it started in the row of the track named `start`, the
    /// pointer is in the row of the track named `end`, and it reaches over
    /// `range` of the song. The clips it touches on those tracks are the
    /// selected ones, and the track it started on is the selected track.
    static func selecting(from start: String, to end: String, range: ClosedRange<Double>) -> MainLayoutContent {
        var content = SampleContent.makeMainLayout()
        let rows = content.timeline.trackRows
        guard let first = rows.firstIndex(where: { $0.name == start }),
              let last = rows.firstIndex(where: { $0.name == end })
        else { return content }
        let covered = min(first, last)...max(first, last)
        for row in rows.indices {
            content.timeline.trackRows[row].isSelected = row == first
            for clip in rows[row].clips.indices {
                // Touched: some part of the clip is inside. Meeting at an edge is not enough.
                let isTouched = rows[row].clips[clip].timeRange.map {
                    $0.lowerBound < range.upperBound && $0.upperBound > range.lowerBound
                } ?? false
                content.timeline.trackRows[row].clips[clip].isSelected = covered.contains(row) && isTouched
            }
        }
        content.timeline.dragging.selectionRectangle = SelectionRectangle(
            firstTrackID: rows[first].id,
            lastTrackID: rows[last].id,
            range: range
        )
        return content
    }

    /// Two whole bars of the made-up song, starting at the first bar that
    /// begins after second 20.
    static func twoBars(in content: MainLayoutContent) -> ClosedRange<Double> {
        let barStarts = content.timeline.beatLines.filter(\.isBarStart).map(\.time)
        guard let first = barStarts.firstIndex(where: { $0 > 20 }), first + 2 < barStarts.count else {
            return 21...26
        }
        return barStarts[first]...barStarts[first + 2]
    }
}

import LockstepCore
import SwiftUI

/// The main timeline, put together from its parts: the ruler, the song row
/// pinned under it, one row per vocal track, and the "New Track" row under the
/// last track. `MainLayout` places this one view and does not assemble the
/// timeline itself.
///
///     @State private var scale = TimelineScale(pointsPerSecond: 0)
///     @State private var playhead = PlayheadPosition(seconds: content.playheadTime)
///
///     MainTimeline(content: content, scale: $scale, playhead: playhead)
///
/// Size: it fills the space it is given and has no padding of its own. The
/// track rows scroll up and down when they do not fit.
///
/// The scale: the timeline keeps it inside the song and writes the corrected
/// value back, so `TimelineScale(pointsPerSecond: 0)` means "fit the whole
/// song to the width". Keep it in the view that owns the window, so a zoom
/// control there can change it.
///
/// The playhead: hand every timeline on screen the same `PlayheadPosition`
/// (this one and the takes timeline), so they show the same playhead. The
/// timeline does not read `content.playheadTime`.
///
/// Dragging: what `content.dragging` holds is drawn on top of the rows (a
/// clip that is moved, a marked stretch, a track that is moved) and in the
/// ruler (the loop region). See `TimelineDragging`.
///
/// Right-click menus: `menus` says which of them are attached. See
/// `TimelineMenus`.
///
/// The height of the track rows: with `trackHeight`, scrolling with Shift
/// held anywhere over the timeline makes all track rows taller or lower
/// together, inside `TrackHeight.range`, and the new height is written back.
/// It needs `pinchesAndScrolls`. Without `trackHeight` the rows have the
/// height `DesignTokens.Sizes.trackLaneHeight` and Shift changes nothing.
///
/// Nothing else about its look can be chosen from outside: the width of the
/// header column, the heights of the other rows and everything else come from
/// the design values.
public struct MainTimeline: View {
    /// Inside a `TimelineScaleLink`, so a change of the scale does not make
    /// this view work out every row again: only the `Timeline` reads it.
    private let scaleLink: TimelineScaleLink
    private var scale: Binding<TimelineScale> { scaleLink.binding }
    private let trackHeight: Binding<CGFloat>?

    private let content: TimelineContent
    private let playhead: PlayheadPosition
    private let showsNewTrackRow: Bool
    private let menus: TimelineMenus
    private let onSeek: ((Double) -> Void)?
    private let onRulerDrag: ((TimelineRulerDrag) -> Void)?
    private let onTrackTap: ((UUID, Double) -> Void)?
    private let onBodyWidthChange: ((CGFloat) -> Void)?
    private let pinchesAndScrolls: Bool
    private let onBeatMove: (@MainActor (BeatLineMove) -> Void)?
    private let trackActions: TrackActions?
    private let clipActions: ClipActions?
    private var onSongDrag: (@MainActor (SongDrag) -> Void)?
    private var onSongHeaderTap: (@MainActor () -> Void)?
    /// Who keeps how far the track rows are scrolled, or nil. See `keepsRowsPosition(_:)`.
    private var rowsPosition: TimelineRowsPosition?
    /// What the drag in progress in a track's row started on.
    @State private var rowDrag = TrackRowDragMemory()

    /// - Parameters:
    ///   - content: The song, its beats and the tracks with their clips.
    ///   - scale: The zoom and the sideways scroll position. See "The scale" above.
    ///   - trackHeight: The height of every track row, which Shift and
    ///     scroll changes. See "The height of the track rows" above. Nil
    ///     keeps the rows at the design's height.
    ///   - playhead: Where the playhead is. See "The playhead" above.
    ///   - showsNewTrackRow: The row with the "New Track" button under the
    ///     last track. Off in the real app until tracks can be added.
    ///   - menus: Which right-click menus are attached. None unless asked for.
    ///   - onSeek: Told the song seconds of a click in the ruler or in the
    ///     song row, so the owner can move the playhead there. A drag is not
    ///     a click. Nil listens for no clicks.
    ///   - onRulerDrag: Told when the ruler is pressed, on every move of the
    ///     drag that follows and when the button is let go, so the owner can
    ///     move the playhead with the pointer. With it, a click in the ruler
    ///     is told here, as a drag that did not move, and not to `onSeek`. A
    ///     click in the song row still is. Nil leaves the ruler with clicks only.
    ///   - onTrackTap: Told the id of the track and the song seconds of a
    ///     click in a track's row, on a clip or beside one, so the owner can
    ///     select what is there. Nil listens for no clicks in track rows.
    ///   - onBodyWidthChange: Told the width of the lane bodies in points,
    ///     at the start and whenever it changes. Nil reports nothing.
    ///   - pinchesAndScrolls: A pinch zooms around the pointer and a sideways
    ///     scroll moves along the song. Scrolling with Option held zooms too,
    ///     with Command held it moves along the song, and with Shift held it
    ///     changes `trackHeight`. Off unless asked for.
    ///   - onBeatMove: Told where a beat line of the song row was dragged
    ///     from and to, when it is let go. Nil leaves the beat lines where
    ///     they are: nothing happens on a drag.
    ///   - trackActions: Who is told when a track's header or the "New
    ///     Track" button is used, and when a track is dragged by its header.
    ///     Nil leaves the track list a picture.
    ///   - clipActions: Who is told when a clip is dragged by its bar or by
    ///     one of its edges, when its bar is double-clicked, when the typing
    ///     of its name ends,
    ///     when a stretch of a track is marked by dragging across its row,
    ///     and when a syllable marker of a clip is clicked. Nil leaves the
    ///     clips pictures.
    public init(
        content: TimelineContent,
        scale: Binding<TimelineScale>,
        trackHeight: Binding<CGFloat>? = nil,
        playhead: PlayheadPosition,
        showsNewTrackRow: Bool = true,
        menus: TimelineMenus = .none,
        onSeek: ((Double) -> Void)? = nil,
        onRulerDrag: ((TimelineRulerDrag) -> Void)? = nil,
        onBodyWidthChange: ((CGFloat) -> Void)? = nil,
        pinchesAndScrolls: Bool = false,
        onBeatMove: (@MainActor (BeatLineMove) -> Void)? = nil,
        onTrackTap: ((UUID, Double) -> Void)? = nil,
        trackActions: TrackActions? = nil,
        clipActions: ClipActions? = nil
    ) {
        self.content = content
        self.scaleLink = TimelineScaleLink(binding: scale)
        self.trackHeight = trackHeight
        self.playhead = playhead
        self.showsNewTrackRow = showsNewTrackRow
        self.menus = menus
        self.onSeek = onSeek
        self.onRulerDrag = onRulerDrag
        self.onTrackTap = onTrackTap
        self.onBodyWidthChange = onBodyWidthChange
        self.pinchesAndScrolls = pinchesAndScrolls
        self.onBeatMove = onBeatMove
        self.trackActions = trackActions
        self.clipActions = clipActions
    }

    public var body: some View {
        let dragging = content.dragging
        let keptRange = content.keptRange
        let songLane = songLane
        // Every place below that asks where something is in a track's row
        // uses the same height the rows are drawn with.
        let rowHeight = trackHeight.map { TrackHeight.shown($0.wrappedValue) } ?? DesignTokens.Sizes.trackLaneHeight
        var timeline = Timeline(
            lanes: [AnyTimelineLane(songLane)]
                + TrackLane.lanes(
                    for: content.trackRows,
                    rowHeight: rowHeight,
                    showsNewTrackRow: showsNewTrackRow,
                    menus: menus,
                    actions: trackActions,
                    clipActions: clipActions
                ),
            scale: scale,
            range: content.shownRange,
            beats: content.beats,
            playhead: playhead,
            options: TimelineOptions(headerWidth: DesignTokens.Sizes.headerWidth)
        ) { viewport, beats in
            // The loop region lies behind the ticks and the bar numbers.
            if let loopRange = dragging.loopRange {
                LoopRegionMark(range: loopRange, viewport: viewport)
            } else if let inOut = dragging.loopInOut {
                LoopInOutMark(inOut: inOut, song: keptRange, viewport: viewport)
            }
            TimelineRuler(viewport: viewport, beats: beats, place: content.songPlace)
        }
        // The drag layer is worked out again whenever the rows scroll up or
        // down, so it is there only while it has something to draw.
        if !dragging.isEmpty {
            timeline = timeline.dragLayer { context in
                TimelineDragPicture(dragging: dragging, context: context)
            }
        }
        if let onSeek {
            timeline = timeline.onRulerTap(onSeek)
        }
        if let onRulerDrag {
            timeline = timeline.onRulerDrag(onRulerDrag)
        }
        if onSeek != nil || onTrackTap != nil || clipActions?.markerClicked != nil {
            let songLaneID = AnyHashable(songLane.id)
            let onSeek = onSeek
            let onTrackTap = onTrackTap
            let markerClicked = clipActions?.markerClicked
            let rows = content.trackRows
            let scale = scale
            timeline = timeline.onLaneTap { tap in
                if tap.laneID == songLaneID {
                    onSeek?(tap.seconds)
                } else if let trackID = tap.laneID.base as? UUID {
                    // Only a track's row has a UUID for its id.
                    // A click on a syllable marker is about that syllable,
                    // for an owner that listens. Every other click in the row
                    // is about the row.
                    if let markerClicked,
                       let hit = rows.first(where: { $0.id == trackID })?.marker(
                           atSeconds: tap.seconds,
                           y: tap.location.y,
                           pointsPerSecond: scale.wrappedValue.pointsPerSecond,
                           rowHeight: rowHeight
                       )
                    {
                        markerClicked(hit.clipID, hit.markerID)
                    } else {
                        onTrackTap?(trackID, tap.seconds)
                    }
                }
            }
        }
        let headerPressed = trackActions?.headerPressed
        if headerPressed != nil || onSongHeaderTap != nil {
            let songLaneID = AnyHashable(songLane.id)
            let onSongHeaderTap = onSongHeaderTap
            timeline = timeline.onHeaderTap { laneID in
                if laneID == songLaneID {
                    onSongHeaderTap?()
                } else if let trackID = laneID.base as? UUID {
                    // Only a track's row has a UUID for its id.
                    headerPressed?(trackID)
                }
            }
        }
        if let dragged = trackActions?.dragged {
            let trackIDs = content.trackRows.map(\.id)
            timeline = timeline.onHeaderDrag { drag in
                guard let trackID = drag.laneID.base as? UUID,
                      let move = TrackMove(
                          trackID: trackID,
                          among: trackIDs,
                          rowHeight: rowHeight,
                          draggedBy: drag.y - drag.startY,
                          isFinished: drag.isFinished
                      )
                else { return }
                dragged(move)
            }
        }
        let barDragged = clipActions?.barDragged
        let stretchDragged = clipActions?.stretchDragged
        let edgeDragged = clipActions?.edgeDragged
        if barDragged != nil || stretchDragged != nil || edgeDragged != nil {
            let rows = content.trackRows
            let rowDrag = rowDrag
            // The zoom at the moment a drag starts says how wide the edges of a clip are.
            let dragScale = scale
            // A stretch is marked, and an edge trimmed, after a shorter way
            // than SwiftUI starts a drag at. `TrackRowDragMemory` says when
            // each kind of drag counts.
            let startDistance = stretchDragged == nil && edgeDragged == nil
                ? TrackRowDragMemory.barStartDistance
                : TrackRowDragMemory.stretchStartDistance
            timeline = timeline.onLaneDrag(startingAfter: startDistance) { drag in
                // Only a track's row has a UUID for its id.
                guard let trackID = drag.laneID.base as? UUID,
                      let row = rows.first(where: { $0.id == trackID })
                else { return }
                // This is where a drag in a track's row is told apart by what
                // it started on. `TrackRowPart` lists the parts.
                let edgeZoom = edgeDragged == nil ? nil : dragScale.wrappedValue.pointsPerSecond
                switch rowDrag.part(of: drag, in: row, rowHeight: rowHeight, pointsPerSecond: edgeZoom) {
                case .clipEdge(let clipID, let edge):
                    // A drag from an edge of a clip trims that clip.
                    edgeDragged?(ClipEdgeDrag(
                        clipID: clipID,
                        trackID: trackID,
                        edge: edge,
                        startSeconds: drag.startSeconds,
                        x: drag.inBody.x,
                        isFinished: drag.isFinished
                    ))
                case .clipBar(let clipID):
                    barDragged?(ClipBarDrag(
                        clipID: clipID,
                        trackID: trackID,
                        startSeconds: drag.startSeconds,
                        x: drag.inBody.x,
                        rowsDown: Self.rowsDown(of: drag, rowHeight: rowHeight),
                        isFinished: drag.isFinished
                    ))
                case .clipBody, .emptyLane:
                    // A drag from anywhere but a bar marks a stretch of the
                    // track it started on, and with the pointer in another
                    // track's row it is a rectangle that selects clips. The
                    // owner tells them apart by the rows.
                    stretchDragged?(StretchDrag(
                        trackID: trackID,
                        startSeconds: drag.startSeconds,
                        x: drag.inBody.x,
                        rowsDown: Self.rowsDown(of: drag, rowHeight: rowHeight),
                        isFinished: drag.isFinished
                    ))
                case nil:
                    // The pointer has not gone far enough yet.
                    break
                }
            }
        }
        if let nameDoubleClicked = clipActions?.nameDoubleClicked {
            let rows = content.trackRows
            timeline = timeline.onLaneDoubleTap { tap in
                guard let trackID = tap.laneID.base as? UUID,
                      let row = rows.first(where: { $0.id == trackID })
                else { return }
                // The bar holds the name. A double-click anywhere else in the
                // row is only two clicks.
                let part = TrackRowPart(in: row, atSeconds: tap.seconds, y: tap.location.y, rowHeight: rowHeight)
                if case .clipBar(let clipID) = part {
                    nameDoubleClicked(clipID)
                }
            }
        }
        if let onBodyWidthChange {
            timeline = timeline.onBodyWidthChange(onBodyWidthChange)
        }
        if pinchesAndScrolls {
            timeline = timeline.pinchAndScroll()
            if let trackHeight {
                timeline = timeline.onRowHeightScroll { points in
                    // From the height as it is now, not as it was when the
                    // view was last worked out: several events can arrive
                    // between two frames.
                    let scrolled = TrackHeight.scrolled(trackHeight.wrappedValue, by: points)
                    if scrolled != trackHeight.wrappedValue {
                        trackHeight.wrappedValue = scrolled
                    }
                }
            }
        }
        timeline = timeline.keepsRowsPosition(rowsPosition)
        return timeline
    }

    /// How many whole rows below the track row a drag started in the pointer
    /// is now. Negative is above. Every whole row the pointer has passed is
    /// one track: a row and the gap under it.
    private static func rowsDown(of drag: TimelineLaneDrag, rowHeight: CGFloat) -> Int {
        let rowPitch = rowHeight + DesignTokens.Spacing.laneGap
        return Int((drag.inBody.y / rowPitch).rounded(.down))
    }

    /// The song row, with the song's and the beat lines' menus when asked
    /// for, and with what its menus and a dragged beat line report to.
    private var songLane: SongLane {
        var lane = SongLane(content: content)
        lane.menu = menus.song
        lane.onSongCommand = menus.onSongCommand
        if menus.showsBeatMenu {
            // Only the lines that are drawn: where the song is cut away there are none.
            lane.beatMenuTimes = content.beats.lines.map(\.time)
            lane.onBeatOne = menus.onBeatOne
        }
        lane.onBeatMove = onBeatMove
        lane.onDrag = onSongDrag
        return lane
    }

    /// Reports a drag of an edge of the song, or of the song itself, in the
    /// song row: on every move and when it is let go (`SongDrag`). Without
    /// it the song's edges light up under the pointer and nothing is reported.
    public func onSongDrag(_ action: (@MainActor (SongDrag) -> Void)?) -> MainTimeline {
        var copy = self
        copy.onSongDrag = action
        return copy
    }

    /// Reports a click on the header of the song row, so the owner can select
    /// the song. Without it the song's header listens for no click.
    public func onSongHeaderTap(_ action: (@MainActor () -> Void)?) -> MainTimeline {
        var copy = self
        copy.onSongHeaderTap = action
        return copy
    }

    /// Tells `position` how far the track rows are scrolled down, and scrolls them
    /// where it asks. See `TimelineRowsPosition`. Nil keeps the place to the timeline.
    public func keepsRowsPosition(_ position: TimelineRowsPosition?) -> MainTimeline {
        var copy = self
        copy.rowsPosition = position
        return copy
    }
}

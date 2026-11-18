import LockstepCore
import SwiftUI

/// What a timeline shows besides its rows.
public struct TimelineOptions: Equatable, Sendable {
    /// A strip above the rows for the ruler, with the head of the playhead in it.
    public var showsRuler: Bool
    /// A column of row headers to the left of the rows. It never scrolls sideways.
    public var showsHeaders: Bool
    /// The width of the header column. Take it from `DesignTokens.Sizes`.
    public var headerWidth: CGFloat

    public init(
        showsRuler: Bool = true,
        showsHeaders: Bool = true,
        headerWidth: CGFloat = DesignTokens.Sizes.headerWidth
    ) {
        self.showsRuler = showsRuler
        self.showsHeaders = showsHeaders
        self.headerWidth = headerWidth
    }
}

/// The timeline: rows of any kind on one shared scale, with the beat lines
/// and one playhead through all of them. The main timeline and the small takes
/// timeline are both this view, with different rows and options.
///
///     Timeline(
///         lanes: [AnyTimelineLane(SongLane(...))] + tracks.map { AnyTimelineLane(TrackLane($0)) },
///         scale: $scale,
///         range: 0...content.songLength,
///         beats: content.beats,
///         playhead: playhead,
///         options: TimelineOptions(headerWidth: DesignTokens.Sizes.headerWidth)
///     ) { viewport, beats in
///         TimelineRuler(viewport: viewport, beats: beats)
///     }
///
/// What it does, so that no row has to: it lays the rows out with their
/// headers, gives each row its background, keeps pinned rows under the ruler
/// while the others scroll up and down, draws the beat and bar lines through
/// every row, and draws the playhead on top. It knows nothing about songs,
/// tracks, clips or takes.
///
/// Size: it fills the space it is given. Its ideal height is the height of
/// its rows, so `.fixedSize(horizontal: false, vertical: true)` makes it
/// exactly as tall as its content (the small takes timeline).
///
/// The scale: the timeline keeps it inside `range`. It never shows more than
/// the range and never zooms closer than `TimelineScale` allows, and it writes
/// the corrected value back. So a scale that is zoomed out too far, such as
/// `TimelineScale(pointsPerSecond: 0)`, means "fit the whole range to the width".
///
/// The ruler: the closure at the end builds it, from the same viewport and
/// beats the rows are drawn with. It fills a strip of
/// `DesignTokens.Sizes.rulerHeight` above the lane bodies, with x = 0 at their
/// left edge. Without the closure the strip is empty. The strip is shown only
/// when `options.showsRuler` is on.
///
/// Pinch and scroll: after `pinchAndScroll()`, a pinch on the trackpad zooms
/// around the pointer and two fingers moved sideways scroll along the range,
/// anywhere over the timeline. Scrolling with Option held zooms around the
/// pointer too, and scrolling with Command held moves along the range, so a
/// mouse wheel can do both.
/// A drag with the middle mouse button held, started anywhere over the
/// timeline, moves what it shows by as far as the pointer moves: along the
/// range, and up and down through the rows that scroll when they do not all
/// fit. Nothing under the pointer reacts to that button.
/// The timeline changes the scale itself, inside the same limits as always.
/// Without it the timeline does not listen for any of them.
///
/// The height of the rows belongs to the lanes, so the timeline does not
/// change it. With `onRowHeightScroll`, scrolling with Shift held is reported
/// and the owner hands the timeline taller or lower lanes.
///
/// Reports and the drag layer are described in `TimelineReports.swift`.
public struct Timeline<Ruler: View>: View {
    @Environment(\.timelineLiesOnGlass) private var liesOnGlass
    @Environment(\.displayScale) private var displayScale
    @State private var scrollOffset = TimelineScrollOffset()
    /// Lets the timeline itself scroll the rows up and down, for a drag with
    /// the middle mouse button.
    @State private var rowsPosition = ScrollPosition(idType: Never.self)
    @State private var pinch = TimelinePinch()
    /// Hands the scale to the rows and the ruler without making them depend on it.
    @State private var scaleSource = TimelineScaleSource()
    /// Hands the reports to the rows the same way: a row that is left as it is still tells the owner's
    /// newest closures.
    @State private var reportsSource = TimelineReportsSource()
    @Binding private var scale: TimelineScale

    private let lanes: [AnyTimelineLane]
    private let range: ClosedRange<Double>
    private let beats: TimelineBeats
    private let playhead: PlayheadPosition
    private let options: TimelineOptions
    private let ruler: (TimelineViewport, TimelineBeats) -> Ruler
    private var reports = TimelineReports()
    private var dragLayer: ((TimelineDragLayerContext) -> AnyView)?
    private var respondsToPinchAndScroll = false
    /// Who keeps how far the rows are scrolled, or nil. See `keepsRowsPosition(_:)`.
    private var keptRowsPosition: TimelineRowsPosition?
    /// Tells this timeline, as its owner made it, from the one the owner
    /// makes next. See `TimelineMaking`.
    private let making = TimelineMaking()

    /// - Parameters:
    ///   - lanes: The rows from top to bottom, each wrapped in `AnyTimelineLane`.
    ///   - scale: The zoom and the sideways scroll position. See "The scale" above.
    ///   - range: The song seconds the timeline covers: the whole song, or the
    ///     few seconds of a clip.
    ///   - beats: The beat grid, drawn through every row. `content.beats`, or
    ///     `.none` when there is none.
    ///   - playhead: Where the playhead is. Hand every timeline the same object.
    ///   - options: Whether there is a ruler and a header column, and how wide.
    ///   - ruler: Builds the ruler. See "The ruler" above.
    public init(
        lanes: [AnyTimelineLane],
        scale: Binding<TimelineScale>,
        range: ClosedRange<Double>,
        beats: TimelineBeats,
        playhead: PlayheadPosition,
        options: TimelineOptions = TimelineOptions(),
        @ViewBuilder ruler: @escaping (TimelineViewport, TimelineBeats) -> Ruler
    ) {
        self.lanes = lanes
        self._scale = scale
        self.range = range
        self.beats = beats
        self.playhead = playhead
        self.options = options
        self.ruler = ruler
    }

    public var body: some View {
        let layout = TimelineLayout(lanes: lanes, options: options)
        let _ = scaleSource.binding = _scale
        let _ = reportsSource.reports = reports
        GeometryReader { proxy in
            if respondsToPinchAndScroll {
                pinchedAndScrolled(content(size: proxy.size, layout: layout), size: proxy.size, layout: layout)
            } else {
                content(size: proxy.size, layout: layout)
            }
        }
        .frame(idealHeight: layout.contentHeight)
    }

    private func content(size: CGSize, layout: TimelineLayout) -> some View {
        let gap = DesignTokens.Spacing.laneGap
        let bodyWidth = max(size.width - layout.bodyMinX, 0)
        let fit = TimelineFit(scale: scale, range: range, bodyWidth: bodyWidth)
        let viewport = fit.viewport
        let page = TimelinePage(viewport: viewport, range: range, bodyWidth: bodyWidth, displayScale: displayScale)
        return VStack(alignment: .leading, spacing: gap) {
            if options.showsRuler {
                TimelineRulerStrip(
                    ruler: ruler(page.viewport, beats),
                    making: making,
                    pageViewport: page.viewport,
                    pageWidth: page.width,
                    range: range,
                    bodyWidth: bodyWidth,
                    scaleSource: scaleSource,
                    reports: reports
                )
                .equatable()
                .padding(.leading, layout.bodyMinX)
            }
            lanesBlock(layout: layout, viewport: viewport, page: page, bodyWidth: bodyWidth, width: size.width)
        }
        .overlay(alignment: .topLeading) {
            TimelinePlayheadView(
                position: playhead,
                scale: viewport.scale,
                width: bodyWidth,
                rulerHeight: options.showsRuler ? DesignTokens.Sizes.rulerHeight : nil
            )
            .frame(width: bodyWidth, height: min(size.height, layout.contentHeight), alignment: .topLeading)
            .padding(.leading, layout.bodyMinX)
        }
        .onChange(of: fit, initial: true) { _, fit in
            guard fit.bodyWidth > 0 else { return }
            let fitted = fit.fittedScale
            if fitted != scale {
                scale = fitted
            }
        }
        .onChange(of: bodyWidth, initial: true) { _, width in
            reports.bodyWidth?(width)
        }
    }

    /// The timeline listening for a pinch and for scrolling, over all the
    /// space it was given: also the empty space under its last row, where the
    /// pointer often is when a song has few tracks.
    private func pinchedAndScrolled(_ content: some View, size: CGSize, layout: TimelineLayout) -> some View {
        let bodyWidth = max(size.width - layout.bodyMinX, 0)
        let rowHeightScroll = reports.rowHeightScroll
        return content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .background {
                TimelineScrollCatcher(takesRowHeight: rowHeightScroll != nil) { scrolling in
                    switch scrolling {
                    case .sideways(let points):
                        scroll(byPoints: points, bodyWidth: bodyWidth)
                    case .zoom(let points, let x):
                        zoom(scrolledBy: points, atX: x - layout.bodyMinX, bodyWidth: bodyWidth)
                    case .rowHeight(let points):
                        rowHeightScroll?(points)
                    case .dragged(let distance, let isFirst):
                        scroll(byPoints: distance.width, bodyWidth: bodyWidth)
                        scrollRows(byPoints: distance.height, isFirst: isFirst)
                    }
                }
            }
            .modifier(TimelinePinchZoom(
                scaleSource: scaleSource,
                pinch: pinch,
                range: range,
                bodyMinX: layout.bodyMinX,
                bodyWidth: bodyWidth
            ))
    }

    /// The scale as it is right now, kept inside the range. It is read when a
    /// pinch or scroll event arrives, not when the view was last worked out,
    /// because several events can arrive between two frames.
    private func currentScale(bodyWidth: CGFloat) -> TimelineScale {
        TimelineFit(scale: scale, range: range, bodyWidth: bodyWidth).fittedScale
    }

    /// Two fingers moved sideways, or the middle mouse button dragged
    /// sideways: the rows move with them.
    private func scroll(byPoints deltaX: CGFloat, bodyWidth: CGFloat) {
        var moved = currentScale(bodyWidth: bodyWidth)
        guard bodyWidth > 0, moved.pointsPerSecond > 0 else { return }
        moved.scrollOffsetSeconds -= Double(deltaX) / moved.pointsPerSecond
        moved.clamp(range: range, viewWidth: Double(bodyWidth))
        if moved != scale {
            scale = moved
        }
    }

    /// The middle mouse button dragged up or down: the rows that scroll go
    /// with the pointer, as far as they can. When they all fit, nothing moves.
    ///
    /// The place they are sent to is counted on from the last one they were
    /// sent to in the same drag. What the scroll view says about itself is a
    /// frame old when several moves arrive between two frames.
    ///
    /// - Parameter isFirst: Whether this is the first move of its drag.
    private func scrollRows(byPoints deltaY: CGFloat, isFirst: Bool) {
        if isFirst {
            scrollOffset.aimedY = nil
        }
        let from = scrollOffset.aimedY ?? scrollOffset.y
        let aimed = min(max(from - deltaY, 0), scrollOffset.maxY)
        scrollOffset.aimedY = aimed
        guard aimed != from else { return }
        rowsPosition.scrollTo(y: aimed - scrollOffset.topInset)
    }

    /// Scrolling with Option held: zooms around the pointer, by 1 % of the
    /// zoom for every point scrolled, so it feels the same far out and close in.
    ///
    /// - Parameter x: Where the pointer is, counted from the left edge of the
    ///   lane bodies. Over the header column the left edge stays in place.
    private func zoom(scrolledBy points: CGFloat, atX x: CGFloat, bodyWidth: CGFloat) {
        var zoomed = currentScale(bodyWidth: bodyWidth)
        guard bodyWidth > 0, zoomed.pointsPerSecond > 0 else { return }
        zoomed.zoom(
            by: exp(Double(points) * 0.01),
            keepingSeconds: zoomed.seconds(forX: Double(x)),
            viewWidth: Double(bodyWidth)
        )
        zoomed.clamp(range: range, viewWidth: Double(bodyWidth))
        if zoomed != scale {
            scale = zoomed
        }
    }

    /// Brings the rows to the place `keptRowsPosition` asks for, once, or else tells
    /// it where they are. A place below the last row goes as far down as they reach.
    private func keepRowsPosition() {
        guard let kept = keptRowsPosition else { return }
        guard let wanted = kept.requestedY else {
            kept.y = scrollOffset.y
            return
        }
        kept.requestedY = nil
        let y = min(wanted, scrollOffset.maxY)
        kept.y = y
        if y != scrollOffset.y {
            rowsPosition.scrollTo(y: y - scrollOffset.topInset)
        }
    }

    /// The rows: the pinned ones first, then the ones that scroll up and down,
    /// with the drag layer on top of both.
    private func lanesBlock(
        layout: TimelineLayout,
        viewport: TimelineViewport,
        page: TimelinePage,
        bodyWidth: CGFloat,
        width: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.laneGap) {
            if !layout.pinned.isEmpty {
                rows(layout.pinned, layout: layout, page: page, bodyWidth: bodyWidth)
            }
            if !layout.scrolling.isEmpty {
                ScrollView(.vertical) {
                    rows(layout.scrolling, layout: layout, page: page, bodyWidth: bodyWidth)
                }
                .scrollPosition($rowsPosition)
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: TimelineRowsScroll.self) { geometry in
                    TimelineRowsScroll(geometry)
                } action: { _, rows in
                    if scrollOffset.y != rows.y {
                        scrollOffset.y = rows.y
                    }
                    scrollOffset.maxY = rows.maxY
                    scrollOffset.topInset = rows.topInset
                    keepRowsPosition()
                }
                .onChange(of: keptRowsPosition?.requestedY) {
                    // A place asked for while the rows are already laid out: the
                    // geometry may not change, so it is reached a moment later.
                    Task { @MainActor in keepRowsPosition() }
                }
            }
        }
        .coordinateSpace(.timelineLanes)
        .overlay(alignment: .topLeading) {
            if let dragLayer {
                TimelineDragLayerHost(
                    content: dragLayer,
                    layout: layout,
                    viewport: viewport,
                    width: width,
                    scrollOffset: scrollOffset
                )
            }
        }
    }

    @ViewBuilder
    private func rows(
        _ lanes: [AnyTimelineLane],
        layout: TimelineLayout,
        page: TimelinePage,
        bodyWidth: CGFloat
    ) -> some View {
        let stack = VStack(alignment: .leading, spacing: DesignTokens.Spacing.laneGap) {
            ForEach(lanes) { lane in
                // Nothing a row is handed changes while the timeline moves
                // inside its page, so a move works no row out again. And a row
                // whose lane shows the same as before is left as it is when
                // the owner makes the timeline again, as after every edit.
                TimelineLaneRow(
                    lane: lane,
                    making: making,
                    pageViewport: page.viewport,
                    pageWidth: page.width,
                    range: range,
                    scaleSource: scaleSource,
                    beats: beats,
                    headerWidth: options.showsHeaders ? options.headerWidth : nil,
                    bodyMinX: layout.bodyMinX,
                    bodyWidth: bodyWidth,
                    reportsSource: reportsSource,
                    listens: TimelineRowListens(reports)
                )
                .equatable()
            }
        }
        // Glass rows that lie close together are drawn as one group, which is
        // what `GlassGroup` is for. The plain rows of a timeline on a glass
        // panel need no group.
        if liesOnGlass {
            stack
        } else {
            GlassGroup { stack }
        }
    }
}

extension Timeline where Ruler == EmptyView {
    /// A timeline without a ruler view: the small takes timeline, or any
    /// timeline whose ruler strip is switched off or left empty.
    public init(
        lanes: [AnyTimelineLane],
        scale: Binding<TimelineScale>,
        range: ClosedRange<Double>,
        beats: TimelineBeats,
        playhead: PlayheadPosition,
        options: TimelineOptions = TimelineOptions()
    ) {
        self.init(
            lanes: lanes,
            scale: scale,
            range: range,
            beats: beats,
            playhead: playhead,
            options: options,
            ruler: { _, _ in EmptyView() }
        )
    }
}

extension Timeline {
    /// Reports a click in the body of a row: which row and which moment in the song.
    public func onLaneTap(_ action: @escaping (TimelineLaneTap) -> Void) -> Timeline {
        var copy = self
        copy.reports.laneTap = action
        return copy
    }

    /// Reports a double-click in the body of a row: which row, which moment in
    /// the song and where in the row. The two clicks are also reported one by
    /// one to `onLaneTap`, each as it happens.
    public func onLaneDoubleTap(_ action: @escaping (TimelineLaneTap) -> Void) -> Timeline {
        var copy = self
        copy.reports.laneDoubleTap = action
        return copy
    }

    /// Lets a pinch zoom the timeline around the pointer and a sideways
    /// scroll move along it. See "Pinch and scroll" above.
    public func pinchAndScroll(_ isOn: Bool = true) -> Timeline {
        var copy = self
        copy.respondsToPinchAndScroll = isOn
        return copy
    }

    /// Tells `position` how far the rows that scroll up and down are scrolled,
    /// and scrolls them where it asks. See `TimelineRowsPosition`.
    public func keepsRowsPosition(_ position: TimelineRowsPosition?) -> Timeline {
        var copy = self
        copy.keptRowsPosition = position
        return copy
    }

    /// Reports scrolling with Shift held, anywhere over the timeline: how
    /// far, in points, positive when the rows should get taller. The owner
    /// then hands the timeline lanes of another height. It is heard only
    /// after `pinchAndScroll()`. Without it, Shift changes nothing about
    /// scrolling.
    public func onRowHeightScroll(_ action: @escaping (CGFloat) -> Void) -> Timeline {
        var copy = self
        copy.reports.rowHeightScroll = action
        return copy
    }

    /// Reports a click in the ruler: the moment in the song under the pointer.
    /// A drag in the ruler is not a click and is not reported.
    public func onRulerTap(_ action: @escaping (Double) -> Void) -> Timeline {
        var copy = self
        copy.reports.rulerTap = action
        return copy
    }

    /// Reports a press in the ruler and the drag that follows: when the button
    /// goes down, on every move and when it is let go. With it, a click in
    /// the ruler is the two reports of a drag that did not move, and
    /// `onRulerTap` is told nothing.
    public func onRulerDrag(_ action: @escaping (TimelineRulerDrag) -> Void) -> Timeline {
        var copy = self
        copy.reports.rulerDrag = action
        return copy
    }

    /// Reports the width of the lane bodies in points, when the timeline
    /// appears and whenever the width changes. Whoever moves the scale from
    /// outside (a zoom command, following the playhead) needs it to know what
    /// is on screen.
    public func onBodyWidthChange(_ action: @escaping (CGFloat) -> Void) -> Timeline {
        var copy = self
        copy.reports.bodyWidth = action
        return copy
    }

    /// Reports a drag that starts in the body of a row, on every move and
    /// when it ends.
    ///
    /// - Parameter distance: How far the pointer must have moved, in points,
    ///   before the press counts as a drag and the first report comes. Left
    ///   out, it is 10, the distance SwiftUI itself starts a drag at.
    public func onLaneDrag(
        startingAfter distance: CGFloat = 10,
        _ action: @escaping (TimelineLaneDrag) -> Void
    ) -> Timeline {
        var copy = self
        copy.reports.laneDrag = action
        copy.reports.laneDragStartDistance = distance
        return copy
    }

    /// Reports a click on the header of a row: the id of that row. A control
    /// in the header keeps its own clicks.
    public func onHeaderTap(_ action: @escaping (AnyHashable) -> Void) -> Timeline {
        var copy = self
        copy.reports.headerTap = action
        return copy
    }

    /// Reports a drag that starts on the header of a row, on every move and
    /// when it ends.
    public func onHeaderDrag(_ action: @escaping (TimelineHeaderDrag) -> Void) -> Timeline {
        var copy = self
        copy.reports.headerDrag = action
        return copy
    }

    /// Draws something on top of all rows and their headers, under the
    /// playhead: a clip on its way from one track to another, or a track
    /// being moved. It lets clicks through to the rows beneath.
    public func dragLayer(
        @ViewBuilder _ content: @escaping (TimelineDragLayerContext) -> some View
    ) -> Timeline {
        var copy = self
        copy.dragLayer = { AnyView(content($0)) }
        return copy
    }
}

// MARK: - One row

/// One row: its header cell and its body, with the beat lines on top of the body.
private struct TimelineLaneRow: View, Equatable {
    let lane: AnyTimelineLane
    /// Which making of the timeline the lane, the beats and the reports are from.
    let making: TimelineMaking
    /// What the row's content and its beat lines are drawn for, and how wide
    /// that is. See `TimelinePage`.
    let pageViewport: TimelineViewport
    let pageWidth: CGFloat
    /// The song seconds the timeline covers.
    let range: ClosedRange<Double>
    /// Where the scale is read from when a click or a drag arrives.
    let scaleSource: TimelineScaleSource
    let beats: TimelineBeats
    /// Nil when the timeline has no header column.
    let headerWidth: CGFloat?
    let bodyMinX: CGFloat
    let bodyWidth: CGFloat
    /// Where the owner's reports are read from when a click or a drag arrives.
    let reportsSource: TimelineReportsSource
    /// Which of the reports the owner listens for.
    let listens: TimelineRowListens

    /// The owner's reports as they are right now.
    private var reports: TimelineReports { reportsSource.reports }

    /// The moment in the song where the drag in progress started. It is kept
    /// from the first move, so it stays right if the timeline scrolls sideways
    /// during the drag.
    @State private var dragStartSeconds: Double?
    /// Where the row is among the rows, and where it was when the drag in
    /// progress started.
    @State private var place = TimelineRowPlace()

    /// Whether a row shows the same as another, so SwiftUI can leave it as it
    /// is.
    ///
    /// The lane holds closures and cannot be compared as a whole. While the
    /// timeline is the same making it is the same lane. When the owner has
    /// made the timeline again, as after every edit, the lane says for itself
    /// whether it shows the same (`TimelineLane.showsSame(as:)`), and the
    /// beats are compared. The reports are not handed to the row at all: it
    /// reads them when a click or a drag arrives (`reportsSource`), and only
    /// which of them are listened for is compared.
    nonisolated static func == (one: TimelineLaneRow, other: TimelineLaneRow) -> Bool {
        (one.making === other.making || (one.beats == other.beats && one.lane.showsSame(as: other.lane)))
            && one.listens == other.listens
            && one.lane.id == other.lane.id
            && one.pageViewport == other.pageViewport
            && one.pageWidth == other.pageWidth
            && one.range == other.range
            && one.headerWidth == other.headerWidth
            && one.bodyMinX == other.bodyMinX
            && one.bodyWidth == other.bodyWidth
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.laneGap) {
            if let headerWidth {
                headerCell(width: headerWidth)
            }
            bodyCell
        }
    }

    private func headerCell(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            lane.header()
        }
        .frame(width: width, height: lane.height, alignment: .leading)
        .modifier(TimelineRowSurface(part: .header, isOn: lane.hasRowSurface))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .timelineLanes)
                .onChanged { reportHeaderDrag($0, isFinished: false) }
                .onEnded { reportHeaderDrag($0, isFinished: true) },
            isEnabled: listens.headerDrag
        )
        .simultaneousGesture(
            TapGesture().onEnded { reports.headerTap?(lane.id) },
            isEnabled: listens.headerTap
        )
    }

    private var bodyCell: some View {
        TimelinePageShift(
            scale: scaleSource.shownBinding,
            range: range,
            bodyWidth: bodyWidth,
            content: ZStack(alignment: .topLeading) {
                lane.content(in: pageViewport)
                    .frame(width: pageWidth, height: lane.height, alignment: .topLeading)
                if lane.hasRowSurface {
                    TimelineBeatLines(beats: beats, viewport: pageViewport)
                }
            }
            .frame(width: pageWidth, height: lane.height, alignment: .topLeading)
        )
        .frame(width: bodyWidth, height: lane.height, alignment: .topLeading)
        .clipped()
        .modifier(TimelineRowSurface(part: .body, isOn: lane.hasRowSurface))
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture(coordinateSpace: .local)
                .onEnded { value in
                    reports.laneTap?(TimelineLaneTap(
                        laneID: lane.id,
                        seconds: screenScale.seconds(forX: Double(value.location.x)),
                        location: value.location
                    ))
                },
            isEnabled: listens.laneTap
        )
        // Together with the single click, so the first click of a double-click
        // is still reported at once and does not wait to see if a second follows.
        .simultaneousGesture(
            SpatialTapGesture(count: 2, coordinateSpace: .local)
                .onEnded { value in
                    reports.laneDoubleTap?(TimelineLaneTap(
                        laneID: lane.id,
                        seconds: screenScale.seconds(forX: Double(value.location.x)),
                        location: value.location
                    ))
                },
            isEnabled: listens.laneDoubleTap
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: listens.laneDragStartDistance, coordinateSpace: .timelineLanes)
                .onChanged { reportLaneDrag($0, isFinished: false) }
                .onEnded { reportLaneDrag($0, isFinished: true) },
            isEnabled: listens.laneDrag
        )
        // A drag is measured among all the rows, so that it can go on over
        // other rows. To say where in this row it started, the row has to
        // know where it lies among them.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .timelineLanes).minY
        } action: { minY in
            place.minY = minY
        }
    }

    /// The scale of what is on screen at this moment. Clicks and drags in the
    /// row are measured with it, from the screen's left edge.
    private var screenScale: TimelineScale {
        scaleSource.screenScale(range: range, bodyWidth: bodyWidth)
    }

    private func reportLaneDrag(_ value: DragGesture.Value, isFinished: Bool) {
        let screenScale = screenScale
        let seconds = screenScale.seconds(forX: Double(value.location.x - bodyMinX))
        let startSeconds = dragStartSeconds
            ?? screenScale.seconds(forX: Double(value.startLocation.x - bodyMinX))
        dragStartSeconds = isFinished ? nil : startSeconds
        // The row's place is kept from the first move too, so the drag is
        // measured from where the row was when it was grabbed.
        let rowMinY = place.dragStartMinY ?? place.minY
        place.dragStartMinY = isFinished ? nil : rowMinY
        reports.laneDrag?(TimelineLaneDrag(
            laneID: lane.id,
            startSeconds: startSeconds,
            seconds: seconds,
            startLocation: value.startLocation,
            location: value.location,
            startInBody: CGPoint(x: value.startLocation.x - bodyMinX, y: value.startLocation.y - rowMinY),
            inBody: CGPoint(x: value.location.x - bodyMinX, y: value.location.y - rowMinY),
            isFinished: isFinished
        ))
    }

    private func reportHeaderDrag(_ value: DragGesture.Value, isFinished: Bool) {
        reports.headerDrag?(TimelineHeaderDrag(
            laneID: lane.id,
            startY: value.startLocation.y,
            y: value.location.y,
            isFinished: isFinished
        ))
    }
}

/// Gives a row's body or header its background, unless the lane asked for none.
private struct TimelineRowSurface: ViewModifier {
    enum Part {
        case header
        case body
    }

    let part: Part
    let isOn: Bool

    func body(content: Content) -> some View {
        if !isOn {
            content
        } else {
            switch part {
            case .header: content.laneHeaderSurface()
            case .body: content.laneSurface()
            }
        }
    }
}

// MARK: - Moving along the song

/// One making of a timeline: its owner worked itself out and made the
/// timeline, with its lanes, beats, ruler and reports. Every such time gives
/// a new one, and while the timeline only follows its own scale and state it
/// stays the same.
///
/// The lanes and the reports hold closures, which cannot be compared. So a
/// row or the ruler says with this whether it was handed the same as before:
/// the same making means the same lanes, beats, ruler and reports.
final class TimelineMaking: Sendable {}

/// Where the rows get the owner's reports from without being handed them.
///
/// The reports are closures, which cannot be compared, and the owner makes
/// new ones every time it works itself out. A row that was handed them could
/// never be left as it is. So the timeline keeps this one object, puts the
/// newest reports in it every time it is worked out, and a row reads them
/// when a click or a drag arrives. No view watches it.
@MainActor
final class TimelineReportsSource {
    var reports = TimelineReports()
}

/// Which reports of a row the owner listens for: what decides which gestures
/// a row has. It can be compared, where the reports themselves cannot.
struct TimelineRowListens: Equatable {
    var laneTap: Bool
    var laneDoubleTap: Bool
    var laneDrag: Bool
    var laneDragStartDistance: CGFloat
    var headerDrag: Bool
    var headerTap: Bool

    init(_ reports: TimelineReports) {
        laneTap = reports.laneTap != nil
        laneDoubleTap = reports.laneDoubleTap != nil
        laneDrag = reports.laneDrag != nil
        laneDragStartDistance = reports.laneDragStartDistance
        headerDrag = reports.headerDrag != nil
        headerTap = reports.headerTap != nil
    }
}

/// Where the rows and the ruler get the scale from without depending on it.
///
/// A row that was handed the scale, or what is on screen, would be worked out
/// again on every move along the song, with its gestures and everything in
/// it. So a row is handed this object, which stays the same and which no view
/// watches. Only `TimelinePageShift`, a thin view around the row's content,
/// follows the scale, and a click or a drag reads it at the moment it arrives.
@MainActor
final class TimelineScaleSource {
    /// The timeline's own binding of its scale. The timeline sets it every
    /// time it is worked out. Nil before the first time.
    var binding: Binding<TimelineScale>?

    /// The binding for a view that follows the scale. Before the timeline has
    /// set one, a scale that fits everything, which nothing follows.
    var shownBinding: Binding<TimelineScale> {
        binding ?? .constant(TimelineScale(pointsPerSecond: 0))
    }

    /// The scale of what is on screen at this moment, kept inside `range` at
    /// the width of the lane bodies.
    func screenScale(range: ClosedRange<Double>, bodyWidth: CGFloat) -> TimelineScale {
        TimelineFit(scale: shownBinding.wrappedValue, range: range, bodyWidth: bodyWidth).fittedScale
    }
}

/// A pinch anywhere over the timeline zooms it around the pointer.
///
/// It is a modifier of its own, handed nothing that changes while the
/// timeline moves, so the gesture is made once. Made where the timeline works
/// itself out, it would be a new gesture on every move, and SwiftUI would
/// attach it again each time.
private struct TimelinePinchZoom: ViewModifier {
    let scaleSource: TimelineScaleSource
    let pinch: TimelinePinch
    let range: ClosedRange<Double>
    let bodyMinX: CGFloat
    let bodyWidth: CGFloat

    func body(content: Content) -> some View {
        // Together with whatever the rows listen for, so a row's own
        // clicks and drags never keep a pinch from being heard.
        content.simultaneousGesture(
            MagnifyGesture()
                .onChanged { zoom(pinch: $0) }
                .onEnded { _ in pinch.start = nil }
        )
    }

    /// Every step is worked out from the scale the pinch started with, so
    /// the moment in the song under the pointer stays where it is for the
    /// whole pinch.
    private func zoom(pinch value: MagnifyGesture.Value) {
        guard bodyWidth > 0, let scale = scaleSource.binding else { return }
        if pinch.start?.location != value.startLocation {
            pinch.start = (scaleSource.screenScale(range: range, bodyWidth: bodyWidth), value.startLocation)
        }
        guard let start = pinch.start, start.scale.pointsPerSecond > 0 else { return }
        var zoomed = start.scale
        zoomed.zoom(
            by: Double(value.magnification),
            keepingSeconds: start.scale.seconds(forX: Double(start.location.x - bodyMinX)),
            viewWidth: Double(bodyWidth)
        )
        zoomed.clamp(range: range, viewWidth: Double(bodyWidth))
        if zoomed != scale.wrappedValue {
            scale.wrappedValue = zoomed
        }
    }
}

/// Moves what was drawn for a page to where the screen is now. See `TimelinePage`.
///
/// It is the only view of a row, or of the ruler, that follows the scale. Its
/// content is handed over finished, so a move along the song changes the
/// shift and works nothing inside it out again.
private struct TimelinePageShift<Content: View>: View {
    @Environment(\.displayScale) private var displayScale
    @Binding var scale: TimelineScale
    let range: ClosedRange<Double>
    let bodyWidth: CGFloat
    /// What is moved, as wide as the page, with x = 0 at the page's left edge.
    let content: Content

    var body: some View {
        let screen = TimelineFit(scale: scale, range: range, bodyWidth: bodyWidth).viewport
        let page = TimelinePage(viewport: screen, range: range, bodyWidth: bodyWidth, displayScale: displayScale)
        content.transformEffect(CGAffineTransform(translationX: page.shift, y: 0))
    }
}

/// The strip of the ruler above the rows: what the owner draws in it, moved
/// with the page, and the clicks and drags in it.
///
/// Like a row, it is handed nothing that changes while the timeline moves
/// inside its page.
private struct TimelineRulerStrip<Ruler: View>: View, Equatable {
    /// What the owner draws, for the page.
    let ruler: Ruler
    /// Which making of the timeline the ruler and the reports are from.
    let making: TimelineMaking
    /// What the ruler was drawn for.
    let pageViewport: TimelineViewport
    let pageWidth: CGFloat
    let range: ClosedRange<Double>
    let bodyWidth: CGFloat
    let scaleSource: TimelineScaleSource
    let reports: TimelineReports

    /// Whether the strip shows the same as another. What the owner draws in
    /// it cannot be compared, but it is the same while the timeline is the
    /// same making and the page is the same.
    nonisolated static func == (one: TimelineRulerStrip, other: TimelineRulerStrip) -> Bool {
        one.making === other.making
            && one.pageViewport == other.pageViewport
            && one.pageWidth == other.pageWidth
            && one.range == other.range
            && one.bodyWidth == other.bodyWidth
    }

    var body: some View {
        TimelinePageShift(
            scale: scaleSource.shownBinding,
            range: range,
            bodyWidth: bodyWidth,
            content: ZStack(alignment: .topLeading) {
                ruler
            }
            .frame(width: pageWidth, height: DesignTokens.Sizes.rulerHeight, alignment: .topLeading)
        )
        .frame(width: bodyWidth, height: DesignTokens.Sizes.rulerHeight, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture(coordinateSpace: .local)
                .onEnded { value in
                    let scale = scaleSource.screenScale(range: range, bodyWidth: bodyWidth)
                    reports.rulerTap?(scale.seconds(forX: Double(value.location.x)))
                },
            isEnabled: reports.rulerTap != nil && reports.rulerDrag == nil
        )
        // From the press on, without waiting for the pointer to move,
        // so what is dragged jumps to the pointer at once. Measured in
        // the ruler's own coordinates, whose x is zero at the left edge
        // of the rows and which go on outside the ruler.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { reportRulerDrag($0, isFinished: false) }
                .onEnded { reportRulerDrag($0, isFinished: true) },
            isEnabled: reports.rulerDrag != nil
        )
    }

    private func reportRulerDrag(_ value: DragGesture.Value, isFinished: Bool) {
        reports.rulerDrag?(TimelineRulerDrag(
            startX: value.startLocation.x,
            x: value.location.x,
            isFinished: isFinished
        ))
    }
}

// MARK: - Where a row is

/// Where a row lies among the rows of its timeline. It is kept in an object
/// that no view watches, so scrolling the rows up and down, which changes it
/// for every row, does not make any row work itself out again.
@MainActor
final class TimelineRowPlace {
    /// The y of the row's top edge, in `.timelineLanes` coordinates.
    var minY: CGFloat = 0
    /// The same, as it was when the drag in progress started. Nil between drags.
    var dragStartMinY: CGFloat?
}

// MARK: - Pinching

/// What a pinch started with. It is kept in an object that no view watches,
/// so remembering it does not make the timeline work itself out once more.
@MainActor
final class TimelinePinch {
    /// The scale when the pinch began and where the pointer was, in the
    /// timeline's own coordinates. Nil between pinches.
    var start: (scale: TimelineScale, location: CGPoint)?
}

/// The binding of a timeline's scale, handed through the views between its
/// owner and the `Timeline` (`MainLayout`, `MainTimeline`).
///
/// A view that keeps a `Binding` among its properties, with `@Binding` or
/// without, is made to depend on the bound value: SwiftUI reads the value
/// every time it looks at the view, so a move of the timeline would work out
/// that view again with everything inside it, the whole window. Inside this
/// struct the binding is not seen, the views in between are left alone while
/// the binding itself stays the same, and only the `Timeline`, which reads
/// the scale, follows a move. Hand them a binding that stays the same, such
/// as one the owner made once.
struct TimelineScaleLink {
    let binding: Binding<TimelineScale>
}

// MARK: - The drag layer

/// How far the rows that scroll have been scrolled down. Only the drag layer
/// reads it, so scrolling does not make the timeline work its rows out again.
///
/// The rest is what a drag with the middle mouse button needs to scroll them.
/// No view reads it.
@MainActor
@Observable
final class TimelineScrollOffset {
    var y: CGFloat = 0
    /// The furthest down they can be scrolled. Zero when they all fit.
    @ObservationIgnored var maxY: CGFloat = 0
    /// What the scroll view keeps free above them. Its own count of how far
    /// it is scrolled starts that much below zero.
    @ObservationIgnored var topInset: CGFloat = 0
    /// Where the drag with the middle button that is going on last sent them.
    @ObservationIgnored var aimedY: CGFloat?
}

/// What the scroll view of the rows says about itself, as much as the
/// timeline needs.
struct TimelineRowsScroll: Equatable {
    /// How far the rows are scrolled down. Zero when the first row is at the top.
    var y: CGFloat
    /// The furthest down they can be scrolled.
    var maxY: CGFloat
    /// What the scroll view keeps free above them.
    var topInset: CGFloat

    init(_ geometry: ScrollGeometry) {
        let insets = geometry.contentInsets
        y = geometry.contentOffset.y + insets.top
        maxY = max(geometry.contentSize.height + insets.top + insets.bottom - geometry.containerSize.height, 0)
        topInset = insets.top
    }
}

/// Shows what the owner of the timeline draws in the drag layer, and tells it
/// where the rows are.
private struct TimelineDragLayerHost: View {
    let content: (TimelineDragLayerContext) -> AnyView
    let layout: TimelineLayout
    let viewport: TimelineViewport
    let width: CGFloat
    let scrollOffset: TimelineScrollOffset

    var body: some View {
        content(TimelineDragLayerContext(
            viewport: viewport,
            bodyMinX: layout.bodyMinX,
            laneFrames: layout.laneFrames(width: width, scrolledBy: scrollOffset.y),
            scrollAreaMinY: layout.scrollAreaMinY
        ))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }
}

// MARK: - Sizes and positions

/// Where the parts of a timeline are, worked out from the rows' heights.
struct TimelineLayout {
    let pinned: [AnyTimelineLane]
    let scrolling: [AnyTimelineLane]
    /// The x of the left edge of the lane bodies: the header column and the
    /// gap after it, or zero.
    let bodyMinX: CGFloat
    /// The y where the rows that scroll begin, counted from the top of the first row.
    let scrollAreaMinY: CGFloat
    /// The ruler, the rows and the gaps between them.
    let contentHeight: CGFloat

    init(lanes: [AnyTimelineLane], options: TimelineOptions) {
        let gap = DesignTokens.Spacing.laneGap
        pinned = lanes.filter(\.isPinned)
        scrolling = lanes.filter { !$0.isPinned }
        bodyMinX = options.showsHeaders ? options.headerWidth + gap : 0

        let pinnedHeight = Self.height(of: pinned)
        let scrollingHeight = Self.height(of: scrolling)
        scrollAreaMinY = pinned.isEmpty ? 0 : pinnedHeight + gap
        let lanesHeight = scrolling.isEmpty ? pinnedHeight : scrollAreaMinY + scrollingHeight
        let rulerHeight = options.showsRuler
            ? DesignTokens.Sizes.rulerHeight + (lanes.isEmpty ? 0 : gap)
            : 0
        contentHeight = rulerHeight + lanesHeight
    }

    /// Where every row is, in `.timelineLanes` coordinates.
    func laneFrames(width: CGFloat, scrolledBy scrollY: CGFloat) -> [TimelineLaneFrame] {
        let gap = DesignTokens.Spacing.laneGap
        var frames: [TimelineLaneFrame] = []
        var y: CGFloat = 0
        for lane in pinned {
            frames.append(TimelineLaneFrame(
                laneID: lane.id,
                frame: CGRect(x: 0, y: y, width: width, height: lane.height),
                isPinned: true
            ))
            y += lane.height + gap
        }
        y = scrollAreaMinY - scrollY
        for lane in scrolling {
            frames.append(TimelineLaneFrame(
                laneID: lane.id,
                frame: CGRect(x: 0, y: y, width: width, height: lane.height),
                isPinned: false
            ))
            y += lane.height + gap
        }
        return frames
    }

    private static func height(of lanes: [AnyTimelineLane]) -> CGFloat {
        guard !lanes.isEmpty else { return 0 }
        let gaps = DesignTokens.Spacing.laneGap * CGFloat(lanes.count - 1)
        return lanes.reduce(gaps) { $0 + $1.height }
    }
}

/// What the rows and the ruler are drawn for: the screen and one more screen
/// on either side of it, moved so the screen lies where it should.
///
/// Moving along the song changes what is on screen on every frame. If every
/// row were drawn again for it, every clip, waveform and beat line in it
/// would be worked out again too, and a drag would lag behind the pointer.
/// So the rows are drawn for a page three screens wide, which stays the same
/// while the timeline moves less than a screen, and only the page is moved
/// (`shift`, by `TimelinePageShift`). When the screen leaves the middle third
/// of the page, the page is made again around it. A zoom makes a new page at
/// once.
///
/// A row is handed the page's `viewport` and `width`, never the `shift`: the
/// shift changes on every move, and a row that was handed it would be worked
/// out again each time.
///
/// Things in a row are placed with `viewport`, from the page's left edge.
/// Clicks and drags on the row itself are measured with the scale of what is
/// on screen, from the screen's left edge (`TimelineScaleSource`).
struct TimelinePage: Equatable {
    /// Converts song seconds to x from the page's left edge, and holds the
    /// seconds the page covers, cut to the timeline's range.
    var viewport: TimelineViewport
    /// The width of the page.
    var width: CGFloat
    /// Where the page's left edge lies, counted from the screen's left edge:
    /// zero or less. On a whole pixel, so lines drawn on whole points stay sharp.
    var shift: CGFloat

    init(viewport screen: TimelineViewport, range: ClosedRange<Double>, bodyWidth: CGFloat, displayScale: CGFloat) {
        let pointsPerSecond = screen.scale.pointsPerSecond
        guard bodyWidth > 0, pointsPerSecond > 0 else {
            viewport = screen
            width = bodyWidth
            shift = 0
            return
        }
        let screenWidth = Double(bodyWidth)
        // The screen's left edge, in points from the song's 00:00, and the
        // screen-wide step of the page that holds it.
        let screenStart = screen.scale.scrollOffsetSeconds * pointsPerSecond
        let step = (screenStart / screenWidth).rounded(.down)
        let pageStart = (step - 1) * screenWidth
        var scale = screen.scale
        scale.scrollOffsetSeconds = pageStart / pointsPerSecond
        let pageWidth = 3 * screenWidth
        let lower = min(max(scale.seconds(forX: 0), range.lowerBound), range.upperBound)
        let upper = min(max(scale.seconds(forX: pageWidth), lower), range.upperBound)
        viewport = TimelineViewport(scale: scale, visibleRange: lower...upper)
        width = CGFloat(pageWidth)
        let pixels = max(displayScale, 1)
        shift = CGFloat(((pageStart - screenStart) * pixels).rounded() / pixels)
    }
}

/// The scale as asked for, and the scale as shown once it is kept inside the
/// timeline's range at the current width.
struct TimelineFit: Equatable {
    var scale: TimelineScale
    var range: ClosedRange<Double>
    /// The width of the lane bodies. Zero before the timeline has a size.
    var bodyWidth: CGFloat

    var fittedScale: TimelineScale {
        guard bodyWidth > 0 else { return scale }
        var fitted = scale
        fitted.clamp(range: range, viewWidth: Double(bodyWidth))
        return fitted
    }

    var viewport: TimelineViewport {
        let fitted = fittedScale
        guard bodyWidth > 0, fitted.pointsPerSecond > 0 else {
            return TimelineViewport(scale: fitted, visibleRange: range.lowerBound...range.lowerBound)
        }
        let lower = min(max(fitted.seconds(forX: 0), range.lowerBound), range.upperBound)
        let upper = min(max(fitted.seconds(forX: Double(bodyWidth)), lower), range.upperBound)
        return TimelineViewport(scale: fitted, visibleRange: lower...upper)
    }
}

import SwiftUI

/// The timing marks on a clip: a marker at every syllable, and the sub-beat
/// lines the markers are judged against. `ClipView` lays it over the clip's
/// waveform when the clip has `ClipBox.timingMarks`. Nothing else uses it.
///
/// A marker is a thin tick whose left edge is where the syllable starts, with
/// a dot on top, just under the clip's bar. Its colour says how far the
/// syllable is from the nearest sub-beat: `timingOnBeat`, `timingSlightlyOff`
/// or `timingNeutral` from `DesignTokens.Colors`. The three differ in
/// lightness as well as in hue, and every marker has a dark edge, so they can
/// be told apart without colour and on top of a waveform. The marker of an
/// excluded syllable is hollow: a ring in its colour around a dark middle.
///
/// The sub-beat lines run from the bar down through the waveform. They are
/// fainter than the beat lines, which the timeline draws over every row.
///
/// A clip that aims at another track (`ClipTimingMarks.leadSyllableTimes`)
/// has no sub-beat lines. It has a line at every syllable of that track
/// instead, from the bar down through the waveform like a sub-beat line, but
/// several times as strong, with a thin dark edge on both sides so it can be
/// followed across the waveform, and with a small bar across its top, right
/// under the clip's bar, so it looks like a "T". A marker that is on its partner
/// stands on that line, under the small bar. A syllable without a partner
/// has a neutral marker.
///
/// The pointer: at a marker, a small readout under its tick says how far off
/// the syllable is ("23 ms late"), and the marker gets a light ring.
///
/// Zoomed out, what would run together is left out:
/// - below `DesignTokens.Sizes.markerDotsFromZoom` a marker is its tick
///   alone, as tall as the whole marker, and there is no readout;
/// - below `DesignTokens.Sizes.markerTicksFromZoom` no markers are drawn;
/// - sub-beat lines that would lie closer to each other than
///   `DesignTokens.Sizes.subBeatLineMinimumSpacing` are not drawn;
/// - the lines at the lead's syllables are drawn only while markers have
///   their dots.
///
/// A low clip: in a track row that was made lower than usual, the markers
/// are smaller so that they still fit under the bar. First the room above and
/// under a marker shrinks, then its tick (`MarkerSize`). The readout, which
/// has no room under the tick then, stands beside the marker instead, at the
/// clip's lower edge. In a taller row the markers keep their size and stay
/// right under the bar.
///
/// Everything is one drawing, however many syllables there are. Only the
/// readout is a view of its own.
struct ClipTimingLayer: View, Equatable {
    @Environment(\.timelinePalette) private var palette

    /// The marker the real pointer is at.
    @State private var markerUnderPointer: SyllableMarker.ID?
    /// The marker the pointer has rested at for as long as
    /// `ClipTimingMarks.readoutDelay` asks.
    @State private var markerRestedAt: SyllableMarker.ID?

    let marks: ClipTimingMarks
    /// The pieces of the clip, in song seconds. A joined clip has a gap
    /// between them, and no sub-beat line is drawn in a gap.
    let pieces: [ClosedRange<Double>]
    /// The part of the clip that is drawn. See `ClipView`.
    let span: ClipSpan
    /// How much of the right end lies under the next clip on the track.
    /// Nothing is drawn there.
    let coveredWidth: CGFloat

    nonisolated static func == (lhs: ClipTimingLayer, rhs: ClipTimingLayer) -> Bool {
        lhs.span == rhs.span && lhs.coveredWidth == rhs.coveredWidth
            && lhs.pieces == rhs.pieces && lhs.marks == rhs.marks
    }

    var body: some View {
        // The markers are made to fit the height the clip has, and only the
        // layout knows that height.
        GeometryReader { proxy in
            layer(clipHeight: proxy.size.height)
        }
    }

    private func layer(clipHeight: CGFloat) -> some View {
        let marks = marks
        let pieces = pieces
        let place = MarkerPlace(span: span, coveredWidth: coveredWidth, clipHeight: clipHeight)
        let shownMarker = shownMarker(in: place)
        let subBeatLine = palette.subBeatLine
        let leadSyllableLine = palette.leadSyllableLine
        return Canvas { context, size in
            ClipTimingDrawing.draw(
                marks,
                pieces: pieces,
                place: place,
                shownMarker: shownMarker?.id,
                subBeatLine: subBeatLine,
                leadSyllableLine: leadSyllableLine,
                in: &context,
                size: size
            )
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            let marker = marker(at: phase, in: place)
            if marker != markerUnderPointer {
                markerUnderPointer = marker
            }
        }
        .task(id: markerUnderPointer) {
            // The pointer came to a marker, or left one: the wait starts again.
            let delay = marks.readoutDelay
            guard delay > 0 else { return }
            markerRestedAt = nil
            guard let marker = markerUnderPointer else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            markerRestedAt = marker
        }
        .overlay(alignment: .topLeading) {
            // The readout hangs under the marker's tick, centred on it. Near
            // an end of the clip it moves in, so it stays on the part of the
            // clip that can be seen. A clip narrower than the readout lets it
            // reach out to the right. In a clip too low for it to hang under
            // the tick, it stands to the right of the marker instead, at the
            // clip's lower edge.
            MarkerReadout(text: shownMarker?.readoutText(againstLead: marks.leadSyllableTimes != nil))
                .alignmentGuide(.leading) { readout in
                    let inset = DesignTokens.Spacing.tight
                    let markerX = place.x(for: shownMarker?.time ?? 0)
                    let wanted = place.hasRoomUnderTick(for: readout.height)
                        ? markerX - readout.width / 2
                        : markerX + DesignTokens.Sizes.markerDotDiameter / 2 + DesignTokens.Spacing.small
                    return -max(min(wanted, place.visibleMaxX - inset - readout.width), place.visibleMinX + inset)
                }
                .alignmentGuide(.top) { readout in
                    place.hasRoomUnderTick(for: readout.height)
                        ? -(place.size.tickBottom + DesignTokens.Spacing.small)
                        : -max(place.clipHeight - readout.height, 0)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timing markers")
        .accessibilityValue(spokenSummary)
    }

    /// The marker whose readout is shown: the one the design lab asked for,
    /// or else the one the pointer is at, once it has rested there for as
    /// long as was asked. Nil when markers have no dots, or when that marker
    /// is not on the part of the clip that is drawn.
    private func shownMarker(in place: MarkerPlace) -> SyllableMarker? {
        var atPointer = markerUnderPointer
        if marks.readoutDelay > 0, markerRestedAt != markerUnderPointer {
            atPointer = nil
        }
        guard place.detail == .dots, let id = marks.shownReadout ?? atPointer else { return nil }
        return marks.markers.first { $0.id == id && place.isDrawn(at: place.x(for: $0.time)) }
    }

    /// The marker nearest to the pointer, when the pointer is in the strip
    /// under the bar where the markers are and within reach of one.
    private func marker(at phase: HoverPhase, in place: MarkerPlace) -> SyllableMarker.ID? {
        let reach = DesignTokens.Sizes.markerHoverReach
        guard place.detail == .dots,
              case .active(let location) = phase,
              location.y >= DesignTokens.Sizes.clipBarHeight,
              location.y <= place.size.tickBottom + reach
        else { return nil }

        var nearest: SyllableMarker.ID?
        var nearestDistance = reach
        for marker in marks.markers where marker.hasDistance {
            let x = place.x(for: marker.time)
            let distance = abs(x - location.x)
            if distance <= nearestDistance, place.isDrawn(at: x) {
                nearest = marker.id
                nearestDistance = distance
            }
        }
        return nearest
    }

    /// What VoiceOver reads for the markers, which are a drawing and have
    /// no parts of their own.
    private var spokenSummary: String {
        func count(_ timing: SyllableMarker.Timing) -> Int {
            marks.markers.count { $0.timing == timing }
        }
        if marks.leadSyllableTimes != nil {
            return "\(marks.markers.count) syllables: \(count(.onBeat)) on the lead, "
                + "\(count(.slightlyOff)) slightly off, \(count(.unpaired)) without a match"
        }
        return "\(marks.markers.count) syllables: \(count(.onBeat)) on the beat, "
            + "\(count(.slightlyOff)) slightly off, \(count(.deliberate)) far off"
    }
}

// MARK: - Where the marks go

/// How much of a marker is drawn at a zoom.
enum MarkerDetail: Equatable, Sendable {
    /// Nothing: even ticks would run together.
    case none
    /// A tick alone.
    case ticks
    /// The tick with its dot, and a readout at the pointer.
    case dots

    init(pointsPerSecond: Double) {
        if pointsPerSecond >= DesignTokens.Sizes.markerDotsFromZoom {
            self = .dots
        } else if pointsPerSecond >= DesignTokens.Sizes.markerTicksFromZoom {
            self = .ticks
        } else {
            self = .none
        }
    }
}

/// How big a marker is in a clip of a certain height.
///
/// In a clip of the usual height or taller it is the marker as designed: a
/// little room under the bar, the dot, and the tick under it. A lower clip
/// has less room under its bar. Then the room above and under the marker is
/// halved first, and after that the tick gets shorter. The dot keeps its
/// size, because it is what tells an excluded syllable from the others.
struct MarkerSize: Equatable, Sendable {
    /// The top of a marker's dot: a little under the clip's bar.
    let dotTop: CGFloat
    /// The height of the tick under the dot.
    let tickHeight: CGFloat

    /// The lower end of a marker's tick.
    var tickBottom: CGFloat {
        dotTop + DesignTokens.Sizes.markerDotDiameter + tickHeight
    }

    /// - Parameter clipHeight: The height of the clip, its bar included: the
    ///   height of its row without the room above and below the clips.
    init(clipHeight: CGFloat) {
        let room = clipHeight - DesignTokens.Sizes.clipBarHeight
        let dot = DesignTokens.Sizes.markerDotDiameter
        let fullTick = DesignTokens.Sizes.markerTickHeight
        let fullGap = DesignTokens.Spacing.small
        let gap = room >= dot + fullTick + 2 * fullGap ? fullGap : DesignTokens.Spacing.tight
        dotTop = DesignTokens.Sizes.clipBarHeight + gap
        tickHeight = min(fullTick, max(room - dot - 2 * gap, DesignTokens.Spacing.tight))
    }
}

/// Where a moment of the song lies inside the drawn part of a clip, and
/// which part of that can be seen.
struct MarkerPlace: Equatable, Sendable {
    let startSeconds: Double
    let pointsPerSecond: Double
    /// The left end of the part of the clip that is on screen.
    let visibleMinX: CGFloat
    /// The right end of the part that is on screen and not under the next clip.
    let visibleMaxX: CGFloat
    /// Where the next clip on the track begins to lie over this one.
    let uncoveredMaxX: CGFloat
    let detail: MarkerDetail
    /// The height of the clip, its bar included.
    let clipHeight: CGFloat
    /// How big the markers are in a clip of that height.
    let size: MarkerSize

    init(span: ClipSpan, coveredWidth: CGFloat, clipHeight: CGFloat) {
        self.clipHeight = clipHeight
        size = MarkerSize(clipHeight: clipHeight)
        startSeconds = span.startSeconds
        pointsPerSecond = span.pointsPerSecond
        visibleMinX = span.hiddenLeading
        visibleMaxX = span.width - max(span.hiddenTrailing, coveredWidth)
        uncoveredMaxX = span.width - coveredWidth
        detail = MarkerDetail(pointsPerSecond: span.pointsPerSecond)
    }

    /// The x of a moment in the song, counted from the left edge of the
    /// drawn part of the clip.
    func x(for seconds: Double) -> CGFloat {
        CGFloat((seconds - startSeconds) * pointsPerSecond)
    }

    /// Whether a mark at this x is drawn: it is inside the drawn part and
    /// not under the next clip.
    func isDrawn(at x: CGFloat) -> Bool {
        x >= 0 && x <= uncoveredMaxX
    }

    /// Whether a readout of this height can hang under a marker's tick
    /// without reaching below the clip.
    func hasRoomUnderTick(for readoutHeight: CGFloat) -> Bool {
        size.tickBottom + DesignTokens.Spacing.small + readoutHeight <= clipHeight
    }
}

// MARK: - The readout

/// The small dark label at a marker that says how far off its syllable is.
/// Without a text it is nothing.
private struct MarkerReadout: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.Spacing.controlGap)
                .padding(.vertical, DesignTokens.Spacing.tight)
                .background(DesignTokens.Colors.timingReadoutBackground, in: Capsule(style: .continuous))
                .fixedSize()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Drawing

extension SyllableMarker.Timing {
    /// The colour of a marker with this timing.
    fileprivate var color: Color {
        switch self {
        case .onBeat: DesignTokens.Colors.timingOnBeat
        case .slightlyOff: DesignTokens.Colors.timingSlightlyOff
        case .deliberate, .unpaired: DesignTokens.Colors.timingNeutral
        }
    }
}

/// Draws the lines to judge against and the markers of a clip, under the
/// clip's bar.
private enum ClipTimingDrawing {
    static func draw(
        _ marks: ClipTimingMarks,
        pieces: [ClosedRange<Double>],
        place: MarkerPlace,
        shownMarker: SyllableMarker.ID?,
        subBeatLine: Color,
        leadSyllableLine: Color,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let top = DesignTokens.Sizes.clipBarHeight
        guard size.height > top, size.width > 0, place.pointsPerSecond > 0 else { return }

        // Keeps the lines inside the clip's rounded bottom corners.
        context.clip(to: DesignTokens.Shapes.clip.path(in: CGRect(origin: .zero, size: size)))

        // Lines and ticks start on a whole pixel, so they come out sharp, and
        // a tick that is on a sub-beat lies exactly on that sub-beat's line.
        let pixel = 1 / max(context.environment.displayScale, 1)
        func leftEdge(of seconds: Double) -> CGFloat {
            (place.x(for: seconds) / pixel).rounded(.down) * pixel
        }

        let box = CGRect(x: 0, y: top, width: size.width, height: size.height - top)
        if let leadTimes = marks.leadSyllableTimes {
            // The clip is held against another track's syllables: its
            // sub-beats are not used, so their lines would only mislead.
            if place.detail == .dots {
                drawLeadSyllableLines(
                    leadTimes,
                    pieces: pieces,
                    place: place,
                    color: leadSyllableLine,
                    leftEdge: leftEdge,
                    in: &context,
                    box: box
                )
            }
        } else {
            drawSubBeatLines(
                marks.subBeatTimes,
                fade: marks.subBeatLineFade,
                pieces: pieces,
                place: place,
                color: subBeatLine,
                leftEdge: leftEdge,
                in: &context,
                box: box
            )
        }
        switch place.detail {
        case .none:
            break
        case .ticks:
            drawTicks(marks.markers, place: place, leftEdge: leftEdge, in: &context)
        case .dots:
            drawMarkers(marks.markers, place: place, shownMarker: shownMarker, leftEdge: leftEdge, in: &context)
        }
    }

    /// The sub-beat lines, from the bar down to the clip's lower edge.
    private static func drawSubBeatLines(
        _ times: [Double],
        fade: ClosedRange<CGFloat>?,
        pieces: [ClosedRange<Double>],
        place: MarkerPlace,
        color: Color,
        leftEdge: (Double) -> CGFloat,
        in context: inout GraphicsContext,
        box: CGRect
    ) {
        // The tightest pair decides for all of them, so the lines of a clip
        // come and go together when the zoom changes.
        let tightest = zip(times, times.dropFirst()).map { $1 - $0 }.min()
        var strength = 1.0
        if let tightest {
            let spacing = tightest * place.pointsPerSecond
            if let fade {
                let length = Double(fade.upperBound - fade.lowerBound)
                let reached = spacing - Double(fade.lowerBound)
                strength = length > 0 ? min(reached / length, 1) : (reached > 0 ? 1 : 0)
                guard strength > 0 else { return }
            } else if spacing < Double(DesignTokens.Sizes.subBeatLineMinimumSpacing) {
                return
            }
        }
        let width = DesignTokens.Lines.subBeatWidth
        var lines = Path()
        for time in times where pieces.contains(where: { $0.contains(time) }) {
            let x = leftEdge(time)
            guard place.isDrawn(at: x) else { continue }
            lines.addRect(CGRect(x: x, y: box.minY, width: width, height: box.height))
        }
        context.fill(lines, with: .color(color.opacity(strength)))
    }

    /// The lines at the syllables of the track the clip aims at: each from
    /// the bar down to the clip's lower edge, with a small bar across its
    /// top. The line's left edge is where the lead's syllable starts, as a
    /// marker's tick is where its own syllable starts, so a marker that is on
    /// its partner covers the top of the line exactly.
    private static func drawLeadSyllableLines(
        _ times: [Double],
        pieces: [ClosedRange<Double>],
        place: MarkerPlace,
        color: Color,
        leftEdge: (Double) -> CGFloat,
        in context: inout GraphicsContext,
        box: CGRect
    ) {
        let width = DesignTokens.Lines.leadSyllableWidth
        let capWidth = DesignTokens.Sizes.leadSyllableCapWidth
        let capHeight = min(DesignTokens.Sizes.leadSyllableCapHeight, box.height)
        // A thin dark edge on both sides of the line, as a marker has, so
        // the line can be followed where it crosses the light waveform.
        let edge = 1 / max(context.environment.displayScale, 1)
        var lines = Path()
        var edges = Path()
        for time in times where pieces.contains(where: { $0.contains(time) }) {
            let x = leftEdge(time)
            guard place.isDrawn(at: x) else { continue }
            lines.addRect(CGRect(x: x + width / 2 - capWidth / 2, y: box.minY, width: capWidth, height: capHeight))
            // Under the small bar, so the two do not lie over each other
            // and come out stronger where they would.
            let line = CGRect(x: x, y: box.minY + capHeight, width: width, height: box.height - capHeight)
            lines.addRect(line)
            edges.addRect(CGRect(x: line.minX - edge, y: line.minY, width: edge, height: line.height))
            edges.addRect(CGRect(x: line.maxX, y: line.minY, width: edge, height: line.height))
        }
        context.fill(edges, with: .color(DesignTokens.Colors.timingMarkerEdge))
        context.fill(lines, with: .color(color))
    }

    /// The markers when zoomed out: a tick each, as tall as a whole marker,
    /// in the marker's colour. There is no room for a dark edge or for
    /// telling an excluded syllable apart.
    private static func drawTicks(
        _ markers: [SyllableMarker],
        place: MarkerPlace,
        leftEdge: (Double) -> CGFloat,
        in context: inout GraphicsContext
    ) {
        let width = DesignTokens.Lines.markerTickWidth
        let top = place.size.dotTop
        let height = place.size.tickBottom - top
        for timing in [SyllableMarker.Timing.unpaired, .deliberate, .slightlyOff, .onBeat] {
            var ticks = Path()
            for marker in markers where marker.timing == timing {
                let x = leftEdge(marker.time)
                guard place.isDrawn(at: x) else { continue }
                ticks.addRect(CGRect(x: x, y: top, width: width, height: height))
            }
            context.fill(ticks, with: .color(timing.color))
        }
    }

    /// The whole markers, in the order the syllables come, so where two lie
    /// close the later one keeps its dark edge against the earlier one.
    private static func drawMarkers(
        _ markers: [SyllableMarker],
        place: MarkerPlace,
        shownMarker: SyllableMarker.ID?,
        leftEdge: (Double) -> CGFloat,
        in context: inout GraphicsContext
    ) {
        let diameter = DesignTokens.Sizes.markerDotDiameter
        let tickWidth = DesignTokens.Lines.markerTickWidth
        let edge = DesignTokens.Lines.markerEdgeWidth
        let ring = DesignTokens.Lines.markerRingWidth
        let edgeColor = GraphicsContext.Shading.color(DesignTokens.Colors.timingMarkerEdge)

        for marker in markers {
            let left = leftEdge(marker.time)
            guard place.isDrawn(at: left) else { continue }
            let color = GraphicsContext.Shading.color(marker.timing.color)
            // The dot is centred on the tick.
            let dot = CGRect(
                x: left + tickWidth / 2 - diameter / 2,
                y: place.size.dotTop,
                width: diameter,
                height: diameter
            )
            let tick = CGRect(
                x: left,
                y: dot.maxY,
                width: tickWidth,
                height: place.size.tickHeight
            )

            // The dark edge first, around the dot and the tick. It also
            // fills the middle of a hollow dot.
            context.fill(Path(ellipseIn: dot.insetBy(dx: -edge, dy: -edge)), with: edgeColor)
            context.fill(Path(tick.insetBy(dx: -edge, dy: -edge)), with: edgeColor)

            context.fill(Path(tick), with: color)
            if marker.isExcluded {
                context.stroke(
                    Path(ellipseIn: dot.insetBy(dx: ring / 2, dy: ring / 2)),
                    with: color,
                    lineWidth: ring
                )
            } else {
                context.fill(Path(ellipseIn: dot), with: color)
            }
            if marker.id == shownMarker {
                context.stroke(
                    Path(ellipseIn: dot.insetBy(dx: -ring / 2, dy: -ring / 2)),
                    with: .color(DesignTokens.Colors.textPrimary),
                    lineWidth: ring
                )
            }
        }
    }
}

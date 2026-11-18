import LockstepCore
import SwiftUI

/// One clip on a track: a bar along the top with the clip's name, and under
/// it the waveform of each of its pieces.
///
/// It is placed like the content of a lane: give it the lane's viewport and
/// put it at the lane's left edge, and it moves itself to the clip's place in
/// the song. It fills the height it is given. A clip that is not on screen
/// draws nothing.
///
///     ZStack(alignment: .topLeading) {
///         ForEach(clips) { ClipView(clip: $0, viewport: viewport) }
///     }
///
/// `TrackLane` does this for a whole track, and also works out `coveredFrom`.
///
/// What it shows from the clip:
/// - the name in the bar, cut off with an ellipsis when it does not fit. A
///   typed name and a name taken from the clip's words look the same. A clip
///   that has neither yet has no text in its bar;
/// - "3/5" at the right of the bar when the clip has more than one take
///   (take 3 of 5 is the one that plays). It is a button, so it has a
///   backing. A ringed "3" when the clip's lines run in triplets;
/// - a muted clip, and any clip on a muted track, dimmed. A clip that is
///   muted itself also has a crossed-out speaker before its name;
/// - a clip that is turned up or down with a taller or shorter waveform, and
///   with the volume in the bar, such as "+4 dB";
/// - a selected clip with a white, stronger outline and a lighter bar.
///   Several selected clips each look like that;
/// - the syllable markers and the sub-beat lines of a clip that has
///   `ClipBox.timingMarks`, over its waveform. `ClipTimingLayer` draws them
///   and says how they look;
/// - a clip with effects (`ClipBox.effects`): a thin band along its lower
///   edge over the stretch each effect is on (`ClipEffectBands`), and the
///   mark "FX" in its bar when an effect is on the whole clip;
/// - a joined clip with a gap: nothing in the gap, with the bar and the
///   outline going across it;
/// - a clip that is being renamed (`ClipBox.isBeingRenamed`) with a text
///   field in place of the bar's content. The field is never narrower than
///   `DesignTokens.Sizes.clipNameFieldMinimumWidth`: on a short clip it
///   reaches out to the right, past the clip's edge, and it moves left where
///   it would leave the row. Draw such a clip in front of the others
///   (`zIndex`), as `TrackLane` does. The field is a picture unless
///   `onRenameEnd` is given: then the name can be typed in it.
///
/// A narrow clip: the bar shows only what fits whole, and a clip too narrow
/// for anything shows the bar alone. `ClipBarFit` has the rule. The whole
/// name is always in the bar's help tag.
///
/// A wide clip: when a clip is wider than the screen, only the part on screen
/// is drawn, and its name and marks stay in view at the edges.
///
/// The pointer: over the clip, its body and outline get a little stronger.
/// Over the bar, which is the handle the clip is dragged by, the bar lightens
/// too and the pointer becomes an open hand. Over the take count, that button
/// lights up and the pointer becomes a pointing hand. A press on the take
/// count calls `onTakeCount`. Nothing else happens on a click or a drag yet.
///
/// The edges: near the left or the right edge of the clip, over its whole
/// height, the pointer becomes the resize pointer and that edge is drawn as a
/// thin bright bar. A drag from there trims the clip (`ClipEdgeHandles`, and
/// `ClipActions.edgeDragged` for who is told). The edge stays lit while it is
/// dragged (`ClipBox.trimmedEdge`). An end that lies under the next clip, or
/// beyond the part of a very wide clip that is drawn, has no handle, and a
/// clip that is being renamed has none.
///
/// Two clips that overlap: `coveredFrom` tells a clip where the next clip on
/// its track begins to lie over it. From there on its waveform is dim, and
/// its name and marks keep to the part that is not covered. Draw the later
/// clip in front.
///
/// A `ClipBox` is already the take that plays, so the other takes of a clip
/// are never drawn here.
public struct ClipView: View {
    private let clip: ClipBox
    private let viewport: TimelineViewport
    private let isOnMutedTrack: Bool
    private let coveredFrom: Double?
    private let shownPointer: ClipPart?
    private let onTakeCount: (@MainActor () -> Void)?
    private let onRenameEnd: (@MainActor (String?) -> Void)?

    /// - Parameters:
    ///   - clip: The clip to show.
    ///   - viewport: The viewport of the lane the clip is drawn in.
    ///   - isOnMutedTrack: Dims the clip the way a muted clip is dimmed.
    ///   - coveredFrom: The song seconds from which a clip that starts later
    ///     on the same track lies over this one, or nil when none does.
    ///   - shownPointer: Draws the clip as if the pointer were over that part
    ///     of it, wherever the pointer really is. The design lab uses it for
    ///     pictures. Nil follows the real pointer.
    ///   - onTakeCount: Called when the take count in the clip's bar is
    ///     pressed. Left out, pressing it does nothing.
    ///   - onRenameEnd: Told when the typing of the clip's name is over: the
    ///     name as typed, or nil when it was given up with Escape. Left out,
    ///     the name field of a clip that is being renamed is a picture.
    public init(
        clip: ClipBox,
        viewport: TimelineViewport,
        isOnMutedTrack: Bool = false,
        coveredFrom: Double? = nil,
        shownPointer: ClipPart? = nil,
        onTakeCount: (@MainActor () -> Void)? = nil,
        onRenameEnd: (@MainActor (String?) -> Void)? = nil
    ) {
        self.clip = clip
        self.viewport = viewport
        self.isOnMutedTrack = isOnMutedTrack
        self.coveredFrom = coveredFrom
        self.shownPointer = shownPointer
        self.onTakeCount = onTakeCount
        self.onRenameEnd = onRenameEnd
    }

    public var body: some View {
        if let placement = ClipPlacement(clip: clip, viewport: viewport) {
            // Scrolling sideways changes only the offset. Everything inside
            // is compared with what it was, so a clip that is fully on screen
            // is not drawn again while the timeline scrolls.
            ClipContent(
                clip: clip,
                isDimmed: clip.muted || isOnMutedTrack,
                span: placement.span,
                coveredWidth: coveredWidth(of: placement.span),
                nameField: nameField(for: placement),
                shownPointer: shownPointer,
                onTakeCount: onTakeCount,
                onRenameEnd: onRenameEnd
            )
            .equatable()
            .frame(width: placement.span.width)
            .frame(maxHeight: .infinity)
            .offset(x: placement.minX)
        }
    }

    /// How much of the right end of the drawn part lies under the next clip.
    private func coveredWidth(of span: ClipSpan) -> CGFloat {
        guard let coveredFrom else { return 0 }
        let covered = (span.endSeconds - max(coveredFrom, span.startSeconds)) * span.pointsPerSecond
        return min(max(CGFloat(covered), 0), span.width)
    }

    /// Where the field for typing the name goes, or nil when this clip is not
    /// being renamed.
    private func nameField(for placement: ClipPlacement) -> ClipNameFieldPlace? {
        guard clip.isBeingRenamed else { return nil }
        let span = placement.span
        let width = max(
            span.width - span.hiddenLeading - span.hiddenTrailing,
            DesignTokens.Sizes.clipNameFieldMinimumWidth
        )
        // The field starts where the clip comes into view. Where it would
        // reach past the right end of the row it moves left instead, but
        // never past the row's left end.
        let rowMinX = viewport.x(for: viewport.visibleRange.lowerBound)
        let rowMaxX = viewport.x(for: viewport.visibleRange.upperBound)
        let minX = max(min(placement.minX + span.hiddenLeading, rowMaxX - width), rowMinX)
        return ClipNameFieldPlace(minX: minX - placement.minX, width: width)
    }
}

extension ClipBox {
    /// From the start of the clip's first piece to the end of its last one,
    /// in song seconds. Nil for a clip without pieces.
    public var timeRange: ClosedRange<Double>? {
        guard var lower = segments.first?.range.lowerBound,
              var upper = segments.first?.range.upperBound
        else { return nil }
        for segment in segments.dropFirst() {
            lower = min(lower, segment.range.lowerBound)
            upper = max(upper, segment.range.upperBound)
        }
        return lower...upper
    }
}

// MARK: - Where a clip is drawn

/// The part of a clip that is drawn, measured without the scroll position:
/// it stays the same while a clip that is fully on screen scrolls sideways.
struct ClipSpan: Equatable, Sendable {
    /// The song time at the left edge of the drawn part.
    var startSeconds: Double
    var pointsPerSecond: Double
    /// The width of the drawn part in points.
    var width: CGFloat
    /// How much of the drawn part lies beyond the left edge of the screen.
    var hiddenLeading: CGFloat
    /// How much of the drawn part lies beyond the right edge of the screen.
    var hiddenTrailing: CGFloat

    /// The song time at the right edge of the drawn part.
    var endSeconds: Double {
        startSeconds + Double(width) / pointsPerSecond
    }
}

/// Where a clip sits in its lane right now.
struct ClipPlacement {
    /// The x of the left edge of the drawn part, on a whole point so the
    /// clip's left edge is sharp and meets a beat line exactly.
    var minX: CGFloat
    var span: ClipSpan

    /// How far a clip that goes on beyond the screen is drawn past the edge:
    /// far enough to hide its rounded corner and its outline there.
    private static let overhang = DesignTokens.Radius.clip + DesignTokens.Lines.clipOutlineSelectedWidth

    /// The widest clip that is drawn whole, in points. About two screens.
    private static let widestWholeClip: CGFloat = 2048

    /// Nil when the clip is not on screen.
    init?(clip: ClipBox, viewport: TimelineViewport) {
        let pointsPerSecond = viewport.scale.pointsPerSecond
        let visible = viewport.visibleRange
        guard pointsPerSecond > 0,
              let range = clip.timeRange,
              range.overlaps(visible)
        else { return nil }

        // A clip can be far wider than the screen when zoomed in. Then only
        // the part on screen is given a view, so a long clip costs no more
        // than a short one. A clip of ordinary width is given a view for all
        // of it, also where a part lies beyond the screen: its drawing then
        // stays the same while it scrolls in or out, and is not made again on
        // every frame.
        let overhangSeconds = Double(Self.overhang) / pointsPerSecond
        let isDrawnWhole = (range.upperBound - range.lowerBound) * pointsPerSecond <= Double(Self.widestWholeClip)
        let start = isDrawnWhole ? range.lowerBound : max(range.lowerBound, visible.lowerBound - overhangSeconds)
        let end = isDrawnWhole ? range.upperBound : min(range.upperBound, visible.upperBound + overhangSeconds)
        guard end > start else { return nil }

        minX = viewport.x(for: start).rounded(.down)
        span = ClipSpan(
            startSeconds: start,
            pointsPerSecond: pointsPerSecond,
            width: CGFloat((end - start) * pointsPerSecond),
            hiddenLeading: CGFloat(max((visible.lowerBound - start) * pointsPerSecond, 0)),
            hiddenTrailing: CGFloat(max((end - visible.upperBound) * pointsPerSecond, 0))
        )
    }
}

// MARK: - The clip itself

/// The clip as drawn inside its own frame: the body with the waveforms, the
/// bar on top, and the outline around both.
private struct ClipContent: View, Equatable {
    @Environment(\.timelinePalette) private var palette

    /// The part of the clip the real pointer is over: the bar or the body.
    @State private var partUnderPointer: ClipPart?
    /// The real pointer is over the take count, which lies inside the bar.
    @State private var isPointerOverTakeCount = false

    let clip: ClipBox
    let isDimmed: Bool
    let span: ClipSpan
    /// How much of the right end lies under the next clip on the track.
    let coveredWidth: CGFloat
    /// Where the field for typing the name goes, or nil when the clip is not
    /// being renamed.
    let nameField: ClipNameFieldPlace?
    /// See `ClipView`'s `shownPointer`.
    let shownPointer: ClipPart?
    /// See `ClipView`'s `onTakeCount`. It is not compared: what it does
    /// depends only on the clip's id, which is.
    let onTakeCount: (@MainActor () -> Void)?
    /// See `ClipView`'s `onRenameEnd`. It is not compared, for the same reason.
    let onRenameEnd: (@MainActor (String?) -> Void)?

    nonisolated static func == (lhs: ClipContent, rhs: ClipContent) -> Bool {
        lhs.isDimmed == rhs.isDimmed && lhs.span == rhs.span && lhs.coveredWidth == rhs.coveredWidth
            && lhs.nameField == rhs.nameField && lhs.shownPointer == rhs.shownPointer
            && lhs.clip == rhs.clip
    }

    /// The part of the clip that is drawn as having the pointer over it.
    private var pointer: ClipPart? {
        if let shownPointer {
            return shownPointer
        }
        // An edge that is being dragged stays lit, wherever the pointer has gone.
        if let trimmedEdge = clip.trimmedEdge {
            return trimmedEdge == .start ? .startEdge : .endEdge
        }
        return isPointerOverTakeCount ? .takeCount : partUnderPointer
    }

    /// The drawn part begins where the clip begins, so the clip's start can
    /// be taken hold of there. Not while the name is typed.
    private var hasStartEdge: Bool {
        nameField == nil && clip.timeRange?.lowerBound == span.startSeconds
    }

    /// The drawn part ends where the clip ends, and the next clip does not
    /// lie over that end.
    private var hasEndEdge: Bool {
        guard nameField == nil, coveredWidth == 0, let end = clip.timeRange?.upperBound else { return false }
        return abs(CGFloat((end - span.startSeconds) * span.pointsPerSecond) - span.width) < 0.5
    }

    var body: some View {
        let pointer = pointer
        ZStack(alignment: .top) {
            // The fill and the waveform of every piece, in one drawing. It is
            // compared with what it was, so it is drawn again only when the
            // clip or the zoom changes, and not while the clip scrolls across
            // an edge of the screen, where only the bar's text has to move.
            ClipBodyCanvas(
                clip: clip,
                startSeconds: span.startSeconds,
                pointsPerSecond: span.pointsPerSecond,
                coveredWidth: coveredWidth,
                hasPointerOver: pointer != nil
            )
            .equatable()
            // The bands of the effects on stretches of the clip, along its
            // lower edge: over the waveform and under the markers, so a
            // marker and its readout are never hidden by one.
            if clip.ownEffects.contains(where: { $0.range != nil }) {
                ClipEffectBands(effects: clip.ownEffects, span: span, coveredWidth: coveredWidth)
                    .equatable()
            }
            // The syllable markers and the sub-beat lines, over the waveform
            // and under the bar. Only a clip that was given them has them.
            if let marks = clip.timingMarks {
                ClipTimingLayer(
                    marks: marks,
                    pieces: clip.segments.map(\.range),
                    span: span,
                    coveredWidth: coveredWidth
                )
                .equatable()
            }
            ClipBar(
                clip: clip,
                width: span.width,
                hiddenLeading: span.hiddenLeading,
                hiddenTrailing: max(span.hiddenTrailing, coveredWidth),
                showsParts: nameField == nil,
                pointer: pointer,
                isPointerOverTakeCount: $isPointerOverTakeCount,
                onTakeCount: onTakeCount
            )
        }
        .overlay(alignment: .topLeading) {
            if let nameField {
                ClipNameField(
                    name: clip.displayName,
                    place: nameField,
                    isSelected: clip.isSelected,
                    onEnd: onRenameEnd
                )
            }
        }
        .overlay {
            ClipEdgeHandles(
                width: span.width,
                hasStart: hasStartEdge,
                hasEnd: hasEndEdge,
                lit: pointer == .startEdge ? .start : pointer == .endEdge ? .end : nil
            )
        }
        .overlay {
            outline(hasPointerOver: pointer != nil)
                .allowsHitTesting(false)
        }
        // A clip that is being renamed is shown at full strength even when
        // it is muted, so what is typed can be read.
        .opacity(isDimmed && nameField == nil ? DesignTokens.Opacity.muted : 1)
        .onContinuousHover(coordinateSpace: .local) { phase in
            let part = partUnderPointer(for: phase)
            if part != partUnderPointer {
                partUnderPointer = part
            }
        }
        // The take count must stay reachable for VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenName)
    }

    /// The outline of the clip. While the clip is renamed the name field may
    /// reach out past the clip, so the outline then goes around both.
    @ViewBuilder
    private func outline(hasPointerOver: Bool) -> some View {
        let color = clip.isSelected
            ? palette.clipOutlineSelected
            : hasPointerOver ? palette.clipOutlineHovered : palette.clipOutline
        let lineWidth = clip.isSelected
            ? DesignTokens.Lines.clipOutlineSelectedWidth
            : DesignTokens.Lines.clipOutlineWidth
        if let nameField {
            ClipWithNameFieldOutline(fieldMinX: nameField.minX, fieldWidth: nameField.width, lineWidth: lineWidth)
                .stroke(color, lineWidth: lineWidth)
        } else {
            DesignTokens.Shapes.clip.strokeBorder(color, lineWidth: lineWidth)
        }
    }

    /// The bar or the body, from where the pointer is. The end that lies
    /// under the next clip belongs to that clip, so it counts as outside.
    private func partUnderPointer(for phase: HoverPhase) -> ClipPart? {
        guard case .active(let location) = phase,
              location.x <= span.width - coveredWidth
        else { return nil }
        // The edges come first: they run over the bar and the body alike.
        let edgeZone = ClipEdgeZone.width(ofClipWidth: span.width)
        if hasStartEdge, location.x < edgeZone {
            return .startEdge
        }
        if hasEndEdge, location.x >= span.width - edgeZone {
            return .endEdge
        }
        return location.y < DesignTokens.Sizes.clipBarHeight ? .bar : .body
    }

    /// What VoiceOver reads for the clip.
    private var spokenName: String {
        var parts = [clip.displayName.isEmpty ? "Clip" : clip.displayName]
        if clip.takeCount > 1 {
            parts.append("take \(clip.activeTakeNumber) of \(clip.takeCount)")
        }
        if clip.isTriplet {
            parts.append("triplets")
        }
        if let volume = ClipBar.volumeText(for: clip) {
            parts.append("volume \(volume)")
        }
        if clip.muted {
            parts.append("muted")
        }
        let ownEffects = clip.ownEffects
        if !ownEffects.isEmpty {
            parts.append("effects: " + ownEffects.map(\.kind.menuTitle).joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }
}

/// What is under a clip's bar, drawn for the part of the clip that starts at
/// `startSeconds` and fills the width it is given.
private struct ClipBodyCanvas: View, Equatable {
    @Environment(\.timelinePalette) private var palette

    let clip: ClipBox
    let startSeconds: Double
    let pointsPerSecond: Double
    /// How much of the right end lies under the next clip on the track.
    let coveredWidth: CGFloat
    /// The pointer is over the clip, so the fill is a little stronger.
    let hasPointerOver: Bool

    nonisolated static func == (lhs: ClipBodyCanvas, rhs: ClipBodyCanvas) -> Bool {
        lhs.startSeconds == rhs.startSeconds && lhs.pointsPerSecond == rhs.pointsPerSecond
            && lhs.coveredWidth == rhs.coveredWidth && lhs.hasPointerOver == rhs.hasPointerOver
            && lhs.clip == rhs.clip
    }

    var body: some View {
        let clip = clip
        let startSeconds = startSeconds
        let pointsPerSecond = pointsPerSecond
        let coveredWidth = coveredWidth
        let fill = hasPointerOver ? palette.clipFillHovered : palette.clipFill
        let waveform = palette.clipWaveform
        let coveredWaveform = palette.clipWaveformCovered
        Canvas { context, size in
            ClipBodyDrawing.draw(
                clip,
                startSeconds: startSeconds,
                pointsPerSecond: pointsPerSecond,
                coveredWidth: coveredWidth,
                fill: fill,
                waveform: waveform,
                coveredWaveform: coveredWaveform,
                in: &context,
                size: size
            )
        }
    }
}

/// The outline of a clip that is being renamed: one line around the clip and
/// the name field together. The field's top corners are round and its lower
/// corners square, like the bar it lies on.
private struct ClipWithNameFieldOutline: Shape {
    /// The field's left edge, counted from the left edge of the clip.
    let fieldMinX: CGFloat
    let fieldWidth: CGFloat
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        // A line is drawn half on each side of its path. The path therefore
        // lies half a line width inside the edge, so the line stays inside.
        let inset = lineWidth / 2
        let radius = DesignTokens.Radius.clip - inset
        let clip = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: rect.insetBy(dx: inset, dy: inset))
        let field = UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: radius,
            style: .continuous
        )
        .path(
            in: CGRect(
                x: rect.minX + fieldMinX,
                y: rect.minY,
                width: fieldWidth,
                height: DesignTokens.Sizes.clipBarHeight
            )
            .insetBy(dx: inset, dy: inset)
        )
        return clip.union(field)
    }
}

// MARK: - Drawing the body

/// Draws what is under a clip's bar: a fill behind every piece and the
/// waveform on it. Where a joined clip has a gap, nothing is drawn. Where the
/// next clip lies over the end of this one, the waveform is dim.
private enum ClipBodyDrawing {
    static func draw(
        _ clip: ClipBox,
        startSeconds: Double,
        pointsPerSecond: Double,
        coveredWidth: CGFloat,
        fill: Color,
        waveform: Color,
        coveredWaveform: Color,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let top = DesignTokens.Sizes.clipBarHeight
        guard size.height > top, size.width > 0, pointsPerSecond > 0 else { return }

        // Keeps the fill inside the clip's rounded bottom corners.
        context.clip(to: DesignTokens.Shapes.clip.path(in: CGRect(origin: .zero, size: size)))

        // The waveform is the same drawing the song row and the take rows
        // use. It is handed the drawn part of the clip as if that were the
        // screen, so it keeps its shape while the clip scrolls.
        let drawn = TimelineViewport(
            scale: TimelineScale(pointsPerSecond: pointsPerSecond, scrollOffsetSeconds: startSeconds),
            visibleRange: startSeconds...(startSeconds + Double(size.width) / pointsPerSecond)
        )
        let box = CGRect(x: 0, y: top, width: size.width, height: size.height - top)
        // A clip that is turned up 6 dB is drawn twice as tall. The volume it
        // is really played with decides, when the clip says what that is.
        let gain = pow(10, (clip.appliedGainDB ?? clip.volumeDB) / 20)

        var fills = Path()
        var waves = Path()
        for segment in clip.segments {
            let left = max((segment.range.lowerBound - startSeconds) * pointsPerSecond, 0)
            let right = min(
                (segment.range.upperBound - startSeconds) * pointsPerSecond,
                Double(size.width)
            )
            guard right > left else { continue }

            fills.addRect(CGRect(x: left, y: Double(top), width: right - left, height: Double(size.height - top)))
            waves.addPath(
                WaveformShape(levels: segment.levels, range: segment.range, viewport: drawn, gain: gain)
                    .path(in: box)
            )
        }
        context.fill(fills, with: .color(fill))

        guard coveredWidth > 0 else {
            context.fill(waves, with: .color(waveform))
            return
        }
        // The same waveform twice, each cut to its side of the place where
        // the next clip begins.
        let coveredMinX = size.width - coveredWidth
        var uncovered = context
        uncovered.clip(to: Path(CGRect(x: 0, y: top, width: coveredMinX, height: size.height - top)))
        uncovered.fill(waves, with: .color(waveform))
        var covered = context
        covered.clip(to: Path(CGRect(x: coveredMinX, y: top, width: coveredWidth, height: size.height - top)))
        covered.fill(waves, with: .color(coveredWaveform))
    }
}

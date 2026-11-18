import SwiftUI

/// The bands of a clip's effects: for every effect on a stretch of the clip, a thin band along the bottom of
/// the clip over that stretch, with the kind's name in it when there is room. `ClipView` lays it over the
/// clip's waveform, under the timing markers. Nothing else uses it. An effect on the whole clip has no band:
/// it is the mark "FX" in the clip's bar.
///
/// The bands are neutral, dark and see-through with a thin light line around them, so they are none of the
/// timing colours and the waveform shows through them. They lie at the lower edge, where a waveform seldom
/// reaches, and the syllable markers stand at the top, under the bar.
///
/// Bands of effects that overlap in time lie over each other, the one that starts first lowest. Together
/// they may take `DesignTokens.Sizes.effectBandsShareOfBody` of the height under the bar. When they would
/// take more, in a low row or with many effects on one word, every band of the clip becomes a bright line
/// without a name.
///
/// The band of the effect whose row is lit in the panel (`ClipEffectMark.isSelected`) has a brighter line.
///
/// It is one drawing, however many effects there are, and it never takes the pointer.
struct ClipEffectBands: View, Equatable {
    /// The clip's effects. Those without a stretch are skipped.
    let effects: [ClipEffectMark]
    /// The part of the clip that is drawn. See `ClipView`.
    let span: ClipSpan
    /// How much of the right end lies under the next clip on the track. Nothing is drawn there.
    let coveredWidth: CGFloat

    var body: some View {
        let effects = effects
        let span = span
        let coveredWidth = coveredWidth
        Canvas { context, size in
            ClipEffectBandsDrawing.draw(effects, span: span, coveredWidth: coveredWidth, in: &context, size: size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Which band lies over which: the row of each effect on a stretch, counted from the lowest.
enum EffectBandRows {
    /// The effects that have a stretch, in the order they start, each with its row. An effect gets the
    /// lowest row that is free where it starts, so two effects share a row unless they overlap.
    static func place(_ effects: [ClipEffectMark]) -> [(effect: ClipEffectMark, range: ClosedRange<Double>, row: Int)] {
        let onStretches = effects
            .compactMap { effect in effect.range.map { (effect: effect, range: $0) } }
            .sorted { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }
        // Where the last band of each row ends.
        var rowEnds: [Double] = []
        return onStretches.map { entry in
            let row = rowEnds.firstIndex { $0 <= entry.range.lowerBound } ?? rowEnds.count
            if row == rowEnds.count {
                rowEnds.append(entry.range.upperBound)
            } else {
                rowEnds[row] = entry.range.upperBound
            }
            return (entry.effect, entry.range, row)
        }
    }
}

private enum ClipEffectBandsDrawing {
    static func draw(
        _ effects: [ClipEffectMark],
        span: ClipSpan,
        coveredWidth: CGFloat,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        let placed = EffectBandRows.place(effects)
        let top = DesignTokens.Sizes.clipBarHeight
        let bodyHeight = size.height - top
        let inset = DesignTokens.Sizes.effectBandInset
        guard !placed.isEmpty, bodyHeight > 0, span.pointsPerSecond > 0, size.width > 2 * inset else { return }

        let rowCount = (placed.map(\.row).max() ?? 0) + 1
        let gap = DesignTokens.Sizes.effectBandGap
        let namedHeight = CGFloat(rowCount) * DesignTokens.Sizes.effectBandHeight + CGFloat(rowCount - 1) * gap
        let isNamed = namedHeight <= bodyHeight * DesignTokens.Sizes.effectBandsShareOfBody
        let height = isNamed ? DesignTokens.Sizes.effectBandHeight : DesignTokens.Sizes.effectBandLineHeight

        // Nothing under the bar's place and nothing where the next clip lies over this one.
        context.clip(to: Path(CGRect(x: 0, y: top, width: size.width - coveredWidth, height: bodyHeight)))

        for entry in placed {
            // A band keeps inside the clip's outline at both ends, and is never too narrow to see.
            var left = CGFloat((entry.range.lowerBound - span.startSeconds) * span.pointsPerSecond)
            var right = CGFloat((entry.range.upperBound - span.startSeconds) * span.pointsPerSecond)
            left = max(left, inset)
            right = min(right, size.width - inset)
            guard right > left - DesignTokens.Sizes.effectBandLineHeight else { continue }
            if right - left < DesignTokens.Sizes.effectBandLineHeight {
                let middle = min(max((left + right) / 2, inset), size.width - inset)
                left = middle - DesignTokens.Sizes.effectBandLineHeight / 2
                right = middle + DesignTokens.Sizes.effectBandLineHeight / 2
            }
            let bottom = size.height - inset - CGFloat(entry.row) * (height + gap)
            let box = CGRect(x: left, y: bottom - height, width: right - left, height: height)
            let corner = min(DesignTokens.Sizes.effectBandCorner, height / 2)
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

            guard isNamed else {
                let color = entry.effect.isSelected
                    ? DesignTokens.Colors.effectBandEdgeSelected
                    : DesignTokens.Colors.effectBandLine
                // In a low row the waveform fills the clip, so the line gets a dark edge to stand on.
                let edge = DesignTokens.Lines.effectBandEdgeWidth
                context.fill(
                    RoundedRectangle(cornerRadius: corner + edge, style: .continuous)
                        .path(in: box.insetBy(dx: -edge, dy: -edge)),
                    with: .color(DesignTokens.Colors.effectBandLineEdge)
                )
                context.fill(shape.path(in: box), with: .color(color))
                continue
            }
            context.fill(shape.path(in: box), with: .color(DesignTokens.Colors.effectBandFill))
            let lineWidth = DesignTokens.Lines.effectBandEdgeWidth
            context.stroke(
                shape.path(in: box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)),
                with: .color(
                    entry.effect.isSelected
                        ? DesignTokens.Colors.effectBandEdgeSelected
                        : DesignTokens.Colors.effectBandEdge
                ),
                lineWidth: lineWidth
            )

            // The name, when all of it fits in the part of the band that can be seen.
            let name = context.resolve(
                Text(entry.effect.kind.shortName)
                    .font(DesignTokens.Fonts.effectBandName)
                    .foregroundStyle(DesignTokens.Colors.effectBandText)
            )
            let nameSize = name.measure(in: CGSize(width: CGFloat.infinity, height: height))
            let padding = DesignTokens.Spacing.small
            let seenLeft = max(box.minX, span.hiddenLeading)
            let seenRight = min(box.maxX, size.width - max(span.hiddenTrailing, coveredWidth))
            if seenRight - seenLeft >= nameSize.width + 2 * padding {
                context.draw(name, at: CGPoint(x: seenLeft + padding, y: box.midY), anchor: .leading)
            }
        }
    }
}

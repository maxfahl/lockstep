import LockstepCore
import SwiftUI

/// The recording that is going to a track right now, drawn in the track's
/// row. It is the only thing in the timeline that is red.
///
/// It is placed like the content of a lane: give it the lane's viewport and
/// lay it over the whole row. `TrackLane` does this for a track that has a
/// `recording`.
///
///     RecordingClip(recording: recording, viewport: viewport)
///
/// What it shows:
/// - during the run-up, a red line at the place where the recording will
///   start, and nothing else;
/// - while recording, a red clip from that place up to the playhead: a red
///   bar with a dot and the word "Recording", and the waveform of what has
///   been recorded so far. Its left corners are round, like a clip's. Its
///   right edge is square, because the clip is still growing there.
///
/// A narrow one shows the dot alone, and a very narrow one only the bar.
/// Nothing on it can be clicked.
public struct RecordingClip: View {
    private let recording: TrackRecording
    private let viewport: TimelineViewport

    public init(recording: TrackRecording, viewport: TimelineViewport) {
        self.recording = recording
        self.viewport = viewport
    }

    public var body: some View {
        let originX = viewport.x(for: recording.origin).rounded(.down)
        // A recording that grows is read from its progress, here and nowhere
        // else, so this is the only view drawn again while it grows.
        let recordedUntil = recording.progress.map(\.recordedUntil) ?? recording.recordedUntil
        let levels = recording.progress?.levels ?? recording.levels
        ZStack(alignment: .topLeading) {
            if let until = recordedUntil, until > recording.origin {
                let width = max(viewport.x(for: until) - originX, 0)
                clip(until: until, width: width, levels: levels)
                    .frame(width: width)
                    .offset(x: originX)
            }
            Rectangle()
                .fill(DesignTokens.Colors.recordingClipOutline)
                .frame(width: DesignTokens.Lines.recordOriginWidth)
                .offset(x: originX)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recordedUntil == nil ? "Recording starts here" : "Recording")
    }

    /// The red clip, inside a frame that is as wide as what has been recorded.
    private func clip(until: Double, width: CGFloat, levels: WaveformLevels) -> some View {
        let shape = Self.shape
        return ZStack(alignment: .top) {
            shape.fill(DesignTokens.Colors.recordingClipFill)
            // The waveform is the same drawing a clip uses. It is handed the
            // recorded stretch as if that were the screen.
            WaveformShape(
                levels: levels,
                range: recording.origin...until,
                viewport: TimelineViewport(
                    scale: TimelineScale(
                        pointsPerSecond: viewport.scale.pointsPerSecond,
                        scrollOffsetSeconds: recording.origin
                    ),
                    visibleRange: recording.origin...until
                )
            )
            .fill(DesignTokens.Colors.record)
            .padding(.top, DesignTokens.Sizes.clipBarHeight)
            bar(width: width)
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                DesignTokens.Colors.recordingClipOutline,
                lineWidth: DesignTokens.Lines.clipOutlineWidth
            )
        }
    }

    /// The bar on top: a dot and the word "Recording" when there is room.
    private func bar(width: CGFloat) -> some View {
        let showsDot = width >= 2 * DesignTokens.Spacing.clipBarPadding + DesignTokens.Sizes.clipBarCharacterWidth
        let showsWord = width >= DesignTokens.Sizes.recordingClipLabelMinimumWidth
        return HStack(spacing: DesignTokens.Spacing.small) {
            if showsDot {
                Image(systemName: "circle.fill")
                    .font(DesignTokens.Fonts.clipBadge)
                    .foregroundStyle(DesignTokens.Colors.record)
            }
            if showsWord {
                Text("Recording")
                    .font(DesignTokens.Fonts.clipName)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.clipBarPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DesignTokens.Sizes.clipBarHeight)
        .background(DesignTokens.Colors.recordingClipBar)
    }

    /// Round on the left like a clip, square on the right where it grows.
    private static var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: DesignTokens.Radius.clip,
            bottomLeadingRadius: DesignTokens.Radius.clip,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
    }
}

import SwiftUI

/// The colours of everything drawn inside a timeline: waveforms, beat lines,
/// clips, the ruler and the playhead.
///
/// There are two sets. Timeline rows are glass, and `glassLanes` is the set for
/// them. A timeline that lies on a glass panel (the takes in the inspector) has
/// plain dark rows, because glass must not lie on glass, and `plainLanes` is
/// the set for those. Such a timeline is marked with `timelineOnGlass()`.
///
/// A view reads the set that is on from the environment and never picks one
/// itself:
///
///     @Environment(\.timelinePalette) private var palette
///
/// The line colours are light and see-through. They are meant to be drawn on
/// top of the rows' content, where they read on the dark row and stay faintly
/// visible where they cross a waveform.
public struct TimelinePalette: Sendable {

    // Waveforms. Used by the song row, the clips of a track row and the rows
    // of the small takes timeline.

    /// The song's waveform. A neutral tone.
    public var songWaveform: Color
    /// The waveform of a clip, and of the active take. The accent tone.
    public var clipWaveform: Color
    /// The waveform of a take that is not the active one. A dimmer neutral.
    public var inactiveTakeWaveform: Color

    // Beat lines. Drawn by the timeline container through every row.

    /// A beat line. Low contrast.
    public var beatLine: Color
    /// A bar line, at every bar start. Clearly stronger than a beat line.
    public var barLine: Color
    /// A sub-beat line across a selected clip, between the beat lines. About
    /// half as strong as a beat line.
    public var subBeatLine: Color
    /// A line at a syllable of the track a selected clip aims at, with its
    /// small bar on top. Much stronger than a sub-beat line, so the two are
    /// not taken for each other, and neutral, because colour on a clip means
    /// timing.
    public var leadSyllableLine: Color
    /// An estimated beat, and a beat in an uncertain stretch. Drawn dashed,
    /// with `DesignTokens.Lines.estimatedBeatDash`.
    public var estimatedBeatLine: Color
    /// A faint light band behind an uncertain stretch. Not a warning colour.
    public var uncertainBand: Color
    /// A faint dark band over a gap that has no beats at all.
    public var unfilledGapBand: Color

    // Clips. Used by the clip view of a track row.

    /// The body of a clip, behind its waveform.
    public var clipFill: Color
    /// The body of a clip while the pointer is over the clip. A little stronger.
    public var clipFillHovered: Color
    /// The outline of a clip. It continues across the gap of a joined clip.
    public var clipOutline: Color
    /// The outline of a clip while the pointer is over the clip. Brighter,
    /// but still coloured, so it is not taken for the white outline of a
    /// selected clip.
    public var clipOutlineHovered: Color
    /// The waveform at the end of a clip where the next clip on the track
    /// lies over it. Dim, so the waveform of the clip in front reads clearly.
    public var clipWaveformCovered: Color
    /// The stronger outline of a selected clip.
    public var clipOutlineSelected: Color
    /// The name in a clip bar.
    public var clipBarText: Color
    /// The small marks in a clip bar: the take count "3/5", the triplet "3".
    public var clipBarBadge: Color

    // The ruler.

    /// The tick at a beat.
    public var rulerTick: Color
    /// The taller tick at a bar start.
    public var rulerBarTick: Color
    /// Bar numbers and time marks.
    public var rulerLabel: Color

    // The playhead. Bright and neutral: red is kept for recording.

    /// The playhead line and its head.
    public var playhead: Color

    /// For the plain dark rows of a timeline on a glass panel: calm waveforms
    /// and quiet lines, because the background behind them is known and even.
    public static let plainLanes = TimelinePalette(
        songWaveform: Color(hex: 0x8E8E99),
        clipWaveform: DesignTokens.Colors.accent,
        inactiveTakeWaveform: Color(hex: 0x6C6C76),
        beatLine: Color.white.opacity(0.16),
        barLine: Color.white.opacity(0.34),
        subBeatLine: Color.white.opacity(0.09),
        leadSyllableLine: Color.white.opacity(0.50),
        estimatedBeatLine: Color.white.opacity(0.22),
        uncertainBand: Color.white.opacity(0.05),
        unfilledGapBand: Color.black.opacity(0.30),
        clipFill: DesignTokens.Colors.accent.opacity(0.12),
        clipFillHovered: DesignTokens.Colors.accent.opacity(0.20),
        clipOutline: DesignTokens.Colors.accent.opacity(0.45),
        clipOutlineHovered: DesignTokens.Colors.accent.opacity(0.85),
        clipWaveformCovered: DesignTokens.Colors.accent.opacity(0.35),
        clipOutlineSelected: Color.white.opacity(0.90),
        clipBarText: Color.white.opacity(0.92),
        clipBarBadge: Color.white.opacity(0.70),
        rulerTick: Color.white.opacity(0.28),
        rulerBarTick: Color.white.opacity(0.55),
        rulerLabel: Color.white.opacity(0.62),
        playhead: Color.white.opacity(0.96)
    )

    /// For glass rows, which is what a timeline has unless it lies on a glass
    /// panel: everything is brighter and the lines are stronger, because glass
    /// is lighter than a plain row and uneven across its surface.
    public static let glassLanes = TimelinePalette(
        songWaveform: Color(hex: 0xDCDCE4),
        clipWaveform: Color(hex: 0xB4B8FF),
        inactiveTakeWaveform: Color(hex: 0xA0A0AC),
        beatLine: Color.white.opacity(0.26),
        barLine: Color.white.opacity(0.50),
        subBeatLine: Color.white.opacity(0.14),
        leadSyllableLine: Color.white.opacity(0.62),
        estimatedBeatLine: Color.white.opacity(0.34),
        uncertainBand: Color.white.opacity(0.08),
        unfilledGapBand: Color.black.opacity(0.30),
        clipFill: DesignTokens.Colors.accent.opacity(0.18),
        clipFillHovered: DesignTokens.Colors.accent.opacity(0.28),
        clipOutline: Color(hex: 0xB4B8FF, opacity: 0.60),
        clipOutlineHovered: Color(hex: 0xB4B8FF, opacity: 0.95),
        clipWaveformCovered: Color(hex: 0xB4B8FF, opacity: 0.35),
        clipOutlineSelected: Color.white.opacity(0.95),
        clipBarText: Color.white.opacity(0.92),
        clipBarBadge: Color.white.opacity(0.74),
        rulerTick: Color.white.opacity(0.36),
        rulerBarTick: Color.white.opacity(0.65),
        rulerLabel: Color.white.opacity(0.72),
        playhead: Color.white.opacity(0.96)
    )
}

extension EnvironmentValues {
    /// True below `timelineOnGlass()`: the timeline lies on a glass panel, so
    /// its rows are plain and dark instead of glass.
    @Entry public var timelineLiesOnGlass: Bool = false

    /// The timeline colours that are on: for glass rows, or for the plain
    /// rows of a timeline on a glass panel.
    public var timelinePalette: TimelinePalette {
        timelineLiesOnGlass ? .plainLanes : .glassLanes
    }
}

extension View {
    /// Marks a timeline that lies on a glass panel. Its rows become plain and
    /// dark, with the calmer colours that suit them, because glass must not
    /// lie on glass. Everything else in the app has glass rows.
    public func timelineOnGlass() -> some View {
        environment(\.timelineLiesOnGlass, true)
    }
}

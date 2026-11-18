import Foundation

/// One syllable of a clip, as its marker shows it: where the syllable starts
/// and how far that is from what it is judged against. That is the nearest
/// sub-beat, or, for a clip that aims at another track, the syllable of that
/// track it is paired with.
///
/// Like the other display types it holds finished values. Which kind of
/// timing a syllable has is decided where the markers are made, because the
/// limits are settings. The marker only shows it.
public struct SyllableMarker: Sendable, Equatable, Identifiable {
    /// How close a syllable is to its sub-beat, or to its partner in the
    /// track its clip aims at. It decides the marker's colour:
    /// `DesignTokens.Colors.timingOnBeat`, `timingSlightlyOff` or
    /// `timingNeutral`.
    public enum Timing: Sendable, Equatable {
        /// On the beat, or on its partner.
        case onBeat
        /// Slightly off: meant for the sub-beat or the partner, but not on it.
        case slightlyOff
        /// So far from any sub-beat that it counts as meant. Not an error.
        case deliberate
        /// In a clip that aims at another track: no syllable of that track
        /// is paired with this one, so it is left where it is. Neutral, like
        /// `deliberate`, and its readout says "No match".
        case unpaired
    }

    public var id: UUID
    /// Where the syllable starts, in song seconds.
    public var time: Double
    /// The distance to the nearest sub-beat, or to the partner, in
    /// milliseconds. Late is positive, early is negative. Not used for an
    /// unpaired syllable.
    public var offsetMilliseconds: Double
    public var timing: Timing
    /// The syllable is left out of the timing fixes. Its marker is hollow.
    public var isExcluded: Bool
    /// The syllable has a distance to show. False where the song has no
    /// beats to measure against: the marker is drawn, and the pointer brings
    /// up no readout at it.
    public var hasDistance: Bool

    public init(
        id: UUID,
        time: Double,
        offsetMilliseconds: Double,
        timing: Timing,
        isExcluded: Bool = false,
        hasDistance: Bool = true
    ) {
        self.id = id
        self.time = time
        self.offsetMilliseconds = offsetMilliseconds
        self.timing = timing
        self.isExcluded = isExcluded
        self.hasDistance = hasDistance
    }

    /// What the readout says when the pointer is at the marker: "23 ms late",
    /// "8 ms early", "On the beat", and ", excluded" after it for a syllable
    /// that is left out of the timing fixes.
    public var readoutText: String {
        readoutText(againstLead: false)
    }

    /// The readout of a marker in a clip that is judged against the beat, or,
    /// with `againstLead`, against the syllables of the track it aims at.
    /// There a syllable that is on its partner reads "On the lead", and one
    /// without a partner "No match".
    public func readoutText(againstLead: Bool) -> String {
        let milliseconds = Int(offsetMilliseconds.rounded())
        let distance: String
        if timing == .unpaired {
            distance = "No match"
        } else if milliseconds == 0 {
            distance = againstLead ? "On the lead" : "On the beat"
        } else {
            distance = "\(abs(milliseconds)) ms \(milliseconds > 0 ? "late" : "early")"
        }
        return isExcluded ? distance + ", excluded" : distance
    }
}

/// What is drawn on a clip to judge its timing: a marker at every syllable
/// and the lines to judge the markers against. Those are the sub-beat lines,
/// or, for a clip that aims at another track, lines at that track's
/// syllables. `ClipBox.timingMarks` holds it, and it is filled in only for a
/// selected clip.
public struct ClipTimingMarks: Sendable, Equatable {
    /// The syllables of the clip, in the order they come.
    public var markers: [SyllableMarker]
    /// The sub-beats between the beats, in song seconds and in order. The
    /// beats themselves are left out, because the timeline draws those. With
    /// four sub-beats to a beat there are three of these between two beats,
    /// and five across a clip whose lines run in triplets (six to a beat).
    public var subBeatTimes: [Double]
    /// For a clip that aims at another track: where that track's syllables
    /// are heard, in song seconds and in order. A line is drawn at each, in
    /// a look of its own, and no sub-beat line is drawn, whatever
    /// `subBeatTimes` holds. Nil, which is what the marks start with, for a
    /// clip that aims at the beat. Set it after making the marks.
    public var leadSyllableTimes: [Double]?
    /// Shows the readout of this marker as if the pointer were at it,
    /// wherever the pointer really is. The design lab uses it for pictures.
    /// Nil follows the real pointer.
    public var shownReadout: SyllableMarker.ID?
    /// Lets the sub-beat lines fade in while zooming in, in place of
    /// appearing all at once. The numbers are the distance between two
    /// neighbouring lines, in points: at the lower one and below no line is
    /// drawn, at the upper one and above the lines are as strong as they
    /// get, and between the two they are fainter. Nil draws them at full
    /// strength from `DesignTokens.Sizes.subBeatLineMinimumSpacing` on.
    public var subBeatLineFade: ClosedRange<CGFloat>?
    /// How long the pointer must rest at a marker before its readout comes
    /// up, in seconds. 0 shows it at once.
    public var readoutDelay: Double

    public init(
        markers: [SyllableMarker],
        subBeatTimes: [Double],
        shownReadout: SyllableMarker.ID? = nil,
        subBeatLineFade: ClosedRange<CGFloat>? = nil,
        readoutDelay: Double = 0
    ) {
        self.markers = markers
        self.subBeatTimes = subBeatTimes
        self.shownReadout = shownReadout
        self.subBeatLineFade = subBeatLineFade
        self.readoutDelay = readoutDelay
    }
}

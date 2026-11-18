/// What a clip's timing is held against when it is corrected.
///
/// Until phase 36 that was always the song: the beats and the sub-beats between them. A double that Max
/// recorded himself is held against the lead instead, so that the two voices sound like one, and then the
/// places to aim at are the lead's syllables.
///
///     let beat = TimingTargets.subBeats(grid: grid, perBeat: 4)       // as it always was
///     let lead = TimingTargets.syllables([
///         TimingTargets.Target(time: 12.480),                         // where a syllable of the lead is heard
///         TimingTargets.Target(time: 12.730, noteEnd: 13.210),        // one that is held, and where it ends
///     ])
///
///     LineShift.slide(markerTimes: times, targets: lead)              // how far a line slides
///     SyllableMoves.plan(line: line, songStart: start, targets: lead, strength: 1)
///
/// Against sub-beats every answer is what it was before there was a choice. What changes against a list of
/// times is written where it is done: the slide of a line and who is paired with whom in `SyllableMatch`,
/// the move of each syllable and the end of a held note in `SyllableMoves`.
public enum TimingTargets: Sendable, Equatable {
    /// The beats of the song, each divided in `perBeat` equal parts: 4 for sixteenths, 6 for triplets.
    case subBeats(grid: Grid, perBeat: Int)
    /// The syllables of another voice, earliest first, in song seconds where they are heard.
    case times([Target])

    /// One syllable of the voice that is aimed at.
    public struct Target: Sendable, Equatable {
        /// When it is heard, in song seconds.
        public var time: Double
        /// When its note ends, in song seconds: where the pause after it starts, or the next syllable. Nil
        /// when that is not known, and then no note end is matched to it.
        public var noteEnd: Double?

        public init(time: Double, noteEnd: Double? = nil) {
            self.time = time
            self.noteEnd = noteEnd
        }
    }

    /// A list of syllables to aim at, put in the order of the song. A syllable without a place is left out.
    public static func syllables(_ targets: [Target]) -> TimingTargets {
        .times(targets.filter(\.time.isFinite).sorted { $0.time < $1.time })
    }
}

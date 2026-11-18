import LockstepCore
import LockstepUI

/// A project's beats in the form the timeline draws: one line per beat, the
/// stretches the app is unsure about, and the stretches where no beat was placed.
///
///     let shown = ShownBeats(grid)
///     timeline.beatLines = shown.lines
struct ShownBeats {
    /// One line per beat, in time order. A line that starts a bar carries its bar number.
    var lines: [BeatLine] = []
    /// Runs of three or more beats no clean drum hit backed, in song seconds.
    var uncertainRanges: [ClosedRange<Double>] = []
    /// From the last beat before a stretch without beats to the first beat after it.
    var unfilledGaps: [ClosedRange<Double>] = []

    /// No beats: what the window shows before the beats are found.
    static let none = ShownBeats()

    private init() {}

    init(_ grid: Grid) {
        let beats = grid.beats
        // Bars are counted from the first bar start of the song. Beat numbers go on
        // counting across a stretch without beats, so the bars after it keep their numbers.
        let firstBarStart = beats.first { grid.isBarStart($0.number) }?.number
        lines = beats.map { beat in
            let isBarStart = grid.isBarStart(beat.number)
            return BeatLine(
                time: beat.time,
                isBarStart: isBarStart,
                isEstimated: beat.estimated,
                barNumber: isBarStart ? firstBarStart.map { (beat.number - $0) / Grid.beatsPerBar + 1 } : nil
            )
        }
        uncertainRanges = BeatRefiner.uncertainRanges(in: beats)
        unfilledGaps = zip(beats, beats.dropFirst())
            .filter { $1.number != $0.number + 1 && $1.time >= $0.time }
            .map { $0.time...$1.time }
    }
}

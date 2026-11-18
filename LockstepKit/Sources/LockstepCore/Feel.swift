import Foundation

/// The two ways a beat is divided when timing is measured, and when the click sounds on sub-beats
/// (`ClickSettings.subBeats`), which is why it can be saved.
public enum SubBeatGrid: String, Codable, Sendable, Equatable, CaseIterable {
    /// Four equal parts to a beat.
    case sixteenths
    /// Six equal parts to a beat, which holds both three and six syllables to a beat.
    case triplets

    /// How many sub-beats a beat has: the `perBeat` that `MarkerDistance`, `LineShift` and `ClipTightening` take.
    public var perBeat: Int {
        switch self {
        case .sixteenths: 4
        case .triplets: 6
        }
    }
}

/// Tells from a clip's syllables whether it is rapped in sixteenths or in triplets. This is what a clip on
/// Auto uses.
///
///     let times = project.markers(in: clip, allMarkers: markers).filter { !$0.isExcluded }.map(\.songTime)
///     Feel.detect(markerTimes: times, grid: grid)     // .sixteenths or .triplets
///
/// Each grid gets a score for how well the syllables gather at one place between its sub-beats. Triplets are
/// chosen only when they win clearly, so a clip that says little either way stays on sixteenths.
public enum Feel {
    /// How much better the triplet score must be than the sixteenth score for triplets to be chosen.
    public static let tripletMargin: Double = 0.1
    /// A clip with fewer syllables than this is sixteenths: so few say nothing about the feel.
    public static let minimumMarkers = 4
    /// How strong the triplet pattern must be before it is believed: the number of syllables times the square
    /// of the triplet score. Syllables that fall anywhere reach 4 less than once in fifty clips, while four
    /// syllables exactly on triplets reach it.
    public static let minimumEvidence: Double = 4

    /// The grid a clip's syllables fit: triplets when they win clearly, otherwise sixteenths.
    ///
    /// Sixteenths is also the answer when there is too little to go by: fewer than four syllables with beats
    /// around them, or a song whose beats are not found.
    ///
    /// - Parameters:
    ///   - markerTimes: when each syllable of the clip sounds, in song seconds. Leave out the ones Max has
    ///     excluded from timing fixes.
    ///   - grid: the beats of the song.
    public static func detect(markerTimes: [Double], grid: Grid) -> SubBeatGrid {
        guard markerTimes.count >= minimumMarkers else { return .sixteenths }
        let triplets = measure(markerTimes: markerTimes, grid: grid, subBeats: .triplets)
        guard triplets.count >= minimumMarkers,
            Double(triplets.count) * triplets.score * triplets.score >= minimumEvidence
        else { return .sixteenths }
        let sixteenths = measure(markerTimes: markerTimes, grid: grid, subBeats: .sixteenths)
        return triplets.score - sixteenths.score >= tripletMargin ? .triplets : .sixteenths
    }

    /// How well the syllables gather at one place between the sub-beats of a grid: 1 when every syllable sits
    /// at the same place, 0 when they are spread evenly, or there are none to measure.
    ///
    /// The clip is first slid as a whole to where it fits this grid best, so a clip that is simply late is
    /// not taken for one in another grid. That is the best fit of all its syllables (`LineShift.best`), and
    /// on purpose not the slide that is heard, which goes by a line's first syllable alone: one syllable
    /// says too little about which grid a clip is in. Then each syllable's place between two sub-beats is read as
    /// an angle, a full turn for one sub-beat spacing, and the score is the length of the mean of those
    /// directions. Counting in turns of the grid's own spacing keeps the finer grid from winning just because
    /// its sub-beats are closer together.
    public static func score(markerTimes: [Double], grid: Grid, subBeats: SubBeatGrid) -> Double {
        measure(markerTimes: markerTimes, grid: grid, subBeats: subBeats).score
    }

    /// The score, and how many syllables had beats around them and so counted in it.
    private static func measure(
        markerTimes: [Double],
        grid: Grid,
        subBeats: SubBeatGrid
    ) -> (score: Double, count: Int) {
        let shift = LineShift.best(markerTimes: markerTimes, grid: grid, perBeat: subBeats.perBeat)
        var x = 0.0
        var y = 0.0
        var count = 0
        for time in markerTimes {
            let moved = time + shift
            guard let nearest = MarkerDistance.nearestSubBeat(to: moved, grid: grid, perBeat: subBeats.perBeat)
            else { continue }
            let angle = 2 * Double.pi * (moved - nearest.subBeatTime) / nearest.spacing
            x += cos(angle)
            y += sin(angle)
            count += 1
        }
        guard count > 0 else { return (0, 0) }
        return ((x * x + y * y).squareRoot() / Double(count), count)
    }
}

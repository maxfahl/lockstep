import LockstepCore

/// Works out what the project keeps when Max drags a beat line: an anchor, which says
/// where the beat stood by itself (`from`) and where Max put it (`to`). Every refit
/// finds the beat again by `from`, so `from` must be the beat's own place, not the
/// place it was shown at, which other dragged beats nearby may have pulled along.
///
///     let anchors = BeatMove.anchors(moving: beat, to: seconds, in: grid, unanchored: plain)
///     model.editGrid("Move Beat") { $0.anchors = anchors }
enum BeatMove {
    /// The anchors of `grid` after one of its beats was dragged to `time`.
    ///
    /// A beat that was dragged before keeps the `from` of its anchor, and that anchor
    /// is replaced, so dragging a beat twice leaves one anchor, not two.
    ///
    /// - Parameters:
    ///   - beat: The beat that was dragged, as it is in `grid`.
    ///   - time: Where it was let go, in song seconds.
    ///   - grid: The project's beats as they are shown.
    ///   - unanchored: The same beats fitted without any anchor, at the same tempo level
    ///     and with the same beat 1. It says where each beat stands by itself.
    static func anchors(moving beat: Beat, to time: Double, in grid: Grid, unanchored: Grid) -> [Anchor] {
        guard let index = grid.beats.firstIndex(where: { $0.number == beat.number }) else { return grid.anchors }
        /// Where the beat stands without an anchor of its own.
        let home: Double
        /// An anchor that was dragged from within this of `home` is this beat's.
        let reach: Double
        if grid.tempoLevel == .doubled, !beat.number.isMultiple(of: 2),
            index > 0, index + 1 < grid.beats.count
        {
            // At double tempo every second beat is a new one, halfway between two fitted
            // beats. The refit knows it by that halfway place, as the beats stand now,
            // and by an eighth of the distance between its two neighbours.
            let before = grid.beats[index - 1].time
            let after = grid.beats[index + 1].time
            home = (before + after) / 2
            reach = (after - before) / 8
        } else {
            home = unanchored.beats.first { $0.number == beat.number }?.time ?? beat.time
            // The refit gives an anchor to the fitted beat it was dragged from within a
            // quarter of a beat period of, counted at the normal tempo level.
            reach = normalPeriod(around: beat.number, in: unanchored) / 4
        }
        var anchors = grid.anchors
        let own = anchors.last { abs($0.from - home) <= reach }
        anchors.removeAll { abs($0.from - home) <= reach }
        anchors.append(Anchor(from: own?.from ?? home, to: time))
        return anchors
    }

    /// The beat period at the normal tempo level around one beat of a grid: the distance
    /// to the nearer of its two neighbours, halved at half tempo and doubled at double tempo.
    private static func normalPeriod(around number: Int, in grid: Grid) -> Double {
        guard let index = grid.beats.firstIndex(where: { $0.number == number }) else { return 0 }
        var spacings: [Double] = []
        if index > 0, grid.beats[index - 1].number == number - 1 {
            spacings.append(grid.beats[index].time - grid.beats[index - 1].time)
        }
        if index + 1 < grid.beats.count, grid.beats[index + 1].number == number + 1 {
            spacings.append(grid.beats[index + 1].time - grid.beats[index].time)
        }
        let spacing = spacings.min() ?? 0
        switch grid.tempoLevel {
        case .halved: return spacing / 2
        case .normal: return spacing
        case .doubled: return spacing * 2
        }
    }
}

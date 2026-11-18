/// How far one step of the playhead goes: the Left and Right arrow keys step by sub-beats, with Command by
/// half beats, and with Shift and Command by beats.
///
///     let perBeat = PlayheadStep.subBeat.perBeat     // 4
///     let place = grid.stepPlace(.back, from: playhead, perBeat: perBeat, songLength: song.duration)
public enum PlayheadStep: Sendable, Equatable, CaseIterable {
    /// Sixteenths: four to a beat.
    case subBeat
    /// The beats and the middle between two beats.
    case halfBeat
    case beat

    /// How many equal parts a beat is cut into for this step. The song has no sub-beats of its own, each
    /// clip has, so a sub-beat step is always a sixteenth.
    public var perBeat: Int {
        switch self {
        case .beat: 1
        case .halfBeat: 2
        case .subBeat: SubBeatGrid.sixteenths.perBeat
        }
    }
}

/// Which way the playhead is stepped.
public enum StepDirection: Sendable, Equatable {
    case back
    case forward
}

extension Grid {
    /// How near a place the playhead must be to count as standing on it, in seconds. A playhead that was sent
    /// to a place is reported back by the player to the nearest sample, which can be a hair before or after
    /// it. Without this, a step from there could land on the very place the playhead stands on.
    public static let stepTolerance = 0.001

    /// Where one step takes the playhead: the nearest beat or part of a beat that lies before `seconds`, or
    /// after it. A playhead that stands between two such places goes to the closest one in that direction,
    /// and one that stands on a place goes to the next.
    ///
    /// The places are the same as `subBeats(perBeat:in:)` gives: each stretch between two neighbouring beats
    /// cut into `perBeat` equal parts, and no places inside a gap the grid left empty. A step back with no
    /// place before the playhead goes to the start of the song, and a step forward with none after it goes
    /// to the song's end.
    ///
    /// - Parameters:
    ///   - seconds: where the playhead stands, in song seconds.
    ///   - perBeat: 1 for beats, 2 for half beats, 4 or 6 for sub-beats (`PlayheadStep.perBeat`).
    ///   - songLength: the length of the song in seconds. The answer is never outside the song.
    public func stepPlace(
        _ direction: StepDirection,
        from seconds: Double,
        perBeat: Int,
        songLength: Double
    ) -> Double {
        let end = max(songLength, 0)
        guard perBeat >= 1, !beats.isEmpty else { return direction == .back ? 0 : end }
        let last = beats.count - 1
        let index = lastIndex(atOrBefore: seconds)
        var place: Double?
        switch direction {
        case .back:
            // From one beat further back than the playhead, so that a playhead standing on a beat finds the
            // last part of the beat before it.
            if let index {
                let from = beats[max(index - 1, 0)].time
                if from <= seconds {
                    place = subBeats(perBeat: perBeat, in: from...seconds).last { $0 < seconds - Self.stepTolerance }
                }
            }
        case .forward:
            // To two beats further on, so that a playhead standing a hair before a beat finds the first
            // part after that beat.
            let to = beats[min((index ?? -1) + 2, last)].time
            if seconds <= to {
                place = subBeats(perBeat: perBeat, in: seconds...to).first { $0 > seconds + Self.stepTolerance }
            }
        }
        return min(max(place ?? (direction == .back ? 0 : end), 0), end)
    }
}

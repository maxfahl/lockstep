/// Questions the rest of the app asks a grid: where the bars start, what the
/// tempo is at a position, where the sub-beats are, and what the beats look
/// like at half or double tempo. All of it is pure arithmetic on the beat list.
extension Grid {
    /// Lockstep counts four beats to the bar.
    public static let beatsPerBar = 4

    // MARK: - Bar starts

    /// Whether the beat with this number is beat 1 of a bar.
    public func isBarStart(_ number: Int) -> Bool {
        Self.barPhase(number - barStartNumber) == 0
    }

    /// Sets `barStartNumber` from the bar starts the model reported.
    ///
    /// Each reported time is moved to the nearest beat, and the place in the bar
    /// (beat number modulo 4) that most of them agree on wins. When Max has
    /// chosen a beat 1 (`beatOne`), that choice wins whatever the model says.
    public mutating func setBarStart(fromModelBarStarts times: [Double]) {
        if let chosen = chosenBeatOne() {
            barStartNumber = chosen.number
            return
        }
        var votes = [Int](repeating: 0, count: Self.beatsPerBar)
        for time in times {
            guard let index = index(nearest: time) else { continue }
            // A bar start that is not near any beat, for example one on a
            // dropped double-time beat, says nothing about the bars.
            if let spacing = spacingToNearestNeighbour(of: index),
                abs(beats[index].time - time) > spacing / 4
            {
                continue
            }
            votes[Self.barPhase(beats[index].number)] += 1
        }
        guard let most = votes.max(), most > 0, let phase = votes.firstIndex(of: most) else {
            barStartNumber = beats.first?.number ?? 0
            return
        }
        barStartNumber = beats.first { Self.barPhase($0.number) == phase }?.number ?? phase
    }

    /// Makes the beat with this number beat 1 of a bar, and remembers the
    /// choice by its song time so it survives a refit. Does nothing when the
    /// grid has no beat with that number.
    public mutating func setBeatOne(at beatNumber: Int) {
        guard let beat = beats.first(where: { $0.number == beatNumber }) else { return }
        beatOne = beat.time
        barStartNumber = beat.number
    }

    /// The last bar start at or before this song time, or nil when there is none.
    public func barStart(atOrBefore seconds: Double) -> Beat? {
        guard var index = lastIndex(atOrBefore: seconds) else { return nil }
        while index >= 0 {
            if isBarStart(beats[index].number) { return beats[index] }
            index -= 1
        }
        return nil
    }

    // MARK: - Lookups

    /// The beat closest to this song time, or nil when the grid has no beats.
    public func beat(nearest seconds: Double) -> Beat? {
        index(nearest: seconds).map { beats[$0] }
    }

    /// The tempo at this song time in beats per minute, to one decimal: 60
    /// divided by the mean of the two beat spacings around the nearest beat.
    ///
    /// Nil where the grid has no beats: before the first beat, after the last
    /// one, and inside a gap that was left empty.
    public func tempo(at seconds: Double) -> Double? {
        guard let before = lastIndex(atOrBefore: seconds), seconds <= beats[beats.count - 1].time else {
            return nil
        }
        var centre = before
        if seconds > beats[before].time {
            guard follows(before) else { return nil }
            if beats[before + 1].time - seconds < seconds - beats[before].time { centre = before + 1 }
        }
        var spacings: [Double] = []
        if centre > 0, follows(centre - 1) {
            spacings.append(beats[centre].time - beats[centre - 1].time)
        }
        if centre + 1 < beats.count, follows(centre) {
            spacings.append(beats[centre + 1].time - beats[centre].time)
        }
        let mean = spacings.reduce(0, +) / Double(max(spacings.count, 1))
        guard mean > 0 else { return nil }
        return (600 / mean).rounded() / 10
    }

    /// Every beat and sub-beat time inside `range`, ascending.
    ///
    /// Each stretch between two neighbouring beats is cut into `perBeat` equal
    /// parts (4 for sixteenths, 6 for triplets), and the beat itself is the
    /// first of them. There are no sub-beats where the grid has no beats: a
    /// beat with an empty gap after it, and the last beat, stand alone.
    public func subBeats(perBeat: Int, in range: ClosedRange<Double>) -> [Double] {
        guard perBeat >= 1 else { return [] }
        var result: [Double] = []
        var index = lastIndex(atOrBefore: range.lowerBound) ?? 0
        while index < beats.count, beats[index].time <= range.upperBound {
            let start = beats[index].time
            if index + 1 < beats.count, follows(index) {
                let step = (beats[index + 1].time - start) / Double(perBeat)
                for part in 0..<perBeat {
                    let time = start + step * Double(part)
                    if range.contains(time) { result.append(time) }
                }
            } else if range.contains(start) {
                result.append(start)
            }
            index += 1
        }
        return result
    }

    // MARK: - Half and double tempo

    /// The grid as it looks at the given tempo level.
    ///
    /// Call it on the beats as they were fitted, which are the normal level; the
    /// result is derived and is not meant to be fed back in.
    /// - Halved keeps every second beat, counted from a bar start so that bar
    ///   starts stay bar starts, and renumbers them.
    /// - Doubled puts a beat halfway between each two neighbouring beats, but
    ///   not across a gap that was left empty. A new beat is estimated only
    ///   when both its neighbours are.
    /// When Max has chosen a beat 1, the beat nearest to that time is kept and
    /// is a bar start in the result.
    public func applying(tempoLevel level: TempoLevel) -> Grid {
        var result = self
        result.tempoLevel = level
        let origin = chosenBeatOne()?.number ?? barStartNumber

        switch level {
        case .normal:
            result.barStartNumber = origin
        case .halved:
            // Halving the number, rounded down, keeps neighbours one apart and
            // keeps the skipped numbers of an empty gap.
            result.beats = beats.filter { ($0.number - origin) % 2 == 0 }.map {
                Beat(number: $0.number >> 1, time: $0.time, estimated: $0.estimated)
            }
            result.barStartNumber = origin >> 1
        case .doubled:
            var doubled: [Beat] = []
            doubled.reserveCapacity(beats.count * 2)
            for (index, beat) in beats.enumerated() {
                doubled.append(Beat(number: beat.number * 2, time: beat.time, estimated: beat.estimated))
                guard index + 1 < beats.count, follows(index) else { continue }
                let next = beats[index + 1]
                doubled.append(Beat(
                    number: beat.number * 2 + 1,
                    time: (beat.time + next.time) / 2,
                    estimated: beat.estimated && next.estimated
                ))
            }
            result.beats = doubled
            result.barStartNumber = origin * 2
        }
        // A chosen beat 1 can be one of the new halfway beats.
        if let chosen = result.chosenBeatOne() {
            result.barStartNumber = chosen.number
        }
        return result
    }

    // MARK: - Helpers

    /// Where a beat number sits in its bar, 0 to 3, also for negative numbers.
    static func barPhase(_ number: Int) -> Int {
        ((number % beatsPerBar) + beatsPerBar) % beatsPerBar
    }

    /// The beat nearest to the time Max chose as beat 1, if he chose one.
    func chosenBeatOne() -> Beat? {
        beatOne.flatMap { beat(nearest: $0) }
    }

    /// Whether the beat after `index` is the very next beat, with no empty gap between.
    func follows(_ index: Int) -> Bool {
        beats[index + 1].number == beats[index].number + 1
    }

    /// Index of the last beat at or before this time, or nil when there is none.
    func lastIndex(atOrBefore seconds: Double) -> Int? {
        var low = 0
        var high = beats.count
        while low < high {
            let middle = (low + high) / 2
            if beats[middle].time <= seconds { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? low - 1 : nil
    }

    func index(nearest seconds: Double) -> Int? {
        guard !beats.isEmpty else { return nil }
        guard let before = lastIndex(atOrBefore: seconds) else { return 0 }
        guard before + 1 < beats.count else { return before }
        return beats[before + 1].time - seconds < seconds - beats[before].time ? before + 1 : before
    }

    func spacingToNearestNeighbour(of index: Int) -> Double? {
        var spacings: [Double] = []
        if index > 0 { spacings.append(beats[index].time - beats[index - 1].time) }
        if index + 1 < beats.count { spacings.append(beats[index + 1].time - beats[index].time) }
        return spacings.min()
    }
}

import Foundation

/// The stretch of the song that repeats while Loop is on.
///
/// It is kept in whole samples, and its length is fixed when Loop is switched on: every pass is exactly that
/// many samples, so the click cannot slide against the song however long the loop runs, and every pass of a
/// loop recording is as long as the one before it.
///
///     // Loop was switched on with a stretch marked from 12.3 s to 15.9 s.
///     let region = LoopRegion.snapped(12.3...15.9, to: project.grid, keeping: project.keptSamples)
///     region?.start                                  // the bar start at or before 12.3 s
///     region?.end                                    // the bar start at or after 15.9 s
///     region?.songSample(afterPlaying: n, from: s)   // where the song is, n samples after it started at s
///     region?.shortened(to: project.keptSamples)     // after the song was cut: what is left of the region
///
/// A region lies inside what is left of the song (`Project.keptSamples`): where the song is cut away nothing
/// is played, so nothing can go round there.
///
/// The region is not part of the project: it is not saved and Undo does not bring it back.
public struct LoopRegion: Sendable, Equatable {
    /// A loop shorter than this, in seconds, cannot be switched on. The player hands every pass over ahead of
    /// time, which a loop of a few samples leaves no time for, and nobody rehearses a quarter of a second.
    public static let shortestSeconds: Double = 0.25

    /// The first sample of the song that repeats.
    public var startSample: Int
    /// How many samples one pass is.
    public var lengthSamples: Int

    /// One past the last sample that repeats.
    public var endSample: Int { startSample + lengthSamples }
    /// Where the loop starts, in song seconds.
    public var start: Double { Double(startSample) / Lockstep.sampleRate }
    /// Where the loop ends and the song jumps back, in song seconds.
    public var end: Double { Double(endSample) / Lockstep.sampleRate }
    /// How long one pass is, in seconds.
    public var seconds: Double { Double(lengthSamples) / Lockstep.sampleRate }
    /// The region in song seconds, as the ruler draws it.
    public var range: ClosedRange<Double> { start...end }

    /// Nil for a region that starts before the song or is shorter than `shortestSeconds`.
    public init?(startSample: Int, lengthSamples: Int) {
        guard startSample >= 0, Double(lengthSamples) >= Self.shortestSeconds * Lockstep.sampleRate else { return nil }
        self.startSample = startSample
        self.lengthSamples = lengthSamples
    }

    /// The region from one song time to another, on whole samples and kept inside the song. Nil when what is
    /// left is shorter than `shortestSeconds`.
    public init?(from start: Double, to end: Double, songLengthSamples: Int) {
        self.init(from: start, to: end, keeping: 0..<max(songLengthSamples, 0))
    }

    /// The region from one song time to another, on whole samples and kept inside `kept`, the samples of the
    /// song that are left after cutting. Nil when what is left of it is shorter than `shortestSeconds`.
    public init?(from start: Double, to end: Double, keeping kept: Range<Int>) {
        guard start.isFinite, end.isFinite, !kept.isEmpty else { return nil }
        func sample(_ seconds: Double) -> Int {
            min(max(Int((seconds * Lockstep.sampleRate).rounded()), kept.lowerBound), kept.upperBound)
        }
        let first = sample(start)
        self.init(startSample: first, lengthSamples: sample(end) - first)
    }

    /// What is left of the region when only `kept` is left of the song: the region shortened to it, the same
    /// region when it lies inside already, and nil when less than `shortestSeconds` of it is left.
    public func shortened(to kept: Range<Int>) -> LoopRegion? {
        let start = max(startSample, kept.lowerBound)
        return LoopRegion(startSample: start, lengthSamples: min(endSample, kept.upperBound) - start)
    }

    // MARK: Snapping to whole bars

    /// The loop region for a marked stretch: its start moved down and its end moved up to the nearest bar
    /// starts, so the loop is a whole number of bars and comes round on the beat.
    ///
    /// An edge is moved only where the song has beats around it. Where it has none (no beats were found,
    /// before the first beat, after the last one, or in a stretch that was left empty) that edge is used as
    /// it is. An edge that already stands on a bar start stays there.
    ///
    /// - Returns: nil when the region would be shorter than `shortestSeconds`.
    public static func snapped(
        _ stretch: ClosedRange<Double>,
        to grid: Grid?,
        songLengthSamples: Int
    ) -> LoopRegion? {
        snapped(stretch, to: grid, keeping: 0..<max(songLengthSamples, 0))
    }

    /// The same for a song that may be cut: `kept` is what is left of it (`Project.keptSamples`). A bar start
    /// in a part that is cut away is not one the loop can start or end on, so an edge whose bar start lies
    /// there is used as it is, like an edge with no beats around it, and the region never reaches outside
    /// what is left.
    public static func snapped(
        _ stretch: ClosedRange<Double>,
        to grid: Grid?,
        keeping kept: Range<Int>
    ) -> LoopRegion? {
        func isKept(_ seconds: Double) -> Bool {
            let sample = Int((seconds * Lockstep.sampleRate).rounded())
            return sample >= kept.lowerBound && sample <= kept.upperBound
        }
        let start = grid?.barStartTime(atOrBefore: stretch.lowerBound).flatMap { isKept($0) ? $0 : nil }
        let end = grid?.barStartTime(atOrAfter: stretch.upperBound).flatMap { isKept($0) ? $0 : nil }
        return LoopRegion(from: start ?? stretch.lowerBound, to: end ?? stretch.upperBound, keeping: kept)
    }

    // MARK: Where the song is

    /// Whether playback that starts at this sample of the song will loop: it starts before the end of the
    /// region, so it plays into the region, or on inside it, and comes round. Playback that starts after the
    /// region plays on to the end of the song.
    public func isReached(from startSample: Int) -> Bool {
        startSample < endSample
    }

    /// The sample of the song that is heard `elapsed` samples after playback started at `startSample`.
    ///
    /// Until the end of the region is reached for the first time, the song simply moves on. From then on it
    /// goes round: the sample after the last one of the region is the region's first. Playback that started
    /// after the region never loops.
    public func songSample(afterPlaying elapsed: Int, from startSample: Int) -> Int {
        let straight = startSample + elapsed
        guard isReached(from: startSample), straight >= endSample else { return straight }
        return self.startSample + (straight - self.startSample) % lengthSamples
    }

    /// The same for a time in seconds that need not fall on a whole sample: where the song is when it would
    /// be at `straight` seconds had it not looped. Only for playback that reaches the region
    /// (`isReached(from:)`).
    public func songSeconds(forStraight straight: Double) -> Double {
        guard straight >= end else { return straight }
        return start + (straight - start).truncatingRemainder(dividingBy: seconds)
    }
}

// MARK: - Bar starts

extension Grid {
    /// The time of the bar start at or before a song time, or nil where the song has no beats around that
    /// time, or the bar's first beat is missing: then there is no bar start to speak of.
    public func barStartTime(atOrBefore seconds: Double) -> Double? {
        guard var index = lastIndex(atOrBefore: seconds), isAmongBeats(seconds, after: index) else { return nil }
        while !isBarStart(beats[index].number) {
            // The beat before must be the very one before, with no empty stretch between.
            guard index > 0, follows(index - 1) else { return nil }
            index -= 1
        }
        return beats[index].time
    }

    /// The time of the bar start at or after a song time, or nil where the song has no beats around that
    /// time, or the next bar's first beat is missing.
    public func barStartTime(atOrAfter seconds: Double) -> Double? {
        guard let before = lastIndex(atOrBefore: seconds), isAmongBeats(seconds, after: before) else { return nil }
        var index = beats[before].time == seconds ? before : before + 1
        while !isBarStart(beats[index].number) {
            guard index + 1 < beats.count, follows(index) else { return nil }
            index += 1
        }
        return beats[index].time
    }

    /// Whether a song time has beats around it: it stands on the beat at `index`, or between that beat and
    /// the very next one.
    private func isAmongBeats(_ seconds: Double, after index: Int) -> Bool {
        beats[index].time == seconds || (index + 1 < beats.count && follows(index))
    }

    /// Every bar start inside a stretch of the song, in song seconds.
    public func barStartTimes(in range: ClosedRange<Double>) -> [Double] {
        // The first beat that is not before the stretch.
        var index = lastIndex(atOrBefore: range.lowerBound).map { beats[$0].time < range.lowerBound ? $0 + 1 : $0 } ?? 0
        var times: [Double] = []
        while index < beats.count, beats[index].time <= range.upperBound {
            if isBarStart(beats[index].number) { times.append(beats[index].time) }
            index += 1
        }
        return times
    }
}

// MARK: - Snapping the marked stretch

extension SnapKind {
    /// The first beat of a bar. An edge of the marked stretch catches on it.
    public static let barStart = SnapKind(name: "barStart", rank: 300)
}

/// The bar starts of the song, as snap points: what the edges of the marked stretch catch on, so a stretch
/// that is marked to be looped is whole bars already while it is dragged.
///
///     let engine = SnapEngine(sources: [BarStartSource(grid: grid)])
///     // Each edge of the stretch is held against the bar starts on its own:
///     let moved = engine.snap(start: edge, end: edge, tolerance: tolerance).map { edge + $0.delta } ?? edge
public struct BarStartSource: SnapSource {
    public var grid: Grid

    public init(grid: Grid) {
        self.grid = grid
    }

    public func points(in range: ClosedRange<Double>, excluding moving: Set<Clip.ID>) -> [SnapPoint] {
        grid.barStartTimes(in: range).map { SnapPoint(time: $0, kind: .barStart) }
    }
}

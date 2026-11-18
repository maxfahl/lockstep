import Foundation

/// The loop's in and out, set with Set Loop In (I) and Set Loop Out (O), as in DaVinci
/// Resolve. They stay until Clear Loop In and Out (Option+X) takes them away: selecting
/// clips, marking or deleting a stretch, Escape and Delete leave them alone. Loop plays
/// the stretch between them, and while it is off the ruler still shows it, quieter.
///
/// Either end may be missing: an in without an out reaches to the end of what is left of
/// the song, an out without an in from its start. Song seconds. They are not part of the
/// project and no undo step; `ProjectView` keeps them with the rest of the view.
///
///     let marks = LoopInOut().setting(.in, at: 12.5, in: kept)   // an in, no out yet
public struct LoopInOut: Sendable, Equatable {
    public var inTime: Double?
    public var outTime: Double?

    public init(inTime: Double? = nil, outTime: Double? = nil) {
        self.inTime = inTime
        self.outTime = outTime
    }

    /// The stretch they mark, with a missing end taken from `song`, the part of the song
    /// that is kept. Nil when neither is set or the stretch is empty.
    public func range(in song: ClosedRange<Double>) -> ClosedRange<Double>? {
        guard inTime != nil || outTime != nil else { return nil }
        let start = inTime ?? song.lowerBound
        let end = outTime ?? song.upperBound
        return end > start ? start...end : nil
    }

    /// Which end Set Loop In or Set Loop Out puts at the playhead.
    public enum End: Sendable {
        case `in`, out
    }

    /// The in and out with one end put at `place`, exactly, held inside `song`. The other
    /// end stays, unless the new one reaches or passes it: then it is let go, and the
    /// stretch reaches to the start or end of the song instead. Nil when nothing would be
    /// left between them, so the press changes nothing.
    public func setting(_ end: End, at place: Double, in song: ClosedRange<Double>) -> LoopInOut? {
        guard place.isFinite else { return nil }
        let place = min(max(place, song.lowerBound), song.upperBound)
        var next = self
        switch end {
        case .in:
            next.inTime = place
            if let out = outTime, out <= place { next.outTime = nil }
        case .out:
            next.outTime = place
            if let start = inTime, start >= place { next.inTime = nil }
        }
        return next.range(in: song) == nil ? nil : next
    }

    /// What is left of them after the song was cut to `song`: an end that now lies where
    /// the song is cut away goes to the edge of what is left, and nil when nothing of the
    /// stretch is left.
    public func kept(inside song: ClosedRange<Double>) -> LoopInOut? {
        let start = inTime.map { max($0, song.lowerBound) }
        let end = outTime.map { min($0, song.upperBound) }
        let next = LoopInOut(inTime: start, outTime: end)
        return next.range(in: song) == nil ? nil : next
    }
}

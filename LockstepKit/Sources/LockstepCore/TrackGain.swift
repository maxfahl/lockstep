import Foundation

// A track's own volume. Max balances his vocal tracks against each other and against the beat with it. The
// number is kept on the track (`Track.gainDb`), and `Project.clipPlaybackPlan` adds it to every piece of the
// track's clips, on top of each clip's own volume. Only the player hears it: an export of a clip leaves it
// out (`ClipExporter`).

extension Track {
    /// The lowest and highest volume a track can have, in dB. It goes above 0 so that a quiet vocal track
    /// can be lifted, and as far down as the song's own volume goes.
    public static let gainRange: ClosedRange<Double> = -24...12

    /// A volume for a track brought into `gainRange`. Something that is no number becomes 0.
    public static func gain(clamped gainDb: Double) -> Double {
        guard gainDb.isFinite else { return 0 }
        return min(max(gainDb, gainRange.lowerBound), gainRange.upperBound)
    }
}

extension Project {
    /// Gives a track a volume, brought into `Track.gainRange`.
    ///
    /// - Returns: false when the track already has that volume, or the project has no such track.
    @discardableResult
    public mutating func setTrack(_ id: Track.ID, gainDb: Double) -> Bool {
        let gain = Track.gain(clamped: gainDb)
        guard let index = tracks.firstIndex(where: { $0.id == id }), tracks[index].gainDb != gain else { return false }
        tracks[index].gainDb = gain
        return true
    }
}

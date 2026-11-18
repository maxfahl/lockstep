import Foundation

// Normalize: bringing clips to the same loudness. Phase 16.
//
// A clip's loudness is measured the way the ear hears it (`Loudness`), and Normalize writes down how far that
// is from the target: `normalizeGainDb = target - loudness`. Nothing else about the clip changes. The volume
// Max set for it (`gainDb`) stays and is added on top, and the recording is never touched.
//
// The work is in two steps, so the measuring can be done away from the main thread:
//
//     let clips = project.clipsToNormalize(selected)                    // the clips, with every take of each
//     let loudness = Project.loudness(of: clips) { sounds[$0] }         // slow for long clips: any thread
//     project.normalize(clips: selected, target: -18, loudness: loudness)
//
// Or in one go, where the time does not matter:
//
//     project.normalize(clips: selected, target: -18) { sounds[$0] }
extension Project {
    /// The clips Normalize acts on when these are chosen: the clips themselves and every other take of their
    /// lines, also the takes that wait and are not drawn. A take that is chosen later is then as loud as the
    /// one it replaces. In the order of the tracks, and of the clips on each track.
    public func clipsToNormalize(_ ids: Set<Clip.ID>) -> [Clip] {
        var wanted = ids
        for id in ids {
            wanted.formUnion(takes(of: id).map(\.id))
        }
        return tracks.flatMap { track in track.clips.filter { wanted.contains($0.id) } }
    }

    /// How loud each of these clips sounds, in LUFS, by the clip's id. A clip that is silent, or whose
    /// recording has no sound, is left out.
    ///
    /// It only reads what it is given, so it can run on any thread.
    ///
    /// - Parameter recording: the samples of a recording, mono at 48,000 Hz, or nil when there are none.
    public static func loudness(of clips: [Clip], recording: (UUID) -> [Float]?) -> [Clip.ID: Double] {
        var measured: [Clip.ID: Double] = [:]
        for clip in clips {
            measured[clip.id] = Loudness.integrated(of: clip, recording: recording)
        }
        return measured
    }

    /// Normalize: brings these clips, and every other take of their lines, to the target loudness, by setting
    /// each one's `normalizeGainDb` to the target minus its own loudness.
    ///
    /// A clip without a loudness in `loudness` is left as it is: a silent clip has none. The volume Max set for
    /// a clip (`gainDb`) is never changed.
    ///
    /// - Parameters:
    ///   - target: the loudness to bring the clips to, in LUFS.
    ///   - loudness: how loud each clip sounds, from `Project.loudness(of:recording:)`.
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func normalize(clips ids: Set<Clip.ID>, target: Double, loudness: [Clip.ID: Double]) -> Bool {
        let wanted = Set(clipsToNormalize(ids).map(\.id))
        var changed = false
        for track in tracks.indices {
            for clip in tracks[track].clips.indices {
                let id = tracks[track].clips[clip].id
                guard wanted.contains(id), let measured = loudness[id], measured.isFinite else { continue }
                let gain = target - measured
                if tracks[track].clips[clip].normalizeGainDb != gain {
                    tracks[track].clips[clip].normalizeGainDb = gain
                    changed = true
                }
            }
        }
        return changed
    }

    /// Normalize in one go: measures the clips and brings them to the target loudness.
    ///
    /// - Parameter recording: the samples of a recording, mono at 48,000 Hz, or nil when there are none.
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func normalize(clips ids: Set<Clip.ID>, target: Double, recording: (UUID) -> [Float]?) -> Bool {
        let loudness = Project.loudness(of: clipsToNormalize(ids), recording: recording)
        return normalize(clips: ids, target: target, loudness: loudness)
    }

    /// Sets the volume Max chose for these clips, in dB, kept within -12...+12 (`Clip.gainRange`). What
    /// Normalize set stays, and the volume is added on top of it.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func setClips(_ ids: Set<Clip.ID>, gainDb: Double) -> Bool {
        let gain = min(max(gainDb, Clip.gainRange.lowerBound), Clip.gainRange.upperBound)
        var changed = false
        for track in tracks.indices {
            for clip in tracks[track].clips.indices
            where ids.contains(tracks[track].clips[clip].id) && tracks[track].clips[clip].gainDb != gain {
                tracks[track].clips[clip].gainDb = gain
                changed = true
            }
        }
        return changed
    }

    /// Normalize Track: the same for every clip on one track.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func normalizeTrack(_ trackID: Track.ID, target: Double, recording: (UUID) -> [Float]?) -> Bool {
        guard let track = track(trackID) else { return false }
        return normalize(clips: Set(track.clips.map(\.id)), target: target, recording: recording)
    }
}

extension Clip {
    /// The lowest and the highest volume Max can give a clip, in dB.
    public static let gainRange: ClosedRange<Double> = -12...12
}

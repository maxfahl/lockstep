import Foundation

/// One end of a clip: where it starts in the song, or where it ends.
public enum ClipEdge: Sendable, Hashable {
    case start
    case end
}

/// Trimming: an edge of a clip is dragged, and the clip gets shorter from that side, or longer again.
///
/// The rules, as Max asked for them on 13 November 2026:
///
/// - Only the edge moves. No sound moves in the song: a trim changes which samples of the recording the
///   clip's outermost segment plays (`inSample` at the start, `outSample` at the end), never `offsetSamples`.
/// - Inwards the edge stops when 50 ms of the segment it belongs to are left. In a clip joined from several
///   pieces that is the first piece for the start and the last piece for the end, so an edge never passes a
///   join, and the other pieces are not touched.
/// - Outwards the edge stops where the recording has no more sound, and at the start and the end of what is
///   left of the song (`keptSamples`): where the song is cut away nothing is played, so a clip is not made
///   longer into it.
/// - Only the clip that is asked for is trimmed, and only a clip that is shown. The takes that wait behind it
///   keep all of their sound, and stay its takes however short it is made: a clip keeps its line.
/// - An edge dragged outwards does not stop at a neighbour. The clip that is dragged wins: what it comes to
///   cover of other lines on its track gives way, shown clips and waiting takes alike
///   (`ProjectGivingWay.swift`). So a clip that was shortened by a newer one can be dragged out again, and
///   then the newer one is shortened in turn.
/// - The recording is never changed, and the clip stays as loud as it was: like a split, a clip the safe limit
///   holds back first gets that lowering as its own (see the top of `ProjectClipEdits.swift`).
///
/// The words of a trimmed clip are for other sound than it now plays. The app takes them away and has them
/// written out again, as after a split (`clearWordsOfCutClips(since:)`).
///
///     // While the edge is dragged. `sample` is where the pointer has taken it, in samples of the song.
///     let allowed = project.trimRange(of: id, edge: .start)       // nil: this clip cannot be trimmed
///     // When it is let go.
///     var changed = store.project
///     guard changed.trimClip(id, edge: .start, toSongSample: sample, peaks: peaks) != nil else { return }
///     store.edit("Trim Clip") { $0 = changed }
extension Project {
    /// The least a trim leaves of the segment whose edge it moves: 50 ms, in samples.
    public static let trimMinimumSamples = 2_400

    /// The sample of the song an edge of a clip is on. Nil for a clip the project does not have, one with no
    /// segments, or one whose recording the project does not have.
    public func edgeSample(of id: Clip.ID, edge: ClipEdge) -> Int? {
        trimPlace(of: id, edge: edge)?.sample
    }

    /// The samples of the song an edge of this clip can be dragged to. The place it is on now is always one
    /// of them.
    ///
    /// Nil when the clip cannot be trimmed: the project has no such clip, it is a take that waits behind
    /// another, or it has no place in the song.
    public func trimRange(of id: Clip.ID, edge: ClipEdge) -> ClosedRange<Int>? {
        trimPlace(of: id, edge: edge)?.allowed
    }

    /// Moves an edge of a clip to a sample of the song, or as near it as the limits of `trimRange` let it.
    ///
    /// When the edge went outwards, every other line the clip now covers part of gives way to it.
    ///
    /// - Parameters:
    ///   - peaks: the highest sample of a stretch of a recording, so a clip the safe limit holds back
    ///     stays as loud as it was, this one and any that gives way.
    ///   - voices: which voice stands in for which recording on which track, so the safe limit is asked
    ///     about the sound each clip is heard from on its track (see the top of `ProjectClipEdits.swift`).
    /// - Returns: the sample of the song the edge is on afterwards. Nil, with nothing changed, when the clip
    ///   cannot be trimmed or the edge is already there.
    @discardableResult
    public mutating func trimClip(
        _ id: Clip.ID,
        edge: ClipEdge,
        toSongSample sample: Int,
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices
    ) -> Int? {
        guard let place = trimPlace(of: id, edge: edge) else { return nil }
        let target = min(max(sample, place.allowed.lowerBound), place.allowed.upperBound)
        guard target != place.sample else { return nil }
        // What is left must sound as it did, so a clip that is held back is trimmed with the lowering as its own.
        var clip = Project.holdingItselfBack(
            tracks[place.track].clips[place.clip], peaks, voices: voices, on: tracks[place.track]
        )
        switch edge {
        case .start:
            clip.segments[place.segment].inSample = target - place.origin
            // It no longer starts where it was recorded, so a recording from that place is not a take of it.
            clip.recordPlace = nil
        case .end:
            clip.segments[place.segment].outSample = target - place.origin
        }
        tracks[place.track].clips[place.clip] = clip
        let wentOutwards = edge == .start ? target < place.sample : target > place.sample
        if wentOutwards {
            giveWay(to: id, peaks: peaks, voices: voices)
        }
        return target
    }

    /// Where an edge of a clip is and how far it can go.
    private struct TrimPlace {
        /// The places of the clip's track, of the clip in it, and of the segment whose edge it is.
        var track: Int
        var clip: Int
        var segment: Int
        /// The sample of the song on which sample 0 of the recording would be heard through that segment.
        var origin: Int
        /// The sample of the song the edge is on now.
        var sample: Int
        /// The samples of the song the edge can be dragged to.
        var allowed: ClosedRange<Int>
    }

    private func trimPlace(of id: Clip.ID, edge: ClipEdge) -> TrimPlace? {
        for (trackIndex, track) in tracks.enumerated() {
            guard let clipIndex = track.clips.firstIndex(where: { $0.id == id }) else { continue }
            let clip = track.clips[clipIndex]
            guard clip.isActiveTake, !clip.segments.isEmpty else { return nil }
            let segmentIndex = edge == .start ? 0 : clip.segments.count - 1
            let segment = clip.segments[segmentIndex]
            guard let recording = recording(segment.recordingID) else { return nil }
            let origin = recording.songSample(ofSample: 0, offsetSamples: segment.offsetSamples)
            let kept = keptSamples
            let sample: Int
            let allowed: ClosedRange<Int>
            switch edge {
            case .start:
                sample = origin + segment.inSample
                // Out to the first sample of the recording, but not before what is left of the song. In until
                // 50 ms are left. An edge that already lies beyond a limit may stay where it is.
                let furthestOut = min(sample, max(origin, kept.lowerBound))
                let furthestIn = max(sample, origin + segment.outSample - Project.trimMinimumSamples)
                allowed = furthestOut...furthestIn
            case .end:
                sample = origin + segment.outSample
                let furthestOut = max(sample, min(origin + recording.lengthSamples, kept.upperBound))
                let furthestIn = min(sample, origin + segment.inSample + Project.trimMinimumSamples)
                allowed = furthestIn...furthestOut
            }
            return TrimPlace(
                track: trackIndex,
                clip: clipIndex,
                segment: segmentIndex,
                origin: origin,
                sample: sample,
                allowed: allowed
            )
        }
        return nil
    }
}

import Foundation

/// The four jumps of the playhead between clips: A and D go to the start of the clip before and after it on
/// the selected track, W and S to the nearest clip on the track above and below.
///
///     if let landing = project.clipJump(.next, from: playhead, selectedTrack: trackID) {
///         // landing.trackID becomes the selected track, and landing.clip, when there is one, the selected
///         // clip, with the playhead at landing.clip.place
///     }
public enum ClipJump: Sendable, Equatable, CaseIterable {
    /// The latest clip start before the playhead, on the selected track.
    case previous
    /// The earliest clip start after the playhead, on the selected track.
    case next
    /// The nearest clip on the track above the selected one.
    case above
    /// The nearest clip on the track below the selected one.
    case below
}

/// Where a jump between clips ends.
public struct ClipJumpLanding: Sendable, Equatable {
    /// The clip a jump lands on, and where the playhead goes.
    public struct LandedClip: Sendable, Equatable {
        public var id: Clip.ID
        /// The start of the clip in song seconds. For a clip that starts in the part of the song that is cut
        /// away at the beginning, it is where the kept part begins.
        public var place: Double
    }

    /// The track that becomes the selected one. For `previous` and `next` it is the track that was selected.
    public var trackID: Track.ID
    /// The clip landed on. Nil when a jump up or down reaches a track without clips: the track is still
    /// selected, and the playhead stays.
    public var clip: LandedClip?
}

extension Project {
    /// Where a jump between clips takes the playhead, or nil when there is nothing in that direction: no clip
    /// before or after the playhead, no track above the top one or below the bottom one.
    ///
    /// Only clips that are shown count: of several takes of a line the active one, and no clip that lies
    /// wholly in a part of the song that is cut away.
    ///
    /// - `previous`: the latest clip start before the playhead. Inside a clip that is the start of that clip,
    ///   and on a clip's start it is the start of the clip before.
    /// - `next`: the earliest clip start after the playhead.
    /// - `above` and `below`: on the neighbouring track, the clip the playhead stands inside, or else the
    ///   clip whose start is nearest to the playhead.
    ///
    /// - Parameters:
    ///   - seconds: where the playhead is, in song seconds.
    ///   - selectedTrack: the selected track.
    ///   - reach: how far past a clip's start the playhead may be and still count as standing on it, for
    ///     `previous`. While the song plays the playhead leaves the start at once, so the app gives a longer
    ///     reach then, and a second press goes on to the clip before.
    public func clipJump(
        _ jump: ClipJump,
        from seconds: Double,
        selectedTrack: Track.ID,
        reach: Double = Grid.stepTolerance
    ) -> ClipJumpLanding? {
        guard let index = tracks.firstIndex(where: { $0.id == selectedTrack }) else { return nil }
        switch jump {
        case .previous:
            let before = jumpTargets(on: tracks[index]).last { $0.place <= seconds - max(reach, Grid.stepTolerance) }
            return before.map { ClipJumpLanding(trackID: selectedTrack, clip: .init(id: $0.id, place: $0.place)) }
        case .next:
            let after = jumpTargets(on: tracks[index]).first { $0.place >= seconds + Grid.stepTolerance }
            return after.map { ClipJumpLanding(trackID: selectedTrack, clip: .init(id: $0.id, place: $0.place)) }
        case .above, .below:
            let neighbour = jump == .above ? index - 1 : index + 1
            guard tracks.indices.contains(neighbour) else { return nil }
            let targets = jumpTargets(on: tracks[neighbour])
            // Where clips lie on top of each other, the one that starts last is the one drawn in front.
            let nearest = targets.last { $0.place <= seconds && seconds < $0.end }
                ?? targets.min { abs($0.place - seconds) < abs($1.place - seconds) }
            return ClipJumpLanding(
                trackID: tracks[neighbour].id,
                clip: nearest.map { .init(id: $0.id, place: $0.place) }
            )
        }
    }

    /// The clips of a track a jump can land on, in the order they start in the song.
    private func jumpTargets(on track: Track) -> [(id: Clip.ID, place: Double, end: Double)] {
        let kept = keptSeconds
        var targets: [(id: Clip.ID, place: Double, end: Double)] = []
        for clip in track.clips where clip.isActiveTake {
            guard let start = start(of: clip), let end = end(of: clip) else { continue }
            // A clip that lies wholly in a cut-away part of the song is not drawn.
            guard end > kept.lowerBound, start < kept.upperBound else { continue }
            targets.append((clip.id, max(start, kept.lowerBound), end))
        }
        // The sort keeps the track's own order for clips that start at the same place.
        return targets.enumerated()
            .sorted { ($0.element.place, $0.offset) < ($1.element.place, $1.offset) }
            .map(\.element)
    }
}

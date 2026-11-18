import Foundation

/// Selecting clips on several tracks with one drag.
///
/// A drag across a track's row, from anywhere but a clip's bar, marks a stretch of that track for as long
/// as the pointer stays in the row. In another track's row it is a rectangle: it reaches from the row the
/// drag started in to the row the pointer is in, and from where the drag started in the song to where the
/// pointer is, and every clip it touches on those tracks is selected. `SelectionDrag` says which of the
/// two a drag is at a given moment. The two functions before it are what it is made of.
extension Project {
    /// The ids of the clips that are drawn on these tracks and have some part inside a stretch of the song.
    ///
    /// A clip that only meets the stretch at an edge is not touched. Of several takes of a line only the one
    /// that is shown counts (`isActiveTake`): a take that waits behind it is not drawn, so a rectangle drawn
    /// over it cannot mean it. A clip with no place in the song, and a track the project does not have,
    /// give nothing.
    public func shownClips(onTracks trackIDs: [UUID], touching range: ClosedRange<Double>) -> Set<UUID> {
        ProjectLookup(self).shownClips(onTracks: trackIDs, touching: range)
    }

    /// The ids of the tracks from one track to the track a number of rows below it, both included, in the
    /// order the project holds them. A negative number is rows above.
    ///
    /// The rows stop at the first and at the last track: a number that points past either gives the tracks
    /// up to it. Empty when the project has no such track.
    public func tracks(from trackID: UUID, rowsDown: Int) -> [UUID] {
        guard let from = tracks.firstIndex(where: { $0.id == trackID }) else { return [] }
        // The number can be as far out as the pointer is, so it is held inside the tracks before it is added.
        let to = from + min(max(rowsDown, -from), tracks.count - 1 - from)
        return tracks[min(from, to)...max(from, to)].map(\.id)
    }
}

extension ProjectLookup {
    /// As `Project.shownClips(onTracks:touching:)`, without a search of the recordings for every clip. A
    /// drag asks on every move of the pointer, so it makes the table once and asks it each time.
    public func shownClips(onTracks trackIDs: [UUID], touching range: ClosedRange<Double>) -> Set<UUID> {
        let wanted = Set(trackIDs)
        var touched = Set<UUID>()
        for track in project.tracks where wanted.contains(track.id) {
            for clip in track.clips where clip.isActiveTake {
                guard let start = start(of: clip), let end = end(of: clip),
                      start < range.upperBound, end > range.lowerBound
                else { continue }
                touched.insert(clip.id)
            }
        }
        return touched
    }
}

/// What a drag across the track rows is at one moment: a stretch of the track it started on, or a
/// rectangle over several tracks that selects clips.
///
/// It is asked again on every move of the pointer, with the same selection from before the drag each time,
/// so a rectangle that is made smaller lets go of the clips it no longer touches, and a pointer that comes
/// back into the first row turns the rectangle back into a stretch.
public enum SelectionDrag: Sendable, Equatable {
    /// The pointer is in the row the drag started in, or in no track's row at all (above the first track
    /// or below the last one, when the drag started on that track): a stretch of this track is marked.
    /// Where the stretch starts and ends is for the one who asks, who may snap its ends.
    case stretch(trackID: UUID)
    /// The pointer is in another track's row.
    case rectangle(Rectangle)

    /// A rectangle over the rows of some tracks, and what it selects.
    public struct Rectangle: Sendable, Equatable {
        /// The tracks whose rows it covers, in the order the project holds them: from the top row to the
        /// bottom one, whichever of them the drag started in.
        public var trackIDs: [UUID]
        /// From where to where it reaches in the song, in song seconds. Nothing is snapped: it selects
        /// clips, not time.
        public var range: ClosedRange<Double>
        /// The clips that are selected while the drag is like this: the shown clips it touches, and with
        /// Shift also the clips that were selected before the drag.
        public var clipIDs: Set<UUID>

        public init(trackIDs: [UUID], range: ClosedRange<Double>, clipIDs: Set<UUID>) {
            self.trackIDs = trackIDs
            self.range = range
            self.clipIDs = clipIDs
        }
    }

    /// - Parameters:
    ///   - project: The project as it is now.
    ///   - trackID: The track whose row the drag started in.
    ///   - startSeconds: The moment in the song under the pointer when the drag started.
    ///   - pointerSeconds: The moment in the song under the pointer now. Before or after the start.
    ///   - rowsDown: How many whole rows below the row it started in the pointer is now. Negative is
    ///     above. It may point past the first or the last track.
    ///   - selectedBefore: The clips that were selected when the drag started.
    ///   - addsToSelection: Shift was held when the drag started: what the rectangle touches is added to
    ///     `selectedBefore`. Without it, it takes its place.
    public init(
        in project: Project,
        trackID: UUID,
        startSeconds: Double,
        pointerSeconds: Double,
        rowsDown: Int,
        selectedBefore: Set<UUID>,
        addsToSelection: Bool
    ) {
        self.init(
            in: ProjectLookup(project),
            trackID: trackID,
            startSeconds: startSeconds,
            pointerSeconds: pointerSeconds,
            rowsDown: rowsDown,
            selectedBefore: selectedBefore,
            addsToSelection: addsToSelection
        )
    }

    /// The same, asked of the lookup table of the project. A drag is asked about on every move of the
    /// pointer: it makes one table when it starts and asks with it each time, so no move searches the
    /// project's lists.
    public init(
        in lookup: ProjectLookup,
        trackID: UUID,
        startSeconds: Double,
        pointerSeconds: Double,
        rowsDown: Int,
        selectedBefore: Set<UUID>,
        addsToSelection: Bool
    ) {
        let trackIDs = lookup.project.tracks(from: trackID, rowsDown: rowsDown)
        guard trackIDs.count > 1 else {
            self = .stretch(trackID: trackID)
            return
        }
        let range = min(startSeconds, pointerSeconds)...max(startSeconds, pointerSeconds)
        let touched = lookup.shownClips(onTracks: trackIDs, touching: range)
        self = .rectangle(Rectangle(
            trackIDs: trackIDs,
            range: range,
            clipIDs: addsToSelection ? selectedBefore.union(touched) : touched
        ))
    }
}

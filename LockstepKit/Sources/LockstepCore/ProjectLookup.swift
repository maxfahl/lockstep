import Foundation

/// A lookup table of one project, for whoever asks about many of its clips at once.
///
/// `Project.recording(_:)`, `clip(_:)` and `track(_:)` search their lists from the start each time. That is
/// right for one question. Asked once for every clip of a project with several hundred recordings, it is
/// what made an edit slow in a big project (15 November 2026). So such a caller makes one of these and asks
/// it instead:
///
///     let lookup = ProjectLookup(project)
///     for clip in track.clips {
///         lookup.start(of: clip)          // as project.start(of: clip), without the search
///     }
///     lookup.clip(id)                     // as project.clip(id)
///     lookup.takes(of: id)                // as project.takes(of: id)
///
/// Every answer is exactly the answer the project gives. The table is made from the project in one pass
/// and belongs to that value of it: after an edit, make a new one. It is never kept in the project, which
/// is saved and compared.
public struct ProjectLookup: Sendable {
    /// The project the table was made from.
    public let project: Project

    /// Where a clip is: its track's place among the tracks and its own place in the track's list.
    private struct ClipPlace: Sendable {
        var track: Int
        var clip: Int
    }

    /// The first recording with each id, as a place in `project.recordings`. That place is also the order
    /// takes are counted in.
    private let recordingPlaces: [UUID: Int]
    private let trackPlaces: [UUID: Int]
    /// The first clip with each id, in the order of the tracks.
    private let clipPlaces: [UUID: ClipPlace]

    public init(_ project: Project) {
        self.project = project
        var recordingPlaces: [UUID: Int] = [:]
        recordingPlaces.reserveCapacity(project.recordings.count)
        for index in project.recordings.indices {
            let id = project.recordings[index].id
            if recordingPlaces[id] == nil { recordingPlaces[id] = index }
        }
        var trackPlaces: [UUID: Int] = [:]
        var clipPlaces: [UUID: ClipPlace] = [:]
        for trackIndex in project.tracks.indices {
            let id = project.tracks[trackIndex].id
            if trackPlaces[id] == nil { trackPlaces[id] = trackIndex }
            let clips = project.tracks[trackIndex].clips
            for clipIndex in clips.indices where clipPlaces[clips[clipIndex].id] == nil {
                clipPlaces[clips[clipIndex].id] = ClipPlace(track: trackIndex, clip: clipIndex)
            }
        }
        self.recordingPlaces = recordingPlaces
        self.trackPlaces = trackPlaces
        self.clipPlaces = clipPlaces
    }

    // MARK: Finding things

    /// As `Project.recording(_:)`.
    public func recording(_ id: UUID) -> Recording? {
        recordingPlaces[id].map { project.recordings[$0] }
    }

    /// As `Project.track(_:)`.
    public func track(_ id: UUID) -> Track? {
        trackPlaces[id].map { project.tracks[$0] }
    }

    /// As `Project.clip(_:)`.
    public func clip(_ id: UUID) -> Clip? {
        clipPlaces[id].map { project.tracks[$0.track].clips[$0.clip] }
    }

    /// The track a clip is on, or nil when the project has no such clip.
    public func trackID(ofClip id: UUID) -> UUID? {
        clipPlaces[id].map { project.tracks[$0.track].id }
    }

    /// Where a recording stands among the recordings: the order takes are counted in. Nil when the project
    /// does not have it.
    public func recordingOrder(_ id: UUID) -> Int? {
        recordingPlaces[id]
    }

    // MARK: Positions, in song seconds

    /// As `Project.start(of:)` for a segment.
    public func start(of segment: Segment) -> Double? {
        guard let place = recordingPlaces[segment.recordingID] else { return nil }
        return project.recordings[place].songTime(ofSample: segment.inSample, offsetSamples: segment.offsetSamples)
    }

    /// As `Project.end(of:)` for a segment.
    public func end(of segment: Segment) -> Double? {
        guard let place = recordingPlaces[segment.recordingID] else { return nil }
        return project.recordings[place].songTime(ofSample: segment.outSample, offsetSamples: segment.offsetSamples)
    }

    /// As `Project.start(of:)` for a clip.
    public func start(of clip: Clip) -> Double? {
        clip.segments.first.flatMap { start(of: $0) }
    }

    /// As `Project.end(of:)` for a clip.
    public func end(of clip: Clip) -> Double? {
        clip.segments.last.flatMap { end(of: $0) }
    }

    // MARK: Cutting

    /// As `Project.canSplit(clip:at:)`.
    public func canSplit(clip id: UUID, at seconds: Double) -> Bool {
        Project.splitSample(of: clip(id), at: seconds, recording: recording) != nil
    }

    // MARK: Markers

    /// As `Project.markers(in:allMarkers:)`.
    public func markers(in clip: Clip, allMarkers: [UUID: [SyllableMarker]]) -> [ClipMarker] {
        Project.markers(in: clip, allMarkers: allMarkers, recording: recording)
    }

    // MARK: Takes

    /// As `Project.takeGroups(on:)`.
    public func takeGroups(on trackID: UUID) -> [[Clip]] {
        guard let place = trackPlaces[trackID] else { return [] }
        let track = project.tracks[place]
        return Project.takeGroupIndices(in: track, order: { recordingPlaces[$0] })
            .map { group in group.map { track.clips[$0] } }
    }

    /// As `Project.takes(of:)`.
    public func takes(of clipID: UUID) -> [Clip] {
        guard let place = clipPlaces[clipID] else { return [] }
        let track = project.tracks[place.track]
        let group = Project.takeGroupIndices(in: track, holding: place.clip, order: { recordingPlaces[$0] })
        return group.map { track.clips[$0] }
    }
}

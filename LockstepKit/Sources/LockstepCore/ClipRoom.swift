import Foundation

// The room around a clip: how far its sound may reach past its own edges when a line slides.
//
// A line slides until its first syllable stands on its sub-beat. When the line lies close to an edge of its
// clip, the clip is too short for that, and the sound then reaches past the edge: the clip is shown and
// played that much longer. The recording and the clip in the project stay as they are. This file says how
// much longer a clip may get, on each side.
//
//     let rooms = project.room(around: clip, atMost: settings.maxShiftSamples)
//     rooms[0].before        // samples free before the clip's first segment
//     rooms[0].after         // samples free after it
//
// What stands in the way, and nothing else does:
// - the clip before or after it on the same track,
// - the start and the end of what is kept of the song,
// - another segment of the same clip.

extension ClipTightening {
    /// How many samples of the song are free on each side of one segment of a clip.
    public struct Room: Sendable, Equatable {
        /// Free samples before the segment's first sample.
        public var before: Int
        /// Free samples after its last sample.
        public var after: Int

        public init(before: Int = 0, after: Int = 0) {
            self.before = before
            self.after = after
        }

        /// No room on either side: the sound stays inside the segment.
        public static let none = Room()
    }
}

extension Project {
    /// The room around every segment of a clip, one answer per segment in the order of `clip.segments`.
    ///
    /// Only what is shown on the clip's track stands in the way: the active takes of other lines, muted or
    /// not. The other takes of the clip's own line lie in the same place by their nature and do not count,
    /// and neither does a take of another line that waits, which is neither drawn nor heard.
    ///
    /// A neighbour is measured by its own edges as the project keeps them, not by how far its own lines have
    /// slid. So when two clips with a short gap between them both slide a line into that gap, the two sounds
    /// can lie on top of each other for the few milliseconds they share.
    ///
    /// - Parameters:
    ///   - clip: the clip. It is looked up on its track by its id, so a copy with other settings is fine.
    ///   - limit: no answer is larger than this. Hand in the furthest a line may slide: more room than that
    ///     is never used, and the answer then does not change when a clip far away is moved.
    /// - Returns: `.none` for a segment whose recording the project does not have.
    public func room(around clip: Clip, atMost limit: Int = .max) -> [ClipTightening.Room] {
        let known = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let track = tracks.first { track in track.clips.contains { $0.id == clip.id } }
        let shown = ShownPlaces(of: track, recording: { known[$0] })
        return shown.room(around: clip, kept: keptSamples, atMost: limit)
    }
}

/// Where the shown clips of one track lie in the song, in whole samples: what stands in the way of a line
/// that slides out of its clip. It is worked out once for a track and then asked for each of its clips,
/// which is what `TighteningInputsMemory` does. `Project.room(around:atMost:)` is the same rule for one clip.
struct ShownPlaces {
    /// One clip that is shown on the track: an active take.
    private struct Shown {
        var clipID: UUID
        var line: UUID
        var places: [Range<Int>]
    }

    private let recording: (UUID) -> Recording?
    private var shown: [Shown] = []

    /// - Parameters:
    ///   - track: the track, or nil for a clip that is on none: nothing then stands in its way but itself
    ///     and the ends of the song.
    ///   - recording: the project's recording with an id, or nil when it has none.
    init(of track: Track?, recording: @escaping (UUID) -> Recording?) {
        self.recording = recording
        for clip in track?.clips ?? [] where clip.isActiveTake {
            shown.append(Shown(clipID: clip.id, line: clip.line, places: clip.segments.compactMap(place)))
        }
    }

    /// Where a segment lies in the song, in whole samples, by the one position rule. Nil when the project
    /// does not have its recording.
    private func place(of segment: Segment) -> Range<Int>? {
        guard let recording = recording(segment.recordingID) else { return nil }
        let start = recording.songSample(ofSample: segment.inSample, offsetSamples: segment.offsetSamples)
        return start..<start + segment.lengthSamples
    }

    /// The room around every segment of a clip of the track, as `Project.room(around:atMost:)` gives it.
    ///
    /// - Parameter kept: the samples of the song that are left after cutting (`Project.keptSamples`).
    func room(around clip: Clip, kept: Range<Int>, atMost limit: Int) -> [ClipTightening.Room] {
        let places = clip.segments.map(place)
        var neighbours: [Range<Int>] = []
        for other in shown where other.clipID != clip.id && other.line != clip.line {
            neighbours += other.places
        }
        return places.enumerated().map { index, place in
            guard let place else { return .none }
            var before = place.lowerBound - kept.lowerBound
            var after = kept.upperBound - place.upperBound
            let own = places.enumerated().compactMap { $0.offset == index ? nil : $0.element }
            for other in neighbours + own where !other.isEmpty {
                // Whatever starts at or before this segment is in the way before it, and whatever ends at or
                // after it is in the way after it. One that lies across an edge leaves no room there.
                if other.lowerBound <= place.lowerBound {
                    before = min(before, place.lowerBound - other.upperBound)
                }
                if other.upperBound >= place.upperBound {
                    after = min(after, other.lowerBound - place.upperBound)
                }
            }
            return ClipTightening.Room(
                before: min(max(before, 0), max(limit, 0)),
                after: min(max(after, 0), max(limit, 0))
            )
        }
    }
}

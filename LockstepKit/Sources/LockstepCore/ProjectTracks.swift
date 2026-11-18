import Foundation

/// The track commands: new, rename, mute, duplicate, merge, delete and reorder.
///
/// Each function changes the project and nothing else, so the app runs it inside `ProjectStore.edit`, which
/// makes it one undo step and puts the takes right afterwards.
///
/// Which track is selected is not in the project. A function that leaves the app with something new to select
/// gives that track's id back. Every function also says whether it changed anything, so the app can leave out
/// an undo step for a command that was refused:
///
///     var changed = store.project
///     guard let next = changed.deleteTrack(selected) else { return }   // refused: the only track
///     store.edit("Delete Track") { $0 = changed }
///     select(next)
extension Project {
    // MARK: Asking

    /// The name a new track would get now: "Track N" with the lowest number, from 1, that no track is called.
    /// A track that was renamed or deleted has given its number back.
    public func nextTrackName() -> String {
        let taken = Set(tracks.map(\.name))
        var number = 1
        while taken.contains(Project.trackName(number: number)) { number += 1 }
        return Project.trackName(number: number)
    }

    /// The name of the track with a number: "Track 3".
    public static func trackName(number: Int) -> String {
        "Track \(number)"
    }

    // MARK: Changing

    /// Adds an empty track at the bottom, named by `nextTrackName()`.
    ///
    /// - Returns: the id of the new track, which the app selects.
    @discardableResult
    public mutating func addTrack() -> Track.ID {
        let track = Track(name: nextTrackName())
        tracks.append(track)
        return track.id
    }

    /// Gives a track another name. Spaces and line breaks around the name are dropped first.
    ///
    /// - Returns: false, with the old name kept, when nothing is left of the name, when it is the name the
    ///   track already has, or when the project has no such track.
    @discardableResult
    public mutating func renameTrack(_ id: Track.ID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = trackIndex(id), tracks[index].name != trimmed else { return false }
        tracks[index].name = trimmed
        return true
    }

    /// Mutes a track, or lets it be heard again. A muted track's clips are left out of
    /// `clipPlaybackPlan(from:to:)`.
    ///
    /// - Returns: false when the track was already that way, or the project has no such track.
    @discardableResult
    public mutating func setTrackMuted(_ id: Track.ID, _ muted: Bool) -> Bool {
        guard let index = trackIndex(id), tracks[index].muted != muted else { return false }
        tracks[index].muted = muted
        return true
    }

    /// Makes a copy of a track right below it, named "<name> copy", with the same mute, volume, Sound and
    /// Voice, and with the same effects under the same ids, so what the copied clips changed of them still
    /// holds. With the same Voice the copies are heard from the very voices the original's clips are: a voice
    /// belongs to a recording and a setting, and the copies play the same recordings.
    ///
    /// With clips, every clip is copied as it is (name, text, mute, volume, feel, tightening, its own knobs,
    /// which take is active) under a new id. The copies play the same parts of the same recordings: no recording is added and no sound is
    /// copied. Without clips the new track is empty.
    ///
    /// - Returns: the id of the new track, which the app selects. Nil, with nothing changed, when the project
    ///   has no such track.
    @discardableResult
    public mutating func duplicateTrack(_ id: Track.ID, withClips: Bool) -> Track.ID? {
        guard let index = trackIndex(id) else { return nil }
        let original = tracks[index]
        var clips: [Clip] = []
        if withClips {
            // The copies are lines of their own, with the same takes together as on the original track.
            var lines: [UUID: UUID] = [:]
            clips = original.clips.map { clip in
                var copy = clip
                copy.id = UUID()
                let line = lines[clip.line] ?? UUID()
                lines[clip.line] = line
                copy.line = line
                return copy
            }
        }
        // The track as it is, with everything it has now and whatever it gets later, under an id of its own.
        // Naming the fields one by one dropped the Voice when tracks got one.
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " copy"
        copy.clips = clips
        tracks.insert(copy, at: index + 1)
        return copy.id
    }

    /// Moves every clip of one track to another and removes the track they came from. The target keeps its own
    /// name and settings, and its clips, old and new, are put in the order they start in the song. The clips
    /// that came follow the target's Sound, effects and Voice from then on, and keep the knobs they turned for
    /// themselves and what they changed of the effects of the track they came from, which counts for nothing
    /// on the target. The Voice of the track that is removed goes with it.
    ///
    /// The clips that came are treated as clips moved there (`land`): one that starts where a clip of the
    /// target starts, within 50 ms, becomes a take of that clip's line and is the one shown, and whatever
    /// else a clip that came covers of the target's clips gives way to it.
    ///
    /// - Parameters:
    ///   - peaks: the highest sample of a stretch of a recording, so a clip that gives way stays as
    ///     loud as it was (see the top of `ProjectClipEdits.swift`).
    ///   - voices: which voice stands in for which recording on which track, so the safe limit is asked
    ///     about the sound each clip is heard from on its track (see the top of `ProjectClipEdits.swift`).
    /// - Returns: false, with nothing changed, when source and target are the same track or the project does
    ///   not have both. On true the app selects the target.
    @discardableResult
    public mutating func mergeTrack(
        _ source: Track.ID,
        into target: Track.ID,
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices
    ) -> Bool {
        guard source != target, let from = trackIndex(source), let to = trackIndex(target) else { return false }
        let came = Set(tracks[from].clips.map(\.id))
        tracks[to].clips = inSongOrder(tracks[to].clips + tracks[from].clips)
        tracks.remove(at: from)
        land(came, peaks: peaks, voices: voices)
        return true
    }

    /// Removes a track and its clips. The recordings stay in the project, so an undo brings the clips back with
    /// their sound. The ones no other clip plays show up in `unusedRecordingIDs()` and are removed when the
    /// project closes.
    ///
    /// - Returns: the id of the track to select next: the one that was below the removed track, or the one
    ///   above it when it was the bottom track. Nil, with nothing changed, when it is the only track or the
    ///   project has no such track.
    @discardableResult
    public mutating func deleteTrack(_ id: Track.ID) -> Track.ID? {
        guard tracks.count > 1, let index = trackIndex(id) else { return nil }
        tracks.remove(at: index)
        return tracks[min(index, tracks.count - 1)].id
    }

    /// Moves a track to another place in the order, top to bottom. No clip is touched.
    ///
    /// - Parameter index: the place the track has afterwards, counted from 0 at the top. A place past either
    ///   end is the nearest end. When a drag ends on the line above the track that is now at place `row`, the
    ///   place to ask for is `row` for a track dragged upward and `row - 1` for one dragged downward.
    /// - Returns: false when the track is already there, or the project has no such track.
    @discardableResult
    public mutating func moveTrack(_ id: Track.ID, toIndex index: Int) -> Bool {
        guard let from = trackIndex(id) else { return false }
        let to = min(max(index, 0), tracks.count - 1)
        guard to != from else { return false }
        let track = tracks.remove(at: from)
        tracks.insert(track, at: to)
        return true
    }

    // MARK: Helpers

    /// The place of a track in the order, or nil when the project does not have it.
    private func trackIndex(_ id: Track.ID) -> Int? {
        tracks.firstIndex { $0.id == id }
    }

    /// Clips in the order they start in the song, by the same whole-sample position rule the player uses.
    /// Clips that start on the same sample keep the order they came in, and clips with no place (no segments,
    /// or a recording the project does not have) go last.
    private func inSongOrder(_ clips: [Clip]) -> [Clip] {
        let known = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = clips.enumerated().map { index, clip -> (start: Int, index: Int, clip: Clip) in
            let start = clip.segments.first.flatMap { segment in
                known[segment.recordingID]?.songSample(ofSample: segment.inSample, offsetSamples: segment.offsetSamples)
            }
            return (start ?? Int.max, index, clip)
        }
        return placed.sorted { ($0.start, $0.index) < ($1.start, $1.index) }.map(\.clip)
    }
}

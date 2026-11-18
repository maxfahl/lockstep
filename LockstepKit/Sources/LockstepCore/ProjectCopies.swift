import Foundation

/// Clips that were copied with Edit > Copy, waiting to be pasted.
///
/// It holds what the clips were when they were copied, so a clip that is changed or deleted afterwards
/// is still pasted as it was. A copy plays the same recordings as its clip: nothing of a recording is
/// copied or written again.
public struct CopiedClips: Sendable, Equatable {
    /// One copied clip, and how many tracks below the topmost copied clip it was.
    public struct Item: Sendable, Equatable {
        public var clip: Clip
        public var trackStep: Int
    }

    /// The copied clips, by track from the top and along each track by where they start.
    public var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
}

/// Copying clips: Edit > Copy and Edit > Paste, and a drag with Option held.
///
/// The rules, as Max asked for them on 14 November 2026:
///
/// - Of each line only the shown take is copied, with everything it has: its correction, Stretch, volume,
///   name and words.
/// - A copy is a line of its own, a new clip that plays the same parts of the same recordings. No recording
///   is changed or written again.
/// - Paste puts the copies on the selected track with the first one's start at the playhead, keeping their
///   distances in time. Clips copied from several tracks keep their distance in tracks from the topmost, counted
///   from the selected track, and a copy that would land below the last track lands on the last track.
/// - Nothing is pasted outside what is left of the song (`keptSamples`): the copies are moved inside together,
///   as moved clips stop there, so they keep their distances.
/// - A drag with Option held leaves the clips where they are and puts copies where the clips would have gone.
/// - A copy wins over what it covers, as a new recording aimed there does (`ProjectGivingWay.swift`), and never
///   becomes a take of another line.
///
/// Each function changes the project and nothing else. The app runs it inside `ProjectStore.edit`, so a paste
/// or a drop is one undo step, the clips that gave way included.
///
///     let copies = store.project.copyClips(selectedClipIDs)
///     store.edit("Paste Clips") { pasted = $0.paste(copies, onTrack: trackID, atSample: playhead, peaks: peaks) }
extension Project {
    /// The shown takes of the lines of these clips, as `CopiedClips`. Empty when none of the ids is a clip.
    public func copyClips(_ ids: Set<Clip.ID>) -> CopiedClips {
        var found: [(track: Int, start: Int, clip: Clip)] = []
        var lines: Set<UUID> = []
        for (index, track) in tracks.enumerated() {
            for clip in track.clips where ids.contains(clip.id) && !lines.contains(clip.line) {
                lines.insert(clip.line)
                let shown = shownTake(ofLineOf: clip)
                found.append((index, songSpan(of: shown)?.lowerBound ?? 0, shown))
            }
        }
        found.sort { ($0.track, $0.start) < ($1.track, $1.start) }
        let top = found.first?.track ?? 0
        return CopiedClips(items: found.map { CopiedClips.Item(clip: $0.clip, trackStep: $0.track - top) })
    }

    /// Whether any of the copies can be pasted here: it plays a recording this project has.
    public func canPaste(_ copies: CopiedClips) -> Bool {
        copies.items.contains { item in
            !item.clip.segments.isEmpty && item.clip.segments.allSatisfy { recording($0.recordingID) != nil }
        }
    }

    /// Paste: puts new copies of the copied clips on a track, the first one's start on a sample of the song,
    /// by the rules at the top of this file. Copies of recordings the project does not have are left out.
    ///
    /// - Parameters:
    ///   - peaks: the highest sample of a stretch of a recording, so a clip that gives way stays as
    ///     loud as it was (see the top of `ProjectClipEdits.swift`).
    ///   - voices: which voice stands in for which recording on which track, so the safe limit is asked
    ///     about the sound each clip is heard from on its track (see the top of `ProjectClipEdits.swift`).
    /// - Returns: the copies as they were made, before anything gave way, in the order of `copies`. One that a
    ///   later copy covered completely is no longer in the project.
    @discardableResult
    public mutating func paste(
        _ copies: CopiedClips,
        onTrack trackID: UUID,
        atSample start: Int,
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices
    ) -> [Clip] {
        guard let firstTrack = tracks.firstIndex(where: { $0.id == trackID }) else { return [] }
        let items = copies.items.filter { item in
            !item.clip.segments.isEmpty && item.clip.segments.allSatisfy { recording($0.recordingID) != nil }
        }
        let spans = items.compactMap { songSpan(of: $0.clip) }
        guard let earliest = spans.map(\.lowerBound).min(), let latest = spans.map(\.upperBound).max()
        else { return [] }
        // The first copy's start on the sample, then the whole group pushed back inside what is left of the
        // song. A group longer than that keeps its start at the start of the song.
        var shift = start - earliest
        let kept = keptSamples
        shift -= max(0, latest + shift - kept.upperBound)
        shift += max(0, kept.lowerBound - (earliest + shift))
        let placed = items.map { item in
            (clip: Project.copy(of: item.clip, bySamples: shift), track: min(firstTrack + item.trackStep, tracks.count - 1))
        }
        return put(placed, peaks: peaks, voices: voices)
    }

    /// A drag with Option held: new copies of the shown takes of these clips' lines, moved along the song and
    /// between tracks by a move that was asked of `allowedMove(of:bySamples:trackSteps:)`. The clips stay as
    /// they are, unless a copy covers part of them: then they give way to it.
    ///
    /// - Parameters:
    ///   - newIDs: the id each copy is to have, by the id of its clip, so the copies drawn during the
    ///     drag are the ones that land. A clip that is not in it gets a new id.
    ///   - voices: which voice stands in for which recording on which track, so the safe limit is asked
    ///     about the sound each clip is heard from on its track (see the top of `ProjectClipEdits.swift`).
    /// - Returns: the copies as they were made, as `paste` gives them. Empty for a move of nothing.
    @discardableResult
    public mutating func duplicateClips(
        _ ids: Set<Clip.ID>,
        by move: ClipMove,
        newIDs: [Clip.ID: Clip.ID] = [:],
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices
    ) -> [Clip] {
        guard !move.isNothing else { return [] }
        var placed: [(clip: Clip, track: Int)] = []
        var lines: Set<UUID> = []
        for (index, track) in tracks.enumerated() {
            for clip in track.clips where ids.contains(clip.id) && !lines.contains(clip.line) {
                lines.insert(clip.line)
                let shown = shownTake(ofLineOf: clip)
                let target = index + move.trackSteps
                guard tracks.indices.contains(target) else { continue }
                let copy = Project.copy(of: shown, bySamples: move.samples, id: newIDs[shown.id] ?? newIDs[clip.id] ?? UUID())
                placed.append((copy, target))
            }
        }
        return put(placed, peaks: peaks, voices: voices)
    }

    // MARK: Making the copies

    /// The take of a clip's line that is drawn and heard: the one active take, or the one `normalizeTakes`
    /// would make it.
    func shownTake(ofLineOf clip: Clip) -> Clip {
        let takes = takes(of: clip.id)
        let active = takes.filter(\.isActiveTake)
        return active.count == 1 ? active[0] : takes.last ?? clip
    }

    /// A new clip that plays what a clip plays, `delta` samples further along the song, as a line of its own.
    /// It was never recorded where it stands, so it has no place Record aimed at.
    static func copy(of clip: Clip, bySamples delta: Int, id: Clip.ID = UUID()) -> Clip {
        var copy = clip
        copy.id = id
        copy.line = UUID()
        copy.isActiveTake = true
        copy.recordPlace = nil
        for index in copy.segments.indices {
            copy.segments[index].offsetSamples += delta
        }
        return copy
    }

    /// Puts copies on their tracks, last in each track's list and one after the other, and makes what each
    /// covers give way to it, so a later copy wins over an earlier one where they meet.
    ///
    /// - Returns: the copies as they were made. The app keeps their words with them
    ///   (`clearWordsOfCutClips(since:copies:)`) and selects the ones still there.
    private mutating func put(
        _ placed: [(clip: Clip, track: Int)],
        peaks: RecordingPeak,
        voices: TrackVoices
    ) -> [Clip] {
        for (clip, track) in placed {
            tracks[track].clips.append(clip)
            giveWay(to: clip.id, peaks: peaks, voices: voices)
        }
        return placed.map(\.clip)
    }
}

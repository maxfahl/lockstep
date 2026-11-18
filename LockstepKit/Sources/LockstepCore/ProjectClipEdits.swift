import Foundation

/// The clip commands that cut and join: Split at Playhead, deleting a marked stretch, and Join Clips.
///
/// Each function changes the project and nothing else, so the app runs it inside `ProjectStore.edit`,
/// which makes it one undo step and puts the takes right afterwards. A function that was refused changes
/// nothing and gives nil:
///
///     let peaks = recordingPeaks.lookup(in: sounds)                               // see `RecordingPeak`
///
///     guard project.canSplit(clip: id, at: playhead) else { return }              // the menu item is disabled
///     store.edit("Split at Playhead") { right = $0.splitClip(id, at: playhead, peaks: peaks)?.second }
///
///     store.edit("Delete Marked Stretch") { $0.cut(range: stretch, onTrack: track, peaks: peaks) }
///
///     guard project.canJoin(selection) else { return }
///     store.edit("Join Clips") { joined = $0.joinClips(selection, peaks: peaks) }
///
/// What never changes here:
/// - Where a sample is heard. A cut only changes which samples of a recording a segment plays, and no function
///   here touches `offsetSamples`, so every sample that is left sounds on the same sample of the song as before.
/// - How loud a part is. Pieces keep their clip's volume, and joined parts carry the difference between their old
///   clip's volume and the new one in their segments' own `gainDb`. That also holds for a clip the safe limit
///   holds back (`Clip.appliedGain`). The limit follows the clip's highest sample, and a piece that no longer
///   holds that sample would be let louder. So before such a clip is cut or joined, the amount it is held back
///   by is moved into its segments' own `gainDb`: every part is then played exactly as loud as before, and the
///   clip is no longer held back, because the lowering is now its own. This is what `peaks` is for. Without it
///   nothing is known to be held back, and such a part can come out louder than it was.
///   On a track with a Voice the clip is heard from the voice, whose highest sample is another than the
///   recording's. So the edits are handed `voices` beside `peaks`, and the limit is asked about the sound
///   the clip is read from on its own track (`TrackVoices.peaks(_:on:)`). The rule: an edit keeps a part as
///   loud as it was heard when the edit was made. What an edit writes into a segment's own `gainDb` can
///   therefore differ by which voice was heard at that moment. The project still never names a voice. With
///   `voices` left out the limit is asked about the recordings, as before a track could have a Voice.
/// - The recordings. Nothing is removed from `recordings`, so an undo brings every sound back.
///
/// Cuts are made on whole samples of the song, by the position rule the player uses (`Recording.songSample`).
/// So every take of a line is cut on the very same sample. What a divided line has after the cut becomes a line
/// of its own, with the pieces of the takes as its takes, so each side is again one line.
extension Project {
    /// The closest a split may come to the edges of the segment it divides: 1 ms, in samples.
    public static let splitMarginSamples = 48

    // MARK: Split at Playhead

    /// Whether this clip can be split at a place in the song: the place must be inside one of the clip's
    /// segments, at least 1 ms from that segment's edges. In a gap of a joined clip, at an edge, or outside the
    /// clip there is nothing to split.
    public func canSplit(clip id: Clip.ID, at seconds: Double) -> Bool {
        splitSample(of: id, at: seconds) != nil
    }

    /// Cuts a clip in two at a place in the song, on the nearest sample.
    ///
    /// The first piece keeps the clip's id, name and text. The second is a new clip right after it in the track's
    /// list, with no name and no text. Both keep the mute, the volume, the feel and whether they are the take
    /// that is heard.
    ///
    /// Every other take of the line is cut on the same sample of the song, the waiting ones included, so each
    /// side is again one line with the same take heard: the first pieces keep the line, and the second pieces
    /// are a new line together. A take that does not reach the place is left whole, on the side it lies on, and
    /// one that has a gap there is divided at the gap.
    ///
    /// - Parameters:
    ///   - peaks: the highest sample of a stretch of a recording, so a clip the safe limit holds back
    ///     stays as loud as it was (see the top of this file).
    ///   - voices: which voice stands in for which recording on which track, so the limit is asked about
    ///     the sound the clip is heard from.
    /// - Returns: the ids of the two pieces of this clip, or nil, with nothing changed, when `canSplit` says no.
    @discardableResult
    public mutating func splitClip(
        _ id: Clip.ID,
        at seconds: Double,
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices
    ) -> (first: Clip.ID, second: Clip.ID)? {
        guard let sample = splitSample(of: id, at: seconds),
              let track = tracks.firstIndex(where: { track in track.clips.contains { $0.id == id } })
        else { return nil }
        let line = Set(takes(of: id).map(\.id))
        let changed = takeOut(sample..<sample, ofClips: line, onTrackAt: track, peaks: peaks, voices: voices)
        guard let pieces = changed.first(where: { $0.clip == id })?.pieces, pieces.count == 2 else { return nil }
        return (pieces[0], pieces[1])
    }

    // MARK: Delete a marked stretch

    /// Removes a stretch of the song from the clips of one track. Nothing after the stretch moves.
    ///
    /// For every clip the stretch touches, the waiting takes included:
    /// - a clip that lies inside the stretch is removed;
    /// - a clip the stretch covers one end of is made shorter, and stays the same clip;
    /// - a clip the stretch lies inside becomes two. The piece before keeps the id, the name and the text, and the
    ///   piece after is a new clip with no name and no text, as after a split. That is also what happens when the
    ///   stretch only covers a gap inside a joined clip: two clips, and not a sample less.
    ///
    /// A line that is divided this way is two lines afterwards: what its takes have before the stretch, and what
    /// they have after it.
    ///
    /// The edges of the stretch are the nearest samples of the song.
    ///
    /// - Parameters:
    ///   - peaks: the highest sample of a stretch of a recording, so a clip the safe limit holds back
    ///     stays as loud as it was (see the top of this file).
    ///   - voices: which voice stands in for which recording on which track, so the limit is asked about
    ///     the sound each clip is heard from.
    /// - Returns: the ids of what is left of the clips the stretch touched, in the order of the track's list
    ///   (empty when all of them were removed). Nil, with nothing changed, when the stretch touches no clip, has
    ///   no length, or the project has no such track.
    @discardableResult
    public mutating func cut(
        range: Range<Double>,
        onTrack trackID: Track.ID,
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices
    ) -> [Clip.ID]? {
        guard let track = tracks.firstIndex(where: { $0.id == trackID }),
              let from = Project.songSample(at: range.lowerBound),
              let to = Project.songSample(at: range.upperBound),
              to > from
        else { return nil }
        let changed = takeOut(from..<to, ofClips: nil, onTrackAt: track, peaks: peaks, voices: voices)
        return changed.isEmpty ? nil : changed.flatMap(\.pieces)
    }

    // MARK: Join Clips

    /// Whether these clips can be joined into one: two or more clips, all on one track, all of them shown (the
    /// take of their line that is heard), with no other shown clip of the track starting between them, and no
    /// two of them lying on top of each other.
    public func canJoin(_ ids: Set<Clip.ID>) -> Bool {
        joined(ids, peaks: Clip.unknownPeaks, voices: .none) != nil
    }

    /// Makes one clip out of two or more clips in a row. Every part stays where it was and as loud as it was, and
    /// the gaps between the parts stay as silence inside the clip.
    ///
    /// The clip keeps the id, name, volume and feel of the part that starts first, and stands where that part
    /// stood in the track's list. It is muted only when every part was. The texts of the parts are put together
    /// in the order of the song. Two parts that play one recording straight on, such as the two pieces of a
    /// split, become one segment again. The effects of every part are kept, each where it was heard
    /// (`joinedEffects`), and the knobs are the first part's.
    ///
    /// Waiting takes of the joined clips keep their sound and their place: they are still there, as takes of
    /// the joined clip, whichever part they waited behind. The lines of the parts become one line.
    ///
    /// - Parameters:
    ///   - peaks: the highest sample of a stretch of a recording, so a part the safe limit held back
    ///     stays as loud as it was (see the top of this file).
    ///   - voices: which voice stands in for which recording on which track, so the limit is asked about
    ///     the sound each part is heard from.
    /// - Returns: the id of the joined clip, or nil, with nothing changed, when `canJoin` says no.
    @discardableResult
    public mutating func joinClips(
        _ ids: Set<Clip.ID>,
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices
    ) -> Clip.ID? {
        guard let (track, clip) = joined(ids, peaks: peaks, voices: voices) else { return nil }
        let lines = Set(tracks[track].clips.filter { ids.contains($0.id) }.map(\.line))
        tracks[track].clips.removeAll { ids.contains($0.id) && $0.id != clip.id }
        guard let index = tracks[track].clips.firstIndex(where: { $0.id == clip.id }) else { return nil }
        tracks[track].clips[index] = clip
        for other in tracks[track].clips.indices where lines.contains(tracks[track].clips[other].line) {
            tracks[track].clips[other].line = clip.line
        }
        return clip.id
    }

    // MARK: Working it out

    /// The sample of the song a split of this clip at this time is made on, or nil when the clip cannot be
    /// split there.
    private func splitSample(of id: Clip.ID, at seconds: Double) -> Int? {
        Self.splitSample(of: clip(id), at: seconds, recording: recording)
    }

    /// The same for a clip that is at hand, asking for each of its recordings by id: the project itself, or
    /// its lookup table (`ProjectLookup.canSplit(clip:at:)`). Only the clip's own recordings are looked at.
    static func splitSample(of clip: Clip?, at seconds: Double, recording: (UUID) -> Recording?) -> Int? {
        guard let clip, let sample = Project.songSample(at: seconds) else { return nil }
        for segment in clip.segments {
            guard let found = recording(segment.recordingID),
                  let span = Project.songSpan(of: segment, [found.id: found])
            else { return nil }
            if sample - span.lowerBound >= Project.splitMarginSamples,
               span.upperBound - sample >= Project.splitMarginSamples {
                return sample
            }
        }
        return nil
    }

    /// Takes a stretch of the song out of clips of one track, and makes two clips of every clip that then has
    /// sound on both sides of the stretch. A stretch with no length takes nothing out and only divides, which
    /// is a split.
    ///
    /// - Parameters:
    ///   - range: the samples of the song to take out.
    ///   - ids: the clips to look at. Nil is every clip of the track.
    ///   - track: the place of the track in the project.
    ///   - peaks: the highest sample of a stretch of a recording.
    ///   - voices: which voice stands in for which recording on which track. The clips are asked about on
    ///     the track they lie on when they are cut.
    /// - Returns: every clip the stretch touched, with the ids of what is left of it, in the order of the track's
    ///   list. A clip the stretch does not reach into is not touched and not in the answer.
    ///
    /// Lines: the second of two pieces is a clip of a new line, the same one for every take of the line that
    /// was divided. Whatever else that line has after the stretch goes to the new line too, so what lies
    /// before the stretch and what lies after it are never takes of each other. A clip that loses its start
    /// is no longer where it was recorded, and forgets the place it was recorded from (`Clip.recordPlace`).
    ///
    /// - Parameter leastRest: the shortest rest that is kept on a side of the stretch, in samples, measured
    ///   from where the rest starts to where it ends. A shorter one is removed with what the stretch took.
    ///   0, as for a split and for Delete Marked Stretch, keeps every rest. A clip that gives way to another
    ///   leaves no rest shorter than `leastRestSamples`.
    mutating func takeOut(
        _ range: Range<Int>,
        ofClips ids: Set<Clip.ID>?,
        onTrackAt track: Int,
        peaks: RecordingPeak,
        voices: TrackVoices,
        leastRest: Int = 0
    ) -> [(clip: Clip.ID, pieces: [Clip.ID])] {
        let known = knownRecordings()
        var changed: [(clip: Clip.ID, pieces: [Clip.ID])] = []
        var clips: [Clip] = []
        // For every line the stretch divides, the line of what lies after the stretch.
        var lineAfter: [UUID: UUID] = [:]
        for whole in tracks[track].clips {
            guard ids?.contains(whole.id) ?? true,
                  let span = Project.songSpan(of: whole, known),
                  span.lowerBound < range.upperBound, span.upperBound > range.lowerBound
            else {
                clips.append(whole)
                continue
            }
            // What is left must sound as it did, so a clip that is held back is cut with the lowering as its own.
            let clip = Project.holdingItselfBack(whole, peaks, voices: voices, on: tracks[track])
            guard var sides = Project.sides(of: clip, without: range, known) else {
                clips.append(whole)
                continue
            }
            if leastRest > 0 {
                if (Project.songSpan(of: sides.before, known)?.count ?? 0) < leastRest { sides.before = [] }
                if (Project.songSpan(of: sides.after, known)?.count ?? 0) < leastRest { sides.after = [] }
            }
            var pieces: [Clip] = []
            if !sides.before.isEmpty {
                var piece = clip
                piece.segments = sides.before
                pieces.append(piece)
            }
            if !sides.after.isEmpty {
                var piece = clip
                piece.segments = sides.after
                if !pieces.isEmpty {
                    // The second of two pieces is a new clip. Its words are written out again in phase 17.
                    piece.id = UUID()
                    piece.name = nil
                    piece.text = nil
                    let line = lineAfter[clip.line] ?? UUID()
                    lineAfter[clip.line] = line
                    piece.line = line
                }
                if piece.segments.first != clip.segments.first {
                    piece.recordPlace = nil
                }
                pieces.append(piece)
            }
            clips += pieces
            changed.append((clip.id, pieces.map(\.id)))
        }
        guard !changed.isEmpty else { return [] }
        if !lineAfter.isEmpty {
            for index in clips.indices {
                guard let line = lineAfter[clips[index].line],
                      let span = Project.songSpan(of: clips[index], known), span.lowerBound >= range.upperBound
                else { continue }
                clips[index].line = line
            }
        }
        tracks[track].clips = clips
        return changed
    }

    /// What is left of a clip's segments before and after a stretch of the song that is taken out. A segment the
    /// stretch reaches into is cut at the stretch's edges. Only `inSample` and `outSample` of a cut segment
    /// change, never where its samples are heard. Nil when the project lacks a recording the clip plays.
    private static func sides(
        of clip: Clip,
        without range: Range<Int>,
        _ known: [UUID: Recording]
    ) -> (before: [Segment], after: [Segment])? {
        var before: [Segment] = []
        var after: [Segment] = []
        for segment in clip.segments {
            guard let recording = known[segment.recordingID] else { return nil }
            // The sample of the song on which sample 0 of the recording would be heard through this segment.
            let origin = recording.songSample(ofSample: 0, offsetSamples: segment.offsetSamples)
            let start = origin + segment.inSample
            let end = origin + segment.outSample
            if end <= range.lowerBound {
                before.append(segment)
            } else if start >= range.upperBound {
                after.append(segment)
            } else {
                if start < range.lowerBound {
                    var kept = segment
                    kept.outSample = range.lowerBound - origin
                    before.append(kept)
                }
                if end > range.upperBound {
                    var kept = segment
                    kept.inSample = range.upperBound - origin
                    after.append(kept)
                }
            }
        }
        return (before, after)
    }

    /// What a clip would have left before and after a stretch of the song, were the stretch taken out of
    /// it: the samples of the song each rest covers, from its start to its end. A side with nothing left is
    /// nil. Nil altogether when the project lacks a recording the clip plays.
    func rests(of clip: Clip, without range: Range<Int>) -> (before: Range<Int>?, after: Range<Int>?)? {
        let known = knownRecordings()
        guard let sides = Project.sides(of: clip, without: range, known) else { return nil }
        return (Project.songSpan(of: sides.before, known), Project.songSpan(of: sides.after, known))
    }

    /// The clip that joining these clips gives, and the place of their track, or nil when they cannot be joined.
    private func joined(
        _ ids: Set<Clip.ID>,
        peaks: RecordingPeak,
        voices: TrackVoices
    ) -> (track: Int, clip: Clip)? {
        guard ids.count >= 2,
              let track = tracks.firstIndex(where: { track in track.clips.contains { ids.contains($0.id) } })
        else { return nil }
        let known = knownRecordings()

        // The shown clips of the track in the order they start in the song. Waiting takes are not seen, so they
        // are neither joined nor in the way.
        var shown: [(clip: Clip, start: Int, index: Int)] = []
        var found = 0
        for (index, clip) in tracks[track].clips.enumerated() {
            let chosen = ids.contains(clip.id)
            if chosen { found += 1 }
            guard clip.isActiveTake, let span = Project.songSpan(of: clip, known) else {
                // A chosen clip that is a waiting take, or has no place in the song, cannot be joined.
                if chosen { return nil }
                continue
            }
            shown.append((clip, span.lowerBound, index))
        }
        // Fewer were found than asked for: some are on another track, or nowhere.
        guard found == ids.count else { return nil }
        shown.sort { ($0.start, $0.index) < ($1.start, $1.index) }
        guard let first = shown.firstIndex(where: { ids.contains($0.clip.id) }),
              let last = shown.lastIndex(where: { ids.contains($0.clip.id) }),
              last - first + 1 == ids.count
        else { return nil }
        let parts = shown[first...last].map(\.clip)

        // Every segment of every part, with the samples of the song it covers. A segment is raised by what its
        // old clip was played with above the volume of the new clip, which is the first part's, so it is as loud
        // as before. What a part was played with is its volume after the safe limit: a part that was held back
        // carries that lowering with it, the first part too. The joined clip is then not held back, since none
        // of its parts is louder than it was.
        var segments: [(segment: Segment, span: Range<Int>, order: Int)] = []
        for part in parts {
            let raise = part.appliedGain(peaks: peaks, voices: voices, on: tracks[track]).db - parts[0].totalGainDb
            for var segment in part.segments {
                guard let span = Project.songSpan(of: segment, known) else { return nil }
                segment.gainDb += raise
                segments.append((segment, span, segments.count))
            }
        }
        segments.sort { ($0.span.lowerBound, $0.order) < ($1.span.lowerBound, $1.order) }

        var joined: [Segment] = []
        var end = Int.min
        for (segment, span, _) in segments {
            // A clip's segments never lie on top of each other, so clips that do cannot be one clip.
            guard span.lowerBound >= end else { return nil }
            end = span.upperBound
            if let before = joined.last, before.recordingID == segment.recordingID,
               before.outSample == segment.inSample, before.offsetSamples == segment.offsetSamples,
               before.gainDb == segment.gainDb {
                joined[joined.count - 1].outSample = segment.outSample
            } else {
                joined.append(segment)
            }
        }

        var clip = parts[0]
        clip.segments = joined
        clip.effects = Project.joinedEffects(of: parts)
        clip.muted = parts.allSatisfy(\.muted)
        let texts = parts.compactMap(\.text).filter { !$0.isEmpty }
        if !texts.isEmpty {
            clip.text = texts.joined(separator: " ")
        }
        return (track, clip)
    }

    // MARK: Helpers

    /// A clip with the amount the safe limit holds it back by moved into its segments' own `gainDb`. It sounds
    /// exactly the same and is no longer held back, so any part of it does too. A clip that is not held back is
    /// given back as it is.
    ///
    /// The limit is asked about the sound the clip is heard from on its track: the track's voice where one
    /// stands in, and the recording otherwise.
    static func holdingItselfBack(_ clip: Clip, _ peaks: RecordingPeak, voices: TrackVoices, on track: Track) -> Clip {
        let held = clip.appliedGain(peaks: peaks, voices: voices, on: track).heldBackDb
        guard held > 0 else { return clip }
        var lowered = clip
        for index in lowered.segments.indices {
            lowered.segments[index].gainDb -= held
        }
        return lowered
    }

    /// The recordings by their id.
    private func knownRecordings() -> [UUID: Recording] {
        Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The sample of the song nearest to a time in song seconds. Nil for a time that is no number.
    private static func songSample(at seconds: Double) -> Int? {
        let sample = (seconds * Lockstep.sampleRate).rounded()
        guard sample.isFinite, abs(sample) < 1e15 else { return nil }
        return Int(sample)
    }

    /// The samples of the song a segment covers. Nil when the project does not have its recording.
    private static func songSpan(of segment: Segment, _ known: [UUID: Recording]) -> Range<Int>? {
        guard let recording = known[segment.recordingID] else { return nil }
        let start = recording.songSample(ofSample: segment.inSample, offsetSamples: segment.offsetSamples)
        return start..<max(start, recording.songSample(ofSample: segment.outSample, offsetSamples: segment.offsetSamples))
    }

    /// The samples of the song a clip covers, from the start of its first segment to the end of its last. Nil
    /// for a clip with no segments, or whose recording the project does not have.
    private static func songSpan(of clip: Clip, _ known: [UUID: Recording]) -> Range<Int>? {
        songSpan(of: clip.segments, known)
    }

    /// The samples of the song that segments in the order of the song cover, from the start of the first to
    /// the end of the last. Nil for no segments, or when the project does not have a recording.
    private static func songSpan(of segments: [Segment], _ known: [UUID: Recording]) -> Range<Int>? {
        guard let first = segments.first.flatMap({ songSpan(of: $0, known) }),
              let last = segments.last.flatMap({ songSpan(of: $0, known) })
        else { return nil }
        return first.lowerBound..<max(first.lowerBound, last.upperBound)
    }
}

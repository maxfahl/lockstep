import Foundation

/// Where clips sit in the song, and adding and removing them.
///
/// Every time comes from the one position rule, `Recording.songTime(ofSample:offsetSamples:)`.
extension Project {
    // MARK: Finding things

    /// The recording with this id, if the project has it.
    public func recording(_ id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    /// The track with this id, if the project has it.
    public func track(_ id: UUID) -> Track? {
        tracks.first { $0.id == id }
    }

    /// The clip with this id, on whichever track it is.
    public func clip(_ id: UUID) -> Clip? {
        for track in tracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }

    // MARK: Positions, in song seconds

    /// Where a segment starts. Nil when the project does not have its recording.
    public func start(of segment: Segment) -> Double? {
        recording(segment.recordingID)?
            .songTime(ofSample: segment.inSample, offsetSamples: segment.offsetSamples)
    }

    /// Where a segment ends. Nil when the project does not have its recording.
    public func end(of segment: Segment) -> Double? {
        recording(segment.recordingID)?
            .songTime(ofSample: segment.outSample, offsetSamples: segment.offsetSamples)
    }

    /// Where a clip starts: the start of its first segment. Nil for a clip
    /// with no segments, or whose recording the project does not have.
    public func start(of clip: Clip) -> Double? {
        clip.segments.first.flatMap { start(of: $0) }
    }

    /// Where a clip ends: the end of its last segment. Nil for a clip with no
    /// segments, or whose recording the project does not have.
    public func end(of clip: Clip) -> Double? {
        clip.segments.last.flatMap { end(of: $0) }
    }

    /// The clips of one track that have some part inside a stretch of the
    /// song, in the order the track holds them. A clip that only touches the
    /// stretch at an edge is not counted.
    public func clips(on trackID: UUID, overlapping range: Range<Double>) -> [Clip] {
        guard let track = track(trackID) else { return [] }
        return track.clips.filter { clip in
            guard let start = start(of: clip), let end = end(of: clip) else { return false }
            return start < range.upperBound && end > range.lowerBound
        }
    }

    /// The clips with these ids, on whatever track they are, in the order of the tracks.
    public func clips(_ ids: Set<UUID>) -> [Clip] {
        tracks.flatMap { track in track.clips.filter { ids.contains($0.id) } }
    }

    /// The clip on a track that a click at a moment in the song lands on, or nil when the track is empty there.
    /// Where clips lie on top of each other it is the one that starts last, because that is the one drawn in front.
    ///
    /// Only clips that are shown count: of several takes of a line that is the active one. A take that waits
    /// behind it is not drawn, so a click can never land on it.
    public func clip(on trackID: UUID, at seconds: Double) -> Clip? {
        guard let track = track(trackID) else { return nil }
        var found: (clip: Clip, start: Double)?
        for clip in track.clips where clip.isActiveTake {
            guard let start = start(of: clip), let end = end(of: clip), start <= seconds, seconds < end else { continue }
            if found.map({ start >= $0.start }) ?? true {
                found = (clip, start)
            }
        }
        return found?.clip
    }

    // MARK: Adding and removing

    /// Adds a recording, and one clip on the given track that plays the given
    /// samples of it: the part with the voice in it. The rest of the recording
    /// stays in its file, outside the clip.
    ///
    /// The clip becomes a new take of a line that is already on the track when it was aimed at that line: at
    /// where the line's shown clip starts, or at the place that clip was itself recorded from, within 50 ms
    /// (`lineToJoin`). Otherwise it is a line of its own. Either way it is the new clip that counts: every
    /// other line it covers part of gives way to it (`giveWay(to:peaks:)`).
    ///
    /// A new take starts with the correction of the take that was heard until now: its choice of Off, Lines
    /// or All, its strength, Stretch and its sub-beats, with the knobs of the track's Sound that take
    /// turned for itself, with that take's effects on the whole clip, under the same ids, and with what that
    /// take changed of its track's effects. So a new take is heard the way the line was set up. A clip on a new line starts with everything off, following its
    /// track.
    ///
    /// The samples are kept inside the recording.
    ///
    /// - Parameters:
    ///   - aim: where Max aimed the recording: the place it started, and where the playhead stood when
    ///     Record was pressed. A clip is cut to where the voice is and can start well away from both, so
    ///     this, and not the clip's start alone, says whether it is a take. Left out, only where the clip
    ///     starts is looked at.
    ///   - peaks: the highest sample of a stretch of a recording, so a clip that gives way stays as loud as
    ///     it was (see the top of `ProjectClipEdits.swift`).
    ///   - voices: which voice stands in for which recording on which track, so the safe limit is asked
    ///     about the sound each clip is heard from on its track (see the top of `ProjectClipEdits.swift`).
    /// - Returns: the id of the new clip, or nil, with nothing added, when the project has no such track.
    @discardableResult
    public mutating func addRecording(
        _ recording: Recording,
        samples: Range<Int>,
        asClipOn trackID: UUID,
        aim: RecordAim? = nil,
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices
    ) -> UUID? {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return nil }
        let first = min(max(samples.lowerBound, 0), recording.lengthSamples)
        let last = min(max(samples.upperBound, first), recording.lengthSamples)
        var clip = Clip(
            segments: [Segment(recordingID: recording.id, inSample: first, outSample: last)],
            recordPlace: aim?.place
        )
        recordings.append(recording)
        if let line = lineToJoin(onTrackAt: index, start: recording.songSample(ofSample: first), aim: aim) {
            clip.line = line
            // The takes are not put right yet, so the take that was heard until now still says so. When
            // several do, as while the passes of a loop recording are added one by one, they all have the
            // same values.
            let others = tracks[index].clips.filter { $0.line == line }
            if let heard = others.first(where: \.isActiveTake) ?? others.last {
                clip.takeCorrection(of: heard)
                clip.feel = heard.feel
                clip.knobs = heard.knobs
                // Only the effects on the whole clip: one on a stretch is on that take's own words.
                clip.effects = heard.effects.filter { $0.span == nil }
                clip.effectChanges = heard.effectChanges
            }
        }
        tracks[index].clips.append(clip)
        giveWay(to: clip.id, peaks: peaks, voices: voices)
        return clip.id
    }

    /// Removes these clips from their tracks. Their recordings stay in the
    /// project, so an undo can bring the clips back with their sound.
    public mutating func removeClips(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for index in tracks.indices {
            tracks[index].clips.removeAll { ids.contains($0.id) }
        }
    }

    /// Mutes the clips with these ids, or lets them be heard again.
    public mutating func setClips(_ ids: Set<UUID>, muted: Bool) {
        for track in tracks.indices {
            for clip in tracks[track].clips.indices where ids.contains(tracks[track].clips[clip].id) {
                tracks[track].clips[clip].muted = muted
            }
        }
    }

    /// The recordings no clip plays any part of, in the order the project
    /// holds them. Their files can be removed when the project closes.
    public func unusedRecordingIDs() -> [UUID] {
        var used = Set<UUID>()
        for track in tracks {
            for clip in track.clips {
                for segment in clip.segments { used.insert(segment.recordingID) }
            }
        }
        return recordings.map(\.id).filter { !used.contains($0) }
    }
}

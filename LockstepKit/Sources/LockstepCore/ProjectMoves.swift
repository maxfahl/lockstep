import Foundation

/// A move of clips: how far along the song, and how many tracks down.
///
/// It is what a move was asked to be, or what was left of it after the limits. Nothing is moved by making one.
public struct ClipMove: Sendable, Equatable {
    /// How far along the song, in samples. Negative is toward the start of the song.
    public var samples: Int
    /// How many tracks down. Negative is up.
    public var trackSteps: Int

    public init(samples: Int = 0, trackSteps: Int = 0) {
        self.samples = samples
        self.trackSteps = trackSteps
    }

    /// True when it moves nothing, in time or between tracks.
    public var isNothing: Bool {
        samples == 0 && trackSteps == 0
    }
}

/// Moving clips along the song and between tracks, and naming them.
///
/// The rules:
///
/// - A move adds the same number of samples to `offsetSamples` of every segment of a clip. Nothing else about
///   the clip changes, and its recording is not touched.
/// - Every take of a moved clip moves with it, in time and to the other track, so a line and its takes stay
///   together.
/// - No clip may start before what is left of the song or end after it (`keptSamples`): where the song is cut
///   away nothing is played, so a clip is not moved into it. A move that would is made shorter for all the
///   clips together, so they keep their distances to each other.
/// - A step to another track that would take any of the clips above the first track or below the last is not
///   made at all, for any of them. The move in time is still made.
/// - A clip is at its recorded place when its first segment's `offsetSamples` is 0.
/// - A clip that lands with its start within 50 ms of where another line's shown clip starts becomes a take of
///   that line, with all its own takes, and is the one shown. Whatever else it lands on gives way to it: the
///   clip that was moved wins (`ProjectGivingWay.swift`).
///
/// Each function changes the project and nothing else. The app runs it inside `ProjectStore.edit`, which makes
/// it one undo step, the clips that gave way included.
///
///     let move = store.project.allowedMove(of: selected, bySamples: delta, trackSteps: rows)
///     guard !move.isNothing else { return }
///     store.edit("Move Clip") {
///         $0.moveClips(selected, bySamples: move.samples, trackSteps: move.trackSteps, peaks: peaks)
///     }
extension Project {
    // MARK: Asking

    /// How far a clip is from where it was recorded, in samples: its first segment's `offsetSamples`.
    /// 0 means it is at its recorded place. Negative means it now sits earlier in the song.
    public func recordedOffset(of clip: Clip) -> Int {
        clip.segments.first?.offsetSamples ?? 0
    }

    /// Where a clip would start if it were back where it was recorded, in song seconds. Nil for a clip with no
    /// segments, or whose recording the project does not have.
    ///
    /// This is where the faint mark of a dragged clip is drawn, and the time the clip snaps back to.
    public func recordedStart(of clip: Clip) -> Double? {
        clip.segments.first.flatMap { segment in
            recording(segment.recordingID)?.songTime(ofSample: segment.inSample)
        }
    }

    /// The clips that move when these clips are moved: the clips themselves and every take of their lines.
    /// Ids the project has no clip for are left out.
    public func clipsMovingTogether(with ids: Set<Clip.ID>) -> Set<Clip.ID> {
        var together = Set<Clip.ID>()
        for id in ids where !together.contains(id) {
            together.formUnion(takes(of: id).map(\.id))
        }
        return together
    }

    /// What is left of a move of these clips, and of their takes, after the limits. `moveClips` makes exactly
    /// this move, so a drag can ask here where the clips would land before anything is changed.
    ///
    /// - The move in time is made shorter until no clip starts before what is left of the song or ends after
    ///   it. A clip that already lies partly outside it, because the song was cut afterwards, may stay there
    ///   and may move inward, but not further out.
    /// - The step between tracks is kept as asked when every clip has a track to land on, and is 0 otherwise.
    public func allowedMove(of ids: Set<Clip.ID>, bySamples delta: Int, trackSteps: Int) -> ClipMove {
        allowedMove(ofAll: clipsMovingTogether(with: ids), bySamples: delta, trackSteps: trackSteps)
    }

    // MARK: Changing

    /// Moves these clips, and every take of their lines, `delta` samples along the song and `trackSteps` tracks
    /// down (negative: up). The limits of `allowedMove(of:bySamples:trackSteps:)` apply.
    ///
    /// A clip that changes track is put last in its new track's list, and clips that go together keep their
    /// order. Its name, volume, mute and active flag go with it.
    ///
    /// Where the clips land, they become takes of a line whose shown clip starts where they do, and every
    /// other line they cover part of gives way (`land`).
    ///
    /// A clip that comes to another track follows that track's Voice from then on, as it follows its Sound.
    ///
    /// - Parameters:
    ///   - peaks: the highest sample of a stretch of a recording, so a clip that gives way stays as
    ///     loud as it was (see the top of `ProjectClipEdits.swift`).
    ///   - voices: which voice stands in for which recording on which track, so the safe limit is asked
    ///     about the sound each clip is heard from on its track (see the top of `ProjectClipEdits.swift`).
    /// - Returns: the move that was made. It `isNothing` when nothing changed, so the app can leave out the
    ///   undo step.
    @discardableResult
    public mutating func moveClips(
        _ ids: Set<Clip.ID>,
        bySamples delta: Int,
        trackSteps: Int,
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices
    ) -> ClipMove {
        let moving = clipsMovingTogether(with: ids)
        let move = allowedMove(ofAll: moving, bySamples: delta, trackSteps: trackSteps)
        guard !move.isNothing else { return move }

        if move.samples != 0 {
            for track in tracks.indices {
                for clip in tracks[track].clips.indices where moving.contains(tracks[track].clips[clip].id) {
                    for segment in tracks[track].clips[clip].segments.indices {
                        tracks[track].clips[clip].segments[segment].offsetSamples += move.samples
                    }
                }
            }
        }

        if move.trackSteps != 0 {
            // Everything is lifted off first and put down after, so a clip that lands on a track further down
            // is not picked up a second time when the loop reaches that track.
            var lifted: [(target: Int, clips: [Clip])] = []
            for track in tracks.indices {
                let going = tracks[track].clips.filter { moving.contains($0.id) }
                guard !going.isEmpty else { continue }
                tracks[track].clips.removeAll { moving.contains($0.id) }
                lifted.append((track + move.trackSteps, going))
            }
            for (target, clips) in lifted {
                tracks[target].clips.append(contentsOf: clips)
            }
        }
        land(moving, peaks: peaks, voices: voices)
        return move
    }

    /// Gives a clip a name. Spaces and line breaks around the name are dropped first. When nothing is left the
    /// clip has no name any more, and its bar shows its text again.
    ///
    /// Only this clip is named: every take of a line has a name of its own.
    ///
    /// - Returns: false when that is the name the clip already has, or the project has no such clip.
    @discardableResult
    public mutating func renameClip(_ id: Clip.ID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName: String? = trimmed.isEmpty ? nil : trimmed
        for track in tracks.indices {
            guard let clip = tracks[track].clips.firstIndex(where: { $0.id == id }) else { continue }
            guard tracks[track].clips[clip].name != newName else { return false }
            tracks[track].clips[clip].name = newName
            return true
        }
        return false
    }

    // MARK: Working out the limits

    /// The limits for a set of clips that already holds every take that moves along.
    private func allowedMove(ofAll moving: Set<Clip.ID>, bySamples delta: Int, trackSteps: Int) -> ClipMove {
        guard !moving.isEmpty else { return ClipMove() }
        let known = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // The stretch of the song the clips cover together, in whole samples by the position rule the player
        // uses, and the first and last track any of them is on.
        var earliestStart: Int?
        var latestEnd: Int?
        var topTrack: Int?
        var bottomTrack: Int?
        for (trackIndex, track) in tracks.enumerated() {
            for clip in track.clips where moving.contains(clip.id) {
                topTrack = topTrack ?? trackIndex
                bottomTrack = trackIndex
                guard let first = clip.segments.first, let last = clip.segments.last,
                      let firstRecording = known[first.recordingID], let lastRecording = known[last.recordingID]
                else { continue }
                let start = firstRecording.songSample(ofSample: first.inSample, offsetSamples: first.offsetSamples)
                let end = lastRecording.songSample(ofSample: last.outSample, offsetSamples: last.offsetSamples)
                earliestStart = min(earliestStart ?? start, start)
                latestEnd = max(latestEnd ?? end, end)
            }
        }

        // Standing still is always allowed, also for a clip that already reaches outside what is left of the
        // song. With no clip that has a place in the song there is nothing to keep inside it, and nothing is
        // moved in time.
        var samples = 0
        if let earliestStart, let latestEnd {
            let kept = keptSamples
            let furthestBack = min(0, kept.lowerBound - earliestStart)
            let furthestOn = max(0, kept.upperBound - latestEnd)
            samples = min(max(delta, furthestBack), furthestOn)
        }

        var steps = 0
        if let topTrack, let bottomTrack, trackSteps != 0,
           trackSteps >= -topTrack, trackSteps <= tracks.count - 1 - bottomTrack {
            steps = trackSteps
        }
        return ClipMove(samples: samples, trackSteps: steps)
    }
}

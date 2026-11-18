import Foundation

/// Takes: clips of one line on a track, of which exactly one is drawn and heard.
///
/// The rules, as Max asked for them on 13 November 2026:
///
/// - Every clip keeps the line it belongs to (`Clip.line`). The clips of one track with the same line are
///   takes of each other. Nothing else makes a take: clips that lie on top of each other are not takes for
///   that reason, and trimming, cutting or correcting a clip never moves it to another line.
/// - A clip joins a line when it comes to start within 50 ms (`takeReachSamples`) of where the shown clip of
///   that line starts, on the same track: by being recorded there, as a pass of a loop recording, or by being
///   moved there. A recording is judged by the place Max aimed at (`RecordAim`), because its clip is cut to
///   where the voice is and can start well before or after that place.
/// - Anything else that comes to lie on a clip of another line wins, and the other line gives way
///   (`ProjectGivingWay.swift`).
/// - In every line exactly one clip has `isActiveTake`. A clip with no other takes always has it.
/// - Takes are counted in the order they were recorded, from 1: the order of the recording of a clip's first
///   segment in `recordings`, which grows at its end with every new recording.
///
/// A project saved before lines were kept gets them once, when it is read, by the rule of that time: two
/// clips were takes of each other when they overlapped by more than half of the shorter one (`giveLines`).
///
///     project.takes(of: clip.id).map(\.id)   // every take of the line, oldest first
///     project.takeNumber(of: clip.id)        // 3
///     project.takeCount(of: clip.id)         // 5, so the clip's bar shows "3/5"
///     if let next = project.nextTake(of: clip.id) {
///         store.edit("Next Take") { $0.chooseTake(next, peaks: peaks) }
///     }

/// Where a recording was aimed: what decides whether it becomes a new take of a line that is already there.
public struct RecordAim: Sendable, Equatable {
    /// The place recording started, in song seconds: the beat Record aimed at, or the loop's start.
    public var place: Double
    /// Where the playhead stood when Record was pressed, in song seconds. Nil when it had no say: with Loop
    /// on, recording starts at the loop's start wherever the playhead is.
    public var playhead: Double?

    public init(place: Double, playhead: Double? = nil) {
        self.place = place
        self.playhead = playhead
    }
}

extension Project {
    // MARK: Asking

    /// The groups of takes on one track: every line that two or more of its clips belong to. Each group is in
    /// the order its takes were recorded, and the groups are in the order the track holds the first clip of
    /// each. A clip that has no other takes is in none of them.
    ///
    /// This is the one to use when all clips of a track are needed at once, such as when a track is drawn.
    public func takeGroups(on trackID: UUID) -> [[Clip]] {
        guard let track = track(trackID) else { return [] }
        return Self.takeGroupIndices(in: track, order: recordingOrder(of: [track]))
            .map { group in group.map { track.clips[$0] } }
    }

    /// Every take of the line this clip belongs to, the clip itself included, in the order they were recorded.
    /// A clip with no other takes gives just itself. Empty when the project has no such clip.
    public func takes(of clipID: UUID) -> [Clip] {
        guard let place = takePlace(of: clipID) else { return [] }
        return place.group.map { tracks[place.track].clips[$0] }
    }

    /// Which take of its line this clip is, counted from 1 in the order they were recorded. A clip with no other
    /// takes is number 1. Nil when the project has no such clip.
    public func takeNumber(of clipID: UUID) -> Int? {
        takePlace(of: clipID).map { $0.position + 1 }
    }

    /// How many takes the line of this clip has, the clip itself included. 1 for a clip with no other takes, and
    /// 0 when the project has no such clip.
    public func takeCount(of clipID: UUID) -> Int {
        takePlace(of: clipID)?.group.count ?? 0
    }

    /// The take recorded after this one, or the first one when this is the last. Nil when the clip has no other
    /// takes, or the project has no such clip. Nothing is changed: hand the answer to `chooseTake(_:peaks:)`.
    public func nextTake(of clipID: UUID) -> UUID? {
        take(steps: 1, from: clipID)
    }

    /// The take recorded before this one, or the last one when this is the first. Nil when the clip has no other
    /// takes, or the project has no such clip. Nothing is changed: hand the answer to `chooseTake(_:peaks:)`.
    public func previousTake(of clipID: UUID) -> UUID? {
        take(steps: -1, from: clipID)
    }

    // MARK: Changing

    /// Makes this clip the take that is drawn and heard, and every other take of its line a waiting one.
    /// Does nothing when the project has no such clip.
    ///
    /// No other clip is touched. When Max chooses a take, use `chooseTake(_:peaks:)`, which also makes
    /// what the take covers of other lines give way.
    public mutating func setActiveTake(_ clipID: UUID) {
        guard let place = takePlace(of: clipID) else { return }
        for (position, index) in place.group.enumerated() {
            tracks[place.track].clips[index].isActiveTake = position == place.position
        }
    }

    /// Removes every other take of this clip's line and keeps this clip, as the active take. Their recordings stay
    /// in the project, so an undo can bring them back. Does nothing when the clip has no other takes.
    public mutating func deleteOtherTakes(of clipID: UUID) {
        guard let place = takePlace(of: clipID), place.group.count > 1 else { return }
        let clips = tracks[place.track].clips
        removeClips(Set(place.group.map { clips[$0].id }.filter { $0 != clipID }))
        setActiveTake(clipID)
    }

    /// Makes the take rule true again: exactly one active take in every line, and every clip that has no
    /// other takes active.
    ///
    /// A line with one active take keeps it. A line with none, or with several, gets the take recorded last.
    /// That one rule covers the cases:
    /// - a new recording that joined a line: it is active like every new clip, so the line has two, and the
    ///   new one is the last recorded;
    /// - the active take is deleted: none is left, and the latest of the rest comes forward;
    /// - a project saved before takes existed, where clips on top of each other were all active.
    ///
    /// `ProjectStore` calls it after every edit and when a project is opened. Calling it on a project that is
    /// already right changes nothing.
    public mutating func normalizeTakes() {
        // One table for all the tracks: it is asked after every edit, for every track.
        let order = recordingOrder(of: tracks)
        for track in tracks.indices {
            let clips = tracks[track].clips
            var active = [Bool](repeating: true, count: clips.count)
            for group in Self.takeGroupIndices(in: tracks[track], order: order) {
                let chosen = group.filter { clips[$0].isActiveTake }
                let kept = chosen.count == 1 ? chosen[0] : group[group.count - 1]
                for index in group { active[index] = index == kept }
            }
            for index in clips.indices where clips[index].isActiveTake != active[index] {
                tracks[track].clips[index].isActiveTake = active[index]
            }
        }
    }

    // MARK: Working out the groups

    /// Where a clip is among its takes: its track, its group as places in the track's list of clips in the order
    /// recorded (just the clip itself when it has no other takes), and its own place in that group.
    private func takePlace(of clipID: UUID) -> (track: Int, group: [Int], position: Int)? {
        for (trackIndex, track) in tracks.enumerated() {
            guard let clipIndex = track.clips.firstIndex(where: { $0.id == clipID }) else { continue }
            let group = Self.takeGroupIndices(in: track, holding: clipIndex, order: recordingOrder(of: [track]))
            return (trackIndex, group, group.firstIndex(of: clipIndex) ?? 0)
        }
        return nil
    }

    /// The take `steps` places after this clip in its group, going round at the ends.
    private func take(steps: Int, from clipID: UUID) -> UUID? {
        guard let place = takePlace(of: clipID), place.group.count > 1 else { return nil }
        let count = place.group.count
        let position = ((place.position + steps) % count + count) % count
        return tracks[place.track].clips[place.group[position]].id
    }

    /// Where a recording stands among the recordings, for the recordings that can decide the order of the
    /// takes on these tracks: the ones a line with two or more clips starts with. It is the first place of
    /// each id in `recordings`.
    ///
    /// Only those are looked up, and the search stops when all are found. A table of every recording, made
    /// for every question, was a large part of what an edit cost in a project with several hundred
    /// recordings (15 November 2026). `ProjectLookup` has the table for whoever asks about many clips.
    private func recordingOrder(of tracks: [Track]) -> (UUID) -> Int? {
        var wanted: Set<UUID> = []
        for track in tracks where track.clips.count > 1 {
            var lines: Set<UUID> = []
            var shared: Set<UUID> = []
            for clip in track.clips where !lines.insert(clip.line).inserted {
                shared.insert(clip.line)
            }
            guard !shared.isEmpty else { continue }
            for clip in track.clips where shared.contains(clip.line) {
                if let first = clip.segments.first { wanted.insert(first.recordingID) }
            }
        }
        var order: [UUID: Int] = [:]
        if !wanted.isEmpty {
            for (index, recording) in recordings.enumerated() where wanted.contains(recording.id) {
                guard order[recording.id] == nil else { continue }
                order[recording.id] = index
                if order.count == wanted.count { break }
            }
        }
        return { order[$0] }
    }

    /// The take groups of a track, as places in its list of clips: every line that two or more of its clips
    /// belong to. Each group is in the order recorded, and the groups are in the order the track holds the
    /// first clip of each.
    ///
    /// Two clips that play the same recording (a duplicated clip), or whose recording the project does not
    /// have, keep the order the track holds them in.
    ///
    /// - Parameter order: where a recording stands among the project's recordings, or nil when the project
    ///   does not have it (`recordingOrder(of:)`, or `ProjectLookup.recordingOrder(_:)`).
    static func takeGroupIndices(in track: Track, order: (UUID) -> Int?) -> [[Int]] {
        guard track.clips.count > 1 else { return [] }
        var groups: [[Int]] = []
        var groupOfLine: [UUID: Int] = [:]
        for (index, clip) in track.clips.enumerated() {
            if let existing = groupOfLine[clip.line] {
                groups[existing].append(index)
            } else {
                groupOfLine[clip.line] = groups.count
                groups.append([index])
            }
        }
        return groups.filter { $0.count > 1 }.map { sorted($0, in: track, order: order) }
    }

    /// The take group of one clip of a track, given by its place in the track's list: the places of every
    /// clip of its line in the order recorded, or just the clip's own place when it has no other takes.
    static func takeGroupIndices(in track: Track, holding clipIndex: Int, order: (UUID) -> Int?) -> [Int] {
        let line = track.clips[clipIndex].line
        let group = track.clips.indices.filter { track.clips[$0].line == line }
        return group.count > 1 ? sorted(group, in: track, order: order) : [clipIndex]
    }

    /// The clips of one line, as places in the track's list, in the order they were recorded.
    private static func sorted(_ group: [Int], in track: Track, order: (UUID) -> Int?) -> [Int] {
        let recorded = group.map { index in
            (place: track.clips[index].segments.first.flatMap { order($0.recordingID) } ?? Int.max, index: index)
        }
        return recorded.sorted { ($0.place, $0.index) < ($1.place, $1.index) }.map(\.index)
    }
}

// MARK: - Joining a line

extension Project {
    /// How near the start of a line's shown clip something must come to become a take of that line: 50 ms,
    /// in samples. The keys that jump between clips put the playhead exactly on a clip's start, and this
    /// covers a click close to it.
    public static let takeReachSamples = 2_400

    /// The samples of the song a clip covers, from the start of its first segment to the end of its last.
    /// Nil for a clip with no segments, or whose recording the project does not have.
    func songSpan(of clip: Clip) -> Range<Int>? {
        Self.songSpan(of: clip, recording: recording)
    }

    /// The same, asking for each recording by its id. Whoever asks about every clip of a track hands in
    /// the recordings those clips play (`recordings(playedBy:)`), so the project's list of recordings is
    /// gone through once and not twice for each clip: that search was most of the 90 ms a move or a paste
    /// of thirty clips took in a project with several hundred recordings (15 November 2026).
    static func songSpan(of clip: Clip, recording: (UUID) -> Recording?) -> Range<Int>? {
        guard let first = clip.segments.first, let last = clip.segments.last,
              let firstRecording = recording(first.recordingID), let lastRecording = recording(last.recordingID)
        else { return nil }
        let start = firstRecording.songSample(ofSample: first.inSample, offsetSamples: first.offsetSamples)
        let end = lastRecording.songSample(ofSample: last.outSample, offsetSamples: last.offsetSamples)
        return start..<max(start, end)
    }

    /// The recordings that clips play, by id: for each id the first recording the project has with it,
    /// as `recording(_:)` finds it. A recording the project does not have is not in the answer.
    func recordings(playedBy clips: [Clip]) -> [UUID: Recording] {
        var wanted: Set<UUID> = []
        for clip in clips {
            for segment in clip.segments { wanted.insert(segment.recordingID) }
        }
        var found: [UUID: Recording] = [:]
        guard !wanted.isEmpty else { return found }
        for index in recordings.indices where wanted.contains(recordings[index].id) {
            guard found[recordings[index].id] == nil else { continue }
            found[recordings[index].id] = recordings[index]
            if found.count == wanted.count { break }
        }
        return found
    }

    /// The place Record aimed at when a clip was recorded, where that place is now, in song seconds: a clip
    /// that was moved has taken it along. Nil for a clip that has none (`Clip.recordPlace`).
    public func recordPlace(of clip: Clip) -> Double? {
        clip.recordPlace.map { $0 + Double(recordedOffset(of: clip)) / Lockstep.sampleRate }
    }

    /// The line on a track that a clip put at a place becomes a take of, or nil when it starts a line of
    /// its own.
    ///
    /// Only the clips that are shown say where their lines are. Of several lines within reach the nearest
    /// one is joined.
    ///
    /// - Parameters:
    ///   - start: the sample of the song the clip starts on. It is held against where each shown clip starts.
    ///   - aim: where the clip was aimed, when it is a recording. Its place and its playhead are held
    ///     against where each shown clip starts and against the place that clip was itself recorded from.
    ///   - lines: lines that are not joined: the clip's own, and the lines that move along with it.
    ///   - known: the recordings the track's clips play (`recordings(playedBy:)`), when the caller has them.
    func lineToJoin(
        onTrackAt track: Int,
        start: Int?,
        aim: RecordAim? = nil,
        notOf lines: Set<UUID> = [],
        known: [UUID: Recording]? = nil
    ) -> UUID? {
        let known = known ?? recordings(playedBy: tracks[track].clips)
        func sample(_ seconds: Double) -> Int? {
            let sample = (seconds * Lockstep.sampleRate).rounded()
            return sample.isFinite && abs(sample) < 1e15 ? Int(sample) : nil
        }
        let aims = [aim?.place, aim?.playhead].compactMap { $0.flatMap(sample) }
        var best: (line: UUID, distance: Int)?
        for clip in tracks[track].clips where clip.isActiveTake && !lines.contains(clip.line) {
            guard let span = Self.songSpan(of: clip, recording: { known[$0] }), !span.isEmpty else { continue }
            var distances = (aims + [start].compactMap { $0 }).map { abs($0 - span.lowerBound) }
            if let recorded = recordPlace(of: clip).flatMap(sample) {
                distances += aims.map { abs($0 - recorded) }
            }
            guard let nearest = distances.min(), nearest <= Project.takeReachSamples else { continue }
            if best.map({ nearest < $0.distance }) ?? true {
                best = (clip.line, nearest)
            }
        }
        return best?.line
    }
}

// MARK: - Projects saved before lines were kept

extension Project {
    /// Gives the clips of a project saved before lines were kept their lines, by the rule of that time: two
    /// clips on a track were takes of each other when they overlapped by more than half of the shorter one's
    /// length, and a line was everything that hung together that way. So every take Max had then is still a
    /// take of the same line, and the clip that was shown is still the one shown.
    ///
    /// - Parameter needsLine: for each track, which of its clips were saved without a line. Only those are
    ///   given one. A clip that was saved with a line keeps it.
    static func giveLines(to tracks: inout [Track], needsLine: [[Bool]], recordings: [Recording]) {
        let known = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (track, needs) in needsLine.enumerated() where track < tracks.count {
            // Every clip that needs a line, with the samples of the song it covers. A clip with no place (no
            // segments, or a recording the project does not have) or with no length stays a line of its own.
            var placed: [(index: Int, span: Range<Int>)] = []
            for (index, clip) in tracks[track].clips.enumerated() where index < needs.count && needs[index] {
                guard let first = clip.segments.first, let last = clip.segments.last,
                      let firstRecording = known[first.recordingID], let lastRecording = known[last.recordingID]
                else { continue }
                let start = firstRecording.songSample(ofSample: first.inSample, offsetSamples: first.offsetSamples)
                let end = lastRecording.songSample(ofSample: last.outSample, offsetSamples: last.offsetSamples)
                guard end > start else { continue }
                placed.append((index, start..<end))
            }
            placed.sort { ($0.span.lowerBound, $0.index) < ($1.span.lowerBound, $1.index) }
            for earlier in placed.indices {
                for later in placed.indices.dropFirst(earlier + 1) {
                    // Sorted by start: once one starts after this clip has ended, the rest do too.
                    guard placed[later].span.lowerBound < placed[earlier].span.upperBound else { break }
                    let overlap = min(placed[earlier].span.upperBound, placed[later].span.upperBound)
                        - placed[later].span.lowerBound
                    let shorter = min(placed[earlier].span.count, placed[later].span.count)
                    // More than half of the shorter one, without doubling a number that may be large.
                    guard overlap > shorter - overlap else { continue }
                    // The two lines become one: every clip of the later one's line gets the earlier one's.
                    let joining = tracks[track].clips[placed[later].index].line
                    let joined = tracks[track].clips[placed[earlier].index].line
                    guard joining != joined else { continue }
                    for clip in placed where tracks[track].clips[clip.index].line == joining {
                        tracks[track].clips[clip.index].line = joined
                    }
                }
            }
        }
    }
}

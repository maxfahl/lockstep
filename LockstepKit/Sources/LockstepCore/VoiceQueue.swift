import Foundation

// Which voices are made next, and how far a track has come.
//
//     let next = VoiceQueue.order(project, playhead: seconds) { key in voicesInMemoryOrOnDisk.contains(key) }
//     // next[0] is the voice to make first: `VoiceKey(recordingID:knobs:way:)`
//
//     let progress = VoiceQueue.progress(of: track.id, in: project) { key in voicesInMemory[key] != nil }
//     // "Making the voice: \(progress.done) of \(progress.clips) clips"

/// The order voices are made in, and how many clips of a track have theirs.
///
/// A voice is wanted for every recording that a clip plays on a track whose Voice is heard
/// (`TrackVoice.isHeard`): the recording made again with that track's knobs. It is named by its `VoiceKey`,
/// which is also what its file is named by. A track without a Voice, with its Voice off, or with both knobs
/// in the middle wants nothing.
///
/// Both functions ask the same question of whoever keeps the voices, `isThere`, so the count in the panel and
/// the queue behind it can never disagree. They do not look at `TrackVoices`: while a new setting is made,
/// the voice of the setting before it stands in there, and that is not the voice that is wanted.
public enum VoiceQueue {
    /// How far the voices of one track have come.
    public struct Progress: Sendable, Equatable {
        /// How many of the track's shown clips have every voice they need.
        public var done: Int
        /// How many shown clips the track has that need a voice at all.
        public var clips: Int

        public init(done: Int, clips: Int) {
            self.done = done
            self.clips = clips
        }

        /// Whether nothing is left to make.
        public var isComplete: Bool { done >= clips }
    }

    /// The voices that are wanted and not there, in the order to make them.
    ///
    /// - First those of the shown clips: the take of each line that is drawn and heard. A muted clip and a
    ///   clip on a muted track count too. A mute says what is heard right now, and unmuting should not start
    ///   a making.
    ///   - The clip under the playhead first, then the clips after it by how soon they start.
    ///   - Then the clips that ended before the playhead, the nearest first.
    /// - Then those of the takes that wait behind a shown clip, by the same rule.
    /// - Clips that are equally far are taken in the order of the tracks and of each track's clips, and the
    ///   recordings of a joined clip in the order of its segments.
    /// - A voice is in the list once, at the first place it is wanted, however many clips play its recording.
    ///   The same recording on two tracks with different settings is two voices, and with the same setting
    ///   one.
    ///
    /// It is worked out again on every pass through the clips, so moving the playhead changes what comes
    /// next. A project in which no track's Voice is heard costs one look at each track.
    ///
    /// - Parameters:
    ///   - project: the project as it is now.
    ///   - playhead: where the playhead is, in song seconds.
    ///   - way: how the voices of a track's Voice are made, or nil when none is wanted for that track in
    ///     this way. Left out, it is the Fast way for every track. Whoever makes Natural voices asks again
    ///     with the Natural way for the tracks that have it on, and gets the same order.
    ///   - isThere: whether a voice is made already, or needs no making. Left out, none is.
    public static func order(
        _ project: Project,
        playhead: Double,
        way: (TrackVoice) -> VoiceWay? = { _ in .fast },
        isThere: (VoiceKey) -> Bool = { _ in false }
    ) -> [VoiceKey] {
        guard project.tracks.contains(where: { $0.voice?.isHeard == true }) else { return [] }
        let known = Dictionary(project.recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        /// One clip that wants voices, and where it stands in the order.
        struct Asking {
            var keys: [VoiceKey]
            /// 0 for a shown clip, 1 for a take that waits.
            var waits: Int
            /// 0 for a clip under or after the playhead, 1 for one that ended before it.
            var behind: Int
            /// How far from the playhead, in seconds.
            var distance: Double
            /// The place it was found at, which settles what is equally far.
            var found: Int
        }
        var asking: [Asking] = []
        for track in project.tracks {
            guard let voice = track.voice, voice.isHeard, let way = way(voice) else { continue }
            for clip in track.clips {
                // The clip's voices, and where it lies in the song: from the start of the first segment
                // whose recording the project has to the end of the last. A segment of a recording the
                // project does not have plays nothing and wants nothing.
                var keys: [VoiceKey] = []
                var start = Double.infinity
                var end = -Double.infinity
                for segment in clip.segments {
                    guard let recording = known[segment.recordingID] else { continue }
                    let key = VoiceKey(recordingID: recording.id, knobs: voice.knobs, way: way)
                    if !keys.contains(key) { keys.append(key) }
                    start = min(start, recording.songTime(ofSample: segment.inSample, offsetSamples: segment.offsetSamples))
                    end = max(end, recording.songTime(ofSample: segment.outSample, offsetSamples: segment.offsetSamples))
                }
                guard !keys.isEmpty else { continue }
                let isBehind = end <= playhead
                asking.append(Asking(
                    keys: keys,
                    waits: clip.isActiveTake ? 0 : 1,
                    behind: isBehind ? 1 : 0,
                    distance: isBehind ? playhead - end : max(start - playhead, 0),
                    found: asking.count
                ))
            }
        }
        asking.sort { ($0.waits, $0.behind, $0.distance, $0.found) < ($1.waits, $1.behind, $1.distance, $1.found) }

        var order: [VoiceKey] = []
        var seen: Set<VoiceKey> = []
        for clip in asking {
            for key in clip.keys where seen.insert(key).inserted && !isThere(key) {
                order.append(key)
            }
        }
        return order
    }

    /// How many of a track's shown clips have every voice they need, of how many: what the panel's line
    /// says while voices are made ("Making the voice: 3 of 12 clips").
    ///
    /// A clip counts as done when the voice of every recording it plays is there. So the two pieces of a
    /// split line, which play one recording, are two clips that are done at the same moment. The takes that
    /// wait are not counted: they are made after everything that is shown, and the line is about what Max
    /// can hear.
    ///
    /// Nothing of nothing for a track whose Voice is not heard, and for one the project does not have.
    ///
    /// - Parameters:
    ///   - way: as for `order`. Left out, the Fast way.
    ///   - isThere: whether a voice is made and can be heard. For the panel that is "in memory": a voice
    ///     that is on disk and still being read is not heard yet.
    public static func progress(
        of trackID: Track.ID,
        in project: Project,
        way: (TrackVoice) -> VoiceWay? = { _ in .fast },
        isThere: (VoiceKey) -> Bool
    ) -> Progress {
        guard let track = project.tracks.first(where: { $0.id == trackID }),
              let voice = track.voice, voice.isHeard, let way = way(voice)
        else { return Progress(done: 0, clips: 0) }
        let held = Set(project.recordings.map(\.id))
        // Each voice is asked about once, however many clips play its recording.
        var answers: [UUID: Bool] = [:]
        var progress = Progress(done: 0, clips: 0)
        for clip in track.clips where clip.isActiveTake {
            let recordings = clip.segments.map(\.recordingID).filter { held.contains($0) }
            guard !recordings.isEmpty else { continue }
            progress.clips += 1
            let done = recordings.allSatisfy { id in
                if let answer = answers[id] { return answer }
                let answer = isThere(VoiceKey(recordingID: id, knobs: voice.knobs, way: way))
                answers[id] = answer
                return answer
            }
            if done { progress.done += 1 }
        }
        return progress
    }
}

import Foundation

/// One stretch of a recording to play: which samples of it, and when.
///
/// A list of these is the whole answer to "what is heard of the clips from here on". The player
/// plays exactly what the list says and decides nothing itself.
public struct ClipPiece: Sendable, Hashable {
    /// The recording the samples come from.
    public var recordingID: UUID
    /// The first sample of the recording to play. It lies inside the segment when playback
    /// starts in the middle of it.
    public var offset: Int
    /// How many samples after the play position the piece starts. Zero for a piece that is
    /// already sounding at the play position.
    public var startDelay: Int
    /// How many samples to play.
    public var length: Int
    /// How many samples of the piece's segment lie before the piece. Zero when the piece starts where its
    /// segment starts, and more when the play position fell inside the segment. The fade at a segment's start
    /// (`EdgeFade`) is measured from the segment's own first sample, so a piece that starts in the middle of
    /// its segment starts at full level.
    public var segmentBefore: Int
    /// How many samples of the piece's segment lie after the piece. Zero unless the sound was asked to end
    /// inside the segment. The fade at a segment's end is measured from the segment's own last sample.
    public var segmentAfter: Int
    /// How much louder or quieter than the recording the piece is played, in dB: the volume its clip is played
    /// with (`Clip.appliedGain`) plus its segment's own and its track's (`Track.gainDb`). 0 plays the samples
    /// as they are.
    public var gainDb: Double
    /// Whether the piece plays a clip's finished sound in place of the clip (`FinishedSounds`). `recordingID`
    /// is then the id of that sound among the finished sounds' samples, which are in stereo, and `offset`
    /// counts from its first sample. `segmentBefore` and `segmentAfter` say how much of the whole sound, tail
    /// included, lies before and after the piece. A finished piece gets no fades: the sound has its own edges.
    public var isFinished: Bool

    public init(
        recordingID: UUID,
        offset: Int,
        startDelay: Int,
        length: Int,
        segmentBefore: Int = 0,
        segmentAfter: Int = 0,
        gainDb: Double = 0,
        isFinished: Bool = false
    ) {
        self.recordingID = recordingID
        self.offset = offset
        self.startDelay = startDelay
        self.length = length
        self.segmentBefore = segmentBefore
        self.segmentAfter = segmentAfter
        self.gainDb = gainDb
        self.isFinished = isFinished
    }

    /// What every sample of the piece is multiplied by: `gainDb` as a factor. Exactly 1 for 0 dB.
    public var gain: Float {
        Float(pow(10, gainDb / 20))
    }

    /// How many samples the piece's whole segment has.
    public var segmentLength: Int {
        segmentBefore + length + segmentAfter
    }

    /// The samples of the row the piece is heard on, counted like `startDelay`.
    public var rowSamples: Range<Int> {
        startDelay..<(startDelay + max(length, 0))
    }

    /// What is left of the piece inside a stretch of the row, or nil when nothing of it lies there.
    ///
    /// The part still says where it lies in its segment (`segmentBefore`, `segmentAfter`), so it fades exactly
    /// as those samples of the whole piece do, and it is as loud. Whoever lays a row out again only where it
    /// changed (`OfflineMix.layAgain`) adds such parts, and gets the samples the whole pieces give there.
    public func cut(to stretch: Range<Int>) -> ClipPiece? {
        let from = max(startDelay, stretch.lowerBound)
        let to = min(startDelay + length, stretch.upperBound)
        guard to > from else { return nil }
        var part = self
        part.offset += from - startDelay
        part.segmentBefore += from - startDelay
        part.segmentAfter += startDelay + length - to
        part.startDelay = from
        part.length = to - from
        return part
    }
}

extension Recording {
    /// The one position rule in whole samples: the sample of the song on which a sample of this
    /// recording is heard, when a segment moved by `offsetSamples` plays it.
    ///
    /// Only the recording's own start is rounded, once. Everything else is added as whole
    /// samples, so two segments that touch inside the recording also touch in the song, with
    /// no sample lost or played twice at the cut.
    public func songSample(ofSample sample: Int, offsetSamples: Int = 0) -> Int {
        let origin = songTime(ofSample: 0) * Lockstep.sampleRate
        guard origin.isFinite, abs(origin) < 1e15 else { return offsetSamples + sample }
        return Int(origin.rounded()) + offsetSamples + sample
    }
}

extension Project {
    /// What is heard of the clips from a place in the song on.
    ///
    /// - A clip is heard when it is not muted, its track is not muted, and it is the active take
    ///   of its line (`isActiveTake`). The other takes of the line wait, silent, until one of them
    ///   is chosen. Which clips are takes of each other is not worked out here: the answer trusts
    ///   the flags, which `normalizeTakes()` keeps right after every edit and on opening.
    /// - Clips that overlap too little to be takes of each other are all heard.
    /// - A segment that ended before the play position, or starts at or after the end, is left
    ///   out. One that the play position falls inside is played from the right sample inside it.
    /// - A segment is kept inside its recording, and one whose recording the project does not
    ///   have is left out.
    /// - Every piece says how loud it is played (`gainDb`): the volume of its clip, held back by the safe limit
    ///   when the clip would otherwise distort (`Clip.appliedGain`), plus its segment's own. The limit needs the
    ///   highest sample of what each clip plays, which `peaks` gives.
    /// - The volume of the track (`Track.gainDb`) is added to every piece of the track's clips, after the safe
    ///   limit and not held back by it: it is a fader on top of the clips, for what is heard while playing and
    ///   recording. A clip that is exported alone is asked about with its track at 0 dB (`ClipExporter`).
    /// - The fades at segment edges are not in the samples either, because the answer holds no
    ///   samples. Each piece says how much of its segment lies before and after it
    ///   (`segmentBefore`, `segmentAfter`), and whoever makes the sound hands that to `EdgeFade`.
    ///
    /// - On a clip whose lines slide or whose syllables move (`Clip.hasTimingFix`), a segment that has a
    ///   tightened sound in `tightened` is played from
    ///   that sound in place of its recording: the piece names the sound's id, and counts its samples from the
    ///   sound's first one. How loud the piece is and how it fades are the same either way. Where it lies and
    ///   how long it is are the same too, unless a line slid out of the segment: the sound then starts that
    ///   much before the segment or ends that much after it (`TightenedSounds.Sound.leadSamples` and
    ///   `tailSamples`), and so does the piece, with its fades at the sound's own edges.
    ///
    /// - A clip that has a finished sound in `finished` is one piece for the whole clip, in place of a piece
    ///   for each segment (`ClipPiece.isFinished`). It starts on the sample the clip's first sound is on, where
    ///   the dry sound the finished one was made from starts (`ClipDry`), and lasts as long as that dry sound
    ///   plus the tail. It is as loud as the track's volume alone, because every volume of the clip is in the
    ///   sound already, and it has no fades. A play position inside it starts inside it, as for any piece. A
    ///   clip that is not heard has no piece, finished sound or not.
    ///
    /// - On a track whose Voice is heard, a segment whose recording has a voice in `voices` for that track is
    ///   played from the voice in place of the recording: the piece names the voice's id. Everything else
    ///   about the piece is the recording's, its offset, its length and its fades, because the voice is as
    ///   long as the recording and has every sample where the recording has it. A tightened sound comes
    ///   first: it was made from the voice already (`ClipTightening.Inputs.voices`). The clip's volume is
    ///   held back by the highest sample of the sound the clip is read from on its own track
    ///   (`TrackVoices.peaks(_:on:)`). The same recording on another track is played as that track says.
    ///
    /// - Parameters:
    ///   - playSample: the play position, as a sample of the song.
    ///   - endSample: where the sound ends, one past the last sample. Nil is the end of the song.
    ///   - peaks: the highest sample of a stretch of a recording (see `RecordingPeak`). Whoever makes sound
    ///     hands it in. Left out, no clip is held back by the safe limit.
    ///   - tightened: the tightened sounds there are, by clip and segment (see `TightenedSounds`). Left out,
    ///     or for a segment that is not in it, the recording is played as it is. The safe limit
    ///     is still measured on the recording, whose highest sample a tightened sound never passes.
    ///   - finished: the finished sounds there are, by clip (see `FinishedSounds`). Left out, or for a clip
    ///     that is not in it or no longer plays the pieces its sound was made from, the clip is played from
    ///     its segments, and the plan is what it was before a clip could have a finished sound.
    ///   - voices: which made voice stands in for which recording on which track (see `TrackVoices`). With
    ///     `.none` every clip is read from Max's own recordings and the plan is what it was before a track
    ///     could have a Voice. Never left out: which sound a clip is read from is always said.
    /// - Returns: the pieces in the order of the tracks, their clips and their segments.
    public func clipPlaybackPlan(
        from playSample: Int,
        to endSample: Int? = nil,
        peaks: RecordingPeak = Clip.unknownPeaks,
        tightened: TightenedSounds = .none,
        finished: FinishedSounds = .none,
        voices: TrackVoices
    ) -> [ClipPiece] {
        let end = endSample ?? songLengthSamples
        guard end > playSample else { return [] }
        let known = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pieces: [ClipPiece] = []
        for track in tracks where !track.muted {
            for clip in track.clips where !clip.muted && clip.isActiveTake {
                // A finished sound made from a voice that no longer stands in here is never heard: the clip
                // is played from its segments until its sound is made again.
                if let sound = finished.sound(for: clip, on: track, voices: voices) {
                    // The finished sound starts where the clip's first sound is heard.
                    let starts = clip.segments.indices.compactMap {
                        heardSegment($0, of: clip, on: track, recordings: known, tightened: tightened, voices: voices)?
                            .songStart
                    }
                    guard let songStart = starts.min() else { continue }
                    let whole = sound.drySamples + sound.tailSamples
                    let from = max(songStart, playSample)
                    let to = min(songStart + whole, end)
                    guard to > from else { continue }
                    pieces.append(ClipPiece(
                        recordingID: sound.id,
                        offset: from - songStart,
                        startDelay: from - playSample,
                        length: to - from,
                        segmentBefore: from - songStart,
                        segmentAfter: songStart + whole - to,
                        gainDb: track.gainDb,
                        isFinished: true
                    ))
                    continue
                }
                // The whole clip decides how far it may be raised, also when only a part of it is asked for. It
                // is asked about the sound the clip is read from on this track.
                let clipGainDb = clip.appliedGain(peaks: peaks, voices: voices, on: track).db
                for (index, segment) in clip.segments.enumerated() {
                    guard let heard = heardSegment(
                        index, of: clip, on: track, recordings: known, tightened: tightened, voices: voices
                    ) else { continue }
                    let from = max(heard.songStart, playSample)
                    let to = min(heard.songStart + heard.length, end)
                    guard to > from else { continue }
                    pieces.append(ClipPiece(
                        recordingID: heard.soundID,
                        offset: heard.soundOffset + (from - heard.songStart),
                        startDelay: from - playSample,
                        length: to - from,
                        // Where the piece lies in its segment, for the fades at the segment's edges.
                        segmentBefore: from - heard.songStart,
                        segmentAfter: heard.songStart + heard.length - to,
                        gainDb: clipGainDb + segment.gainDb + track.gainDb
                    ))
                }
            }
        }
        return pieces
    }

    /// Where one segment of a clip is heard in the song, and from which sound.
    private struct HeardSegment {
        /// The sound it is played from: the tightened sound that stands in for the segment, or else the voice
        /// that stands in for its recording on the clip's track, or else its recording.
        var soundID: UUID
        /// The sample of that sound that is heard on `songStart`.
        var soundOffset: Int
        /// The sample of the song its first sound is on.
        var songStart: Int
        /// How many samples of it are heard.
        var length: Int
    }

    /// Where segment `index` of a clip is heard, or nil when nothing of it is: the project does not have its
    /// recording, or it plays no sample of it.
    ///
    /// This is the one answer to where a segment lies. The pieces of a clip that is played from its segments
    /// are cut from it, and the first of these in the song is where a clip's finished sound starts.
    private func heardSegment(
        _ index: Int,
        of clip: Clip,
        on track: Track,
        recordings known: [UUID: Recording],
        tightened: TightenedSounds,
        voices: TrackVoices
    ) -> HeardSegment? {
        let segment = clip.segments[index]
        guard let recording = known[segment.recordingID] else { return nil }
        let length = max(recording.lengthSamples, 0)
        let first = min(max(segment.inSample, 0), length)
        let last = min(max(segment.outSample, first), length)
        // The tightened sound of this segment, if its clip asks for one and there is one that may be heard on
        // this track. Its sample `leadSamples` is the segment's `inSample`, where the recording's sample 0 is
        // its own start. One made from a voice that no longer stands in here is passed over, and the segment
        // is played from what stands in now, uncorrected until its sound is made again.
        let stand = clip.hasTimingFix
            ? tightened.sound(for: segment, at: index, of: clip, on: track, voices: voices)
            : nil
        // How far the sound reaches past the segment, where a line slid out of it. Only at an edge that the
        // segment really plays to.
        let lead = first == segment.inSample ? stand?.leadSamples ?? 0 : 0
        let tail = last == segment.outSample ? stand?.tailSamples ?? 0 : 0
        let heardLength = last - first + lead + tail
        guard heardLength > 0 else { return nil }
        return HeardSegment(
            // A voice is as long as its recording, so only the id differs: the offsets below hold for both.
            soundID: stand?.id ?? voices.soundID(forRecording: recording.id, on: track) ?? recording.id,
            soundOffset: stand.map { first - segment.inSample + $0.leadSamples - lead } ?? first,
            songStart: recording.songSample(ofSample: first, offsetSamples: segment.offsetSamples) - lead,
            length: heardLength
        )
    }
}

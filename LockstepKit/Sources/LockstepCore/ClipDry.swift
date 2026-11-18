import Foundation

/// One clip alone, and its dry sound: step 1 of making a clip's finished sound
/// (`FinishedSoundRenderer` does the rest).
///
///     let dry = ClipDry.render(
///         clip, in: project,
///         recordings: sounds,                               // the recordings' samples by recording id
///         peaks: recordingPeaks.lookup(in: sounds),         // for the safe limit, see `RecordingPeak`
///         edgeFadeMs: settings[.edgeFadeMs],
///         tightened: tightened,                             // their samples are in `recordings` too
///         voices: voices                                    // and so are the voices'. `.none`: Max's own
///     )
///     // dry.samples[0] is heard on sample dry.firstSample of the song
///
/// The dry sound is what a clip's finished sound is made from (`FinishedSoundRenderer.render`): the clip as it
/// is heard without a Sound on its track, mono, with one thing left out, the clip's own volume (`Clip.gainDb`),
/// which is applied after the voice chain. Everything else is in: the segments at their places, the fades at
/// their edges, the tightened sounds, each segment's own volume, and what Normalize set, held back by the safe
/// limit.
///
/// Which sound the clip is read from is said with `voices`. With the voices of the clip's track it is the
/// dry sound of the track's Voice, which is what the track's Sound and effects are put on. With `.none` it is
/// the dry sound of Max's own recordings, whatever Voice the clip's track has.
///
/// This is also the one way to ask about a clip alone. `ClipExporter` gets the clip it writes to a file from
/// `alone`, so a clip that is sent and a clip whose finished sound is made lie on the same sample of the song
/// and are made of the same pieces.
public enum ClipDry {
    /// The dry sound of a clip.
    public struct Sound: Sendable, Equatable {
        /// From the clip's first sound to its last, mono at 48,000 Hz.
        public var samples: [Float]
        /// The sample of the song on which `samples[0]` is heard.
        public var firstSample: Int

        public init(samples: [Float], firstSample: Int) {
            self.samples = samples
            self.firstSample = firstSample
        }
    }

    /// The dry sound of a clip, or nil for a clip that plays nothing.
    ///
    /// A clip that is muted, on a muted track, or a take that waits behind another is made all the same: its
    /// finished sound may be wanted before it is heard.
    ///
    /// - Parameters:
    ///   - clip: the clip, read as it is handed in.
    ///   - project: the project the clip's recordings are in.
    ///   - recordings: the sound of the recordings, by recording id: mono samples at 48,000 Hz.
    ///   - peaks: the highest sample of a stretch of a recording, for the safe limit.
    ///   - edgeFadeMs: the fade at every segment edge, in milliseconds: the setting `timing.edgeFadeMs`.
    ///   - tightened: the tightened sounds of the clip's segments, when the clip has a timing fix. Their
    ///     samples are in `recordings` under their own ids.
    ///   - voices: which voice stands in for which recording on which track. Their samples are in
    ///     `recordings` under their own ids. With `.none` the clip is read from Max's own recordings. Hand in
    ///     tightened sounds that were made from the same source (`ClipTightening.Inputs.voices`).
    public static func render(
        _ clip: Clip,
        in project: Project,
        recordings: [UUID: [Float]],
        peaks: RecordingPeak,
        edgeFadeMs: Double,
        tightened: TightenedSounds = .none,
        voices: TrackVoices
    ) -> Sound? {
        // The clip's own volume comes after the chain. With it at 0 the safe limit is measured on what is
        // left, which is the volume the recipe of the finished sound names (`DryIdentity.gainDb`).
        var unturned = clip
        unturned.gainDb = 0
        // A voice whose samples are not at hand would be a silent clip: the recording is read instead. A
        // lookup made with `having` from the same samples loses nothing here, and then the recipe that
        // names this sound names what it was made from.
        let voices = voices.having(recordings)
        guard let alone = alone(unturned, in: project, peaks: peaks, tightened: tightened, voices: voices) else {
            return nil
        }
        return Sound(
            samples: OfflineMix.render(
                alone.pieces,
                recordings: recordings,
                lengthSamples: alone.lengthSamples,
                fadeSamples: EdgeFade.samples(milliseconds: edgeFadeMs)
            ),
            firstSample: alone.firstSample
        )
    }

    /// What is heard of one clip alone.
    struct Alone {
        /// The sample of the song the clip's first sound is on.
        var firstSample: Int
        /// How many samples it lasts, from its first sound to its last. With a finished sound, the tail too.
        var lengthSamples: Int
        /// Its pieces, with `startDelay` counted from `firstSample`.
        var pieces: [ClipPiece]
    }

    /// Far enough before and after any song that a clip is never cut off by the stretch that is asked for.
    private static let reach = 1 << 50

    /// What is heard of one clip alone, with its volume as the clip says. Nil for a clip that plays nothing.
    ///
    /// The plan is the player's own (`Project.clipPlaybackPlan`), asked about a project that holds only this
    /// clip, heard, on a track of its own at 0 dB. So where each segment lies, how loud it is and what the
    /// safe limit does are answered by the one rule for all of that. A track's volume is only for what is
    /// heard while playing, and a mute says what is heard in Lockstep, so neither counts for a clip alone.
    ///
    /// The Voice does count: it is how the clip sounds, not how it is mixed. With `voices`, the track of its
    /// own is the clip's real track as far as the Voice goes: it has that track's id and its Voice, so the
    /// plan finds the voices that stand in there. The clip is found in the project by its id, and a clip the
    /// project does not have is on no track and is read from its recordings.
    ///
    /// - Parameters:
    ///   - finished: the finished sounds there are. A clip that has one is one finished piece.
    ///   - voices: which voice stands in for which recording on which track. `.none`: Max's own recordings,
    ///     and then the clip's real track is not even looked for.
    static func alone(
        _ clip: Clip,
        in project: Project,
        peaks: RecordingPeak,
        tightened: TightenedSounds = .none,
        finished: FinishedSounds = .none,
        voices: TrackVoices
    ) -> Alone? {
        var heard = clip
        heard.muted = false
        heard.isActiveTake = true
        var only = project
        var own = Track(clips: [heard])
        if !voices.isEmpty,
           let real = project.tracks.first(where: { track in track.clips.contains { $0.id == clip.id } }),
           voices.isHeard(on: real) {
            own = Track(id: real.id, voice: real.voice, clips: [heard])
        }
        only.tracks = [own]
        // Asked for from far before the song to far after it, so a clip that reaches past either end of the
        // song is whole.
        let pieces = only.clipPlaybackPlan(
            from: -reach, to: reach, peaks: peaks, tightened: tightened, finished: finished, voices: voices
        )
        guard let first = pieces.map(\.startDelay).min(),
            let end = pieces.map({ $0.startDelay + $0.length }).max(), end > first
        else {
            return nil
        }
        return Alone(
            firstSample: first - reach,
            lengthSamples: end - first,
            pieces: pieces.map { piece in
                var moved = piece
                moved.startDelay -= first
                return moved
            }
        )
    }
}

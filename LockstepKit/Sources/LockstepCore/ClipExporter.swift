import Foundation

/// One clip made ready for DaVinci Resolve: the sound of the file, and where the file goes on the timeline.
///
/// The file starts exactly on a frame, because Resolve's playhead stands on whole frames only. So the clip's
/// first sound is not the file's first sample: the file begins with `paddingSamples` of silence, less than one
/// frame, and ends with silence up to the next frame, so it is a whole number of frames long.
///
/// A clip that is sent with its finished sound is in stereo, and its file also holds what rings after the
/// clip, the tail. It starts on the same frame either way: a finished sound never begins before the clip's
/// first sound.
public struct ClipExport: Sendable, Equatable {
    /// Everything the file holds, at 48,000 Hz: the silence before the clip, the clip, its tail when it has
    /// one, the silence after it. Mono, or with two channels left and right in turn, as a WAV file has them.
    public var samples: [Float]
    /// The frame the file starts on, counted from the start of the Resolve timeline.
    public var startFrame: Int
    /// The timecode of that frame: where Max puts the file in Resolve.
    public var timecode: Timecode
    /// How many samples of silence the file begins with.
    public var paddingSamples: Int
    /// How many samples the clip itself lasts, from its first sound to its last.
    public var clipSamples: Int
    /// The name of the file, such as "Weighted Silence - Double - 01.00.16.00.wav".
    public var fileName: String
    /// How many channels the file has: 1 for a clip sent dry, 2 for a clip sent with its finished sound.
    public var channels: Int
    /// How many samples ring after the clip's last one: the tail of its finished sound. 0 for a clip sent dry.
    public var tailSamples: Int

    public init(
        samples: [Float],
        startFrame: Int,
        timecode: Timecode,
        paddingSamples: Int,
        clipSamples: Int,
        fileName: String,
        channels: Int = 1,
        tailSamples: Int = 0
    ) {
        self.samples = samples
        self.startFrame = startFrame
        self.timecode = timecode
        self.paddingSamples = paddingSamples
        self.clipSamples = clipSamples
        self.fileName = fileName
        self.channels = channels
        self.tailSamples = tailSamples
    }

    /// How long the file is, in samples of one channel. Always whole frames.
    public var lengthSamples: Int {
        samples.count / max(channels, 1)
    }
}

/// Makes the sound of one clip for DaVinci Resolve.
///
///     let export = ClipExporter.export(
///         clipID, in: project,
///         recordings: sounds,                               // the recordings' samples by recording id
///         peaks: recordingPeaks.lookup(in: sounds),         // for the safe limit, see `RecordingPeak`
///         edgeFadeMs: settings[.edgeFadeMs]
///     )
///
/// The clip sounds exactly as it does when the song plays, because the sound is made by the code the player
/// uses: `Project.clipPlaybackPlan` says which samples of which recording go where and how loud, asked about
/// the clip alone (`ClipDry.alone`), and `OfflineMix` makes the row. Whatever changes how a clip sounds (a timing fix, a volume, a fade) changes
/// those two, and the export follows without being touched.
///
/// With `finished` and `finishedSamples` handed in, a clip that has a finished sound is exported as that sound:
/// the very samples the player lays into its row for the clip, left and right, with the tail. The clip's own
/// volume is in the finished sound already. A clip without a finished sound is exported dry, as before.
///
/// With `voices` handed in, a clip on a track whose Voice is heard is exported in that voice, and with `.none`
/// in Max's own, the very bytes the same project gives with every Voice taken off its tracks. Whoever sends
/// chooses once and hands the same choice to every step: the tightened sounds, the finished sound, the peaks
/// and this. The frame, the timecode and the length are the same either way.
///
/// Two things differ from playing on purpose. The clip is exported alone, without the other clips of its
/// track. And a muted clip, or a clip on a muted track, is exported all the same: muting says what is heard in
/// Lockstep, not what Max may take to Resolve.
///
/// Writing the file is `ClipExporter.write` in `LockstepAudio`.
public enum ClipExporter {
    /// The clip an export of `clipID` is about, and its track. For a line with several takes it is the take
    /// that is drawn and played, whichever take of the line was asked for. Nil when there is no such clip.
    public static func clipToExport(_ clipID: UUID, in project: Project) -> (clip: Clip, track: Track)? {
        guard let asked = project.clip(clipID) else { return nil }
        let clip = project.takes(of: clipID).first(where: \.isActiveTake) ?? asked
        guard let track = project.tracks.first(where: { track in track.clips.contains { $0.id == clip.id } }) else {
            return nil
        }
        return (clip, track)
    }

    /// The sample of the song on which the clip's first sound is heard. The frame and the timecode of an
    /// export are worked out from it, and so is the start time the window shows for a selected clip, so the
    /// two can never disagree. Nil for a clip that plays nothing.
    ///
    /// - Parameters:
    ///   - tightened: the tightened sounds the clip is heard with. A line that slid out of the clip at its
    ///     start makes the first sound earlier than the clip's own start. Left out, the answer is where the
    ///     clip starts as it was recorded.
    ///   - voices: the voices the clip is heard with, as for `export`. A tightened sound made from a voice
    ///     that may not be heard on the clip's track is not heard, so it does not move the start either.
    public static func startSample(
        of clipID: UUID,
        in project: Project,
        tightened: TightenedSounds = .none,
        voices: TrackVoices
    ) -> Int? {
        guard let chosen = clipToExport(clipID, in: project) else { return nil }
        return ClipDry.alone(chosen.clip, in: project, peaks: Clip.unknownPeaks, tightened: tightened, voices: voices)?
            .firstSample
    }

    /// The file for one clip: its sound as it plays, starting on a frame of the project's Resolve timeline.
    ///
    /// - Parameters:
    ///   - clipID: the clip. For a line with takes, the take that is drawn and played is exported.
    ///   - project: the project as it is now.
    ///   - recordings: the sound of the recordings, by recording id: mono samples at 48,000 Hz.
    ///   - peaks: the highest sample of a stretch of a recording, for the safe limit on the clip's volume.
    ///   - edgeFadeMs: the fade at every segment edge, in milliseconds: the setting `timing.edgeFadeMs`.
    ///   - tightened: the tightened sounds of the clip's segments, when the clip has a timing fix. Their
    ///     samples are in `recordings` under their own ids. An export is the clip as it is heard, so hand
    ///     them in for every clip that is not Off.
    ///   - finished: the finished sounds there are, by clip (see `FinishedSounds`). A clip that has one is
    ///     exported as that sound, in stereo, with its tail. Left out, every clip is exported dry: the file
    ///     is, sample for sample, what it was before a clip could have a finished sound.
    ///   - finishedSamples: the samples of the finished sounds, by their ids. A finished sound whose samples
    ///     are not here counts as none.
    ///   - voices: which voice stands in for which recording on which track. Their samples are in
    ///     `recordings` under their own ids. With `.none` the clip is exported in Max's own voice.
    ///     The tightened and finished sounds handed in must have been made from the same source: this
    ///     cannot take a voice out of a sound that already has it. A voice whose samples are not in
    ///     `recordings` counts as not made, and its recording is read.
    /// - Returns: nil when there is no such clip, or when it plays nothing.
    public static func export(
        _ clipID: UUID,
        in project: Project,
        recordings: [UUID: [Float]],
        peaks: RecordingPeak,
        edgeFadeMs: Double,
        tightened: TightenedSounds = .none,
        finished: FinishedSounds = .none,
        finishedSamples: [UUID: StereoSound] = [:],
        voices: TrackVoices
    ) -> ClipExport? {
        let finished = finished.having(finishedSamples)
        // A voice whose samples are not at hand would be a silent file: the recording is read instead.
        let voices = voices.having(recordings)
        guard let chosen = clipToExport(clipID, in: project),
            let sound = ClipDry.alone(
                chosen.clip, in: project, peaks: peaks, tightened: tightened, finished: finished, voices: voices
            )
        else {
            return nil
        }
        // With a finished sound the clip alone is that one piece, and it lasts as long as the dry sound plus
        // the tail.
        let tail = sound.pieces.contains(where: \.isFinished) ? finished.sound(for: chosen.clip)?.tailSamples : nil
        let resolve = project.resolve
        // Counted from the timeline's 00:00, which is the first frame of the Resolve timeline.
        let onTimeline = project.songPlace.timelineSample(forSong: sound.firstSample)
        let frame = resolve.startFrame(forTimelineSample: onTimeline)
        let padding = resolve.paddingSamples(forTimelineSample: onTimeline)
        // Up to the next frame boundary. A clip that ends exactly on one gets no silence after it.
        let perFrame = resolve.samplesPerFrame
        let length = (padding + sound.lengthSamples + perFrame - 1) / perFrame * perFrame
        // Each piece is moved back by the silence the file begins with. Past the clip's end the row stays silent.
        let pieces = sound.pieces.map { piece in
            var moved = piece
            moved.startDelay += padding
            return moved
        }
        let timecode = resolve.timecode(frame: frame)
        let fadeSamples = EdgeFade.samples(milliseconds: edgeFadeMs)
        let samples: [Float]
        if tail != nil {
            let row = OfflineMix.renderStereo(
                pieces, recordings: recordings, finished: finishedSamples, lengthSamples: length, fadeSamples: fadeSamples
            )
            samples = interleaved(row)
        } else {
            samples = OfflineMix.render(pieces, recordings: recordings, lengthSamples: length, fadeSamples: fadeSamples)
        }
        return ClipExport(
            samples: samples,
            startFrame: frame,
            timecode: timecode,
            paddingSamples: padding,
            clipSamples: sound.lengthSamples - (tail ?? 0),
            fileName: fileName(songName: project.songName, trackName: chosen.track.name, timecode: timecode),
            channels: tail == nil ? 1 : 2,
            tailSamples: tail ?? 0
        )
    }

    /// The two sides of a sound as a stereo WAV file holds them: left, right, left, right.
    static func interleaved(_ sound: StereoSound) -> [Float] {
        let count = min(sound.left.count, sound.right.count)
        return [Float](unsafeUninitializedCapacity: 2 * count) { buffer, written in
            for index in 0..<count {
                buffer[2 * index] = sound.left[index]
                buffer[2 * index + 1] = sound.right[index]
            }
            written = 2 * count
        }
    }

    /// The name of an exported file: "<Song name> - <Track name> - <HH.MM.SS.FF>.wav".
    ///
    /// A slash and a colon cannot stand in a file name on a Mac, and a line break has no place in one, so each
    /// becomes a space. A name that is empty is left out with its dash.
    public static func fileName(songName: String, trackName: String, timecode: Timecode) -> String {
        let parts = [songName, trackName].map(cleaned).filter { !$0.isEmpty } + [timecode.fileNameText]
        return parts.joined(separator: " - ") + ".wav"
    }

    /// A name with every character a file name cannot hold replaced by a space, and no space at its ends.
    private static func cleaned(_ name: String) -> String {
        let allowed = String(name.map { character in
            let isForbidden = character == "/" || character == ":" || character.isNewline
                || character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            return isForbidden ? " " : character
        })
        return allowed.trimmingCharacters(in: .whitespaces)
    }
}

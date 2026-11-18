import Foundation

// Which made voice stands in for which recording on which track.
//
//     var voices = TrackVoices.none
//     voices.set(heard: voiceID, before: nil, forRecording: recording.id, onTrack: track.id)
//     voices.soundID(forRecording: recording.id, on: track)     // voiceID while the track's Voice is heard
//     voices.standIns(for: clip, on: track)                     // [recording.id: voiceID]
//     voices.peaks(peaks, on: track)                            // the safe limit, asked about the voice
//     voices.mayBeHeardOn(madeFrom: sources, for: clip, on: track)   // may an older result still play?

/// Which voice stands in for which recording on which track, as `TightenedSounds` is for segments.
///
/// The voice of a recording is a row of samples of its own, exactly as long as the recording, kept with the
/// recordings' samples under an id of its own. This says which id stands in for a recording on a track. It is
/// a track's matter: the same recording on a track without a Voice, or on one with another setting, is read
/// from another sound.
///
/// Every rule that reads a clip's samples is handed one of these, and `.none` means Max's own recordings.
/// A recording that is not in here for a track is read as it was recorded.
///
/// Every voice in here has its samples at hand: whoever holds the samples makes the lookup once with
/// `having(_:)` and hands that same value to every rule of one pass, those that make sound (the plan, the dry
/// sound, the export, the correction) and those that name what a sound is made from (`ClipTightening.Inputs`,
/// `ClipSoundRecipe`, `TighteningInputsMemory`). So a sound is never named after a voice it was not made
/// from: while a voice's samples are not in, nothing names it and the recording is read, and when they
/// arrive the names change and the sound is made again. The rules that make sound still drop a voice whose
/// samples they were not handed, so a lookup that broke this would at worst play the recording, never
/// silence.
public struct TrackVoices: Sendable, Equatable {
    /// One recording on one track.
    public struct Key: Sendable, Hashable {
        public var trackID: UUID
        public var recordingID: UUID

        public init(trackID: UUID, recordingID: UUID) {
            self.trackID = trackID
            self.recordingID = recordingID
        }
    }

    /// What stands in for one recording on one track.
    public struct Entry: Sendable, Equatable {
        /// The id the samples that are heard are kept under, among the recordings' samples.
        public var heard: UUID
        /// The id of the sound that stood in just before on the same track, or nil when that was the
        /// recording itself or nothing is remembered. A result made from it may still be heard while a newer
        /// one is made.
        public var before: UUID?

        public init(heard: UUID, before: UUID? = nil) {
            self.heard = heard
            self.before = before
        }
    }

    public var entries: [Key: Entry]

    public init(_ entries: [Key: Entry] = [:]) {
        self.entries = entries
    }

    /// No voice at all: every clip is read from Max's own recordings.
    public static let none = TrackVoices()

    public var isEmpty: Bool { entries.isEmpty }

    /// Says that the samples kept under `heard` stand in for this recording on this track.
    ///
    /// - Parameter before: the id of the sound that stood in for it just before on the same track, if one
    ///   did.
    public mutating func set(heard: UUID, before: UUID?, forRecording recordingID: UUID, onTrack trackID: UUID) {
        entries[Key(trackID: trackID, recordingID: recordingID)] = Entry(heard: heard, before: before)
    }

    /// The id of the sound a recording is read from on this track, or nil when it is read from the recording
    /// itself: nothing stands in for it there, or the track's Voice is not heard (it has none, it is switched
    /// off, or both its knobs are in the middle).
    ///
    /// The track is asked as it is now, so switching the Voice off, or an Undo back to off, gives Max's own
    /// recording at once, whatever is still kept in here.
    public func soundID(forRecording recordingID: UUID, on track: Track) -> UUID? {
        guard !entries.isEmpty, track.voice?.isHeard == true else { return nil }
        return entries[Key(trackID: track.id, recordingID: recordingID)]?.heard
    }

    /// For each recording a clip plays that a voice stands in for on this track: the id of that voice. Empty
    /// when the clip is read from its recordings alone.
    public func standIns(for clip: Clip, on track: Track) -> [UUID: UUID] {
        guard !entries.isEmpty, track.voice?.isHeard == true else { return [:] }
        var standIns: [UUID: UUID] = [:]
        for segment in clip.segments where standIns[segment.recordingID] == nil {
            if let heard = entries[Key(trackID: track.id, recordingID: segment.recordingID)]?.heard {
                standIns[segment.recordingID] = heard
            }
        }
        return standIns
    }

    /// Whether anything stands in for a recording on this track right now: its Voice is heard, and there is
    /// something in here at all. False is the quick answer for a track without a Voice, which then costs a
    /// rule nothing more than this.
    public func isHeard(on track: Track) -> Bool {
        !entries.isEmpty && track.voice?.isHeard == true
    }

    /// The lookup with only the voices there are samples for: the one to hand to every rule (see the type's
    /// own notes).
    ///
    /// Whoever makes sound from clips hands in a lookup and the samples it names, in with the recordings'
    /// samples. A voice whose samples are not there cannot be played, and a plan that named it would leave
    /// its clip silent. Asked through this, such a recording is read as it was recorded, as if its voice
    /// were not made yet. `FinishedSounds.having` does the same for finished sounds.
    public func having(_ samples: [UUID: [Float]]) -> TrackVoices {
        guard !entries.isEmpty else { return self }
        return TrackVoices(entries.filter { samples[$0.value.heard] != nil })
    }

    // MARK: Which older results may still play

    /// Whether a result made from `sources` (a tightened sound, a finished sound) may still be heard for this
    /// clip on this track while a newer one is made.
    ///
    /// The plan of what is played asks this of every tightened and finished sound it is handed
    /// (`TightenedSounds.sound(for:at:of:on:voices:)`, `FinishedSounds.sound(for:on:voices:)`), so a result made
    /// from a voice that no longer stands in is never played, sent or made into a finished sound, whatever
    /// the app hands in.
    ///
    /// It may when every sound it was made from is, for that recording on this track, one of three: the
    /// recording itself, the sound that stands in for it now, or the one that stood in just before, when
    /// the result was made for this same track (`VoiceSources.trackID`). So:
    /// - a result made from Max's own recordings may always be heard, also once a voice has arrived;
    /// - a result made from a voice may be heard while that voice stands in on this track, and while its
    ///   successor does (a knob was turned: one change in the ear, from the old setting to the new);
    /// - a result made from a voice is never heard once the track's Voice is off, gone or in the middle, nor
    ///   on a track the clip was moved to, where another sound stands in or none, nor where the sound that
    ///   stood in just before on that track happens to be the one it was made from. The clip then falls
    ///   back to what stands in now, until its results are made again;
    /// - a result made from the sound that stands in now may be heard wherever it was made: it is that very
    ///   sound.
    ///
    /// Only the recordings the clip plays now are asked about: what a result was made from for a recording the
    /// clip no longer plays cannot be heard through it.
    ///
    /// - Parameter sources: what the result was made from (`VoiceSources`): `.recordings` for a result made
    ///   from the recordings alone.
    public func mayBeHeardOn(madeFrom sources: VoiceSources, for clip: Clip, on track: Track) -> Bool {
        mayBeHeard(madeFrom: sources, for: clip, on: track)
    }

    /// `mayBeHeardOn(madeFrom:for:on:)` for a clip that may be on no track: a result made from a voice is then
    /// never heard, as on a track without a Voice.
    func mayBeHeard(madeFrom sources: VoiceSources, for clip: Clip, on track: Track?) -> Bool {
        guard !sources.voices.isEmpty else { return true }
        let heard = track?.voice?.isHeard == true
        for segment in clip.segments {
            guard let source = sources.voices[segment.recordingID], source != segment.recordingID else { continue }
            // What stood in just before belongs to this track: a result made from it elsewhere was never
            // heard here, so a clip moved onto this track starts with what stands in now.
            guard heard, let track, let entry = entries[Key(trackID: track.id, recordingID: segment.recordingID)],
                  entry.heard == source || (entry.before == source && sources.trackID == track.id)
            else { return false }
        }
        return true
    }

    // MARK: The safe limit

    /// The safe limit's question, put about the sound each recording is read from on this track: asked about
    /// a recording a voice stands in for, it is answered for the voice, and otherwise for the recording.
    ///
    /// A clip's volume is held back by the highest sample of what the clip plays (`Clip.appliedGain`). On a
    /// track with a Voice the clip plays the voice, whose highest sample is another than the recording's. So
    /// wherever a clip's applied volume is worked out for what is heard, `peaks` goes through here first:
    ///
    ///     clip.appliedGain(peaks: voices.peaks(recordingPeaks.lookup(in: sounds), on: track))
    ///
    /// The same recording on another track is asked about with that track, and a dry send with `.none`, so
    /// one track's voice never turns down another track's clip or Max's own voice. `RecordingPeaks` measures
    /// any sound by its id, so `peaks` is handed the voice's id as it is handed a recording's.
    ///
    /// On a track where nothing stands in, the answer is `peaks` itself.
    public func peaks(_ peaks: @escaping RecordingPeak, on track: Track) -> RecordingPeak {
        guard isHeard(on: track) else { return peaks }
        let trackID = track.id
        let entries = entries
        return { recordingID, samples in
            peaks(entries[Key(trackID: trackID, recordingID: recordingID)]?.heard ?? recordingID, samples)
        }
    }

    /// One answer of `peaks(_:on:)`, for a rule that was itself handed `peaks` and may not keep it: the
    /// highest sample of a stretch of the sound this recording is read from on this track.
    func peak(_ peaks: RecordingPeak, of recordingID: UUID, _ samples: Range<Int>, on track: Track) -> Float {
        peaks(soundID(forRecording: recordingID, on: track) ?? recordingID, samples)
    }
}

/// What a result (a tightened sound, a finished sound) was made from, as far as voices go, kept with it so that
/// the plan can tell whether it may still be heard (`TrackVoices.mayBeHeardOn`).
///
/// Whoever keeps a result names its sources when it hands it in (`TightenedSounds.set`,
/// `FinishedSounds.Sound`), with what the result was made from: `ClipTightening.Inputs.voices`,
/// `ClipSoundRecipe.DryIdentity.sources`, and the track the clip was on.
public struct VoiceSources: Sendable, Equatable {
    /// For each recording the result read from another sound than the recording: that sound's id. Empty for a
    /// result made from the recordings alone.
    public var voices: [UUID: UUID]
    /// The track the result was made for, whose voices those were. Nil when it read no voice.
    public var trackID: UUID?

    /// - Parameters:
    ///   - voices: recording id to the id of the sound that was read in its place (`TrackVoices.standIns`).
    ///   - trackID: the track the clip was on when its result was made. Not kept when `voices` is empty.
    public init(_ voices: [UUID: UUID], onTrack trackID: UUID?) {
        self.voices = voices
        self.trackID = voices.isEmpty ? nil : trackID
    }

    /// Made from Max's own recordings: such a result may always be heard.
    public static let recordings = VoiceSources([:], onTrack: nil)
}

extension Clip {
    /// The volume the clip is played with on a track (`appliedGain(peaks:)`), with the safe limit asking
    /// about the sound the clip is read from there: the track's voice where one stands in, and the recording
    /// otherwise (`TrackVoices.peaks(_:on:)`). With `.none`, and on a track without a Voice, it is
    /// `appliedGain(peaks:)`.
    public func appliedGain(peaks: RecordingPeak, voices: TrackVoices, on track: Track) -> AppliedGain {
        guard voices.isHeard(on: track) else { return appliedGain(peaks: peaks) }
        return appliedGain(peaks: { voices.peak(peaks, of: $0, $1, on: track) })
    }
}

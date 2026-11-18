import Foundation

// A clip's finished sound: the clip with its track's Sound and its own effects, made ahead and played or sent
// in place of the clip.

/// A sound in stereo: two rows of samples of the same length, at 48,000 Hz.
public struct StereoSound: Sendable, Equatable {
    public var left: [Float]
    public var right: [Float]

    public init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }
}

/// Everything a clip's finished sound depends on besides the dry sound's samples. Two that are equal give
/// the same sound.
///
/// It does not hold where the clip lies in the song, unless something in it follows the beats. So moving,
/// deleting or copying a clip without an echo, a stutter or a swell makes nothing again.
public struct ClipSoundRecipe: Sendable, Equatable {
    public var dry: DryIdentity
    /// The numbers of the track's Sound with the clip's own knobs. Nil: the track has no Sound, and the chain
    /// is skipped.
    public var chain: ChainParameters?
    /// `Clip.gainDb`, applied after the chain.
    public var clipGainDb: Double
    public var effects: [HeardEffect]
    /// The beats as samples of the dry sound, only when the chain or an effect follows the beats. Otherwise
    /// empty.
    public var beats: [Double]
    /// The clip's sub-beats per beat, for stutter.
    public var perBeat: Int

    public init(
        dry: DryIdentity,
        chain: ChainParameters? = nil,
        clipGainDb: Double = 0,
        effects: [HeardEffect] = [],
        beats: [Double] = [],
        perBeat: Int = 4
    ) {
        self.dry = dry
        self.chain = chain
        self.clipGainDb = clipGainDb
        self.effects = effects
        self.beats = beats
        self.perBeat = perBeat
    }

    /// What the dry sound of step 1 is made from. Two that are equal give the same dry sound.
    public struct DryIdentity: Sendable, Equatable {
        /// The clip's segments, with their own volumes.
        public var segments: [Segment]
        /// For each segment, the id of the tightened sound that stands in for it, or nil for a segment that is
        /// played from its recording.
        public var tightenedIDs: [UUID?]
        /// How long the fades at the edges are.
        public var fadeSamples: Int
        /// The volume step 1 applies to the whole clip, in dB: what Normalize set, held back by the safe limit.
        /// The clip's own volume is not in it.
        public var gainDb: Double
        /// The sound each recording of the clip is read from where that is not the recording itself: the id
        /// of the voice that stands in for it on the clip's track, by recording id
        /// (`TrackVoices.standIns(for:on:)`). Empty for a dry sound made from Max's own recordings, which is
        /// then the identity it was before a track could have a Voice.
        ///
        /// With it a finished sound is made again when a voice arrives or changes, and an older finished
        /// sound can be asked whether it may still be heard (`TrackVoices.mayBeHeardOn`).
        public var sources: [UUID: UUID]
        /// The track whose voices `sources` names, or nil when it names none. It is part of the identity so
        /// that a sound made from one track's voices is never taken for one made on another track: a clip
        /// with a voice that is moved to another track has its finished sound made again there.
        public var sourcesTrackID: UUID?

        /// What the dry sound was read from, as the finished sound made from it is handed in with
        /// (`FinishedSounds.Sound`).
        public var madeFrom: VoiceSources { VoiceSources(sources, onTrack: sourcesTrackID) }

        public init(
            segments: [Segment],
            tightenedIDs: [UUID?],
            fadeSamples: Int,
            gainDb: Double,
            sources: [UUID: UUID] = [:],
            onTrack trackID: UUID? = nil
        ) {
            self.segments = segments
            self.tightenedIDs = tightenedIDs
            self.fadeSamples = fadeSamples
            self.gainDb = gainDb
            self.sources = sources
            sourcesTrackID = sources.isEmpty ? nil : trackID
        }
    }

    /// One effect of the clip as the making of the sound needs it: on samples of the dry sound, where
    /// `ClipEffect` names samples of a recording.
    public struct HeardEffect: Sendable, Equatable {
        public var id: UUID
        public var kind: ClipEffect.Kind
        public var levelDb: Double
        /// Its stretch as samples of the dry sound. Nil: the whole of it.
        public var span: Range<Int>?

        public init(id: UUID, kind: ClipEffect.Kind, levelDb: Double, span: Range<Int>? = nil) {
            self.id = id
            self.kind = kind
            self.levelDb = levelDb
            self.span = span
        }
    }
}

/// Which finished sound is played in place of which clip, as `TightenedSounds` is for segments.
public struct FinishedSounds: Sendable, Equatable {
    /// The finished sound of one clip.
    public struct Sound: Sendable, Equatable {
        /// The id its samples are kept under, among the finished sounds' samples.
        public var id: UUID
        /// How long the dry sound was. The finished sound is that long plus its tail.
        public var drySamples: Int
        /// How many samples ring after the dry sound's last one.
        public var tailSamples: Int
        /// The segments it was made from, without their volumes.
        public var pieces: [Segment]
        /// The voices its dry sound was read from, if any, and the track they were the voices of. A sound
        /// made from a voice is heard only while that voice may be (`TrackVoices.mayBeHeardOn`).
        public var sources: VoiceSources

        /// - Parameter sources: what its dry sound was read from: the recipe's `dry.sources` and the track the
        ///   clip was on, or `.recordings`. Never left out, so a sound made from a voice is always known as
        ///   one, and never heard once that voice no longer stands in.
        public init(id: UUID, drySamples: Int, tailSamples: Int, pieces: [Segment], madeFrom sources: VoiceSources) {
            self.id = id
            self.drySamples = drySamples
            self.tailSamples = tailSamples
            self.sources = sources
            self.pieces = pieces.map { piece in
                var piece = piece
                piece.gainDb = 0
                return piece
            }
        }
    }

    public var sounds: [UUID: Sound]

    public init(_ sounds: [UUID: Sound] = [:]) {
        self.sounds = sounds
    }

    /// No finished sound at all: every clip is played as before a track could have a Sound.
    public static let none = FinishedSounds()

    /// Says that `sound` is the finished sound of this clip.
    public mutating func set(_ sound: Sound, for clipID: UUID) {
        sounds[clipID] = sound
    }

    /// The finished sound that is heard in place of a clip on a track, or nil when the clip is played from its
    /// segments: there is none, the clip no longer plays its pieces, or it was made from a voice that may no
    /// longer be heard there (`TrackVoices.mayBeHeardOn`): the Voice was switched off, taken off or undone,
    /// or the clip was moved to another track. The plan of what is played asks this one.
    ///
    /// - Parameter track: the track the clip is heard on. Nil for a clip on no track, where only a sound made
    ///   from the recordings is heard.
    public func sound(for clip: Clip, on track: Track?, voices: TrackVoices) -> Sound? {
        guard let sound = sound(for: clip), voices.mayBeHeard(madeFrom: sound.sources, for: clip, on: track) else {
            return nil
        }
        return sound
    }

    /// The finished sound made for a clip, or nil when there is none or the clip no longer plays the pieces
    /// the one there is was made from. It says nothing about the voice it was made from: what is heard is
    /// `sound(for:on:voices:)`.
    ///
    /// A clip still plays those pieces when every segment plays the same stretch of the same recording and
    /// they lie as they did against each other. So a clip that was only moved, or turned up or down, keeps
    /// its sound, and one that was trimmed, cut or joined does not.
    public func sound(for clip: Clip) -> Sound? {
        guard let sound = sounds[clip.id], sound.pieces.count == clip.segments.count else { return nil }
        var moved: Int?
        for (segment, piece) in zip(clip.segments, sound.pieces) {
            // How far the first segment was moved is how far every segment must have been.
            let distance = segment.offsetSamples - piece.offsetSamples
            if moved == nil { moved = distance }
            guard segment.recordingID == piece.recordingID,
                  segment.inSample == piece.inSample,
                  segment.outSample == piece.outSample,
                  distance == moved
            else { return nil }
        }
        return sound
    }
}

import Foundation

// What a project says about how a voice sounds: a track's Sound, a clip's own knobs and a clip's effects.
// They are only what is saved. What the numbers mean for the sound
// is `ChainParameters`, and the sound itself is made from a `ClipSoundRecipe`.

/// The four knobs of a Sound, each from 0 to 1 (0 to 100 % in the panel on the right).
public struct SoundKnobs: Codable, Sendable, Equatable {
    /// How much loud and quiet words are evened out.
    public var squeeze: Double
    /// How much of the character's cut of mud and lift of clarity is applied.
    public var tone: Double
    /// How much grit.
    public var warmth: Double
    /// How much reverb and echo.
    public var space: Double

    public init(squeeze: Double, tone: Double, warmth: Double, space: Double) {
        self.squeeze = squeeze
        self.tone = tone
        self.warmth = warmth
        self.space = space
    }
}

/// Which of the six built-in sounds a Sound is. It decides everything the knobs do not, and has no control of
/// its own.
public enum SoundCharacter: String, Codable, Sendable, CaseIterable {
    case rapLead, rapDouble, adLib, sungLead, sungHook, backingVoice
}

/// The Sound of a track: a character and four knobs, under the name of the preset it was chosen from. A
/// chosen preset is copied here, so a project never depends on a preset still being there.
public struct TrackSound: Codable, Sendable, Equatable {
    /// What the menu shows: the built-in's name, or the name of Max's own preset.
    public var name: String
    public var character: SoundCharacter
    public var knobs: SoundKnobs

    public init(name: String, character: SoundCharacter, knobs: SoundKnobs) {
        self.name = name
        self.character = character
        self.knobs = knobs
    }
}

/// The knobs a clip turned for itself, each from 0 to 1. Nil is the track's value, which every knob of a new
/// clip is.
public struct ClipKnobs: Codable, Sendable, Equatable {
    public var squeeze: Double?
    public var tone: Double?
    public var warmth: Double?
    public var space: Double?

    public init(squeeze: Double? = nil, tone: Double? = nil, warmth: Double? = nil, space: Double? = nil) {
        self.squeeze = squeeze
        self.tone = tone
        self.warmth = warmth
        self.space = space
    }

    /// Whether the clip follows its track with all four knobs.
    public var isEmpty: Bool {
        squeeze == nil && tone == nil && warmth == nil && space == nil
    }
}

/// A stretch of a clip, kept as samples of the recording it plays, as the syllable markers are. So it stays
/// on its word when the clip is moved, trimmed or split, and when its timing is corrected.
public struct ClipSpan: Codable, Sendable, Equatable {
    public var recordingID: UUID
    /// The first sample of the recording in the stretch.
    public var inSample: Int
    /// One past the last sample.
    public var outSample: Int

    public init(recordingID: UUID, inSample: Int, outSample: Int) {
        self.recordingID = recordingID
        self.inSample = inSample
        self.outSample = outSample
    }
}

/// One effect of a clip: a double (phase 34) or an effect on a word (phase 35), on the whole clip or on a
/// stretch of it.
public struct ClipEffect: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: Kind
    /// The stretch it is on. Nil: the whole clip.
    public var span: ClipSpan?
    /// How loud its layer is, from -24 to +6 dB. A kind that replaces the voice has no use for it.
    public var levelDb: Double

    /// Every kind of phases 34 and 35, listed from the start so that the saved form does not change between
    /// them.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case thick, lowFourth, lowOctave, high, big, small
        case echoQuarter, echoEighth, phone, stutter, tapeStop, swell
    }

    public init(id: UUID = UUID(), kind: Kind, span: ClipSpan? = nil, levelDb: Double = 0) {
        self.id = id
        self.kind = kind
        self.span = span
        self.levelDb = levelDb
    }
}

/// What a clip changed for itself of one effect of its track (`Track.effects`): its own level for it, or that
/// it is heard without it. A clip without one for an effect follows its track with that effect. Phase 36.5.
///
/// In `project.json` it is `{"effect": "<id>", "levelDb": -6}` or `{"effect": "<id>", "off": true}`, with
/// `levelDb` left out when nil and `off` when false.
public struct ClipEffectChange: Codable, Sendable, Equatable {
    /// The track's effect it is about.
    public var effectID: UUID
    /// The clip's own level for it, from -24 to +6 dB. Nil: the track's level.
    public var levelDb: Double?
    /// The clip is heard without it.
    public var isOff: Bool

    public init(effectID: UUID, levelDb: Double? = nil, isOff: Bool = false) {
        self.effectID = effectID
        self.levelDb = levelDb
        self.isOff = isOff
    }

    /// Whether it says nothing: no level of the clip's own and not off. Such a one is never kept.
    public var changesNothing: Bool {
        levelDb == nil && !isOff
    }

    private enum CodingKeys: String, CodingKey {
        case effectID = "effect"
        case levelDb
        case isOff = "off"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            effectID: try container.decode(UUID.self, forKey: .effectID),
            levelDb: try container.decodeIfPresent(Double.self, forKey: .levelDb),
            isOff: try container.decodeIfPresent(Bool.self, forKey: .isOff) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(effectID, forKey: .effectID)
        try container.encodeIfPresent(levelDb, forKey: .levelDb)
        if isOff { try container.encode(true, forKey: .isOff) }
    }
}

/// One effect of a saved clip, or nothing where its kind is one this Lockstep does not know: a project that a
/// newer Lockstep gave another kind of effect still opens, without that effect.
struct SavedClipEffect: Decodable {
    var effect: ClipEffect?

    private enum Key: String, CodingKey {
        case kind
    }

    init(from decoder: any Decoder) throws {
        let kind = try decoder.container(keyedBy: Key.self).decodeIfPresent(String.self, forKey: .kind)
        effect = kind.flatMap(ClipEffect.Kind.init(rawValue:)) == nil ? nil : try ClipEffect(from: decoder)
    }
}

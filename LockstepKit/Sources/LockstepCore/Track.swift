import Foundation

/// One vocal track.
/// The order of the tracks in the project is top to bottom in the window.
///
/// Tightening is not the track's: since phase 27 each clip says for itself how much of its timing is
/// corrected (`Clip.tighten`, `Clip.strength`, `Clip.stretch`).
public struct Track: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var muted: Bool
    /// How much louder or quieter than their own volumes say the track's clips are played, in dB, inside
    /// `Track.gainRange`. 0, which a new track has and one saved before tracks had a volume gets, plays them
    /// as they are. It is only for what is heard while playing and recording: the recordings and what is
    /// sent to DaVinci never have it in them. See `TrackGain.swift`.
    public var gainDb: Double
    /// The Sound the track's clips are heard with: a character and four knobs. Nil, which a new track has and
    /// one saved before phase 33 gets, is no Sound: the clips are heard as they are. It is left out of
    /// `project.json` when nil. See `Sound.swift`.
    public var sound: TrackSound?
    /// The effects every clip of the track is heard with, each on the whole clip: none has a span. A clip can
    /// have its own level for one or go without it (`Clip.effectChanges`). Empty, which a new track has and
    /// one saved before phase 36.5 gets, is left out of `project.json`. See `ProjectTrackEffects.swift`.
    public var effects: [ClipEffect]
    /// The Voice the track's clips are heard in: a switch, a preset's name and two knobs. Nil, which a new
    /// track has and one saved before phase 37 gets, is no Voice: the clips are heard in Max's own. One that
    /// is switched off stays here with its knobs. It is left out of `project.json` when nil. See
    /// `TrackVoice.swift`.
    public var voice: TrackVoice?
    public var clips: [Clip]

    public init(
        id: UUID = UUID(),
        name: String = "",
        muted: Bool = false,
        gainDb: Double = 0,
        sound: TrackSound? = nil,
        effects: [ClipEffect] = [],
        voice: TrackVoice? = nil,
        clips: [Clip] = []
    ) {
        self.id = id
        self.name = name
        self.muted = muted
        self.gainDb = Track.gain(clamped: gainDb)
        self.sound = sound
        self.effects = effects.map(\.onWholeClip)
        self.voice = voice
        self.clips = clips
    }

    /// What a track saved before phase 27 said about tightening, for all of its clips at once. It is read and
    /// never written.
    private enum SavedBeforeClipsTightened: String, CodingKey {
        case tightenLines
        case strength
    }

    /// Reads a saved track. A missing field gets its default.
    ///
    /// A track saved before phase 27 kept Tighten lines and the strength itself. Every clip of such a track
    /// gets the choice those two stand for (`Clip.choice(savedLines:savedStrength:)`).
    ///
    /// A track saved before phase 36.5 has no `effects`. An effect of a kind this Lockstep does not know is
    /// left out, and a span on one is dropped: a track's effect is on the whole of every clip.
    ///
    /// A track saved before phase 37 has no `voice`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var clips = try container.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        let before = try decoder.container(keyedBy: SavedBeforeClipsTightened.self)
        let tightenLines = try before.decodeIfPresent(Bool.self, forKey: .tightenLines)
        let strength = try before.decodeIfPresent(Double.self, forKey: .strength)
        if tightenLines != nil || strength != nil {
            let saved = Clip.choice(savedLines: tightenLines ?? false, savedStrength: strength ?? 0)
            for index in clips.indices {
                clips[index].tighten = saved.tighten
                clips[index].strength = saved.strength
            }
        }
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            muted: try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
            gainDb: try container.decodeIfPresent(Double.self, forKey: .gainDb) ?? 0,
            sound: try container.decodeIfPresent(TrackSound.self, forKey: .sound),
            effects: try container.decodeIfPresent([SavedClipEffect].self, forKey: .effects)?
                .compactMap(\.effect) ?? [],
            voice: try container.decodeIfPresent(TrackVoice.self, forKey: .voice),
            clips: clips
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, muted, gainDb, sound, effects, voice, clips
    }

    /// Writes the track. `effects` is left out when the track has none, so a track without effects is written
    /// exactly as before phase 36.5, and a Lockstep from before then reads a project that uses them without
    /// them. `sound` is left out when nil, as it always was, and so is `voice`: a track that never had a Voice
    /// is written exactly as before phase 37.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(muted, forKey: .muted)
        try container.encode(gainDb, forKey: .gainDb)
        try container.encodeIfPresent(sound, forKey: .sound)
        if !effects.isEmpty { try container.encode(effects.map(\.onWholeClip), forKey: .effects) }
        try container.encodeIfPresent(voice, forKey: .voice)
        try container.encode(clips, forKey: .clips)
    }
}

/// The grid a clip's timing is measured against, which the interface calls its sub-beats: the three buttons
/// 16ths, Triplets and Auto under "Correction" in the panel on the right. Only the clip says it: since
/// phase 27 the song has no choice of its own.
public enum ClipFeel: String, Codable, CaseIterable, Sendable {
    /// Four parts to a beat. The starting value.
    case sixteenths
    /// Six parts to a beat, which holds both three and six syllables to a beat.
    case triplets
    /// Whichever of the two the clip's own syllables fit (`Feel.detect`).
    case auto

    /// What a clip without a choice of its own had saved, before phase 27: it followed the song.
    static let savedFollowingSong = "followSong"
}

/// How much of a clip's timing is corrected: the three buttons Off, Lines and All under "Correction" in the
/// panel on the right. Phase 27.
public enum ClipTighten: String, Codable, CaseIterable, Sendable {
    /// The clip is heard as it was recorded.
    case off
    /// Each whole line slides toward the place where its first syllable lands on the nearest sub-beat, and
    /// nothing else moves.
    case lines
    /// The lines slide the same way, and then each syllable moves toward its nearest sub-beat.
    case all
}

/// One box on a track. It plays one or more parts of original recordings.
public struct Clip: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Typed by Max. Phase 14.
    public var name: String?
    /// Written out by the speech model. Phase 17.
    public var text: String?
    /// Sorted by time, never overlapping.
    public var segments: [Segment]
    public var muted: Bool
    /// Max's own volume for the clip, -12...+12. Phase 16.
    public var gainDb: Double
    /// Set by Normalize. Phase 16.
    public var normalizeGainDb: Double?
    /// The clip's sub-beats: 16ths, Triplets or Auto. Phase 21, and the clip's alone since phase 27.
    public var feel: ClipFeel
    /// How much of the clip's timing is corrected: Off, Lines or All. Phase 27.
    public var tighten: ClipTighten {
        didSet {
            if tighten != .off { tightenWhenOn = tighten }
        }
    }
    /// The choice the clip had last when it was not Off, which is what Correction On or Off (T) switches back
    /// to: Lines or All. All for a clip that never had one.
    public private(set) var tightenWhenOn: ClipTighten
    /// How much of the correction is applied, 0...1: the slider "Strength". It is how much of the way a line
    /// slides, and with All also how much of the way each syllable moves. Kept when Off is chosen. Phase 27.
    public var strength: Double
    /// Whether the clip's voice may be stretched or squeezed to move syllables that run together: the switch
    /// "Stretch". Off, such syllables move only as one block. Phase 27.
    public var stretch: Bool
    /// Whether this clip is the take that is drawn and played. Phase 11.
    public var isActiveTake: Bool
    /// The line this clip is a take of. The clips of one track that have the same line are takes of each
    /// other, and a clip that shares its line with no other has no other takes. It is kept with the clip, so
    /// trimming, cutting or correcting a clip never moves it to another line (`ProjectTakes.swift`).
    public var line: UUID
    /// The place Record aimed at when this clip was recorded, in song seconds, as long as the clip still
    /// starts where it did then. A recording aimed at the same place becomes a take of this clip's line,
    /// wherever the voice happened to start. It is counted from where the clip was recorded: a clip that was
    /// moved has it that much later or earlier (`Project.recordPlace(of:)`). Nil for a clip that was not
    /// recorded as it stands: one whose start was trimmed or cut, the second piece of a split, or a clip
    /// saved before lines were kept.
    public var recordPlace: Double?
    /// The knobs of the track's Sound that the clip turned for itself. None, which a new clip has: it follows
    /// its track. They are kept while the track has no Sound and count again when it gets one. Phase 33.
    public var knobs: ClipKnobs
    /// The clip's doubles and effects on a word, each on the whole clip or on a stretch of it. Phases 34
    /// and 35.
    public var effects: [ClipEffect]
    /// What the clip changed for itself of its track's effects (`Track.effects`): its own level for one, or
    /// that it is heard without it. None, which a new clip has: it follows its track with all of them. One
    /// that names an effect the clip's track does not have counts for nothing and is kept, so a clip moved to
    /// another track has its changes back when it is moved home. Phase 36.5.
    public var effectChanges: [ClipEffectChange]
    /// What the clip's correction aims at: nil is the beat, and otherwise the id of the track whose syllables
    /// it is held against, so a double Max recorded himself sits on its lead. The row "Aim at" under
    /// "Correction". It is left out of `project.json` when nil. An aim that cannot be followed counts as the
    /// beat while it cannot (`Project.aim(of:)`), and is kept, so it counts again when it can. Phase 36.
    public var aimTrack: UUID?

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        text: String? = nil,
        segments: [Segment] = [],
        muted: Bool = false,
        gainDb: Double = 0,
        normalizeGainDb: Double? = nil,
        feel: ClipFeel = .sixteenths,
        tighten: ClipTighten = .off,
        tightenWhenOn: ClipTighten = .all,
        strength: Double = Clip.startingStrength,
        stretch: Bool = false,
        isActiveTake: Bool = true,
        line: UUID = UUID(),
        recordPlace: Double? = nil,
        knobs: ClipKnobs = ClipKnobs(),
        effects: [ClipEffect] = [],
        aimTrack: UUID? = nil,
        effectChanges: [ClipEffectChange] = []
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.segments = segments
        self.muted = muted
        self.gainDb = gainDb
        self.normalizeGainDb = normalizeGainDb
        self.feel = feel
        self.tighten = tighten
        // A clip that is on was last on with the choice it has. Off is not something to switch back to.
        self.tightenWhenOn = tighten != .off ? tighten : tightenWhenOn == .lines ? .lines : .all
        self.strength = strength
        self.stretch = stretch
        self.isActiveTake = isActiveTake
        self.line = line
        self.recordPlace = recordPlace
        self.knobs = knobs
        self.effects = effects
        self.aimTrack = aimTrack
        self.effectChanges = effectChanges
    }

    /// The strength of a clip that has never been given one: all of the correction.
    public static let startingStrength: Double = 1

    /// What a clip saved before the choice of Off, Lines or All said about tightening. It is read and never
    /// written.
    private enum SavedBeforeTheChoice: String, CodingKey {
        case tightenLines
    }

    /// The choice that stands for what a clip saved before had, a switch for its lines and a strength for
    /// its syllables alone:
    /// - Syllables above 0: All, with that strength. Its lines slid the whole way then, with the switch on,
    ///   and now slide by the strength, so a little less.
    /// - Lines on and Syllables at 0: Lines, at 100 %, since its lines slid the whole way.
    /// - Neither: Off, with the strength a clip starts with.
    public static func choice(savedLines: Bool, savedStrength: Double) -> (tighten: ClipTighten, strength: Double) {
        if savedStrength > 0 { return (.all, min(savedStrength, 1)) }
        return (savedLines ? .lines : .off, startingStrength)
    }

    /// Reads a saved clip. A missing field gets its default.
    ///
    /// A clip saved before the choice of Off, Lines or All has no `tighten`. It gets the choice its older
    /// fields stand for (`choice(savedLines:savedStrength:)`), with Stretch off.
    ///
    /// A clip saved while the song had sub-beats of its own may say that it follows the song, or say nothing.
    /// It is read as 16ths here, and the project, which knows what the song had, then gives it that
    /// (`Project.init(from:)`).
    ///
    /// A clip saved before lines were kept has no `line`. It is read as a line of its own here, and the
    /// project, which knows where the clips lie, then puts the takes of one line together
    /// (`Project.giveLines`).
    ///
    /// A clip saved before phase 33 has no `knobs` and no `effects`: it follows its track and has no effect.
    /// An effect of a kind this Lockstep does not know is left out, and the rest of the clip is read.
    ///
    /// A clip saved before phase 36, or one that aims at the beat, has no `aimTrack`.
    ///
    /// A clip saved before phase 36.5 has no `effectChanges`: it follows its track's effects. An entry that
    /// changes nothing is not kept.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tighten: ClipTighten
        let strength: Double
        if let chosen = try container.decodeIfPresent(ClipTighten.self, forKey: .tighten) {
            tighten = chosen
            strength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? Clip.startingStrength
        } else {
            let before = try decoder.container(keyedBy: SavedBeforeTheChoice.self)
            let saved = Clip.choice(
                savedLines: try before.decodeIfPresent(Bool.self, forKey: .tightenLines) ?? false,
                savedStrength: try container.decodeIfPresent(Double.self, forKey: .strength) ?? 0
            )
            tighten = saved.tighten
            strength = saved.strength
        }
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            text: try container.decodeIfPresent(String.self, forKey: .text),
            segments: try container.decodeIfPresent([Segment].self, forKey: .segments) ?? [],
            muted: try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
            gainDb: try container.decodeIfPresent(Double.self, forKey: .gainDb) ?? 0,
            normalizeGainDb: try container.decodeIfPresent(Double.self, forKey: .normalizeGainDb),
            feel: try container.decodeIfPresent(String.self, forKey: .feel).flatMap(ClipFeel.init(rawValue:))
                ?? .sixteenths,
            tighten: tighten,
            tightenWhenOn: try container.decodeIfPresent(ClipTighten.self, forKey: .tightenWhenOn) ?? .all,
            strength: strength,
            stretch: try container.decodeIfPresent(Bool.self, forKey: .stretch) ?? false,
            isActiveTake: try container.decodeIfPresent(Bool.self, forKey: .isActiveTake) ?? true,
            line: try container.decodeIfPresent(UUID.self, forKey: .line) ?? UUID(),
            recordPlace: try container.decodeIfPresent(Double.self, forKey: .recordPlace),
            knobs: try container.decodeIfPresent(ClipKnobs.self, forKey: .knobs) ?? ClipKnobs(),
            effects: try container.decodeIfPresent([SavedClipEffect].self, forKey: .effects)?
                .compactMap(\.effect) ?? [],
            aimTrack: try container.decodeIfPresent(UUID.self, forKey: .aimTrack),
            effectChanges: try container.decodeIfPresent([ClipEffectChange].self, forKey: .effectChanges)?
                .filter { !$0.changesNothing } ?? []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, text, segments, muted, gainDb, normalizeGainDb, feel, tighten, tightenWhenOn, strength
        case stretch, isActiveTake, line, recordPlace, knobs, effects, aimTrack, effectChanges
    }

    /// Writes the clip. `knobs` is left out when no knob is set and `effects` when there is none, so a clip
    /// that uses neither is written exactly as before phase 33, and a Lockstep from before then reads a
    /// project that uses them without them. Every other field is written as it always was: a field that is
    /// nil is left out, and so is `aimTrack` of a clip that aims at the beat. `effectChanges` is left out when
    /// the clip changed nothing of its track's effects, so such a clip is written as before phase 36.5.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encode(segments, forKey: .segments)
        try container.encode(muted, forKey: .muted)
        try container.encode(gainDb, forKey: .gainDb)
        try container.encodeIfPresent(normalizeGainDb, forKey: .normalizeGainDb)
        try container.encode(feel, forKey: .feel)
        try container.encode(tighten, forKey: .tighten)
        try container.encode(tightenWhenOn, forKey: .tightenWhenOn)
        try container.encode(strength, forKey: .strength)
        try container.encode(stretch, forKey: .stretch)
        try container.encode(isActiveTake, forKey: .isActiveTake)
        try container.encode(line, forKey: .line)
        try container.encodeIfPresent(recordPlace, forKey: .recordPlace)
        if !knobs.isEmpty { try container.encode(knobs, forKey: .knobs) }
        if !effects.isEmpty { try container.encode(effects, forKey: .effects) }
        try container.encodeIfPresent(aimTrack, forKey: .aimTrack)
        let changes = effectChanges.filter { !$0.changesNothing }
        if !changes.isEmpty { try container.encode(changes, forKey: .effectChanges) }
    }

    /// How many characters of the text stand in for a name.
    public static let displayNameLength = 30

    /// What the clip's bar shows: the name if Max typed one, else the start
    /// of the text (`shortened`), else nothing.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let text, !text.isEmpty { return Clip.shortened(text) }
        return ""
    }

    /// The start of a text, as it stands in for a name: all of a text of 30
    /// characters or fewer, otherwise its first 30 characters with "…" after
    /// them. The cut is made between two words when there is a space to cut
    /// at, so the name does not end in half a word.
    public static func shortened(_ text: String) -> String {
        guard text.count > displayNameLength else { return text }
        var start = text.prefix(displayNameLength)
        // Cut inside a word: back to the space before that word, when there is one.
        if !text[start.endIndex].isWhitespace, let space = start.lastIndex(where: \.isWhitespace) {
            start = start[..<space]
        }
        // No space and no comma is left hanging before the dots.
        while let last = start.last, last.isWhitespace || last.isPunctuation {
            start = start.dropLast()
        }
        return start + "…"
    }

    /// Whether the clip's timing is corrected: Lines or All is chosen.
    public var hasTimingFix: Bool {
        tighten != .off
    }

    /// How much of the way each line of the clip slides, 0...1: the strength with Lines and with All, and
    /// nothing with Off.
    public var lineStrength: Double {
        tighten == .off ? 0 : strength
    }

    /// How much of the way each syllable of the clip moves by itself, 0...1: the strength with All, and
    /// nothing otherwise.
    public var syllableStrength: Double {
        tighten == .all ? strength : 0
    }

    /// Whether the clip's voice is ever stretched or squeezed: only with All, where syllables move, and
    /// Stretch on.
    public var stretchesVoice: Bool {
        tighten == .all && stretch
    }

    /// Gives the clip the correction of another clip: its choice with the one it switches back to, its
    /// strength, Stretch and what it aims at. A new take starts with what the take heard before it has.
    public mutating func takeCorrection(of other: Clip) {
        tighten = other.tighten
        tightenWhenOn = other.tightenWhenOn
        strength = other.strength
        stretch = other.stretch
        aimTrack = other.aimTrack
    }
}

/// One part of a recording that a clip plays.
public struct Segment: Codable, Sendable, Equatable {
    public var recordingID: UUID
    /// The first sample of the recording this segment plays.
    public var inSample: Int
    /// One past the last sample.
    public var outSample: Int
    /// How far it was moved from where it was recorded. Only moving a clip changes it. Phase 14.
    public var offsetSamples: Int
    /// Keeps a part as loud as it was when clips are joined, and when a clip that the safe limit holds back is
    /// cut or joined. It is added to the volume its clip is played with.
    public var gainDb: Double

    public init(recordingID: UUID, inSample: Int, outSample: Int, offsetSamples: Int = 0, gainDb: Double = 0) {
        self.recordingID = recordingID
        self.inSample = inSample
        self.outSample = outSample
        self.offsetSamples = offsetSamples
        self.gainDb = gainDb
    }

    /// Reads a saved segment. A missing field gets its default, except the
    /// recording it plays: without that the segment means nothing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            recordingID: try container.decode(UUID.self, forKey: .recordingID),
            inSample: try container.decodeIfPresent(Int.self, forKey: .inSample) ?? 0,
            outSample: try container.decodeIfPresent(Int.self, forKey: .outSample) ?? 0,
            offsetSamples: try container.decodeIfPresent(Int.self, forKey: .offsetSamples) ?? 0,
            gainDb: try container.decodeIfPresent(Double.self, forKey: .gainDb) ?? 0
        )
    }

    /// How many samples it plays.
    public var lengthSamples: Int {
        max(0, outSample - inSample)
    }
}

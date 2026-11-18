import Foundation

// The presets a track's Sound is chosen from: the six built-in ones, and the ones Max saves himself with "Save
// as Preset…".
//
//     track.sound = SoundPreset.builtIn(named: "Rap lead")?.sound      // a chosen preset is copied onto the track
//
//     settings.saveOwnPreset(named: "My hook", from: track.sound!, effects: track.effects)
//                                                                       // kept with the settings, not in a project
//     project.setTrack(trackID, preset: preset)                         // the Sound, and the preset's effects
//     settings[.ownPresets].presets                                     // for the menu, in the order they were saved
//     settings.removeOwnPreset(named: "My hook")                        // changes no track

/// A preset: a name, a character, where the four knobs start, and the effects a track gets with it.
public struct SoundPreset: Codable, Sendable, Equatable {
    /// One effect of a preset, or of a copied sound: what kind it is and how loud. It names no clip, no track
    /// and no project, so it can be kept with the settings and pasted anywhere.
    public struct Effect: Codable, Sendable, Equatable {
        public var kind: ClipEffect.Kind
        /// From -24 to +6 dB. 0 for a kind that replaces the voice and has no level.
        public var levelDb: Double

        public init(kind: ClipEffect.Kind, levelDb: Double) {
            self.kind = kind
            self.levelDb = kind.isLayer ? ClipEffect.level(clamped: levelDb) : 0
        }

        /// The kind and the level of an effect of a track or of a clip.
        public init(_ effect: ClipEffect) {
            self.init(kind: effect.kind, levelDb: effect.levelDb)
        }
    }

    /// What the menu shows.
    public var name: String
    public var character: SoundCharacter
    public var knobs: SoundKnobs
    /// The effects a track gets in place of its own when the preset is chosen for it. With none, as every
    /// built-in preset has, the track keeps the effects it has.
    public var effects: [Effect]

    public init(name: String, character: SoundCharacter, knobs: SoundKnobs, effects: [Effect] = []) {
        self.name = name
        self.character = character
        self.knobs = knobs
        self.effects = effects
    }

    private enum CodingKeys: String, CodingKey {
        case name, character, knobs, effects
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            character: try container.decode(SoundCharacter.self, forKey: .character),
            knobs: try container.decode(SoundKnobs.self, forKey: .knobs),
            effects: try container.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(character, forKey: .character)
        try container.encode(knobs, forKey: .knobs)
        if !effects.isEmpty { try container.encode(effects, forKey: .effects) }
    }

    /// The Sound a track gets when this preset is chosen for it: a copy, so the track never depends on the
    /// preset still being there.
    public var sound: TrackSound {
        TrackSound(name: name, character: character, knobs: knobs)
    }

    /// The six built-in presets, in the order of the menu. The knob positions are starting values, to be
    /// judged by Max's ear. What each character is beyond its knobs is in `SoundCharacters.swift`.
    public static let builtIn: [SoundPreset] = [
        //                                                  Squeeze      Tone        Warmth        Space
        preset("Rap lead", .rapLead, /*            */ squeeze: 70, tone: 55, warmth: 35, space: 8),
        preset("Rap double", .rapDouble, /*        */ squeeze: 80, tone: 50, warmth: 25, space: 12),
        preset("Ad-lib", .adLib, /*                */ squeeze: 80, tone: 100, warmth: 55, space: 25),
        preset("Sung lead", .sungLead, /*          */ squeeze: 50, tone: 55, warmth: 15, space: 35),
        preset("Sung hook", .sungHook, /*          */ squeeze: 60, tone: 65, warmth: 20, space: 45),
        preset("Backing voice", .backingVoice, /*  */ squeeze: 75, tone: 45, warmth: 10, space: 50),
    ]

    /// The built-in preset with this name, whatever its letters' case. Nil when there is none.
    public static func builtIn(named name: String) -> SoundPreset? {
        builtIn.first { SoundPresets.sameName($0.name, name) }
    }

    /// One row of the table above, with the knobs in percent as the panel shows them.
    private static func preset(
        _ name: String, _ character: SoundCharacter, squeeze: Double, tone: Double, warmth: Double, space: Double
    ) -> SoundPreset {
        SoundPreset(
            name: name,
            character: character,
            knobs: SoundKnobs(squeeze: squeeze / 100, tone: tone / 100, warmth: warmth / 100, space: space / 100)
        )
    }
}

/// Max's own presets, in the order he saved them. This is the value the settings store keeps, as one setting
/// (`sound.ownPresets`): they belong to Lockstep, not to a project.
public struct SoundPresets: Codable, SettingValue {
    public var presets: [SoundPreset]

    public init(presets: [SoundPreset] = []) {
        self.presets = presets
    }

    /// Keeps a preset. One that has the name already is replaced, where it stands in the list.
    ///
    /// Spaces and line breaks around the name are dropped first.
    ///
    /// - Returns: false, with nothing kept, when nothing is left of the name, or when it is the name of a
    ///   built-in preset: the menu would then show that name twice.
    @discardableResult
    public mutating func add(_ preset: SoundPreset) -> Bool {
        var preset = preset
        preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.name.isEmpty, SoundPreset.builtIn(named: preset.name) == nil else { return false }
        preset.knobs = preset.knobs.inWholePercent
        if let index = presets.firstIndex(where: { SoundPresets.sameName($0.name, preset.name) }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        return true
    }

    /// Forgets the preset with this name. A track that was given it keeps its Sound.
    ///
    /// - Returns: false when there is no such preset.
    @discardableResult
    public mutating func remove(named name: String) -> Bool {
        guard let index = presets.firstIndex(where: { SoundPresets.sameName($0.name, name) }) else { return false }
        presets.remove(at: index)
        return true
    }

    /// Whether two names are the same preset: the same letters, whatever their case.
    static func sameName(_ one: String, _ other: String) -> Bool {
        one.compare(other, options: .caseInsensitive) == .orderedSame
    }

    // MARK: In the settings store

    /// Reads the list as the store keeps it. A row that cannot be read (no name, or a character this Lockstep
    /// does not know) is left out and the others are kept. A row saved before presets had effects has none,
    /// and an effect of a kind this Lockstep does not know is skipped while the row keeps its others.
    public init?(stored: Any) {
        guard let rows = stored as? [Any] else { return nil }
        var presets = SoundPresets()
        for row in rows {
            guard let row = row as? [String: Any],
                  let name = row["name"] as? String,
                  let character = (row["character"] as? String).flatMap(SoundCharacter.init(rawValue:))
            else { continue }
            func knob(_ key: String) -> Double {
                row[key].flatMap { Double(stored: $0) } ?? 0
            }
            let effects = (row["effects"] as? [Any] ?? []).compactMap { effect -> SoundPreset.Effect? in
                guard let effect = effect as? [String: Any],
                      let kind = (effect["kind"] as? String).flatMap(ClipEffect.Kind.init(rawValue:))
                else { return nil }
                // A whole number written by hand is a level too.
                let level = (effect["levelDb"] as? NSNumber)?.doubleValue ?? effect["levelDb"].flatMap { Double(stored: $0) }
                return SoundPreset.Effect(kind: kind, levelDb: level ?? kind.startLevelDb)
            }
            presets.add(SoundPreset(
                name: name,
                character: character,
                knobs: SoundKnobs(squeeze: knob("squeeze"), tone: knob("tone"), warmth: knob("warmth"), space: knob("space")),
                effects: effects
            ))
        }
        self = presets
    }

    /// A preset without effects is kept as it was before presets had any: its row has no `effects`.
    public var storedForm: Any {
        presets.map { preset -> [String: Any] in
            var row: [String: Any] = [
                "name": preset.name,
                "character": preset.character.rawValue,
                "squeeze": preset.knobs.squeeze,
                "tone": preset.knobs.tone,
                "warmth": preset.knobs.warmth,
                "space": preset.knobs.space,
            ]
            if !preset.effects.isEmpty {
                row["effects"] = preset.effects.map { effect -> [String: Any] in
                    ["kind": effect.kind.rawValue, "levelDb": effect.levelDb]
                }
            }
            return row
        }
    }
}

extension SettingKey where Value == SoundPresets {
    /// Max's own presets of a track's Sound. App-wide, not part of a project.
    ///
    /// It is in no pane of the settings window: the presets are saved and deleted in the Sound menu of the
    /// panel on the right. So it is left out of `AppSettings.keys` on purpose, as `snapping` is: Restore
    /// Defaults in a pane must not delete them.
    public static var ownPresets: SettingKey {
        SettingKey("sound.ownPresets", pane: .general, default: SoundPresets())
    }
}

extension AppSettings {
    /// "Save as Preset…": keeps a track's Sound, its character and its four knobs, and the track's effects,
    /// under a name Max typed. A preset of his that has the name already is replaced, its effects too.
    ///
    /// - Parameter effects: the track's effects (`Track.effects`). The kind and the level of each are kept.
    /// - Returns: false, with nothing kept, when the name is empty or a built-in preset's (`SoundPresets.add`).
    @discardableResult
    public func saveOwnPreset(named name: String, from sound: TrackSound, effects: [ClipEffect] = []) -> Bool {
        var own = self[.ownPresets]
        let preset = SoundPreset(
            name: name, character: sound.character, knobs: sound.knobs, effects: effects.map(SoundPreset.Effect.init)
        )
        guard own.add(preset) else { return false }
        self[.ownPresets] = own
        return true
    }

    /// "Delete Preset": forgets one of Max's own presets. No track is changed.
    ///
    /// - Returns: false when there is no such preset.
    @discardableResult
    public func removeOwnPreset(named name: String) -> Bool {
        var own = self[.ownPresets]
        guard own.remove(named: name) else { return false }
        self[.ownPresets] = own
        return true
    }
}

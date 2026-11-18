import Foundation

// The presets a track's Voice is chosen from: the three built-in ones, and the ones Max saves himself with
// "Save as Preset…", after the pattern of a Sound's presets (`SoundPresets.swift`).
//
//     track.voice = VoicePresets.builtIn(named: "Darker")?.voice       // a chosen preset is copied onto the track
//
//     settings.saveOwnVoicePreset(named: "Villain", knobs: knobs)      // kept with the settings, not in a project
//     settings[.ownVoicePresets].presets                               // for the menu, in the order they were saved
//     settings.removeOwnVoicePreset(named: "Villain")                  // changes no track

/// A preset of a Voice: a name and where the two knobs stand.
public struct VoicePreset: Codable, Sendable, Equatable {
    /// What the menu shows.
    public var name: String
    public var knobs: VoiceKnobs

    public init(name: String, knobs: VoiceKnobs) {
        self.name = name
        self.knobs = knobs
    }

    /// The Voice a track gets when this preset is chosen for it, switched on: a copy, so the track never
    /// depends on the preset still being there.
    public var voice: TrackVoice {
        TrackVoice(isOn: true, name: name, knobs: knobs)
    }
}

/// Max's own presets of a Voice, in the order he saved them. This is the value the settings store keeps, as
/// one setting (`voices.ownPresets`): they belong to Lockstep, not to a project.
public struct VoicePresets: Codable, SettingValue {
    public var presets: [VoicePreset]

    public init(presets: [VoicePreset] = []) {
        self.presets = presets
    }

    /// The three built-in presets, in the order of the menu. The numbers are a first guess that no agent
    /// could hear: Max turns the knobs and saves his own.
    public static let builtIn: [VoicePreset] = [
        VoicePreset(name: "Darker", knobs: VoiceKnobs(depth: 6, pitch: -1)),
        VoicePreset(name: "Deeper", knobs: VoiceKnobs(depth: 10, pitch: -2)),
        VoicePreset(name: "Lighter", knobs: VoiceKnobs(depth: -6, pitch: 1)),
    ]

    /// The built-in preset with this name, whatever its letters' case. Nil when there is none.
    public static func builtIn(named name: String) -> VoicePreset? {
        builtIn.first { sameName($0.name, name) }
    }

    /// The preset with this name, whatever its letters' case: a built-in one, or else one of Max's own. Nil
    /// when there is none.
    public func preset(named name: String) -> VoicePreset? {
        VoicePresets.builtIn(named: name) ?? presets.first { VoicePresets.sameName($0.name, name) }
    }

    /// Keeps the knobs under a name. One of Max's own presets that has the name already is replaced, where it
    /// stands in the list, as with a Sound's presets.
    ///
    /// Spaces and line breaks around the name are dropped first.
    ///
    /// - Returns: false, with nothing kept, when nothing is left of the name, or when the name is taken by
    ///   what Max cannot replace: a built-in preset, or "Custom", which the menu shows for a Voice that is no
    ///   preset's. The menu would then show that name for two different things.
    @discardableResult
    public mutating func save(named name: String, knobs: VoiceKnobs) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              VoicePresets.builtIn(named: name) == nil,
              !VoicePresets.sameName(name, TrackVoice.customName)
        else { return false }
        let preset = VoicePreset(name: name, knobs: knobs)
        if let index = presets.firstIndex(where: { VoicePresets.sameName($0.name, name) }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        return true
    }

    /// Forgets the preset with this name. A track that was given it keeps its Voice.
    ///
    /// - Returns: false when there is no such preset.
    @discardableResult
    public mutating func remove(named name: String) -> Bool {
        guard let index = presets.firstIndex(where: { VoicePresets.sameName($0.name, name) }) else { return false }
        presets.remove(at: index)
        return true
    }

    /// Whether two names are the same preset: the same letters, whatever their case.
    static func sameName(_ one: String, _ other: String) -> Bool {
        one.compare(other, options: .caseInsensitive) == .orderedSame
    }

    // MARK: In the settings store

    /// Reads the list as the store keeps it: rows with `name`, `depth` and `pitch`. A row that cannot be read
    /// (no name, or a name that may not be kept) is left out and the others are kept. A knob that is missing
    /// is in the middle, and one outside its range is brought inside.
    public init?(stored: Any) {
        guard let rows = stored as? [Any] else { return nil }
        var presets = VoicePresets()
        for row in rows {
            guard let row = row as? [String: Any], let name = row["name"] as? String else { continue }
            // A whole number written by hand is a knob's value too.
            func knob(_ key: String) -> Double {
                (row[key] as? NSNumber)?.doubleValue ?? row[key].flatMap { Double(stored: $0) } ?? 0
            }
            presets.save(
                named: name,
                knobs: VoiceKnobs(depth: VoiceKnobs.depth(clamped: knob("depth")), pitch: knob("pitch"))
            )
        }
        self = presets
    }

    public var storedForm: Any {
        presets.map { preset -> [String: Any] in
            ["name": preset.name, "depth": preset.knobs.depth, "pitch": preset.knobs.pitch]
        }
    }
}

extension SettingKey where Value == VoicePresets {
    /// Max's own presets of a track's Voice. App-wide, not part of a project.
    ///
    /// It is in no pane of the settings window: the presets are saved and deleted in the Voice menu of the
    /// panel on the right. So it is left out of `AppSettings.keys` on purpose, as the Sound's presets are:
    /// Restore Defaults in a pane must not delete them.
    public static var ownVoicePresets: SettingKey {
        SettingKey("voices.ownPresets", pane: .general, default: VoicePresets())
    }
}

extension AppSettings {
    /// "Save as Preset…": keeps a Voice's two knobs under a name Max typed. A preset of his that has the
    /// name already is replaced.
    ///
    /// - Returns: false, with nothing kept, when the name is empty or taken (`VoicePresets.save`).
    @discardableResult
    public func saveOwnVoicePreset(named name: String, knobs: VoiceKnobs) -> Bool {
        var own = self[.ownVoicePresets]
        guard own.save(named: name, knobs: knobs) else { return false }
        self[.ownVoicePresets] = own
        return true
    }

    /// "Delete Preset": forgets one of Max's own presets of a Voice. No track is changed.
    ///
    /// - Returns: false when there is no such preset.
    @discardableResult
    public func removeOwnVoicePreset(named name: String) -> Bool {
        var own = self[.ownVoicePresets]
        guard own.remove(named: name) else { return false }
        self[.ownVoicePresets] = own
        return true
    }
}

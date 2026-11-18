/// How often the click sounds.
public enum ClickDivision: String, Codable, CaseIterable, Sendable {
    /// On every beat.
    case beats
    /// On every beat and halfway to the next one.
    case halfBeats
    /// On every sub-beat, evenly spaced: four times per beat in 16ths and six times in Triplets
    /// (`ClickSettings.subBeats`).
    case subBeats
}

/// The click of one song: whether it is on, its sound, its volume, how often
/// it clicks and how a beat is divided when it clicks on sub-beats. It is
/// changed while working and is saved with the project.
///
/// A new song starts with what Settings says under "New songs" (the app hands
/// those values in). A field that is missing in a saved project gets the
/// starting value of its setting, which `AppSettings.swift` holds.
public struct ClickSettings: Codable, Sendable, Equatable {
    public var isOn: Bool
    public var sound: ClickSound
    /// From 0 (silent) to 1 (full).
    public var volume: Double
    public var division: ClickDivision
    /// How a beat is divided while the click sounds on sub-beats: 16ths or Triplets. It is the click's own
    /// choice, because the song has none since phase 27 and each clip has its own. It starts on 16ths, also
    /// in a project whose song was on Triplets before: the click always sounded four times a beat.
    public var subBeats: SubBeatGrid

    public init(
        isOn: Bool = false,
        sound: ClickSound = SettingKey<ClickSound>.clickDefaultSound.defaultValue,
        volume: Double = SettingKey<Double>.clickDefaultVolume.defaultValue,
        division: ClickDivision = SettingKey<ClickDivision>.clickDefaultDivision.defaultValue,
        subBeats: SubBeatGrid = .sixteenths
    ) {
        self.isOn = isOn
        self.sound = sound
        self.volume = min(max(volume, 0), 1)
        self.division = division
        self.subBeats = subBeats
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = ClickSettings()
        self.init(
            isOn: try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? fresh.isOn,
            sound: try container.decodeIfPresent(ClickSound.self, forKey: .sound) ?? fresh.sound,
            volume: try container.decodeIfPresent(Double.self, forKey: .volume) ?? fresh.volume,
            division: try container.decodeIfPresent(ClickDivision.self, forKey: .division) ?? fresh.division,
            subBeats: try container.decodeIfPresent(SubBeatGrid.self, forKey: .subBeats) ?? fresh.subBeats
        )
    }

    /// How many clicks one beat gets, the beat's own click included.
    public var clicksPerBeat: Int {
        switch division {
        case .beats: 1
        case .halfBeats: 2
        case .subBeats: subBeats.perBeat
        }
    }

    /// What the click's samples are multiplied by, when it is played and when
    /// it is written to a file. The rendered click (`ClickRenderer`) does not
    /// have the volume in it, so both use this one number and stay the same.
    public var gain: Float {
        Float(min(max(volume, 0), 1))
    }
}

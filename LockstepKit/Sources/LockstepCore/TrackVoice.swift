import Foundation

// A track's Voice: a switch, the name of a preset and two knobs. The voice of every recording on the track is
// made again with the knobs and stands in for the recording.
//
//     track.voice = TrackVoice(name: "Darker", knobs: VoiceKnobs(depth: 6, pitch: -1))
//     track.voice?.isHeard                      // on, and the knobs change something
//     track.voice?.knobs.folderName             // "d+06p-1.0", the setting as a folder's name

/// The two knobs of a Voice, which together are a setting. Both go in steps, so two settings that are almost
/// equal are the same setting and share their files, and a setting can be a folder's name.
///
/// A value outside its range is brought inside, and one between two steps to the nearer step, whoever sets it:
/// the panel, a project file or a preset written by hand.
public struct VoiceKnobs: Codable, Sendable, Hashable {
    /// How far Depth goes, in whole percent.
    public static let depthRange = -15...15
    /// How far Pitch goes, in semitones.
    public static let pitchRange: ClosedRange<Double> = -4...4
    /// The distance between two values of Pitch next to each other: half a semitone.
    public static let pitchStep = 0.5

    /// Depth, in whole percent. Positive is deeper: at 8 every resonance of the voice sits 8 % lower.
    public var depth: Int {
        didSet { depth = VoiceKnobs.depth(clamped: Double(depth)) }
    }

    /// Pitch, in semitones, in half steps. Negative is lower.
    public var pitch: Double {
        didSet { pitch = VoiceKnobs.pitch(clamped: pitch) }
    }

    public init(depth: Int = 0, pitch: Double = 0) {
        self.depth = VoiceKnobs.depth(clamped: Double(depth))
        self.pitch = VoiceKnobs.pitch(clamped: pitch)
    }

    /// Both knobs in the middle, which is the recording itself: nothing is made for it.
    public static let neutral = VoiceKnobs()

    /// Whether both knobs are in the middle.
    public var isNeutral: Bool {
        depth == 0 && pitch == 0
    }

    /// A Depth inside its range, as a whole percent. A value that is not a number is the middle.
    public static func depth(clamped value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        return Int(min(max(value.rounded(), Double(depthRange.lowerBound)), Double(depthRange.upperBound)))
    }

    /// A Pitch inside its range, on a half step. A value that is not a number is the middle.
    public static func pitch(clamped value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        let stepped = (min(max(value, pitchRange.lowerBound), pitchRange.upperBound) / pitchStep).rounded() * pitchStep
        // A small negative value rounds to minus zero, which would be written as "-0" and named "p-0.0".
        return stepped == 0 ? 0 : stepped
    }

    /// The setting as the name of a folder in the project's cache: `d+06p-1.0` for Depth 6 and Pitch -1,
    /// `d-06p+1.5` for Depth -6 and Pitch 1.5. Each number has its sign and always as many digits, so the
    /// names are as long as each other and no two settings share one.
    public var folderName: String {
        let depthDigits = abs(depth) < 10 ? "0\(abs(depth))" : "\(abs(depth))"
        return "d\(depth < 0 ? "-" : "+")\(depthDigits)p\(pitch < 0 ? "-" : "+")\(abs(pitch))"
    }

    private enum CodingKeys: String, CodingKey {
        case depth, pitch
    }

    /// Reads saved knobs. A missing one is in the middle, and a Depth with decimals, written by hand, is the
    /// nearest whole percent.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            depth: VoiceKnobs.depth(clamped: try container.decodeIfPresent(Double.self, forKey: .depth) ?? 0),
            pitch: try container.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
        )
    }
}

/// The Voice of a track: whether it is on, the name of the preset it was chosen as, and the two knobs. A
/// chosen preset is copied here, so a project never depends on a preset still being there.
///
/// A Voice that is switched off stays on the track with its knobs, as a clip that is Off keeps its
/// correction. That is how Max compares with his own voice.
public struct TrackVoice: Codable, Sendable, Equatable {
    /// The name a Voice has after a knob was turned, when it is no preset's any more.
    public static let customName = "Custom"

    /// The switch. Off, every clip of the track is heard in Max's own voice.
    public var isOn: Bool
    /// What the menu shows: the preset it was chosen as, or "Custom" after a knob was turned.
    public var name: String
    public var knobs: VoiceKnobs
    /// Whether the voices are made by the voice model after the Fast ones. It is read only when the Natural
    /// quality is built (`FeatureSet.naturalVoice`).
    public var natural: Bool

    public init(isOn: Bool = true, name: String = TrackVoice.customName, knobs: VoiceKnobs, natural: Bool = false) {
        self.isOn = isOn
        self.name = name
        self.knobs = knobs
        self.natural = natural
    }

    /// Whether the track's clips are heard in another voice than Max's own: the Voice is on, and its knobs
    /// are not both in the middle. Only then does a made voice stand in for a recording.
    public var isHeard: Bool {
        isOn && !knobs.isNeutral
    }

    private enum CodingKeys: String, CodingKey {
        case isOn = "on"
        case name, depth, pitch, natural
    }

    /// Reads a saved Voice: `{"on": true, "name": "Darker", "depth": 6, "pitch": -1}`. A missing field gets
    /// its default: on, "Custom", both knobs in the middle, and not Natural.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.init(
            isOn: try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? true,
            name: name.isEmpty ? TrackVoice.customName : name,
            knobs: try VoiceKnobs(from: decoder),
            natural: try container.decodeIfPresent(Bool.self, forKey: .natural) ?? false
        )
    }

    /// Writes the Voice with its knobs beside its name, not inside a group of their own. `natural` is written
    /// only when it is on, so a Voice of the Fast way is the same text whether or not Natural is built.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isOn, forKey: .isOn)
        try container.encode(name, forKey: .name)
        try container.encode(knobs.depth, forKey: .depth)
        try container.encode(knobs.pitch, forKey: .pitch)
        if natural { try container.encode(true, forKey: .natural) }
    }
}

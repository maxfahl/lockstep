import Foundation

// What each kind of effect is, as numbers: the one table of the kinds of effects.
// Whoever lists the kinds in a menu, shows a level or makes the sound reads it here.
//
//     ClipEffect.Kind.lowOctave.menuName        // "Low, an octave down"
//     ClipEffect.Kind.lowOctave.startLevelDb    // -10
//     ClipEffect.Kind.phone.isLayer             // false: it replaces the voice and has no level
//     DoubleLayers.plan(for: .thick)            // the two copies a Thick double is made of

extension ClipEffect.Kind {
    /// What the menu that adds an effect calls this kind.
    public var menuName: String {
        switch self {
        case .thick: "Thick"
        case .lowFourth: "Low, a fourth down"
        case .lowOctave: "Low, an octave down"
        case .high: "High"
        case .big: "Big"
        case .small: "Small"
        case .echoQuarter: "Echo, quarter notes"
        case .echoEighth: "Echo, eighth notes"
        case .phone: "Phone"
        case .stutter: "Stutter"
        case .tapeStop: "Tape stop"
        case .swell: "Swell"
        }
    }

    /// The level a new effect of this kind starts at, in dB. 0 for a kind that has no level.
    public var startLevelDb: Double {
        switch self {
        case .thick, .big, .small: -9
        case .lowFourth, .swell: -8
        case .lowOctave: -10
        case .high: -16
        case .echoQuarter, .echoEighth: -6
        case .phone, .stutter, .tapeStop: 0
        }
    }

    /// Whether this kind is a sound added beside the voice, with a level of its own. The other kinds replace
    /// the voice on their stretch, and have no level and show none.
    public var isLayer: Bool {
        switch self {
        case .thick, .lowFourth, .lowOctave, .high, .big, .small, .echoQuarter, .echoEighth, .swell: true
        case .phone, .stutter, .tapeStop: false
        }
    }

    /// Whether this kind is one of the six doubles of phase 34, made by `DoubleLayers.plan(for:)`.
    public var isDouble: Bool {
        switch self {
        case .thick, .lowFourth, .lowOctave, .high, .big, .small: true
        case .echoQuarter, .echoEighth, .phone, .stutter, .tapeStop, .swell: false
        }
    }

    /// Whether the sound of this kind depends on where the song's beats are: the echoes, whose repeats are
    /// placed by the beats, the stutter, which repeats on the sub-beats, and the swell, which is one beat
    /// long. A clip with such an effect is made again when it is moved.
    public var followsBeats: Bool {
        switch self {
        case .echoQuarter, .echoEighth, .stutter, .swell: true
        case .thick, .lowFourth, .lowOctave, .high, .big, .small, .phone, .tapeStop: false
        }
    }
}

extension ClipEffect {
    /// The lowest and highest level an effect can have, in dB.
    public static let levelRange: ClosedRange<Double> = -24...6

    /// A level brought into `levelRange`. Something that is no number becomes 0.
    public static func level(clamped levelDb: Double) -> Double {
        guard levelDb.isFinite else { return 0 }
        return min(max(levelDb, levelRange.lowerBound), levelRange.upperBound)
    }
}

/// What each double is made of, as numbers. `FinishedSoundRenderer` makes one layer for each entry from the
/// effect's stretch of the dry sound (`VoiceShifter.shift(_:semitones:formantScale:)`), moves it later by
/// its delay, puts it on its side and adds it at the effect's level.
public enum DoubleLayers {
    /// Where a layer is heard.
    public enum Side: Sendable, Equatable {
        case left, middle, right
    }

    /// One copy of the voice.
    public struct Layer: Sendable, Equatable {
        /// How many semitones up it is pitched. Negative is down.
        public var semitones: Double
        /// How many hundredths of a semitone more, for the small detune of Thick.
        public var cents: Double
        /// How large the throat sounds: 1 is the voice's own, below 1 larger, above 1 smaller.
        public var formantScale: Double
        /// How much later than the voice it is heard, in milliseconds.
        public var delayMs: Double
        public var side: Side

        public init(
            semitones: Double = 0,
            cents: Double = 0,
            formantScale: Double = 1,
            delayMs: Double = 0,
            side: Side = .middle
        ) {
            self.semitones = semitones
            self.cents = cents
            self.formantScale = formantScale
            self.delayMs = delayMs
            self.side = side
        }

        /// The pitch change the stretching library is handed: the semitones with the cents.
        public var pitchSemitones: Double {
            semitones + cents / 100
        }

        /// The delay in whole samples.
        public var delaySamples: Int {
            Int((delayMs * Lockstep.sampleRate / 1_000).rounded())
        }
    }

    /// The fade at both ends of a layer that is on a stretch, in milliseconds.
    public static let fadeMs: Double = 10

    /// The layers a double of this kind is made of. Empty for a kind that is no double.
    public static func plan(for kind: ClipEffect.Kind) -> [Layer] {
        switch kind {
        case .thick:
            [
                Layer(cents: -9, delayMs: 12, side: .left),
                Layer(cents: 9, delayMs: 19, side: .right),
            ]
        case .lowFourth: [Layer(semitones: -5)]
        case .lowOctave: [Layer(semitones: -12)]
        case .high: [Layer(semitones: 12)]
        case .big: [Layer(formantScale: 0.88, delayMs: 15)]
        case .small: [Layer(formantScale: 1.12, delayMs: 15)]
        case .echoQuarter, .echoEighth, .phone, .stutter, .tapeStop, .swell: []
        }
    }
}

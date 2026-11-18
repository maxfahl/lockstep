import Foundation

/// The numbers of every part of the voice chain, in the order the parts act: low cut, de-ess, squeeze, tone,
/// warmth, space. `SoundCharacter.parameters(_:)` is the only place that turns a character and four knob
/// positions into these, and `VoiceChain` in LockstepAudio applies them.
public struct ChainParameters: Sendable, Equatable {
    /// Where the low cut begins. It has no knob.
    public var lowCutHz: Double
    public var deEss: DeEss
    /// The slow ride of the level before the squeeze, which only the sung characters have. Nil: no ride.
    public var ride: Ride?
    public var squeeze: Squeeze
    /// The bands of the tone, three or four.
    public var tone: [ToneBand]
    /// How much of the distortion is mixed in, from 0 to 1.
    public var warmth: Double
    /// Nil: no reverb.
    public var reverb: Reverb?
    /// Nil: no echo.
    public var echo: Echo?

    public init(
        lowCutHz: Double,
        deEss: DeEss,
        ride: Ride? = nil,
        squeeze: Squeeze,
        tone: [ToneBand],
        warmth: Double,
        reverb: Reverb? = nil,
        echo: Echo? = nil
    ) {
        self.lowCutHz = lowCutHz
        self.deEss = deEss
        self.ride = ride
        self.squeeze = squeeze
        self.tone = tone
        self.warmth = warmth
        self.reverb = reverb
        self.echo = echo
    }

    /// Turning the band of the s sounds down while an s is sharper than the threshold.
    public struct DeEss: Sendable, Equatable {
        public var thresholdDb: Double
        /// The most the band is turned down.
        public var maxCutDb: Double

        public init(thresholdDb: Double, maxCutDb: Double) {
            self.thresholdDb = thresholdDb
            self.maxCutDb = maxCutDb
        }
    }

    /// Riding the level slowly, so that quiet endings are heard.
    public struct Ride: Sendable, Equatable {
        /// The most the level is turned up.
        public var maxGainDb: Double
        public var speedMs: Double

        public init(maxGainDb: Double, speedMs: Double) {
            self.maxGainDb = maxGainDb
            self.speedMs = speedMs
        }
    }

    /// Evening out loud and quiet words.
    public struct Squeeze: Sendable, Equatable {
        public var thresholdDb: Double
        /// 1 is no levelling.
        public var ratio: Double
        public var attackMs: Double
        public var releaseMs: Double
        public var makeupDb: Double

        public init(thresholdDb: Double, ratio: Double, attackMs: Double, releaseMs: Double, makeupDb: Double) {
            self.thresholdDb = thresholdDb
            self.ratio = ratio
            self.attackMs = attackMs
            self.releaseMs = releaseMs
            self.makeupDb = makeupDb
        }
    }

    /// One band of the tone.
    public struct ToneBand: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case bell, lowShelf, highShelf, highPass, lowPass
        }

        public var kind: Kind
        public var hz: Double
        public var gainDb: Double
        public var q: Double

        public init(kind: Kind, hz: Double, gainDb: Double, q: Double) {
            self.kind = kind
            self.hz = hz
            self.gainDb = gainDb
            self.q = q
        }
    }

    /// The reverb of the space.
    public struct Reverb: Sendable, Equatable {
        public enum Room: Sendable, Equatable {
            case smallRoom, plate, largeHall
        }

        public var room: Room
        /// How much of the reverb is mixed in, from 0 to 1.
        public var mix: Double

        public init(room: Room, mix: Double) {
            self.room = room
            self.mix = mix
        }
    }

    /// The echo of the space, which follows the song's beats.
    public struct Echo: Sendable, Equatable {
        public enum Note: Sendable, Equatable {
            case quarter, eighth
        }

        /// The note the repeats are on.
        public var note: Note
        public var levelDb: Double

        public init(note: Note, levelDb: Double) {
            self.note = note
            self.levelDb = levelDb
        }
    }
}

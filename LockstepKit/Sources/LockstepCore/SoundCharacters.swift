import Foundation

// The table that turns a character and four knob positions into the numbers of the voice chain. It is the
// only place that does.
//
//     let chain = SoundCharacter.rapLead.parameters(SoundKnobs(squeeze: 0.7, tone: 0.55, warmth: 0.35, space: 0.08))
//
// Every number here is a starting value, to be judged by Max's ear. A character is written as what it is with
// all four knobs at 100 % (`SoundCharacter.full`), and `parameters(_:)` scales that by the knobs.

extension SoundCharacter {
    /// What a character is with all four knobs at 100 %: one row of the table.
    struct Full {
        /// Where the low cut begins. No knob moves it.
        var lowCutHz: Double
        /// The de-esser, which no knob moves either: how sharp an s must be against the whole voice before it
        /// is turned down, and the most it is turned down, both in dB.
        var deEss: (thresholdDb: Double, maxCutDb: Double)
        /// The levelling at full Squeeze: its ratio, how fast it reacts and lets go, and the threshold it has
        /// with the knob at 50 %, in dBFS.
        var squeeze: (ratio: Double, attackMs: Double, releaseMs: Double, thresholdAtHalfDb: Double)
        /// The most the slow ride turns a quiet word up, at full Squeeze, in dB. Nil: the level is not ridden.
        var rideDb: Double?
        /// The tone's bands at full Tone. A bell or a shelf has its full gain here. A high-pass or a low-pass
        /// stands where it ends up, and comes in from outside the voice as the knob is turned up.
        var tone: [ChainParameters.ToneBand]
        /// How much of the grit is mixed in at full Warmth, from 0 to 1.
        var warmth: Double
        /// The room, and how much of it is mixed in at full Space, from 0 to 1.
        var room: (ChainParameters.Reverb.Room, mix: Double)
        /// The echo's note, and the level of its first repeat at full Space, in dB. Nil: no echo.
        var echo: (ChainParameters.Echo.Note, levelDb: Double)?
    }

    /// The table. Hz for where, dB for how much, ms for how fast.
    var full: Full {
        switch self {
        // Hard, fast levelling. Less mud, forward at 3 kHz, a little air. A small room.
        case .rapLead: Full(
            lowCutHz: 90,
            deEss: (thresholdDb: -14, maxCutDb: 8),
            squeeze: (ratio: 6, attackMs: 3, releaseMs: 60, thresholdAtHalfDb: -18),
            rideDb: nil,
            tone: [.bell(300, -5), .bell(3_000, 5), .highShelf(10_000, 3)],
            warmth: 0.6,
            room: (.smallRoom, mix: 0.5),
            echo: nil
        )
        // Harder levelling than the lead, and a little less top, so it sits behind the lead.
        case .rapDouble: Full(
            lowCutHz: 140,
            deEss: (thresholdDb: -14, maxCutDb: 10),
            squeeze: (ratio: 8, attackMs: 2, releaseMs: 50, thresholdAtHalfDb: -20),
            rideDb: nil,
            tone: [.bell(300, -5), .bell(3_000, 2.5), .highShelf(9_000, -4)],
            warmth: 0.5,
            room: (.smallRoom, mix: 0.5),
            echo: nil
        )
        // Thin, like a phone: only 350 Hz to 3.4 kHz gets through at full Tone. A quiet echo on eighth notes.
        case .adLib: Full(
            lowCutHz: 150,
            deEss: (thresholdDb: -14, maxCutDb: 6),
            squeeze: (ratio: 8, attackMs: 3, releaseMs: 60, thresholdAtHalfDb: -20),
            rideDb: nil,
            tone: [.highPass(350), .bell(1_800, 3), .lowPass(3_400)],
            warmth: 0.8,
            room: (.smallRoom, mix: 0.6),
            echo: (.eighth, levelDb: -10)
        )
        // The level is ridden first, then gentle levelling. Less at 250 Hz, a little at 4 kHz, air from 12 kHz.
        // A plate and an echo on quarter notes.
        case .sungLead: Full(
            lowCutHz: 80,
            deEss: (thresholdDb: -14, maxCutDb: 6),
            squeeze: (ratio: 3, attackMs: 15, releaseMs: 150, thresholdAtHalfDb: -18),
            rideDb: 6,
            tone: [.bell(250, -4), .bell(4_000, 3), .highShelf(12_000, 4)],
            warmth: 0.4,
            room: (.plate, mix: 0.6),
            echo: (.quarter, levelDb: -8)
        )
        // As Sung lead, with more air, a large hall and the echo on eighth notes.
        case .sungHook: Full(
            lowCutHz: 80,
            deEss: (thresholdDb: -14, maxCutDb: 6),
            squeeze: (ratio: 3, attackMs: 15, releaseMs: 150, thresholdAtHalfDb: -18),
            rideDb: 6,
            tone: [.bell(250, -4), .bell(4_000, 3), .highShelf(12_000, 6)],
            warmth: 0.4,
            room: (.largeHall, mix: 0.6),
            echo: (.eighth, levelDb: -8)
        )
        // Firm levelling. Less at 300 Hz, held back where a lead is forward, and less top, so it stays behind.
        // A large hall.
        case .backingVoice: Full(
            lowCutHz: 160,
            deEss: (thresholdDb: -16, maxCutDb: 10),
            squeeze: (ratio: 5, attackMs: 5, releaseMs: 100, thresholdAtHalfDb: -20),
            rideDb: nil,
            tone: [.bell(300, -5), .bell(2_500, -2), .highShelf(8_000, -6)],
            warmth: 0.4,
            room: (.largeHall, mix: 0.7),
            echo: nil
        )
        }
    }

    /// How far the levelling's threshold falls from Squeeze at 0 % to 100 %, in dB: 6 dB for each half.
    static let thresholdSpanDb = 12.0
    /// How loud a loud word of a normalised clip is where the levelling measures it, in dBFS. The make-up gain
    /// gives back what the levelling takes from a sound this loud, so that turning Squeeze changes how even
    /// the voice is more than how loud it is.
    static let loudWordDb = -10.0
    /// How fast the slow ride follows the level, in milliseconds.
    static let rideSpeedMs = 300.0
    /// Where a high-pass and a low-pass of the tone stand with Tone just above 0 %, in Hz: below any low cut
    /// and above the voice, where they take nothing away. From there they come in as the knob is turned up.
    static let passOpenHz = (high: 40.0, low: 20_000.0)

    /// The numbers of the voice chain for this character with the knobs at these positions. A knob outside
    /// 0...1 counts as its nearest end.
    ///
    /// How each knob scales its part:
    /// - Squeeze: 0 % is no levelling (a ratio of 1), 100 % the character's full ratio, with the threshold
    ///   falling 6 dB from 50 % to 100 %. The make-up gain follows (`loudWordDb`), and in the sung characters
    ///   so does how far the ride turns quiet words up.
    /// - Tone: every bell's and shelf's gain is the knob times its full gain, so 0 % is flat. A high-pass or a
    ///   low-pass (the Ad-lib's phone) is left out at 0 % and comes in from outside the voice to where the
    ///   table has it at 100 %. The low cut stays whatever the knob says.
    /// - Warmth: the knob times the most grit the character allows.
    /// - Space: the knob times the most reverb the character allows, and the echo's level falls with it. 0 % is
    ///   dry: no reverb and no echo.
    public func parameters(_ knobs: SoundKnobs) -> ChainParameters {
        func held(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }
        let squeeze = held(knobs.squeeze)
        let tone = held(knobs.tone)
        let warmth = held(knobs.warmth)
        let space = held(knobs.space)
        let full = full

        let ratio = 1 + (full.squeeze.ratio - 1) * squeeze
        let threshold = full.squeeze.thresholdAtHalfDb - Self.thresholdSpanDb * (squeeze - 0.5)
        let bands = full.tone.compactMap { band -> ChainParameters.ToneBand? in
            var band = band
            switch band.kind {
            case .bell, .lowShelf, .highShelf:
                band.gainDb *= tone
            case .highPass, .lowPass:
                guard tone > 0 else { return nil }
                // The same share of the way at every knob position, counted in octaves. At 100 % it stands
                // exactly where the table has it.
                let open = band.kind == .highPass ? Self.passOpenHz.high : Self.passOpenHz.low
                if tone < 1 { band.hz = open * pow(band.hz / open, tone) }
            }
            return band
        }
        return ChainParameters(
            lowCutHz: full.lowCutHz,
            deEss: .init(thresholdDb: full.deEss.thresholdDb, maxCutDb: full.deEss.maxCutDb),
            ride: full.rideDb.flatMap { reach in
                squeeze > 0 ? .init(maxGainDb: reach * squeeze, speedMs: Self.rideSpeedMs) : nil
            },
            squeeze: .init(
                thresholdDb: threshold,
                ratio: ratio,
                attackMs: full.squeeze.attackMs,
                releaseMs: full.squeeze.releaseMs,
                makeupDb: max(Self.loudWordDb - threshold, 0) * (1 - 1 / ratio)
            ),
            tone: bands,
            warmth: full.warmth * warmth,
            reverb: space > 0 ? .init(room: full.room.0, mix: full.room.mix * space) : nil,
            echo: full.echo.flatMap { echo in
                space > 0 ? .init(note: echo.0, levelDb: echo.levelDb + 20 * log10(space)) : nil
            }
        )
    }
}

/// The short ways the table writes a band of the tone.
private extension ChainParameters.ToneBand {
    /// A lift or a cut around `hz`, about an octave and a half wide.
    static func bell(_ hz: Double, _ gainDb: Double) -> Self {
        .init(kind: .bell, hz: hz, gainDb: gainDb, q: 1)
    }

    /// A lift or a cut of everything above `hz`.
    static func highShelf(_ hz: Double, _ gainDb: Double) -> Self {
        .init(kind: .highShelf, hz: hz, gainDb: gainDb, q: 0.7)
    }

    /// Only what lies above `hz` gets through.
    static func highPass(_ hz: Double) -> Self {
        .init(kind: .highPass, hz: hz, gainDb: 0, q: 0.7)
    }

    /// Only what lies below `hz` gets through.
    static func lowPass(_ hz: Double) -> Self {
        .init(kind: .lowPass, hz: hz, gainDb: 0, q: 0.7)
    }
}

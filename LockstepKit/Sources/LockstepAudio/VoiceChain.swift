import Accelerate
import AudioToolbox
import AVFoundation
import LockstepCore

/// The voice chain of a track's Sound: step 5 of making a clip's finished sound.
///
/// It applies the numbers of `ChainParameters` to a sound in stereo, the parts in this order: low cut,
/// de-ess, squeeze, tone, warmth, space. Left and right are worked together.
///
///     let finished = VoiceChain.render(voice, parameters: parameters, beats: recipe.beats)
///     // as long as `voice` plus what rings after it
///
/// What each part is made of:
/// - Low cut and tone: Apple's EQ unit.
/// - De-ess: our own `DeEsser`.
/// - Squeeze: our own `LevelRider` where the character has a ride, then our own `Squeezer` (Apple's dynamics
///   unit has no ratio and answers late; see `Squeezer`).
/// - Warmth: the soft clip of Apple's distortion unit, with everything else in that unit switched off.
/// - Space: Apple's reverb unit, and our own `BeatEcho`.
///
/// The Apple units run in an audio engine in manual rendering mode, through `OfflineUnits`: no sound device
/// is opened and nothing is heard. Every call makes its own units and engines and keeps none, so it may be
/// called from any thread, several calls at a time.
///
/// The two promises, both tested:
/// - Nothing moves the voice. A click at sample n has its peak at sample n of the answer, within one sample.
///   The parts that are only a gain cannot move it. The tone can, where it lets only the low part of the
///   voice through, so its delay is measured on every call and taken out. Reverb and echo are added beside
///   the voice, which itself goes through neither.
/// - The same call gives the same answer. Every part starts from rest on every call, and Apple's units were
///   measured to answer with the very same samples each time, the reverb too.
///
/// A unit that cannot be made or does not answer leaves its part out, and the rest of the chain is applied.
public enum VoiceChain {
    /// The sound through the chain. The answer is longer than the sound by its tail: what the reverb and the
    /// echo ring after it, cut and faded as `SoundTail` says. Without reverb and echo it is as long as the
    /// sound.
    ///
    /// - Parameter beats: the song's beats as samples of the sound, for the echo. Empty: no echo.
    public static func render(_ sound: StereoSound, parameters: ChainParameters, beats: [Double]) -> StereoSound {
        guard !sound.left.isEmpty, sound.left.count == sound.right.count else { return sound }
        var voice = lowCut(sound, hz: parameters.lowCutHz)
        voice = DeEsser.render(voice, parameters: parameters.deEss)
        if let ride = parameters.ride {
            voice = LevelRider.render(voice, parameters: ride)
        }
        voice = Squeezer.render(voice, parameters: parameters.squeeze)
        voice = tone(voice, bands: parameters.tone)
        voice = warmth(voice, amount: parameters.warmth)
        return space(voice, reverb: parameters.reverb, echo: parameters.echo, beats: beats)
    }

    // MARK: Low cut and tone

    /// The sound without what lies below `hz`: rumble, so that it does not drive the squeeze.
    static func lowCut(_ sound: StereoSound, hz: Double) -> StereoSound {
        guard hz > 0 else { return sound }
        let band = ChainParameters.ToneBand(kind: .highPass, hz: hz, gainDb: 0, q: 0.7)
        return OfflineUnits.render(sound, through: [equalizer([band])]) ?? sound
    }

    /// The sound with the tone's bands applied, and not moved in time.
    ///
    /// A band that lifts or cuts leaves a click on its sample. A band that lets only the low part through
    /// (`lowPass`) does not: at 3.4 kHz the click's peak comes 3 samples late. So the delay of these bands
    /// together is measured with a click first, and the answer is taken that many samples later.
    static func tone(_ sound: StereoSound, bands: [ChainParameters.ToneBand]) -> StereoSound {
        let heard = bands.filter(changesTheSound)
        guard !heard.isEmpty else { return sound }
        let delay = delayInSamples(of: heard)
        guard let late = OfflineUnits.render(sound, through: [equalizer(heard)], extra: delay) else { return sound }
        return StereoSound(left: Array(late.left.dropFirst(delay)), right: Array(late.right.dropFirst(delay)))
    }

    /// How many samples late the peak of a click comes out of these bands.
    static func delayInSamples(of bands: [ChainParameters.ToneBand]) -> Int {
        var click = [Float](repeating: 0, count: 256)
        click[0] = 1
        guard let answer = OfflineUnits.render(StereoSound(left: click, right: click), through: [equalizer(bands)])
        else { return 0 }
        var peak = 0
        for index in answer.left.indices where abs(answer.left[index]) > abs(answer.left[peak]) {
            peak = index
        }
        return peak
    }

    /// Whether a band does anything: one that lifts or cuts by 0 dB does not.
    private static func changesTheSound(_ band: ChainParameters.ToneBand) -> Bool {
        switch band.kind {
        case .bell, .lowShelf, .highShelf: band.gainDb != 0
        case .highPass, .lowPass: true
        }
    }

    /// Apple's EQ unit with these bands, for one run.
    private static func equalizer(_ bands: [ChainParameters.ToneBand]) -> AVAudioUnitEQ {
        let unit = AVAudioUnitEQ(numberOfBands: bands.count)
        for (band, wanted) in zip(unit.bands, bands) {
            switch wanted.kind {
            case .bell:
                band.filterType = .parametric
                // The unit wants the width of a bell in octaves.
                band.bandwidth = Float(min(max(2 / log(2) * asinh(1 / (2 * max(wanted.q, 0.1))), 0.05), 5))
            case .lowShelf: band.filterType = .lowShelf
            case .highShelf: band.filterType = .highShelf
            case .highPass: band.filterType = .highPass
            case .lowPass: band.filterType = .lowPass
            }
            band.frequency = Float(min(max(wanted.hz, 20), Lockstep.sampleRate * 0.45))
            band.gain = Float(min(max(wanted.gainDb, -96), 24))
            band.bypass = false
        }
        return unit
    }

    // MARK: Warmth

    /// How hard the voice is pushed into the soft clip, in dB.
    static let warmthDriveDb: Float = 12
    /// How much the clipped voice is turned down before it is mixed in, in dB, so that warmth adds grit and
    /// not loudness: a tone at -14 dBFS comes out of the clip about this much louder.
    static let warmthTrimDb = -7.0

    /// The sound with grit mixed in: `amount` of it is the voice through a soft clip, the rest the voice as
    /// it was. 0 leaves the samples as they are.
    ///
    /// Apple's distortion unit is many effects in one. All but its soft clip are switched off, so it is a
    /// soft kind and never a harsh one, and it does not delay (measured).
    static func warmth(_ sound: StereoSound, amount: Double) -> StereoSound {
        let amount = Float(min(max(amount, 0), 1))
        guard amount > 0 else { return sound }
        let unit = AVAudioUnitDistortion()
        let settings: [(AudioUnitParameterID, Float)] = [
            (kDistortionParam_DelayMix, 0), (kDistortionParam_DecimationMix, 0),
            (kDistortionParam_PolynomialMix, 0), (kDistortionParam_RingModMix, 0),
            (kDistortionParam_SoftClipGain, warmthDriveDb), (kDistortionParam_FinalMix, 100),
        ]
        for (address, value) in settings {
            guard let parameter = unit.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(address))
            else { return sound }
            parameter.value = value
        }
        guard let clipped = OfflineUnits.render(sound, through: [unit]) else { return sound }
        let wet = amount * Float(pow(10, warmthTrimDb / 20))
        func mixed(_ dry: [Float], _ clipped: [Float]) -> [Float] {
            vDSP.add(multiplication: (dry, 1 - amount), multiplication: (clipped, wet))
        }
        return StereoSound(left: mixed(sound.left, clipped.left), right: mixed(sound.right, clipped.right))
    }

    // MARK: Space

    /// How long each room is given to ring, in samples. Where it has fallen below -60 dB before that, the
    /// tail is cut there.
    static func ringSamples(of room: ChainParameters.Reverb.Room) -> Int {
        let seconds = switch room {
        case .smallRoom: 0.6
        case .plate: 2.0
        case .largeHall: 3.0
        }
        return Int(seconds * Lockstep.sampleRate)
    }

    /// Which of the reverb unit's own rooms each room is. Its "Small Room" is gone after 0.3 s and its
    /// "Medium Room" after the 0.6 s the design gives a small room, so that one is the small room.
    static func preset(of room: ChainParameters.Reverb.Room) -> AVAudioUnitReverbPreset {
        switch room {
        case .smallRoom: .mediumRoom
        case .plate: .plate
        case .largeHall: .largeHall
        }
    }

    /// The voice with its reverb and its echo beside it, and the tail they ring.
    ///
    /// The voice itself goes through neither: the reverb unit gives only the room's answer, which is added
    /// to the voice as loud as `mix` says, and the echo's repeats are added after it. So the voice stays the
    /// samples it was.
    static func space(
        _ voice: StereoSound,
        reverb: ChainParameters.Reverb?,
        echo: ChainParameters.Echo?,
        beats: [Double]
    ) -> StereoSound {
        let count = voice.left.count
        var room: StereoSound?
        if let reverb, reverb.mix > 0 {
            let unit = AVAudioUnitReverb()
            room = OfflineUnits.render(voice, through: [unit], extra: ringSamples(of: reverb.room)) {
                unit.loadFactoryPreset(preset(of: reverb.room))
                unit.wetDryMix = 100
            }
        }
        let reach = echo.map { BeatEcho.reach(startingAt: 0, note: $0.note, levelDb: $0.levelDb, beats: beats) } ?? 0
        guard room != nil || reach > 0 else { return voice }

        let tail = min(max((room?.left.count ?? count) - count, reach), SoundTail.longest)
        let silence = [Float](repeating: 0, count: tail)
        var sound = StereoSound(left: voice.left + silence, right: voice.right + silence)
        if let room, let reverb {
            // The room's answer ends before the sound does where the echo rings longer than the room.
            let mix = Float(min(max(reverb.mix, 0), 1))
            let place = 0..<min(room.left.count, sound.left.count)
            sound.left.replaceSubrange(
                place, with: vDSP.add(multiplication: (room.left[place], mix), sound.left[place]))
            sound.right.replaceSubrange(
                place, with: vDSP.add(multiplication: (room.right[place], mix), sound.right[place]))
        }
        if let echo, reach > 0 {
            BeatEcho.add(
                repeatsOf: voice, startingAt: 0, note: echo.note, levelDb: echo.levelDb, beats: beats, to: &sound)
        }
        return SoundTail.cut(sound, after: count)
    }
}

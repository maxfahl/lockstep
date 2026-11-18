import Foundation
import LockstepCore
@testable import LockstepAudio

/// Made-up sound and made-up numbers for the tests of the voice chain. Everything is the same on every run.
enum ChainFixtures {
    static let rate = 48_000

    // MARK: Sound

    static func stereo(_ mono: [Float]) -> StereoSound {
        StereoSound(left: mono, right: mono)
    }

    /// A pure tone whose highest sample is at `db` dBFS.
    static func tone(hz: Double, db: Double, count: Int) -> [Float] {
        let size = pow(10, db / 20)
        return (0..<count).map { Float(size * sin(2 * Double.pi * hz * Double($0) / Double(rate))) }
    }

    /// Noise between -`size` and `size`.
    static func noise(count: Int, size: Double, seed: UInt64 = 11) -> [Float] {
        var random = StretchFixtures.Random(state: seed)
        return (0..<count).map { _ in Float(random.next(in: -size...size)) }
    }

    /// Noise that lies around 7 kHz, where an s lies.
    static func hiss(count: Int, size: Double) -> [Float] {
        // Twice through the band, so that little of it lies far from 7 kHz.
        let around = VoiceFilter.bandPass(hz: 7_000, q: 3)
        let band = around.filtered(around.filtered(noise(count: count, size: 1)))
        let highest = Double(band.map(abs).max() ?? 1)
        return band.map { Float(Double($0) * size / highest) }
    }

    /// How loud what a sound holds beside a pure tone is, in dB against the tone: its overtones. `tone` is
    /// the tone alone, as long as the sound.
    static func overtonesDb(of sound: some Collection<Float>, beside tone: some Collection<Float>) -> Double {
        var both = 0.0
        var toneAlone = 0.0
        for (one, other) in zip(sound, tone) {
            both += Double(one) * Double(other)
            toneAlone += Double(other) * Double(other)
        }
        // What is left when as much of the tone as the sound holds is taken away.
        let share = both / toneAlone
        var rest = 0.0
        for (one, other) in zip(sound, tone) {
            let left = Double(one) - share * Double(other)
            rest += left * left
        }
        return 10 * log10(max(rest, 1e-20) / (share * share * toneAlone))
    }

    /// Silence with one click, standing on a tone so quiet that the click is far above it.
    static func click(at sample: Int, count: Int) -> [Float] {
        var sound = tone(hz: 200, db: -40, count: count)
        sound[sample] = 0.5
        return sound
    }

    /// Something like a voice: syllables with pauses between them, a sharp s in each.
    static func voice(count: Int) -> [Float] {
        let syllable = StretchFixtures.syllable(period: 218, count: 9_600)
        let hissing = hiss(count: 2_400, size: 0.2)
        var sound = [Float](repeating: 0, count: count)
        var start = 2_400
        while start + 14_400 <= count {
            for index in syllable.indices { sound[start + index] = syllable[index] }
            for index in hissing.indices { sound[start + 9_600 + index] = hissing[index] }
            start += 16_800
        }
        return sound
    }

    /// Beats every `distance` samples, the first on `first`.
    static func beats(every distance: Int, first: Int = 0, count: Int = 40) -> [Double] {
        (0..<count).map { Double(first + $0 * distance) }
    }

    // MARK: Measuring

    static func loudnessDb(_ sound: some Collection<Float>) -> Double {
        let power = sound.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(sound.count, 1))
        return 10 * log10(max(power, 1e-20))
    }

    static func highest(_ sound: StereoSound) -> Float {
        max(sound.left.map(abs).max() ?? 0, sound.right.map(abs).max() ?? 0)
    }

    /// The sample with the largest size.
    static func peak(of samples: [Float]) -> Int {
        var best = 0
        for index in samples.indices where abs(samples[index]) > abs(samples[best]) {
            best = index
        }
        return best
    }

    /// The largest difference between two sounds, in dB against full scale. Where one is longer, the other
    /// counts as silent there.
    static func differenceDb(_ first: StereoSound, _ second: StereoSound) -> Double {
        func largest(_ one: [Float], _ other: [Float]) -> Float {
            var largest: Float = 0
            for index in 0..<max(one.count, other.count) {
                let difference = (index < one.count ? one[index] : 0) - (index < other.count ? other[index] : 0)
                largest = max(largest, abs(difference))
            }
            return largest
        }
        return 20 * log10(Double(max(largest(first.left, second.left), largest(first.right, second.right), 1e-10)))
    }

    // MARK: The six presets

    /// Where each built-in preset's knobs start.
    static let startingKnobs: [(character: SoundCharacter, knobs: SoundKnobs)] = [
        (.rapLead, SoundKnobs(squeeze: 0.70, tone: 0.55, warmth: 0.35, space: 0.08)),
        (.rapDouble, SoundKnobs(squeeze: 0.80, tone: 0.50, warmth: 0.25, space: 0.12)),
        (.adLib, SoundKnobs(squeeze: 0.80, tone: 1.00, warmth: 0.55, space: 0.25)),
        (.sungLead, SoundKnobs(squeeze: 0.50, tone: 0.55, warmth: 0.15, space: 0.35)),
        (.sungHook, SoundKnobs(squeeze: 0.60, tone: 0.65, warmth: 0.20, space: 0.45)),
        (.backingVoice, SoundKnobs(squeeze: 0.75, tone: 0.45, warmth: 0.10, space: 0.50)),
    ]

    static let allAtZero = SoundKnobs(squeeze: 0, tone: 0, warmth: 0, space: 0)
    static let allAtFull = SoundKnobs(squeeze: 1, tone: 1, warmth: 1, space: 1)

    /// The chain's numbers for a character and four knob positions, written here from the table of "The six
    /// presets" and its rules for the knobs.
    ///
    /// The app's own table is `SoundCharacter.parameters(_:)`, which another task of phase 33 writes and
    /// which was not there when these tests were written. These numbers stand in for it: the same parts,
    /// rooms, notes and knob rules, so the chain is tried with every kind of number it will be given.
    static func parameters(_ character: SoundCharacter, _ knobs: SoundKnobs) -> ChainParameters {
        typealias Band = ChainParameters.ToneBand
        func squeeze(_ fullRatio: Double, attackMs: Double, releaseMs: Double) -> ChainParameters.Squeeze {
            let ratio = 1 + (fullRatio - 1) * knobs.squeeze
            let thresholdDb = -18 - 12 * (knobs.squeeze - 0.5)
            return .init(
                thresholdDb: thresholdDb, ratio: ratio, attackMs: attackMs, releaseMs: releaseMs,
                makeupDb: -thresholdDb * (1 - 1 / ratio) / 2)
        }
        func bell(_ hz: Double, _ fullDb: Double) -> Band {
            Band(kind: .bell, hz: hz, gainDb: fullDb * knobs.tone, q: 1)
        }
        func shelf(_ hz: Double, _ fullDb: Double) -> Band {
            Band(kind: .highShelf, hz: hz, gainDb: fullDb * knobs.tone, q: 0.7)
        }
        func reverb(_ room: ChainParameters.Reverb.Room, most: Double) -> ChainParameters.Reverb? {
            knobs.space > 0 ? .init(room: room, mix: most * knobs.space) : nil
        }
        func echo(_ note: ChainParameters.Echo.Note) -> ChainParameters.Echo? {
            knobs.space > 0 ? .init(note: note, levelDb: -12 + 20 * log10(knobs.space)) : nil
        }
        let deEss = ChainParameters.DeEss(thresholdDb: -14, maxCutDb: 8)
        let ride = ChainParameters.Ride(maxGainDb: 6 * knobs.squeeze, speedMs: 300)

        switch character {
        case .rapLead:
            return ChainParameters(
                lowCutHz: 90, deEss: deEss, squeeze: squeeze(6, attackMs: 3, releaseMs: 60),
                tone: [bell(300, -3), bell(3_000, 4), shelf(10_000, 2)],
                warmth: 0.6 * knobs.warmth, reverb: reverb(.smallRoom, most: 0.5))
        case .rapDouble:
            return ChainParameters(
                lowCutHz: 140, deEss: deEss, squeeze: squeeze(8, attackMs: 3, releaseMs: 60),
                tone: [bell(300, -3), bell(3_000, 2), shelf(10_000, -2)],
                warmth: 0.6 * knobs.warmth, reverb: reverb(.smallRoom, most: 0.5))
        case .adLib:
            // Like a phone at full Tone: only 350 Hz to 3.4 kHz gets through.
            let phone = knobs.tone > 0
                ? [
                    Band(kind: .highPass, hz: 90 * pow(350.0 / 90, knobs.tone), gainDb: 0, q: 0.7),
                    Band(kind: .lowPass, hz: 16_000 * pow(3_400.0 / 16_000, knobs.tone), gainDb: 0, q: 0.7),
                ]
                : []
            return ChainParameters(
                lowCutHz: 90, deEss: deEss, squeeze: squeeze(8, attackMs: 3, releaseMs: 60), tone: phone,
                warmth: 0.8 * knobs.warmth, reverb: reverb(.smallRoom, most: 0.5), echo: echo(.eighth))
        case .sungLead:
            return ChainParameters(
                lowCutHz: 80, deEss: deEss, ride: ride, squeeze: squeeze(3, attackMs: 15, releaseMs: 150),
                tone: [bell(250, -2.5), bell(4_000, 2.5), shelf(12_000, 3)],
                warmth: 0.5 * knobs.warmth, reverb: reverb(.plate, most: 0.5), echo: echo(.quarter))
        case .sungHook:
            return ChainParameters(
                lowCutHz: 80, deEss: deEss, ride: ride, squeeze: squeeze(3, attackMs: 15, releaseMs: 150),
                tone: [bell(250, -2.5), bell(4_000, 2.5), shelf(12_000, 4.5)],
                warmth: 0.5 * knobs.warmth, reverb: reverb(.largeHall, most: 0.5), echo: echo(.eighth))
        case .backingVoice:
            return ChainParameters(
                lowCutHz: 160, deEss: deEss, squeeze: squeeze(5, attackMs: 10, releaseMs: 100),
                tone: [bell(300, -3), shelf(8_000, -3)],
                warmth: 0.5 * knobs.warmth, reverb: reverb(.largeHall, most: 0.5))
        }
    }
}

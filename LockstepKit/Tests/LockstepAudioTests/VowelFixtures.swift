import Foundation

/// A made-up vowel, and the measures of where its throat rings and how high it is, for the tests of the
/// shifter of the doubles (`VoiceShifterTests`) and of a track's Fast voice (`VoiceMakerTests`).
///
/// The vowel is a train of pulses, one per wave of the vocal cords, each ringing at the throat's notes and
/// dying away. Everything here is the same on every run.
enum VowelFixtures {
    /// A vowel of `count` samples whose voice is one wave every `period` samples (480 is 100 Hz), and whose
    /// throat rings at each of `peaks` Hz.
    static func vowel(count: Int, period: Int = 480, peaks: [Double]) -> [Float] {
        // What the throat answers to one beat of the vocal cords: each of its notes, dying away.
        let ring = (0..<4800).map { index -> Double in
            let time = Double(index) / 48_000
            return peaks.reduce(0) { $0 + exp(-Double.pi * 110 * time) * sin(2 * Double.pi * $1 * time) }
        }
        var sound = [Double](repeating: 0, count: count)
        for beat in stride(from: 0, to: count, by: period) {
            for index in 0..<min(ring.count, count - beat) { sound[beat + index] += ring[index] }
        }
        return sound.map { Float(0.15 * $0) }
    }

    /// How strong each overtone of a voice is, from the first up to 4 kHz, measured over whole waves in the
    /// middle of the sound. `period` is the length of one wave in samples and need not be whole.
    static func overtones(of sound: [Float], period: Double) -> [Double] {
        let waves = (Double(sound.count) * 0.6 / period).rounded(.down)
        let length = Int((waves * period).rounded())
        let start = (sound.count - length) / 2
        return (1...Int(4000 * period / 48_000)).map { overtone in
            var real = 0.0
            var imaginary = 0.0
            for index in 0..<length {
                let angle = 2 * Double.pi * Double(overtone) * Double(index) / period
                real += Double(sound[start + index]) * cos(angle)
                imaginary += Double(sound[start + index]) * sin(angle)
            }
            return (real * real + imaginary * imaginary).squareRoot() / Double(length)
        }
    }

    /// Where the throat rings near `expected` Hz: the top of a curve laid through the strongest overtone there
    /// and its two neighbours, so it is found between two overtones as well. It is looked for within `within`
    /// of `expected` either way (30 %), which has to be narrower when two resonances lie closer than that.
    static func peak(of sound: [Float], period: Double, near expected: Double, within: Double = 0.3) -> Double {
        let levels = overtones(of: sound, period: period).map { 20 * log10(max($0, 1e-12)) }
        let spacing = 48_000 / period
        let range = max(1, Int(expected * (1 - within) / spacing) - 1)...min(levels.count - 2, Int(expected * (1 + within) / spacing) - 1)
        guard let top = range.max(by: { levels[$0] < levels[$1] }) else { return 0 }
        let (below, here, above) = (levels[top - 1], levels[top], levels[top + 1])
        let bend = below - 2 * here + above
        let offset = bend < 0 ? 0.5 * (below - above) / bend : 0
        return (Double(top + 1) + offset) * spacing
    }

    /// The length of one wave of a voice in samples: how far the sound has to be moved to lie on itself again,
    /// looked for near `expected`.
    static func period(of sound: [Float], near expected: Int) -> Double {
        let middle = Array(sound[(2 * sound.count / 5)..<(3 * sound.count / 5)])
        func likeness(_ lag: Int) -> Double {
            StretchFixtures.correlation(middle[..<(middle.count - lag)], middle[lag...])
        }
        let lags = (expected * 3 / 4)...(expected * 5 / 4)
        guard let best = lags.max(by: { likeness($0) < likeness($1) }) else { return 0 }
        let (below, here, above) = (likeness(best - 1), likeness(best), likeness(best + 1))
        let bend = below - 2 * here + above
        return Double(best) + (bend < 0 ? 0.5 * (below - above) / bend : 0)
    }
}

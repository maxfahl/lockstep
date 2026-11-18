import Foundation

/// The five sounds the click can have. Lockstep makes each of them itself, from
/// sines and noise, so there is no sound file to license or to lose.
///
///     let plain = ClickSound.woodblock.samples(accent: false)
///     let firstBeatOfTheBar = ClickSound.woodblock.samples(accent: true)
///
/// What every sound keeps to, whatever its recipe:
/// - It is mono at 48,000 Hz and between 30 and 150 ms long.
/// - It is sound from its very first sample, rising from silence without a
///   jump, and its loudest point comes within the first 3 ms. So a click that
///   is placed on a beat is heard on the beat, not after it.
/// - It fades out to silence at its end.
/// - Its loudest sample is `peak`, the same for all five. The accent version
///   is `accentPeak`, 3 dB louder, and still below full scale.
/// - It is the same every time: the noise comes from a fixed seed.
///
/// The recipes are the values of the app's first technical design, tuned by
/// ear. "Falls to a tenth in 12 ms" is how a decay
/// is written here: the time in which the sound drops by 20 dB.
public enum ClickSound: String, Codable, CaseIterable, Sendable {
    case woodblock
    case rimshot
    case hiHat
    case cowbell
    case beep

    /// The loudest sample of a plain click: 4.5 dB below full scale.
    public static let peak: Float = 0.5957
    /// The loudest sample of an accent click: 3 dB louder than a plain one,
    /// which is 1.5 dB below full scale.
    public static let accentPeak: Float = 0.8414

    /// The sound as samples, mono at 48,000 Hz.
    /// - Parameter accent: the stronger version, for the first beat of a bar.
    public func samples(accent: Bool) -> [Float] {
        let shape: [Double]
        switch self {
        case .woodblock: shape = Self.woodblock(accent: accent)
        case .rimshot: shape = Self.rimshot(accent: accent)
        case .hiHat: shape = Self.hiHat(accent: accent)
        case .cowbell: shape = Self.cowbell(accent: accent)
        case .beep: shape = Self.beep(accent: accent)
        }
        return Self.levelled(shape, peak: accent ? Self.accentPeak : Self.peak)
    }

    // MARK: - The click to start on

    /// How long the click to start on lasts, in samples: 60 ms.
    public static let startLengthSamples = 2_880

    /// The click on the place recording starts: a sound of its own, the same whichever of the five sounds
    /// the click has, so it is always known as "now". It is higher than every one of them (a sine at 3200 Hz,
    /// where the woodblock's accent is at 2400 Hz) and rings longer than the woodblock, falling to a tenth
    /// in 20 ms.
    ///
    /// It keeps to what every click sound keeps to: sound from its first sample, loudest within its first
    /// 3 ms, fading out to silence, and the same every time. It is only played in a count-in. The click of
    /// a song (`samples(accent:)`), and so the click file, never contains it.
    ///
    /// - Parameter peak: its loudest sample. `ClickRenderer.renderCountIn` decides it from the click's volume.
    public static func startSamples(peak: Float) -> [Float] {
        let frequency = 3200.0
        let shape = (0..<startLengthSamples).map { index in
            let t = time(index)
            let body = sin(2 * .pi * frequency * t)
            let partial = 0.35 * sin(2 * .pi * frequency * 2.7 * t) * fall(t, toATenthIn: 8)
            return (body + partial) * fall(t, toATenthIn: 20)
        }
        return levelled(faded(shape, inMilliseconds: 0.5, outMilliseconds: 8), peak: max(peak, 0))
    }

    // MARK: - The recipes

    /// A sine at 1800 Hz with a quieter partial at 2.7 times that, which dies
    /// away faster. The accent is tuned higher, at 2400 Hz.
    private static func woodblock(accent: Bool) -> [Double] {
        let frequency = accent ? 2400.0 : 1800.0
        let shape = (0..<count(milliseconds: 40)).map { index in
            let t = time(index)
            let body = sin(2 * .pi * frequency * t)
            let partial = 0.35 * sin(2 * .pi * frequency * 2.7 * t) * fall(t, toATenthIn: 6)
            return (body + partial) * fall(t, toATenthIn: 12)
        }
        return faded(shape, inMilliseconds: 0.5, outMilliseconds: 5)
    }

    /// A 5 ms burst of noise between 2 and 6 kHz on top of a 480 Hz sine that
    /// dies away over about 25 ms. The accent has more noise, and brighter
    /// (3 to 9 kHz).
    private static func rimshot(accent: Bool) -> [Double] {
        let length = count(milliseconds: 60)
        var noise = SeededNoise(seed: 0x5EED_0001)
        let band = accent
            ? Biquad.bandPass(centre: 5196, q: 0.87)
            : Biquad.bandPass(centre: 3464, q: 0.87)
        let hiss = band.filtered((0..<length).map { _ in noise.next() })
        let hissLevel = accent ? 3.0 : 2.0
        let burstSeconds = 0.005
        let shape = (0..<length).map { index in
            let t = time(index)
            let left = max(0, 1 - t / burstSeconds)
            let burst = hissLevel * hiss[index] * left * left
            let body = sin(2 * .pi * 480 * t) * fall(t, toATenthIn: 25)
            return burst + body
        }
        return faded(shape, inMilliseconds: 0.25, outMilliseconds: 5)
    }

    /// Noise above 7 kHz: a short tick followed by a hiss that falls to a
    /// tenth in 18 ms. The accent's hiss lasts longer (30 ms).
    ///
    /// The tick at the start is what puts the loudest point on the beat. Noise
    /// that only dies away slowly can have its loudest sample anywhere in its
    /// first hundredth of a second.
    private static func hiHat(accent: Bool) -> [Double] {
        let length = count(milliseconds: accent ? 80 : 50)
        var noise = SeededNoise(seed: 0x5EED_0002)
        let highPass = Biquad.highPass(cutoff: 7000, q: 0.707)
        let hiss = highPass.filtered(highPass.filtered((0..<length).map { _ in noise.next() }))
        let shape = (0..<length).map { index in
            let t = time(index)
            let tick = fall(t, toATenthIn: 2)
            let tail = fall(t, toATenthIn: accent ? 30 : 18)
            return hiss[index] * (0.5 * tick + 0.5 * tail)
        }
        return faded(shape, inMilliseconds: 0.25, outMilliseconds: 5)
    }

    /// Two square tones at 540 and 800 Hz through a band-pass filter: a strike
    /// and a ring that falls to a tenth in 60 ms. The accent has both tones
    /// raised by a major third.
    ///
    /// The two tones beat against each other every 4 ms, so without the strike
    /// the loudest point could come one beat of theirs late.
    private static func cowbell(accent: Bool) -> [Double] {
        let raise = accent ? 1.25 : 1.0
        let band = Biquad.bandPass(centre: 1800 * raise, q: 1)
        let tones = band.filtered((0..<count(milliseconds: 150)).map { index in
            let t = time(index)
            return square(540 * raise, at: t) + square(800 * raise, at: t)
        })
        let shape = tones.indices.map { index in
            let t = time(index)
            return tones[index] * (0.75 * fall(t, toATenthIn: 4) + 0.25 * fall(t, toATenthIn: 60))
        }
        return faded(shape, inMilliseconds: 0.25, outMilliseconds: 20)
    }

    /// A plain 1000 Hz tone, 30 ms long, fading in and out over 2 ms. The
    /// accent is 1500 Hz.
    private static func beep(accent: Bool) -> [Double] {
        let frequency = accent ? 1500.0 : 1000.0
        let shape = (0..<count(milliseconds: 30)).map { sin(2 * .pi * frequency * time($0)) }
        return faded(shape, inMilliseconds: 2, outMilliseconds: 2)
    }

    // MARK: - What the recipes are made of

    /// The time of a sample in seconds. The first sample is one step in: the
    /// silence a sound rises from is the sample before it, so the sound's own
    /// first sample is already sound and lands exactly on the beat.
    private static func time(_ index: Int) -> Double {
        Double(index + 1) / Lockstep.sampleRate
    }

    private static func count(milliseconds: Double) -> Int {
        Int((milliseconds / 1000 * Lockstep.sampleRate).rounded())
    }

    /// A level that starts at 1 and drops to a tenth (20 dB) in the given time.
    private static func fall(_ seconds: Double, toATenthIn milliseconds: Double) -> Double {
        pow(10, -seconds * 1000 / milliseconds)
    }

    /// A square wave built from its odd harmonics up to 12 kHz. A square wave
    /// made by switching between two values would add tones of its own at
    /// this sample rate.
    private static func square(_ frequency: Double, at seconds: Double) -> Double {
        var value = 0.0
        var harmonic = 1.0
        while harmonic * frequency < 12_000 {
            value += sin(2 * .pi * harmonic * frequency * seconds) / harmonic
            harmonic += 2
        }
        return value
    }

    /// Lets the sound rise smoothly from silence over its first part and fall
    /// smoothly to silence over its last part.
    private static func faded(
        _ samples: [Double],
        inMilliseconds: Double,
        outMilliseconds: Double
    ) -> [Double] {
        var result = samples
        let rise = min(count(milliseconds: inMilliseconds), samples.count)
        for step in 0..<rise {
            result[step] *= 0.5 * (1 - cos(.pi * Double(step + 1) / Double(rise + 1)))
        }
        let drop = min(count(milliseconds: outMilliseconds), samples.count)
        for step in 0..<drop {
            result[samples.count - 1 - step] *= 0.5 * (1 - cos(.pi * Double(step + 1) / Double(drop + 1)))
        }
        return result
    }

    /// Scales a sound so that its loudest sample is `peak`.
    private static func levelled(_ samples: [Double], peak: Float) -> [Float] {
        let loudest = samples.reduce(0) { max($0, abs($1)) }
        guard loudest > 0 else { return samples.map { _ in 0 } }
        let gain = Double(peak) / loudest
        return samples.map { Float($0 * gain) }
    }
}

/// Noise that is the same every time it is made: values from -1 up to 1 from a
/// fixed starting number (the SplitMix64 generator).
private struct SeededNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        mixed ^= mixed >> 31
        return Double(mixed >> 11) / Double(1 << 52) - 1
    }
}

/// A small filter that keeps one band of a sound, or everything above one
/// frequency (the standard two-pole "biquad" filter).
private struct Biquad {
    private let b0, b1, b2, a1, a2: Double

    /// Keeps what lies around `centre`. A higher `q` keeps a narrower band.
    static func bandPass(centre: Double, q: Double) -> Biquad {
        let angle = 2 * Double.pi * centre / Lockstep.sampleRate
        let alpha = sin(angle) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(angle) / a0, a2: (1 - alpha) / a0)
    }

    /// Keeps what lies above `cutoff`.
    static func highPass(cutoff: Double, q: Double) -> Biquad {
        let angle = 2 * Double.pi * cutoff / Lockstep.sampleRate
        let alpha = sin(angle) / (2 * q)
        let a0 = 1 + alpha
        let rise = (1 + cos(angle)) / 2
        return Biquad(b0: rise / a0, b1: -2 * rise / a0, b2: rise / a0, a1: -2 * cos(angle) / a0, a2: (1 - alpha) / a0)
    }

    func filtered(_ input: [Double]) -> [Double] {
        var output = [Double](repeating: 0, count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for index in input.indices {
            let x = input[index]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            output[index] = y
        }
        return output
    }
}

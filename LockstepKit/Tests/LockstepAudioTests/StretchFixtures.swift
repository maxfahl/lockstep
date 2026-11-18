import Foundation

/// Made-up sound for the tests of the stretcher, and the ways of measuring where something landed.
///
/// Everything here is the same on every run. The stretch tolerance was measured with exactly these runs and these
/// two ways of measuring (`onset` and `peak`), so a later test that checks a place against the tolerance should
/// measure with them too.
enum StretchFixtures {
    static let rate = 48_000

    /// The same numbers on every run.
    struct Random {
        var state: UInt64

        /// The next number, from 0 up to 1.
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }

        mutating func next(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + next() * (range.upperBound - range.lowerBound)
        }
    }

    /// A sound with the overtones of a voice: one wave is `period` samples long, and every overtone below 4 kHz is
    /// in it, weaker the higher it is. `level` gives the loudness at each sample, 1 being a peak of about 0.4.
    static func voice(period: Int, count: Int, level: (Int) -> Double = { _ in 1 }) -> [Float] {
        let wave = (0..<period).map { index -> Double in
            var value = 0.0
            var overtone = 1
            while overtone * rate / period < 4000 {
                value += sin(2 * Double.pi * Double(overtone * index) / Double(period)) / Double(overtone)
                overtone += 1
            }
            return 0.25 * value
        }
        return (0..<count).map { Float(wave[$0 % period] * level($0)) }
    }

    /// A syllable that runs straight on from the one before it: it jumps to full loudness within 2 ms and sinks
    /// to a third by its end, so the next syllable starts with a step of 10 dB.
    static func syllable(period: Int, count: Int) -> [Float] {
        voice(period: period, count: count) { index in
            let attack = min(1, Double(index) / 96)
            return (0.3 + 0.7 * attack) * (1 - 0.7 * Double(index) / Double(count))
        }
    }

    /// One made-up run of syllables with no pause between them, and the map that moves them.
    struct Run {
        /// The syllables as voiced sound. A new syllable starts at every key frame.
        var voiced: [Float]
        /// The same run as faint noise with one click at every key frame.
        var clicks: [Float]
        var keyFrames: [(source: Int, target: Int)]
        var outputLength: Int
        /// The length of one wave of the syllable that starts at each key frame.
        var periods: [Int]
    }

    /// A run as the plan allows them: 2 to 7 syllables of 90 to 500 ms at pitches from 90 to 220 Hz, each made
    /// longer or shorter by at most a quarter (one in five keeps its length), and no place moved more than 40 ms.
    static func run(_ random: inout Random) -> Run {
        let syllables = 2 + Int(random.next() * 6)
        var run = Run(voiced: [], clicks: [], keyFrames: [], outputLength: 0, periods: [])
        var source = 0
        var target = 0
        for index in 0..<syllables {
            let length = Int(random.next(in: 0.09...0.5) * Double(rate))
            var ratio = random.next() < 0.2 ? 1.0 : random.next(in: 0.8...1.25)
            var end = target + Int((Double(length) * ratio).rounded())
            let move = end - (source + length)
            let furthest = rate * 40 / 1000
            if abs(move) > furthest {
                end = source + length + (move > 0 ? furthest : -furthest)
                ratio = Double(end - target) / Double(length)
                if ratio < 0.8 || ratio > 1.25 {
                    end = target + Int(Double(length) * min(max(ratio, 0.8), 1.25))
                }
            }
            let period = Int(random.next(in: 218...533))
            if index > 0 { run.periods.append(period) }
            run.voiced += syllable(period: period, count: length)
            source += length
            target = end
            if index < syllables - 1 { run.keyFrames.append((source, target)) }
        }
        var noise = Random(state: 99)
        run.clicks = (0..<source).map { _ in Float((noise.next() * 2 - 1) * 0.001) }
        for frame in run.keyFrames { run.clicks[frame.source] = 0.8 }
        run.outputLength = target
        return run
    }

    /// Where a sound gets louder near `expected`, in samples: the middle of the steepest rise of its energy.
    ///
    /// The energy is taken over exactly one wave of the sound (`period`) before and after each place, so the pitch
    /// itself does not look like a rise. Before the start and after the end the sound counts as silence. The same
    /// measure is taken on the sound that went in and on the result, and the two are compared.
    static func onset(in sound: [Float], near expected: Int, period: Int, search: Int = 1440) -> Double {
        var sums = [Double](repeating: 0, count: sound.count + 1)
        for index in sound.indices { sums[index + 1] = sums[index] + Double(sound[index]) * Double(sound[index]) }
        func energy(_ from: Int, _ to: Int) -> Double {
            sums[min(sound.count, max(0, to))] - sums[min(sound.count, max(0, from))]
        }
        let first = max(0, expected - search)
        let last = min(sound.count, expected + search)
        guard first < last else { return Double(expected) }
        let rises = (first..<last).map { energy($0, $0 + period) - energy($0 - period, $0) }
        guard let top = rises.max(), top > 0, let peak = rises.firstIndex(of: top) else { return Double(expected) }
        var from = peak
        var to = peak
        while from > 0, rises[from - 1] > 0.7 * top { from -= 1 }
        while to < rises.count - 1, rises[to + 1] > 0.7 * top { to += 1 }
        var sum = 0.0
        var weight = 0.0
        for index in from...to {
            sum += rises[index] * Double(index)
            weight += rises[index]
        }
        return Double(first) + sum / weight
    }

    /// The sample with the largest swing near `expected`: where a click is.
    static func peak(in sound: [Float], near expected: Int, search: Int = 1440) -> Int {
        let range = max(0, expected - search)..<min(sound.count, expected + search)
        return range.max { abs(sound[$0]) < abs(sound[$1]) } ?? expected
    }

    /// How alike two sounds are, sample by sample: 1 is the same, 0 is unrelated, -1 is upside down.
    static func correlation(_ first: some Collection<Float>, _ second: some Collection<Float>) -> Double {
        var both = 0.0
        var one = 0.0
        var other = 0.0
        for (a, b) in zip(first, second) {
            both += Double(a) * Double(b)
            one += Double(a) * Double(a)
            other += Double(b) * Double(b)
        }
        return both / (one * other).squareRoot()
    }

    /// The loudness of a sound: the root of its mean square.
    static func loudness(_ sound: some Collection<Float>) -> Double {
        (sound.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(sound.count)).squareRoot()
    }

    /// The pitch of a plain tone in Hz, from the places where it crosses zero going up.
    static func frequency(of tone: some RandomAccessCollection<Float>) -> Double {
        let samples = Array(tone)
        var crossings: [Double] = []
        for index in 1..<samples.count where samples[index - 1] < 0 && samples[index] >= 0 {
            let part = Double(-samples[index - 1]) / Double(samples[index] - samples[index - 1])
            crossings.append(Double(index - 1) + part)
        }
        guard let first = crossings.first, let last = crossings.last, last > first else { return 0 }
        return Double(crossings.count - 1) * Double(rate) / (last - first)
    }
}

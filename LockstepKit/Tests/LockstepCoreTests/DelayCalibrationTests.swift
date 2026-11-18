import Foundation
import Testing
@testable import LockstepCore

/// The recordings in these tests are made up: the ticks themselves, moved later by a known time, with noise and
/// muffling added where a test says so. No sound is played and nothing is recorded.
@Suite("Delay calibration")
struct DelayCalibrationTests {
    // MARK: Making recordings up

    /// Noise that is the same every time: values from -1 up to 1 (the SplitMix64 generator).
    struct Noise {
        var state: UInt64

        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            mixed ^= mixed >> 31
            return Double(mixed >> 11) / Double(1 << 52) - 1
        }

        /// Noise of a given loudness (its root mean square), `count` samples long.
        static func samples(count: Int, rms: Double, seed: UInt64) -> [Float] {
            var noise = Noise(state: seed)
            // Values spread evenly from -1 to 1 have a root mean square of 1 / √3.
            let gain = rms * 3.0.squareRoot()
            return (0..<count).map { _ in Float(noise.next() * gain) }
        }
    }

    /// What a microphone hears of the ticks when they come back `delay` seconds late: the ticks moved later by
    /// exactly that long, also when it is not a whole number of samples, followed by `tail` seconds of silence.
    static func heard(_ ticks: DelayCalibration.TickSignal, delay: Double, tail: Double = 0.7) -> [Float] {
        let rate = Lockstep.sampleRate
        let shift = delay * rate
        let whole = Int(shift.rounded(.down))
        let rest = shift - Double(whole)
        var heard = [Float](repeating: 0, count: ticks.samples.count + whole + Int(tail * rate))
        // Moving a sound by part of a sample: every sample is spread over its neighbours (a windowed sinc).
        let reach = 32
        let spread: [Double] = (-reach...reach).map { step in
            let distance = Double(step) - rest
            let sinc = distance == 0 ? 1 : sin(Double.pi * distance) / (Double.pi * distance)
            let window = 0.5 + 0.5 * cos(Double.pi * distance / Double(reach + 1))
            return sinc * window
        }
        for tick in ticks.tickSamples {
            for index in tick..<tick + ticks.tickLength {
                let sample = Double(ticks.samples[index])
                for step in -reach...reach {
                    let place = index + whole + step
                    guard heard.indices.contains(place) else { continue }
                    heard[place] += Float(sample * spread[step + reach])
                }
            }
        }
        return heard
    }

    /// Muffles a sound the way a headphone held against a microphone does: the highs are taken down, more the
    /// higher they are (a one-pole low-pass at `cutoff` Hz).
    static func muffled(_ samples: [Float], cutoff: Double = 3_000) -> [Float] {
        let keep = exp(-2 * Double.pi * cutoff / Lockstep.sampleRate)
        var last = 0.0
        return samples.map { sample in
            last = (1 - keep) * Double(sample) + keep * last
            return Float(last)
        }
    }

    static func adding(_ noise: [Float], to samples: [Float]) -> [Float] {
        zip(samples, noise).map { $0 + $1 }
    }

    /// The delay a recording gives, or nil when the ticks were not found.
    static func delay(of result: DelayCalibration.Result) -> Double? {
        if case .measured(let delay, _) = result { return delay }
        return nil
    }

    // MARK: The ticks

    @Test("The ticks are eight bursts of 2 ms after 0.3 s of silence, at gaps that are all different")
    func ticksAreEightUnevenBursts() {
        let ticks = DelayCalibration.tickSignal()
        #expect(ticks.tickSamples.count == 8)
        #expect(ticks.tickLength == 96)
        #expect(ticks.tickSamples[0] == 14_400)

        // In samples: 350 ms is 16,800 samples, 450 ms is 21,600, and 15 ms is 720.
        let gaps = zip(ticks.tickSamples.dropFirst(), ticks.tickSamples).map { $0 - $1 }
        #expect(gaps.count == 7)
        #expect(gaps.allSatisfy { $0 >= 16_800 && $0 <= 21_600 })
        for (index, gap) in gaps.enumerated() {
            for other in gaps[(index + 1)...] {
                #expect(abs(gap - other) >= 720)
            }
        }

        // Sound only where the ticks are, and silence everywhere else.
        var expectedSilence = [Bool](repeating: true, count: ticks.samples.count)
        for tick in ticks.tickSamples {
            for index in tick..<tick + ticks.tickLength { expectedSilence[index] = false }
            let sound = ticks.samples[tick..<tick + ticks.tickLength]
            #expect(sound.map { abs($0) }.max() == DelayCalibration.tickPeak)
            // A tick adds up to nothing, so a hum in the room cannot pass for one.
            #expect(abs(sound.reduce(0, +)) < 0.001)
        }
        #expect(ticks.samples.indices.allSatisfy { !expectedSilence[$0] || ticks.samples[$0] == 0 })
        #expect(ticks.samples.count == ticks.tickSamples[7] + 96)
        #expect(abs(ticks.listeningSeconds - (ticks.duration + 0.6)) < 1e-12)

        // The same every time.
        #expect(DelayCalibration.tickSignal() == ticks)
    }

    // MARK: The delay

    @Test("Ticks that come back exactly 23.4 ms late are measured within 0.1 ms")
    func cleanDelayIsMeasured() throws {
        let ticks = DelayCalibration.tickSignal()
        let result = DelayCalibration.estimate(played: ticks, recorded: Self.heard(ticks, delay: 0.0234))
        let delay = try #require(Self.delay(of: result))
        #expect(abs(delay - 0.0234) < 0.0001)
        // 23.4 ms is 1123.2 samples. The answer is right to well under one sample (21 millionths of a second).
        #expect(abs(delay - 0.0234) < 0.000_005)
        guard case .measured(_, let quality) = result else { return }
        #expect(quality > 0.95)
    }

    @Test("Ticks 217 ms late, muffled and with noise at -20 dB, are measured within 0.5 ms")
    func noisyMuffledDelayIsMeasured() throws {
        let ticks = DelayCalibration.tickSignal()
        let clean = Self.muffled(Self.heard(ticks, delay: 0.217))
        // Noise as loud as a tenth of full scale, which is louder than the muffled ticks are on average.
        let noise = Noise.samples(count: clean.count, rms: 0.1, seed: 0xCA11_B8A7)
        let result = DelayCalibration.estimate(played: ticks, recorded: Self.adding(noise, to: clean))
        let delay = try #require(Self.delay(of: result))
        #expect(abs(delay - 0.217) < 0.0005)
    }

    @Test("Noise alone, silence, and a single knock give no delay")
    func noiseAloneFails() {
        let ticks = DelayCalibration.tickSignal()
        let count = ticks.samples.count + 33_600
        for seed in 1...12 as ClosedRange<UInt64> {
            var noise = Noise.samples(count: count, rms: 0.1, seed: seed)
            // Half of them dull, like the noise of a room.
            if seed.isMultiple(of: 2) { noise = Self.muffled(noise, cutoff: 6_000) }
            #expect(DelayCalibration.estimate(played: ticks, recorded: noise) == .failed)
        }
        #expect(DelayCalibration.estimate(played: ticks, recorded: [Float](repeating: 0, count: count)) == .failed)
        #expect(DelayCalibration.estimate(played: ticks, recorded: []) == .failed)

        // One tick alone in the recording, as loud as can be: it fits one tick perfectly and seven not at all.
        var knock = [Float](repeating: 0, count: count)
        let tick = ticks.samples[ticks.tickSamples[0]..<ticks.tickSamples[0] + ticks.tickLength]
        knock.replaceSubrange(60_000..<60_000 + tick.count, with: tick)
        #expect(DelayCalibration.estimate(played: ticks, recorded: knock) == .failed)
    }

    @Test("Ticks that are heard twice, nearly as loud the second time, give no delay")
    func twoPlacesThatFitGiveNoDelay() throws {
        let ticks = DelayCalibration.tickSignal()
        let first = Self.heard(ticks, delay: 0.05, tail: 1)
        let second = Self.heard(ticks, delay: 0.3, tail: 1)
        func both(secondAt loudness: Float) -> [Float] {
            (0..<min(first.count, second.count)).map { first[$0] + loudness * second[$0] }
        }
        // Two places fit nearly as well as each other, and nothing says which of them is the delay.
        #expect(DelayCalibration.estimate(played: ticks, recorded: both(secondAt: 0.8)) == .failed)
        // A faint second copy, like an echo, does not get in the way.
        let delay = try #require(Self.delay(of: DelayCalibration.estimate(played: ticks, recorded: both(secondAt: 0.3))))
        #expect(abs(delay - 0.05) < 0.0001)
    }

    @Test("A delay of exactly one gap between ticks is measured as that, not as one tick over")
    func delayOfOneTickGapIsNotMistaken() throws {
        let ticks = DelayCalibration.tickSignal()
        for gap in DelayCalibration.gapsMilliseconds {
            let expected = Double(gap) / 1000
            let result = DelayCalibration.estimate(played: ticks, recorded: Self.heard(ticks, delay: expected))
            let delay = try #require(Self.delay(of: result))
            #expect(abs(delay - expected) < 0.0001)
        }
    }

    @Test("A recording at half volume, or upside down, gives the same delay")
    func volumeDoesNotChangeTheAnswer() throws {
        let ticks = DelayCalibration.tickSignal()
        let clean = Self.muffled(Self.heard(ticks, delay: 0.0871))
        let noise = Noise.samples(count: clean.count, rms: 0.02, seed: 7)
        let full = Self.adding(noise, to: clean)
        let whole = DelayCalibration.estimate(played: ticks, recorded: full)
        let half = DelayCalibration.estimate(played: ticks, recorded: full.map { $0 * 0.5 })
        let upsideDown = DelayCalibration.estimate(played: ticks, recorded: full.map { -$0 })

        guard case .measured(let delay, let quality) = whole,
              case .measured(let halfDelay, let halfQuality) = half
        else {
            Issue.record("The ticks were not found: \(whole), \(half)")
            return
        }
        #expect(abs(delay - 0.0871) < 0.0005)
        #expect(abs(halfDelay - delay) < 1e-7)
        #expect(abs(halfQuality - quality) < 1e-4)
        let turnedDelay = try #require(Self.delay(of: upsideDown))
        #expect(abs(turnedDelay - delay) < 1e-7)
    }

    @Test("A microphone that was listening before the ticks started is allowed for")
    func earlierStartOfTheRecordingIsAllowedFor() throws {
        let ticks = DelayCalibration.tickSignal()
        // The microphone was opened 0.1503 s before the ticks were due, as it is in a take: 7214.4 samples.
        // The ticks come back 0.0312 s late, so they are in the recording 0.1815 s after their place.
        let recorded = Self.heard(ticks, delay: 0.1503 + 0.0312)
        let result = DelayCalibration.estimate(played: ticks, recorded: recorded, recordedStart: -0.1503)
        let delay = try #require(Self.delay(of: result))
        #expect(abs(delay - 0.0312) < 0.000_005)

        // A microphone that only started 0.02 s after the ticks were due still heard them all.
        let late = Array(Self.heard(ticks, delay: 0.2).dropFirst(960))
        let lateDelay = try #require(Self.delay(of: DelayCalibration.estimate(played: ticks, recorded: late, recordedStart: 0.02)))
        #expect(abs(lateDelay - 0.2) < 0.000_005)
    }

    @Test("The longest and the shortest delay that are looked for are found, and a longer one is not")
    func endsOfTheSearch() throws {
        let ticks = DelayCalibration.tickSignal()
        let none = try #require(Self.delay(of: DelayCalibration.estimate(played: ticks, recorded: ticks.samples)))
        #expect(none < 0.000_005)
        let longest = try #require(Self.delay(of: DelayCalibration.estimate(played: ticks, recorded: Self.heard(ticks, delay: 0.6))))
        #expect(abs(longest - 0.6) < 0.000_005)
        #expect(DelayCalibration.estimate(played: ticks, recorded: Self.heard(ticks, delay: 0.75, tail: 1)) == .failed)
    }
}

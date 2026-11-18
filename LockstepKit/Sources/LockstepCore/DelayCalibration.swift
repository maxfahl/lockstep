import Foundation

/// Working out how late a sound comes back: the time from Lockstep handing a sound to the Mac until that sound
/// arrives in the recording. That is the delay of the headphones plus the delay of the microphone, which is
/// exactly how late a performance lands in a take.
///
/// Lockstep plays a row of short ticks, records them with a headphone held against the microphone, and compares
/// the two. This is the comparing, as plain arithmetic: it knows nothing of sound devices, so it can be tested
/// with recordings that were made up.
///
///     let ticks = DelayCalibration.tickSignal()
///     // ... play `ticks.samples`, and record what the microphone hears while they play ...
///     switch DelayCalibration.estimate(played: ticks, recorded: heard) {
///     case .measured(let delay, _): print("\(Int((delay * 1000).rounded())) ms")
///     case .failed: print("Could not hear the ticks.")
///     }
///
/// The method is the one the app's first technical design set out.
public enum DelayCalibration {
    // MARK: The ticks

    /// The silence before the first tick, in seconds: time for the sound output to wake up.
    public static let silenceBeforeSeconds: Double = 0.3
    /// The length of one tick, in seconds.
    public static let tickSeconds: Double = 0.002
    /// The time from the start of each tick to the start of the next, in milliseconds. Every gap is different
    /// from every other by at least 15 ms. So when the recording is laid over the ticks one tick too early or too
    /// late, at most one tick of the eight lands on a tick, and that can never look like the right place.
    public static let gapsMilliseconds: [Int] = [395, 350, 440, 365, 425, 380, 410]
    /// The loudest sample of a tick, where 1 is the loudest a sample can be.
    public static let tickPeak: Float = 0.8
    /// The lowest and the highest pitch of a tick, in Hz. A tick sweeps from one to the other. Every headphone
    /// and every microphone passes this band, also AirPods when they are the microphone as well.
    static let tickSweep: ClosedRange<Double> = 1_000...10_000

    /// The ticks Lockstep plays to measure the delay.
    public struct TickSignal: Sendable, Equatable {
        /// The sound: mono at 48,000 Hz, silent except for the ticks.
        public var samples: [Float]
        /// The first sample of each tick, in the order they are played.
        public var tickSamples: [Int]
        /// How many samples each tick lasts.
        public var tickLength: Int

        public init(samples: [Float], tickSamples: [Int], tickLength: Int) {
            self.samples = samples
            self.tickSamples = tickSamples
            self.tickLength = tickLength
        }

        /// The length of the sound in seconds.
        public var duration: Double {
            Double(samples.count) / Lockstep.sampleRate
        }

        /// How long the microphone must go on listening, counted from the start of the sound, to hear the last
        /// tick even when it comes back as late as `longestDelay`. In seconds.
        public var listeningSeconds: Double {
            duration + DelayCalibration.longestDelay
        }
    }

    /// Eight ticks of 2 ms after 0.3 s of silence, at the uneven gaps of `gapsMilliseconds`: 3.07 s in all.
    /// The same every time, so one measurement can be compared with another.
    public static func tickSignal() -> TickSignal {
        let rate = Lockstep.sampleRate
        let tick = tick()
        var starts = [Int((silenceBeforeSeconds * rate).rounded())]
        for gap in gapsMilliseconds {
            starts.append(starts[starts.count - 1] + Int((Double(gap) / 1000 * rate).rounded()))
        }
        var samples = [Float](repeating: 0, count: starts[starts.count - 1] + tick.count)
        for start in starts {
            samples.replaceSubrange(start..<start + tick.count, with: tick)
        }
        return TickSignal(samples: samples, tickSamples: starts, tickLength: tick.count)
    }

    /// One tick: a sweep from 1 to 10 kHz in 2 ms, faded in and out over a quarter of a millisecond.
    ///
    /// A sweep over a wide band is heard as a tick, and laid over a copy of itself it fits in one place only,
    /// to a fraction of a millisecond. A plain beep would fit again one wave further on.
    private static func tick() -> [Float] {
        let rate = Lockstep.sampleRate
        let count = Int((tickSeconds * rate).rounded())
        let fade = count / 8
        var window = [Double](repeating: 1, count: count)
        for index in 0..<fade {
            let rise = 0.5 - 0.5 * cos(Double.pi * (Double(index) + 0.5) / Double(fade))
            window[index] = rise
            window[count - 1 - index] = rise
        }
        var shape = (0..<count).map { index -> Double in
            let time = Double(index) / rate
            let climb = (tickSweep.upperBound - tickSweep.lowerBound) / tickSeconds
            let turns = tickSweep.lowerBound * time + climb * time * time / 2
            return window[index] * sin(2 * Double.pi * turns)
        }
        // The samples are made to add up to nothing. A hum or a rumble in the room hardly changes within 2 ms,
        // and against a tick that adds up to nothing it counts for nothing.
        let lean = shape.reduce(0, +) / window.reduce(0, +)
        for index in shape.indices {
            shape[index] -= lean * window[index]
        }
        let loudest = shape.reduce(0) { max($0, abs($1)) }
        return shape.map { Float($0 / loudest * Double(tickPeak)) }
    }

    // MARK: The delay

    /// The longest delay that is looked for, in seconds. AirPods are expected at 0.15 to 0.3.
    public static let longestDelay: Double = 0.6
    /// How many times the best fit must stand above the usual fit (the middle value of all of them) to be
    /// believed.
    public static let peakStandout: Double = 6
    /// How many times the best fit must stand above the best fit anywhere else (more than 1 ms away from it)
    /// to be believed. With the ticks really there it is about 8 times in a clean recording and still above 2
    /// in one drowned in noise. In noise alone the two best fits are nearly the same.
    public static let otherPlaceStandout: Double = 1.5
    /// How far around the delay each single tick is looked for, in seconds.
    public static let tickSearchSeconds: Double = 0.005
    /// How close to the delay a single tick must be found to agree with it, in seconds.
    public static let tickAgreementSeconds: Double = 0.001
    /// How many of the eight ticks must agree with the delay for it to be believed.
    public static let ticksThatMustAgree = 6

    /// What a recording of the ticks said.
    public enum Result: Sendable, Equatable {
        /// The ticks were found.
        ///
        /// - `delay`: how late they arrived in the recording, in seconds.
        /// - `quality`: how much of what the microphone heard at the ticks was the ticks themselves, from 0
        ///   (nothing) to 1 (a perfect copy). It is the same for a quiet and for a loud recording. Noise and a
        ///   muffled sound lower it.
        case measured(delay: Double, quality: Double)
        /// The ticks could not be told from the rest of the recording. No delay can be given.
        case failed
    }

    /// How late the ticks arrived in a recording of them.
    ///
    /// The ticks are laid over the recording at every delay from 0 to `longestDelay`, one sample at a time, and
    /// each time it is measured how well they fit (a cross-correlation). The best fit is the delay, and the fits
    /// one sample to either side of it say where between two samples the best fit really lies.
    ///
    /// The answer is only given when it can be trusted:
    /// - the best fit must stand out: at least `peakStandout` times the usual fit,
    /// - no other delay may fit nearly as well: the best fit is at least `otherPlaceStandout` times the best
    ///   fit more than 1 ms away from it, and
    /// - each tick is also looked for on its own, within 5 ms of the delay. At least 6 of the 8 must be found
    ///   within 1 ms of it. One loud knock on the table fits one tick well and fails here.
    ///
    /// A recording in which the sound is upside down, as some microphones deliver it, is measured the same.
    ///
    /// - Parameters:
    ///   - played: the ticks that were played, from `tickSignal()`.
    ///   - recorded: what the microphone heard, mono at 48,000 Hz.
    ///   - recordedStart: when the first sample of `recorded` was heard, in seconds after the first sample of
    ///     `played` was due to sound. Negative when the microphone was listening before the ticks started, as
    ///     it is in a take (this is the take's `Recording.rawStart`, with the ticks played from position 0).
    public static func estimate(played: TickSignal, recorded: [Float], recordedStart: Double = 0) -> Result {
        let rate = Lockstep.sampleRate
        let length = played.tickLength
        guard
            recordedStart.isFinite, abs(recordedStart) < 3_600,
            length > 0, !played.tickSamples.isEmpty, !recorded.isEmpty,
            played.tickSamples.allSatisfy({ $0 >= 0 && $0 + length <= played.samples.count })
        else { return .failed }

        // The recording starts between two samples of the ticks. The whole samples are taken care of when the
        // two are laid over each other, and the rest is added to the answer.
        let startInSamples = recordedStart * rate
        let wholeStart = Int(startInSamples.rounded())
        let restOfStart = startInSamples - Double(wholeStart)

        let longest = Int((longestDelay * rate).rounded())
        // One more delay at each end, so the best fit always has a neighbour on both sides.
        let firstDelay = -1
        var fits = [Double](repeating: 0, count: longest + 3)
        var playedEnergy = 0.0
        played.samples.withUnsafeBufferPointer { ticks in
            recorded.withUnsafeBufferPointer { heard in
                for tick in played.tickSamples {
                    let tickSound = UnsafeBufferPointer(rebasing: ticks[tick..<tick + length])
                    playedEnergy += Double(product(of: tickSound, with: tickSound, at: 0))
                    for index in fits.indices {
                        let place = tick - wholeStart + firstDelay + index
                        fits[index] += Double(product(of: tickSound, with: heard, at: place))
                    }
                }
            }
        }

        // The best fit, whichever way up the sound is.
        var best = 1
        for index in 1...longest + 1 where abs(fits[index]) > abs(fits[best]) {
            best = index
        }
        let bestFit = abs(fits[best])
        let usualFit = middle(of: fits[1...longest + 1].map { abs($0) })
        guard bestFit > 0, bestFit >= peakStandout * usualFit else { return .failed }
        let wayUp: Double = fits[best] < 0 ? -1 : 1
        let delaySamples = best + firstDelay

        // Somewhere in three seconds of noise, the ticks fit by chance well enough to pass the test above, and
        // now and then the single ticks agree by chance too (about one recording of noise in 150). What noise
        // never has is one place that fits far better than every other place.
        let agreement = Int((tickAgreementSeconds * rate).rounded())
        var bestElsewhere = 0.0
        for index in 1...longest + 1 where abs(index - best) > agreement {
            bestElsewhere = max(bestElsewhere, abs(fits[index]))
        }
        guard bestFit >= otherPlaceStandout * bestElsewhere else { return .failed }

        // Each tick on its own.
        let search = Int((tickSearchSeconds * rate).rounded())
        var agreeing = 0
        var heardEnergy = 0.0
        played.samples.withUnsafeBufferPointer { ticks in
            recorded.withUnsafeBufferPointer { heard in
                for tick in played.tickSamples {
                    let tickSound = UnsafeBufferPointer(rebasing: ticks[tick..<tick + length])
                    let place = tick - wholeStart + delaySamples
                    var ownBest = 0
                    var ownBestFit = 0.0
                    for offset in -search...search {
                        let fit = wayUp * Double(product(of: tickSound, with: heard, at: place + offset))
                        if fit > ownBestFit {
                            ownBestFit = fit
                            ownBest = offset
                        }
                    }
                    if ownBestFit > 0, abs(ownBest) <= agreement {
                        agreeing += 1
                    }
                    heardEnergy += Double(energy(of: heard, at: place, count: length))
                }
            }
        }
        guard agreeing >= min(ticksThatMustAgree, played.tickSamples.count) else { return .failed }

        // Where between two samples the best fit lies: the top of the curve through it and its two neighbours.
        let before = wayUp * fits[best - 1]
        let after = wayUp * fits[best + 1]
        let bend = before - 2 * bestFit + after
        let between = bend < 0 ? min(max(0.5 * (before - after) / bend, -0.5), 0.5) : 0

        let delay = max((Double(delaySamples) + between + restOfStart) / rate, 0)
        let quality = heardEnergy > 0 ? min(bestFit / (playedEnergy * heardEnergy).squareRoot(), 1) : 0
        return .measured(delay: delay, quality: quality)
    }

    /// How well a tick fits the recording when its first sample is laid on sample `place` of the recording:
    /// the two multiplied sample by sample and added up. Where the recording has no samples it counts as silent.
    ///
    /// This is run some twenty million times for one measurement, so it is written with bare memory addresses
    /// and a plain loop. Written the usual way it takes seconds in the build Max runs, and this way a moment.
    private static func product(
        of tick: UnsafeBufferPointer<Float>,
        with heard: UnsafeBufferPointer<Float>,
        at place: Int
    ) -> Float {
        let first = max(0, -place)
        let end = min(tick.count, heard.count - place)
        guard first < end, let tickStart = tick.baseAddress, let heardStart = heard.baseAddress else { return 0 }
        let tickSamples = tickStart + first
        let heardSamples = heardStart + place + first
        let count = end - first
        var sum: Float = 0
        var index = 0
        while index < count {
            sum += tickSamples[index] * heardSamples[index]
            index += 1
        }
        return sum
    }

    /// How much sound the recording holds in `count` samples from sample `place` on: its samples squared and
    /// added up.
    private static func energy(of heard: UnsafeBufferPointer<Float>, at place: Int, count: Int) -> Float {
        let first = max(0, place)
        let end = min(heard.count, place + count)
        guard first < end else { return 0 }
        let part = UnsafeBufferPointer(rebasing: heard[first..<end])
        return product(of: part, with: part, at: 0)
    }

    /// The middle value of a list: half of the values are below it.
    private static func middle(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

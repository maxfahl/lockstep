import Accelerate
import Foundation
import LockstepCore

/// The picture of a sound that the beat model reads: for every 20 ms of sound, how loud each of
/// 128 pitch bands is.
public struct BeatSpectrogram: Sendable, Equatable {
    /// Frame after frame, `BeatModel.bandCount` values each. Frame `i` is centred on the time
    /// `i / 50` seconds. Digital silence is exactly 0.
    public let values: [Float]
    /// `1 + floor(samples / 441)` for a sound of `samples` samples at 22,050 Hz. 0 for no sound.
    public let frameCount: Int

    public init(values: [Float], frameCount: Int) {
        precondition(values.count == frameCount * BeatModel.bandCount, "A frame holds one value for each band.")
        self.values = values
        self.frameCount = frameCount
    }
}

/// Turns sound into the spectrogram the beat model was trained on.
///
/// The settings are the model's own, read from its source: 22,050 Hz mono, a 1024-point transform
/// every 441 samples (50 frames per second) with a periodic Hann window, frames centred with the
/// sound mirrored at both ends, the magnitude divided by 32, 128 Slaney mel bands from 30 to 11,000
/// Hz without area normalisation, and `log(1 + 1000 x)`.
public enum BeatFrontEnd {
    /// The sample rate the model listens at.
    public static let sampleRate = 22_050.0
    /// Frames per second of the spectrogram: 22,050 / 441.
    public static let framesPerSecond = 50.0
    static let fftSize = 1024
    static let hop = 441
    static let bandCount = BeatModel.bandCount
    static let lowestHertz = 30.0
    static let highestHertz = 11_000.0
    private static let binCount = fftSize / 2 + 1

    /// The spectrogram of a song's mono mix (the mean of left and right).
    public static func spectrogram(of song: ImportedSong) -> BeatSpectrogram {
        spectrogram(of: OnsetStrength.monoMix(of: song), sampleRate: Lockstep.sampleRate)
    }

    /// The spectrogram of a mono signal at any sample rate. A signal that is not at 22,050 Hz is
    /// resampled first.
    public static func spectrogram(of samples: [Float], sampleRate: Double = Lockstep.sampleRate) -> BeatSpectrogram {
        let atModelRate = sampleRate == Self.sampleRate ? samples : resample(samples, from: sampleRate)
        return atModelRate.withUnsafeBufferPointer { spectrogram(atModelRate: $0) }
    }

    // MARK: - Resampling

    /// How far below half the lower sample rate the resampler starts to fade out, as a share of
    /// it. Everything above half the lower rate is removed. The model's own code resamples with
    /// the library soxr at its default quality, which fades over the same stretch.
    static let passbandShare = 0.913
    /// How much quieter everything above half the lower rate becomes, in decibels.
    static let stopbandDecibels = 120.0

    /// The same sound at 22,050 Hz. It has `samples.count * 22,050 / sampleRate` samples, rounded,
    /// and sample `n` of the result is the sound at the time `n / 22,050` seconds: nothing is shifted.
    ///
    /// Each new sample is a weighted mean of the old samples around its time. The weights are a
    /// sinc curve under a Kaiser window. Because the two rates are whole numbers, the weights
    /// repeat after a few new samples (147 for 48,000 Hz), so they are worked out once.
    public static func resample(_ samples: [Float], from sampleRate: Double) -> [Float] {
        let (inRate, outRate) = (Int(sampleRate.rounded()), Int(Self.sampleRate))
        guard inRate > 0, !samples.isEmpty else { return [] }
        guard inRate != outRate else { return samples }
        let divisor = greatestCommonDivisor(inRate, outRate)
        // New sample `n` stands at old position `n * step / phaseCount`.
        let (step, phaseCount) = (inRate / divisor, outRate / divisor)

        let nyquist = Double(min(inRate, outRate)) / 2
        let cutoff = nyquist * (1 + passbandShare) / 2
        let transition = 2 * Double.pi * nyquist * (1 - passbandShare) / Double(inRate)
        let half = Int(((stopbandDecibels - 7.95) / (2.285 * transition) / 2).rounded(.up))
        let tapCount = 2 * half
        let beta = 0.1102 * (stopbandDecibels - 8.7)

        // For each phase: the weights of the old samples `floor(position) - half + 1` and on.
        var weights = [Float](repeating: 0, count: phaseCount * tapCount)
        for phase in 0..<phaseCount {
            let fraction = Double(phase) / Double(phaseCount)
            var row = [Double](repeating: 0, count: tapCount)
            for tap in 0..<tapCount {
                let distance = Double(tap - half + 1) - fraction
                let x = 2 * cutoff * distance / Double(inRate)
                let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                let across = distance / Double(half)
                row[tap] = abs(across) < 1 ? sinc * besselI0(beta * (1 - across * across).squareRoot()) : 0
            }
            // A steady level must come out at the same level.
            let sum = row.reduce(0, +)
            for tap in 0..<tapCount { weights[phase * tapCount + tap] = Float(row[tap] / sum) }
        }

        let outCount = Int((Double(samples.count) * Double(outRate) / Double(inRate)).rounded())
        guard outCount > 0 else { return [] }
        let blockSize = 32_768
        return [Float](unsafeUninitializedCapacity: outCount) { output, initialized in
            samples.withUnsafeBufferPointer { input in
                weights.withUnsafeBufferPointer { weights in
                    let shared = ResamplerMemory(input: input, weights: weights, output: output)
                    // The pieces run side by side. Each writes its own stretch of the result.
                    DispatchQueue.concurrentPerform(iterations: (outCount + blockSize - 1) / blockSize) { block in
                        guard let input = shared.input.baseAddress, let weights = shared.weights.baseAddress,
                            let output = shared.output.baseAddress
                        else { return }
                        let inCount = shared.input.count
                        for n in (block * blockSize)..<min((block + 1) * blockSize, outCount) {
                            let position = n * step
                            let first = position / phaseCount - half + 1
                            let row = weights + (position % phaseCount) * tapCount
                            // Beyond the ends of the sound there is silence.
                            let from = max(first, 0), to = min(first + tapCount, inCount)
                            guard from < to else {
                                output[n] = 0
                                continue
                            }
                            vDSP_dotpr(input + from, 1, row + (from - first), 1, output + n, vDSP_Length(to - from))
                        }
                    }
                }
            }
            initialized = outCount
        }
    }

    /// Lets the pieces of the resampling, which run side by side, read the one sound and the one
    /// table of weights, and each write its own part of the result.
    private struct ResamplerMemory: @unchecked Sendable {
        let input: UnsafeBufferPointer<Float>
        let weights: UnsafeBufferPointer<Float>
        let output: UnsafeMutableBufferPointer<Float>
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    /// The modified Bessel function of the first kind, order 0, which shapes the Kaiser window.
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0, k = 1.0
        while term > sum * 1e-17 {
            term *= (x / (2 * k)) * (x / (2 * k))
            sum += term
            k += 1
        }
        return sum
    }

    // MARK: - Spectrogram

    /// The spectrogram of a mono signal that is already at 22,050 Hz.
    static func spectrogram(atModelRate samples: UnsafeBufferPointer<Float>) -> BeatSpectrogram {
        guard let base = samples.baseAddress, !samples.isEmpty else { return BeatSpectrogram(values: [], frameCount: 0) }
        let count = samples.count
        let frameCount = 1 + count / hop
        let half = fftSize / 2
        let bank = MelBank.shared
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
            preconditionFailure("A 1024-point transform is always available.")
        }
        defer { vDSP_DFT_DestroySetup(setup) }

        // The Hann window (the periodic kind), split into its even and odd samples the way the
        // transform wants its input. The transform returns twice the true spectrum and the model
        // wants the spectrum divided by 32, so the window carries both: a division by 64.
        var windowEven = [Float](repeating: 0, count: half), windowOdd = windowEven
        for index in 0..<half {
            windowEven[index] = Float((0.5 - 0.5 * cos(2 * Double.pi * Double(2 * index) / Double(fftSize))) / 64)
            windowOdd[index] = Float((0.5 - 0.5 * cos(2 * Double.pi * Double(2 * index + 1) / Double(fftSize))) / 64)
        }
        var padded = [Float](repeating: 0, count: fftSize)
        var inputEven = [Float](repeating: 0, count: half), inputOdd = inputEven
        var real = inputEven, imaginary = inputEven
        var magnitude = [Float](repeating: 0, count: binCount)
        var values = [Float](repeating: 0, count: frameCount * bandCount)
        var thousand: Float = 1000
        var bandsPerCall = Int32(frameCount * bandCount)

        values.withUnsafeMutableBufferPointer { values in
            guard let values = values.baseAddress else { return }
            for frame in 0..<frameCount {
                let start = frame * hop - half
                padded.withUnsafeMutableBufferPointer { padded in
                    guard let padded = padded.baseAddress else { return }
                    if start >= 0, start + fftSize <= count {
                        padded.update(from: base + start, count: fftSize)
                    } else {
                        // The frame hangs over the start or the end, where the sound is mirrored
                        // around its first or last sample. A sound too short to mirror gets silence.
                        for offset in 0..<fftSize {
                            var index = start + offset
                            if index < 0 { index = -index }
                            if index >= count { index = 2 * (count - 1) - index }
                            padded[offset] = index >= 0 && index < count ? base[index] : 0
                        }
                    }
                    vDSP_vmul(padded, 2, windowEven, 1, &inputEven, 1, vDSP_Length(half))
                    vDSP_vmul(padded + 1, 2, windowOdd, 1, &inputOdd, 1, vDSP_Length(half))
                }
                vDSP_DFT_Execute(setup, inputEven, inputOdd, &real, &imaginary)

                // Bin 0 arrives in real[0] and the top bin (512) in imaginary[0]; neither has a second part.
                let lowest = abs(real[0]), highest = abs(imaginary[0])
                real.withUnsafeMutableBufferPointer { real in
                    imaginary.withUnsafeMutableBufferPointer { imaginary in
                        var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                        vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(half))
                    }
                }
                magnitude[0] = lowest
                magnitude[binCount - 1] = highest

                let row = values + frame * bandCount
                magnitude.withUnsafeBufferPointer { magnitude in
                    bank.weights.withUnsafeBufferPointer { weights in
                        for band in 0..<bandCount {
                            vDSP_dotpr(
                                magnitude.baseAddress! + bank.firstBin[band], 1,
                                weights.baseAddress! + bank.weightStart[band], 1,
                                row + band, vDSP_Length(bank.weightCount[band])
                            )
                        }
                    }
                }
            }
            // log(1 + 1000 x) for the whole spectrogram at once.
            vDSP_vsmul(values, 1, &thousand, values, 1, vDSP_Length(frameCount * bandCount))
            vvlog1pf(values, values, &bandsPerCall)
        }
        return BeatSpectrogram(values: values, frameCount: frameCount)
    }

    /// The 128 mel bands as the model's own code builds them (torchaudio's `melscale_fbanks` with
    /// the Slaney scale and no area normalisation): triangles that reach 1 at their centre, each
    /// stored as the few spectrum bins it covers.
    struct MelBank: Sendable {
        static let shared = MelBank()

        let firstBin: [Int]
        let weightStart: [Int]
        let weightCount: [Int]
        let weights: [Float]

        init() {
            let bottom = OnsetStrength.melFromHertz(lowestHertz)
            let top = OnsetStrength.melFromHertz(highestHertz)
            let edges = (0..<(bandCount + 2)).map {
                OnsetStrength.hertzFromMel(bottom + (top - bottom) * Double($0) / Double(bandCount + 1))
            }
            let binWidth = BeatFrontEnd.sampleRate / Double(fftSize)
            var firstBin: [Int] = [], weightStart: [Int] = [], weightCount: [Int] = [], weights: [Float] = []
            for band in 0..<bandCount {
                let (low, centre, high) = (edges[band], edges[band + 1], edges[band + 2])
                var bandWeights: [Float] = []
                var first = 0
                for bin in 0..<binCount {
                    let frequency = Double(bin) * binWidth
                    let weight = min((frequency - low) / (centre - low), (high - frequency) / (high - centre))
                    guard weight > 0 else { continue }
                    if bandWeights.isEmpty { first = bin }
                    bandWeights.append(Float(weight))
                }
                firstBin.append(first)
                weightStart.append(weights.count)
                weightCount.append(bandWeights.count)
                weights.append(contentsOf: bandWeights)
            }
            self.firstBin = firstBin
            self.weightStart = weightStart
            self.weightCount = weightCount
            self.weights = weights
        }
    }
}

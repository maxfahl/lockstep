import Accelerate
import Foundation
import LockstepCore

/// How much new sound appears at each moment of a signal: one value every 32 samples (0.67 ms).
///
/// A drum hit or the start of a syllable shows as a sharp peak. A held note shows as nothing.
public struct OnsetCurve: Sendable, Equatable {
    /// The distance between two values, in samples at 48,000 Hz.
    public static let hopSamples = 32

    /// One value per hop: the mean rise in loudness across 128 frequency bands, in decibels.
    /// Never negative. Value `i` belongs to the time `time(at: i)`.
    public let values: [Float]

    public init(values: [Float]) {
        self.values = values
    }

    /// The time of value `index`, in seconds from the start of the signal: `index * 32 / 48,000`.
    public func time(at index: Int) -> Double {
        Double(index * Self.hopSamples) / Lockstep.sampleRate
    }

    /// The time of every value, in seconds, in the same order as `values`.
    public var times: [Double] {
        (0..<values.count).map(time(at:))
    }
}

/// Measures the onset curve of a mono signal at 48,000 Hz.
///
/// A port of `librosa.onset.onset_strength(y, sr=48000, hop_length=32, n_fft=1024)` with librosa's
/// defaults, as the Python prototype that came before the app used it (full band):
/// a power spectrogram (Hann window, frames centred on multiples of the hop, zeros beyond the ends),
/// 128 Slaney mel bands from 0 to 24,000 Hz, decibels with nothing quieter than 80 dB under the
/// loudest point, the rise from one frame to the next with falls set to zero, and the mean across bands.
///
/// As in librosa, the curve is moved 16 hops (half a window) later, so that a value stands at the time
/// where its window ends. A sudden sound then peaks 0 to 1 ms after it begins, instead of 10 ms before.
public enum OnsetStrength {
    static let fftSize = 1024
    static let hop = OnsetCurve.hopSamples
    static let bandCount = 128
    /// Nothing is counted as quieter than this power (librosa's `amin`).
    static let quietestPower: Float = 1e-10
    /// Nothing is counted as more than this many decibels under the loudest point (librosa's `top_db`).
    static let rangeDecibels: Float = 80
    /// How many hops later a value is placed than the centre of its window: one for the difference
    /// between two frames is added to this where it is used.
    static let shiftFrames = fftSize / (2 * hop)
    private static let binCount = fftSize / 2 + 1
    /// Frames worked on as one piece. A piece needs under 100 kB of working memory.
    private static let blockFrames = 4096

    /// The onset curve of a mono signal at 48,000 Hz. It has `1 + samples.count / 32` values,
    /// and none for an empty signal.
    public static func curve(of samples: [Float]) -> OnsetCurve {
        samples.withUnsafeBufferPointer { curve(of: $0) }
    }

    /// The onset curve of a song's mono mix (the mean of left and right).
    public static func curve(of song: ImportedSong) -> OnsetCurve {
        curve(of: monoMix(of: song))
    }

    /// The mean of left and right for every sample of a song.
    public static func monoMix(of song: ImportedSong) -> [Float] {
        let count = song.lengthSamples
        return [Float](unsafeUninitializedCapacity: count) { mono, initialized in
            song.samples.withUnsafeBufferPointer { stereo in
                guard count > 0, let source = stereo.baseAddress, let target = mono.baseAddress else { return }
                var half: Float = 0.5
                vDSP_vasm(source, 2, source + 1, 2, &half, target, 1, vDSP_Length(count))
            }
            initialized = count
        }
    }

    public static func curve(of samples: UnsafeBufferPointer<Float>) -> OnsetCurve {
        guard !samples.isEmpty else { return OnsetCurve(values: []) }
        let frameCount = 1 + samples.count / hop
        let bank = MelBank.shared
        let blockCount = (frameCount + blockFrames - 1) / blockFrames

        // First time through the signal: only to find the loudest point, which sets the quietest
        // level that counts. Keeping every band of every frame instead would take 160 MB for a song.
        let samples = SharedInput(pointer: samples)
        var blockLoudest = [Float](repeating: -.infinity, count: blockCount)
        blockLoudest.withUnsafeMutableBufferPointer { loudest in
            let loudest = Shared(loudest)
            DispatchQueue.concurrentPerform(iterations: blockCount) { block in
                let worker = Worker(bank: bank)
                var best = -Float.infinity
                var frameLoudest: Float = 0
                let first = block * blockFrames
                for frame in first..<min(first + blockFrames, frameCount) {
                    worker.melDecibels(ofFrame: frame, in: samples.pointer, into: worker.now)
                    vDSP_maxv(worker.now, 1, &frameLoudest, vDSP_Length(bandCount))
                    best = max(best, frameLoudest)
                }
                loudest.pointer[block] = best
            }
        }
        let floorDecibels = (blockLoudest.max() ?? 0) - rangeDecibels

        // Second time through: the rise between neighbouring frames. Value `i` of the result is the
        // rise into frame `i - shiftFrames`, so the last `shiftFrames` frames are not needed.
        var values = [Float](repeating: 0, count: frameCount)
        let lastRiseFrame = frameCount - 1 - shiftFrames
        guard lastRiseFrame >= 1 else { return OnsetCurve(values: values) }
        let riseBlockCount = (lastRiseFrame + blockFrames - 1) / blockFrames
        values.withUnsafeMutableBufferPointer { output in
            let output = Shared(output)
            DispatchQueue.concurrentPerform(iterations: riseBlockCount) { block in
                let worker = Worker(bank: bank)
                var before = worker.before, now = worker.now
                let rise = worker.rise, count = vDSP_Length(bandCount)
                var floorLevel = floorDecibels, zero: Float = 0
                let first = 1 + block * blockFrames
                worker.melDecibels(ofFrame: first - 1, in: samples.pointer, into: before)
                vDSP_vthr(before, 1, &floorLevel, before, 1, count)
                for frame in first...min(first + blockFrames - 1, lastRiseFrame) {
                    worker.melDecibels(ofFrame: frame, in: samples.pointer, into: now)
                    vDSP_vthr(now, 1, &floorLevel, now, 1, count)
                    vDSP_vsub(before, 1, now, 1, rise, 1, count)
                    vDSP_vthr(rise, 1, &zero, rise, 1, count)
                    vDSP_meanv(rise, 1, output.pointer.baseAddress! + frame + shiftFrames, count)
                    swap(&before, &now)
                }
            }
        }
        return OnsetCurve(values: values)
    }

    /// Lets the pieces, which run side by side, all read the one signal.
    private struct SharedInput: @unchecked Sendable {
        let pointer: UnsafeBufferPointer<Float>
    }

    /// Lets the pieces, which run side by side, each write their own part of one list.
    private struct Shared<Element>: @unchecked Sendable {
        let pointer: UnsafeMutableBufferPointer<Element>
        init(_ pointer: UnsafeMutableBufferPointer<Element>) { self.pointer = pointer }
    }

    /// The 128 mel bands as librosa builds them (`librosa.filters.mel`, Slaney scale and Slaney norm),
    /// each stored as the few spectrum bins it covers.
    struct MelBank: Sendable {
        static let shared = MelBank()

        /// For every band: the first spectrum bin it reads and where its weights start in `weights`.
        let firstBin: [Int]
        let weightStart: [Int]
        let weightCount: [Int]
        let weights: [Float]

        init() {
            let top = OnsetStrength.melFromHertz(Lockstep.sampleRate / 2)
            let edges = (0..<(bandCount + 2)).map { OnsetStrength.hertzFromMel(top * Double($0) / Double(bandCount + 1)) }
            let binWidth = Lockstep.sampleRate / Double(fftSize)
            var firstBin: [Int] = [], weightStart: [Int] = [], weightCount: [Int] = [], weights: [Float] = []
            for band in 0..<bandCount {
                let (low, centre, high) = (edges[band], edges[band + 1], edges[band + 2])
                let scale = 2 / (high - low)
                var bandWeights: [Float] = []
                var first = 0
                for bin in 0..<binCount {
                    let frequency = Double(bin) * binWidth
                    let weight = min((frequency - low) / (centre - low), (high - frequency) / (high - centre))
                    guard weight > 0 else { continue }
                    if bandWeights.isEmpty { first = bin }
                    bandWeights.append(Float(weight * scale))
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

    /// The Slaney mel scale: even steps of 66.7 Hz up to 1,000 Hz, even ratios above.
    static func melFromHertz(_ hertz: Double) -> Double {
        hertz < 1000 ? hertz * 3 / 200 : 15 + log(hertz / 1000) / (log(6.4) / 27)
    }

    static func hertzFromMel(_ mel: Double) -> Double {
        mel < 15 ? mel * 200 / 3 : 1000 * exp((mel - 15) * (log(6.4) / 27))
    }

    /// The working memory of one piece: turns one frame of the signal into 128 band levels in decibels.
    ///
    /// Everything it touches in the inner loop is memory of its own, reached through plain pointers.
    /// Pieces run side by side, and lists shared between them would make them wait for each other.
    private final class Worker {
        private let setup: vDSP_DFT_Setup
        /// One block of memory, cut into the parts named below.
        private let memory: UnsafeMutablePointer<Float>
        private let memoryCount: Int
        /// The Hann window, split into its even and odd samples the way the transform wants its input,
        /// and halved because the transform returns twice the true spectrum.
        private let windowEven: UnsafeMutablePointer<Float>
        private let windowOdd: UnsafeMutablePointer<Float>
        private let padded: UnsafeMutablePointer<Float>
        private let inputEven: UnsafeMutablePointer<Float>
        private let inputOdd: UnsafeMutablePointer<Float>
        private let real: UnsafeMutablePointer<Float>
        private let imaginary: UnsafeMutablePointer<Float>
        private let power: UnsafeMutablePointer<Float>
        private let weights: UnsafeMutablePointer<Float>
        /// Three numbers per band: first spectrum bin, where its weights start, how many there are.
        private let bands: UnsafeMutablePointer<Int>
        /// Band levels of the frame before, of this frame, and the rise between them.
        let before: UnsafeMutablePointer<Float>
        let now: UnsafeMutablePointer<Float>
        let rise: UnsafeMutablePointer<Float>

        init(bank: MelBank) {
            guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
                preconditionFailure("A 1024-point transform is always available.")
            }
            self.setup = setup
            let half = fftSize / 2
            memoryCount = 6 * half + fftSize + binCount + bank.weights.count + 3 * bandCount
            memory = .allocate(capacity: memoryCount)
            memory.initialize(repeating: 0, count: memoryCount)
            var next = memory
            func take(_ count: Int) -> UnsafeMutablePointer<Float> {
                defer { next += count }
                return next
            }
            windowEven = take(half)
            windowOdd = take(half)
            padded = take(fftSize)
            inputEven = take(half)
            inputOdd = take(half)
            real = take(half)
            imaginary = take(half)
            power = take(binCount)
            weights = take(bank.weights.count)
            before = take(bandCount)
            now = take(bandCount)
            rise = take(bandCount)
            for index in 0..<half {
                windowEven[index] = Float(0.5 * (0.5 - 0.5 * cos(2 * Double.pi * Double(2 * index) / Double(fftSize))))
                windowOdd[index] = Float(0.5 * (0.5 - 0.5 * cos(2 * Double.pi * Double(2 * index + 1) / Double(fftSize))))
            }
            for index in bank.weights.indices { weights[index] = bank.weights[index] }
            bands = .allocate(capacity: 3 * bandCount)
            for band in 0..<bandCount {
                bands[3 * band] = bank.firstBin[band]
                bands[3 * band + 1] = bank.weightStart[band]
                bands[3 * band + 2] = bank.weightCount[band]
            }
        }

        deinit {
            vDSP_DFT_DestroySetup(setup)
            memory.deallocate()
            bands.deallocate()
        }

        /// The level of each band, in decibels, for the frame centred on sample `frame * hop`.
        func melDecibels(ofFrame frame: Int, in samples: UnsafeBufferPointer<Float>, into decibels: UnsafeMutablePointer<Float>) {
            let half = vDSP_Length(fftSize / 2)
            let start = frame * hop - fftSize / 2
            var source = padded
            if start >= 0, start + fftSize <= samples.count, let base = samples.baseAddress {
                source = UnsafeMutablePointer(mutating: base + start)
            } else {
                // The frame hangs over the start or the end: there is silence beyond.
                let from = max(start, 0), to = min(start + fftSize, samples.count)
                padded.update(repeating: 0, count: fftSize)
                if from < to, let base = samples.baseAddress {
                    (padded + (from - start)).update(from: base + from, count: to - from)
                }
            }
            vDSP_vmul(source, 2, windowEven, 1, inputEven, 1, half)
            vDSP_vmul(source + 1, 2, windowOdd, 1, inputOdd, 1, half)
            vDSP_DFT_Execute(setup, inputEven, inputOdd, real, imaginary)

            // Bin 0 arrives in real[0] and the top bin (512) in imaginary[0]; neither has a second part.
            let lowest = real[0] * real[0], highest = imaginary[0] * imaginary[0]
            var split = DSPSplitComplex(realp: real, imagp: imaginary)
            vDSP_zvmags(&split, 1, power, 1, half)
            power[0] = lowest
            power[binCount - 1] = highest

            for band in 0..<bandCount {
                vDSP_dotpr(
                    power + bands[3 * band], 1,
                    weights + bands[3 * band + 1], 1,
                    decibels + band, vDSP_Length(bands[3 * band + 2])
                )
            }
            var quietest = quietestPower
            var count = Int32(bandCount)
            var ten: Float = 10
            vDSP_vthr(decibels, 1, &quietest, decibels, 1, vDSP_Length(bandCount))
            vvlog10f(decibels, decibels, &count)
            vDSP_vsmul(decibels, 1, &ten, decibels, 1, vDSP_Length(bandCount))
        }
    }
}

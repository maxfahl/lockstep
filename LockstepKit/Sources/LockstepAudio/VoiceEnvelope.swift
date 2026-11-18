import Accelerate
import Foundation
import LockstepCore

/// How loud a recording is in the band where a voice is strong (300 to 3,000 Hz): one value
/// for every 48 samples (1 ms), lightly smoothed.
///
/// This is the app's one definition of "sound" and "pause" in a recording. Sound is what
/// stands clearly above the recording's own noise floor in this band. The deep part of a song
/// leaking from the headphones, hum and rumble lie outside the band and count for little.
///
///     let envelope = VoiceEnvelope.envelope(of: recordingSamples)   // mono, 48,000 Hz
///     if let voice = envelope.voicedRange() {
///         // voice.lowerBound ..< voice.upperBound, in samples of the recording
///     }
public struct VoiceEnvelope: Sendable, Equatable {
    /// The distance between two values, in samples at 48,000 Hz: exactly 1 ms.
    public static let hopSamples = 48
    /// The band that is measured, in hertz.
    public static let band: ClosedRange<Double> = 300...3000
    /// How far above the noise floor counts as sound, in decibels.
    public static let clearlyAboveDecibels: Float = 12
    /// How long sound must last to count, in milliseconds. A tap or a tick is shorter.
    public static let minimumSoundMs: Double = 30
    /// How much is kept before the first sound and after the last, in milliseconds. A word
    /// starts with a breath or a soft consonant and dies away slowly.
    /// The two numbers are kept with the other numbers that decide a clip's edges (`TakeTrim`).
    public static let marginBeforeMs: Double = TakeTrim.marginBeforeSeconds * 1000
    public static let marginAfterMs: Double = TakeTrim.marginAfterSeconds * 1000
    /// No value and no noise floor is lower than these, in decibels. A stretch of pure
    /// digital silence would otherwise make everything else look like sound.
    public static let quietestValue: Float = -120
    public static let quietestNoiseFloor: Float = -90

    /// One value per hop, in decibels relative to full scale: the mean power of the band
    /// around that moment (about 10 ms). A full-scale sine in the band reads -3.
    /// Value `i` belongs to samples `i * 48 ..< (i + 1) * 48`.
    public let values: [Float]
    /// The length of the recording the values were measured from, in samples.
    public let lengthSamples: Int
    /// The level of the quietest tenth of the recording, in decibels: a tenth of the values
    /// lie under it. Room noise, and the song leaking from the headphones at its quietest.
    public let noiseFloor: Float

    /// `values` must be the values measured from a recording of `lengthSamples` samples.
    public init(values: [Float], lengthSamples: Int) {
        self.values = values
        self.lengthSamples = lengthSamples
        self.noiseFloor = Self.noiseFloor(of: values)
    }

    /// How many values a recording of this many samples has: one per started millisecond.
    public static func valueCount(forLength lengthSamples: Int) -> Int {
        (max(lengthSamples, 0) + hopSamples - 1) / hopSamples
    }

    /// Measures a mono recording at 48,000 Hz.
    public static func envelope(of samples: [Float]) -> VoiceEnvelope {
        let count = samples.count
        guard count > 0 else { return VoiceEnvelope(values: [], lengthSamples: 0) }

        // The band is cut out by filtering once forwards and once backwards. Going both ways
        // cancels the small delay a filter adds, so a sound stands at its true time.
        var work = [Float](repeating: 0, count: count)
        var filtered = [Float](repeating: 0, count: count)
        filter(samples, into: &work)
        vDSP_vrvrs(&work, 1, vDSP_Length(count))
        filter(work, into: &filtered)
        vDSP_vrvrs(&filtered, 1, vDSP_Length(count))

        // The mean power of every millisecond.
        vDSP_vsq(filtered, 1, &work, 1, vDSP_Length(count))
        let valueCount = valueCount(forLength: count)
        var power = [Float](repeating: 0, count: valueCount)
        work.withUnsafeBufferPointer { squares in
            for index in 0..<valueCount {
                let start = index * hopSamples
                vDSP_meanv(squares.baseAddress! + start, 1, &power[index], vDSP_Length(min(hopSamples, count - start)))
            }
        }

        // Smoothed: each value becomes the mean of itself and its neighbours, 11 ms in all.
        // At the two ends the mean is of the neighbours that exist.
        var runningSum = [Double](repeating: 0, count: valueCount + 1)
        for index in 0..<valueCount { runningSum[index + 1] = runningSum[index] + Double(power[index]) }
        var values = [Float](repeating: 0, count: valueCount)
        for index in 0..<valueCount {
            let from = max(index - smoothingReach, 0), to = min(index + smoothingReach + 1, valueCount)
            let mean = (runningSum[to] - runningSum[from]) / Double(to - from)
            values[index] = max(Float(10 * log10(max(mean, 1e-30))), quietestValue)
        }
        return VoiceEnvelope(values: values, lengthSamples: count)
    }

    /// The part of the recording with sound in it, in samples of the recording: from 50 ms
    /// before the first sound to 150 ms after the last, never beyond the recording's ends.
    /// Nil when nothing in the recording counts as sound.
    ///
    /// Sound is what `voicedStretches` finds.
    public func voicedRange(minimumGapMs: Double = 20) -> Range<Int>? {
        let stretches = voicedStretches(minimumGapMs: minimumGapMs)
        guard let first = stretches.first, let last = stretches.last else { return nil }
        let before = Self.hops(Self.marginBeforeMs) * Self.hopSamples
        let after = Self.hops(Self.marginAfterMs) * Self.hopSamples
        let start = max(first.lowerBound - before, 0)
        let end = min(last.upperBound + after, lengthSamples)
        return start < end ? start..<end : nil
    }

    /// When the noise floor is measured from a later sample on, at least this much of the
    /// recording must lie after that sample, in seconds. With less, the whole recording is
    /// measured: a noise floor from a moment of sound says little.
    public static let shortestNoiseFloorSeconds: Double = 1

    /// Every stretch of sound in the recording, one after the other, in samples of the
    /// recording, exactly where the sound is: nothing is added before or after.
    ///
    /// Sound is a stretch at least 30 ms long where the envelope is more than 12 dB above the
    /// noise floor. A dip under that level shorter than `minimumGapMs` does not end a stretch,
    /// so a syllable that wavers in loudness is still one sound.
    ///
    /// - Parameter firstSample: the sample from which the noise floor is measured. A take
    ///   begins with its count-in, where the song in the headphones is silent or still rising,
    ///   so that part is quieter than the rest. Measured over the whole take, the quietest
    ///   tenth can be that part alone, and the song leaking in at full level afterwards then
    ///   stands 12 dB above it and looks like a voice. Give the sample where the song has
    ///   reached full level, and the floor is that of the take proper. 0 measures everything.
    public func voicedStretches(minimumGapMs: Double = 20, noiseFloorFrom firstSample: Int = 0) -> [Range<Int>] {
        let threshold = noiseFloor(from: firstSample) + Self.clearlyAboveDecibels
        let minimumGap = Self.hops(minimumGapMs)
        let minimumSound = max(Self.hops(Self.minimumSoundMs), 1)

        var stretches: [Range<Int>] = []
        var stretchStart: Int?
        var stretchEnd = 0
        func closeStretch() {
            guard let start = stretchStart, stretchEnd - start >= minimumSound else { return }
            stretches.append(start * Self.hopSamples..<min(stretchEnd * Self.hopSamples, lengthSamples))
        }
        for (index, value) in values.enumerated() where value > threshold {
            if stretchStart != nil, index - stretchEnd >= max(minimumGap, 1) {
                closeStretch()
                stretchStart = nil
            }
            if stretchStart == nil { stretchStart = index }
            stretchEnd = index + 1
        }
        closeStretch()
        return stretches
    }

    /// The noise floor of the part of the recording from `firstSample` on, or of all of it
    /// when that part is too short to say.
    private func noiseFloor(from firstSample: Int) -> Float {
        let first = max(firstSample, 0) / Self.hopSamples
        let shortest = Self.hops(Self.shortestNoiseFloorSeconds * 1000)
        guard first > 0, values.count - first >= shortest else { return noiseFloor }
        return Self.noiseFloor(of: Array(values[first...]))
    }

    // MARK: The parts

    /// How many values on each side are averaged with a value.
    private static let smoothingReach = 5

    private static func hops(_ milliseconds: Double) -> Int {
        Int((max(milliseconds, 0) / 1000 * Lockstep.sampleRate / Double(hopSamples)).rounded())
    }

    private static func noiseFloor(of values: [Float]) -> Float {
        guard !values.isEmpty else { return quietestNoiseFloor }
        let sorted = values.sorted()
        return max(sorted[values.count / 10], quietestNoiseFloor)
    }

    /// Lets through 300 to 3,000 Hz: a high-pass and a low-pass, each of second order
    /// (Butterworth). Run forwards and backwards they fall away at 24 dB per octave.
    private static func filter(_ input: [Float], into output: inout [Float]) {
        func section(cutoff: Double, highPass: Bool) -> [Double] {
            let angle = 2 * Double.pi * cutoff / Lockstep.sampleRate
            let cosine = cos(angle), alpha = sin(angle) / 2.0.squareRoot()
            let scale = 1 + alpha
            let edge = (highPass ? 1 + cosine : 1 - cosine) / 2
            return [edge, highPass ? -2 * edge : 2 * edge, edge, -2 * cosine, 1 - alpha].map { $0 / scale }
        }
        let coefficients = section(cutoff: band.lowerBound, highPass: true) + section(cutoff: band.upperBound, highPass: false)
        guard let setup = vDSP_biquad_CreateSetup(coefficients, 2) else {
            preconditionFailure("A two-section filter is always available.")
        }
        defer { vDSP_biquad_DestroySetup(setup) }
        var memory = [Float](repeating: 0, count: 2 * 2 + 2)
        vDSP_biquad(setup, &memory, input, 1, &output, 1, vDSP_Length(input.count))
    }
}

/// Keeping a recording's envelope in the project's `cache/envelope/` folder, as
/// `<recording id>.f32`: the values, one 32-bit float after the other, lowest byte first.
/// The noise floor follows from the values, so reading gives it back the same.
///
/// The file can be thrown away at any time. `read` then gives nil and the envelope is
/// measured again from the recording.
extension VoiceEnvelope {
    public static func folder(in package: ProjectPackage) -> URL {
        package.cacheFolder.appendingPathComponent("envelope", isDirectory: true)
    }

    public static func file(forRecording id: UUID, in package: ProjectPackage) -> URL {
        folder(in: package).appendingPathComponent("\(id.uuidString).f32")
    }

    /// Writes the file, replacing the one that was there. The folder is made if it is missing.
    public func write(forRecording id: UUID, to package: ProjectPackage) throws {
        try FileManager.default.createDirectory(at: Self.folder(in: package), withIntermediateDirectories: true)
        try values.withUnsafeBytes { Data($0) }.write(to: Self.file(forRecording: id, in: package), options: .atomic)
    }

    /// Reads the file. Nil when it is missing or does not fit a recording of this length.
    public static func read(forRecording id: UUID, lengthSamples: Int, from package: ProjectPackage) -> VoiceEnvelope? {
        guard let raw = try? Data(contentsOf: file(forRecording: id, in: package)) else { return nil }
        let bytesPerValue = MemoryLayout<Float>.size
        let count = valueCount(forLength: lengthSamples)
        guard count > 0, raw.count == count * bytesPerValue else { return nil }
        let values = [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = raw.copyBytes(to: buffer) / bytesPerValue
        }
        return VoiceEnvelope(values: values, lengthSamples: lengthSamples)
    }
}

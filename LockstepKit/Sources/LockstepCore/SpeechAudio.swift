import Foundation

extension Clip {
    /// The sound of the clip as the speech model should hear it, at Lockstep's usual 48,000 samples a second:
    /// the clip's segments one after the other, in their order.
    ///
    /// Gaps between segments are left out, because silence in the middle only costs the model time. Volumes
    /// and fades are ignored: the model hears the recording as it was made. A segment is kept inside its
    /// recording, and one whose recording is not in `recordings` is left out.
    ///
    /// - Parameter recordings: the samples of each recording, by its id (what `RecordingLoader.readAll` gives).
    public func speechSamples(from recordings: [UUID: [Float]]) -> [Float] {
        var sound: [Float] = []
        for segment in segments {
            guard let samples = recordings[segment.recordingID] else { continue }
            let first = min(max(segment.inSample, 0), samples.count)
            let last = min(max(segment.outSample, first), samples.count)
            sound.append(contentsOf: samples[first..<last])
        }
        return sound
    }
}

/// Turns Lockstep's sound, 48,000 samples a second, into what the speech model takes: 16,000 a second.
public enum SpeechAudio {
    /// The rate the speech model was trained on.
    public static let sampleRate = 16_000.0

    /// Sound quieter than this everywhere (-80 dB) counts as silence and is never given to the model.
    public static let silencePeak: Float = 0.0001

    /// True when there is nothing in `samples` that the model could hear words in.
    public static func isSilent(_ samples: [Float]) -> Bool {
        !samples.contains { abs($0) >= silencePeak }
    }

    /// `samples48k` at a third of its rate: every third sample, after everything above 8 kHz is filtered
    /// away. Without the filter the high sounds of a voice (s, t, breath) would fold down into the range
    /// of speech as noise and the model would hear worse.
    public static func resampledTo16k(_ samples48k: [Float]) -> [Float] {
        let count = samples48k.count / 3
        guard count > 0 else { return [] }
        let half = filter.count / 2
        return [Float](unsafeUninitializedCapacity: count) { out, written in
            samples48k.withUnsafeBufferPointer { input in
                filter.withUnsafeBufferPointer { taps in
                    for index in 0..<count {
                        let centre = index * 3
                        // Past the ends of the sound there is silence.
                        let from = max(centre - half, 0)
                        let to = min(centre + half, input.count - 1)
                        var sum: Float = 0
                        if from <= to {
                            for position in from...to {
                                sum += input[position] * taps[position - centre + half]
                            }
                        }
                        out[index] = sum
                    }
                }
            }
            written = count
        }
    }

    /// A low-pass filter for 48 kHz sound that lets through what is below about 5.5 kHz and removes what
    /// is above 8 kHz, the highest sound 16 kHz can hold. 121 values, symmetric, adding up to 1.
    static let filter: [Float] = {
        let half = 60
        let cutoff = 6_800.0 / Lockstep.sampleRate
        var taps = (-half...half).map { step -> Double in
            let x = Double(step)
            let sinc = step == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            // A Blackman window, which keeps what is left above 8 kHz far below the voice.
            let phase = 2 * Double.pi * Double(step + half) / Double(2 * half)
            let window = 0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)
            return sinc * window
        }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 / sum }
        return taps.map(Float.init)
    }()
}

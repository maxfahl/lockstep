import Foundation

/// The short fade at both ends of every segment a clip plays, so a cut in the middle of a sound does not click.
///
/// The fade is a straight line from silence to full level over `timing.edgeFadeMs` (5 ms until Max changes it),
/// and the same line back down at the end. A segment shorter than two fades gets fades of half its length each.
/// A fade of no length changes nothing.
///
/// It is applied to a copy of the sound when it is played or exported. The recording is never changed.
///
/// Whoever makes sound out of the clips uses this one function: the player now, rendering and export later.
/// The samples handed in may be the whole segment, or any stretch of it, with the place of the stretch said:
///
///     let fade = EdgeFade.samples(milliseconds: settings[.edgeFadeMs])
///     var sound = Array(recording[segment.inSample..<segment.outSample])
///     EdgeFade.apply(fade, to: &sound)                                    // the whole segment
///
///     var later = Array(recording[first..<last])                           // a stretch inside the segment
///     EdgeFade.apply(fade, to: &later, at: first - segment.inSample, ofSegmentWithLength: segment.lengthSamples)
///
/// Only the samples inside a fade are touched, so handing in a long stretch costs no more than a short one.
public enum EdgeFade {
    /// How many samples a fade of so many milliseconds lasts. Nothing for a length that is below zero or no
    /// number.
    public static func samples(milliseconds: Double) -> Int {
        let samples = (milliseconds * Lockstep.sampleRate / 1_000).rounded()
        guard samples.isFinite, samples > 0, samples < 1e9 else { return 0 }
        return Int(samples)
    }

    /// The length of the fade a segment really gets at each end: the length asked for, or half the segment when
    /// it is shorter than two fades.
    public static func length(_ fadeSamples: Int, inSegmentOf segmentLength: Int) -> Int {
        max(0, min(fadeSamples, segmentLength / 2))
    }

    /// The part of a stretch of a segment that no fade reaches, counted from the first sample of the stretch.
    /// What lies before it is in the fade at the segment's start, and what lies after it in the fade at its end.
    ///
    /// - Parameters:
    ///   - count: how many samples the stretch has.
    ///   - position: how many samples of the segment lie before the stretch.
    ///   - segmentLength: how many samples the whole segment has.
    public static func untouchedPart(
        _ fadeSamples: Int,
        ofStretch count: Int,
        at position: Int,
        ofSegmentWithLength segmentLength: Int
    ) -> Range<Int> {
        let fade = length(fadeSamples, inSegmentOf: segmentLength)
        let first = min(max(fade - position, 0), max(count, 0))
        let end = min(max(segmentLength - fade - position, first), max(count, first))
        return first..<end
    }

    /// Fades the ends of a segment in a row of samples, in place.
    ///
    /// - Parameters:
    ///   - fadeSamples: the length of each fade, from `samples(milliseconds:)`.
    ///   - samples: the segment's sound, or a stretch of it.
    ///   - position: how many samples of the segment lie before the first sample handed in. 0 when the row
    ///     starts where the segment starts.
    ///   - segmentLength: how many samples the whole segment has. Nil when the row is the whole segment.
    public static func apply<Samples>(
        _ fadeSamples: Int,
        to samples: inout Samples,
        at position: Int = 0,
        ofSegmentWithLength segmentLength: Int? = nil
    ) where Samples: MutableCollection & RandomAccessCollection, Samples.Element == Float {
        let count = samples.count
        let whole = segmentLength ?? (position + count)
        let fade = length(fadeSamples, inSegmentOf: whole)
        guard fade > 0, count > 0 else { return }
        let untouched = untouchedPart(fadeSamples, ofStretch: count, at: position, ofSegmentWithLength: whole)
        let step = 1 / Float(fade)
        // The line is read in the middle of each sample, so the way up and the way down mirror each other and no
        // sample is silenced altogether.
        var index = samples.startIndex
        for place in 0..<untouched.lowerBound {
            samples[index] *= (Float(position + place) + 0.5) * step
            samples.formIndex(after: &index)
        }
        index = samples.index(samples.startIndex, offsetBy: untouched.upperBound)
        for place in untouched.upperBound..<count {
            // Past the end of the segment there is nothing to fade toward, so the level stays at silence.
            samples[index] *= max((Float(whole - position - place) - 0.5) * step, 0)
            samples.formIndex(after: &index)
        }
    }
}

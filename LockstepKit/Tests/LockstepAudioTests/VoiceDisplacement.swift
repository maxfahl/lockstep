import Accelerate
import Foundation
import LockstepCore
@testable import LockstepAudio

/// How far the sound of one file lies from the sound of another at given places, measured from the sound
/// itself and not with the syllable finder. This is the measure behind the timing gate of phase 37 since
/// 16 November 2026 (`VoiceTimingMeasure`).
///
/// Why not the finder. The app never looks for syllables in a made voice: the markers found in the
/// recording are the voice's markers. So the question is whether the voice's sound is where the recording's
/// is, at those markers. The finder keeps the strongest rise within 70 ms, and a voice that was taken apart
/// and put together has its rises a little differently strong, so it loses markers without any sound
/// having moved.
///
/// How it is measured. Both sounds are cut into five bands (100 to 12,000 Hz), and the loudness of each
/// band is taken once a millisecond, in decibels, smoothed over 11 ms as `VoiceEnvelope` does. Around a
/// place the other sound's five curves are slid over the reference's, each curve with its own mean taken
/// away, and the slide at which they lie closest is the displacement. Five bands and the means taken away
/// are what keep a moved formant or a moved pitch from looking like a move in time: they change how loud a
/// band is, not when it rises.
///
/// It is done twice. First with 40 ms to each side, slid up to 30 ms either way: that finds which slide it
/// is. Then with 25 ms to each side, slid only up to 6 ms from the first answer: that says where, closely,
/// read to a fraction of a millisecond from the three closest slides. The long look alone blurs a move of a
/// short stretch (a stretch of 60 ms moved by 8 ms reads 6.8 ms in it); the short look alone is fooled by
/// a creaky voice, whose loudness dips once a pitch period, so that sliding one period on fits nearly as
/// well (WORLD smoothed one dip of Daniel's creak at 11.908 s of the fast line, and the short look alone
/// read 18.5 ms there, with nothing moved).
///
/// How sure it is. A displacement is confident when the curves lie within `Marks.fitDb` of each other at
/// the best slide of both looks, when in the long look no slide 8 ms or more away fits nearly as well
/// (`Marks.sharpness`), and when neither look's best slide is the furthest one it tried. A held vowel or a
/// silence has no shape to slide, and says so this way; so does a sound that is not the same speech at all
/// (an unrelated line of the same length has no confident place in a hundred).
enum VoiceDisplacement {
    /// The numbers of the measure, set on 16 November 2026 from made-up speech.
    enum Marks {
        /// The bands, in hertz.
        static let bands: [ClosedRange<Double>] = [100...400, 400...1_000, 1_000...2_500, 2_500...6_000, 6_000...12_000]
        /// How much of the curves is compared, to each side of a place, in milliseconds: in the long look and
        /// in the short one.
        static let longReachMs = 40
        static let reachMs = 25
        /// How far the curves are slid either way in the long look, and in the short look from the long
        /// look's answer, in milliseconds.
        static let furthestMs = 30
        static let nearMs = 6
        /// A band counts from this far above its quietest tenth in the reference, in decibels. Under it both
        /// curves are lifted to it, so what happens down in the room's hiss is not compared.
        static let aboveFloorDb: Float = 6
        /// Confident only when the curves lie this close at the best slide: the root of the mean square of
        /// what is left between them, in decibels. WORLD at Depth 15 lies within 5 dB at all but one place in
        /// a hundred and an unrelated line at 3 to 5 in a hundred, which the sharpness then rules out.
        static let fitDb = 5.0
        /// And when every slide 8 ms or more from the best lies at least this many times as far apart.
        static let sharpness = 1.3
        static let sharpnessFromMs = 8
    }

    /// The loudness of a sound in each band, one value a millisecond, in decibels.
    struct Curves {
        var bands: [[Float]]

        init(of samples: [Float]) {
            bands = Marks.bands.map { Curves.curve(of: samples, band: $0) }
        }

        /// One band: cut out by filtering forwards and backwards (so nothing is delayed), the mean power of
        /// every millisecond, smoothed over 11 ms, in decibels and never under -120.
        static func curve(of samples: [Float], band: ClosedRange<Double>) -> [Float] {
            let count = samples.count
            guard count > 0 else { return [] }
            func section(cutoff: Double, highPass: Bool) -> [Double] {
                let angle = 2 * Double.pi * cutoff / Lockstep.sampleRate
                let cosine = cos(angle), alpha = sin(angle) / 2.0.squareRoot()
                let scale = 1 + alpha
                let edge = (highPass ? 1 + cosine : 1 - cosine) / 2
                return [edge, highPass ? -2 * edge : 2 * edge, edge, -2 * cosine, 1 - alpha].map { $0 / scale }
            }
            let coefficients = section(cutoff: band.lowerBound, highPass: true)
                + section(cutoff: band.upperBound, highPass: false)
            guard let setup = vDSP_biquad_CreateSetup(coefficients, 2) else { return [] }
            defer { vDSP_biquad_DestroySetup(setup) }
            func filtered(_ input: [Float]) -> [Float] {
                var output = [Float](repeating: 0, count: count)
                var memory = [Float](repeating: 0, count: 2 * 2 + 2)
                vDSP_biquad(setup, &memory, input, 1, &output, 1, vDSP_Length(count))
                return output
            }
            let once = filtered(samples)
            let twice = Array(filtered(Array(once.reversed())).reversed())
            let hop = VoiceEnvelope.hopSamples
            let valueCount = (count + hop - 1) / hop
            var sums = [Double](repeating: 0, count: valueCount + 1)
            for index in 0..<valueCount {
                let first = index * hop
                var power: Float = 0
                twice.withUnsafeBufferPointer {
                    vDSP_measqv($0.baseAddress! + first, 1, &power, vDSP_Length(min(hop, count - first)))
                }
                sums[index + 1] = sums[index] + Double(power)
            }
            return (0..<valueCount).map { index in
                let from = max(index - 5, 0), to = min(index + 6, valueCount)
                return max(Float(10 * log10(max((sums[to] - sums[from]) / Double(to - from), 1e-30))), -120)
            }
        }

        /// The level each band counts from: its quietest tenth, never under -90, and a little above that.
        var floors: [Float] {
            bands.map { values in
                guard !values.isEmpty else { return -90 }
                return max(values.sorted()[values.count / 10], -90) + Marks.aboveFloorDb
            }
        }

        /// The curves with everything under `floors` lifted to them.
        func lifted(to floors: [Float]) -> Curves {
            var copy = self
            copy.bands = zip(bands, floors).map { values, floor in values.map { max($0, floor) } }
            return copy
        }
    }

    /// What was found at one place.
    struct Found: Codable, Equatable {
        /// Where the place is in the reference, in seconds.
        var seconds: Double
        /// What it is: "syllable", "pause start", "pause end", "line start" or "line end".
        var kind: String
        /// How far the other sound lies from the reference there, in milliseconds. Positive is later.
        var displacementMs: Double
        /// How close the curves lie at the best slide, in decibels: the worse of the two looks.
        var fitDb: Double
        /// How many times as far apart the best slide 8 ms or more away lies.
        var sharpness: Double
        var confident: Bool

        /// Whether the place is where a sound ends (a pause starts, a line ends) and not where one starts. A
        /// made voice may let a sound ring on a little longer than the recording does, and an end is held
        /// to its own furthest distance (`Pass.furthestEndMs`).
        var isEnd: Bool { kind == "pause start" || kind == "line end" }
    }

    /// How far apart the curves lie around `middle` (in milliseconds of the curves) at each slide of
    /// `slides`, with `reach` milliseconds to each side. The window is cut where the sound ends, and a slide
    /// that would take the other sound's window past an end is left out. Nil when less than `reach` is left.
    static func apart(
        at middle: Int, reach: Int, slides: ClosedRange<Int>, reference: Curves, other: Curves
    ) -> [Int: Double]? {
        let count = reference.bands.first?.count ?? 0
        let first = max(middle - reach, 0), last = min(middle + reach, count - 1)
        guard last - first >= reach else { return nil }
        func withoutMean(_ values: ArraySlice<Float>) -> [Double] {
            let mean = values.reduce(0) { $0 + Double($1) } / Double(values.count)
            return values.map { Double($0) - mean }
        }
        let wanted = reference.bands.map { withoutMean($0[first...last]) }
        let width = Double((last - first + 1) * wanted.count)
        var apart: [Int: Double] = [:]
        for slide in slides {
            guard first + slide >= 0, last + slide < count else { continue }
            var sum = 0.0
            for (band, values) in other.bands.enumerated() {
                let had = withoutMean(values[(first + slide)...(last + slide)])
                for index in had.indices { sum += (had[index] - wanted[band][index]) * (had[index] - wanted[band][index]) }
            }
            apart[slide] = (sum / width).squareRoot()
        }
        return apart
    }

    /// The best slide of a look: the closest, and of two as close the one nearer to `towards`. Whether it is
    /// the furthest slide tried on either side.
    static func best(of apart: [Int: Double], towards: Int) -> (slide: Int, value: Double, atTheEdge: Bool)? {
        guard let best = apart.min(by: { ($0.value, abs($0.key - towards)) < ($1.value, abs($1.key - towards)) }) else { return nil }
        return (best.key, best.value, apart[best.key - 1] == nil || apart[best.key + 1] == nil)
    }

    /// Whether a place lies far enough from both ends of a sound of `count` milliseconds for the long look
    /// to slide its whole window the whole way either side. One nearer is not measured: its best slide could
    /// be the furthest one allowed only because the sound ends there.
    static func measurable(_ sample: Int, count: Int) -> Bool {
        let middle = sample / VoiceEnvelope.hopSamples, room = Marks.longReachMs + Marks.furthestMs
        return middle - room >= 0 && middle + room < count
    }

    /// The displacement of `other` against `reference` at each place. Both curves must be lifted to the
    /// reference's floors already. A place that is not `measurable` is left out.
    static func measure(_ places: [(sample: Int, kind: String)], reference: Curves, other: Curves) -> [Found] {
        let count = reference.bands.first?.count ?? 0
        return places.compactMap { place in
            guard measurable(place.sample, count: count) else { return nil }
            let middle = place.sample / VoiceEnvelope.hopSamples
            // The long look: which slide it is.
            guard let long = apart(
                at: middle, reach: Marks.longReachMs, slides: -Marks.furthestMs...Marks.furthestMs,
                reference: reference, other: other
            ), let coarse = best(of: long, towards: 0) else { return nil }
            let elsewhere = long.filter { abs($0.key - coarse.slide) >= Marks.sharpnessFromMs }.map(\.value).min()
            let sharpness = elsewhere.map { coarse.value > 0 ? $0 / coarse.value : ($0 > 0 ? 999 : 1) } ?? 1
            // The short look: where, closely.
            guard let short = apart(
                at: middle, reach: Marks.reachMs, slides: (coarse.slide - Marks.nearMs)...(coarse.slide + Marks.nearMs),
                reference: reference, other: other
            ), let fine = best(of: short, towards: coarse.slide) else { return nil }
            var displacement = Double(fine.slide)
            if let before = short[fine.slide - 1], let after = short[fine.slide + 1] {
                // The lowest point of the curve through the three closest slides, in squares.
                let a = before * before, b = fine.value * fine.value, c = after * after
                let bend = a - 2 * b + c
                if bend > 0 { displacement += min(max(0.5 * (a - c) / bend, -0.5), 0.5) }
            }
            return Found(
                seconds: (Double(place.sample) / Lockstep.sampleRate * 1_000).rounded() / 1_000,
                kind: place.kind,
                displacementMs: (displacement * 100).rounded() / 100,
                fitDb: (max(coarse.value, fine.value) * 100).rounded() / 100,
                sharpness: (min(sharpness, 999) * 100).rounded() / 100,
                confident: coarse.value <= Marks.fitDb && fine.value <= Marks.fitDb && sharpness >= Marks.sharpness
                    && !coarse.atTheEdge && !fine.atTheEdge
            )
        }
    }

    /// The numbers of a set of places, and whether they pass.
    struct Summary: Codable, Equatable {
        var places: Int
        var confident: Int
        /// The share of the places that are not confident, in percent.
        var unconfidentPercent: Double
        /// How many unconfident places lie beyond the share `Pass.unconfidentPercent` allows. They are
        /// counted as places out of place.
        var unconfidentBeyondAllowed: Int
        /// The share of the counted places where a sound starts (the confident ones, and the unconfident
        /// ones beyond the allowance) that are confident and within `Pass.withinMs`, in percent. Nil when
        /// nothing is counted.
        var withinPercent: Double?
        /// The same share of the confident places where a sound ends, for the reader: an end is held only to
        /// `Pass.furthestEndMs`.
        var endsWithinPercent: Double?
        /// Of the confident ones: the middle, the 95th in a hundred and the furthest distance, in
        /// milliseconds, and the furthest of the places where a sound starts and of those where one ends.
        /// Nil when none is confident (or none of that sort).
        var middleMs: Double?
        var ninetyFifthMs: Double?
        var furthestMs: Double?
        var furthestStartMs: Double?
        var furthestEndMs: Double?
        /// The middle with its direction: positive when the other sound is late as a whole.
        var middleSignedMs: Double?
        var passed: Bool
    }

    /// The pass marks of the timing gate, set by the coordinator for Max on 16 November 2026 from this
    /// tool's calibration: WORLD at no change (taken apart and put together, with nothing moved on purpose)
    /// against the recording, on the eight made-up lines of `Scripts/voice-test/make-speech.sh` (the fast,
    /// the long, the short and the gap line of both voices), at the recording's places and on the corrected
    /// line. They are written in
    /// the design document too, with the numbers behind them, and are not to be moved by whoever measures.
    enum Pass {
        /// A confident place is in place when it is displaced by no more than this, in milliseconds. WORLD at
        /// no change has 93.3 to 100 % of the places where a sound starts within 5 ms, and 97.1 to 100 %
        /// within 6.
        static let withinMs = 6.0
        /// At least this share of the counted places where a sound starts must be in place, in percent. A
        /// sound's start is what is heard on the beat. Where a sound ends, WORLD at no change is a few
        /// milliseconds late as often as not (it lets a tail ring on), which moves nothing that is heard as
        /// timing, so an end is held only to `furthestEndMs`.
        static let withinPercent = 95.0
        /// No confident place where a sound starts (a syllable, a pause's end, a line's start) may be
        /// displaced by more than this, in milliseconds. WORLD at no change: 8.2 at the furthest.
        static let furthestStartMs = 10.0
        /// No confident place where a sound ends (a pause's start, a line's end) may be displaced by more
        /// than this, in milliseconds. WORLD at no change lets the s at the end of a phrase ring 14.6 ms longer.
        static let furthestEndMs = 20.0
        /// No more than this share of the places may be unconfident, in percent, rounded up to whole places.
        /// WORLD at no change: 0 to 6.6 % on the lines of 13 seconds and more, one place of seven on the line
        /// of half a second. Beyond it, the unconfident places count as places out of place.
        static let unconfidentPercent = 10.0
    }

    static func summary(of found: [Found]) -> Summary {
        func rounded(_ value: Double?) -> Double? { value.map { ($0 * 100).rounded() / 100 } }
        let sure = found.filter(\.confident)
        let distances = sure.map { abs($0.displacementMs) }.sorted()
        let unconfidentCount = found.count - sure.count
        // Rounded up, so that a short line of a handful of places may have one.
        let allowed = Int((Double(found.count) * Pass.unconfidentPercent / 100).rounded(.up))
        let beyond = max(unconfidentCount - allowed, 0)
        let unconfident = found.isEmpty ? 0 : Double(unconfidentCount) / Double(found.count) * 100
        let startDistances = sure.filter { !$0.isEnd }.map { abs($0.displacementMs) }
        let endDistances = sure.filter(\.isEnd).map { abs($0.displacementMs) }
        let counted = startDistances.count + beyond
        let within = counted == 0 ? nil : Double(startDistances.filter { $0 <= Pass.withinMs }.count) / Double(counted) * 100
        let endsWithin = endDistances.isEmpty ? nil : Double(endDistances.filter { $0 <= Pass.withinMs }.count) / Double(endDistances.count) * 100
        let starts = startDistances.max(), ends = endDistances.max()
        let signed = sure.map(\.displacementMs).sorted()
        // No place at all is nothing that could have moved. Places of which none is confident are not.
        let passed = found.isEmpty || (
            !sure.isEmpty && (within ?? 100) >= Pass.withinPercent
                && (starts ?? 0) <= Pass.furthestStartMs && (ends ?? 0) <= Pass.furthestEndMs
        )
        return Summary(
            places: found.count,
            confident: sure.count,
            unconfidentPercent: rounded(unconfident) ?? 0,
            unconfidentBeyondAllowed: beyond,
            withinPercent: rounded(within),
            endsWithinPercent: rounded(endsWithin),
            middleMs: rounded(distances.isEmpty ? nil : distances[distances.count / 2]),
            ninetyFifthMs: rounded(distances.isEmpty ? nil : distances[min(distances.count - 1, Int((Double(distances.count) * 0.95).rounded(.up)) - 1)]),
            furthestMs: rounded(distances.last),
            furthestStartMs: rounded(starts),
            furthestEndMs: rounded(ends),
            middleSignedMs: rounded(signed.isEmpty ? nil : signed[signed.count / 2]),
            passed: passed
        )
    }

    /// One line of words for a summary. With `verdict` false it leaves out "passed" or "FAILED", for the
    /// parts of a set whose verdict is given once.
    static func words(_ name: String, _ summary: Summary, verdict: Bool = true) -> String {
        let end = verdict ? (summary.passed ? ": passed" : ": FAILED") : ""
        guard summary.places > 0 else { return "\(name): no places" + end }
        guard let middle = summary.middleMs, let ninetyFifth = summary.ninetyFifthMs else {
            return "\(name): \(summary.places) places, none of them confident" + end
        }
        let leaning = summary.middleSignedMs.flatMap { signed -> String? in
            abs(signed) >= 1 ? String(format: " (%.1f ms ", abs(signed)) + (signed > 0 ? "late" : "early") + " as a whole)" : nil
        } ?? ""
        let beyond = summary.unconfidentBeyondAllowed > 0
            ? ", \(summary.unconfidentBeyondAllowed) unconfident beyond the \(Int(Pass.unconfidentPercent)) % allowed counted as out of place"
            : ""
        let furthest = [
            summary.furthestStartMs.map { String(format: "where a sound starts %.1f ms", $0) },
            summary.furthestEndMs.map { String(format: "where one ends %.1f ms", $0) },
        ].compactMap { $0 }.joined(separator: ", ")
        return "\(name): \(summary.places) places, \(summary.confident) confident "
            + String(format: "(%.1f %% not)", summary.unconfidentPercent) + beyond
            + (summary.withinPercent.map { String(format: ", where a sound starts %.1f %% within %.0f ms", $0, Pass.withinMs) } ?? "")
            + (summary.endsWithinPercent.map { String(format: ", where one ends %.1f %%", $0) } ?? "")
            + String(format: ", middle %.1f ms", middle)
            + leaning + String(format: ", 95 in 100 within %.1f ms, furthest ", ninetyFifth) + furthest + end
    }
}

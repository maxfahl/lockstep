import Foundation

// Choosing a stretch of a clip for an effect. Max drags roughly over a word in the clip, and the stretch
// catches on the word: each of its ends moves onto the nearest start of a syllable or edge of a pause within
// 60 ms.
//
//     let pauses = ClipSpan.pauses(in: clip, markers: markersByRecording, levels: levelsByRecording)
//     guard let span = ClipSpan.catching(
//         marked, in: clip, of: project, markers: markersByRecording, pauses: pauses,
//         heardShift: { segment, sample in /* how far the correction moved that sample, in samples */ 0 }
//     ) else { return }                       // less than 20 ms of the clip is in the stretch
//     store.edit("Add Double") { $0.addEffect(clip.id, kind: .lowOctave, span: span) }

extension ClipSpan {
    /// How far an end of a marked stretch may lie from a syllable's start or a pause's edge and still be
    /// moved onto it: 60 ms, in samples.
    public static let catchReachSamples = 2_880

    /// The least of a span that must be played for its effect to stay: 20 ms, in samples.
    public static let leastSamples = 960

    /// How many samples of its recording the span covers.
    public var lengthSamples: Int {
        max(0, outSample - inSample)
    }

    /// The span of a clip that a marked stretch of the song stands for.
    ///
    /// - The stretch is held against one segment of the clip: the one that holds most of it. So a stretch
    ///   dragged over two parts of a joined clip is cut to the part it mostly lies on.
    /// - Each end moves onto the nearest catch point within 60 ms: the start of a syllable, either edge of a
    ///   pause, or an edge of the segment. An end with nothing in reach stays where it was dragged.
    /// - The span is kept inside what the segment plays.
    /// - Everything is measured where it is heard. On a clip whose timing is corrected a syllable is heard
    ///   earlier or later than it was recorded (`heardShift`), and the stretch was marked where it is heard.
    ///
    /// - Parameters:
    ///   - stretch: the marked stretch, in song seconds.
    ///   - clip: the clip it was marked on.
    ///   - project: the project, for where the clip's recordings lie in the song.
    ///   - markers: the syllable markers of every recording, by recording id, each list in the order of its
    ///     recording.
    ///   - pauses: the pauses of every recording, by recording id, as samples of the recording
    ///     (`pauses(in:markers:levels:)`).
    ///   - heardShift: how many samples later than recorded a sample of the clip's segment at `segment` is
    ///     heard. Negative is earlier. Left out, everything is heard as recorded.
    /// - Returns: the span, or nil when less than 20 ms of the clip is left in it.
    public static func catching(
        _ stretch: Range<Double>,
        in clip: Clip,
        of project: Project,
        markers: [UUID: [SyllableMarker]],
        pauses: [UUID: [Range<Int>]] = [:],
        heardShift: (_ segment: Int, _ sample: Int) -> Int = { _, _ in 0 }
    ) -> ClipSpan? {
        let lower = (stretch.lowerBound * Lockstep.sampleRate).rounded()
        let upper = (stretch.upperBound * Lockstep.sampleRate).rounded()
        guard lower.isFinite, upper.isFinite, abs(lower) < 1e15, abs(upper) < 1e15, upper > lower else { return nil }
        let from = Int(lower)
        let to = Int(upper)

        /// The sample of the song on which a sample of a segment is heard. The sample one past the segment's
        /// end is asked about as the one after its last.
        func heard(_ sample: Int, _ index: Int, _ segment: Segment, _ origin: Int) -> Int {
            origin + sample + heardShift(index, min(sample, segment.outSample - 1))
        }

        var best: (index: Int, origin: Int, overlap: Int)?
        for (index, segment) in clip.segments.enumerated() where segment.outSample > segment.inSample {
            guard let recording = project.recording(segment.recordingID) else { continue }
            let origin = recording.songSample(ofSample: 0, offsetSamples: segment.offsetSamples)
            let overlap = min(heard(segment.outSample, index, segment, origin), to)
                - max(heard(segment.inSample, index, segment, origin), from)
            if overlap > best?.overlap ?? 0 {
                best = (index, origin, overlap)
            }
        }
        guard let best else { return nil }
        let segment = clip.segments[best.index]

        var points = [segment.inSample, segment.outSample]
        points += (markers[segment.recordingID] ?? []).map(\.sample)
        points += (pauses[segment.recordingID] ?? []).flatMap { [$0.lowerBound, $0.upperBound] }
        points.removeAll { $0 < segment.inSample || $0 > segment.outSample }

        /// The sample of the recording an end of the stretch stands for.
        func end(at place: Int) -> Int {
            var caught: (sample: Int, distance: Int)?
            for point in points {
                let distance = abs(heard(point, best.index, segment, best.origin) - place)
                if distance <= catchReachSamples, distance < caught?.distance ?? Int.max {
                    caught = (point, distance)
                }
            }
            if let caught { return caught.sample }
            // Nothing in reach: the first sample that is heard at or after the place. A later sample is
            // never heard earlier, so halving the segment finds it.
            var low = segment.inSample
            var high = segment.outSample
            while low < high {
                let middle = low + (high - low) / 2
                if heard(middle, best.index, segment, best.origin) < place {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }

        let span = ClipSpan(recordingID: segment.recordingID, inSample: end(at: from), outSample: end(at: to))
        return span.lengthSamples >= leastSamples ? span : nil
    }

    /// The pauses of a clip that a marked stretch can catch on: for each of its segments, the longest pause
    /// between every two neighbouring syllables, and before the first and after the last. They are the
    /// pauses the correction counts with (`SyllablePauses`), by recording id, as samples of the recording.
    ///
    /// - Parameters:
    ///   - markers: the syllable markers of every recording, by recording id, each list in the order of its
    ///     recording.
    ///   - levels: how loud each recording is, by recording id. A recording that has none gives no pauses.
    public static func pauses(
        in clip: Clip,
        markers: [UUID: [SyllableMarker]],
        levels: [UUID: VoiceLevels]
    ) -> [UUID: [Range<Int>]] {
        var found: [UUID: [Range<Int>]] = [:]
        for segment in clip.segments where segment.outSample > segment.inSample {
            guard let levels = levels[segment.recordingID] else { continue }
            let inside = (markers[segment.recordingID] ?? []).map(\.sample)
                .filter { $0 > segment.inSample && $0 < segment.outSample }
            let points = [segment.inSample] + inside + [segment.outSample]
            let pauses = SyllablePauses.between(points, levels: levels).compactMap { $0 }
            if !pauses.isEmpty {
                found[segment.recordingID, default: []] += pauses
            }
        }
        return found
    }
}

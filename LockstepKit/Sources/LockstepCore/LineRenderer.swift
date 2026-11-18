/// Builds the tightened sound of one segment of a clip: the same sound with every line slid to its new
/// place. Sliding a line stretches nothing. The pauses between lines get a little longer or shorter instead.
///
/// A line whose single syllables move as well is first built by itself (`quantized`, which may stretch sound
/// where syllables run together) and handed in with `quantized:`. It is then slid like any other line.
///
///     let lines = LineFinder.lines(in: segment.inSample..<segment.outSample, levels: levels, markers: markers)
///     let maps = lines.map { TimeMap(line: $0, shiftSeconds: shift(of: $0)) }
///     let tightened = LineRenderer.render(segment: segment, recording: samples, lines: lines, maps: maps)
///
/// The answer has exactly as many samples as the segment plays, and its first sample is the segment's first
/// sample, so it is played in place of the original with nothing else changed: the same place in the song,
/// the same volume, the same fades at the segment's edges.
///
/// Unless a line has to slide out of the segment to reach its sub-beat. Then the answer is asked for with a
/// `lead` or a `tail`: that many more samples before the segment's first sample or after its last, for the
/// line to lie in. Whoever plays it starts it that much earlier and plays it that much longer.
///
/// How a line is moved:
/// - The line is lifted out and laid down again at its new place, with the 10 ms on either side of it fading
///   in and out, so the line itself stays at full level from its first sample to its last.
/// - Where a pause gets longer, the gap that opens is filled with the room sound of that same pause, played
///   backwards from the edge of the gap, so there is no hole of dead silence and no jump where the fill starts.
/// - Where a pause gets shorter, the moved line covers part of it.
/// - A line never leaves the answer: it moves as far as there is room and no further. Without a lead or a
///   tail that is the segment.
///
/// The recording's samples are only read. The answer is a new row of samples.
public enum LineRenderer {
    /// How long every crossfade between a moved line and the pause around it is, in milliseconds.
    public static let crossfadeMs: Double = 10

    /// The tightened sound of one segment.
    ///
    /// - Parameters:
    ///   - segment: the stretch of the recording to build, `inSample` to `outSample`.
    ///   - recording: the recording's samples: mono, 48,000 Hz, sample 0 first.
    ///   - lines: the lines of this segment, from `LineFinder`, in samples of the recording.
    ///   - maps: where each line goes, one map for every line in the same order. A line moves by its map's
    ///     `shiftSamples`.
    ///   - quantized: the sound of each line with its syllables moved inside it, from `quantized`, in the
    ///     order of `lines`. Nil, or left out, for a line that is used as it was recorded. A sound that is
    ///     not exactly as long as its line, or whose line does not lie whole inside the segment, is not used.
    ///   - fadeMs: the length of every crossfade, in milliseconds.
    ///   - lead: how many samples the answer has before the segment's first one, for a line that slides
    ///     out of the segment at its start. They are silent until a line is laid there: what the recording
    ///     holds before the segment is not the clip's, and is never brought in.
    ///   - tail: how many samples the answer has after the segment's last one, in the same way.
    /// - Returns: `lead + segment.lengthSamples + tail` samples. With every shift at 0 and no line handed in
    ///   with `quantized`, the segment's part of them is the original samples exactly.
    public static func render(
        segment: Segment,
        recording: [Float],
        lines: [VoiceLine],
        maps: [TimeMap],
        quantized: [[Float]?] = [],
        fadeMs: Double = crossfadeMs,
        lead: Int = 0,
        tail: Int = 0
    ) -> [Float] {
        precondition(lines.count == maps.count, "Every line needs its map.")
        guard segment.lengthSamples > 0 else { return [] }
        let lead = max(lead, 0)
        // Everything below counts positions in the answer: position `lead` is the segment's first sample.
        let segmentEnd = lead + segment.lengthSamples
        let count = segmentEnd + max(tail, 0)

        // 1. The original sound of the segment, with silence where the lead and the tail are.
        var original = [Float](repeating: 0, count: count)
        let firstKnown = max(segment.inSample, 0)
        let known = firstKnown..<max(min(segment.outSample, recording.count), firstKnown)
        if !known.isEmpty {
            original.replaceSubrange(
                known.lowerBound - segment.inSample + lead..<known.upperBound - segment.inSample + lead,
                with: recording[known]
            )
        }

        // The lines inside the segment, in order, each with the shift it really gets.
        var moves: [Move] = []
        for index in lines.indices.sorted(by: { lines[$0].startSample < lines[$1].startSample }) {
            let line = lines[index]
            let start = max(line.startSample - segment.inSample + lead, moves.last?.end ?? lead)
            let end = min(line.endSample - segment.inSample + lead, segmentEnd)
            guard end > start else { continue }
            moves.append(Move(start: start, end: end, shift: min(max(maps[index].shiftSamples, -start), count - end)))
            // A line with its syllables moved takes the place of the recorded line before anything slides.
            // It is as long as the line and begins and ends with the line's own samples, so from here on
            // it is slid exactly as the recorded line would be.
            if quantized.indices.contains(index), let moved = quantized[index], moved.count == line.lengthSamples,
               start == line.startSample - segment.inSample + lead, end == line.endSample - segment.inSample + lead {
                original.replaceSubrange(start..<end, with: moved)
            }
        }
        guard moves.contains(where: { $0.shift != 0 }) else { return original }

        let fade = EdgeFade.samples(milliseconds: fadeMs)
        for (earlier, later) in zip(moves, moves.dropFirst()) {
            // The limit on how far a line may slide leaves room for both lines' crossfades between them.
            assert(
                later.start + later.shift - (earlier.end + earlier.shift) >= min(later.start - earlier.end, 2 * fade),
                "Two lines were shifted into each other."
            )
        }

        var result = original
        // 2. Room sound where the moved lines were: the pause before a line played backwards into the line's
        // old place from its start, and the pause after it from its end. A pause ends where the segment
        // does: the lead and the tail hold no room sound.
        for (index, move) in moves.enumerated() where move.shift != 0 {
            let pauseBefore = (index > 0 ? moves[index - 1].end : lead)..<move.start
            let pauseAfter = move.end..<(index + 1 < moves.count ? moves[index + 1].start : segmentEnd)
            let left = min(fade + max(move.shift, 0), move.end - move.start)
            let right = min(fade + max(-move.shift, 0), move.end - move.start - left)
            for step in 0..<left {
                result[move.start + step] = mirrored(original, pause: pauseBefore, fromItsEnd: true, step: step, fade: fade)
            }
            for step in 0..<right {
                result[move.end - 1 - step] = mirrored(original, pause: pauseAfter, fromItsEnd: false, step: step, fade: fade)
            }
        }

        // 3. Every moved line at its new place. It takes up to 10 ms of the pause on either side with it,
        // and over those it fades in and out, on top of what is there.
        for (index, move) in moves.enumerated() where move.shift != 0 {
            let from = max(move.start - fade, index > 0 ? moves[index - 1].end : lead)
            let to = min(move.end + fade, index + 1 < moves.count ? moves[index + 1].start : segmentEnd)
            let fadeInEnd = min(from + fade, to)
            let fadeOutStart = max(to - fade, fadeInEnd)
            for fading in [from..<fadeInEnd, fadeOutStart..<to] {
                for source in fading {
                    let target = source + move.shift
                    guard target >= 0, target < count else { continue }
                    // The level is read in the middle of each sample, as the fades at clip edges are.
                    let rising = (Float(source - from) + 0.5) / Float(fade)
                    let falling = (Float(to - source) - 0.5) / Float(fade)
                    let weight = min(rising, falling, 1)
                    result[target] = weight * original[source] + (1 - weight) * result[target]
                }
            }
            let full = max(fadeInEnd + move.shift, 0)..<min(fadeOutStart + move.shift, count)
            if !full.isEmpty {
                result.replaceSubrange(full, with: original[full.lowerBound - move.shift..<full.upperBound - move.shift])
            }
        }
        return result
    }

    /// How far a line really moves in a segment when it is asked to move by `shiftSamples`: as far as asked,
    /// but never further past the segment's first or last sample than there is room. With no room, a line
    /// that touches an edge cannot move toward it.
    ///
    /// `render` applies this by itself, with its lead and its tail as the room. It is here so that markers
    /// and waveforms can be drawn where the sound really is.
    ///
    /// - Parameter room: how far the sound may reach past the segment's edges (`Project.room(around:atMost:)`).
    ///   Left out, the line stays inside the segment.
    public static func allowedShift(
        _ shiftSamples: Int,
        of line: VoiceLine,
        in segment: Segment,
        room: ClipTightening.Room = .none
    ) -> Int {
        let start = max(line.startSample, segment.inSample)
        let end = min(line.endSample, segment.outSample)
        guard end > start else { return 0 }
        return min(
            max(shiftSamples, segment.inSample - max(room.before, 0) - start),
            segment.outSample + max(room.after, 0) - end
        )
    }

    /// A line inside the segment, counted from the segment's first sample, and how far it moves.
    private struct Move {
        var start: Int
        var end: Int
        var shift: Int
    }

    /// The room sound of a pause, read from one of its ends inward: step 0 is the sample at that end, step 1
    /// the one next to it, and so on. At the far end of the pause the reading turns around and comes back, as
    /// often as needed, so there is never a jump from one sample to an unrelated one.
    ///
    /// A pause shorter than a crossfade has too little room sound to repeat without it turning into a tone,
    /// so it gives silence. That happens only next to an edge of the segment.
    private static func mirrored(_ original: [Float], pause: Range<Int>, fromItsEnd: Bool, step: Int, fade: Int) -> Float {
        let length = pause.count
        guard length >= max(fade, 1) else { return 0 }
        let turn = step % (2 * length)
        let inward = turn < length ? turn : 2 * length - 1 - turn
        return original[fromItsEnd ? pause.upperBound - 1 - inward : pause.lowerBound + inward]
    }
}

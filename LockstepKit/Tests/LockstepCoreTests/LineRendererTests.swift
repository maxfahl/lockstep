import Foundation
import Testing
@testable import LockstepCore

@Suite("LineRenderer")
struct LineRendererTests {
    /// One millisecond, in samples.
    private let ms = 48
    /// The length of a crossfade: 10 ms.
    private let fade = 480

    /// A made-up recording: quiet room sound everywhere, never exactly silent, and a loud tone in each burst.
    /// The bursts are given in milliseconds. No two samples of the room sound are alike, so a sample that
    /// turns up somewhere else can be told apart.
    private func recording(lengthMs: Int, bursts: [Range<Int>]) -> [Float] {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var samples = (0..<lengthMs * ms).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(state >> 40) / Float(1 << 24) - 0.5
            return noise == 0 ? 0.0005 : noise * 0.002
        }
        for burst in bursts {
            for index in burst.lowerBound * ms..<burst.upperBound * ms {
                samples[index] += 0.5 * sin(Float(index) * 2 * .pi * 220 / 48_000)
            }
        }
        return samples
    }

    /// The lines of a recording with these bursts, found as the app finds them.
    private func lines(lengthMs: Int, bursts: [Range<Int>], in range: Range<Int>? = nil, pauseMs: Double = 250) -> [VoiceLine] {
        var values = [Float](repeating: -70, count: lengthMs)
        for burst in bursts {
            for index in burst { values[index] = -20 }
        }
        return LineFinder.lines(
            in: range ?? 0..<lengthMs * ms,
            levels: VoiceLevels(values: values, threshold: -58, hopSamples: ms),
            markers: [],
            pauseMs: pauseMs
        )
    }

    private func whole(_ samples: [Float]) -> Segment {
        Segment(recordingID: UUID(), inSample: 0, outSample: samples.count)
    }

    /// Whether every sample of the line is in the result, moved by `shift` samples and otherwise untouched.
    private func isIntact(_ line: VoiceLine, movedBy shift: Int, in result: [Float], of original: [Float]) -> Bool {
        (line.startSample..<line.endSample).allSatisfy { result[$0 + shift] == original[$0] }
    }

    @Test func aLineShiftedByFourHundredEightySamplesHasEverySampleThatMuchLater() throws {
        let bursts = [500..<1000]
        let samples = recording(lengthMs: 2000, bursts: bursts)
        let line = try #require(lines(lengthMs: 2000, bursts: bursts).first)
        let later = LineRenderer.render(
            segment: whole(samples), recording: samples, lines: [line], maps: [TimeMap(line: line, shiftSamples: 480)]
        )
        #expect(isIntact(line, movedBy: 480, in: later, of: samples))
        // Outside the line and its crossfades the sound before it is as it was.
        #expect(later[0..<line.startSample - fade] == samples[0..<line.startSample - fade])
        #expect(later[(line.endSample + 480 + fade)...] == samples[(line.endSample + 480 + fade)...])

        let earlier = LineRenderer.render(
            segment: whole(samples), recording: samples, lines: [line], maps: [TimeMap(line: line, shiftSamples: -480)]
        )
        #expect(isIntact(line, movedBy: -480, in: earlier, of: samples))
    }

    @Test func allShiftsZeroRendersTheOriginal() {
        let bursts = [200..<700, 1100..<1600]
        let samples = recording(lengthMs: 2000, bursts: bursts)
        let found = lines(lengthMs: 2000, bursts: bursts)
        #expect(found.count == 2)
        let result = LineRenderer.render(
            segment: whole(samples), recording: samples, lines: found,
            maps: found.map { TimeMap(line: $0, shiftSamples: 0) }
        )
        #expect(result == samples)
        // One line moving leaves the other exactly as it was.
        let oneMoved = LineRenderer.render(
            segment: whole(samples), recording: samples, lines: found,
            maps: [TimeMap(line: found[0], shiftSamples: 0), TimeMap(line: found[1], shiftSeconds: 0.040)]
        )
        #expect(isIntact(found[0], movedBy: 0, in: oneMoved, of: samples))
        #expect(isIntact(found[1], movedBy: 1920, in: oneMoved, of: samples))
    }

    @Test func theResultHasExactlyTheSegmentsLength() {
        // A segment that plays a part of the recording, with lines given in samples of the recording.
        let bursts = [300..<700, 1100..<1500]
        let samples = recording(lengthMs: 2000, bursts: bursts)
        let segment = Segment(recordingID: UUID(), inSample: 100 * ms + 7, outSample: 1800 * ms - 5)
        let found = lines(lengthMs: 2000, bursts: bursts, in: segment.inSample..<segment.outSample)
        let maps = [TimeMap(line: found[0], shiftSamples: 1000), TimeMap(line: found[1], shiftSamples: -2000)]
        let result = LineRenderer.render(segment: segment, recording: samples, lines: found, maps: maps)
        #expect(result.count == segment.lengthSamples)
        // Sample 0 of the result is the segment's first sample, so each line is found that far in.
        #expect((found[0].startSample..<found[0].endSample).allSatisfy {
            result[$0 - segment.inSample + 1000] == samples[$0]
        })
        #expect((found[1].startSample..<found[1].endSample).allSatisfy {
            result[$0 - segment.inSample - 2000] == samples[$0]
        })
        // A segment of no length gives nothing, and one with no lines gives its own samples.
        #expect(LineRenderer.render(
            segment: Segment(recordingID: UUID(), inSample: 500, outSample: 500), recording: samples, lines: [], maps: []
        ).isEmpty)
        #expect(LineRenderer.render(segment: segment, recording: samples, lines: [], maps: [])
            == Array(samples[segment.inSample..<segment.outSample]))
    }

    @Test func theWidenedPauseContainsNoRunOfExactZeros() {
        // The two lines move apart by 80 ms each, so the pause between them gets 160 ms longer.
        let bursts = [300..<700, 1100..<1500]
        let samples = recording(lengthMs: 2000, bursts: bursts)
        let found = lines(lengthMs: 2000, bursts: bursts)
        let shift = 80 * ms
        let result = LineRenderer.render(
            segment: whole(samples), recording: samples, lines: found,
            maps: [TimeMap(line: found[0], shiftSamples: -shift), TimeMap(line: found[1], shiftSamples: shift)]
        )
        let pause = found[0].endSample - shift..<found[1].startSample + shift
        #expect(pause.count == found[1].startSample - found[0].endSample + 2 * shift)
        #expect(!zip(result[pause], result[pause].dropFirst()).contains { $0 == 0 && $1 == 0 })
        #expect(!result[pause].contains(0))
        // What fills the gap is the room sound of the same pause, and it stays as quiet as a pause.
        #expect(result[pause].allSatisfy { abs($0) <= 0.002 })
        // Where the first line was, the pause after it is played backwards from the edge of the gap, so the
        // fill joins the pause without a jump. The same goes for the pause before the second line.
        for step in 0..<shift - fade {
            #expect(result[found[0].endSample - 1 - step] == samples[found[0].endSample + step])
            #expect(result[found[1].startSample + step] == samples[found[1].startSample - 1 - step])
        }
    }

    @Test func twoLinesShiftedTowardEachOtherByTheMostDoNotOverlap() {
        // The sounds are exactly one pause apart, and the lines move toward each other by the most the
        // settings allow for that pause: (pause - 60) / 2. At 150 ms that leaves exactly the two crossfades.
        for (pauseMs, maxShiftMs) in [(250, 80), (250, 95), (150, 45), (600, 120)] {
            let bursts = [300..<700, 700 + pauseMs..<1700]
            let samples = recording(lengthMs: 2000, bursts: bursts)
            let found = lines(lengthMs: 2000, bursts: bursts, pauseMs: Double(pauseMs))
            #expect(found.count == 2)
            let shift = maxShiftMs * ms
            let result = LineRenderer.render(
                segment: whole(samples), recording: samples, lines: found,
                maps: [TimeMap(line: found[0], shiftSamples: shift), TimeMap(line: found[1], shiftSamples: -shift)]
            )
            // Both lines are whole at their new places, so neither covers a sample of the other.
            #expect(isIntact(found[0], movedBy: shift, in: result, of: samples))
            #expect(isIntact(found[1], movedBy: -shift, in: result, of: samples))
            #expect(found[0].endSample + shift + 2 * fade <= found[1].startSample - shift)
            #expect(result.count == samples.count)
        }
    }

    @Test func aLineDoesNotMovePastTheSegmentsEdges() throws {
        // The segment starts 5 ms before the line and ends 20 ms after it.
        let bursts = [500..<1000]
        let samples = recording(lengthMs: 2000, bursts: bursts)
        let line = try #require(lines(lengthMs: 2000, bursts: bursts).first)
        let segment = Segment(recordingID: UUID(), inSample: line.startSample - 5 * ms, outSample: line.endSample + 20 * ms)
        #expect(LineRenderer.allowedShift(-20 * ms, of: line, in: segment) == -5 * ms)
        #expect(LineRenderer.allowedShift(30 * ms, of: line, in: segment) == 20 * ms)
        #expect(LineRenderer.allowedShift(3 * ms, of: line, in: segment) == 3 * ms)

        let result = LineRenderer.render(
            segment: segment, recording: samples, lines: [line], maps: [TimeMap(line: line, shiftSamples: -20 * ms)]
        )
        #expect(result.count == segment.lengthSamples)
        // The line moved 5 ms, all the room there was. Past the fade at its start every sample is in place.
        #expect((line.startSample + fade..<line.endSample).allSatisfy {
            result[$0 - segment.inSample - 5 * ms] == samples[$0]
        })
    }

    @Test func aTimeMapOfASlideMovesEveryMomentAlike() {
        let line = VoiceLine(startSample: 1000, endSample: 5000, markers: [1500, 3000])
        let map = TimeMap(line: line, shiftSeconds: -0.010)
        #expect(map.pairs == [
            TimeMap.Pair(source: 1000, result: 520), TimeMap.Pair(source: 5000, result: 4520),
        ])
        #expect(map.shiftSamples == -480)
        #expect(map.result(ofSource: 1500) == 1020)
        #expect(map.result(ofSource: 3000) == 2520)
        #expect(TimeMap.samples(ofShift: 0.0295) == 1416)
        // With a pair inside the line, as later phases add, a moment between two pairs moves by a share of each.
        let bent = TimeMap(pairs: [
            TimeMap.Pair(source: 0, result: 0), TimeMap.Pair(source: 100, result: 120), TimeMap.Pair(source: 200, result: 200),
        ])
        #expect(bent.result(ofSource: 50) == 60)
        #expect(bent.result(ofSource: 150) == 160)
        #expect(bent.result(ofSource: 250) == 250)
    }
}

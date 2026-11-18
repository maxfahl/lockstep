import Foundation
import Synchronization
import Testing
@testable import LockstepCore

/// A stand-in for the real stretcher, for these tests only: it reads the sound faster or slower, which also
/// makes it higher or lower, so it must never be heard. What it is good for is arithmetic: a sample that sits
/// on a key frame lands on its target exactly, so a wrong place shows as a wrong number.
///
/// It counts how often it is asked, and notes when it is handed something a stretcher is promised never to get.
final class LinearStretcher: TimeStretcher {
    private let state = Mutex((calls: 0, promiseBroken: false, keyFrames: [[Int]](), mostStretch: 1.0))

    var calls: Int { state.withLock { $0.calls } }
    /// The most any piece between two neighbouring points was made longer or shorter, as a factor: 1.25 for
    /// a piece that came out a quarter longer, and also for one that came out as 1 / 1.25 of its length. 1
    /// when nothing was stretched.
    var mostStretch: Double { state.withLock { $0.mostStretch } }
    /// True when a call had an empty sound, a length below 1, or key frames that are not inside the piece and
    /// rising.
    var promiseBroken: Bool { state.withLock { $0.promiseBroken } }
    /// The key frames of every call, each as source, target, source, target and so on.
    var keyFrames: [[Int]] { state.withLock { $0.keyFrames } }

    func stretch(_ samples: [Float], keyFrames: [(source: Int, target: Int)], outputLength: Int) -> [Float] {
        let points = [(source: 0, target: 0)] + keyFrames + [(source: samples.count, target: outputLength)]
        let rises = zip(points, points.dropFirst()).allSatisfy { $1.source > $0.source && $1.target > $0.target }
        let factors = zip(points, points.dropFirst()).map { from, to -> Double in
            let (before, after) = (Double(to.source - from.source), Double(to.target - from.target))
            return before > 0 && after > 0 ? max(after / before, before / after) : .infinity
        }
        state.withLock {
            $0.calls += 1
            $0.keyFrames.append(keyFrames.flatMap { [$0.source, $0.target] })
            if !rises { $0.promiseBroken = true }
            $0.mostStretch = max($0.mostStretch, factors.max() ?? 1)
        }
        guard rises else { return [Float](repeating: 0, count: max(outputLength, 0)) }
        var piece = 0
        return (0..<outputLength).map { index in
            while index >= points[piece + 1].target { piece += 1 }
            let (from, to) = (points[piece], points[piece + 1])
            let place = Double(from.source)
                + Double(index - from.target) * Double(to.source - from.source) / Double(to.target - from.target)
            let low = min(Int(place), samples.count - 1)
            let high = min(low + 1, samples.count - 1)
            let share = Float(place - Double(low))
            return samples[low] * (1 - share) + samples[high] * share
        }
    }
}

/// A stretcher that gives back one number over and over, of the length asked for plus `extra` samples. With it
/// a test can tell which samples of a result came from the stretcher and which from the recording.
struct ConstantStretcher: TimeStretcher {
    var value: Float = 0.25
    var extra = 0

    func stretch(_ samples: [Float], keyFrames: [(source: Int, target: Int)], outputLength: Int) -> [Float] {
        [Float](repeating: value, count: max(outputLength + extra, 0))
    }
}

@Suite("A line with its syllables moved")
struct QuantizedLineTests {
    /// One millisecond, in samples.
    private let ms = 48

    /// Quiet room sound that never repeats and is never exactly silent.
    private func room(lengthMs: Int) -> [Float] {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        return (0..<lengthMs * ms).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(state >> 40) / Float(1 << 24) - 0.5
            return noise == 0 ? 0.0005 : noise * 0.002
        }
    }

    /// Room sound with a loud tone in each burst. The bursts are given in milliseconds.
    private func recording(lengthMs: Int, bursts: [Range<Int>]) -> [Float] {
        var samples = room(lengthMs: lengthMs)
        for burst in bursts {
            for index in burst.lowerBound * ms..<burst.upperBound * ms {
                samples[index] += 0.5 * sin(Float(index) * 2 * .pi * 220 / 48_000)
            }
        }
        return samples
    }

    /// How loud a recording with these bursts is, as the app measures it: one value for every millisecond.
    private func levels(lengthMs: Int, bursts: [Range<Int>]) -> VoiceLevels {
        var values = [Float](repeating: -70, count: lengthMs)
        for burst in bursts {
            for index in burst { values[index] = -20 }
        }
        return VoiceLevels(values: values, threshold: -58, hopSamples: ms)
    }

    /// The map of a line that slides by `shift` samples, with each of its markers moved by so many
    /// milliseconds more, in the order of the markers.
    private func map(_ line: VoiceLine, shift: Int = 0, movesMs: [Int]) -> TimeMap {
        TimeMap(pairs: [TimeMap.Pair(source: line.startSample, result: line.startSample + shift)]
            + zip(line.markers, movesMs).map { TimeMap.Pair(source: $0, result: $0 + shift + $1 * ms) }
            + [TimeMap.Pair(source: line.endSample, result: line.endSample + shift)])
    }

    /// Where the clicks are in a sound: every sample far louder than a voice that is louder than its neighbours.
    private func clicks(in samples: [Float]) -> [Int] {
        samples.indices.dropFirst().dropLast().filter {
            samples[$0] > 2 && samples[$0] >= samples[$0 - 1] && samples[$0] > samples[$0 + 1]
        }
    }

    // A line whose three syllables are separated by pauses of 60 ms, 100 ms into its recording. In
    // milliseconds from the line's start: 10 ms of quiet, sound from 10 to 110, from 170 to 270 and from 330
    // to 430, then 30 ms of quiet. The syllables start at 20, 180 and 340.
    private let pausedStart = 100
    private let pausedBursts = [110..<210, 270..<370, 430..<530]
    private var pausedLine: VoiceLine {
        VoiceLine(startSample: 100 * ms, endSample: 560 * ms, markers: [120 * ms, 280 * ms, 440 * ms])
    }

    @Test("Where syllables run together, the run is stretched once and every click lands on its target")
    func clicksLandOnTheirTargets() throws {
        // A line of 600 ms with sound all through it, 200 ms into its recording, with a click on each syllable.
        var samples = recording(lengthMs: 1_000, bursts: [200..<800])
        let line = VoiceLine(startSample: 200 * ms, endSample: 800 * ms, markers: [300 * ms, 450 * ms, 600 * ms])
        for marker in line.markers { samples[marker] = 3 }
        let stretcher = LinearStretcher()
        // The line also slides by 10 ms. That is not part of the line's own sound.
        let moved = try #require(LineRenderer.quantized(
            line: line,
            map: map(line, shift: 480, movesMs: [10, -15, 20]),
            recording: samples,
            levels: levels(lengthMs: 1_000, bursts: [200..<800]),
            stretcher: stretcher
        ))
        #expect(moved.count == line.lengthSamples)
        #expect(stretcher.calls == 1)
        #expect(!stretcher.promiseBroken)
        // The key frames are the syllables, counted from the run's first sample, which is the line's.
        #expect(stretcher.keyFrames == [[100 * ms, 110 * ms, 250 * ms, 235 * ms, 400 * ms, 420 * ms]])
        // Each click within 1 ms of where the map sends it, counted from the line's first sample.
        let found = clicks(in: moved)
        try #require(found.count == 3)
        for (click, target) in zip(found, [110, 235, 420]) {
            #expect(abs(click - target * ms) <= ms)
        }
        // The line begins and ends with the samples that were recorded.
        #expect(moved.first == samples[line.startSample])
        #expect(moved.last == samples[line.endSample - 1])
    }

    @Test("With a pause between all syllables nothing is stretched, and every syllable is the recorded samples")
    func pausesTakeUpTheChange() throws {
        let samples = recording(lengthMs: 700, bursts: pausedBursts)
        let line = pausedLine
        let stretcher = LinearStretcher()
        // The first syllable stays: the 10 ms before it are too short to be a pause. The second goes 12 ms
        // later and the third 8 ms earlier.
        let moved = try #require(LineRenderer.quantized(
            line: line,
            map: map(line, movesMs: [0, 12, -8]),
            recording: samples,
            levels: levels(lengthMs: 700, bursts: pausedBursts),
            stretcher: stretcher
        ))
        #expect(stretcher.calls == 0)
        #expect(moved.count == line.lengthSamples)
        // Each stretch of sound, from the line's first sample: untouched, at its new place.
        for (sound, move) in [(0..<110, 0), (170..<270, 12), (330..<430, -8)] {
            let from = sound.lowerBound * ms
            let length = sound.count * ms
            #expect(moved[from + move * ms..<from + move * ms + length]
                .elementsEqual(samples[line.startSample + from..<line.startSample + from + length]))
        }
        // The pauses are now 72, 40 and 38 ms long. They hold room sound and nothing else: no hole of dead
        // silence, and nothing louder than the room.
        for pause in [110..<182, 282..<322, 422..<460] {
            let part = moved[pause.lowerBound * ms..<pause.upperBound * ms]
            #expect(part.allSatisfy { $0 != 0 && abs($0) <= 0.001 })
        }
        #expect(moved.first == samples[line.startSample])
        #expect(moved.last == samples[line.endSample - 1])
    }

    @Test("A pause that would be left with less than 20 ms does not take the change, and the sound is stretched")
    func aPauseTooShortIsStretchedInstead() throws {
        let samples = recording(lengthMs: 700, bursts: pausedBursts)
        let line = pausedLine
        let stretcher = LinearStretcher()
        // The third syllable comes 42 ms closer to the second: of the 60 ms between them 18 would be left.
        let moved = try #require(LineRenderer.quantized(
            line: line,
            map: map(line, movesMs: [0, 12, -30]),
            recording: samples,
            levels: levels(lengthMs: 700, bursts: pausedBursts),
            stretcher: stretcher
        ))
        #expect(moved.count == line.lengthSamples)
        // The second and third stretch of sound and the pause between them go through the stretcher as one.
        #expect(stretcher.calls == 1)
        #expect(!stretcher.promiseBroken)
        // That run starts 170 ms into the line, 10 ms before its first syllable, and moves 12 ms with it.
        #expect(stretcher.keyFrames == [[10 * ms, 10 * ms, 170 * ms, 128 * ms]])
        // The first stretch of sound is still untouched, and the pause after it still takes its 12 ms.
        #expect(moved[..<(110 * ms)].elementsEqual(samples[line.startSample..<line.startSample + 110 * ms]))

        // 40 ms closer leaves exactly 20 ms, and that the pause can still take.
        let spared = LinearStretcher()
        _ = try #require(LineRenderer.quantized(
            line: line,
            map: map(line, movesMs: [0, 12, -28]),
            recording: samples,
            levels: levels(lengthMs: 700, bursts: pausedBursts),
            stretcher: spared
        ))
        #expect(spared.calls == 0)
    }

    @Test("With the stretch limit at 0 a syllable after a 100 ms pause moves, and every syllable is the recorded samples")
    func atLimitZeroOnlyThePausesChange() throws {
        // In milliseconds of the recording: sound from 110 to 260, a pause of 100 ms, sound from 360 to 560,
        // and the line ends 30 ms after that. The syllables are at 120, 390 and 515, so the last two run
        // together.
        let bursts = [110..<260, 360..<560]
        let samples = recording(lengthMs: 700, bursts: bursts)
        let levels = levels(lengthMs: 700, bursts: bursts)
        let line = VoiceLine(startSample: 100 * ms, endSample: 590 * ms, markers: [120 * ms, 390 * ms, 515 * ms])
        // A beat every half second, so a sixteenth every 125 ms. The line starts 2.98 s into the song: its
        // first syllable is on the sixteenth at 3.0, and the two after the pause are each 20 ms late.
        let grid = Grid(beats: (0...12).map { Beat(number: $0, time: Double($0) * 0.5) })
        let nothingStretched = SyllableMoves.Limits(maxStretchPercent: 0)
        let map = SyllableMoves.plan(
            line: line, songStart: 2.98, grid: grid, strength: 1, limits: nothingStretched, levels: levels
        )
        // The two syllables after the pause go their whole 20 ms, together. The first stays with the line's
        // start, which never moves.
        #expect(map.pairs.map { $0.result - $0.source } == [0, 0, -20 * ms, -20 * ms, 0])
        // A planner that is not told where the pauses are moves nothing at this limit.
        let blind = SyllableMoves.plan(line: line, songStart: 2.98, grid: grid, strength: 1, limits: nothingStretched)
        #expect(blind.pairs.allSatisfy { $0.result == $0.source })

        let stretcher = LinearStretcher()
        let moved = try #require(LineRenderer.quantized(
            line: line, map: map, recording: samples, levels: levels, stretcher: stretcher
        ))
        #expect(stretcher.calls == 0)
        #expect(moved.count == line.lengthSamples)
        // Each stretch of sound, from the line's first sample: untouched, at its new place.
        for (sound, move) in [(0..<160, 0), (260..<460, -20)] {
            let from = sound.lowerBound * ms
            let length = sound.count * ms
            #expect(moved[from + move * ms..<from + move * ms + length]
                .elementsEqual(samples[line.startSample + from..<line.startSample + from + length]))
        }
        // The pause of 100 ms is now 80 ms long and the 30 ms at the line's end are 50. They hold room sound
        // and nothing else.
        for pause in [160..<240, 440..<490] {
            let part = moved[pause.lowerBound * ms..<pause.upperBound * ms]
            #expect(part.allSatisfy { $0 != 0 && abs($0) <= 0.001 })
        }
        #expect(moved.first == samples[line.startSample])
        #expect(moved.last == samples[line.endSample - 1])
    }

    @Test("Syllables of one run that move by nearly the same amount move as one block, unstretched")
    func nearlyEqualMovesAreOneBlock() throws {
        let samples = recording(lengthMs: 700, bursts: pausedBursts)
        // The middle stretch of sound holds two syllables. One moves by 576 samples and the other by 590.
        var line = pausedLine
        line.markers = [120 * ms, 280 * ms, 340 * ms, 440 * ms]
        var pairs = map(line, movesMs: [0, 12, 12, 0]).pairs
        pairs[3].result += 14
        let stretcher = LinearStretcher()
        let moved = try #require(LineRenderer.quantized(
            line: line,
            map: TimeMap(pairs: pairs),
            recording: samples,
            levels: levels(lengthMs: 700, bursts: pausedBursts),
            stretcher: stretcher
        ))
        #expect(stretcher.calls == 0)
        // The block goes to the middle of what its two syllables ask for.
        let from = 170 * ms
        #expect(moved[from + 583..<from + 583 + 100 * ms]
            .elementsEqual(samples[line.startSample + from..<line.startSample + from + 100 * ms]))
    }

    @Test("A map that moves nothing inside the line gives no sound of its own: the line is used as recorded")
    func nothingToMoveGivesNothing() throws {
        let samples = recording(lengthMs: 700, bursts: pausedBursts)
        let line = pausedLine
        let levels = levels(lengthMs: 700, bursts: pausedBursts)
        let stretcher = LinearStretcher()
        func quantized(_ map: TimeMap) -> [Float]? {
            LineRenderer.quantized(line: line, map: map, recording: samples, levels: levels, stretcher: stretcher)
        }
        // No syllable moves, with and without a slide of the whole line, and with no syllables in the map.
        #expect(quantized(map(line, movesMs: [0, 0, 0])) == nil)
        #expect(quantized(map(line, shift: 480, movesMs: [0, 0, 0])) == nil)
        #expect(quantized(TimeMap(line: line, shiftSamples: 480)) == nil)
        // Maps no sound can be built from: the line's end moves, two syllables cross, another line's map.
        var endMoves = map(line, movesMs: [0, 12, 0]).pairs
        endMoves[4].result += 48
        #expect(quantized(TimeMap(pairs: endMoves)) == nil)
        #expect(quantized(map(line, movesMs: [0, 170, 0])) == nil)
        #expect(quantized(map(VoiceLine(startSample: 0, endSample: 560 * ms, markers: line.markers), movesMs: [0, 12, 0])) == nil)
        #expect(stretcher.calls == 0)

        // And the segment built from such a line is the recording, sample for sample.
        let whole = Segment(recordingID: UUID(), inSample: 0, outSample: samples.count)
        #expect(LineRenderer.render(
            segment: whole, recording: samples, lines: [line], maps: [map(line, movesMs: [0, 0, 0])], quantized: [nil]
        ) == samples)
    }

    @Test("A stretched line still begins and ends with the recorded samples, and a wrong length gives the line up")
    func theEdgesAreTheRecording() throws {
        let samples = recording(lengthMs: 1_000, bursts: [200..<800])
        let line = VoiceLine(startSample: 200 * ms, endSample: 800 * ms, markers: [300 * ms, 450 * ms])
        let levels = levels(lengthMs: 1_000, bursts: [200..<800])
        // Everything this stretcher gives is 0.25, so whatever is not 0.25 came from the recording.
        let moved = try #require(LineRenderer.quantized(
            line: line, map: map(line, movesMs: [10, -10]), recording: samples, levels: levels,
            stretcher: ConstantStretcher()
        ))
        #expect(moved.count == line.lengthSamples)
        #expect(moved.first == samples[line.startSample])
        #expect(moved.last == samples[line.endSample - 1])
        // 10 ms in from either edge the stretcher's sound is all there is.
        #expect(moved[480..<moved.count - 480].allSatisfy { $0 == 0.25 })

        for extra in [-1, 1] {
            #expect(LineRenderer.quantized(
                line: line, map: map(line, movesMs: [10, -10]), recording: samples, levels: levels,
                stretcher: ConstantStretcher(extra: extra)
            ) == nil)
        }
        // A recording that does not hold the whole line.
        #expect(LineRenderer.quantized(
            line: line, map: map(line, movesMs: [10, -10]), recording: Array(samples[..<(700 * ms)]), levels: levels,
            stretcher: LinearStretcher()
        ) == nil)
    }

    @Test("A pause made longer or shorter keeps its first and last samples, and is exactly as long as asked")
    func aPauseIsResized() {
        let pause = Array(room(lengthMs: 60))
        for change in [-40 * ms, -1, 0, 1, 100, 12 * ms, 90 * ms] {
            let resized = LineRenderer.resized(pause, by: change, fade: 480)
            #expect(resized.count == pause.count + change)
            // 5 ms at either end are the pause's own, whatever happens in the middle.
            #expect(resized.prefix(240).elementsEqual(pause.prefix(240)))
            #expect(resized.suffix(240).elementsEqual(pause.suffix(240)))
            #expect(resized.allSatisfy { $0 != 0 && abs($0) <= 0.001 })
        }
        // Where the gap opens, the room sound turns around: the same sample again, with no jump.
        let longer = LineRenderer.resized(pause, by: 12 * ms, fade: 480)
        let half = pause.count / 2
        #expect(longer[half] == pause[half - 1])
        #expect(longer[half + 12 * ms - 1] == pause[half])
    }

    @Test("""
    Five hundred made-up lines: each comes out as long as it was, with its own first and last sample, and \
    a plan that knew the pauses never has one stretched
    """)
    func everyMadeUpLineKeepsItsLengthAndItsEdges() throws {
        // The same made-up numbers on every run, so a failure can be repeated.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ range: ClosedRange<Int>) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return range.lowerBound + Int((state >> 33) % UInt64(range.count))
        }
        let samples = room(lengthMs: 1_600)
        var built = 0
        var stretched = 0
        var unstretched = 0
        var movedAtLimitZero = 0
        for _ in 0..<500 {
            // A line of 0.2 to 1.2 seconds somewhere in the recording, with syllables 40 to 200 ms apart and
            // a pause of 20 to 90 ms after some of them.
            let start = next(0...300) * ms + next(0...47)
            let lengthMs = next(200...1_200)
            var values = [Float](repeating: -20, count: 1_600)
            var markers: [Int] = []
            var place = next(5...40)
            while place < lengthMs - 40 {
                markers.append(start + place * ms)
                if next(0...2) == 0 {
                    let pause = next(20...90)
                    let from = start / ms + place + next(10...30)
                    for index in from..<min(from + pause, 1_600) { values[index] = -70 }
                }
                place += next(40...200)
            }
            let line = VoiceLine(startSample: start, endSample: start + lengthMs * ms, markers: markers)
            let levels = VoiceLevels(values: values, threshold: -58, hopSamples: ms)
            // Each syllable asks for up to 40 ms either way, and gets what the planner's rules leave of it.
            let asked = [0] + markers.map { _ in next(-40...40) * ms } + [0]
            let points = [line.startSample] + markers + [line.endSample]
            let percent = Double(next(0...40))
            let shift = next(-80...80) * ms
            let pauses = SyllablePauses.lengths(between: points, levels: levels)
            // The line is planned three times: as the app plans it, knowing where the pauses are; without
            // that knowledge, which is what a map from anywhere else may look like; and as the app plans it
            // with the stretch limit at 0.
            for (percent, knowsPauses) in [(percent, true), (percent, false), (0, true)] {
                let moves = SyllableMoves.held(
                    asked, points: points, maxStretchPercent: percent, pauses: knowsPauses ? pauses : []
                )
                let map = TimeMap(pairs: zip(points, moves).map { TimeMap.Pair(source: $0, result: $0 + shift + $1) })
                let stretcher = LinearStretcher()
                let moved = LineRenderer.quantized(
                    line: line, map: map, recording: samples, levels: levels, stretcher: stretcher
                )
                #expect(!stretcher.promiseBroken)
                if knowsPauses {
                    // The planner and the renderer agree. Every pause the planner counted on takes its
                    // change, so no pause is given up and stretched over. What the stretcher gets is never
                    // stretched by more than the limit. And with the limit at 0 it gets nothing at all.
                    if let controlPoints = LineRenderer.controlPoints(of: line, map: map) {
                        let runs = LineRenderer.runs(of: line, points: controlPoints, levels: levels)
                        #expect(runs.count == pauses.compactMap { $0 }.count + 1)
                    }
                    #expect(stretcher.mostStretch <= 1 + percent / 100 + 1e-9)
                    if percent == 0 { #expect(stretcher.calls == 0) }
                }
                guard let moved else {
                    // Only a line in which nothing moves is used as recorded.
                    #expect(moves.allSatisfy { $0 == 0 })
                    continue
                }
                #expect(moved.count == line.lengthSamples)
                #expect(moved.first == samples[line.startSample])
                #expect(moved.last == samples[line.endSample - 1])
                #expect(moved.allSatisfy { $0 != 0 && abs($0) <= 0.001 })
                guard knowsPauses else { continue }
                built += 1
                stretched += stretcher.calls > 0 ? 1 : 0
                unstretched += stretcher.calls == 0 ? 1 : 0
                movedAtLimitZero += percent == 0 ? 1 : 0
            }
        }
        // The made-up lines really did hold both kinds: some that needed the stretcher and some that did not,
        // among them many that changed with the stretch limit at 0.
        #expect(built > 400 && stretched > 300 && unstretched > 100 && movedAtLimitZero > 100)
    }

    @Test("The segment is built with the moved line at the place the line slides to")
    func theMovedLineIsSlidLikeAnyOther() throws {
        let samples = recording(lengthMs: 1_000, bursts: pausedBursts)
        let line = pausedLine
        let levels = levels(lengthMs: 1_000, bursts: pausedBursts)
        let whole = Segment(recordingID: UUID(), inSample: 0, outSample: samples.count)
        let moves = map(line, shift: 960, movesMs: [0, 12, -8])
        let moved = try #require(LineRenderer.quantized(
            line: line, map: moves, recording: samples, levels: levels, stretcher: LinearStretcher()
        ))
        let result = LineRenderer.render(
            segment: whole, recording: samples, lines: [line], maps: [moves], quantized: [moved]
        )
        #expect(result.count == samples.count)
        #expect(result[line.startSample + 960..<line.endSample + 960].elementsEqual(moved))
        // Outside the line, the segment is what sliding the recorded line gives.
        let slid = LineRenderer.render(
            segment: whole, recording: samples, lines: [line], maps: [TimeMap(line: line, shiftSamples: 960)]
        )
        #expect(result[..<(line.startSample + 960)] == slid[..<(line.startSample + 960)])
        #expect(result[(line.endSample + 960)...] == slid[(line.endSample + 960)...])
        #expect(result != slid)

        // Without a slide the moved line lies where the line was, and the rest is the recording.
        let still = map(line, movesMs: [0, 12, -8])
        let inPlace = LineRenderer.render(
            segment: whole, recording: samples, lines: [line], maps: [still], quantized: [moved]
        )
        #expect(inPlace[line.startSample..<line.endSample].elementsEqual(moved))
        #expect(inPlace[..<line.startSample] == samples[..<line.startSample])
        #expect(inPlace[line.endSample...] == samples[line.endSample...])
        // A sound of the wrong length is not used.
        #expect(LineRenderer.render(
            segment: whole, recording: samples, lines: [line], maps: [still], quantized: [Array(moved.dropLast())]
        ) == samples)
    }
}

/// Single syllables from a clip to what is heard.
///
/// The song has a beat every half second, so a sixteenth is 125 ms. The recording began one second into the
/// song and holds one line with sound from 500 to 1,100 ms. Its four syllables are 20, 30, 10 and 30 ms late,
/// so no slide of the whole line can put them all on the beat.
@Suite("Clip tightening with single syllables")
struct ClipSyllablesTests {
    static let ms = 48
    static let recordingMs = 2_000
    static let burst = 500..<1_100
    static let syllables = [520, 655, 760, 905]

    static let grid = Grid(beats: (0...12).map { Beat(number: $0, time: Double($0) * 0.5) })
    static let recording = Recording(lengthSamples: recordingMs * ms, rawStart: 1)
    static let markers = [recording.id: syllables.map { SyllableMarker(sample: $0 * ms, strength: 12) }]
    /// A clip that plays the whole recording at the place it was recorded.
    static let clip = Clip(segments: [Segment(recordingID: recording.id, inSample: 0, outSample: recordingMs * ms)])

    /// Quiet room sound as long as the recording, that never repeats and is never exactly silent.
    static let room: [Float] = {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        return (0..<recordingMs * ms).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(state >> 40) / Float(1 << 24) - 0.5
            return noise == 0 ? 0.0005 : noise * 0.002
        }
    }()

    /// Room sound, a tone where the line is, and a click on every syllable.
    static let sound: [Float] = {
        var samples = room
        for index in burst.lowerBound * ms..<burst.upperBound * ms {
            samples[index] += 0.5 * sin(Float(index) * 2 * .pi * 220 / 48_000)
        }
        for syllable in syllables { samples[syllable * ms] = 3 }
        return samples
    }()

    static let levels: [UUID: VoiceLevels] = {
        var values = [Float](repeating: -70, count: recordingMs)
        for index in burst { values[index] = -20 }
        return [recording.id: VoiceLevels(values: values, threshold: -58, hopSamples: ms)]
    }()

    static func inputs(
        strength: Double,
        tightenLines: Bool = true,
        settings: TightenSettings = TightenSettings(),
        excluded: [Int] = []
    ) throws -> ClipTightening.Inputs {
        var recording = recording
        recording.excludedMarkers = excluded
        let project = Project(
            songLengthSamples: 288_000,
            grid: grid,
            tracks: [Track(name: "Track 1", clips: [clip])],
            recordings: [recording]
        )
        return try #require(ClipTightening.Inputs(
            clip: clip, in: project, markers: markers, settings: settings, strength: strength, tightenLines: tightenLines, voices: .none
        ))
    }

    static func render(_ inputs: ClipTightening.Inputs, stretcher: (any TimeStretcher)?) -> [ClipTightening.SegmentSound] {
        ClipTightening.render(inputs, levels: levels, recordings: [recording.id: sound], stretcher: stretcher)
    }

    /// Where the clicks are in a sound.
    static func clicks(in samples: [Float]) -> [Int] {
        samples.indices.dropFirst().dropLast().filter {
            samples[$0] > 2 && samples[$0] >= samples[$0 - 1] && samples[$0] > samples[$0 + 1]
        }
    }

    @Test("With the strength at 0, or with no stretcher, the sound is sample for sample what Tighten lines gives")
    func withoutStrengthOrStretcherNothingChanges() throws {
        let today = ClipTightening.render(
            try Self.inputs(strength: 0), levels: Self.levels, recordings: [Self.recording.id: Self.sound]
        )
        try #require(today.count == 1 && today[0].samples != nil)
        // Strength 0 with a stretcher: the stretcher is never asked.
        let stretcher = LinearStretcher()
        #expect(Self.render(try Self.inputs(strength: 0), stretcher: stretcher) == today)
        #expect(stretcher.calls == 0)
        // Full strength with no stretcher: the same lines, the same maps, the same samples.
        #expect(Self.render(try Self.inputs(strength: 1), stretcher: nil) == today)
        // The maps of today hold the slide and nothing else.
        #expect(today[0].lines.allSatisfy { $0.map.pairs.count == 2 })
    }

    @Test("With a strength and a stretcher each syllable is heard where the line's map says it went")
    func syllablesAreHeardWhereTheMapSays() throws {
        let today = Self.render(try Self.inputs(strength: 0), stretcher: nil)
        let stretcher = LinearStretcher()
        let made = Self.render(try Self.inputs(strength: 1), stretcher: stretcher)
        try #require(made.count == 1 && made[0].lines.count == 1)
        let line = made[0].lines[0]
        let samples = try #require(made[0].samples)
        #expect(stretcher.calls >= 1)
        #expect(!stretcher.promiseBroken)

        // The same line with the same slide as today, now with a place for each syllable.
        #expect(line.line == today[0].lines[0].line)
        #expect(line.shiftSamples == today[0].lines[0].shiftSamples)
        #expect(line.map.pairs.count == 6)
        // The segment is as long as it was.
        #expect(samples.count == Self.recordingMs * Self.ms)

        // Each click within 1 ms of where the map sends its syllable, and at least one moved by itself.
        let found = Self.clicks(in: samples)
        try #require(found.count == 4)
        let targets = Self.syllables.map { line.map.result(ofSource: $0 * Self.ms) }
        for (click, target) in zip(found, targets) {
            #expect(abs(click - target) <= Self.ms)
        }
        #expect(zip(targets, Self.syllables).contains { $0 - $1 * Self.ms != line.shiftSamples })
        // At full strength a syllable that the limits do not hold back is on its sixteenth: sample 48,000 of
        // the song is sample 0 of the recording, and a sixteenth is 6,000 samples.
        #expect(targets.contains { $0 % 6_000 == 0 })

        // The line starts and ends where the slide puts it, so outside it nothing differs from today.
        let from = line.line.startSample + line.shiftSamples
        let to = line.line.endSample + line.shiftSamples
        let slid = try #require(today[0].samples)
        #expect(samples[..<from] == slid[..<from])
        #expect(samples[to...] == slid[to...])
        #expect(samples[from] == slid[from] && samples[to - 1] == slid[to - 1])
        #expect(samples != slid)
    }

    @Test("With Tighten lines off the line stays, and its syllables still move inside it")
    func syllablesMoveInALineThatStays() throws {
        let made = Self.render(try Self.inputs(strength: 1, tightenLines: false), stretcher: LinearStretcher())
        let line = try #require(made.first?.lines.first)
        let samples = try #require(made[0].samples)
        #expect(line.shiftSamples == 0)
        #expect(line.map.pairs.count == 6)
        #expect(line.map.pairs.contains { $0.result != $0.source })
        // Outside the line the sound is the recording.
        #expect(samples[..<line.line.startSample] == Self.sound[..<line.line.startSample])
        #expect(samples[line.line.endSample...] == Self.sound[line.line.endSample...])
        // With the strength at 0 as well there is nothing to make at all.
        #expect(Self.render(try Self.inputs(strength: 0, tightenLines: false), stretcher: LinearStretcher())[0].samples == nil)
    }

    @Test("A syllable Max excluded is heard where the slide of its line puts it and nowhere else")
    func anExcludedSyllableStays() throws {
        let excluded = Self.syllables[2] * Self.ms
        let made = Self.render(try Self.inputs(strength: 1, excluded: [excluded]), stretcher: LinearStretcher())
        let line = try #require(made.first?.lines.first)
        let samples = try #require(made[0].samples)
        #expect(line.map.result(ofSource: excluded) == excluded + line.shiftSamples)
        #expect(Self.clicks(in: samples).contains(excluded + line.shiftSamples))
    }

    @Test("With the stretch limit at 0 a clip's syllables after a pause still move, and the stretcher is never asked")
    func atLimitZeroAClipChangesOnlyItsPauses() throws {
        // One line with a pause of 100 ms in it: sound from 500 to 780 ms and from 880 to 1,100 ms of the
        // recording. The two syllables before the pause are on their sixteenths (500 and 625 ms), and the
        // two after it are each 20 ms late (895 and 1,020 ms).
        let ms = Self.ms
        let syllables = [500, 625, 895, 1_020]
        let recording = Recording(lengthSamples: Self.recordingMs * ms, rawStart: 1)
        let clip = Clip(segments: [Segment(recordingID: recording.id, inSample: 0, outSample: Self.recordingMs * ms)])
        var sound = Self.room
        var values = [Float](repeating: -70, count: Self.recordingMs)
        for burst in [500..<780, 880..<1_100] {
            for index in burst.lowerBound * ms..<burst.upperBound * ms {
                sound[index] += 0.5 * sin(Float(index) * 2 * .pi * 220 / 48_000)
            }
            for index in burst { values[index] = -20 }
        }
        for syllable in syllables { sound[syllable * ms] = 3 }
        let project = Project(
            songLengthSamples: 288_000,
            grid: Self.grid,
            tracks: [Track(name: "Track 1", clips: [clip])],
            recordings: [recording]
        )
        // Lines do not slide here, so every move is a syllable's own.
        let inputs = try #require(ClipTightening.Inputs(
            clip: clip,
            in: project,
            markers: [recording.id: syllables.map { SyllableMarker(sample: $0 * ms, strength: 12) }],
            settings: TightenSettings(maxStretchPercent: 0),
            strength: 1,
            tightenLines: false, voices: .none
        ))
        let stretcher = LinearStretcher()
        let made = ClipTightening.render(
            inputs,
            levels: [recording.id: VoiceLevels(values: values, threshold: -58, hopSamples: ms)],
            recordings: [recording.id: sound],
            stretcher: stretcher
        )
        try #require(made.count == 1 && made[0].lines.count == 1)
        #expect(stretcher.calls == 0)
        // The two syllables after the pause are on their sixteenths now, to the sample, and the two before
        // it are where they were.
        #expect(made[0].lines[0].map.pairs.map { $0.result - $0.source } == [0, 0, 0, -20 * ms, -20 * ms, 0])
        let samples = try #require(made[0].samples)
        #expect(Self.clicks(in: samples) == [500, 625, 875, 1_000].map { $0 * ms })
    }

    @Test("A clip with Stretch off gets the same moves and the same sound as the stretch limit 0 gives")
    func stretchOffIsTheStretchLimitZero() throws {
        // The line of these tests has no pause in it, and its syllables are 20, 30, 10 and 30 ms late, so
        // they ask for different moves. With Stretch on, at the 25 % of Settings, they get them.
        func clip(stretch: Bool) -> Clip {
            var clip = Self.clip
            clip.tighten = .all
            clip.strength = 1
            clip.stretch = stretch
            return clip
        }
        func project(_ clip: Clip) -> Project {
            Project(
                songLengthSamples: 288_000,
                grid: Self.grid,
                tracks: [Track(name: "Track 1", clips: [clip])],
                recordings: [Self.recording]
            )
        }
        let settings = TightenSettings(maxStretchPercent: 25)
        let off = try #require(ClipTightening.Inputs(
            correcting: clip(stretch: false), in: project(clip(stretch: false)), markers: Self.markers, settings: settings, voices: .none
        ))
        let on = try #require(ClipTightening.Inputs(
            correcting: clip(stretch: true), in: project(clip(stretch: true)), markers: Self.markers, settings: settings, voices: .none
        ))
        // What the stretch limit 0 gives, asked for the old way: the setting itself at 0.
        let atZero = try Self.inputs(strength: 1, settings: TightenSettings(maxStretchPercent: 0))

        let offStretcher = LinearStretcher()
        let madeOff = Self.render(off, stretcher: offStretcher)
        let madeAtZero = Self.render(atZero, stretcher: LinearStretcher())
        // The same moves for every syllable, and the same sound, sample for sample.
        #expect(madeOff.map { $0.lines.map(\.map) } == madeAtZero.map { $0.lines.map(\.map) })
        #expect(madeOff.map(\.samples) == madeAtZero.map(\.samples))
        // Nothing went through the stretcher, and the syllables, which run together, all moved alike.
        #expect(offStretcher.calls == 0)
        let moves = try #require(madeOff.first?.lines.first).map.pairs.dropFirst().dropLast().map { $0.result - $0.source }
        #expect(Set(moves).count <= 1)

        // With Stretch on the same clip is stretched, and its syllables move by different amounts.
        let onStretcher = LinearStretcher()
        let madeOn = Self.render(on, stretcher: onStretcher)
        #expect(onStretcher.calls >= 1)
        let stretched = try #require(madeOn.first?.lines.first).map.pairs.dropFirst().dropLast().map { $0.result - $0.source }
        #expect(Set(stretched).count > 1)
    }

    @Test("The inputs change with the strength, the switch and the two limits, so the sound is made again")
    func inputsChangeWithStrengthAndLimits() throws {
        let inputs = try Self.inputs(strength: 0.5)
        #expect(try Self.inputs(strength: 0.5) == inputs)
        #expect(try Self.inputs(strength: 0.6) != inputs)
        #expect(try Self.inputs(strength: 0.5, tightenLines: false) != inputs)
        #expect(try Self.inputs(strength: 0.5, settings: TightenSettings(maxSyllableMoveMs: 20)) != inputs)
        #expect(try Self.inputs(strength: 0.5, settings: TightenSettings(maxStretchPercent: 10)) != inputs)
        // The limits reach the planner as the settings have them.
        #expect(TightenSettings().syllableLimits == SyllableMoves.Limits())
        #expect(
            TightenSettings(deliberatePercent: 20, maxSyllableMoveMs: 15, maxStretchPercent: 5).syllableLimits
                == SyllableMoves.Limits(deliberatePercent: 20, maxMoveMs: 15, maxStretchPercent: 5)
        )
    }
}

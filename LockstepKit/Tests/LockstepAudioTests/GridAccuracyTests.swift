import Foundation
import Testing
import LockstepCore
@testable import LockstepAudio

/// How far the beat lines of a grid are from the drum hits of the song.
///
/// For every beat that is not estimated, the strongest onset within `reach` of the beat line is
/// taken as its drum hit, and the distance between the two is measured. This is the measure the
/// plan names. It is stricter than the prototype's: the prototype (`refine2.py`) looked only
/// 20 ms either side of the line and left out hits it judged not to fit, so `prototypeReach`
/// gives the figure that compares best with its 5.8 ms.
struct GridAccuracy {
    static let reach = 0.035
    static let prototypeReach = 0.020

    struct Measured: Equatable {
        var number: Int
        /// Where the beat line is, in song seconds.
        var time: Double
        /// How much later than the line the drum hit comes, in seconds. Negative when it comes earlier.
        var offset: Double
        var distance: Double { abs(offset) }
    }

    var beatCount = 0
    var estimatedCount = 0
    /// Beats that are not estimated but have no onset at all within reach (the curve is flat there).
    var withoutOnset = 0
    /// One entry per beat that was measured, in song order.
    var measured: [Measured] = []
    /// The slowest and the fastest tempo the grid shows at any beat, in beats per minute.
    var tempoRange: ClosedRange<Double>?

    var median: Double { Self.median(measured.map(\.distance)) }
    var worst: Double { measured.map(\.distance).max() ?? 0 }
    /// Positive when the hits tend to come after the lines.
    var medianOffset: Double { Self.median(measured.map(\.offset)) }
    /// The beats furthest from their hit, furthest first.
    func furthest(_ count: Int) -> [Measured] {
        Array(measured.sorted { $0.distance > $1.distance }.prefix(count))
    }
    func count(beyond distance: Double) -> Int {
        measured.filter { $0.distance > distance }.count
    }

    static func measure(_ grid: Grid, against onsets: OnsetCurve, reach: Double = GridAccuracy.reach) -> GridAccuracy {
        var result = GridAccuracy()
        result.beatCount = grid.beats.count
        result.estimatedCount = grid.beats.filter(\.estimated).count
        for beat in grid.beats where !beat.estimated {
            if let hit = strongestOnset(in: onsets, around: beat.time, within: reach) {
                result.measured.append(Measured(number: beat.number, time: beat.time, offset: hit - beat.time))
            } else {
                result.withoutOnset += 1
            }
        }
        let tempos = grid.beats.compactMap { grid.tempo(at: $0.time) }
        if let slowest = tempos.min(), let fastest = tempos.max() { result.tempoRange = slowest...fastest }
        return result
    }

    /// The time of the highest onset value within `reach` seconds of `centre`, or nil when the
    /// curve has no values there or is flat there. Of equal values the one nearest the centre wins.
    static func strongestOnset(in onsets: OnsetCurve, around centre: Double, within reach: Double) -> Double? {
        let perSecond = Lockstep.sampleRate / Double(OnsetCurve.hopSamples)
        let first = max(Int(((centre - reach) * perSecond).rounded(.up)), 0)
        let last = min(Int(((centre + reach) * perSecond).rounded(.down)), onsets.values.count - 1)
        guard first <= last else { return nil }
        var best = first
        var lowest = onsets.values[first]
        for index in first...last {
            let value = onsets.values[index]
            let nearer = abs(onsets.time(at: index) - centre) < abs(onsets.time(at: best) - centre)
            if value > onsets.values[best] || (value == onsets.values[best] && nearer) { best = index }
            lowest = min(lowest, value)
        }
        guard onsets.values[best] > lowest else { return nil }
        return onsets.time(at: best)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: The report Max reads

    static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1_000)
    }

    static func songTime(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds - Double(Int(seconds) / 60 * 60))
    }

    func report() -> String {
        var lines = [
            "  \(beatCount) beats, \(estimatedCount) of them estimated, \(measured.count) measured against a drum hit"
                + (withoutOnset > 0 ? ", \(withoutOnset) with no onset near them" : ""),
            "  typical distance from line to hit (median): \(Self.milliseconds(median))",
            "  worst: \(Self.milliseconds(worst))",
            "  further than 10 ms: \(count(beyond: 0.010)) beats, further than 20 ms: \(count(beyond: 0.020)) beats",
            "  the hits come typically \(Self.milliseconds(abs(medianOffset))) \(medianOffset < 0 ? "before" : "after") the lines",
        ]
        if let tempoRange {
            lines.append("  tempo from \(tempoRange.lowerBound) to \(tempoRange.upperBound) beats per minute")
        }
        let far = measured.filter { $0.distance > 0.020 }.map { Self.songTime($0.time) }
        if !far.isEmpty { lines.append("  further than 20 ms, in song order: " + far.joined(separator: ", ")) }
        lines.append("  the beats furthest from their hit:")
        for beat in furthest(10) {
            let side = beat.offset < 0 ? "before" : "after"
            lines.append("    at \(Self.songTime(beat.time)) (beat \(beat.number)): hit \(Self.milliseconds(beat.distance)) \(side) the line")
        }
        return lines.joined(separator: "\n")
    }
}

@Suite struct GridAccuracyTests {
    /// An onset curve with a peak at each of these times (rounded to the curve's 0.67 ms steps).
    private func onsets(seconds: Double, peaks: [(time: Double, strength: Float)]) -> OnsetCurve {
        var values = [Float](repeating: 0, count: Int(seconds * 1_500))
        for peak in peaks { values[Int((peak.time * 1_500).rounded())] = peak.strength }
        return OnsetCurve(values: values)
    }

    /// One step of the onset curve: a distance cannot be known more exactly than this.
    private let step = 0.0007

    @Test func measuresTheDistanceFromEachBeatToItsHit() {
        // Beats every 0.6 s from 1 s. Their hits come 2, 4, 6, 8 and 30 ms late or early.
        let offsets = [0.002, -0.004, 0.006, -0.008, 0.030]
        let grid = Grid(beats: offsets.indices.map { Beat(number: $0, time: 1 + 0.6 * Double($0)) })
        let curve = onsets(seconds: 5, peaks: offsets.indices.map { (1 + 0.6 * Double($0) + offsets[$0], 5) })

        let accuracy = GridAccuracy.measure(grid, against: curve)

        #expect(accuracy.beatCount == 5 && accuracy.estimatedCount == 0 && accuracy.withoutOnset == 0)
        #expect(accuracy.measured.count == 5)
        for (measured, offset) in zip(accuracy.measured, offsets) {
            #expect(abs(measured.offset - offset) < step)
        }
        #expect(abs(accuracy.median - 0.006) < step)
        #expect(abs(accuracy.worst - 0.030) < step)
        #expect(abs(accuracy.medianOffset - 0.002) < step)
        #expect(accuracy.count(beyond: 0.010) == 1 && accuracy.count(beyond: 0.020) == 1)
        #expect(accuracy.furthest(2).map(\.number) == [4, 3])
        #expect(accuracy.tempoRange == 100.0...100.0)
    }

    @Test func theStrongestOnsetCountsNotTheNearest() {
        // A weak tick 3 ms from the line and a strong hit 25 ms from it: the hit is the strong one.
        let grid = Grid(beats: [Beat(number: 0, time: 2)])
        let curve = onsets(seconds: 4, peaks: [(2.003, 1), (1.975, 6)])

        let accuracy = GridAccuracy.measure(grid, against: curve)
        #expect(abs(accuracy.measured[0].offset + 0.025) < step)
        // The prototype's narrower search does not reach the strong hit and takes the tick.
        let narrow = GridAccuracy.measure(grid, against: curve, reach: GridAccuracy.prototypeReach)
        #expect(abs(narrow.measured[0].offset - 0.003) < step)
    }

    @Test func estimatedBeatsAndBeatsWithoutAnOnsetAreNotMeasured() {
        let grid = Grid(beats: [
            Beat(number: 0, time: 1),
            Beat(number: 1, time: 1.6, estimated: true),
            // Its only onset is 40 ms away, outside the 35 ms that are searched.
            Beat(number: 2, time: 2.2),
            Beat(number: 3, time: 2.8),
        ])
        let curve = onsets(seconds: 4, peaks: [(1.001, 5), (1.6, 5), (2.24, 5), (2.79, 5)])

        let accuracy = GridAccuracy.measure(grid, against: curve)

        #expect(accuracy.beatCount == 4 && accuracy.estimatedCount == 1 && accuracy.withoutOnset == 1)
        #expect(accuracy.measured.map(\.number) == [0, 3])
        #expect(abs(accuracy.worst - 0.010) < step)
    }

    @Test func aBeatAtTheVeryStartOrEndOfTheSongIsMeasuredWithWhatIsThere() {
        let grid = Grid(beats: [Beat(number: 0, time: 0.01), Beat(number: 1, time: 0.999)])
        let curve = onsets(seconds: 1, peaks: [(0.004, 5), (0.99, 5)])

        let accuracy = GridAccuracy.measure(grid, against: curve)

        #expect(accuracy.measured.count == 2)
        #expect(abs(accuracy.measured[0].offset + 0.006) < step)
        #expect(abs(accuracy.measured[1].offset + 0.009) < step)
        // A grid without beats gives zeros and no tempo, not a crash.
        let empty = GridAccuracy.measure(Grid(beats: []), against: curve)
        #expect(empty.measured.isEmpty && empty.median == 0 && empty.worst == 0 && empty.tempoRange == nil)
    }

    @Test func theTempoRangeIsTheSlowestAndFastestTempoAtAnyBeat() {
        // Ten beats 0.6 s apart (100 beats per minute), then ten 0.5 s apart (120).
        var times: [Double] = (0..<10).map { 1 + 0.6 * Double($0) }
        for _ in 0..<10 { times.append(times[times.count - 1] + 0.5) }
        let grid = Grid(beats: times.indices.map { Beat(number: $0, time: times[$0]) })

        let accuracy = GridAccuracy.measure(grid, against: OnsetCurve(values: []))

        #expect(accuracy.tempoRange == 100.0...120.0)
        #expect(accuracy.withoutOnset == 20)
    }

    @Test func theReportSaysTheFiguresInWords() {
        let grid = Grid(beats: [Beat(number: 7, time: 65), Beat(number: 8, time: 65.6), Beat(number: 9, time: 66.2, estimated: true)])
        let curve = onsets(seconds: 70, peaks: [(65.004, 5), (65.588, 5)])

        let report = GridAccuracy.measure(grid, against: curve).report()

        #expect(report.contains("3 beats, 1 of them estimated, 2 measured against a drum hit"))
        #expect(report.contains("typical distance from line to hit (median): 8.0 ms"))
        #expect(report.contains("worst: 12.0 ms"))
        #expect(report.contains("at 1:05.6 (beat 8): hit 12.0 ms before the line"))
    }

    /// The measurement itself, on the song `LOCKSTEP_SONG` points to. Point it at another song to
    /// measure that one. It prints the figures and fails only when nothing could be measured: how
    /// close a song comes is a fact about the song to report to Max, not a fault in the code.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCKSTEP_SONG"] != nil))
    func measuresTheGridOfTheSongItIsGiven() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCKSTEP_SONG"]!)
        let song = try await SongImporter.importSong(from: url)
        let found = try await BeatFinder.findBeats(in: song)

        let accuracy = GridAccuracy.measure(found.grid, against: found.cache.onsets)
        let narrow = GridAccuracy.measure(found.grid, against: found.cache.onsets, reach: GridAccuracy.prototypeReach)
        // "About 20 ms" is read as up to 22 ms. The typical distance is compared as it is printed.
        let typicalMet = (accuracy.median * 10_000).rounded() <= 60
        let worstMet = accuracy.worst <= 0.022
        print("""

            GRID ACCURACY for \(url.lastPathComponent) (\(GridAccuracy.songTime(song.duration)) long)
            Each beat line against the strongest onset within 35 ms of it:
            \(accuracy.report())
            The same, searching only 20 ms either side as the prototype did:
              typical \(GridAccuracy.milliseconds(narrow.median)), worst \(GridAccuracy.milliseconds(narrow.worst)), \(narrow.measured.count) beats measured
            Target: typical 6 ms or better: \(typicalMet ? "MET" : "MISSED"). Worst about 20 ms: \(worstMet ? "MET" : "MISSED").

            """)
        #expect(found.grid.beats.count > 0)
        #expect(accuracy.measured.count > 0)
    }
}

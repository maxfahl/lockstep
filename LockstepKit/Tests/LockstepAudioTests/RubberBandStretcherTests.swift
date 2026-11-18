import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

@Suite struct RubberBandStretcherTests {
    private let stretcher = RubberBandStretcher()
    /// The stretch tolerance in samples.
    private let tolerance = RubberBandStretcher.toleranceSeconds * 48_000

    // MARK: The checks the plan lists

    @Test func oneSecondOfToneBecomesExactlyOneSecondAndATenthAtTheSamePitch() {
        let tone = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }

        let longer = stretcher.stretch(tone, keyFrames: [], outputLength: 52_800)

        #expect(longer.count == 52_800)
        // Measured 440.00006 Hz, away from the two ends.
        #expect(abs(StretchFixtures.frequency(of: longer[5280..<47_520]) - 440) < 0.05)
        // As loud as it was: measured 0.997 of the tone.
        #expect(abs(StretchFixtures.loudness(longer) / StretchFixtures.loudness(tone) - 1) < 0.01)
    }

    @Test func clickFollowsItsKeyFrame() {
        var sound = [Float](repeating: 0, count: 48_000)
        sound[24_000] = 0.8

        let result = stretcher.stretch(sound, keyFrames: [(source: 24_000, target: 28_800)], outputLength: 52_800)

        #expect(result.count == 52_800)
        // Half a second in the sound belongs at 0.6 s in the result. Measured: on the sample.
        let found = StretchFixtures.peak(in: result, near: 28_800, search: 20_000)
        #expect(abs(Double(found - 28_800)) <= tolerance)
    }

    @Test func mapThatChangesNothingGivesTheSoundBack() {
        var random = StretchFixtures.Random(state: 5)
        let run = StretchFixtures.run(&random)
        let length = run.voiced.count

        let plain = stretcher.stretch(run.voiced, keyFrames: [], outputLength: length)
        let withFrames = stretcher.stretch(
            run.voiced, keyFrames: [(length / 3, length / 3), (length / 2, length / 2)], outputLength: length)

        for result in [plain, withFrames] {
            #expect(result.count == length)
            #expect(StretchFixtures.correlation(run.voiced, result) > 0.99)
            // It is in fact the same samples, and not delayed: the largest difference measured was 0.00007.
            #expect(zip(run.voiced, result).allSatisfy { abs($0 - $1) < 0.001 })
        }
    }

    @Test func middleOfThreeSyllablesMovesAndTheOuterTwoStay() {
        // Three syllables of 200 ms that run together, at 120, 160 and 100 Hz.
        let periods = [400, 300, 480]
        let run = periods.flatMap { StretchFixtures.syllable(period: $0, count: 9600) }
        // The middle one starts 25 ms later. The third stays, so the run keeps its length.
        let places = [(source: 0, target: 0), (source: 9600, target: 10_800), (source: 19_200, target: 19_200)]

        let result = stretcher.stretch(run, keyFrames: Array(places.dropFirst()), outputLength: run.count)

        #expect(result.count == 28_800)
        // Measured: the first starts 0.1 ms late, the middle one lands 1.4 ms early, the third 0.1 ms late.
        for (place, period) in zip(places, periods) {
            let before = StretchFixtures.onset(in: run, near: place.source, period: period) - Double(place.source)
            let after = StretchFixtures.onset(in: result, near: place.target, period: period) - Double(place.target)
            #expect(abs(after - before) <= tolerance)
        }
        // As loud as it was: measured 0.985.
        #expect(abs(StretchFixtures.loudness(result) / StretchFixtures.loudness(run) - 1) < 0.03)
    }

    // MARK: The stretch tolerance

    /// How far the key frames of made-up runs land from their targets, in samples: once for the start of a voiced
    /// syllable at every key frame and once for a click there.
    private func landings(runs: Int) -> (onsets: [Double], clicks: [Double]) {
        var random = StretchFixtures.Random(state: 20_261_113)
        var onsets: [Double] = []
        var clicks: [Double] = []
        for _ in 0..<runs {
            let run = StretchFixtures.run(&random)
            let voiced = stretcher.stretch(run.voiced, keyFrames: run.keyFrames, outputLength: run.outputLength)
            let clicked = stretcher.stretch(run.clicks, keyFrames: run.keyFrames, outputLength: run.outputLength)
            #expect(voiced.count == run.outputLength)
            for (frame, period) in zip(run.keyFrames, run.periods) {
                // The measure is a little late on any sound, so it is taken on the sound that went in as well.
                let before = StretchFixtures.onset(in: run.voiced, near: frame.source, period: period)
                let after = StretchFixtures.onset(in: voiced, near: frame.target, period: period)
                onsets.append(abs((after - Double(frame.target)) - (before - Double(frame.source))))
                clicks.append(Double(abs(StretchFixtures.peak(in: clicked, near: frame.target) - frame.target)))
            }
        }
        return (onsets, clicks)
    }

    @Test func keyFramesOfTwentyMadeUpRunsLandWithinTheTolerance() throws {
        let landed = landings(runs: 20)

        #expect(landed.onsets.count == 64)
        // Measured: voiced starts at most 6.8 ms off, clicks at most 1.1 ms.
        #expect(try #require(landed.onsets.max()) <= tolerance)
        #expect(try #require(landed.clicks.max()) <= 2.5 * 48)
    }

    /// The measurement the tolerance comes from. It takes two minutes, so it runs only when asked for:
    /// `LOCKSTEP_STRETCH_WIDE=1 swift test --package-path LockstepKit --filter keyFramesOfSixHundred`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCKSTEP_STRETCH_WIDE"] != nil))
    func keyFramesOfSixHundredMadeUpRunsLandWithinTheTolerance() throws {
        let landed = landings(runs: 600)
        func milliseconds(_ samples: Double) -> String { String(format: "%.2f ms", samples / 48) }
        for (name, values) in [("voiced starts", landed.onsets), ("clicks", landed.clicks)] {
            let sorted = values.sorted()
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            print(
                "Stretch landing, \(name), \(sorted.count) key frames: worst \(milliseconds(sorted[sorted.count - 1])),",
                "99 in 100 within \(milliseconds(sorted[sorted.count * 99 / 100])), mean \(milliseconds(mean))")
        }
        let twenty = landings(runs: 20)
        print(
            "Stretch landing, the twenty runs of the test: voiced starts worst",
            milliseconds(try #require(twenty.onsets.max())) + ", clicks worst",
            milliseconds(try #require(twenty.clicks.max())))

        #expect(try #require(landed.onsets.max()) <= tolerance)
        #expect(try #require(landed.clicks.max()) <= 2.5 * 48)
    }

    // MARK: What the code that builds the tightened sound relies on

    @Test func itIsAStretcherForTheCodeThatBuildsTheTightenedSound() {
        let anyStretcher: any TimeStretcher = RubberBandStretcher()
        let voice = StretchFixtures.voice(period: 300, count: 4800)

        #expect(anyStretcher.stretch(voice, keyFrames: [(source: 2400, target: 2700)], outputLength: 5000).count == 5000)
    }

    @Test func partsThatKeepTheirLengthComeBackAsTheSamplesThatWentIn() {
        // Four syllables of 200 ms that run together. Only the start of the third moves, by 25 ms: the first and
        // the fourth keep their length and their place.
        let run = [400, 300, 480, 350].flatMap { StretchFixtures.syllable(period: $0, count: 9600) }

        let result = stretcher.stretch(
            run, keyFrames: [(9600, 9600), (19_200, 20_400), (28_800, 28_800)], outputLength: run.count)

        // The first syllable is the recording, sample for sample, up to 30 ms before the part that changes.
        // Measured: the largest difference is 0.00003.
        #expect(zip(run[..<8000], result[..<8000]).allSatisfy { abs($0 - $1) < 0.001 })
        // The changed part really changed.
        #expect(StretchFixtures.correlation(run[18_000..<22_000], result[18_000..<22_000]) < 0.9)
        // And the fourth is the recording again, sample for sample, from 25 ms after the changed part to the
        // very end. Measured: the largest difference is 0.0000007. This is what lets the last 10 ms of a
        // stretched piece be faded into the recorded sound: the two lie on each other.
        #expect(zip(run[30_000...], result[30_000...]).allSatisfy { abs($0 - $1) < 0.001 })
        // In the 25 ms between, the engine goes over from the one to the other: like the recording
        // (measured 0.998) and as loud (0.998), but not the same samples.
        #expect(StretchFixtures.correlation(run[28_800..<30_000], result[28_800..<30_000]) > 0.95)
    }

    /// Made-up maps of 2 to 8 parts of 20 to 300 ms. Three in ten parts keep their length, the others are made
    /// up to 40 percent longer or shorter, and the last part always keeps its length and is 50 ms or longer.
    private func mapsWithPartsThatKeepTheirLength(_ count: Int) -> [(length: Int, keyFrames: [(source: Int, target: Int)], outputLength: Int)] {
        var random = StretchFixtures.Random(state: 77)
        return (0..<count).map { _ in
            let parts = 2 + Int(random.next() * 7)
            var source = 0
            var target = 0
            var keyFrames: [(source: Int, target: Int)] = []
            for index in 0..<parts {
                let isLast = index == parts - 1
                let length = Int(random.next(in: (isLast ? 2400 : 960)...14_400))
                let keeps = isLast || (index > 0 && random.next() < 0.3)
                let ratio = keeps ? 1 : random.next(in: (1 / 1.4)...1.4)
                source += length
                target += max(1, Int((Double(length) * ratio).rounded()))
                if !isLast { keyFrames.append((source, target)) }
            }
            return (source, keyFrames, target)
        }
    }

    @Test func endOfAStretchedPieceLiesOnTheRecordingWhenItsLastPartKeepsItsLength() {
        // This is how the code that builds the tightened sound calls a stretcher: the part after the last
        // syllable of a run only moves, and the last 10 ms are faded into the recording.
        for (index, map) in mapsWithPartsThatKeepTheirLength(40).enumerated() {
            let voice = StretchFixtures.voice(period: 250 + 5 * index, count: map.length)

            let result = stretcher.stretch(voice, keyFrames: map.keyFrames, outputLength: map.outputLength)

            #expect(result.count == map.outputLength)
            // Measured over 71 such maps: the largest difference in the last 10 ms is 0.00008.
            #expect(zip(voice[(map.length - 480)...], result[(map.outputLength - 480)...]).allSatisfy { abs($0 - $1) < 0.001 })
        }
    }

    @Test func startOfAStretchedPieceLiesOnTheRecording() {
        // Where the stretch starts at the very first sample, the first 10 ms are faded in from the recording, so
        // the two must still lie on each other there. Measured: a likeness of 0.92 to 0.99.
        for length in [38_400, 60_000, 34_286, 67_200] {
            for period in [533, 350, 218] {
                let voice = StretchFixtures.voice(period: period, count: 48_000)

                let result = stretcher.stretch(voice, keyFrames: [], outputLength: length)

                #expect(StretchFixtures.correlation(voice[..<480], result[..<480]) > 0.85)
            }
        }
    }

    @Test func stretchedSoundIsAsLoudAsItWas() {
        for length in [38_400, 60_000, 34_286, 67_200] {
            for period in [533, 350, 218] {
                let voice = StretchFixtures.voice(period: period, count: 48_000)
                let loud = StretchFixtures.loudness(voice)

                let result = stretcher.stretch(voice, keyFrames: [], outputLength: length)

                // Measured: within 0.8 percent for every one of these.
                #expect(abs(StretchFixtures.loudness(result) / loud - 1) < 0.015)
                // The ends are not faded and not delayed. They are the weakest place, because the stretch
                // starts and stops there at once: the outer 10 ms measured between 0.78 and 1.18 of the same
                // 10 ms of the voice.
                let start = StretchFixtures.loudness(result[..<480]) / StretchFixtures.loudness(voice[..<480])
                let end = StretchFixtures.loudness(result[(length - 480)...]) / StretchFixtures.loudness(voice[47_520...])
                #expect((0.65...1.35).contains(start))
                #expect((0.65...1.35).contains(end))
            }
        }
    }

    @Test func anyLengthFromOneSampleUpGivesTheLengthAskedFor() {
        let voice = StretchFixtures.voice(period: 320, count: 6000)
        let lengths = [
            (1, 1), (1, 2), (1, 3), (2, 3), (3, 2), (48, 48), (48, 60), (240, 300), (240, 192), (480, 600),
            (960, 1200), (2400, 3000), (4800, 6000), (5000, 3600),
        ]
        for (count, outputLength) in lengths {
            let piece = Array(voice[700..<(700 + count)])
            let highest = piece.map { abs($0) }.max() ?? 0

            let result = stretcher.stretch(piece, keyFrames: [], outputLength: outputLength)

            #expect(result.count == outputLength)
            #expect(result.allSatisfy { $0.isFinite })
            // Nothing runs away, and a short piece does not fade away either. Measured: the highest peak is
            // 0.6 to 1.1 times the highest of the piece, and the loudness 3.9 dB lower at worst.
            #expect(result.allSatisfy { abs($0) <= 2 * highest })
            #expect(StretchFixtures.loudness(result) > 0.5 * StretchFixtures.loudness(piece))
            // A piece that keeps its length comes back as it was, however short.
            if count == outputLength { #expect(zip(piece, result).allSatisfy { abs($0 - $1) < 0.001 }) }
        }
        #expect(stretcher.stretch(voice, keyFrames: [], outputLength: 0).isEmpty)
        #expect(stretcher.stretch([], keyFrames: [], outputLength: 3) == [0, 0, 0])
    }

    @Test func stretchFarBeyondWhatTheLogicAsksForStillComesBack() {
        // The logic never asks for more than 40 percent. A call far outside that must still give the length
        // asked for and must not stop the app.
        let voice = StretchFixtures.voice(period: 300, count: 9600)
        let calls: [(count: Int, keyFrames: [(source: Int, target: Int)], outputLength: Int)] = [
            (48, [], 4800), (9600, [], 96), (9600, [(4800, 480)], 5280), (9600, [(4800, 24_000)], 28_800),
            (9600, [(100, 4000), (9000, 4100)], 4200),
        ]
        for call in calls {
            let result = stretcher.stretch(Array(voice[..<call.count]), keyFrames: call.keyFrames, outputLength: call.outputLength)

            #expect(result.count == call.outputLength)
            #expect(result.allSatisfy { $0.isFinite && abs($0) < 4 })
        }
    }

    @Test func keyFramesThatCannotHoldAreLeftOut() {
        let voice = StretchFixtures.voice(period: 300, count: 24_000)
        let good = [(source: 8000, target: 9000), (source: 16_000, target: 16_500)]
        // On an end, outside the sound, going backwards in the result, and one given twice.
        let bad = [(0, 0), (24_000, 26_400), (30_000, 31_000), (12_000, 8500), (16_000, 16_500), (-5, 100)]

        let expected = stretcher.stretch(voice, keyFrames: good, outputLength: 26_400)
        let result = stretcher.stretch(voice, keyFrames: (bad + good).reversed(), outputLength: 26_400)

        #expect(result == expected)
    }

    @Test func sameCallGivesTheSameAnswerFromManyTasksAtOnce() async {
        var random = StretchFixtures.Random(state: 11)
        let run = StretchFixtures.run(&random)
        let stretcher = stretcher
        let expected = stretcher.stretch(run.voiced, keyFrames: run.keyFrames, outputLength: run.outputLength)

        let results = await withTaskGroup(of: [Float].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    stretcher.stretch(run.voiced, keyFrames: run.keyFrames, outputLength: run.outputLength)
                }
            }
            var all: [[Float]] = []
            for await result in group { all.append(result) }
            return all
        }

        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == expected })
    }

    // MARK: The engine does what the plan worked out

    /// How many of the engine's steps were not the ones the plan worked out beforehand: of another length, or
    /// with the result at another sample than the plan's count says.
    private func stepsOffThePlan(_ plan: StretchPlan, _ steps: [(length: Int, written: Int)]) -> Int {
        var count = StepCount()
        var change = 0
        var wrong = 0
        for step in steps {
            while change + 1 < plan.changes.count, plan.changes[change + 1].place <= count.taken { change += 1 }
            count.take(plan.changes[change].step, ratio: plan.changes[change].ratio)
            // The engine throws away what it writes before its first sample, half a window, so its own count of
            // what it has given starts later.
            let given = count.written - StretchPlan.window / 2
            if step.length != plan.changes[change].step || (given > 256 && step.written != given) { wrong += 1 }
        }
        return wrong
    }

    @Test func engineTakesTheStepsThePlanWorkedOut() throws {
        // The plan is made by doing the engine's own sums beforehand. If a later version of the library did
        // them differently, key frames would land a little less exactly and nothing else would show it.
        var random = StretchFixtures.Random(state: 20_261_113)
        var steps = 0
        for _ in 0..<10 {
            let run = StretchFixtures.run(&random)
            let done = stretcher.run(run.voiced, keyFrames: run.keyFrames, outputLength: run.outputLength)
            #expect(stepsOffThePlan(try #require(done.plan), done.steps) == 0)
            steps += done.steps.count
        }
        for (index, map) in mapsWithPartsThatKeepTheirLength(20).enumerated() {
            let voice = StretchFixtures.voice(period: 250 + 5 * index, count: map.length)
            let done = stretcher.run(voice, keyFrames: map.keyFrames, outputLength: map.outputLength)
            #expect(stepsOffThePlan(try #require(done.plan), done.steps) == 0)
            steps += done.steps.count
        }
        // Measured: none of 170,026 steps in the 600 runs of the tolerance, and none of 59,608 in 400 maps with
        // parts down to 2 ms.
        #expect(steps > 3000)
    }

    @Test func mirroredPlacesGoBackAndForthThroughThePiece() {
        #expect((-5...8).map { RubberBandStretcher.mirrored($0, in: 4) } == [1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1, 0, 1, 2])
        #expect((-2...2).map { RubberBandStretcher.mirrored($0, in: 1) } == [0, 0, 0, 0, 0])
    }
}

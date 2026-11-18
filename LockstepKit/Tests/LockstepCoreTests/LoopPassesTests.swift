import Foundation
import Testing
@testable import LockstepCore

/// A loop of two seconds that starts ten seconds into the song. The song has no beats in these tests, so a bar
/// is two seconds (96,000 samples) and a beat half a second (24,000 samples).
private let loop = LoopRegion(startSample: 480_000, lengthSamples: 96_000)!

/// A capture that began with two seconds of count-in, eight seconds into the song: the loop's start arrives at
/// its sample 96,000, and the loop comes round at 192,000, 288,000 and 384,000.
private func capture(length: Int, delay: Double = 0) -> Recording {
    Recording(lengthSamples: length, rawStart: 8.0, delay: delay)
}

/// A line of one and a quarter seconds that starts 50 ms after the loop's start, in the pass that begins at `boundary`.
private func line(in boundary: Int) -> Range<Int> {
    boundary + 2_400..<boundary + 62_400
}

@Suite("LoopPasses")
struct LoopPassesTests {
    // MARK: The plain rule

    @Test("The capture is divided at every loop boundary, and the last pass ends where the capture does")
    func rangesWithAShortLastPass() {
        let ranges = LoopPasses.ranges(captureLength: 300_000, originSample: 50_000, loopLength: 96_000)
        #expect(ranges == [50_000..<146_000, 146_000..<242_000, 242_000..<300_000])
    }

    @Test("A capture that ends exactly on a boundary has no empty pass after it")
    func rangesEndingOnABoundary() {
        let ranges = LoopPasses.ranges(captureLength: 242_000, originSample: 50_000, loopLength: 96_000)
        #expect(ranges == [50_000..<146_000, 146_000..<242_000])
    }

    @Test("A capture stopped during the first pass is one short pass, and one stopped before the loop's start is none")
    func rangesOfAShortCapture() {
        #expect(LoopPasses.ranges(captureLength: 60_000, originSample: 50_000, loopLength: 96_000) == [50_000..<60_000])
        #expect(LoopPasses.ranges(captureLength: 50_000, originSample: 50_000, loopLength: 96_000).isEmpty)
        #expect(LoopPasses.ranges(captureLength: 40_000, originSample: 50_000, loopLength: 96_000).isEmpty)
    }

    @Test("The loop's start arrives later in the capture by the measured delay")
    func originIncludesTheDelay() {
        #expect(LoopPasses.originSample(of: capture(length: 400_000), loopStart: loop.start) == 96_000)
        // 200 ms of delay, as with AirPods: 9,600 samples later.
        #expect(LoopPasses.originSample(of: capture(length: 400_000, delay: 0.2), loopStart: loop.start) == 105_600)
    }

    // MARK: Whole recordings

    @Test("Three passes and a stop just after become three takes at the same place, the third one active")
    func threePasses() {
        let voice = [line(in: 96_000), line(in: 192_000), line(in: 288_000)]
        let split = LoopPasses.split(capture(length: 394_000), voicedStretches: voice, loop: loop, grid: nil)
        #expect(split.passes.map { $0.index } == [0, 1, 2])
        #expect(split.passes.map { $0.boundary } == [96_000, 192_000, 288_000])
        // The passes share the capture without a gap. The first holds the count-in, like any recording.
        #expect(split.passes.map { $0.samples } == [0..<192_000, 192_000..<288_000, 288_000..<384_000])
        // Each clip is the voice with 50 ms before it and 150 ms after it, at the same place in every pass.
        #expect(split.passes.map { $0.clip } == [96_000..<165_600, 192_000..<261_600, 288_000..<357_600])
        #expect(split.passes.allSatisfy { $0.isComplete })
        #expect(split.active == 2)
    }

    @Test("The start time of each pass puts its first loop sample exactly on the loop's start")
    func passesSitOnTheLoopStart() {
        for delay in [0.0, 0.2] {
            let taken = capture(length: 500_000, delay: delay)
            let origin = LoopPasses.originSample(of: taken, loopStart: loop.start)
            // A word before every boundary, so the passes do not begin on their boundaries.
            let voice = (0..<4).flatMap { pass -> [Range<Int>] in
                let boundary = origin + pass * 96_000
                return [boundary - 7_200..<boundary - 2_400, line(in: boundary)]
            }
            let split = LoopPasses.split(taken, voicedStretches: voice, loop: loop, grid: nil)
            #expect(split.passes.count == 4)
            for pass in split.passes {
                let recording = Recording(
                    lengthSamples: pass.samples.count,
                    rawStart: LoopPasses.rawStart(of: pass, loopStart: loop.start, delay: delay),
                    delay: delay
                )
                let loopSampleInFile = pass.boundary - pass.samples.lowerBound
                #expect(abs(recording.songTime(ofSample: loopSampleInFile) - loop.start) < 1e-9)
                #expect(pass.boundary == origin + pass.index * 96_000)
            }
        }
    }

    @Test("A word said just before the loop's start belongs to the pass that follows it")
    func pickUpGoesToTheNextPass() {
        // 150 ms before the loop comes round, a word of 100 ms. The line before ended half a second earlier.
        let pickUp = 184_800..<189_600
        let voice = [line(in: 96_000), pickUp, line(in: 192_000)]
        let split = LoopPasses.split(capture(length: 290_000), voicedStretches: voice, loop: loop, grid: nil)
        #expect(split.passes.count == 2)
        // The cut is 50 ms before the word, so the second take starts with it, before the loop's start.
        #expect(split.passes[0].samples == 0..<182_400)
        #expect(split.passes[1].samples == 182_400..<288_000)
        #expect(split.passes[1].clip == 182_400..<261_600)
        // And the first take ends after its own line, without the word.
        #expect(split.passes[0].clip == 96_000..<165_600)
    }

    @Test("With no real pause before it, a word in the last beat still goes to the next pass")
    func pickUpAfterAShortBreath() {
        // The line runs until a quarter of a second before the loop comes round. A breath of 125 ms, then the word.
        let voice = [98_400..<180_000, 186_000..<190_800, 192_480..<250_000]
        let cut = LoopPasses.cut(before: 192_000, voice: voice, window: 48_000, beat: 24_000)
        #expect(cut == 183_600)
    }

    @Test("A voice that sounds right across the loop's start is cut at the start")
    func voiceAcrossTheBoundary() {
        let voice = [98_400..<250_000]
        #expect(LoopPasses.cut(before: 192_000, voice: voice, window: 48_000, beat: 24_000) == 192_000)
        let split = LoopPasses.split(capture(length: 290_000), voicedStretches: voice, loop: loop, grid: nil)
        #expect(split.passes.map { $0.clip } == [96_000..<192_000, 192_000..<257_200])
    }

    @Test("Silence around the loop's start is cut at the start, and never later")
    func silenceAroundTheBoundary() {
        // The next line starts 10 ms after the boundary: the cut leaves it its 50 ms where the pause allows.
        let early = LoopPasses.cut(before: 192_000, voice: [line(in: 96_000), 192_480..<250_000], window: 48_000, beat: 24_000)
        #expect(early == 190_080)
        // The next line starts half a second after the boundary.
        let late = LoopPasses.cut(before: 192_000, voice: [line(in: 96_000), 216_000..<250_000], window: 48_000, beat: 24_000)
        #expect(late == 192_000)
        // Nothing follows at all.
        #expect(LoopPasses.cut(before: 192_000, voice: [line(in: 96_000)], window: 48_000, beat: 24_000) == 192_000)
    }

    @Test("A pass in which nothing was said is left out")
    func silentPassIsDropped() {
        let voice = [line(in: 96_000), line(in: 288_000)]
        let split = LoopPasses.split(capture(length: 400_000), voicedStretches: voice, loop: loop, grid: nil)
        #expect(split.passes.map { $0.index } == [0, 2])
        // The active take is the third pass, the last one with a voice that ran its full length.
        #expect(split.active == 1)
    }

    @Test("The pass that was stopped on its way is kept with a voice and a beat of length, and is not the active take")
    func unfinishedLastPass() {
        let voice = [line(in: 96_000), line(in: 192_000), line(in: 288_000), 386_400..<410_000]
        // Stopped 30,000 samples into the fourth pass: more than a beat.
        let kept = LoopPasses.split(capture(length: 414_000), voicedStretches: voice, loop: loop, grid: nil)
        #expect(kept.passes.map { $0.index } == [0, 1, 2, 3])
        #expect(kept.passes[3].isComplete == false)
        #expect(kept.passes[3].samples == 384_000..<414_000)
        #expect(kept.active == 2)
        // Stopped 20,000 samples into it: shorter than a beat, so it goes.
        let short = [line(in: 96_000), line(in: 192_000), line(in: 288_000), 386_400..<400_000]
        let dropped = LoopPasses.split(capture(length: 404_000), voicedStretches: short, loop: loop, grid: nil)
        #expect(dropped.passes.map { $0.index } == [0, 1, 2])
        #expect(dropped.active == 2)
    }

    @Test("With no voice found anywhere, every full pass is kept whole")
    func noVoiceAtAll() {
        let split = LoopPasses.split(capture(length: 300_000), voicedStretches: [], loop: loop, grid: nil)
        #expect(split.passes.map { $0.clip } == [96_000..<192_000, 192_000..<288_000])
        #expect(split.active == 1)
    }

    @Test("A word during the count-in leads into the first pass, as in any take")
    func leadInToTheFirstPass() {
        // 150 ms before the loop's start, a word of 100 ms.
        let voice = [88_800..<93_600, line(in: 96_000), line(in: 192_000)]
        let split = LoopPasses.split(capture(length: 290_000), voicedStretches: voice, loop: loop, grid: nil)
        #expect(split.passes[0].clip == 86_400..<165_600)
        #expect(split.passes[0].boundary == 96_000)
    }

    @Test("The delay moves every boundary, so the end of a pass does not land in the next take")
    func delayMovesTheBoundaries() {
        // With 200 ms of delay everything arrives 9,600 samples later in the capture.
        let voice = [line(in: 105_600), line(in: 201_600)]
        let split = LoopPasses.split(capture(length: 300_000, delay: 0.2), voicedStretches: voice, loop: loop, grid: nil)
        #expect(split.passes.map { $0.boundary } == [105_600, 201_600])
        #expect(split.passes.map { $0.clip } == [105_600..<175_200, 201_600..<271_200])
    }

    @Test("A recording in which the loop never came round is a take like any other and gives no passes")
    func loopNeverCameRound() {
        let split = LoopPasses.split(capture(length: 150_000), voicedStretches: [line(in: 96_000)], loop: loop, grid: nil)
        #expect(split.passes.isEmpty)
        #expect(split.active == nil)
    }
}

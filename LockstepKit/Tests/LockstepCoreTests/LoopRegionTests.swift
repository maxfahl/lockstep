import Foundation
import Testing
@testable import LockstepCore

/// A song whose tempo drifts: every beat is a little longer than the one before it, as in a song made by Suno.
/// Beat `n` (numbers from 0) is at `0.5 + 0.6 n + 0.002 n²` seconds, and every fourth beat from beat 0 starts a bar.
private func driftingGrid(beats count: Int = 64) -> Grid {
    Grid(
        beats: (0..<count).map { Beat(number: $0, time: beatTime($0)) },
        barStartNumber: 0
    )
}

private func beatTime(_ number: Int) -> Double {
    0.5 + 0.6 * Double(number) + 0.002 * Double(number * number)
}

private func sample(_ seconds: Double) -> Int {
    Int((seconds * Lockstep.sampleRate).rounded())
}

/// Three minutes of song.
private let songLength = 180 * 48_000

@Suite("LoopRegion")
struct LoopRegionTests {
    // MARK: Snapping to whole bars

    @Test("A stretch marked inside bars snaps its start down and its end up to bar starts, on a drifting grid")
    func snapsOutwardToBarStarts() throws {
        let grid = driftingGrid()
        // From a little after beat 9 (in the bar that starts on beat 8) to a little after beat 17 (the bar from 16 to 20).
        let stretch = (beatTime(9) + 0.1)...(beatTime(17) + 0.2)
        let region = try #require(LoopRegion.snapped(stretch, to: grid, songLengthSamples: songLength))
        #expect(region.startSample == sample(beatTime(8)))
        #expect(region.endSample == sample(beatTime(20)))
        // Three bars, each as long as the drifting beats make it: not three times the first one.
        #expect(region.lengthSamples == sample(beatTime(20)) - sample(beatTime(8)))
        #expect(region.lengthSamples != 3 * (sample(beatTime(12)) - sample(beatTime(8))))
    }

    @Test("Edges that already stand on bar starts stay where they are")
    func keepsEdgesOnBarStarts() throws {
        let grid = driftingGrid()
        let region = try #require(LoopRegion.snapped(beatTime(4)...beatTime(8), to: grid, songLengthSamples: songLength))
        #expect(region.startSample == sample(beatTime(4)))
        #expect(region.endSample == sample(beatTime(8)))
    }

    @Test("A short stretch inside one bar becomes that whole bar")
    func shortStretchBecomesOneBar() throws {
        let grid = driftingGrid()
        let stretch = (beatTime(13) + 0.05)...(beatTime(13) + 0.15)
        let region = try #require(LoopRegion.snapped(stretch, to: grid, songLengthSamples: songLength))
        #expect(region.startSample == sample(beatTime(12)))
        #expect(region.endSample == sample(beatTime(16)))
    }

    @Test("Without beats the stretch is used as it is")
    func usedAsItIsWithoutBeats() throws {
        let region = try #require(LoopRegion.snapped(10.3...14.7, to: nil, songLengthSamples: songLength))
        #expect(region.startSample == sample(10.3))
        #expect(region.endSample == sample(14.7))
        let empty = try #require(LoopRegion.snapped(10.3...14.7, to: Grid(), songLengthSamples: songLength))
        #expect(empty == region)
    }

    @Test("An edge outside the beats is used as it is, and the other edge still snaps")
    func edgeOutsideTheBeatsStays() throws {
        let grid = driftingGrid(beats: 16)
        // The start lies before the first beat. The end lies inside the bar from beat 4 to beat 8.
        let before = try #require(LoopRegion.snapped(0.2...(beatTime(5) + 0.1), to: grid, songLengthSamples: songLength))
        #expect(before.startSample == sample(0.2))
        #expect(before.endSample == sample(beatTime(8)))
        // The end lies after the last beat.
        let after = try #require(
            LoopRegion.snapped((beatTime(9) + 0.1)...(beatTime(15) + 3), to: grid, songLengthSamples: songLength)
        )
        #expect(after.startSample == sample(beatTime(8)))
        #expect(after.endSample == sample(beatTime(15) + 3))
    }

    @Test("An edge in a stretch that was left without beats is not moved to a bar far away")
    func edgeInAnEmptyStretchStays() throws {
        // Beats 0 to 7, then nothing until beats 20 to 31: the numbers skip across the empty stretch.
        let beats = (Array(0..<8) + Array(20..<32)).map { Beat(number: $0, time: beatTime($0)) }
        let grid = Grid(beats: beats, barStartNumber: 0)
        let inTheGap = beatTime(12)
        let region = try #require(
            LoopRegion.snapped(inTheGap...(beatTime(25) + 0.1), to: grid, songLengthSamples: songLength)
        )
        #expect(region.startSample == sample(inTheGap))
        #expect(region.endSample == sample(beatTime(28)))
    }

    @Test("A region shorter than a quarter of a second, or outside the song, is refused")
    func refusesWhatCannotBeLooped() {
        #expect(LoopRegion.snapped(10.0...10.2, to: nil, songLengthSamples: songLength) == nil)
        #expect(LoopRegion(startSample: -1, lengthSamples: 48_000) == nil)
        // A stretch that runs past the end of the song is cut off there.
        let atTheEnd = LoopRegion(from: 179, to: 200, songLengthSamples: songLength)
        #expect(atTheEnd?.endSample == songLength)
        #expect(LoopRegion(from: 179.9, to: 200, songLengthSamples: songLength) == nil)
    }

    // MARK: A song that is cut

    @Test("A loop cannot be made in a part of the song that is cut away")
    func staysInsideWhatIsLeftOfTheSong() throws {
        // Seconds 10 to 100 are left of the song.
        let kept = sample(10)..<sample(100)
        let region = try #require(LoopRegion(from: 4, to: 120, keeping: kept))
        #expect(region.startSample == sample(10))
        #expect(region.endSample == sample(100))
        // A stretch that lies in the cut part alone leaves nothing to loop.
        #expect(LoopRegion(from: 2, to: 9, keeping: kept) == nil)
        #expect(LoopRegion(from: 101, to: 130, keeping: kept) == nil)
        #expect(LoopRegion(from: 9, to: 10.1, keeping: kept) == nil)
    }

    @Test("An edge whose bar start is cut away is used as it is, and the other edge still snaps")
    func doesNotSnapIntoTheCutPart() throws {
        let grid = driftingGrid()
        // The song is cut in the middle of the bar from beat 8 to beat 12, and of the bar from 24 to 28.
        let kept = sample(beatTime(9))..<sample(beatTime(26))
        let atTheStart = try #require(
            LoopRegion.snapped((beatTime(10) + 0.1)...(beatTime(17) + 0.2), to: grid, keeping: kept)
        )
        #expect(atTheStart.startSample == sample(beatTime(10) + 0.1))
        #expect(atTheStart.endSample == sample(beatTime(20)))
        let atTheEnd = try #require(
            LoopRegion.snapped((beatTime(13) + 0.1)...(beatTime(25) + 0.1), to: grid, keeping: kept)
        )
        #expect(atTheEnd.startSample == sample(beatTime(12)))
        #expect(atTheEnd.endSample == sample(beatTime(25) + 0.1))
        // A cut on a bar start leaves that bar start to loop from.
        let onTheBar = sample(beatTime(8))..<sample(beatTime(28))
        let whole = try #require(
            LoopRegion.snapped((beatTime(9) + 0.1)...(beatTime(27) + 0.1), to: grid, keeping: onTheBar)
        )
        #expect(whole.startSample == sample(beatTime(8)))
        #expect(whole.endSample == sample(beatTime(28)))
    }

    @Test("Cutting the song shortens a loop that reaches outside what is left, and removes one with nothing left")
    func isShortenedByACut() throws {
        // A loop from second 10 to second 20.
        let loop = try #require(LoopRegion(startSample: 480_000, lengthSamples: 480_000))
        // Inside what is left, it stays as it is.
        #expect(loop.shortened(to: 0..<songLength) == loop)
        #expect(loop.shortened(to: 480_000..<960_000) == loop)
        // The beginning is cut away up to second 12, or the end from second 15.
        #expect(loop.shortened(to: 576_000..<songLength) == LoopRegion(startSample: 576_000, lengthSamples: 384_000))
        #expect(loop.shortened(to: 0..<720_000) == LoopRegion(startSample: 480_000, lengthSamples: 240_000))
        #expect(loop.shortened(to: 576_000..<720_000) == LoopRegion(startSample: 576_000, lengthSamples: 144_000))
        // Nothing of it is left, or less than can be looped.
        #expect(loop.shortened(to: 1_000_000..<songLength) == nil)
        #expect(loop.shortened(to: 0..<400_000) == nil)
        #expect(loop.shortened(to: 0..<480_000 + 4_800) == nil)
    }

    // MARK: Bar starts as snap points

    @Test("An edge of the marked stretch catches on a bar start that is near, through the snap engine as it is")
    func barStartsAreASnapSource() throws {
        let grid = driftingGrid()
        let engine = SnapEngine(sources: [BarStartSource(grid: grid)])
        let edge = beatTime(12) + 0.03
        let snap = try #require(engine.snap(start: edge, end: edge, tolerance: 0.05))
        #expect(abs(edge + snap.delta - beatTime(12)) < 1e-12)
        #expect(snap.point.kind == .barStart)
        // A beat inside a bar is no snap point, and neither is a bar start that is too far away.
        #expect(engine.snap(start: beatTime(13), end: beatTime(13), tolerance: 0.05) == nil)
        #expect(engine.snap(start: edge, end: edge, tolerance: 0.01) == nil)
        #expect(grid.barStartTimes(in: beatTime(4)...beatTime(12)) == [beatTime(4), beatTime(8), beatTime(12)])
    }

    // MARK: Where the song is

    @Test("Played samples become a place in the song that goes round at the end of the loop")
    func positionGoesRound() throws {
        // A loop of one second, from second 2 to second 3.
        let loop = try #require(LoopRegion(startSample: 96_000, lengthSamples: 48_000))
        // Started inside the loop, half a second in.
        #expect(loop.songSample(afterPlaying: 0, from: 120_000) == 120_000)
        #expect(loop.songSample(afterPlaying: 23_999, from: 120_000) == 143_999)
        // The sample after the last one of the loop is its first.
        #expect(loop.songSample(afterPlaying: 24_000, from: 120_000) == 96_000)
        #expect(loop.songSample(afterPlaying: 24_001, from: 120_000) == 96_001)
        // And again after every full pass, with nothing lost or gained after an hour of them.
        #expect(loop.songSample(afterPlaying: 24_000 + 48_000 - 1, from: 120_000) == 143_999)
        #expect(loop.songSample(afterPlaying: 24_000 + 48_000, from: 120_000) == 96_000)
        #expect(loop.songSample(afterPlaying: 24_000 + 3_600 * 48_000 + 7, from: 120_000) == 96_007)
    }

    @Test("Playback that starts before the loop plays into it and then goes round")
    func playsIntoTheLoop() throws {
        let loop = try #require(LoopRegion(startSample: 96_000, lengthSamples: 48_000))
        #expect(loop.isReached(from: 48_000))
        #expect(loop.songSample(afterPlaying: 50_000, from: 48_000) == 98_000)
        #expect(loop.songSample(afterPlaying: 95_999, from: 48_000) == 143_999)
        #expect(loop.songSample(afterPlaying: 96_000, from: 48_000) == 96_000)
        #expect(loop.songSample(afterPlaying: 96_000 + 5 * 48_000 + 10, from: 48_000) == 96_010)
    }

    @Test("Playback that starts after the loop never loops")
    func playsOnAfterTheLoop() throws {
        let loop = try #require(LoopRegion(startSample: 96_000, lengthSamples: 48_000))
        #expect(!loop.isReached(from: 144_000))
        #expect(loop.songSample(afterPlaying: 100_000, from: 144_000) == 244_000)
        // The last sample of the loop still belongs to it.
        #expect(loop.isReached(from: 143_999))
        #expect(loop.songSample(afterPlaying: 1, from: 143_999) == 96_000)
    }

    @Test("A time between two samples goes round the same way")
    func secondsGoRound() throws {
        let loop = try #require(LoopRegion(startSample: 96_000, lengthSamples: 48_000))
        #expect(loop.songSeconds(forStraight: 1.5) == 1.5)
        #expect(loop.songSeconds(forStraight: 2.75) == 2.75)
        #expect(abs(loop.songSeconds(forStraight: 3.0) - 2.0) < 1e-12)
        #expect(abs(loop.songSeconds(forStraight: 3.25) - 2.25) < 1e-12)
        #expect(abs(loop.songSeconds(forStraight: 62.5) - 2.5) < 1e-9)
    }
}

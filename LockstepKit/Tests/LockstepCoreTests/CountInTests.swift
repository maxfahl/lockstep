import Testing
@testable import LockstepCore

@Suite("CountIn")
struct CountInTests {
    /// `count` beats at one steady spacing, numbered from 0, with beat 0 the first of a bar.
    private func steadyGrid(from start: Double, spacing: Double, count: Int) -> Grid {
        Grid(beats: (0..<count).map { Beat(number: $0, time: start + Double($0) * spacing) })
    }

    private func times(_ clicks: [CountIn.Click]) -> [Double] { clicks.map(\.time) }

    private func near(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    // MARK: The place

    @Test("The place is the beat nearest the playhead")
    func placeSnapsToTheNearestBeat() {
        let grid = steadyGrid(from: 0.25, spacing: 0.5, count: 100)
        #expect(RecordingPlacement.recordPlace(nearest: 10.3, grid: grid) == 10.25)
        #expect(RecordingPlacement.recordPlace(nearest: 10.6, grid: grid) == 10.75)
        #expect(RecordingPlacement.recordPlace(nearest: 10.25, grid: grid) == 10.25)
    }

    @Test("Without beats the place stays where the playhead is")
    func placeStaysPutWithoutBeats() {
        #expect(RecordingPlacement.recordPlace(nearest: 10.3, grid: nil) == 10.3)
        #expect(RecordingPlacement.recordPlace(nearest: 10.3, grid: Grid()) == 10.3)
        // A single beat says nothing about the tempo.
        #expect(RecordingPlacement.recordPlace(nearest: 10.3, grid: Grid(beats: [Beat(number: 0, time: 10.2)])) == 10.3)
        #expect(RecordingPlacement.recordPlace(nearest: -1, grid: nil) == 0)
    }

    @Test("Where the song has no beats the place stays put, and just outside the beats it catches the nearest one")
    func placeOutsideTheBeats() {
        // The first beat is at 20 s and the last at 39.6 s, 0.4 s apart.
        let late = steadyGrid(from: 20, spacing: 0.4, count: 50)
        #expect(RecordingPlacement.recordPlace(nearest: 12, grid: late) == 12)
        #expect(RecordingPlacement.recordPlace(nearest: 19.7, grid: late) == 20)
        #expect(RecordingPlacement.recordPlace(nearest: 50, grid: late) == 50)

        // Standing at the very start of a song whose first beat comes a moment later aims at that beat.
        let song = steadyGrid(from: 0.3, spacing: 0.5, count: 100)
        #expect(RecordingPlacement.recordPlace(nearest: 0, grid: song) == 0.3)

        // A stretch that was left empty, from 10 s to 20 s.
        var gapped = Grid()
        gapped.beats = (0...20).map { Beat(number: $0, time: Double($0) * 0.5) }
            + (0...20).map { Beat(number: 31 + $0, time: 20 + Double($0) * 0.4) }
        #expect(RecordingPlacement.recordPlace(nearest: 15, grid: gapped) == 15)
    }

    // MARK: The count-in

    @Test("With enough bars before the place the count-in starts that many bars back, with a click on every beat")
    func countInWithEnoughBars() {
        let grid = steadyGrid(from: 0.25, spacing: 0.5, count: 100)
        let one = RecordingPlacement.countIn(to: 10.25, bars: 1, grid: grid)
        #expect(one.place == 10.25)
        #expect(one.start == 8.25)
        #expect(one.leadInSeconds == 0)
        #expect(one.songStart == 8.25)
        #expect(one.clicksBeforeSong.isEmpty)
        #expect(times(one.clicks) == [8.25, 8.75, 9.25, 9.75, 10.25])
        // 10.25 s is beat 20, the first of a bar, and so is 8.25 s. The place gets the click to start on.
        #expect(one.clicks.map(\.kind) == [.barStart, .beat, .beat, .beat, .start])

        let two = RecordingPlacement.countIn(to: 10.75, bars: 2, grid: grid)
        #expect(two.start == 6.75)
        #expect(two.clicks.count == 9)
        // 10.75 s is beat 21, the second of its bar: the bars start at 8.25 s and 6.25 s.
        #expect(two.clicks.map(\.kind) == [.beat, .beat, .beat, .barStart, .beat, .beat, .beat, .barStart, .start])
        #expect(RecordingPlacement.countIn(to: 20.25, bars: 4, grid: grid).start == 12.25)
    }

    @Test("Across a tempo change the count-in clicks on the song's real beats")
    func countInFollowsTheRealBeats() {
        let slow = (0...20).map { Double($0) * 0.5 }
        let fast = (1...20).map { 10 + Double($0) * 0.4 }
        let grid = Grid(beats: (slow + fast).enumerated().map { Beat(number: $0.offset, time: $0.element) })
        let countIn = RecordingPlacement.countIn(to: 10.8, bars: 1, grid: grid)
        #expect(times(countIn.clicks) == [9.0, 9.5, 10.0, 10.4, 10.8])
        #expect(countIn.start == 9.0)
    }

    @Test("With too few bars before the place the click counts alone before the song, spaced like its first beats")
    func countInBeforeTheSong() {
        let grid = steadyGrid(from: 0.25, spacing: 0.5, count: 100)
        // One bar before the second beat: three beats are missing before the first one.
        let countIn = RecordingPlacement.countIn(to: 0.75, bars: 1, grid: grid)
        #expect(abs(countIn.start - -1.25) < 1e-9)
        #expect(abs(countIn.leadInSeconds - 1.25) < 1e-9)
        #expect(countIn.songStart == 0)
        #expect(near(times(countIn.clicks), [-1.25, -0.75, -0.25, 0.25, 0.75]))
        #expect(near(times(countIn.clicksBeforeSong), [-1.25, -0.75, -0.25]))
        #expect(countIn.clicks.last == CountIn.Click(time: 0.75, kind: .start))
        // The bars are counted on from the song's beats: beat 0 at 0.25 s starts a bar, and so does 2 s earlier.
        #expect(countIn.clicks.map(\.kind) == [.beat, .beat, .beat, .barStart, .start])

        // Two bars from the very first beat: all of the count-in but its last 0.25 s is before the song.
        let two = RecordingPlacement.countIn(to: 0.25, bars: 2, grid: grid)
        #expect(abs(two.start - -3.75) < 1e-9)
        #expect(two.clicksBeforeSong.count == 8)
        #expect(two.clicks.first?.kind == .barStart)
        #expect(two.clicks[4].kind == .barStart)
    }

    @Test("At the very start of a song without beats the click counts in two seconds a bar")
    func countInBeforeASongWithoutBeats() {
        let countIn = RecordingPlacement.countIn(to: 0, bars: 1, grid: nil)
        #expect(countIn.start == -2)
        #expect(countIn.leadInSeconds == 2)
        #expect(countIn.songStart == 0)
        #expect(times(countIn.clicks) == [-2, -1.5, -1, -0.5, 0])
        #expect(countIn.clicks.map(\.kind) == [.barStart, .beat, .beat, .beat, .start])
        #expect(countIn.clicksBeforeSong.count == 4)

        // In the middle of the song there is enough of it before the place.
        let later = RecordingPlacement.countIn(to: 10, bars: 2, grid: nil)
        #expect(later.start == 6)
        #expect(later.leadInSeconds == 0)
        #expect(later.clicks.count == 9)
    }

    @Test("A count-in that ends exactly one bar into the song starts with the song, with nothing before it")
    func countInThatStartsExactlyAtZero() {
        let grid = steadyGrid(from: 0.25, spacing: 0.5, count: 100)
        let countIn = RecordingPlacement.countIn(to: 2.25, bars: 1, grid: grid)
        #expect(abs(countIn.start - 0.25) < 1e-9)
        // Exactly at zero, also when the walk back misses it by a rounding error.
        let exact = RecordingPlacement.countIn(to: 2, bars: 1, grid: nil)
        #expect(exact.start == 0)
        #expect(exact.leadInSeconds == 0)
        #expect(exact.leadInSamples == 0)
    }

    @Test("Off has no count-in: recording starts at once at the place")
    func countInOff() {
        let grid = steadyGrid(from: 0.25, spacing: 0.5, count: 100)
        let off = RecordingPlacement.countIn(to: 10.25, bars: 0, grid: grid)
        #expect(off == CountIn(place: 10.25, start: 10.25, clicks: []))
        #expect(off.isOff)
        #expect(off.seconds == 0)
        #expect(off.leadInSeconds == 0)
        #expect(off.songLevel(at: 10.25) == 1)
        #expect(off.lengthSamples == 0)
        #expect(!RecordingPlacement.countIn(to: 10.25, bars: 1, grid: grid).isOff)
        #expect(SettingKey<Int>.runUpBars.choices == [0, 1, 2, 4])
        #expect(SettingKey<Int>.runUpBars.fitted(0) == 0)
    }

    // MARK: The fade

    @Test("The song is silent at the start of the count-in, at full level from half of it on, and rises evenly between")
    func songFadesUpOverTheFirstHalf() {
        let countIn = CountIn(place: 12, start: 8)
        #expect(countIn.songLevel(at: 8) == 0)
        #expect(countIn.songLevel(at: 8.5) == 0.25)
        #expect(countIn.songLevel(at: 9) == 0.5)
        #expect(countIn.songLevel(at: 10) == 1)
        #expect(countIn.songLevel(at: 11) == 1)
        #expect(countIn.songLevel(at: 12) == 1)
        #expect(countIn.songLevel(at: 30) == 1)
        #expect(countIn.songLevel(at: 7) == 0)

        // A count-in that begins before the song fades over the same share of itself.
        let early = CountIn(place: 1, start: -1)
        #expect(early.songLevel(at: -1) == 0)
        #expect(early.songLevel(at: -0.5) == 0.5)
        #expect(early.songLevel(at: 0) == 1)
    }

    @Test("In whole samples the count-in counts from its own first sample")
    func countInInSamples() {
        let inside = CountIn(place: 12, start: 8)
        #expect(inside.leadInSamples == 0)
        #expect(inside.songStartSample == 384_000)
        #expect(inside.lengthSamples == 192_000)
        #expect(inside.sample(at: 9) == 48_000)
        #expect(inside.fadeSamples == 96_000)
        #expect(inside.songLevel(atSample: 0) == 0)
        #expect(inside.songLevel(atSample: 48_000) == 0.5)
        #expect(inside.songLevel(atSample: 96_000) == 1)
        #expect(inside.songLevel(atSample: 192_000) == 1)

        let early = CountIn(place: 0.75, start: -1.25)
        #expect(early.leadInSamples == 60_000)
        #expect(early.songStartSample == 0)
        #expect(early.lengthSamples == 96_000)
        #expect(early.sample(at: -1.25) == 0)
        #expect(early.sample(at: 0) == 60_000)
        #expect(early.sample(at: 0.25) == 72_000)
    }
}

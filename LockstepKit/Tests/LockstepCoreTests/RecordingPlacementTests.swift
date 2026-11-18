import Testing
@testable import LockstepCore

@Suite("RecordingPlacement")
struct RecordingPlacementTests {
    /// The clock of a Mac with Apple's own chip: one tick is 125/3 nanoseconds, so 24,000,000 ticks are a second.
    private let appleClock = HostClock(numerator: 125, denominator: 3)
    /// The clock of an older Mac: one tick is a nanosecond.
    private let nanosecondClock = HostClock(numerator: 1, denominator: 1)

    /// Beats one after the other at the given times, numbered from 0.
    private func grid(at times: [Double]) -> Grid {
        Grid(beats: times.enumerated().map { Beat(number: $0.offset, time: $0.element) })
    }

    /// `count` beats at one steady spacing.
    private func steadyGrid(from start: Double, spacing: Double, count: Int) -> Grid {
        grid(at: (0..<count).map { start + Double($0) * spacing })
    }

    // MARK: The clock

    @Test("Ticks become seconds by the clock's own fraction")
    func ticksBecomeSeconds() {
        #expect(appleClock.seconds(from: 0, to: 24_000_000) == 1)
        #expect(appleClock.seconds(from: 1_000, to: 1_000 + 2_400_000) == 0.1)
        #expect(nanosecondClock.seconds(from: 5, to: 1_500_000_005) == 1.5)
        // Backwards in time gives a negative length, not a crash.
        #expect(appleClock.seconds(from: 24_000_000, to: 0) == -1)
        #expect(appleClock.ticks(forSeconds: 0.1) == 2_400_000)
        #expect(nanosecondClock.ticks(forSeconds: 0.02) == 20_000_000)
        #expect(appleClock.ticks(forSeconds: -1) == 0)
    }

    @Test("A Mac that has been awake for a month still measures to the tick")
    func longUptimeKeepsItsPrecision() {
        // Thirty days of ticks, a number too large to keep its last digits as a floating-point value.
        let month: UInt64 = 30 * 24 * 3_600 * 24_000_000 + 7
        #expect(appleClock.seconds(from: month, to: month + 24) == 0.000_001)
        #expect(appleClock.seconds(from: month, to: month + 1) > 0)
    }

    // MARK: Where a recording starts

    @Test("A recording starts where playback started, plus the time until the first recorded sound")
    func rawStartAddsTheTimeBetweenTheTwoStarts() {
        let songStart: UInt64 = 9_000_000_000_000
        // The microphone was first heard 100 ms after the song started playing from 10 s.
        #expect(RecordingPlacement.rawStart(
            playbackStartPosition: 10,
            songStartHostTime: songStart,
            firstInputHostTime: songStart + 2_400_000,
            clock: appleClock
        ) == 10.1)
        // On a Mac whose ticks are nanoseconds the same tick numbers are a different length of time.
        #expect(abs(RecordingPlacement.rawStart(
            playbackStartPosition: 10,
            songStartHostTime: songStart,
            firstInputHostTime: songStart + 2_400_000,
            clock: nanosecondClock
        ) - 10.0024) < 1e-12)
    }

    @Test("A microphone that was heard before the song started gives an earlier start")
    func rawStartCanLieBeforeThePlaybackStart() {
        let songStart: UInt64 = 9_000_000_000_000
        #expect(RecordingPlacement.rawStart(
            playbackStartPosition: 10,
            songStartHostTime: songStart,
            firstInputHostTime: songStart - 1_200_000,
            clock: appleClock
        ) == 9.95)
        // At the very start of the song that is a little before zero.
        #expect(RecordingPlacement.rawStart(
            playbackStartPosition: 0,
            songStartHostTime: songStart,
            firstInputHostTime: songStart - 1_200_000,
            clock: appleClock
        ) == -0.05)
    }

    // MARK: The run-up

    @Test("One bar at a steady 120 beats a minute is two seconds")
    func runUpOfOneBarAtSteadyTempo() {
        let grid = steadyGrid(from: 0.25, spacing: 0.5, count: 100)
        // From a beat, and from a place between two beats.
        #expect(abs(RecordingPlacement.runUpStart(origin: 10.25, bars: 1, grid: grid) - 8.25) < 1e-9)
        #expect(abs(RecordingPlacement.runUpStart(origin: 10.1, bars: 1, grid: grid) - 8.1) < 1e-9)
        #expect(abs(RecordingPlacement.runUpStart(origin: 10.1, bars: 2, grid: grid) - 6.1) < 1e-9)
        #expect(RecordingPlacement.runUpStart(origin: 10.1, bars: 0, grid: grid) == 10.1)
    }

    @Test("Near the start of the song the run-up stops at zero")
    func runUpNearTheSongStartStopsAtZero() {
        let grid = steadyGrid(from: 0.25, spacing: 0.5, count: 100)
        #expect(RecordingPlacement.runUpStart(origin: 1.2, bars: 1, grid: grid) == 0)
        #expect(RecordingPlacement.runUpStart(origin: 0, bars: 1, grid: grid) == 0)
        #expect(RecordingPlacement.runUpStart(origin: -3, bars: 1, grid: grid) == 0)
        // Exactly one bar in, counted with the first spacing before the first beat, is exactly the start.
        #expect(abs(RecordingPlacement.runUpStart(origin: 2.0, bars: 1, grid: grid)) < 1e-9)
    }

    @Test("Across a tempo change the run-up follows the real beats")
    func runUpAcrossATempoChangeUsesTheRealBeats() {
        // Beats half a second apart up to 10 s, then 0.4 s apart.
        let slow = (0...20).map { Double($0) * 0.5 }
        let fast = (1...20).map { 10 + Double($0) * 0.4 }
        let grid = grid(at: slow + fast)

        // Two fast beats and two slow ones lie before 10.8 s: 0.8 s and 1.0 s.
        #expect(abs(RecordingPlacement.runUpStart(origin: 10.8, bars: 1, grid: grid) - 9.0) < 1e-9)
        // From the middle of a fast beat: one and a half fast beats, then two and a half slow ones.
        #expect(abs(RecordingPlacement.runUpStart(origin: 10.6, bars: 1, grid: grid) - 8.75) < 1e-9)
        // Well after the change only the fast beats count.
        #expect(abs(RecordingPlacement.runUpStart(origin: 14.0, bars: 1, grid: grid) - 12.4) < 1e-9)
    }

    @Test("Where the song has no beats the nearest known tempo is used")
    func runUpWhereThereAreNoBeats() {
        // After the last beat (at 49.75 s): the last spacing goes on.
        let steady = steadyGrid(from: 0.25, spacing: 0.5, count: 100)
        #expect(abs(RecordingPlacement.runUpStart(origin: 60, bars: 1, grid: steady) - 58) < 1e-9)

        // Before the first beat (at 20 s): the first spacing is used.
        let late = steadyGrid(from: 20, spacing: 0.4, count: 50)
        #expect(abs(RecordingPlacement.runUpStart(origin: 19, bars: 1, grid: late) - 17.4) < 1e-9)

        // A stretch that was left empty: beats 0.5 s apart up to 10 s, nothing until 20 s, where the beat numbers
        // go on eleven higher, then beats 0.4 s apart.
        var gapped = Grid()
        gapped.beats = (0...20).map { Beat(number: $0, time: Double($0) * 0.5) }
            + (0...20).map { Beat(number: 31 + $0, time: 20 + Double($0) * 0.4) }
        // In the empty stretch, nearer its end, the tempo after it is used.
        #expect(abs(RecordingPlacement.runUpStart(origin: 18, bars: 1, grid: gapped) - 16.4) < 1e-9)
        // Nearer its start, the tempo before it.
        #expect(abs(RecordingPlacement.runUpStart(origin: 12, bars: 1, grid: gapped) - 10) < 1e-9)
        // Two beats after the empty stretch: two fast beats, then two beats' worth of the empty stretch.
        #expect(abs(RecordingPlacement.runUpStart(origin: 20.8, bars: 1, grid: gapped) - 19.2) < 1e-9)
    }

    @Test("Without beats one bar is two seconds")
    func runUpWithoutBeats() {
        #expect(RecordingPlacement.runUpStart(origin: 10, bars: 1, grid: nil) == 8)
        #expect(RecordingPlacement.runUpStart(origin: 10, bars: 2, grid: nil) == 6)
        #expect(RecordingPlacement.runUpStart(origin: 1.5, bars: 1, grid: nil) == 0)
        #expect(RecordingPlacement.runUpStart(origin: 10, bars: 1, grid: Grid()) == 8)
        // A single beat says nothing about the tempo.
        #expect(RecordingPlacement.runUpStart(origin: 10, bars: 1, grid: grid(at: [3])) == 8)
    }

    // MARK: The part of a take that becomes its clip

    /// A take of `seconds` whose first sample was heard at `rawStart` in the song.
    private func take(seconds: Double, rawStart: Double) -> Recording {
        Recording(lengthSamples: Int(seconds * 48_000), rawStart: rawStart)
    }

    @Test("A take with a voice in it becomes a clip of the voice")
    func clipCoversTheVoice() {
        // Recorded from 8 s with the record origin at 10 s. The voice is between the two.
        let recording = take(seconds: 6, rawStart: 8)
        #expect(RecordingPlacement.clipSamples(of: recording, voiced: 120_000..<200_000, origin: 10) == 120_000..<200_000)
    }

    @Test("A voice that starts during the run-up is kept from its start")
    func pickupBeforeTheOriginIsKept() {
        let recording = take(seconds: 6, rawStart: 8)
        // The origin is at sample 96,000 of the take. The line starts half a second before it.
        #expect(RecordingPlacement.clipSamples(of: recording, voiced: 72_000..<200_000, origin: 10) == 72_000..<200_000)
    }

    @Test("A take without any sound becomes a clip from the record origin to the stop")
    func silentTakeRunsFromOriginToStop() {
        let recording = take(seconds: 6, rawStart: 8)
        #expect(RecordingPlacement.clipSamples(of: recording, voiced: nil, origin: 10) == 96_000..<288_000)
        // The delay that was measured moves the take in the song, and the origin with it.
        var calibrated = recording
        calibrated.delay = 0.5
        #expect(RecordingPlacement.clipSamples(of: calibrated, voiced: nil, origin: 10) == 120_000..<288_000)
    }

    @Test("A take at the very start of the song has no run-up to leave out")
    func silentTakeFromTheStartOfTheSong() {
        // The microphone was opened a moment before the song started, so the take begins a little below zero.
        let recording = take(seconds: 3, rawStart: -0.1)
        #expect(RecordingPlacement.clipSamples(of: recording, voiced: nil, origin: 0) == 4_800..<144_000)
    }

    @Test("A take shorter than 0.2 seconds is thrown away")
    func shortTakeIsThrownAway() {
        #expect(RecordingPlacement.clipSamples(of: take(seconds: 0.19, rawStart: 8), voiced: 0..<9_000, origin: 8) == nil)
        #expect(RecordingPlacement.clipSamples(of: take(seconds: 0.2, rawStart: 8), voiced: 0..<9_000, origin: 8) == 0..<9_000)
    }

    @Test("A silent take that was stopped during the run-up is thrown away")
    func silentTakeStoppedInTheRunUpIsThrownAway() {
        // One second was recorded, and the origin is two seconds after the start of the take.
        #expect(RecordingPlacement.clipSamples(of: take(seconds: 1, rawStart: 8), voiced: nil, origin: 10) == nil)
    }

    @Test("A voice range that reaches outside the take is cut to the take")
    func voiceRangeIsCutToTheTake() {
        let recording = take(seconds: 1, rawStart: 8)
        #expect(RecordingPlacement.clipSamples(of: recording, voiced: -500..<60_000, origin: 8) == 0..<48_000)
    }
}

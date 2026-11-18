import LockstepAudio
import Testing

/// The sums that turn the player's count of played samples into a place in the song. A 10-second song is
/// 480,000 samples long.
@Suite("PlaybackPosition")
struct PlaybackPositionTests {
    private let length = 480_000

    @Test("A time in the song becomes the nearest whole sample")
    func secondsToSample() {
        #expect(PlaybackPosition.sample(forSeconds: 0, lengthSamples: length) == 0)
        #expect(PlaybackPosition.sample(forSeconds: 1, lengthSamples: length) == 48_000)
        #expect(PlaybackPosition.sample(forSeconds: 2.5, lengthSamples: length) == 120_000)
        // One sample lasts 1/48,000 s. A time a little before or after a sample belongs to that sample.
        #expect(PlaybackPosition.sample(forSeconds: 100.4 / 48_000, lengthSamples: length) == 100)
        #expect(PlaybackPosition.sample(forSeconds: 99.6 / 48_000, lengthSamples: length) == 100)
    }

    @Test("A jump outside the song lands on its start or its end")
    func seekIsKeptInsideTheSong() {
        #expect(PlaybackPosition.sample(forSeconds: -3, lengthSamples: length) == 0)
        #expect(PlaybackPosition.sample(forSeconds: 10, lengthSamples: length) == length)
        #expect(PlaybackPosition.sample(forSeconds: 12.5, lengthSamples: length) == length)
        #expect(PlaybackPosition.sample(forSeconds: .infinity, lengthSamples: length) == 0)
        #expect(PlaybackPosition.sample(forSeconds: .nan, lengthSamples: length) == 0)
        #expect(PlaybackPosition.sample(forSeconds: 1e300, lengthSamples: length) == length)
        #expect(PlaybackPosition.sample(forSeconds: 4, lengthSamples: 0) == 0)
    }

    @Test("A sample becomes its time in the song")
    func sampleToSeconds() {
        #expect(PlaybackPosition.seconds(forSample: 0) == 0)
        #expect(PlaybackPosition.seconds(forSample: 48_000) == 1)
        #expect(PlaybackPosition.seconds(forSample: 12_000) == 0.25)
        #expect(PlaybackPosition.seconds(forSample: 1) == 1.0 / 48_000)
    }

    @Test("Going from a time to a sample and back gives the same sample")
    func roundTrip() {
        for sample in [0, 1, 2, 47_999, 48_000, 48_001, 123_457, 479_999, 480_000] {
            let seconds = PlaybackPosition.seconds(forSample: sample)
            #expect(PlaybackPosition.sample(forSeconds: seconds, lengthSamples: length) == sample)
        }
    }

    @Test("The position in seconds is exact when the time since the last report is not known")
    func secondsWithoutClock() {
        let position = PlaybackPosition.seconds(
            runStartSample: 96_000, playerSample: 4_800, secondsSinceReport: 0, lengthSamples: length
        )
        #expect(position == 2.1)
        #expect(PlaybackPosition.sample(forSeconds: position, lengthSamples: length) == 100_800)
    }

    @Test("Between two reports the position moves on with the clock")
    func secondsBetweenReports() {
        // 4 ms after the block that starts at 2.1 s began to come out.
        let later = PlaybackPosition.seconds(
            runStartSample: 96_000, playerSample: 4_800, secondsSinceReport: 0.004, lengthSamples: length
        )
        #expect(abs(later - 2.104) < 1e-12)
        // The block is still 3 ms away from coming out.
        let earlier = PlaybackPosition.seconds(
            runStartSample: 96_000, playerSample: 4_800, secondsSinceReport: -0.003, lengthSamples: length
        )
        #expect(abs(earlier - 2.097) < 1e-12)
    }

    @Test("A sound device that stops reporting cannot make the position run away")
    func stalledDevice() {
        let stalled = PlaybackPosition.seconds(
            runStartSample: 96_000, playerSample: 4_800, secondsSinceReport: 30, lengthSamples: length
        )
        #expect(abs(stalled - 2.2) < 1e-12)
        let wrongClock = PlaybackPosition.seconds(
            runStartSample: 96_000, playerSample: 4_800, secondsSinceReport: -30, lengthSamples: length
        )
        #expect(abs(wrongClock - 2.0) < 1e-12)
        let noClock = PlaybackPosition.seconds(
            runStartSample: 96_000, playerSample: 4_800, secondsSinceReport: .nan, lengthSamples: length
        )
        #expect(noClock == 2.1)
    }

    @Test("The position never leaves the part of the song that this playback covers")
    func secondsAreKeptInside() {
        // Waiting for the start time: the position is the place playback will start from.
        let waiting = PlaybackPosition.seconds(
            runStartSample: 96_000, playerSample: -960, secondsSinceReport: 0.001, lengthSamples: length
        )
        #expect(waiting == 2)
        // Just started, and the first block is still on its way out.
        let justStarted = PlaybackPosition.seconds(
            runStartSample: 96_000, playerSample: 0, secondsSinceReport: -0.01, lengthSamples: length
        )
        #expect(justStarted == 2)
        // The last block of the song is coming out.
        let atEnd = PlaybackPosition.seconds(
            runStartSample: 96_000, playerSample: 383_900, secondsSinceReport: 0.05, lengthSamples: length
        )
        #expect(atEnd == 10)
        let pastEnd = PlaybackPosition.seconds(
            runStartSample: 96_000, playerSample: 500_000, secondsSinceReport: 0, lengthSamples: length
        )
        #expect(pastEnd == 10)
        // A start outside the song is pulled into it.
        let badStart = PlaybackPosition.seconds(
            runStartSample: 999_999, playerSample: 10, secondsSinceReport: 0, lengthSamples: length
        )
        #expect(badStart == 10)
    }

    @Test("When the player cannot be asked, the clock gives the place")
    func estimateFromTheClock() {
        #expect(PlaybackPosition.estimatedSeconds(runStartSample: 96_000, secondsSinceStart: 3.5, lengthSamples: length) == 5.5)
        // The start time has not come yet.
        #expect(PlaybackPosition.estimatedSeconds(runStartSample: 96_000, secondsSinceStart: -0.02, lengthSamples: length) == 2)
        #expect(PlaybackPosition.estimatedSeconds(runStartSample: 96_000, secondsSinceStart: 60, lengthSamples: length) == 10)
        #expect(PlaybackPosition.estimatedSeconds(runStartSample: 96_000, secondsSinceStart: .nan, lengthSamples: length) == 2)
        #expect(PlaybackPosition.estimatedSeconds(runStartSample: 0, secondsSinceStart: 1, lengthSamples: 0) == 0)
    }

    @Test("During a count-in before the song the position is below the place the song starts from")
    func positionBeforeTheSong() {
        // The click counts alone for one second (48,000 samples) before the song starts at its first sample.
        func position(_ playerSample: Int64, since: Double = 0) -> Double {
            PlaybackPosition.seconds(
                runStartSample: 0, leadInSamples: 48_000, playerSample: playerSample,
                secondsSinceReport: since, lengthSamples: length
            )
        }
        #expect(position(0) == -1)
        #expect(position(12_000) == -0.75)
        #expect(position(48_000) == 0)
        #expect(position(72_000) == 0.5)
        // The player has not reached its starting moment yet: the position waits at the start of the count-in.
        #expect(position(-2_400) == -1)
        // Between two reports the clock carries the position on.
        #expect(abs(position(12_000, since: 0.01) - -0.74) < 1e-12)
        // And it stops at the end of the song.
        #expect(position(1_000_000) == 10)

        // With no part before the song it is the ordinary position.
        #expect(PlaybackPosition.seconds(
            runStartSample: 96_000, leadInSamples: 0, playerSample: 4_800, secondsSinceReport: 0, lengthSamples: length
        ) == PlaybackPosition.seconds(
            runStartSample: 96_000, playerSample: 4_800, secondsSinceReport: 0, lengthSamples: length
        ))
    }
}

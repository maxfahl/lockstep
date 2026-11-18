import LockstepCore

/// The arithmetic behind the playing position, kept apart from the audio engine so it can be tested with plain numbers.
///
/// The song player counts the samples it has played since it was last started. Playback that started in the middle of
/// the song therefore needs the starting sample added, and every answer is kept inside the song.
public enum PlaybackPosition {
    /// The furthest the position may be moved away from the last block of sound the Mac reported, in seconds.
    /// The Mac reports its progress about every 10 ms; a larger difference means it has stopped reporting.
    public static let longestStepBetweenReports: Double = 0.1

    /// The whole sample nearest to a time in the song, kept between the first sample and the end.
    public static func sample(forSeconds seconds: Double, lengthSamples: Int) -> Int {
        guard seconds.isFinite, lengthSamples > 0 else { return 0 }
        let sample = (seconds * Lockstep.sampleRate).rounded()
        guard sample > 0 else { return 0 }
        guard sample < Double(lengthSamples) else { return lengthSamples }
        return Int(sample)
    }

    /// The time in the song of a sample.
    public static func seconds(forSample sample: Int) -> Double {
        Double(sample) / Lockstep.sampleRate
    }

    /// The playing position in song seconds.
    ///
    /// - Parameters:
    ///   - runStartSample: the sample of the song where playback was last started.
    ///   - playerSample: how many samples the player has played since then. It is negative while the player waits for
    ///     its start time.
    ///   - secondsSinceReport: how long ago the block of sound that `playerSample` belongs to started to come out of
    ///     the Mac. It is negative when that block is still on its way out, and zero when the time is not known.
    public static func seconds(
        runStartSample: Int,
        playerSample: Int64,
        secondsSinceReport: Double,
        lengthSamples: Int
    ) -> Double {
        seconds(
            runStartSample: runStartSample,
            leadInSamples: 0,
            playerSample: playerSample,
            secondsSinceReport: secondsSinceReport,
            lengthSamples: lengthSamples
        )
    }

    /// The playing position in song seconds for playback that began with a count-in before the song: the player
    /// counted `leadInSamples` samples before the song's own first sample came out. During that part the position
    /// is below the place the song starts from, and so below zero at the start of the song: -1.5 means the song
    /// starts in a second and a half.
    ///
    /// - Parameters:
    ///   - runStartSample: the sample of the song that came out when the part before the song was over.
    ///   - leadInSamples: the length of the part before the song, in samples. Zero for ordinary playback.
    ///   - playerSample: how many samples the player has counted since it was started, the part before the song
    ///     included.
    public static func seconds(
        runStartSample: Int,
        leadInSamples: Int,
        playerSample: Int64,
        secondsSinceReport: Double,
        lengthSamples: Int
    ) -> Double {
        let start = seconds(forSample: min(max(runStartSample, 0), max(lengthSamples, 0)))
        let end = seconds(forSample: max(lengthSamples, 0))
        let lead = Double(max(leadInSamples, 0)) / Lockstep.sampleRate
        let reported = start - lead + Double(playerSample) / Lockstep.sampleRate
        let step = secondsSinceReport.isFinite
            ? min(max(secondsSinceReport, -longestStepBetweenReports), longestStepBetweenReports)
            : 0
        return min(max(reported + step, start - lead), end)
    }

    /// The playing position in song seconds for playback that goes round in a loop: the same count of played
    /// samples, taken round the loop once its end has been reached (`LoopRegion.songSeconds(forStraight:)`).
    /// So the position jumps back to the loop's start exactly where the sound does. With `loop` nil it is
    /// the position of playback that plays straight on.
    ///
    /// - Parameter loop: the loop this playback goes round in. Only hand over a loop that playback from
    ///   `runStartSample` reaches (`LoopRegion.isReached(from:)`).
    public static func seconds(
        runStartSample: Int,
        leadInSamples: Int,
        playerSample: Int64,
        secondsSinceReport: Double,
        lengthSamples: Int,
        loop: LoopRegion?
    ) -> Double {
        guard let loop else {
            return seconds(
                runStartSample: runStartSample,
                leadInSamples: leadInSamples,
                playerSample: playerSample,
                secondsSinceReport: secondsSinceReport,
                lengthSamples: lengthSamples
            )
        }
        let start = seconds(forSample: min(max(runStartSample, 0), max(lengthSamples, 0)))
        let lead = Double(max(leadInSamples, 0)) / Lockstep.sampleRate
        let step = secondsSinceReport.isFinite
            ? min(max(secondsSinceReport, -longestStepBetweenReports), longestStepBetweenReports)
            : 0
        // Where the song would be had it not looped. It has no end to stop at: the loop never reaches it.
        let straight = max(start - lead + Double(playerSample) / Lockstep.sampleRate + step, start - lead)
        return loop.songSeconds(forStraight: straight)
    }

    /// The playing position worked out from the clock alone, for the moment when the sound device has just gone away
    /// and the player can no longer be asked.
    ///
    /// - Parameter secondsSinceStart: how long ago the sound started.
    public static func estimatedSeconds(runStartSample: Int, secondsSinceStart: Double, lengthSamples: Int) -> Double {
        let start = seconds(forSample: min(max(runStartSample, 0), max(lengthSamples, 0)))
        let end = seconds(forSample: max(lengthSamples, 0))
        guard secondsSinceStart.isFinite, secondsSinceStart > 0 else { return start }
        return min(start + secondsSinceStart, end)
    }
}

/// How the Mac's clock counts time.
///
/// The Mac stamps every block of sound, played or recorded, with a "host time": a count of ticks since the Mac
/// started. How long a tick lasts differs between Macs, and the system gives it as a fraction: one tick is
/// `numerator / denominator` nanoseconds (what `mach_timebase_info` reports).
public struct HostClock: Sendable, Equatable {
    public var numerator: UInt32
    public var denominator: UInt32

    public init(numerator: UInt32, denominator: UInt32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// The seconds from one host time to another. Negative when `later` is in fact the earlier of the two.
    public func seconds(from earlier: UInt64, to later: UInt64) -> Double {
        guard numerator > 0, denominator > 0 else { return 0 }
        // The two counts are subtracted as whole numbers first. As floating-point numbers they are too large to
        // keep their last digits, and the difference would lose the precision that matters here.
        let ticks = later >= earlier ? Double(later - earlier) : -Double(earlier - later)
        return ticks * Double(numerator) / Double(denominator) / 1_000_000_000
    }

    /// How many ticks a length of time is. Zero for a negative length.
    public func ticks(forSeconds seconds: Double) -> UInt64 {
        guard numerator > 0, denominator > 0, seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64((seconds * 1_000_000_000 * Double(denominator) / Double(numerator)).rounded())
    }
}

/// Where a recording belongs in the song, and where the run-up before it starts. Plain arithmetic, so it can be
/// tested with made-up numbers.
public enum RecordingPlacement {
    /// The song time, in seconds, of the first sample of a recording, before the calibrated delay is removed
    /// (`Recording.rawStart`).
    ///
    /// The song and the microphone are both stamped by the same clock. The song was asked to start playing from
    /// `playbackStartPosition` at one moment, and the first recorded sample was heard at another. The time between
    /// the two moments is how far into the playback the recording begins. A recording that began before the song
    /// started gets a start earlier than `playbackStartPosition`, which can be below zero.
    ///
    /// - Parameters:
    ///   - playbackStartPosition: the place in the song where playback started, in song seconds.
    ///   - songStartHostTime: the host time the song player was asked to start at.
    ///   - firstInputHostTime: the host time of the first block of sound from the microphone.
    public static func rawStart(
        playbackStartPosition: Double,
        songStartHostTime: UInt64,
        firstInputHostTime: UInt64,
        clock: HostClock
    ) -> Double {
        playbackStartPosition + clock.seconds(from: songStartHostTime, to: firstInputHostTime)
    }

    /// The length of one bar of run-up when the song has no beats to measure it on, in seconds.
    public static let barSecondsWithoutGrid: Double = 2

    /// Where playback starts so that Max hears `bars` bars before the place he records from.
    ///
    /// The bars are measured on the song's own beats, four to the bar, walking back from `origin` beat by beat, so
    /// a tempo change inside the run-up is followed. Where the song has no beats (before the first, after the
    /// last, or in a stretch that was left empty) the nearest known beat spacing is used. Without beats a bar is
    /// two seconds. The answer is never before the start of the song.
    ///
    /// - Parameters:
    ///   - origin: the place Max records from, in song seconds.
    ///   - grid: the song's beats as the window shows them, or nil when they have not been found.
    public static func runUpStart(origin: Double, bars: Int, grid: Grid?) -> Double {
        guard origin.isFinite, origin > 0 else { return 0 }
        let wantedBars = Double(max(bars, 0))
        guard let grid, grid.hasNeighbouringBeats else {
            return max(origin - wantedBars * barSecondsWithoutGrid, 0)
        }
        return max(time(beats: wantedBars * Double(Grid.beatsPerBar), before: origin, in: grid), 0)
    }

    /// The song time that lies `count` beats before `time`, measured on the song's own beats.
    ///
    /// The walk goes back beat by beat, so a tempo change on the way is followed. Where the song has no beats the
    /// nearest known beat spacing stands in for them, also before the first beat. So the answer can lie before
    /// the start of the song, as a negative time: that is what lets a count-in begin before the song does.
    /// A walk that ends on a beat gives that beat's time exactly.
    ///
    /// Call it only for a grid in which a beat spacing is known somewhere (`hasNeighbouringBeats`).
    static func time(beats count: Double, before time: Double, in grid: Grid) -> Double {
        let beats = grid.beats
        var remaining = count
        var time = time
        while remaining > 0 {
            // The stretch that ends at `time` starts at the last beat before it.
            let below = grid.lastIndex(before: time)
            let spacing: Double
            let stretchStart: Double
            if let below, below + 1 < beats.count, grid.follows(below) {
                spacing = beats[below + 1].time - beats[below].time
                stretchStart = beats[below].time
            } else {
                // No beats here: the nearest known tempo stands in for them.
                spacing = grid.nearestSpacing(to: time)
                stretchStart = below.map { beats[$0].time } ?? -.infinity
            }
            let available = (time - stretchStart) / spacing
            if available > remaining {
                time -= remaining * spacing
                remaining = 0
            } else {
                // The whole stretch is used up, so the walk stands on its first beat, to the last digit.
                remaining -= available
                time = stretchStart
            }
        }
        return time
    }
}

extension RecordingPlacement {
    /// A take shorter than this, in seconds, is thrown away: Record was pressed and stopped again at once.
    public static let shortestTakeSeconds: Double = 0.2

    /// The part of a finished take that becomes its clip, in samples of the recording, or nil when the take is
    /// thrown away and no clip is made.
    ///
    /// - A take shorter than `shortestTakeSeconds` is thrown away.
    /// - A take with a voice in it gives the stretch with the voice (`voiced`), also when the voice starts during
    ///   the run-up, before the record origin.
    /// - A take in which nothing counts as sound gives everything from the record origin to the stop. If it was
    ///   stopped before the origin was reached, there is nothing to keep and it is thrown away.
    ///
    /// - Parameters:
    ///   - recording: the finished take, with its length and its place in the song.
    ///   - voiced: where the voice is, as `VoiceEnvelope.voicedRange()` found it, or nil for no voice at all.
    ///   - origin: the record origin, in song seconds: where the playhead was when Record was pressed.
    public static func clipSamples(of recording: Recording, voiced: Range<Int>?, origin: Double) -> Range<Int>? {
        let length = recording.lengthSamples
        guard Double(length) >= shortestTakeSeconds * Lockstep.sampleRate else { return nil }
        if let voiced {
            let first = min(max(voiced.lowerBound, 0), length)
            let last = min(max(voiced.upperBound, first), length)
            if last > first { return first..<last }
        }
        // The sample of the take that was heard when the song reached the record origin.
        let sinceTakeStart = origin - recording.songTime(ofSample: 0)
        let first = min(max(Int((sinceTakeStart * Lockstep.sampleRate).rounded()), 0), length)
        return first < length ? first..<length : nil
    }
}

// MARK: - Words before the place

/// The numbers that decide which part of a finished take becomes its clip. They are starting values, set
/// generously: a breath too many at the start of a clip can be cut away, a word too few cannot be brought back.
public enum TakeTrim {
    /// The longest pause, in seconds, between a word before the place and what follows it (the next word, or
    /// the place itself) for that word still to lead into the place.
    public static let longestPauseSeconds: Double = 0.4
    /// How far before the place a clip may start at most, in bars.
    public static let longestLeadInBars: Double = 1
    /// The first part of a take that never belongs to a clip, in seconds: the microphone has just opened and
    /// may thump.
    public static let microphoneSettleSeconds: Double = 0.15
    /// Sound before the place that is shorter than this, in seconds, is a pop or a tick and not a word.
    public static let shortestVoiceSeconds: Double = 0.06
    /// How much is kept before the first sound of a clip and after its last, in seconds. A word starts with a
    /// breath or a soft consonant and dies away slowly.
    public static let marginBeforeSeconds: Double = 0.05
    public static let marginAfterSeconds: Double = 0.15

    /// A click of the count-in that leaks from the headphones into the microphone is known by where it starts:
    /// no more than this much before the click's own time, or this much after it, in seconds. The window is
    /// wider after the click, because sound that has gone out and come back in is late, never early.
    public static let clickLeakEarlySeconds: Double = 0.010
    public static let clickLeakLateSeconds: Double = 0.025
    /// How much longer than the click's own sound its leak may ring in the room, in seconds.
    public static let clickLeakTailSeconds: Double = 0.030
}

/// The clicks Max heard in his headphones during a count-in, for telling their leak into the microphone from
/// his voice (`ClickRenderer.leak(of:settings:)` makes it).
public struct ClickLeak: Sendable, Equatable {
    /// When each click sounded, in song seconds.
    public var times: [Double]
    /// How long the longest of those clicks sounds, in seconds.
    public var soundSeconds: Double

    public init(times: [Double], soundSeconds: Double) {
        self.times = times
        self.soundSeconds = soundSeconds
    }

    /// No click was heard: the count-in was off.
    public static let none = ClickLeak(times: [], soundSeconds: 0)
}

extension RecordingPlacement {
    /// The part of a finished take that becomes its clip, in samples of the recording, or nil when the take is
    /// thrown away and no clip is made. This is the rule from fix phase 16.5 on: it looks at the stretches of
    /// voice one by one, so a word said just before the place is kept and other sound before it is not.
    ///
    /// - A take shorter than `shortestTakeSeconds` is thrown away.
    /// - The clip starts where the voice starts when that voice leads into the place: walking back from the
    ///   place over the stretches of voice, each one belongs as long as the pause after it is at most
    ///   `TakeTrim.longestPauseSeconds`. The walk never goes further back than one bar before the place, and
    ///   never into the first 150 ms after the microphone opened.
    /// - Sound before the place that is shorter than 60 ms does not count as voice, and neither does the leak
    ///   of a count-in click: a stretch that begins on a click and is no longer than the click rings.
    /// - With nothing leading into the place, the clip starts where the voice starts at or after the place.
    /// - 50 ms are kept before the first voice of the clip, also across the place, so a consonant that comes
    ///   just ahead of the beat is not cut. They stop at the same limits as the walk.
    /// - The clip ends 150 ms after the last voice.
    /// - A take with no voice from the place on, and none leading into it, gives everything from the place to
    ///   the stop. If it was stopped before the place was reached, it is thrown away.
    ///
    /// - Parameters:
    ///   - recording: the finished take, with its length and its place in the song.
    ///   - stretches: where the voice is, one stretch after the other in samples of the recording, as
    ///     `VoiceEnvelope.voicedStretches()` found them.
    ///   - origin: the place recording started, in song seconds.
    ///   - grid: the song's beats, for the length of the bar before the place. Nil when they are not known.
    ///   - clickLeak: the clicks of the take's count-in. Left out, no sound is taken for a click.
    public static func clipSamples(
        of recording: Recording,
        voicedStretches stretches: [Range<Int>],
        origin: Double,
        grid: Grid?,
        clickLeak: ClickLeak = .none
    ) -> Range<Int>? {
        let rate = Lockstep.sampleRate
        let length = recording.lengthSamples
        guard Double(length) >= shortestTakeSeconds * rate else { return nil }
        func samples(_ seconds: Double) -> Int { Int((seconds * rate).rounded()) }
        // The sample of the take that was heard when the song was at a song time.
        let takeStart = recording.songTime(ofSample: 0)
        func sample(at songSeconds: Double) -> Int { samples(songSeconds - takeStart) }

        let place = sample(at: origin)
        let clicks = clickLeak.times.map(sample(at:))
        let longestLeak = samples(clickLeak.soundSeconds + TakeTrim.clickLeakTailSeconds)
        let voice = stretches.filter { stretch in
            guard stretch.count <= longestLeak else { return true }
            return !clicks.contains { click in
                stretch.lowerBound >= click - samples(TakeTrim.clickLeakEarlySeconds)
                    && stretch.lowerBound <= click + samples(TakeTrim.clickLeakLateSeconds)
            }
        }

        // Walking back from the place over the words that lead into it.
        let bar = barSeconds(before: origin, grid: grid) * TakeTrim.longestLeadInBars
        let earliest = max(place - samples(bar), samples(TakeTrim.microphoneSettleSeconds))
        var front = place
        if earliest < place {
            for stretch in voice.reversed() where stretch.lowerBound < front {
                guard stretch.count >= samples(TakeTrim.shortestVoiceSeconds) else { continue }
                guard front - stretch.upperBound <= samples(TakeTrim.longestPauseSeconds),
                    stretch.upperBound > earliest
                else { break }
                front = max(stretch.lowerBound, earliest)
                if front == earliest { break }
            }
        }

        // The first voice of the clip: the word the walk ended on, or else the first voice from the place on.
        let firstVoice = front < place ? front : voice.first { $0.upperBound > place }?.lowerBound
        if let firstVoice, let last = voice.last {
            // The 50 ms kept before it stop at the same limits as the walk.
            let first = max(firstVoice - samples(TakeTrim.marginBeforeSeconds), min(earliest, place))
            let start = min(max(first, 0), length)
            let end = min(last.upperBound + samples(TakeTrim.marginAfterSeconds), length)
            if start < end { return start..<end }
        }
        // No voice from the place on: everything from the place to the stop.
        let start = min(max(place, 0), length)
        return start < length ? start..<length : nil
    }

    /// The length of the bar that ends at `seconds`, in seconds, measured on the song's beats. Two seconds
    /// without beats.
    static func barSeconds(before seconds: Double, grid: Grid?) -> Double {
        guard let grid, grid.hasNeighbouringBeats else { return barSecondsWithoutGrid }
        return seconds - time(beats: Double(Grid.beatsPerBar), before: seconds, in: grid)
    }
}

extension Grid {
    /// Whether at least two beats follow each other directly, so a beat spacing is known somewhere.
    var hasNeighbouringBeats: Bool {
        beats.indices.dropLast().contains { follows($0) && beats[$0 + 1].time > beats[$0].time }
    }

    /// Index of the last beat before this time, or nil when there is none.
    func lastIndex(before seconds: Double) -> Int? {
        guard var index = lastIndex(atOrBefore: seconds) else { return nil }
        while index >= 0, beats[index].time >= seconds { index -= 1 }
        return index >= 0 ? index : nil
    }

    /// The spacing of the two neighbouring beats closest to this time. Of two that are equally close, the earlier.
    /// Call it only when `hasNeighbouringBeats`.
    func nearestSpacing(to seconds: Double) -> Double {
        var best = RecordingPlacement.barSecondsWithoutGrid / Double(Grid.beatsPerBar)
        var bestDistance = Double.infinity
        for index in beats.indices.dropLast() where follows(index) {
            let start = beats[index].time
            let end = beats[index + 1].time
            guard end > start else { continue }
            let distance = seconds < start ? start - seconds : seconds > end ? seconds - end : 0
            if distance < bestDistance {
                bestDistance = distance
                best = end - start
            }
        }
        return best
    }
}

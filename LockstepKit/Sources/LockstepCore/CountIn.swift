/// The count-in of one take: what is heard from the press of Record until the place recording starts.
///
///     let place = RecordingPlacement.recordPlace(nearest: playhead, grid: project.grid)
///     let countIn = RecordingPlacement.countIn(to: place, bars: settings[.runUpBars], grid: project.grid)
///     countIn.start              // where the count-in begins, in song seconds. Below zero: before the song
///     countIn.leadInSeconds      // how long the click counts alone before the song starts
///     countIn.clicks             // every click, the last one the louder click on the place
///     countIn.songLevel(at: t)   // how loud the song and the clips are at song time t, from 0 to 1
///
/// The click counts every beat of the count-in and is never faded. The song and the clips rise from silence
/// over the first half of it and are at full level for the second half. Where the song has fewer bars before
/// the place than were asked for, the missing part is counted by the click alone, before the song starts.
///
/// A count-in is only a description. `ClickRenderer.renderCountIn` makes its clicks into sound and
/// `PlaybackEngine.start(countingIn:...)` plays it.
public struct CountIn: Sendable, Equatable {
    /// One click of a count-in.
    public struct Click: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A beat inside a bar.
            case beat
            /// The first beat of a bar.
            case barStart
            /// The place recording starts: the higher, louder click to start on.
            case start
        }

        /// When the click sounds, in song seconds. Below zero for a click before the song starts.
        public var time: Double
        public var kind: Kind

        public init(time: Double, kind: Kind) {
            self.time = time
            self.kind = kind
        }
    }

    /// The share of the count-in over which the song and the clips rise from silence to full level. A starting
    /// value: Max may want the rise shorter or longer.
    public static let fadeShare = 0.5

    /// The place recording starts, in song seconds.
    public var place: Double
    /// Where the count-in begins, in song seconds. Below zero when it begins before the song. Equal to `place`
    /// when the count-in is off.
    public var start: Double
    /// One click for every beat of the count-in, in the order they sound. The last one is on the place itself
    /// and is the click to start on. Empty when the count-in is off.
    public var clicks: [Click]

    public init(place: Double, start: Double, clicks: [Click] = []) {
        self.place = place
        self.start = start
        self.clicks = clicks
    }

    /// True when there is nothing to count: recording starts at once at the place.
    public var isOff: Bool { start >= place }

    /// How long the count-in lasts, in seconds.
    public var seconds: Double { max(place - start, 0) }

    /// The length of the part before the song, in seconds: how long the click counts alone until the song
    /// starts. Zero when the song has enough bars before the place.
    public var leadInSeconds: Double { max(-start, 0) }

    /// Where the song is started from, in song seconds: the start of the count-in, or the start of the song
    /// when the count-in begins before it.
    public var songStart: Double { max(start, 0) }

    /// The clicks of the part before the song.
    public var clicksBeforeSong: [Click] { clicks.filter { $0.time < 0 } }

    /// How loud the song and the clips are at a song time during the count-in: 0 is silent, 1 is full level.
    /// Silent at the start of the count-in, rising evenly to full at half of it, and full from there on.
    /// The click is never faded, so this is not for the click.
    public func songLevel(at seconds: Double) -> Double {
        let rise = self.seconds * Self.fadeShare
        guard rise > 0 else { return 1 }
        return min(max((seconds - start) / rise, 0), 1)
    }
}

// MARK: - In whole samples

/// The count-in in whole samples at 48,000 Hz, counted from its own first sample. The click's sound and the
/// player both work from these, so they agree to the sample.
extension CountIn {
    /// The length of the part before the song, in samples.
    public var leadInSamples: Int {
        Int((leadInSeconds * Lockstep.sampleRate).rounded())
    }

    /// The sample of the song that playback starts from.
    public var songStartSample: Int {
        Int((songStart * Lockstep.sampleRate).rounded())
    }

    /// The sample of the count-in that a song time falls on. The first sample of the count-in is 0.
    public func sample(at seconds: Double) -> Int {
        leadInSamples + Int((seconds * Lockstep.sampleRate).rounded()) - songStartSample
    }

    /// The length of the count-in in samples: the sample of the count-in that the place falls on.
    public var lengthSamples: Int {
        max(sample(at: place), 0)
    }

    /// The number of samples over which the song and the clips rise to full level.
    public var fadeSamples: Int {
        Int((Double(lengthSamples) * Self.fadeShare).rounded(.down))
    }

    /// How loud the song and the clips are at a sample of the count-in, from 0 to 1 (`songLevel(at:)`).
    public func songLevel(atSample sample: Int) -> Float {
        let rise = fadeSamples
        guard rise > 0, sample < rise else { return 1 }
        return Float(max(sample, 0)) / Float(rise)
    }
}

// MARK: - Working it out

extension RecordingPlacement {
    /// How near the playhead must be to a beat, in beats, for Record to aim at that beat. Between two beats the
    /// nearest one is never further than half a beat. This reach counts just outside the beats: before the
    /// first one, after the last one and at the edges of a stretch that was left empty.
    public static let placeSnapBeats: Double = 1

    /// The place recording starts when Record is pressed with the playhead at `playhead`: the beat nearest the
    /// playhead where the song has beats, so the click to start on lands on a beat, and the playhead itself
    /// where it has none.
    public static func recordPlace(nearest playhead: Double, grid: Grid?) -> Double {
        let playhead = playhead.isFinite ? max(playhead, 0) : 0
        guard let grid, grid.hasNeighbouringBeats, let beat = grid.beat(nearest: playhead) else { return playhead }
        let reach = grid.nearestSpacing(to: beat.time) * placeSnapBeats
        return abs(beat.time - playhead) <= reach ? beat.time : playhead
    }

    /// The count-in before `place`.
    ///
    /// - It is `bars` bars long, four beats to the bar, measured back from the place on the song's own beats.
    ///   Where the song has no beats the nearest known beat spacing is used, and without beats a bar is two
    ///   seconds.
    /// - It may begin before the start of the song. `start` is then below zero, the song starts at 0, and the
    ///   clicks before 0 are spaced as the song's first beats are.
    /// - Every beat of it gets a click, and the place itself gets the click to start on.
    /// - With `bars` 0 the count-in is off: it begins at the place and has no click.
    ///
    /// - Parameters:
    ///   - place: where recording starts, in song seconds (`recordPlace(nearest:grid:)`).
    ///   - bars: 0 (off), 1, 2 or 4: the setting `recording.runUpBars`.
    ///   - grid: the song's beats as the window shows them, or nil when they have not been found.
    public static func countIn(to place: Double, bars: Int, grid: Grid?) -> CountIn {
        let place = place.isFinite ? max(place, 0) : 0
        let beatCount = max(bars, 0) * Grid.beatsPerBar
        guard beatCount > 0 else { return CountIn(place: place, start: place) }

        let measured = grid.flatMap { $0.hasNeighbouringBeats ? $0 : nil }
        var time = place
        // The number of the beat the walk stands on, while it stands on the song's beats or counts on from them.
        var number = measured?.beat(at: place)?.number
        var clicks = [CountIn.Click(time: place, kind: .start)]
        for step in 1...beatCount {
            if let measured {
                time = self.time(beats: 1, before: time, in: measured)
            } else {
                time -= barSecondsWithoutGrid / Double(Grid.beatsPerBar)
            }
            number = measured?.beat(at: time)?.number ?? number.map { $0 - 1 }
            // Off the song's beats the place counts as the first beat of a bar, and every fourth beat before it.
            let startsBar = number.flatMap { number in measured.map { $0.isBarStart(number) } }
                ?? (step % Grid.beatsPerBar == 0)
            clicks.append(CountIn.Click(time: time, kind: startsBar ? .barStart : .beat))
        }
        // A start that misses the start of the song by less than half a sample is the start of the song.
        let start = abs(time) * Lockstep.sampleRate < 0.5 ? 0 : time
        return CountIn(place: place, start: start, clicks: clicks.reversed())
    }
}

extension Grid {
    /// The beat that stands on this song time, or nil when no beat does.
    func beat(at seconds: Double) -> Beat? {
        guard let beat = beat(nearest: seconds), abs(beat.time - seconds) < 1e-9 else { return nil }
        return beat
    }
}

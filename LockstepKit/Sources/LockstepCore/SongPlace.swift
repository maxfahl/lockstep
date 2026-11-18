/// How the song lies on the timeline: how much of its beginning and of its end is cut away, and which moment
/// of the song stands at the timeline's 00:00.
///
/// Inside the app a position is still song seconds, counted from the first sample of the song file, whatever
/// is cut away. This is the one place that turns such a position into what is shown and sent: the time in the
/// ruler and in the time readout, the frame and the timecode of a clip in Resolve, and the click file all count
/// from the timeline's 00:00.
///
///     let place = project.songPlace
///     place.timelineSeconds(forSong: playhead)        // what the time readout shows
///     place.timelineSample(forSong: firstSample)      // what the Resolve frame is worked out from
///     project.keptSeconds                             // the part of the song that is drawn and played
///
/// The three numbers are changed only through `cuttingStart`, `cuttingEnd`, `moved` and `startingOnTimeline`,
/// which keep them inside their limits. The song's beats and every clip are placed in song seconds, so they
/// stay on the song when it is cut or moved: moving the song changes where 00:00 lies, and what comes to lie
/// before 00:00 is cut away. So there is one kind of hidden beginning, the cut one, however it came about.
public struct SongPlace: Codable, Sendable, Equatable {
    /// How many samples of the song's beginning are cut away. 0 keeps the beginning.
    public var cutStartSamples: Int
    /// How many samples of the song's end are cut away. 0 keeps the end.
    public var cutEndSamples: Int
    /// The sample of the song that stands at the timeline's 00:00, which is also the first frame of the
    /// Resolve timeline. 0 while the song's own first sample stands there. With the song dragged left until
    /// 00:00 lies inside it, it is `cutStartSamples`: what lies before 00:00 is cut away. It is never above
    /// `cutStartSamples`, and below zero only in a project that was saved with the song starting after the
    /// start of the Resolve timeline.
    public var zeroSample: Int

    /// What is always left of the song, however far its edges are dragged: one second.
    public static let shortestKeptSamples = 48_000

    public init(cutStartSamples: Int = 0, cutEndSamples: Int = 0, zeroSample: Int = 0) {
        self.cutStartSamples = cutStartSamples
        self.cutEndSamples = cutEndSamples
        self.zeroSample = zeroSample
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cutStartSamples: try container.decodeIfPresent(Int.self, forKey: .cutStartSamples) ?? 0,
            cutEndSamples: try container.decodeIfPresent(Int.self, forKey: .cutEndSamples) ?? 0,
            zeroSample: try container.decodeIfPresent(Int.self, forKey: .zeroSample) ?? 0
        )
    }

    // MARK: Song time and timeline time

    /// The song seconds that stand at the timeline's 00:00.
    public var zeroSeconds: Double { Double(zeroSample) / Lockstep.sampleRate }

    /// Where a sample of the song lies on the timeline, in samples from 00:00. Below zero before it.
    public func timelineSample(forSong sample: Int) -> Int { sample - zeroSample }

    /// The sample of the song that lies this many samples after the timeline's 00:00.
    public func songSample(forTimeline sample: Int) -> Int { sample + zeroSample }

    /// The time the window shows for a place in the song: seconds from the timeline's 00:00.
    public func timelineSeconds(forSong seconds: Double) -> Double { seconds - zeroSeconds }

    /// The place in the song of a time on the timeline.
    public func songSeconds(forTimeline seconds: Double) -> Double { seconds + zeroSeconds }

    // MARK: What is left of the song

    /// The samples of a song of `length` samples that are left: drawn, played and clicked.
    public func keptSamples(ofLength length: Int) -> Range<Int> {
        let end = max(length - max(cutEndSamples, 0), 0)
        let start = min(max(cutStartSamples, 0), end)
        return start..<end
    }

    /// The same in song seconds.
    public func keptSeconds(ofLength length: Int) -> ClosedRange<Double> {
        let kept = keptSamples(ofLength: length)
        return Double(kept.lowerBound) / Lockstep.sampleRate...Double(kept.upperBound) / Lockstep.sampleRate
    }

    /// The song seconds the timeline shows: from its 00:00 to the end of the song file. The part that is cut
    /// away at the end stays in view, empty, so the edge can be dragged back into it. The timeline has no room
    /// before the song's own first sample.
    public func shownSeconds(ofLength length: Int) -> ClosedRange<Double> {
        let end = Double(max(length, 0)) / Lockstep.sampleRate
        return min(max(zeroSeconds, 0), end)...end
    }

    // MARK: Cutting and moving

    /// The place with the song starting at another of its samples: the left edge dragged there. The start
    /// never goes left of the timeline's 00:00, and at least `shortestKeptSamples` are left.
    public func cuttingStart(at sample: Int, ofLength length: Int) -> SongPlace {
        let end = keptSamples(ofLength: length).upperBound
        let earliest = max(zeroSample, 0)
        var cut = self
        cut.cutStartSamples = max(min(sample, end - Self.shortestKeptSamples), earliest)
        return cut
    }

    /// The place with the song ending at another of its samples (one past the last that is kept): the right
    /// edge dragged there. At least `shortestKeptSamples` are left.
    public func cuttingEnd(at sample: Int, ofLength length: Int) -> SongPlace {
        let start = keptSamples(ofLength: length).lowerBound
        var cut = self
        cut.cutEndSamples = max(length - max(min(sample, length), start + Self.shortestKeptSamples), 0)
        return cut
    }

    /// The place with the song moved along the timeline by `delta` samples, to the right when positive. The
    /// beats and the clips are placed in song time, so they go with it.
    ///
    /// To the left the song goes on after its start has reached 00:00: its beginning passes 00:00 and is cut
    /// away as it does, so the start of what is left never lies left of 00:00, and it stops when
    /// `shortestKeptSamples` are left. To the right, a song whose start stands at 00:00 gets that beginning
    /// back, as far as its own first sample: the timeline has no room before that sample, so a clip there could
    /// not be played. A song with empty room before its start (its left edge was dragged in) moves in that
    /// room and keeps its cut.
    ///
    ///     SongPlace().moved(bySamples: -480_000, ofLength: length)    // 00:00 is ten seconds into the song
    ///         .moved(bySamples: 480_000, ofLength: length)            // SongPlace() again
    public func moved(bySamples delta: Int, ofLength length: Int) -> SongPlace {
        let end = keptSamples(ofLength: length).upperBound
        let furthestLeft = max(end - Self.shortestKeptSamples, zeroSample)
        return withZero(at: min(max(zeroSample - delta, min(zeroSample, 0)), furthestLeft))
    }

    /// The place with the song's own first sample `sample` samples after the timeline's 00:00, or before it
    /// when negative: what "Song starts at" in the Send to DaVinci panel sets. It is the same as moving the
    /// song there: a start before 00:00 cuts that much of the beginning away, unless more is cut already, and
    /// a later start brings the beginning back to a song whose start stood at 00:00.
    public func startingOnTimeline(at sample: Int, ofLength length: Int) -> SongPlace {
        withZero(at: -sample).fitted(toLength: length)
    }

    /// The place with another sample of the song at 00:00, and the one rule of moving the song: what comes
    /// to lie before 00:00 is cut away, and a song whose start stood at 00:00 still starts there afterwards,
    /// with as much of its beginning back as now lies after 00:00.
    private func withZero(at sample: Int) -> SongPlace {
        let startedAtZero = cutStartSamples <= zeroSample
        var placed = self
        placed.zeroSample = sample
        if sample > cutStartSamples || startedAtZero {
            placed.cutStartSamples = max(sample, 0)
        }
        return placed
    }

    /// The place held inside what a song of `length` samples allows: something is always left of the song,
    /// and its start is never left of 00:00.
    public func fitted(toLength length: Int) -> SongPlace {
        var fitted = self
        let room = max(length - Self.shortestKeptSamples, 0)
        fitted.cutStartSamples = min(max(cutStartSamples, 0), room)
        fitted.cutEndSamples = min(max(cutEndSamples, 0), room - fitted.cutStartSamples)
        fitted.zeroSample = min(zeroSample, fitted.cutStartSamples)
        return fitted
    }

    // MARK: From an older project

    /// The place of a project saved before the song could be cut, from what its Resolve timeline said: how
    /// many frames after the timeline start the song began. A song that began before the timeline start had
    /// its beginning cut away in Resolve, and that is now a cut of the song with what is left standing at
    /// 00:00. Every clip keeps the frame and the timecode it had.
    public init(resolveOffsetFrames frames: Int, samplesPerFrame: Int, ofLength length: Int) {
        self = SongPlace().startingOnTimeline(at: frames * samplesPerFrame, ofLength: length)
    }

    // MARK: A row of samples on the timeline

    /// A row of samples that lies along the whole song, such as its click, as it lies along the timeline:
    /// starting at 00:00 and ending where what is left of the song ends. What a file for Resolve holds.
    public func timelineRow(of row: [Float], ofLength length: Int) -> [Float] {
        let end = min(keptSamples(ofLength: length).upperBound, row.count)
        let silence = [Float](repeating: 0, count: max(-zeroSample, 0))
        let start = max(zeroSample, 0)
        return start < end ? silence + row[start..<end] : silence
    }
}

extension Project {
    /// The samples of the song that are left after cutting: drawn, played and clicked.
    public var keptSamples: Range<Int> { songPlace.keptSamples(ofLength: songLengthSamples) }

    /// The same in song seconds. The playhead stays inside it, and a take starts inside it.
    public var keptSeconds: ClosedRange<Double> { songPlace.keptSeconds(ofLength: songLengthSamples) }

    /// The part of a stretch of the song, in song seconds, that lies in what is left of the song, or nil
    /// when none of it does. A stretch that is marked on a track is held to this while it is dragged, and is
    /// shortened to it when the song is cut afterwards.
    ///
    ///     project.keptPart(of: 8...14)    // 10...14 with the first ten seconds cut away
    ///     project.keptPart(of: 2...9)     // nil
    public func keptPart(of stretch: ClosedRange<Double>) -> ClosedRange<Double>? {
        let kept = keptSeconds
        let start = max(stretch.lowerBound, kept.lowerBound)
        let end = min(stretch.upperBound, kept.upperBound)
        return end > start ? start...end : nil
    }
}

import Foundation

// Recording slower. For a passage that is too fast to rap cleanly, the song is played at 85 or 90 % of its
// speed at the same pitch while the take is recorded, and the take is then made as fast as the song.
//
// There is one seam. While a slow take goes, everything the recording code reads is in "slow time": the
// beats, the song's length, its cut and the loop, all made slower by `SlowTime`. The recording code itself
// (`RecordingPlacement`, `CountIn`, `ClickRenderer`, `LoopPasses`) is used on those values with no change of
// its own. Where a finished take becomes a clip, `SpeedUpPlan` says how its sound is sped up, and
// `SpeedUpPlan.atFullTempo` moves the recording and its clip to song time. From there on nothing knows about
// speed: a recording made slower counts in its sped-up sound, like any other.
//
//     let slow = SlowTime(percent: settings[.recordSpeedPercent])           // 85 → a rate of 0.85
//     let counted = RecordingPlacement.countIn(to: slow.slowSeconds(forSong: place), bars: 1,
//                                              grid: project.grid.map(slow.slowed))
//     // ... the take is recorded against the slowed song, and ends as a recording in slow time ...
//     let plan = SpeedUpPlan(lengthSamples: slowTake.count, rate: slow.rate,
//                            syllableStarts: starts, sound: stretchesOfSound)
//     let spedUp = stretcher.stretch(slowTake, keyFrames: plan.keyFrames, outputLength: plan.targetLength)
//     let (recording, clip) = plan.atFullTempo(slowRecording, clip: slowClip)
//
// The stretching itself needs a library and is in `LockstepAudio` (`SpedUpTake`, `SlowedBacking`).

// MARK: - Slow time

/// The time of a take that is recorded slower than the song: a second of the song lasts `1 / rate` seconds.
///
/// A moment of the song is the same moment in slow time, later: song second 8.5 is slow second 10 at 85 %.
/// That holds before the song too, where a count-in starts below zero.
public struct SlowTime: Sendable, Equatable {
    /// The speeds a take can be recorded at, in percent of the song's speed, as the click menu lists them.
    public static let percents = [100, 90, 85]
    /// No take is recorded slower than this share of the song's speed.
    public static let slowestRate = 0.5

    /// The speed as a share of the song's: 0.85 for 85 %. 1 is the song's own speed.
    public let rate: Double

    /// Something that is no speed, or a speed above the song's own, counts as the song's own.
    public init(rate: Double) {
        self.rate = rate.isFinite && rate < 1 ? max(rate, Self.slowestRate) : 1
    }

    /// The speed of the setting `recording.speedPercent`.
    public init(percent: Int) {
        self.init(rate: Double(percent) / 100)
    }

    /// False at the song's own speed, where slow time is song time.
    public var isSlow: Bool { rate < 1 }

    // MARK: A moment

    /// When a moment of the song comes in slow time, in seconds.
    public func slowSeconds(forSong seconds: Double) -> Double { seconds / rate }

    /// The moment of the song that a slow time stands for, in seconds.
    public func songSeconds(forSlow seconds: Double) -> Double { seconds * rate }

    /// The sample of the slowed song on which a sample of the song is heard.
    public func slowSample(forSong sample: Int) -> Int {
        isSlow ? Int((Double(sample) / rate).rounded()) : sample
    }

    /// How many samples the slowed song has. The slowed sound is made exactly this long
    /// (`SlowedBacking` in `LockstepAudio`), so the two always agree.
    public func slowLength(ofSong lengthSamples: Int) -> Int {
        slowSample(forSong: max(lengthSamples, 0))
    }

    // MARK: What the recording code reads

    /// The song's beats in slow time: every beat at its time divided by the rate. It is still the same beat,
    /// with its number, so the bars are the same bars.
    public func slowed(_ grid: Grid) -> Grid {
        guard isSlow else { return grid }
        var slowed = grid
        for index in slowed.beats.indices { slowed.beats[index].time = slowSeconds(forSong: grid.beats[index].time) }
        slowed.anchors = grid.anchors.map {
            Anchor(from: slowSeconds(forSong: $0.from), to: slowSeconds(forSong: $0.to))
        }
        slowed.beatOne = grid.beatOne.map(slowSeconds(forSong:))
        return slowed
    }

    /// The song's cut and its 00:00 in slow time, for a song of `songLengthSamples`: what is left of the
    /// slowed song starts and ends on the same moments, and so does 00:00.
    public func slowed(_ place: SongPlace, songLengthSamples: Int) -> SongPlace {
        guard isSlow else { return place }
        let kept = place.keptSamples(ofLength: songLengthSamples)
        return SongPlace(
            cutStartSamples: slowSample(forSong: kept.lowerBound),
            cutEndSamples: slowLength(ofSong: songLengthSamples) - slowSample(forSong: kept.upperBound),
            zeroSample: slowSample(forSong: place.zeroSample)
        )
    }

    /// The loop in slow time: it starts and ends on the same moments of the song. Every time round is then
    /// the same number of slow samples.
    public func slowed(_ loop: LoopRegion) -> LoopRegion? {
        guard isSlow else { return loop }
        let start = slowSample(forSong: loop.startSample)
        return LoopRegion(startSample: start, lengthSamples: slowSample(forSong: loop.endSample) - start)
    }

    /// The project as the recording code reads it during a slow take: its beats, the song's length and the
    /// song's place are in slow time. The clips and the recordings are left out, because they are in song time
    /// and nothing that runs in slow time may place anything by them.
    public func slowed(_ project: Project) -> Project {
        guard isSlow else { return project }
        var slowed = project
        slowed.grid = project.grid.map { self.slowed($0) }
        slowed.songLengthSamples = slowLength(ofSong: project.songLengthSamples)
        slowed.songPlace = self.slowed(project.songPlace, songLengthSamples: project.songLengthSamples)
        for index in slowed.tracks.indices { slowed.tracks[index].clips = [] }
        slowed.recordings = []
        return slowed
    }
}

// MARK: - The plan of the speed-up

/// How the sound of a slow take is made as fast as the song: which sample of the take lands on which sample
/// of the sped-up sound.
///
/// What the mouth does when it raps faster is to shorten the vowels and the pauses, and hardly the
/// consonants. So the plan does not squeeze the take evenly:
/// - Every syllable start lands on its own sample times the rate. Each syllable then stands against the beat
///   exactly where it was performed against the slow beat.
/// - A stretch around every start keeps its length (`Rules.keptBeforeMs` before it to `Rules.keptAfterMs`
///   after it). That is where the consonant and the attack of the vowel are.
/// - The time is taken out of what is left between two starts: first out of the pauses, which may shrink to
///   `Rules.pauseShortestShare` of their length, then out of the sound.
/// - Where the sound would have to shrink below `Rules.soundShortestShare` of its length, the kept stretches
///   on both sides are shortened until it does not.
/// - With no syllables, the whole take is squeezed evenly.
///
/// The answer is `(length * rate)` samples long, rounded, and its key frames only go forward.
///
///     plan.keyFrames                    // what `TimeStretcher.stretch(_:keyFrames:outputLength:)` takes
///     plan.targetLength                 // its `outputLength`
///     plan.target(ofSource: sample)     // where a sample of the slow take is heard in the sped-up sound
///
/// A stretcher is promised that no piece is squeezed below `1 / 1.4` of its length (`TimeStretcher`). A pause
/// here may go to half, and sound to 0.7. `RubberBandStretcher` takes both: see `SpedUpTake`.
public struct SpeedUpPlan: Sendable, Equatable {
    /// The numbers of the plan. They are starting values, to be tuned when Max has listened.
    public struct Rules: Sendable, Equatable {
        /// How much before a syllable start keeps its length, in milliseconds.
        public var keptBeforeMs: Double = 15
        /// How much after a syllable start keeps its length, in milliseconds.
        public var keptAfterMs: Double = 45
        /// The shortest a pause may become, as a share of its length.
        public var pauseShortestShare: Double = 0.5
        /// The shortest a piece of sound outside the kept stretches may become, as a share of its length.
        public var soundShortestShare: Double = 0.7

        public init() {}

        public static let standard = Rules()
    }

    /// One moment of the take, before and after.
    public struct Point: Sendable, Equatable {
        /// A sample of the slow take.
        public var source: Int
        /// The sample of the sped-up sound it lands on.
        public var target: Int

        public init(source: Int, target: Int) {
            self.source = source
            self.target = target
        }
    }

    /// The length of the slow take, in samples.
    public let sourceLength: Int
    /// The length of the sped-up sound, in samples: `sourceLength * rate`, rounded.
    public let targetLength: Int
    /// The speed the take was recorded at, as a share of the song's.
    public let rate: Double
    /// Where the map bends, in the order of the take. The start of the take (0 to 0) and its end
    /// (`sourceLength` to `targetLength`) always hold and are not listed. Between two neighbouring points the
    /// sound is squeezed evenly, or keeps its length.
    public let points: [Point]

    /// The points as a stretcher takes them.
    public var keyFrames: [(source: Int, target: Int)] {
        points.map { ($0.source, $0.target) }
    }

    /// - Parameters:
    ///   - lengthSamples: the length of the slow take.
    ///   - rate: the speed it was recorded at, as `SlowTime.rate` has it.
    ///   - syllableStarts: where its syllables start, in samples of the slow take (`SyllableDetector`). Starts
    ///     outside the take, and a start given twice, are left out.
    ///   - sound: the stretches of the take with sound in them, in samples. Everything else is pause.
    public init(
        lengthSamples: Int,
        rate: Double,
        syllableStarts: [Int],
        sound: [Range<Int>],
        rules: Rules = .standard
    ) {
        let slow = SlowTime(rate: rate)
        let length = max(lengthSamples, 0)
        sourceLength = length
        targetLength = Self.target(of: length, at: slow.rate)
        self.rate = slow.rate

        // The moments that are fixed: the start of the take, every syllable start, the end of the take.
        var anchors = [Point(source: 0, target: 0)]
        for start in Set(syllableStarts).sorted() where start > 0 && start < length {
            let target = Self.target(of: start, at: slow.rate)
            if target > anchors[anchors.count - 1].target, target < targetLength {
                anchors.append(Point(source: start, target: target))
            }
        }
        anchors.append(Point(source: length, target: targetLength))
        guard slow.isSlow, anchors.count > 2 else {
            points = []
            return
        }

        let before = Self.samples(milliseconds: rules.keptBeforeMs)
        let after = Self.samples(milliseconds: rules.keptAfterMs)
        let quiet = Self.pauses(in: 0..<length, sound: sound)
        var laid: [Laid] = []
        for index in 0..<(anchors.count - 1) {
            let from = anchors[index]
            let to = anchors[index + 1]
            if index > 0 { laid.append(Laid(point: from, isFixed: true)) }
            laid += Self.between(
                from, to,
                // The start and the end of the take are no syllables, so nothing is kept around them.
                keptAfter: index > 0 ? after : 0,
                keptBefore: index + 2 < anchors.count ? before : 0,
                pauses: quiet, rules: rules
            )
        }

        // Only forward. A point that does not lie after the one before it, in the take and in the sped-up
        // sound, goes: it can only be one that rounding put on its neighbour. A fixed point always stays.
        var kept: [Laid] = []
        for next in laid {
            if next.isFixed {
                while let last = kept.last, !last.isFixed,
                    last.point.source >= next.point.source || last.point.target >= next.point.target
                {
                    kept.removeLast()
                }
            }
            if let last = kept.last, next.point.source <= last.point.source || next.point.target <= last.point.target {
                continue
            }
            kept.append(next)
        }
        points = kept.map(\.point)
    }

    /// Where a sample of the slow take is heard in the sped-up sound. Between two points the place changes
    /// evenly from one to the other. A sample before the take counts as its start, one after it as its end.
    public func target(ofSource sample: Int) -> Int {
        guard sample > 0 else { return 0 }
        guard sample < sourceLength else { return targetLength }
        var earlier = Point(source: 0, target: 0)
        var later = Point(source: sourceLength, target: targetLength)
        // The last point at or before the sample, and the one after it.
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].source <= sample { low = middle + 1 } else { high = middle }
        }
        if low > 0 { earlier = points[low - 1] }
        if low < points.count { later = points[low] }
        let share = Double(sample - earlier.source) / Double(later.source - earlier.source)
        return earlier.target + Int((share * Double(later.target - earlier.target)).rounded())
    }

    // MARK: The parts

    /// A point of the plan while it is laid out. A fixed one is a syllable start or the edge of a kept
    /// stretch: its two numbers are exact. The others are where a pause meets sound, and are rounded.
    private struct Laid {
        var point: Point
        var isFixed: Bool
    }

    /// The points between two fixed moments that follow each other, without those two themselves.
    ///
    /// - Parameters:
    ///   - keptAfter: how many samples after `from` keep their length, at most.
    ///   - keptBefore: how many samples before `to` keep their length, at most.
    private static func between(
        _ from: Point, _ to: Point, keptAfter: Int, keptBefore: Int, pauses: [Range<Int>], rules: Rules
    ) -> [Laid] {
        let length = to.source - from.source
        // How many samples have to go.
        let taken = length - (to.target - from.target)
        guard taken > 0 else { return [] }

        // What is left between the two kept stretches when they are `scale` 1024ths of their full length, and
        // how much of it is pause.
        func middle(_ scale: Int) -> (range: Range<Int>, pause: Int)? {
            let start = from.source + keptAfter * scale / 1024
            let end = to.source - keptBefore * scale / 1024
            guard start < end else { return nil }
            return (start..<end, pauses.reduce(0) { $0 + $1.clamped(to: start..<end).count })
        }
        // Whether that middle can lose what has to go without a pause or a piece of sound getting too short.
        func canTake(_ scale: Int) -> Bool {
            guard let middle = middle(scale) else { return false }
            let sound = middle.range.count - middle.pause
            return (1 - rules.pauseShortestShare) * Double(middle.pause)
                + (1 - rules.soundShortestShare) * Double(sound) >= Double(taken)
        }
        // The longest kept stretches that leave enough to take the time from. Shorter ones always leave more.
        // With none that do, even with nothing kept, the stretch between the two moments is squeezed evenly.
        guard canTake(0) else { return [] }
        var scale = 0
        if canTake(1024) {
            scale = 1024
        } else {
            var tooLong = 1024
            while tooLong - scale > 1 {
                let tried = (scale + tooLong) / 2
                if canTake(tried) { scale = tried } else { tooLong = tried }
            }
        }
        guard let middle = middle(scale) else { return [] }

        // The pauses give what they can, the sound gives the rest, each piece by the same share of its length.
        let pause = Double(middle.pause)
        let sound = Double(middle.range.count) - pause
        let fromPauses = min(Double(taken), (1 - rules.pauseShortestShare) * pause)
        let pauseShare = pause > 0 ? (pause - fromPauses) / pause : 1
        let soundShare = sound > 0 ? (sound - (Double(taken) - fromPauses)) / sound : 1

        var laid: [Laid] = []
        let keptStart = middle.range.lowerBound - from.source
        let keptEnd = to.source - middle.range.upperBound
        if keptStart > 0 {
            laid.append(Laid(point: Point(source: middle.range.lowerBound, target: from.target + keptStart), isFixed: true))
        }
        var source = middle.range.lowerBound
        var target = Double(from.target + keptStart)
        func lay(to end: Int, share: Double) {
            guard end > source else { return }
            target += Double(end - source) * share
            source = end
            if source < middle.range.upperBound {
                laid.append(Laid(point: Point(source: source, target: Int(target.rounded())), isFixed: false))
            }
        }
        for quiet in pauses {
            let part = quiet.clamped(to: middle.range)
            guard !part.isEmpty else { continue }
            lay(to: part.lowerBound, share: soundShare)
            lay(to: part.upperBound, share: pauseShare)
        }
        lay(to: middle.range.upperBound, share: soundShare)
        if keptEnd > 0 {
            laid.append(Laid(point: Point(source: middle.range.upperBound, target: to.target - keptEnd), isFixed: true))
        }
        return laid
    }

    /// The stretches of a take without sound, in order: what lies between the stretches with sound.
    private static func pauses(in take: Range<Int>, sound: [Range<Int>]) -> [Range<Int>] {
        var pauses: [Range<Int>] = []
        var from = take.lowerBound
        for stretch in sound.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let part = stretch.clamped(to: take)
            guard !part.isEmpty else { continue }
            if part.lowerBound > from { pauses.append(from..<part.lowerBound) }
            from = max(from, part.upperBound)
        }
        if from < take.upperBound { pauses.append(from..<take.upperBound) }
        return pauses
    }

    /// The sample of the sped-up sound that a sample of the slow take stands for by the rate alone.
    private static func target(of sample: Int, at rate: Double) -> Int {
        Int((Double(sample) * rate).rounded())
    }

    private static func samples(milliseconds: Double) -> Int {
        let samples = (milliseconds * Lockstep.sampleRate / 1_000).rounded()
        guard samples.isFinite, samples > 0, samples < 1e9 else { return 0 }
        return Int(samples)
    }
}

// MARK: - The finished take at full tempo

extension SpeedUpPlan {
    /// A take that was finished in slow time, as it goes into the project: in song time.
    ///
    /// - The recording counts in its sped-up sound from here on: its length is that of the sped-up sound, and
    ///   its place and its delay are those of song time (both times the rate). `recordedSpeed` says that its
    ///   file holds the take as it was recorded, slow.
    /// - The clip's first and last sample go through the plan's own map, not a plain multiplication, so the
    ///   clip's edges are where the sound is. So do the markers that are excluded.
    ///
    /// - Parameters:
    ///   - recording: the take as the recording code finished it: its length, its place and its delay are in
    ///     slow time, and its length is this plan's `sourceLength`.
    ///   - clip: the part of the slow take that becomes its clip, or nil for a take that is thrown away.
    public func atFullTempo(_ recording: Recording, clip: Range<Int>?) -> (recording: Recording, clip: Range<Int>?) {
        guard rate < 1 else { return (recording, clip) }
        var mapped = recording
        mapped.lengthSamples = targetLength
        mapped.rawStart = recording.rawStart * rate
        mapped.delay = recording.delay * rate
        mapped.excludedMarkers = recording.excludedMarkers.map(target(ofSource:))
        mapped.recordedSpeed = rate
        let mappedClip = clip.map { target(ofSource: $0.lowerBound)..<target(ofSource: $0.upperBound) }
        return (mapped, mappedClip)
    }
}

import Foundation

/// Made-up content for the design lab: a 64-second song with a drifting beat,
/// four tracks and a dozen clips, one of each kind the design must show.
/// The same numbers come out every time, so pictures of the designs compare.
public enum SampleContent {
    static let songLength: Double = 64
    static let blocksPerSecond: Double = 100

    public static func make() -> TimelineContent {
        var random = SeededRandom(seed: 0x10C5_7E9)
        let grid = makeBeats()
        let songLevels = makeSongLevels(beatTimes: grid.allTimes, random: &random)

        // The selected clip has five takes; the third one plays.
        let takeRange = 16.0...19.5
        let takeRows = (1...5).map { number in
            TakeRow(
                number: number,
                displayName: "Take \(number)",
                levels: makeVoiceLevels(duration: takeRange.upperBound - takeRange.lowerBound, random: &random),
                isActive: number == 3
            )
        }

        func clip(
            _ id: Int,
            _ name: String,
            _ ranges: [ClosedRange<Double>],
            muted: Bool = false,
            volumeDB: Double = 0,
            isTriplet: Bool = false
        ) -> ClipBox {
            ClipBox(
                id: uuid(id),
                displayName: name,
                segments: ranges.map { range in
                    ClipSegment(
                        range: range,
                        levels: makeVoiceLevels(duration: range.upperBound - range.lowerBound, random: &random)
                    )
                },
                muted: muted,
                volumeDB: volumeDB,
                isTriplet: isTriplet
            )
        }

        let manyTakes = ClipBox(
            id: uuid(106),
            displayName: "Told myself I'd make it through",
            segments: [ClipSegment(range: takeRange, levels: takeRows[2].levels)],
            isSelected: true,
            takeCount: 5,
            activeTakeNumber: 3
        )

        let tracks = [
            TrackRow(id: uuid(1), name: "Lead", clips: [
                clip(101, "Woke up early, city still asleep", [2.0...5.5]),
                clip(102, "Streets remember every word I said", [12.4...14.6]),
                clip(103, "Every bar another step ahead", [30.0...32.8], isTriplet: true),
            ]),
            TrackRow(id: uuid(2), name: "Lead 2", muted: true, clips: [
                clip(104, "Clock keeps ticking but I hold my ground", [6.5...9.0]),
                clip(105, "Subway lights are flickering below", [34.0...36.4]),
            ]),
            TrackRow(id: uuid(3), name: "Double", isSelected: true, clips: [
                manyTakes,
                clip(108, "Building something out of nothing", [22.0...23.4, 24.2...25.5]),
                clip(109, "Writing lines until the morning", [40.0...42.6], volumeDB: 4),
            ]),
            TrackRow(id: uuid(4), name: "Ad-libs", clips: [
                clip(110, "Nobody knows where we are going", [10.0...11.6], muted: true),
                clip(111, "Hook v2", [26.0...29.5]),
                clip(112, "Cold concrete under my shoes", [44.0...47.2]),
                clip(113, "Keep the rhythm till the sun comes up", [52.0...53.2]),
            ]),
        ]

        return TimelineContent(
            songName: "Night Shift",
            songLength: songLength,
            songLevels: songLevels,
            beatLines: grid.lines,
            uncertainRanges: [grid.uncertainRange],
            unfilledGaps: [grid.gap],
            trackRows: tracks,
            takeRows: takeRows,
            playheadTime: 20.0,
            tempoText: "91.4",
            timeText: "0:20"
        )
    }

    /// Made-up content that is much heavier than `make()`: a song of three and
    /// a half minutes with 12 tracks and 200 clips, each with a bar and a
    /// name. The design lab uses it to measure how fast the timeline draws
    /// (`-state Stress`). The same numbers come out every time.
    ///
    /// Like `make()` it has one selected track and one selected clip with five
    /// takes, so every panel of a layout has something to show.
    public static func makeStress() -> TimelineContent {
        let length = stressSongLength
        var random = SeededRandom(seed: 0x57E5_5ED)
        let grid = makeBeats(songLength: length)
        let songLevels = makeSongLevels(beatTimes: grid.allTimes, songLength: length, random: &random)

        var tracks: [TrackRow] = []
        var takeRows: [TakeRow] = []
        var clipNumber = 0
        for trackIndex in 0..<stressTrackNames.count {
            // 200 clips over 12 tracks: 17 on each of the first eight tracks
            // and 16 on each of the last four.
            let trackCount = stressTrackNames.count
            let clipsOnTrack = stressClipCount / trackCount + (trackIndex < stressClipCount % trackCount ? 1 : 0)
            // Every clip gets a stretch of the song of its own, so no two
            // clips of a track overlap.
            let slot = length / Double(clipsOnTrack)
            let isSelectedTrack = trackIndex == 2

            var clips: [ClipBox] = []
            for slotIndex in 0..<clipsOnTrack {
                clipNumber += 1
                let duration = 2.0 + 4.0 * Double(random.unit())
                let start = Double(slotIndex) * slot + (slot - duration - 0.5) * Double(random.unit())
                let name = stressClipNames[clipNumber % stressClipNames.count]

                if isSelectedTrack, slotIndex == 1 {
                    // The selected clip has five takes; the third one plays.
                    takeRows = (1...5).map { number in
                        TakeRow(
                            number: number,
                            displayName: "Take \(number)",
                            levels: makeVoiceLevels(duration: duration, random: &random),
                            isActive: number == 3
                        )
                    }
                    clips.append(ClipBox(
                        id: uuid(1000 + clipNumber),
                        displayName: name,
                        segments: [ClipSegment(range: start...(start + duration), levels: takeRows[2].levels)],
                        isSelected: true,
                        takeCount: 5,
                        activeTakeNumber: 3
                    ))
                    continue
                }

                // Every ninth clip is joined from two pieces with a gap between.
                let ranges = clipNumber % 9 == 0
                    ? [start...(start + 0.45 * duration), (start + 0.55 * duration)...(start + duration)]
                    : [start...(start + duration)]
                let hasTakes = clipNumber % 5 == 0
                clips.append(ClipBox(
                    id: uuid(1000 + clipNumber),
                    displayName: name,
                    segments: ranges.map { range in
                        ClipSegment(
                            range: range,
                            levels: makeVoiceLevels(duration: range.upperBound - range.lowerBound, random: &random)
                        )
                    },
                    muted: clipNumber % 11 == 0,
                    takeCount: hasTakes ? 3 : 1,
                    activeTakeNumber: hasTakes ? 2 : 1,
                    volumeDB: clipNumber % 13 == 0 ? 4 : 0,
                    isTriplet: clipNumber % 7 == 0
                ))
            }
            tracks.append(TrackRow(
                id: uuid(trackIndex + 1),
                name: stressTrackNames[trackIndex],
                muted: trackIndex == 4,
                isSelected: isSelectedTrack,
                clips: clips
            ))
        }

        return TimelineContent(
            songName: "Stress, 200 clips",
            songLength: length,
            songLevels: songLevels,
            beatLines: grid.lines,
            uncertainRanges: [grid.uncertainRange],
            unfilledGaps: [grid.gap],
            trackRows: tracks,
            takeRows: takeRows,
            playheadTime: 20.0,
            tempoText: "91.4",
            timeText: "0:20"
        )
    }

    static let stressSongLength: Double = 210
    static let stressClipCount = 200
    static let stressTrackNames = [
        "Lead 1", "Lead 2", "Verse 1", "Verse 2", "Hook 1", "Hook 2",
        "Adlib 1", "Adlib 2", "Double 1", "Double 2", "Harmony", "Whisper",
    ]
    static let stressClipNames = [
        "Woke up early, city still asleep",
        "Streets remember every word I said",
        "Every bar another step ahead",
        "Clock keeps ticking but I hold my ground",
        "Subway lights are flickering below",
        "Told myself I'd make it through",
        "Building something out of nothing",
        "Writing lines until the morning",
        "Nobody knows where we are going",
        "Hook v2",
        "Cold concrete under my shoes",
        "Keep the rhythm till the sun comes up",
    ]

    /// Beats from 90.9 BPM drifting to 92.4, with an unsure stretch of 8 beats
    /// in the middle and a gap of 6 beats near the end where no beat was placed.
    private static func makeBeats(songLength: Double = songLength) -> (
        lines: [BeatLine], allTimes: [Double], uncertainRange: ClosedRange<Double>, gap: ClosedRange<Double>
    ) {
        var times: [Double] = []
        var time = 0.2
        while time < songLength {
            times.append(time)
            let bpm = 90.9 + (92.4 - 90.9) * time / songLength
            time += 60 / bpm
        }

        let uncertainBeats = 56...63
        let gapBeats = 86...91
        var lines: [BeatLine] = []
        for (number, time) in times.enumerated() where !gapBeats.contains(number) {
            lines.append(BeatLine(
                time: time,
                isBarStart: number % 4 == 0,
                isEstimated: uncertainBeats.contains(number)
            ))
        }
        return (
            lines,
            times,
            times[uncertainBeats.lowerBound]...times[uncertainBeats.upperBound],
            times[gapBeats.lowerBound - 1]...times[gapBeats.upperBound + 1]
        )
    }

    /// A drum hit on every beat that dies away quickly, with quieter noise between.
    private static func makeSongLevels(
        beatTimes: [Double],
        songLength: Double = songLength,
        random: inout SeededRandom
    ) -> WaveformLevels {
        let count = Int(songLength * blocksPerSecond)
        var minimums = [Float](repeating: 0, count: count)
        var maximums = [Float](repeating: 0, count: count)
        var beatIndex = 0
        for block in 0..<count {
            let time = Double(block) / blocksPerSecond
            while beatIndex + 1 < beatTimes.count, beatTimes[beatIndex + 1] <= time {
                beatIndex += 1
            }
            let sinceBeat = time - beatTimes[beatIndex]
            let hit = sinceBeat >= 0 ? 0.85 * exp(-sinceBeat / 0.07) : 0
            let noise = 0.12 + 0.1 * Double(random.unit())
            let level = Float(min(hit + noise, 1)) * (0.85 + 0.15 * random.unit())
            maximums[block] = level
            minimums[block] = -level * (0.8 + 0.2 * random.unit())
        }
        return WaveformLevels(minimums: minimums, maximums: maximums)
    }

    /// Bursts of syllables a few times a second, fading in and out at the edges.
    private static func makeVoiceLevels(duration: Double, random: inout SeededRandom) -> WaveformLevels {
        let count = max(Int(duration * blocksPerSecond), 1)
        let syllablesPerSecond = 4.0 + 2.0 * Double(random.unit())
        let phase = Double(random.unit()) * 2 * .pi
        var minimums = [Float](repeating: 0, count: count)
        var maximums = [Float](repeating: 0, count: count)
        for block in 0..<count {
            let time = Double(block) / blocksPerSecond
            let syllable = abs(sin(time * syllablesPerSecond * .pi + phase))
            let edge = min(time, duration - time, 0.05) / 0.05
            let level = Float((0.15 + 0.55 * syllable) * edge) * (0.75 + 0.25 * random.unit())
            maximums[block] = level
            minimums[block] = -level * (0.85 + 0.15 * random.unit())
        }
        return WaveformLevels(minimums: minimums, maximums: maximums)
    }

    /// A fixed identity made from a small number, so the same item keeps its id.
    private static func uuid(_ number: Int) -> UUID {
        let low = UInt8(number & 0xFF)
        let high = UInt8((number >> 8) & 0xFF)
        return UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, high, low))
    }
}

/// A small random number source that always gives the same numbers for the same
/// seed (SplitMix64).
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number from 0 up to, but not including, 1.
    mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }
}

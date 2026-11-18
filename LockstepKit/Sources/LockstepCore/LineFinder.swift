import Foundation

// Lines: the stretches of a clip that are rapped in one go, with a pause before and after.
// Tightening slides each line as a whole, so the first step is to find where the lines are.
//
//     let levels = VoiceLevels(
//         values: envelope.values,                                          // from `VoiceEnvelope`
//         threshold: envelope.noiseFloor + VoiceEnvelope.clearlyAboveDecibels,
//         hopSamples: VoiceEnvelope.hopSamples
//     )
//     let lines = LineFinder.lines(
//         in: clip, levels: [recording.id: levels], markers: markersByRecording, pauseMs: 250
//     )
//     // lines[0] holds the lines of clip.segments[0], in the order they are rapped

/// How loud the voice is through a recording, as plain numbers: one value for every `hopSamples`
/// samples, and the level above which a value counts as sound.
///
/// The numbers come from the recording's `VoiceEnvelope`, which lives in the audio layer. They are
/// handed over like this so the search for lines stays pure arithmetic.
public struct VoiceLevels: Sendable, Equatable {
    /// One value per hop, in decibels. Value `i` belongs to samples `i * hopSamples ..< (i + 1) * hopSamples`
    /// of the recording.
    public var values: [Float]
    /// A value above this is sound, and one at or below it is pause. In decibels: the recording's noise floor
    /// plus the distance that counts as clearly above it.
    public var threshold: Float
    /// How many samples lie between two values. 48 is one millisecond.
    public var hopSamples: Int

    public init(values: [Float], threshold: Float, hopSamples: Int = 48) {
        self.values = values
        self.threshold = threshold
        self.hopSamples = hopSamples
    }
}

/// One line of a recording: sound with a pause on both sides, or with a cut on a side.
///
/// All positions are samples of the recording at 48,000 Hz, so a line does not change when its clip is moved.
public struct VoiceLine: Sendable, Equatable {
    /// The first sample of the line: a little before the sound rises.
    public var startSample: Int
    /// One past the last sample: a little after the sound has died away.
    public var endSample: Int
    /// The syllable markers inside the line, as their sample positions, earliest first.
    public var markers: [Int]

    public init(startSample: Int, endSample: Int, markers: [Int] = []) {
        self.startSample = startSample
        self.endSample = endSample
        self.markers = markers
    }

    /// What tells this line from the others of its recording: the position of its first marker. A line with
    /// no markers has none. It is kept, so its sound is known to be a line, but nothing can say where it
    /// should sit on the beat, so it is never shifted.
    public var identity: Int? {
        markers.first
    }

    /// How many samples the line has.
    public var lengthSamples: Int {
        max(0, endSample - startSample)
    }
}

/// Finds the lines of a clip by looking for the pauses between them.
///
/// - A pause is a stretch of at least `pauseMs` in which no value is above the threshold.
/// - A line is the sound between two pauses. It starts 10 ms before the sound rises above the threshold and
///   ends 30 ms after it falls below, so the soft start of a word and its tail belong to the line.
/// - A cut also ends a line: no line reaches outside the stretch of the recording its segment plays, so a
///   line never spans a split or a gap in a clip.
/// - Two lines never share a sample.
public enum LineFinder {
    /// How long a pause must be to separate two lines, in milliseconds, until the setting
    /// `timing.linePauseMs` says otherwise.
    public static let defaultPauseMs: Double = 250
    /// How much before the rise of the sound still belongs to the line, in milliseconds.
    public static let marginBeforeMs: Double = 10
    /// How much after the fall of the sound still belongs to the line, in milliseconds.
    public static let marginAfterMs: Double = 30

    /// The lines of every segment of a clip: one list per segment, in the order of `clip.segments`, each list
    /// in the order of the recording.
    ///
    /// - Parameters:
    ///   - levels: how loud each recording is, by recording id. A segment whose recording is missing here
    ///     has no lines.
    ///   - markers: the syllable markers of each recording, by recording id, each list in the order of its
    ///     recording.
    ///   - pauseMs: how long a pause must be to separate two lines: the setting `timing.linePauseMs`.
    public static func lines(
        in clip: Clip,
        levels: [UUID: VoiceLevels],
        markers: [UUID: [SyllableMarker]],
        pauseMs: Double = defaultPauseMs
    ) -> [[VoiceLine]] {
        clip.segments.map { segment in
            guard let level = levels[segment.recordingID] else { return [] }
            let first = max(segment.inSample, 0)
            return lines(
                in: first..<max(segment.outSample, first),
                levels: level,
                markers: (markers[segment.recordingID] ?? []).map(\.sample),
                pauseMs: pauseMs
            )
        }
    }

    /// The lines inside one stretch of a recording, earliest first.
    ///
    /// - Parameters:
    ///   - range: the samples of the recording to look at: what one segment plays. The edges of the range
    ///     end a line just as a pause does.
    ///   - levels: how loud the recording is.
    ///   - markers: the sample positions of the recording's syllable markers, earliest first.
    ///   - pauseMs: how long a pause must be to separate two lines.
    public static func lines(
        in range: Range<Int>,
        levels: VoiceLevels,
        markers: [Int],
        pauseMs: Double = defaultPauseMs
    ) -> [VoiceLine] {
        let hop = levels.hopSamples
        guard hop > 0, !range.isEmpty, range.lowerBound >= 0 else { return [] }
        let pause = max(samples(milliseconds: pauseMs), 1)

        // The stretches of sound, in samples and kept inside the range. Two that are less than a pause apart
        // are one.
        var sounds: [Range<Int>] = []
        let lastHop = min((range.upperBound - 1) / hop, levels.values.count - 1)
        var index = range.lowerBound / hop
        while index <= lastHop {
            guard levels.values[index] > levels.threshold else {
                index += 1
                continue
            }
            var end = index + 1
            while end <= lastHop, levels.values[end] > levels.threshold { end += 1 }
            let sound = max(index * hop, range.lowerBound)..<min(end * hop, range.upperBound)
            if let previous = sounds.last, sound.lowerBound - previous.upperBound < pause {
                sounds[sounds.count - 1] = previous.lowerBound..<sound.upperBound
            } else {
                sounds.append(sound)
            }
            index = end
        }

        // Each stretch of sound becomes a line by adding the margins. Where a pause is too short to hold the
        // tail of one line and the start of the next, they share it in the same proportion.
        let before = samples(milliseconds: marginBeforeMs)
        let after = samples(milliseconds: marginAfterMs)
        var lines: [VoiceLine] = []
        for (place, sound) in sounds.enumerated() {
            var start = max(sound.lowerBound - before, range.lowerBound)
            var end = min(sound.upperBound + after, range.upperBound)
            if place > 0 {
                start = max(start, meetingPoint(sounds[place - 1], sound, before: before, after: after))
            }
            if place + 1 < sounds.count {
                end = min(end, meetingPoint(sound, sounds[place + 1], before: before, after: after))
            }
            lines.append(VoiceLine(
                startSample: start,
                endSample: end,
                markers: markers.filter { $0 >= start && $0 < end }
            ))
        }
        return lines
    }

    /// Where the tail of one line and the start of the next meet when the pause between their sounds cannot
    /// hold both margins: the pause is shared 30 to 10, as the margins are.
    private static func meetingPoint(_ earlier: Range<Int>, _ later: Range<Int>, before: Int, after: Int) -> Int {
        let pause = later.lowerBound - earlier.upperBound
        guard before + after > 0 else { return earlier.upperBound }
        return earlier.upperBound + pause * after / (before + after)
    }

    private static func samples(milliseconds: Double) -> Int {
        let samples = (milliseconds * Lockstep.sampleRate / 1_000).rounded()
        guard samples.isFinite, samples > 0, samples < 1e9 else { return 0 }
        return Int(samples)
    }
}

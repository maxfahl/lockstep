import Foundation

/// Where the repeats of a stutter lie: the effect that plays the start of a word again and again on the
/// sub-beats of the song, until the word's stretch ends.
///
/// The piece that is repeated is the first sub-beat's length of the stretch. Every repeat is placed by the
/// song's beats, one sub-beat after the one before, so the stutter stays on the grid where the tempo drifts.
/// A stretch that starts a little off a sub-beat keeps that distance in every repeat, as an echo's repeats
/// do (`EchoRepeats`): the word's own start is never moved.
///
///     let plan = StutterPlan(stretch: effect.span, beats: recipe.beats, perBeat: recipe.perBeat)
///     for one in plan.repeats {
///         // the first `one.length` samples of the stretch are heard from sample `one.start` of the dry sound
///     }
///
/// Everything is in samples of a clip's dry sound, where a beat before the clip has a place below 0.
public struct StutterPlan: Sendable, Equatable {
    /// One time the piece is heard.
    public struct Repeat: Sendable, Equatable {
        /// The sample of the dry sound it starts on.
        public var start: Int
        /// How many samples of the piece it plays: all of it, or less where the next repeat or the end of
        /// the stretch comes first.
        public var length: Int

        public init(start: Int, length: Int) {
            self.start = start
            self.length = length
        }
    }

    /// How long the piece is where the song has no beats: 125 ms, a sixteenth at 120 beats a minute.
    public static let sliceWithoutBeats = Int(0.125 * Lockstep.sampleRate)

    /// How many samples from the start of the stretch are repeated.
    public var sliceLength: Int
    /// Every time the piece is heard, in order. The first is the piece where it is, at the stretch's start.
    /// No two overlap and none reaches past the stretch.
    public var repeats: [Repeat]

    /// The plan for a stretch of the dry sound.
    ///
    /// Where the song has no beats at the stretch's start (no beats at all, before the first or after the
    /// last, or inside a part of the song that was left without beats) the pieces are 125 ms long. Where the
    /// beats end inside the stretch, it goes on in pieces of the length it started with.
    ///
    /// - Parameters:
    ///   - stretch: the stretch, as samples of the dry sound.
    ///   - beats: the song's beats in rising order, as samples of the dry sound.
    ///   - perBeat: the clip's sub-beats per beat: 4 in sixteenths, 6 in triplets.
    public init(stretch: Range<Int>, beats: [Double], perBeat: Int) {
        guard !stretch.isEmpty else {
            sliceLength = 0
            repeats = []
            return
        }
        var starts = [stretch.lowerBound]
        // How far the first sub-beat after the stretch's start lies from it, where the beats say.
        var firstStep: Int?
        // Whether the grid stopped giving places before the stretch ended.
        var beatsEnded = true
        if perBeat >= 1, beats.count >= 2,
           let position = EchoRepeats.beatPosition(of: Double(stretch.lowerBound), in: beats) {
            let gap = EchoRepeats.usualDistance(in: beats) * EchoRepeats.gapFactor
            var number = 1
            while let place = EchoRepeats.place(
                ofBeatPosition: position + Double(number) / Double(perBeat), in: beats, from: position, gap: gap
            ) {
                let start = Int(place.rounded())
                if number == 1 {
                    guard start > stretch.lowerBound else { break }
                    firstStep = start - stretch.lowerBound
                }
                guard start < stretch.upperBound else {
                    beatsEnded = false
                    break
                }
                if start > starts[starts.count - 1] {
                    starts.append(start)
                }
                number += 1
            }
        }
        let slice = firstStep ?? Self.sliceWithoutBeats
        if beatsEnded {
            var next = starts[starts.count - 1] + slice
            while next < stretch.upperBound {
                starts.append(next)
                next += slice
            }
        }

        sliceLength = min(slice, stretch.count)
        repeats = starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : stretch.upperBound
            return Repeat(start: start, length: min(slice, end - start))
        }
    }
}

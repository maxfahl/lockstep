import Foundation

/// Where each repeat of an echo is heard, read from the song's beats.
///
/// An echo here is not a delay line with one fixed time. A song's tempo drifts, so every repeat is placed by
/// the beats: repeat k of a sound that starts at beat position p is heard where the beats put position
/// p + k × the note (a quarter note is one beat, an eighth note half a beat). A sound between two beats keeps
/// its place between the two beats each repeat lands on.
///
///     let repeats = EchoRepeats.repeats(ofSoundAt: 0, note: .eighth, levelDb: -12, beats: recipe.beats)
///     // repeats[0].position: the sample of the dry sound the first repeat starts on, at -12 dB
///
/// The positions are in whatever the beats are in: song seconds, or samples of a clip's dry sound (where
/// beats before the clip have positions below 0).
public enum EchoRepeats {
    /// One repeat of the sound.
    public struct Repeat: Sendable, Equatable {
        /// 1 for the first repeat.
        public var number: Int
        /// Where the repeat starts, in the unit of the beats.
        public var position: Double
        /// How loud it is against the sound it repeats.
        public var gainDb: Double

        public init(number: Int, position: Double, gainDb: Double) {
            self.number = number
            self.position = position
            self.gainDb = gainDb
        }
    }

    /// How much quieter each repeat is than the one before, in dB.
    public static let fallDb = 6.0
    /// A repeat quieter than this is not made, and none after it.
    public static let floorDb = -40.0
    /// The furthest a repeat lies after its sound, in beats: two bars.
    public static let reachBeats = Double(2 * Grid.beatsPerBar)
    /// Two beats further apart than this many times the usual distance have a stretch without beats between
    /// them. A drifting tempo never comes near it.
    static let gapFactor = 1.75

    /// The repeats of a sound that starts at `position`, first to last.
    ///
    /// The first repeat is as loud as `levelDb` says and each one after it `fallDb` quieter. They stop when
    /// the next would be below `floorDb`, would lie more than two bars after the sound, or would lie where
    /// there are no beats: after the last beat, or beyond a stretch of the song that was left without beats.
    /// A sound that itself starts where there are no beats has no repeats.
    ///
    /// - Parameter beats: the beats in rising order, in the unit of `position`.
    public static func repeats(
        ofSoundAt position: Double,
        note: ChainParameters.Echo.Note,
        levelDb: Double,
        beats: [Double]
    ) -> [Repeat] {
        guard beats.count >= 2, let start = beatPosition(of: position, in: beats) else { return [] }
        let gap = usualDistance(in: beats) * gapFactor
        let step = note == .quarter ? 1.0 : 0.5

        var repeats: [Repeat] = []
        var number = 1
        while true {
            let gainDb = levelDb - fallDb * Double(number - 1)
            let distance = step * Double(number)
            guard gainDb >= floorDb, distance <= reachBeats,
                  let place = place(ofBeatPosition: start + distance, in: beats, from: start, gap: gap)
            else { break }
            repeats.append(Repeat(number: number, position: place, gainDb: gainDb))
            number += 1
        }
        return repeats
    }

    /// Where a position lies among the beats: 3.25 is a quarter of the way from the fourth beat to the fifth.
    /// Nil before the first beat and after the last.
    static func beatPosition(of position: Double, in beats: [Double]) -> Double? {
        guard let first = beats.first, let last = beats.last, position >= first, position <= last else {
            return nil
        }
        // The last beat at or before the position.
        var low = 0
        var high = beats.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if beats[middle] <= position { low = middle } else { high = middle - 1 }
        }
        guard low < beats.count - 1 else { return Double(low) }
        let length = beats[low + 1] - beats[low]
        return Double(low) + (length > 0 ? (position - beats[low]) / length : 0)
    }

    /// The distance between the two beats around a position, or nil where there are no beats: before the
    /// first beat, after the last, and inside a stretch of the song that was left without beats. For what
    /// is measured in beats without being repeated, as the length of a swell into a word.
    public static func beatLength(at position: Double, in beats: [Double]) -> Double? {
        guard beats.count >= 2, let place = beatPosition(of: position, in: beats) else { return nil }
        let index = min(Int(place.rounded(.down)), beats.count - 2)
        let length = beats[index + 1] - beats[index]
        return length > 0 && length <= usualDistance(in: beats) * gapFactor ? length : nil
    }

    /// The place of a beat position, or nil where the beats end before it or where a stretch without beats
    /// lies between `start` and it. A position inside such a stretch, `start` itself included, has no place.
    static func place(
        ofBeatPosition beatPosition: Double, in beats: [Double], from start: Double, gap: Double
    ) -> Double? {
        guard beatPosition <= Double(beats.count - 1) else { return nil }
        // Every pair of neighbouring beats the way from `start` to the position passes between.
        let first = Int(start.rounded(.down))
        let last = min(Int(beatPosition.rounded(.up)), beats.count - 1)
        for index in first..<last where beats[index + 1] - beats[index] > gap {
            return nil
        }
        let index = min(Int(beatPosition.rounded(.down)), beats.count - 2)
        let share = beatPosition - Double(index)
        return beats[index] + share * (beats[index + 1] - beats[index])
    }

    /// The middle one of the distances between neighbouring beats.
    static func usualDistance(in beats: [Double]) -> Double {
        let distances = zip(beats, beats.dropFirst()).map { $1 - $0 }.sorted()
        return distances[distances.count / 2]
    }
}

import Accelerate
import Foundation
import LockstepCore

/// An echo whose repeats land on the song's real beats: the echo of the voice chain's space, and the echo on
/// a word of phase 35.
///
/// It is our own code and not a delay unit, because a delay has one fixed time and a song's tempo drifts.
/// `EchoRepeats` of LockstepCore says where each repeat starts and how loud it is, and this lays the sound
/// there: each repeat a copy of the source, quieter and a little darker than the one before.
///
///     var sound = voiceWithRoomForItsTail
///     BeatEcho.add(repeatsOf: voice, startingAt: 0, note: .eighth, levelDb: -12, beats: beats, to: &sound)
///
/// For the chain the source is the whole voice, starting at sample 0. For a word it is the word, starting
/// where the word starts. A repeat is never moved off its place by its darkening: the filter that darkens it
/// is run forwards and backwards.
enum BeatEcho {
    /// Above this the first repeat keeps its sound, in Hz. Each repeat after it closes further.
    static let firstRepeatHz = 5_000.0
    /// How much lower each repeat closes than the one before.
    static let closing = 0.8

    /// Where the repeats of a sound that starts on sample `start` begin, as whole samples.
    ///
    /// - Parameter beats: the beats as samples of the sound the repeats are laid into.
    static func repeats(
        startingAt start: Int, note: ChainParameters.Echo.Note, levelDb: Double, beats: [Double]
    ) -> [(sample: Int, gain: Float, number: Int)] {
        EchoRepeats.repeats(ofSoundAt: Double(start), note: note, levelDb: levelDb, beats: beats).map {
            (Int($0.position.rounded()), Float(pow(10, $0.gainDb / 20)), $0.number)
        }
    }

    /// How many samples after the source's start its last repeat starts. 0 when it has no repeats.
    static func reach(startingAt start: Int, note: ChainParameters.Echo.Note, levelDb: Double, beats: [Double]) -> Int {
        (repeats(startingAt: start, note: note, levelDb: levelDb, beats: beats).last?.sample ?? start) - start
    }

    /// Adds the repeats of `source` to `sound`. What would lie after the end of `sound` is left out, so the
    /// caller makes `sound` as long as it wants the echo to ring.
    ///
    /// - Parameter start: the sample of `sound` the source starts on.
    static func add(
        repeatsOf source: StereoSound,
        startingAt start: Int,
        note: ChainParameters.Echo.Note,
        levelDb: Double,
        beats: [Double],
        to sound: inout StereoSound
    ) {
        let sameSides = source.left == source.right
        for one in repeats(startingAt: start, note: note, levelDb: levelDb, beats: beats)
        where one.sample < sound.left.count {
            let darker = VoiceFilter.lowPass(hz: firstRepeatHz * pow(closing, Double(one.number - 1)))
            let left = darker.filteredBothWays(source.left)
            let right = sameSides ? left : darker.filteredBothWays(source.right)
            let count = min(left.count, sound.left.count - one.sample)
            guard count > 0 else { continue }
            let place = one.sample..<(one.sample + count)
            sound.left.replaceSubrange(
                place, with: vDSP.add(multiplication: (left[..<count], one.gain), sound.left[place]))
            sound.right.replaceSubrange(
                place, with: vDSP.add(multiplication: (right[..<count], one.gain), sound.right[place]))
        }
    }
}

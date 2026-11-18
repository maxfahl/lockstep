import Accelerate
import Foundation
import LockstepCore
import Synchronization

/// What is heard during a take that is recorded slower: the song, and the row of the other voices, made
/// longer at the same pitch (phase 31).
///
/// The player is not taught a speed. It is handed sound that is already slow, so the song, the click and the
/// clips stay on the sample as they do at full speed.
///
///     let slowSong = await SlowedBacking.slowed(song.samples, channels: 2, rate: 0.85) { done in
///         // done goes from 0 to 1, told from the background
///     }
///     // nil when the task was cancelled on the way
///
/// The sound is made evenly longer by `1 / rate`, and is exactly `SlowTime.slowLength(ofSong:)` frames long,
/// so the slowed beats, cut and loop of `SlowTime` lie on it: frame `n` of the sound is heard on frame
/// `n / rate`, to the sample.
///
/// How it is made. The sound is divided into pieces of about twenty seconds, and every piece of every channel
/// is stretched by itself with `RubberBandStretcher`, as many at a time as the Mac has cores. That is what
/// makes a whole song ready in a few seconds, and what keeps every piece on the sample: the stretcher puts the
/// first and the last sample of what it is given exactly where it is told. A piece with no sound in it, which
/// is most of a row of voices, is not stretched at all. Each piece is made with a little of its neighbours at
/// both ends, and where two pieces meet the sound fades from one to the other over 20 ms.
///
/// Left and right are stretched apart. Both are on the sample, and what is the same in both comes out the
/// same in both, so a voice or a drum in the middle stays in the middle. This sound is only heard while a
/// take is recorded and is never kept.
///
/// Measured on 15 November 2026 on Max's Mac, in a debug build:
/// - A song of three and a half minutes in stereo is ready in 2.0 s, a row of voices of three minutes with
///   17 s of voice in it in 0.6 s, and an empty row at once. (The library's own two-channel call took 15 s
///   with its finer engine and 7 s with its faster one, and put the sound 3 to 5 ms early, which is why it
///   is not used.)
/// - A click in the song is heard within 1 ms of its place divided by the rate, and a tone keeps its pitch.
/// - What is not as it should be: two pieces are stretched apart, so their waves do not fit where they meet.
///   On a held tone the join was a dip of 10 ms, down to a quarter of the level at worst. Each join is put in
///   the quietest moment near it to be heard as little as it can.
public enum SlowedBacking {
    /// The length of one piece, in frames: twenty seconds, give or take a second (`edges`).
    static let pieceFrames = 960_000
    /// How much of its neighbour a piece is made with at each end, in frames: 50 ms. The outermost part of a
    /// stretched piece is the least exact, and is not used.
    static let marginFrames = 2_400
    /// Half the length of the fade from one piece to the next, in frames of the slowed sound: 10 ms.
    static let halfFadeFrames = 480

    /// Sound made longer by `1 / rate` at the same pitch.
    ///
    /// The work is done off the main thread, whoever calls it.
    ///
    /// - Parameters:
    ///   - samples: the sound at 48,000 Hz. With two channels they come in turn: left, right, left, right.
    ///   - channels: 1 or 2.
    ///   - rate: the speed of the take, as a share of the song's (`SlowTime.rate`). At 1 the sound comes back as it is.
    ///   - progress: told how far the work has come, from 0 to 1. It is called from background threads, and
    ///     not in order: use the largest value it was given.
    /// - Returns: `SlowTime(rate:).slowLength(ofSong:)` frames, in the same form as `samples`. Nil when the
    ///   task was cancelled before the sound was ready.
    @concurrent
    public static func slowed(
        _ samples: [Float],
        channels: Int,
        rate: Double,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> [Float]? {
        // The pieces are made on threads of their own, which do not know of this task. So the task's
        // cancelling is kept where they can see it.
        let cancelled = Atomic<Bool>(false)
        return await withTaskCancellationHandler {
            slowedNow(samples, channels: channels, rate: rate, progress: progress) {
                cancelled.load(ordering: .relaxed)
            }
        } onCancel: {
            cancelled.store(true, ordering: .relaxed)
        }
    }

    /// The same, started from the thread that calls it, which waits until all pieces are made. `isGivenUp`
    /// is asked before every piece, from the threads the pieces are made on.
    static func slowedNow(
        _ samples: [Float],
        channels: Int,
        rate: Double,
        progress: (@Sendable (Double) -> Void)? = nil,
        isGivenUp: @Sendable () -> Bool = { false }
    ) -> [Float]? {
        precondition(channels == 1 || channels == 2, "The song has two channels and a row of voices has one.")
        let slow = SlowTime(rate: rate)
        let frames = samples.count / channels
        guard slow.isSlow, frames > 0 else {
            progress?(1)
            return isGivenUp() ? nil : samples
        }
        let wanted = slow.slowLength(ofSong: frames)

        // One job is one piece of one channel. Each writes to a place of its own in `made`.
        let made = Mutex([[Float]?]())
        let done = Atomic<Int>(0)
        let stretcher = RubberBandStretcher()
        var edges: [Int] = []
        samples.withUnsafeBufferPointer { sound in
            // The sound is only read while the pieces are made, by all of them at once.
            nonisolated(unsafe) let sound = sound.baseAddress!
            edges = Self.edges(of: sound, frames: frames, channels: channels)
            let pieceEdges = edges
            let jobs = (edges.count - 1) * channels
            made.withLock { $0 = [[Float]?](repeating: nil, count: jobs) }
            DispatchQueue.concurrentPerform(iterations: jobs) { job in
                guard !isGivenUp() else { return }
                let piece = job / channels
                let channel = job % channels
                // The piece with its margins, held inside the sound.
                let first = max(pieceEdges[piece] - marginFrames, 0)
                let end = min(pieceEdges[piece + 1] + marginFrames, frames)
                var part = [Float](repeating: 0, count: end - first)
                Self.copy(end - first, from: sound + first * channels + channel, step: channels, to: &part, step: 1)
                var loudest: Float = 0
                vDSP_maxmgv(part, 1, &loudest, vDSP_Length(part.count))
                let length = slow.slowSample(forSong: end) - slow.slowSample(forSong: first)
                let slowed = loudest == 0
                    ? [Float](repeating: 0, count: length)
                    : stretcher.stretch(part, keyFrames: [], outputLength: length)
                made.withLock { $0[job] = slowed }
                progress?(Double(done.add(1, ordering: .relaxed).newValue) / Double(jobs))
            }
        }
        guard !isGivenUp() else { return nil }
        let pieces = made.withLock { $0 }
        let pieceCount = edges.count - 1
        let slowEdges = edges.map { slow.slowSample(forSong: $0) }

        // The pieces are laid one after the other. Each is used from the middle of the fade at its start to
        // the middle of the fade at its end, and inside a fade the two that meet are mixed.
        var result = [Float](repeating: 0, count: wanted * channels)
        for job in pieces.indices {
            guard let slowed = pieces[job] else { return nil }
            let piece = job / channels
            let channel = job % channels
            // Where this piece's first frame lies in the slowed sound.
            let origin = slow.slowSample(forSong: max(edges[piece] - marginFrames, 0))
            let fadeIn = piece > 0 ? halfFadeFrames : 0
            let fadeOut = piece + 1 < pieceCount ? halfFadeFrames : 0
            let from = max(slowEdges[piece] - fadeIn, origin, 0)
            let to = min(slowEdges[piece + 1] + fadeOut, origin + slowed.count, wanted)
            // What lies between the two fades is this piece alone.
            let bodyFrom = min(from + 2 * fadeIn, to)
            let bodyTo = max(to - 2 * fadeOut, bodyFrom)
            slowed.withUnsafeBufferPointer { slowed in
                result.withUnsafeMutableBufferPointer { result in
                    Self.copy(
                        bodyTo - bodyFrom, from: slowed.baseAddress! + bodyFrom - origin, step: 1,
                        to: result.baseAddress! + bodyFrom * channels + channel, step: channels)
                }
            }
            for frame in from..<bodyFrom {
                result[frame * channels + channel] += Float(frame - from) / Float(2 * fadeIn) * slowed[frame - origin]
            }
            for frame in bodyTo..<to {
                result[frame * channels + channel] += Float(to - frame) / Float(2 * fadeOut) * slowed[frame - origin]
            }
        }
        return result
    }

    /// Copies `count` samples that lie `step` apart to places that lie `step` apart. A plain loop over a whole
    /// song takes seconds in a debug build, which is what Max runs.
    private static func copy(
        _ count: Int, from source: UnsafePointer<Float>, step sourceStep: Int,
        to target: UnsafeMutablePointer<Float>, step targetStep: Int
    ) {
        guard count > 0 else { return }
        var nothing: Float = 0
        vDSP_vsadd(source, sourceStep, &nothing, target, targetStep, vDSP_Length(count))
    }

    /// Where one piece ends and the next begins, in frames, with 0 first and `frames` last.
    ///
    /// The pieces are twenty seconds long, give or take a second: each place where two meet is moved to the
    /// quietest 20 ms within a second of it. Two pieces are stretched apart, so their waves do not fit at the
    /// join, and where they are mixed a held note can dip for a moment. In the quietest place that is heard
    /// least, and in a row of voices it is the silence between two clips, where there is nothing to hear.
    static func edges(of sound: UnsafePointer<Float>, frames: Int, channels: Int) -> [Int] {
        let hop = 240          // 5 ms
        let reach = 48_000     // a second to each side
        var edges = [0]
        var nominal = pieceFrames
        // A last piece shorter than half a piece is added to the one before it.
        while nominal <= frames - pieceFrames / 2 {
            let first = nominal - reach
            let hops = 2 * reach / hop
            // How loud each 5 ms is, all channels together.
            var energy = [Float](repeating: 0, count: hops)
            for index in 0..<hops {
                for channel in 0..<channels {
                    var sum: Float = 0
                    vDSP_svesq(sound + (first + index * hop) * channels + channel, channels, &sum, vDSP_Length(hop))
                    energy[index] += sum
                }
            }
            // The quietest four in a row. Of several that are as quiet, the one nearest the middle.
            var best = (index: hops / 2 - 2, energy: Float.infinity, distance: Int.max)
            for index in 0...(hops - 4) {
                let total = energy[index] + energy[index + 1] + energy[index + 2] + energy[index + 3]
                let distance = abs(index + 2 - hops / 2)
                if total < best.energy || (total == best.energy && distance < best.distance) {
                    best = (index, total, distance)
                }
            }
            edges.append(first + (best.index + 2) * hop)
            nominal += pieceFrames
        }
        edges.append(frames)
        return edges
    }
}

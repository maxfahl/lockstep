import Foundation
import LockstepCore
import Synchronization

/// Keeps the copies of the voice that doubles are made of, so the stretching library runs once for each.
///
/// A double is the clip's own voice pitched or resized by Rubber Band (`VoiceShifter`), which is the slow
/// part of making a clip's finished sound: about 40 ms for each second of voice and copy. What comes out
/// depends only on the dry sound, the stretch and the kind. So a turned knob of the track's Sound, a changed
/// level of the double, or the clip's own volume make the finished sound again without running the library:
///
///     let copies = DoubleLayerStore.shared.copies(
///         of: .lowOctave, on: 9_600..<24_000, ofDry: recipe.dry, samples: dry.count
///     ) { /* runs only when these copies are not kept */ }
///
/// How much it keeps: the copies of every double that was asked for, up to five minutes of sound in all
/// (`mostSamples`, about 58 MB). A Thick double on a clip of four seconds is eight seconds of that.
///
/// When it forgets: when a new set of copies would take it past five minutes, the sets that were asked for
/// longest ago go first. A set that alone is longer than five minutes is not kept at all. Nothing else makes
/// it forget, and nothing needs to: a clip that was trimmed, cut or corrected anew has another dry sound and
/// so another key, and its old copies are simply not asked for again. Nothing is kept on disk, and quitting
/// Lockstep forgets everything.
///
/// It is safe from any thread. Two threads that ask for the same copies at the same moment may both make
/// them, and get the same samples.
public final class DoubleLayerStore: Sendable {
    /// The one the app uses, for every clip of every project.
    public static let shared = DoubleLayerStore()

    /// The most it keeps, in samples of all copies together: five minutes at 48,000 Hz.
    public static let mostSamples = 5 * 60 * Int(Lockstep.sampleRate)

    /// What a set of copies was made from.
    private struct Key: Equatable {
        // The numbers come first, so most sets are told apart without going through the segments.
        var kind: ClipEffect.Kind
        var span: Range<Int>
        var drySamples: Int
        var dry: ClipSoundRecipe.DryIdentity
    }

    private struct Kept {
        /// The sets that are kept, the one asked for last at the end.
        var sets: [(key: Key, copies: [[Float]], samples: Int)] = []
        var samples = 0
        var made = 0
    }

    private let kept = Mutex(Kept())

    public init() {}

    /// How many sets of copies were made so far: how often the making was run, not how often it was asked.
    public var madeCount: Int {
        kept.withLock { $0.made }
    }

    /// How many samples it holds right now, in all copies together.
    public var keptSamples: Int {
        kept.withLock { $0.samples }
    }

    /// The copies of one double on one stretch of one dry sound, one for each layer of its kind
    /// (`DoubleLayers.plan(for:)`), in that order. They are as they came from the stretching library: not
    /// faded, not delayed and at the voice's own level.
    ///
    /// - Parameters:
    ///   - span: the stretch of the dry sound the double is on.
    ///   - dry: what the dry sound was made from. Two that are equal are the same sound.
    ///   - samples: how long the dry sound is. It is part of the key, so a dry sound that came out another
    ///     length than its identity promised never gets another sound's copies.
    ///   - make: makes the copies. It runs only when they are not kept, and outside the lock, so other
    ///     threads are not held up while the library works.
    func copies(
        of kind: ClipEffect.Kind,
        on span: Range<Int>,
        ofDry dry: ClipSoundRecipe.DryIdentity,
        samples: Int,
        make: () -> [[Float]]
    ) -> [[Float]] {
        let key = Key(kind: kind, span: span, drySamples: samples, dry: dry)
        let found = kept.withLock { kept -> [[Float]]? in
            guard let index = kept.sets.firstIndex(where: { $0.key == key }) else { return nil }
            // Asked for now, so it is the last to be forgotten.
            let set = kept.sets.remove(at: index)
            kept.sets.append(set)
            return set.copies
        }
        if let found { return found }

        let copies = make()
        let size = copies.reduce(0) { $0 + $1.count }
        kept.withLock { kept in
            kept.made += 1
            guard size <= Self.mostSamples, !kept.sets.contains(where: { $0.key == key }) else { return }
            kept.sets.append((key, copies, size))
            kept.samples += size
            while kept.samples > Self.mostSamples, !kept.sets.isEmpty {
                kept.samples -= kept.sets.removeFirst().samples
            }
        }
        return copies
    }
}

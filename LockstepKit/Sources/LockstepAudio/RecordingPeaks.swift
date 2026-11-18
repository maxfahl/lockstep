import Accelerate
import Foundation
import LockstepCore
import Synchronization

/// Measures the highest sample of stretches of recordings, and remembers every answer.
///
/// The safe limit needs to know how high a clip peaks before it lets the clip be raised (`Clip.appliedGain`).
/// `LockstepCore` has no sound, so it asks through a `RecordingPeak`, and this is what answers:
///
///     let peaks = RecordingPeaks()                    // one for as long as the app runs
///     let lookup = peaks.lookup(in: sounds)           // sounds: the recordings' samples by id
///     clip.appliedGain(peaks: lookup)
///     project.splitClip(id, at: playhead, peaks: lookup)
///
/// A stretch is measured once. Asking again, as the window does on every change, costs a look in a table. This
/// rests on the rule that a recording's samples never change: an answer is kept under the recording's id and
/// the stretch, and never measured again.
///
/// Safe to use from any thread.
public final class RecordingPeaks: Sendable {
    /// A stretch of a recording that was measured.
    private struct Stretch: Hashable {
        var recordingID: UUID
        var first: Int
        var end: Int
    }

    /// How many answers are kept before the table is emptied and filled again. Cuts make new stretches, and a
    /// project never has near this many at a time.
    private static let mostRemembered = 20_000

    private let measured = Mutex<[Stretch: Float]>([:])

    public init() {}

    /// The highest sample in a stretch of a recording: its size without its sign, where 1 is full scale.
    ///
    /// The stretch is kept inside the samples there are. A recording that is not in `sounds`, and a stretch with
    /// no samples in it, give 0.
    ///
    /// - Parameters:
    ///   - samples: the stretch, in samples of the recording.
    ///   - sounds: the recordings' sound by recording id: mono samples at 48,000 Hz. Only read.
    public func peak(of recordingID: UUID, samples: Range<Int>, in sounds: [UUID: [Float]]) -> Float {
        guard let sound = sounds[recordingID] else { return 0 }
        let first = min(max(samples.lowerBound, 0), sound.count)
        let end = min(max(samples.upperBound, first), sound.count)
        guard end > first else { return 0 }
        let stretch = Stretch(recordingID: recordingID, first: first, end: end)
        if let known = measured.withLock({ $0[stretch] }) {
            return known
        }
        var peak: Float = 0
        sound.withUnsafeBufferPointer { all in
            guard let start = all.baseAddress else { return }
            vDSP_maxmgv(start + first, 1, &peak, vDSP_Length(end - first))
        }
        measured.withLock { table in
            if table.count >= Self.mostRemembered {
                table.removeAll(keepingCapacity: true)
            }
            table[stretch] = peak
        }
        return peak
    }

    /// The question `LockstepCore` asks, answered from these sounds.
    public func lookup(in sounds: [UUID: [Float]]) -> RecordingPeak {
        { recordingID, samples in
            self.peak(of: recordingID, samples: samples, in: sounds)
        }
    }
}

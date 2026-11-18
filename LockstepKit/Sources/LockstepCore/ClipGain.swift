import Foundation

/// The highest sample in a stretch of a recording: its size without its sign, where 1 is full scale. 0 for a
/// stretch that is silent, or that there is no sound for.
///
/// `LockstepCore` holds no sound, so whoever has the recordings' samples answers this. In the app and in the
/// player that is `RecordingPeaks` of `LockstepAudio`, which measures the samples and remembers the answers:
///
///     let peaks = RecordingPeaks()                        // kept for as long as the project is open
///     project.clipPlaybackPlan(from: 0, peaks: peaks.lookup(in: sounds))
public typealias RecordingPeak = (_ recordingID: UUID, _ samples: Range<Int>) -> Float

/// The volume a clip is played with, after the safe limit had its say.
///
/// It is the clip's part of the volume only. Each segment adds its own `gainDb` on top.
public struct AppliedGain: Sendable, Equatable {
    /// What was asked for, in dB: what Normalize set plus what Max set.
    public var askedDb: Double
    /// What the clip is played with, in dB. The same as `askedDb`, or lower when the safe limit holds it back.
    public var db: Double

    public init(askedDb: Double, db: Double) {
        self.askedDb = askedDb
        self.db = db
    }

    /// Whether the safe limit holds the clip back: it is played more quietly than asked for.
    public var isHeldBack: Bool {
        db < askedDb
    }

    /// By how many dB the clip is held back. 0 when it is not.
    public var heldBackDb: Double {
        max(askedDb - db, 0)
    }
}

extension Clip {
    /// The safe limit: after its volume, a clip's highest sample stays at or below this, in dBFS.
    public static let safeLimitDb = -1.0

    /// The volume asked for, in dB, without the segments' own: what Normalize set plus what Max set.
    public var totalGainDb: Double {
        (normalizeGainDb ?? 0) + gainDb
    }

    /// The highest sample of what the clip plays, in dBFS, with each segment's own `gainDb` counted in and the
    /// clip's volume left out. Minus infinity for a clip that is silent or has no sound.
    ///
    /// It is the peak of `Loudness.samples(of:recording:)`, found without making that row of samples.
    public func peakDb(_ peaks: RecordingPeak) -> Double {
        var highest = -Double.infinity
        for segment in segments where segment.outSample > segment.inSample {
            let peak = Double(peaks(segment.recordingID, segment.inSample..<segment.outSample))
            guard peak > 0 else { continue }
            highest = max(highest, 20 * log10(peak) + segment.gainDb)
        }
        return highest
    }

    /// The volume the clip is played with: what was asked for, lowered when needed so that the clip's highest
    /// sample stays at or below -1 dBFS (`safeLimitDb`). There is no limiter. A clip is simply raised less.
    ///
    /// Everything that makes or shows the clip's sound uses this one answer: the player, the clip's drawing and
    /// the volume control's "held back" mark.
    ///
    /// - Parameter peaks: the highest sample of a stretch of a recording. See `RecordingPeak`.
    public func appliedGain(peaks: RecordingPeak) -> AppliedGain {
        Clip.appliedGain(askedDb: totalGainDb, peakDb: peakDb(peaks))
    }

    /// The safe limit worked out with numbers alone, for a clip whose highest sample is `peakDb` dBFS.
    public static func appliedGain(askedDb: Double, peakDb: Double) -> AppliedGain {
        // How far the clip can be raised before its highest sample passes the limit. Without end for silence.
        let room = safeLimitDb - peakDb
        // A millionth of a dB cannot be heard. Without it, a clip that sits exactly on the limit, as its parts
        // do after a split, would now and then count as held back because of how the numbers round.
        guard askedDb - room > 1e-6 else { return AppliedGain(askedDb: askedDb, db: askedDb) }
        return AppliedGain(askedDb: askedDb, db: room)
    }

    /// For when nothing is known about the recordings' sound: every stretch counts as silent, so no clip is held
    /// back. Only tests, and callers that have no samples yet, leave it at this.
    public static func unknownPeaks(_ recordingID: UUID, _ samples: Range<Int>) -> Float {
        0
    }
}

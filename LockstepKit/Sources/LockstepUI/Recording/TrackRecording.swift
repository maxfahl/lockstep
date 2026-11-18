import Foundation
import Observation

/// A recording that is going to a track right now. `TrackRow.recording` holds
/// it, and the track's row draws it with `RecordingClip`.
///
/// Before sound is kept, the song plays a run-up: the bars before the place
/// where the recording starts. During the run-up `recordedUntil` is nil, and
/// only the starting place is marked on the track.
///
///     track.recording = TrackRecording(origin: 20, recordedUntil: 23.4, levels: levels)
///
/// A real recording grows on every frame. Handing the window a new
/// `TrackRecording` each time would work the whole window out again, so the
/// real app sets `progress` once and then changes only that:
///
///     var recording = TrackRecording(origin: 20)
///     recording.progress = progress          // a `RecordingProgress` the app keeps
///     track.recording = recording
///     progress.recordedUntil = 20.5          // on every frame; only the red clip is drawn again
public struct TrackRecording: Sendable, Equatable {
    /// Where the recording starts, in song seconds: the place the playhead
    /// was at when Record was pressed.
    public var origin: Double
    /// How far the recording has come, in song seconds: the playhead. Nil
    /// during the run-up, when nothing has been recorded yet.
    public var recordedUntil: Double?
    /// The loudness of what has been recorded so far, spread from `origin`
    /// to `recordedUntil`.
    public var levels: WaveformLevels
    /// How far the recording has come, for a recording that grows while it is
    /// shown. When set, the red clip is drawn from it and `recordedUntil` and
    /// `levels` above are not used. Nil, as in the design lab, draws those.
    public var progress: RecordingProgress?

    public init(
        origin: Double,
        recordedUntil: Double? = nil,
        levels: WaveformLevels = WaveformLevels(minimums: [], maximums: [])
    ) {
        self.origin = origin
        self.recordedUntil = recordedUntil
        self.levels = levels
    }

    public static func == (lhs: TrackRecording, rhs: TrackRecording) -> Bool {
        lhs.origin == rhs.origin && lhs.recordedUntil == rhs.recordedUntil && lhs.levels == rhs.levels
            && lhs.progress === rhs.progress
    }
}

/// How far a recording that is going right now has come. Whoever records
/// changes it, many times a second, and the red clip on the track
/// (`RecordingClip`) follows.
///
/// Only the red clip reads it. Do not read it in a view that holds the
/// timeline or a track's row: that view would then be worked out again on
/// every frame of a recording.
@MainActor
@Observable
public final class RecordingProgress {
    /// How far the recording has come, in song seconds. Nil during the
    /// run-up, when only the starting place is marked.
    public var recordedUntil: Double?
    /// The loudness of what has been recorded so far, spread from the
    /// recording's origin to `recordedUntil`.
    public var levels: WaveformLevels

    public init(
        recordedUntil: Double? = nil,
        levels: WaveformLevels = WaveformLevels(minimums: [], maximums: [])
    ) {
        self.recordedUntil = recordedUntil
        self.levels = levels
    }
}

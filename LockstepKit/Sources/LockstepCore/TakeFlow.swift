import Foundation

/// How far a take has come, from the press of Record until it is a clip.
public enum TakePhase: Sendable, Equatable {
    /// The song plays the run-up before the place Record was pressed at. The microphone is
    /// already open, so a line that starts a little early is not cut.
    case runningUp
    /// The song has reached the place Record was pressed at.
    case recording
    /// The take was stopped and is being turned into a clip. Nothing sounds any more.
    case finishing
}

/// The record origin: what Record remembers when it is pressed. A restart (Record pressed
/// again while the take is going) goes back to it, however often and whatever was selected
/// in between.
public struct RecordOrigin: Sendable, Equatable {
    /// The place recording starts, in song seconds: the beat nearest the playhead when
    /// Record was pressed (`RecordingPlacement.recordPlace`).
    public var seconds: Double
    /// The track that was selected when Record was pressed. The clip goes there.
    public var trackID: UUID
    /// Where every attempt starts: the start of the count-in before `seconds`, in song
    /// seconds (`CountIn.start`). Below zero when the click counts in before the song
    /// starts, and equal to `seconds` when the count-in is off.
    public var runUpStart: Double

    public init(seconds: Double, trackID: UUID, runUpStart: Double) {
        self.seconds = seconds
        self.trackID = trackID
        self.runUpStart = runUpStart
    }

    /// The phase an attempt begins in. With the count-in off there is nothing before
    /// the place, so the attempt is recording from its first moment.
    public var firstPhase: TakePhase {
        runUpStart < seconds ? .runningUp : .recording
    }
}

/// The steps a take goes through, and which of them Record, a restart (Record pressed
/// again while the take is going) and Stop may take at each moment. It only keeps count: the microphone and the song are the
/// app's business, which asks here first and then does what the answer allows.
///
///     var flow = TakeFlow()
///     flow.record(from: origin)        // running up, attempt 1
///     flow.started()                   // the microphone is open and the song plays
///     flow.reach(origin.seconds)       // recording
///     flow.restart()                   // origin: running up again, attempt 2
///     flow.restart()                   // nil: the restart before is still under way
///     flow.started()
///     flow.stop()                      // finishing
///     flow.end()                       // stopped
///
/// - A restart is allowed during the run-up and while recording, and at no other time.
/// - A restart asked for while the start or the restart before it is still under way is
///   ignored, so pressing the key twice by accident restarts once.
/// - The origin is set by Record and never changed by a restart.
public struct TakeFlow: Sendable, Equatable {
    /// How far the take has come, or nil when no take is going.
    public private(set) var phase: TakePhase?
    /// Where the take was started from and where it goes. Nil when no take is going.
    public private(set) var origin: RecordOrigin?
    /// Which attempt of the take this is: 1 after Record, one more after every restart.
    /// 0 when no take is going.
    public private(set) var attempt = 0
    /// True from Record or a restart until `started()`: the microphone and the song have
    /// been asked to start and have not answered yet.
    public private(set) var isStarting = false

    public init() {}

    /// True during the run-up and while recording: the microphone is open and the song plays.
    public var isGoing: Bool {
        phase == .runningUp || phase == .recording
    }

    /// Record was pressed while nothing was going: a take begins at `origin`.
    ///
    /// - Returns: false, with nothing changed, when a take is already going or being finished.
    @discardableResult
    public mutating func record(from origin: RecordOrigin) -> Bool {
        guard phase == nil else { return false }
        self.origin = origin
        phase = origin.firstPhase
        attempt = 1
        isStarting = true
        return true
    }

    /// The microphone is open and the song has been started, after Record or after a restart.
    public mutating func started() {
        isStarting = false
    }

    /// The song has come to `position`, in song seconds. The run-up is over when that is
    /// the place Record was pressed at.
    public mutating func reach(_ position: Double) {
        guard phase == .runningUp, let origin, position >= origin.seconds else { return }
        phase = .recording
    }

    /// Record was pressed while the take was going: the attempt is dropped and the next one begins at
    /// the same origin, with the same run-up.
    ///
    /// - Returns: the origin to start again from, or nil, with nothing changed, when
    ///   there is nothing to restart: no take is going, it is being finished, or the
    ///   start or restart before this one is still under way.
    public mutating func restart() -> RecordOrigin? {
        guard isGoing, !isStarting, let origin else { return nil }
        phase = origin.firstPhase
        attempt += 1
        isStarting = true
        return origin
    }

    /// The take was stopped and is being turned into a clip.
    ///
    /// - Returns: false, with nothing changed, when no take is going.
    @discardableResult
    public mutating func stop() -> Bool {
        guard isGoing else { return false }
        phase = .finishing
        return true
    }

    /// The take is a clip, or was thrown away, or never got going: nothing is going any more.
    public mutating func end() {
        self = TakeFlow()
    }
}

import Foundation

// Moving recordings back by the measured delay of the headphones and the microphone they were made with.
//
// A recording's place in the song is always `rawStart - delay` (`Recording.songTime`). So moving a recording
// back means giving it a delay, and nothing else: its file, its clips and every edit of them stay as they are,
// and playback, drawing and the timing features read the new place by themselves.
//
// There are three moments a recording gets its delay:
//
//     // 1. A new recording, when it becomes a clip:
//     let recording = captured.movedBack { settings.delay(for: $0) }
//
//     // 2. After a calibration, as one undo step:
//     store.edit("Apply Delay") { $0.applyDelay(0.0234, toRecordingsMadeWith: devices) }
//
//     // 3. When a project is opened:
//     project.applyStoredDelays { settings.delay(for: $0) }
//
// In 2 and 3 a take that was recorded slower (`Recording.recordedSpeed`) gets the delay times its speed: it
// was that much time late while it was recorded, and its place is counted in song time, which ran slower.
//
// In 2 and 3 only recordings whose delay is still 0 are touched. A recording that already has a delay was
// measured in an earlier session and keeps it: wireless headphones change their delay between sessions, so
// today's delay is not the one that recording was made with.

extension Recording {
    /// Whether a delay can still be given to this recording: it has none yet, and it says which devices it
    /// was made with.
    var waitsForDelay: Bool {
        delay == 0 && devicePair != nil
    }

    /// The recording as it goes into the project when it has just been made: moved back by the delay that is
    /// kept for its pair of devices.
    ///
    /// - Parameter storedDelay: the delay kept for a pair, in seconds, or nil when the pair has none in use
    ///   (`AppSettings.delay(for:)`). Then the recording gets delay 0, and so does a recording that does not
    ///   say which devices it was made with.
    public func movedBack(by storedDelay: (DevicePair) -> Double?) -> Recording {
        var moved = self
        // A take recorded slower counts in song time, where the delay is shorter by the take's speed.
        moved.delay = (devicePair.flatMap(storedDelay).flatMap(Recording.usableDelay) ?? 0) * (recordedSpeed ?? 1)
        return moved
    }

    /// A delay that can be taken off a recording, or nil for something that is not one: not a number, or not
    /// above zero.
    static func usableDelay(_ delay: Double) -> Double? {
        delay.isFinite && delay > 0 ? delay : nil
    }
}

extension Project {
    /// The recordings that `applyDelay(_:toRecordingsMadeWith:)` would move: made with this pair of devices,
    /// and without a delay so far. The app asks before it makes an undo step, so a calibration that moves
    /// nothing leaves no "Undo Apply Delay".
    ///
    /// A pair is told by the ids of its two devices (`DevicePair.key`), so a device that was renamed since
    /// the recording was made is still the same device.
    public func recordingsWaitingForDelay(madeWith devices: DevicePair) -> [UUID] {
        recordings.filter { $0.waitsForDelay && $0.devicePair?.key == devices.key }.map(\.id)
    }

    /// After a calibration: every recording made with this pair that has no delay yet gets this one, and so
    /// moves back by it. Recordings of another pair, recordings that already have a delay, and recordings
    /// that do not say which devices they were made with are left alone.
    ///
    /// - Parameter delay: in seconds. Something that is not a delay (zero, negative, not a number) changes nothing.
    /// - Returns: how many recordings were moved.
    @discardableResult
    public mutating func applyDelay(_ delay: Double, toRecordingsMadeWith devices: DevicePair) -> Int {
        applyStoredDelays { $0.key == devices.key ? delay : nil }
    }

    /// When a project is opened: every recording without a delay whose pair of devices has one now gets it.
    ///
    /// - Parameter storedDelay: the delay kept for a pair, in seconds, or nil when the pair has none in use
    ///   (`AppSettings.delay(for:)`).
    /// - Returns: how many recordings were moved.
    @discardableResult
    public mutating func applyStoredDelays(_ storedDelay: (DevicePair) -> Double?) -> Int {
        var moved = 0
        for index in recordings.indices where recordings[index].waitsForDelay {
            guard let devices = recordings[index].devicePair,
                let delay = storedDelay(devices).flatMap(Recording.usableDelay)
            else { continue }
            // A take recorded slower counts in song time, where the delay is shorter by the take's speed.
            recordings[index].delay = delay * (recordings[index].recordedSpeed ?? 1)
            moved += 1
        }
        return moved
    }
}

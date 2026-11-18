/// Max's Resolve timeline, and the arithmetic that turns a moment on Lockstep's
/// timeline into the frame and timecode where an exported clip starts. Lockstep's
/// 00:00 is the first frame of the Resolve timeline. Which moment of the song stands
/// there is the project's `SongPlace`.
///
/// Everything is counted in whole samples at 48 kHz and whole frames, never in
/// seconds, so the answer is exact at every supported frame rate.
public struct ResolveSettings: Codable, Sendable, Equatable {
    /// The timecode of the timeline's first frame. Resolve starts at 01:00:00:00.
    public var timelineStart: Timecode
    public var frameRate: ResolveFrameRate

    public static let defaultTimelineStart = Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0)
    public static let defaultFrameRate = ResolveFrameRate.fps25

    public init(
        timelineStart: Timecode = ResolveSettings.defaultTimelineStart,
        frameRate: ResolveFrameRate = ResolveSettings.defaultFrameRate
    ) {
        self.timelineStart = timelineStart
        self.frameRate = frameRate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = ResolveSettings()
        self.init(
            timelineStart: try container.decodeIfPresent(Timecode.self, forKey: .timelineStart) ?? fresh.timelineStart,
            frameRate: try container.decodeIfPresent(ResolveFrameRate.self, forKey: .frameRate) ?? fresh.frameRate
        )
    }

    public var samplesPerFrame: Int { frameRate.samplesPerFrame }

    /// The frame, counted from the timeline start, in which a sample of the timeline falls: a sample counted
    /// from Lockstep's 00:00, which is the first frame of the Resolve timeline (`SongPlace.timelineSample`).
    /// An exported clip whose first sound is that sample starts on this frame.
    public func startFrame(forTimelineSample sample: Int) -> Int {
        Self.floorDivide(sample, by: samplesPerFrame)
    }

    /// The silence an exported clip begins with: from the start of its frame
    /// up to its first sound. Always less than one frame.
    public func paddingSamples(forTimelineSample sample: Int) -> Int {
        sample - startFrame(forTimelineSample: sample) * samplesPerFrame
    }

    /// The timecode Resolve shows for a frame counted from the timeline start.
    public func timecode(frame: Int) -> Timecode {
        timelineStart.adding(frames: frame, at: frameRate)
    }

    /// Division that rounds down also below zero, where Swift's rounds towards zero.
    /// A clip that lies before the timeline's 00:00 must still land in the frame that holds it.
    private static func floorDivide(_ value: Int, by divisor: Int) -> Int {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }
}

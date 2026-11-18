// What the Send to DaVinci panel does to a project's Resolve timeline: its three fields are a timecode, a frame
// rate and a second timecode. The first two are the project's Resolve values. The third, where the song starts,
// is the project's `SongPlace` written as a timecode: the same thing the song's edge and the song itself say
// when they are dragged on the timeline. Each function gives the value after one field was changed, or nil when
// what was typed cannot be used. Nothing is saved here: the app makes the answer an edit that Undo takes back.

extension ResolveSettings {
    /// The settings with another timeline start, typed as "HH:MM:SS:FF". The song keeps its distance from the
    /// start of the timeline, so the timecode it starts at moves along. Nil when the text is no timecode at
    /// this frame rate.
    public func withTimelineStart(typed text: String) -> ResolveSettings? {
        guard let start = Timecode.parse(text, frameRate: frameRate) else { return nil }
        var changed = self
        changed.timelineStart = start
        return changed
    }

    /// How many frames a timecode lies after another, read the short way round the day: more than half a day
    /// later counts as earlier.
    static func offset(from start: Int, to song: Int, at rate: ResolveFrameRate) -> Int {
        let day = 24 * 60 * 60 * rate.timecodeFramesPerSecond
        let offset = song - start
        if offset > day / 2 { return offset - day }
        if offset < -day / 2 { return offset + day }
        return offset
    }

    /// The settings with another frame rate. The timeline start stays as it is written, because it is what
    /// Max reads in Resolve: only frames that do not exist at the new rate (frame 40 at 25 frames per second)
    /// become 00. The song's place is kept in samples, so it does not change with the frame rate.
    public func withFrameRate(_ rate: ResolveFrameRate) -> ResolveSettings {
        guard rate != frameRate else { return self }
        let start = Timecode.parse(timelineStart.text, fittedTo: rate) ?? timelineStart
        return ResolveSettings(timelineStart: start, frameRate: rate)
    }
}

extension Project {
    /// Where on the Resolve timeline the song's own first sample lies, as the timecode Resolve shows for its
    /// frame. The same as the timeline start while that sample stands at 00:00, and before it once the
    /// beginning is cut away and what is left was moved to 00:00.
    public var resolveSongStart: Timecode {
        resolve.timecode(frame: resolve.startFrame(forTimelineSample: songPlace.timelineSample(forSong: 0)))
    }

    /// The song's place with its own first sample at another timecode, typed as "HH:MM:SS:FF". Nil when the
    /// text is no timecode at the project's frame rate.
    ///
    /// The timecode may lie before the start of the timeline: that much of the song's beginning is then cut
    /// away, and what is left starts at 00:00, as when the edge is dragged and the song moved. A timeline that
    /// starts at 00:00:00:00 has no earlier timecode to write, so a timecode more than half a day after the
    /// timeline start is read as that much before it (23:59:48:00 is 12 seconds before 00:00:00:00).
    public func songPlace(withSongStartTyped text: String) -> SongPlace? {
        let rate = resolve.frameRate
        guard let start = Timecode.parse(text, frameRate: rate) else { return nil }
        let frames = ResolveSettings.offset(
            from: resolve.timelineStart.frameCount(at: rate),
            to: start.frameCount(at: rate),
            at: rate
        )
        return songPlace.startingOnTimeline(at: frames * resolve.samplesPerFrame, ofLength: songLengthSamples)
    }
}

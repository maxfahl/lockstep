import Foundation

/// How a project was shown when it was last left: the zoom and the place in the
/// timeline, how far the track rows were scrolled down, how tall they were, where the
/// playhead stood, what was selected and the loop's in and out. Opening the project again brings it back.
///
/// It is not part of the project. It is kept in `view.json` beside `project.json`,
/// written by itself and never an undo step, and nothing changes the project when it is
/// written. A project from before has no `view.json` and opens as a new one does.
///
///     let kept = package.readView()          // nil for a project without one
///     try package.write(ProjectView(...))
public struct ProjectView: Codable, Sendable, Equatable {
    /// The zoom, in points per second of song. Zero means "fit the whole song to the width".
    public var pointsPerSecond: Double
    /// The song second at the left edge of the timeline's rows.
    public var scrollOffsetSeconds: Double
    /// How far the track rows were scrolled down, in points. Zero with the first track at the top.
    public var rowsScrollPoints: Double
    /// The height of the track rows, in points.
    public var trackHeight: Double
    /// Where the playhead stood, in song seconds.
    public var playheadSeconds: Double
    /// The track recordings went to, or nil for the first one.
    public var selectedTrackID: UUID?
    /// The selected clips, in the order of their ids, so the same selection always gives
    /// the same text.
    public var selectedClipIDs: [UUID]
    /// The loop's in and out (`LoopInOut`), in song seconds, or nil for an end that is not
    /// set. They stay until Option+X, so they are kept across a restart like the rest of
    /// the view. A view from before has neither.
    public var loopInSeconds: Double?
    public var loopOutSeconds: Double?

    public init(
        pointsPerSecond: Double = 0,
        scrollOffsetSeconds: Double = 0,
        rowsScrollPoints: Double = 0,
        trackHeight: Double,
        playheadSeconds: Double = 0,
        selectedTrackID: UUID? = nil,
        selectedClipIDs: [UUID] = [],
        loopInOut: LoopInOut? = nil
    ) {
        self.pointsPerSecond = pointsPerSecond
        self.scrollOffsetSeconds = scrollOffsetSeconds
        self.rowsScrollPoints = rowsScrollPoints
        self.trackHeight = trackHeight
        self.playheadSeconds = playheadSeconds
        self.selectedTrackID = selectedTrackID
        self.selectedClipIDs = selectedClipIDs.sorted { $0.uuidString < $1.uuidString }
        self.loopInSeconds = loopInOut?.inTime
        self.loopOutSeconds = loopInOut?.outTime
    }

    /// The loop's in and out as they were kept, or nil when neither was set.
    public var loopInOut: LoopInOut? {
        guard loopInSeconds != nil || loopOutSeconds != nil else { return nil }
        return LoopInOut(inTime: loopInSeconds, outTime: loopOutSeconds)
    }
}

extension ProjectPackage {
    /// Where the view of the project is kept: `view.json`, beside `project.json`.
    public var viewFile: URL { url.appendingPathComponent("view.json") }
    /// Where `view.json` is written before it takes the place of the old one.
    var temporaryViewFile: URL { url.appendingPathComponent("view.json.tmp") }

    /// The view the project was last left with, or nil when there is none: a project from
    /// before, or a file that cannot be read. Either way the project opens as it does
    /// without one, so nothing here is ever an error.
    public func readView() -> ProjectView? {
        guard let data = try? Data(contentsOf: viewFile) else { return nil }
        return try? JSONDecoder().decode(ProjectView.self, from: data)
    }

    /// Writes the view as readable text, in place of the one that was there. Like
    /// `project.json` it is written beside and then moved into place, so a crash halfway
    /// leaves the old one whole.
    public func write(_ view: ProjectView) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(view)
        try data.write(to: temporaryViewFile)
        guard rename(temporaryViewFile.path, viewFile.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: viewFile.path,
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)),
            ])
        }
    }
}

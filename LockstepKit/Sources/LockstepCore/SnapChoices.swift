import Foundation

// What snapping catches on, chosen piece by piece, and the beat grid as one of the choices.
//
// Snapping is still one switch (`editing.snapping`). When it is on, `SnapChoices` says what a dragged clip
// catches on: the grid, the edges of other clips, the playhead, and the place the clip was recorded. Each is
// on or off by itself, and the grid has a unit. Max asked for this on 13 November 2026, "ungefär hur det
// funkar i Illustrator".
//
// The grid works differently from the other three:
//
// - A clip that is moved goes in steps of the unit and keeps its distance to the grid, because a clip starts
//   where its recording was cut and not where its first syllable sounds (`SnapGrid.steppedStart`).
// - The other three still catch within the snap distance, and win over a grid step, so a clip can always go
//   back to exactly its recorded place. They are `SnapSource`s, as before.
// - An edge that is trimmed catches on the grid's lines within the snap distance, like on any other point
//   (`GridLineSource`).
//
//     // When a clip is grabbed.
//     let choices = settings.snapChoices
//     let grid = choices.grid ? SnapGrid(grid: project.grid, unit: choices.gridUnit) : SnapGrid()
//     let engine = SnapEngine(sources: choices.sources(forMoving: clip, in: project, playheadAt: playhead), moving: moving)
//     // At every movement. `start` is where the clip would start without snapping.
//     if let hit = engine.snap(start: start, end: end, tolerance: tolerance) {
//         start += hit.delta
//     } else if let stepped = grid.steppedStart(start, grabbedStart: startAtGrab) {
//         start = stepped
//     }

/// How far apart the lines of the snapping grid are.
public enum SnapGridUnit: String, CaseIterable, Sendable {
    /// Sixteenths: four to a beat.
    case subBeats
    /// The beats and the middle between two beats.
    case halfBeats
    case beats
    /// The first beat of every bar.
    case bars

    /// The name in the menus.
    public var title: String {
        switch self {
        case .subBeats: "Sub-beats"
        case .halfBeats: "Half Beats"
        case .beats: "Beats"
        case .bars: "Bars"
        }
    }

    /// How many equal parts a beat is cut into for this unit, the same count the playhead steps by
    /// (`PlayheadStep`): sub-beats are sixteenths. Nil for bars, which are not parts of a beat.
    public var perBeat: Int? {
        switch self {
        case .subBeats: PlayheadStep.subBeat.perBeat
        case .halfBeats: PlayheadStep.halfBeat.perBeat
        case .beats: PlayheadStep.beat.perBeat
        case .bars: nil
        }
    }
}

extension SnapGridUnit: SettingValue {}

/// What a dragged clip catches on while snapping is on. Everything starts switched on, with beats as the
/// grid's unit.
public struct SnapChoices: Sendable, Equatable {
    /// The beat grid, in steps of `gridUnit`.
    public var grid: Bool
    /// The start and the end of every other clip.
    public var clipEdges: Bool
    public var playhead: Bool
    /// The place the dragged clip was recorded.
    public var recordedPlace: Bool
    public var gridUnit: SnapGridUnit

    public init(
        grid: Bool = true,
        clipEdges: Bool = true,
        playhead: Bool = true,
        recordedPlace: Bool = true,
        gridUnit: SnapGridUnit = .beats
    ) {
        self.grid = grid
        self.clipEdges = clipEdges
        self.playhead = playhead
        self.recordedPlace = recordedPlace
        self.gridUnit = gridUnit
    }

    /// The points a clip that is moved catches on, of the kinds that are switched on. The grid is not among
    /// them: a moved clip goes in steps of it (`SnapGrid.steppedStart`).
    ///
    /// - Parameters:
    ///   - clip: the clip that is grabbed. Its recorded place is one of the points.
    ///   - playheadAt: where the playhead is, in song seconds.
    public func sources(forMoving clip: Clip, in project: Project, playheadAt: Double) -> [any SnapSource] {
        var sources = sharedSources(in: project, playheadAt: playheadAt)
        if recordedPlace, let recorded = RecordedPositionSource(clip: clip, in: project) {
            sources.append(recorded)
        }
        return sources
    }

    /// The points an edge that is trimmed catches on, of the kinds that are switched on: other clips' edges,
    /// the playhead, and the lines of the grid. A trim does not move the clip, so its recorded place is not
    /// one of them.
    ///
    /// - Parameter grid: the lines of the grid in the chosen unit. They are left out when the grid is
    ///   switched off, whatever is handed in.
    public func sources(forTrimmingIn project: Project, playheadAt: Double, grid: SnapGrid) -> [any SnapSource] {
        var sources = sharedSources(in: project, playheadAt: playheadAt)
        if self.grid, !grid.lines.isEmpty {
            sources.append(GridLineSource(grid: grid))
        }
        return sources
    }

    private func sharedSources(in project: Project, playheadAt: Double) -> [any SnapSource] {
        var sources: [any SnapSource] = []
        if clipEdges {
            sources.append(ClipEdgeSource(project: project))
        }
        if playhead {
            sources.append(PlayheadSource(time: playheadAt))
        }
        return sources
    }
}

extension SnapKind {
    /// A line of the beat grid. It loses every tie: a clip edge or the playhead at the same place is the
    /// point that is named.
    public static let gridLine = SnapKind(name: "gridLine", rank: 300)
}

/// The lines of the snapping grid of a song, in one unit: every place a step can land on.
///
/// The lines follow the song's tempo, because they are made from its beats: where the beats are further
/// apart, so are the lines. Where the song has no beats (before the first beat, after the last, and in a gap
/// that was left empty) there are no lines.
public struct SnapGrid: Sendable, Equatable {
    /// Song seconds, ascending.
    public let lines: [Double]

    /// A grid with these lines. No lines is a grid that does nothing.
    public init(lines: [Double] = []) {
        self.lines = lines.sorted()
    }

    /// The grid of a song's beats in a unit. A song whose beats are not found has no lines.
    public init(grid: Grid?, unit: SnapGridUnit) {
        guard let grid, let first = grid.beats.first?.time, let last = grid.beats.last?.time, first <= last else {
            lines = []
            return
        }
        if let perBeat = unit.perBeat {
            lines = grid.subBeats(perBeat: perBeat, in: first...last)
        } else {
            lines = grid.beats.filter { grid.isBarStart($0.number) }.map(\.time)
        }
    }

    /// The line nearest a moment in the song, or nil when the grid has no lines. Of two lines equally near
    /// it is the earlier one.
    public func nearestLine(to seconds: Double) -> Double? {
        guard !lines.isEmpty, seconds.isFinite else { return nil }
        // The first line that is not before the moment, found by halving.
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle] < seconds {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low == 0 { return lines[0] }
        if low == lines.count { return lines[lines.count - 1] }
        return lines[low] - seconds < seconds - lines[low - 1] ? lines[low] : lines[low - 1]
    }

    /// The lines inside a stretch of the song.
    public func lines(in range: ClosedRange<Double>) -> [Double] {
        lines.filter { range.contains($0) }
    }

    /// Where a moved clip starts when it goes in steps of this grid.
    ///
    /// At the grab, the line nearest the clip's start and the distance between them are taken. While it is
    /// dragged, the clip starts that same distance from the line nearest to where the pointer has brought
    /// that place. So a clip that started 30 ms after a beat always starts 30 ms after a beat, and one that
    /// was on a line stays on lines.
    ///
    /// - Parameters:
    ///   - freeStart: where the clip would start without snapping, in song seconds.
    ///   - grabbedStart: where the clip started when it was grabbed.
    /// - Returns: the start on the step, or nil when the grid does nothing here: it has no lines, or the
    ///   pointer has brought the clip before the first line or past the last one, where the song has no
    ///   beats to step by. The clip then moves freely.
    public func steppedStart(_ freeStart: Double, grabbedStart: Double) -> Double? {
        guard let first = lines.first, let last = lines.last, let anchor = nearestLine(to: grabbedStart)
        else { return nil }
        let distance = grabbedStart - anchor
        let place = freeStart - distance
        guard place >= first, place <= last, let line = nearestLine(to: place) else { return nil }
        return line + distance
    }
}

/// The lines of the grid as snap points, for an edge that is trimmed.
public struct GridLineSource: SnapSource {
    public var grid: SnapGrid

    public init(grid: SnapGrid) {
        self.grid = grid
    }

    public func points(in range: ClosedRange<Double>, excluding moving: Set<Clip.ID>) -> [SnapPoint] {
        grid.lines(in: range).map { SnapPoint(time: $0, kind: .gridLine) }
    }
}

// MARK: Kept in the settings

extension SettingKey where Value == Bool {
    /// The four kinds of snap points, each switched by itself in the menu beside the snapping button and in
    /// Edit > Snap To. They only matter while `snapping` is on.
    public static var snapToGrid: SettingKey {
        SettingKey("editing.snapToGrid", pane: .general, default: true)
    }

    public static var snapToClipEdges: SettingKey {
        SettingKey("editing.snapToClipEdges", pane: .general, default: true)
    }

    public static var snapToPlayhead: SettingKey {
        SettingKey("editing.snapToPlayhead", pane: .general, default: true)
    }

    public static var snapToRecordedPlace: SettingKey {
        SettingKey("editing.snapToRecordedPlace", pane: .general, default: true)
    }
}

extension SettingKey where Value == SnapGridUnit {
    /// The unit of the snapping grid.
    public static var snapGridUnit: SettingKey {
        SettingKey("editing.snapGridUnit", pane: .general, default: .beats, choices: SnapGridUnit.allCases)
    }
}

extension AppSettings {
    /// What snapping catches on, read from and written to its five settings. Like `snapping` they are
    /// switched in the main window, so they are not in `AppSettings.keys` and Restore Defaults in the
    /// settings window leaves them alone.
    public var snapChoices: SnapChoices {
        get {
            SnapChoices(
                grid: self[.snapToGrid],
                clipEdges: self[.snapToClipEdges],
                playhead: self[.snapToPlayhead],
                recordedPlace: self[.snapToRecordedPlace],
                gridUnit: self[.snapGridUnit]
            )
        }
        set {
            self[.snapToGrid] = newValue.grid
            self[.snapToClipEdges] = newValue.clipEdges
            self[.snapToPlayhead] = newValue.playhead
            self[.snapToRecordedPlace] = newValue.recordedPlace
            self[.snapGridUnit] = newValue.gridUnit
        }
    }
}

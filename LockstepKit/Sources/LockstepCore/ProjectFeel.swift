import Foundation

// Which grid a clip's timing is measured against: sixteenths or triplets.
//
// Only the clip says it (`Clip.feel`): 16ths, Triplets, or Auto, which is the grid that the clip's own
// syllables fit (`Feel.detect`). The song had a choice of its own until phase 27, and a clip could follow it.
// Max took that away on 13 November 2026: "Ta bort song och det globala valet. Allt görs per klipp."
//
//     let grid = project.grid(for: clip, markers: markersByRecording)   // .sixteenths or .triplets
//     MarkerDistance.nearestSubBeat(to: time, grid: beats, perBeat: grid.perBeat)
//
// Whoever asks often keeps a `FeelMemory`, which gives the same answer and listens to a clip's syllables only
// when they, or the beats, have changed.

extension Project {
    /// The grid that is chosen for a clip without listening to it: 16ths or Triplets. Nil when the clip is
    /// on Auto, so its syllables decide.
    public func chosenGrid(for clip: Clip) -> SubBeatGrid? {
        switch clip.feel {
        case .sixteenths: .sixteenths
        case .triplets: .triplets
        case .auto: nil
        }
    }

    /// When the syllables of a clip sound, in song seconds, without the ones Max has excluded from timing
    /// fixes. This is what the Auto feel listens to.
    public func feelMarkerTimes(of clip: Clip, markers: [UUID: [SyllableMarker]]) -> [Double] {
        self.markers(in: clip, allMarkers: markers).filter { !$0.isExcluded }.map(\.songTime)
    }

    /// The grid a clip's timing is measured against: the one it has chosen, and on Auto the grid its
    /// syllables fit. On Auto a clip stays on sixteenths while the song's beats or the clip's syllables are
    /// not known.
    ///
    /// - Parameter markers: the markers of every recording, by recording id.
    public func grid(for clip: Clip, markers: [UUID: [SyllableMarker]]) -> SubBeatGrid {
        if let chosen = chosenGrid(for: clip) { return chosen }
        guard let grid else { return .sixteenths }
        return Feel.detect(markerTimes: feelMarkerTimes(of: clip, markers: markers), grid: grid)
    }

    /// Gives the clips with these ids a feel: 16ths, Triplets or Auto.
    ///
    /// The takes that wait behind a chosen clip get the same feel, so stepping to another take of the line
    /// does not quietly change the grid it is measured against.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func setClips(_ ids: Set<UUID>, feel: ClipFeel) -> Bool {
        let all = Set(ids.flatMap { takes(of: $0).map(\.id) }).union(ids)
        var changed = false
        for track in tracks.indices {
            for clip in tracks[track].clips.indices
            where all.contains(tracks[track].clips[clip].id) && tracks[track].clips[clip].feel != feel {
                tracks[track].clips[clip].feel = feel
                changed = true
            }
        }
        return changed
    }
}

/// The grids the Auto feel has found, kept per clip, so a clip is listened to again only when its syllables
/// or the song's beats have changed. It is kept in memory only, never in the project.
///
///     var feels = FeelMemory()
///     feels.grid(for: clip, in: project, markers: markersByRecording)   // the same as project.grid(for:markers:)
public struct FeelMemory: Sendable {
    /// What a clip was last heard as, and what that was found from.
    private struct Found: Sendable {
        var times: [Double]
        var beats: [Beat]
        var grid: SubBeatGrid
    }

    private var found: [UUID: Found] = [:]

    public init() {}

    /// How many times a clip has been listened to. A test reads it to see that nothing is worked out twice.
    public private(set) var detections = 0

    /// The grid a clip's timing is measured against, exactly as `Project.grid(for:markers:)` gives it.
    public mutating func grid(for clip: Clip, in project: Project, markers: [UUID: [SyllableMarker]]) -> SubBeatGrid {
        if let chosen = project.chosenGrid(for: clip) { return chosen }
        guard let grid = project.grid else { return .sixteenths }
        let times = project.feelMarkerTimes(of: clip, markers: markers)
        if let kept = found[clip.id], kept.times == times, kept.beats == grid.beats {
            return kept.grid
        }
        let detected = Feel.detect(markerTimes: times, grid: grid)
        detections += 1
        found[clip.id] = Found(times: times, beats: grid.beats, grid: detected)
        return detected
    }

    /// Whether no clip is remembered: no clip on Auto was asked about. There is then nothing to forget.
    public var isEmpty: Bool { found.isEmpty }

    /// Forgets the clips a project no longer has.
    public mutating func forget(allBut ids: Set<UUID>) {
        guard found.keys.contains(where: { !ids.contains($0) }) else { return }
        found = found.filter { ids.contains($0.key) }
    }
}

import Accelerate
import Foundation
import LockstepCore
import LockstepUI

/// The tracks of a project as the timeline draws them: every track with its clips, each clip
/// at its place in the song with the waveform of the part of its recording it plays.
///
///     var shown = ShownClips()
///     content.timeline.trackRows = shown.rows(
///         of: ProjectLookup(project), waveforms: waveforms, selectedTrack: trackID, selectedClips: clipIDs
///     )
///
/// Keep one of these for as long as a project is open. It remembers the waveform of every
/// piece it has shown, so a clip that did not change is handed over with the very same
/// numbers as last time. The timeline then sees at a glance that the clip is the same and
/// does not draw it again.
///
/// It also remembers the row of every track with what the row was made from, and hands the very same
/// row over again while that is the same: the track with its clips, whether it is the selected track,
/// which of its clips are selected, and the tightened sounds its clips are drawn from. So an edit makes
/// again only the rows of the tracks it changed, and whoever compares the rows (the model before it writes
/// them to the window, and the timeline before it works a row out) sees at a glance that the others are
/// the same. Everything is made again when the recordings change, or when a sound or a waveform arrives.
///
/// Takes: of several takes of one line only the active one is shown, and its box says which
/// take it is and how many there are ("3/5" in the clip's bar). A clip without other takes
/// says 1 of 1, which the bar shows as no count at all. The takes that wait are in the project
/// and are not drawn.
///
/// Volume: every box says how loud its clip is really played (`ClipBox.appliedGainDB`), which
/// is how tall its waveform is drawn. That is the clip's volume after the safe limit
/// (`Clip.appliedGain`), and it needs the peaks of the recordings:
///
///     shown.rows(of: project, waveforms: waveforms, selectedTrack: trackID, selectedClips: clipIDs,
///                peaks: recordingPeaks.lookup(in: sounds))
///
/// Cuts: a clip can start and end on any sample of its recording, and after a split its pieces do. Handed the
/// recordings' sound (`sounds`), every piece is drawn from exactly the samples it plays, so the waveform on each
/// side of a cut stays where it was, to the point, however far the timeline is zoomed in. A clip joined from
/// several pieces has one segment for each, and the window leaves the gaps between them empty.
///
/// Correction: a piece that is heard tightened is drawn from its tightened sound (`tightened`), so its
/// lines stand in the waveform where they are heard. A line that slid out of its clip makes that sound
/// longer than the piece, and the piece is drawn that much longer, so the clip's box starts where the clip
/// is heard to start. While the tightened sound is not made yet, nothing is handed in for the piece and it
/// is drawn as recorded.
struct ShownClips {
    /// A piece of a recording that a clip plays, with the volume the piece has of its own.
    private struct Piece: Hashable {
        var recordingID: UUID
        var inSample: Int
        var outSample: Int
        var gainDb: Double
        /// The id of the tightened sound the piece is drawn from, or nil when it is drawn as recorded. A
        /// tightened sound that is made again has a new id, and the piece is then measured again.
        var tightenedID: UUID?
    }

    /// The waveforms of the pieces in the rows made last.
    private var levels: [Piece: WaveformLevels] = [:]

    /// What every row depends on besides its own track. When it changes, every row is made again.
    private struct Ground: Equatable {
        /// Where a clip lies comes from its recordings.
        var recordings: [Recording]
        /// How many sounds and waveforms are loaded: a piece is drawn from them, and they arrive one by one.
        var sounds: Int
        var waveforms: Int
        var showsWords: Bool
        var drawsTightened: Bool
    }

    /// The row of one track as it was made, and what it was made from.
    private struct KeptRow {
        var track: Track
        var isSelected: Bool
        /// The id of the tightened sound each segment of each shown clip with a timing fix was drawn from,
        /// in the order of the clips and their segments.
        var heard: [UUID?]
        /// The voices that stood in for the track's recordings, by recording id: the safe limit of each box
        /// was asked about them.
        var voices: [UUID: UUID]
        var row: TrackRow
        /// The pieces the row shows, for tidying `levels`.
        var pieces: [Piece]
    }

    private var ground: Ground?
    private var kept: [UUID: KeptRow] = [:]
    /// The clips that were drawn as selected in the rows made last.
    private var selectedLast: Set<UUID> = []

    /// How many rows have been made, not counting the ones handed over as they were. For whoever wants to
    /// see that an edit made only the rows it changed.
    private(set) var rowsMade = 0

    /// - Parameters:
    ///   - lookup: the project, as a lookup table.
    ///   - waveforms: the waveform of each recording, by recording id. A clip whose
    ///     recording has none is shown without a waveform.
    ///   - selectedTrack: the track recordings go to. Its header is marked.
    ///   - selectedClips: the clips that are drawn as selected.
    ///   - peaks: the highest sample of a stretch of a recording, for the safe limit on each
    ///     clip's volume. Left out, a clip is drawn as loud as was asked for, also when the
    ///     limit holds it back.
    ///   - voices: which voice stands in for which recording on which track. The safe limit of a clip is
    ///     asked about the sound it is read from on its track, as the player asks it. `peaks` must know the
    ///     voices' samples by their ids. The waveform is the recording's whatever voice is heard.
    ///   - sounds: the sound of each recording, by recording id. With it a piece is drawn from
    ///     exactly the samples it plays. A piece whose recording is not in it is drawn from
    ///     `waveforms`, where a cut can sit up to 5 ms beside the drawn sound.
    ///   - showsWords: puts every clip's words in the help tag of its bar (`ClipBox.helpText`).
    ///   - tightenedID: the id `tightened` gives for a segment, without the sound: a quicker way to see
    ///     whether a row's tightened sounds are the ones it was drawn from. Left out, `tightened` is asked.
    ///   - tightened: the tightened sound a segment of a clip is heard with right now, for the clip's id
    ///     and the segment's place in the clip: its samples, the id the sound has, and how many of the
    ///     samples lie before the segment's first one (`lead`) and after its last (`tail`). Without
    ///     those there are exactly as many as the segment plays. Nil for a segment that is heard as
    ///     recorded. Left out, every clip is drawn as recorded.
    mutating func rows(
        of lookup: ProjectLookup,
        waveforms: [UUID: WaveformPyramid],
        selectedTrack: UUID?,
        selectedClips: Set<UUID>,
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices,
        sounds: [UUID: [Float]] = [:],
        showsWords: Bool = false,
        tightened: ((_ clipID: UUID, _ segment: Int) -> (id: UUID, samples: [Float], lead: Int, tail: Int)?)? = nil,
        tightenedID: ((_ clipID: UUID, _ segment: Int) -> UUID?)? = nil
    ) -> [TrackRow] {
        let project = lookup.project
        let now = Ground(
            recordings: project.recordings,
            sounds: sounds.count,
            waveforms: waveforms.count,
            showsWords: showsWords,
            drawsTightened: tightened != nil
        )
        if ground != now {
            ground = now
            kept = [:]
        }
        // The tracks with a clip that was selected or unselected since the last time. A clip that is gone
        // is on none, and the track it was on has other clips than before.
        var reselected: Set<UUID> = []
        if selectedClips != selectedLast {
            for id in selectedClips.symmetricDifference(selectedLast) {
                if let trackID = lookup.trackID(ofClip: id) { reselected.insert(trackID) }
            }
            selectedLast = selectedClips
        }
        var rows: [TrackRow] = []
        var keptNow: [UUID: KeptRow] = [:]
        for track in project.tracks {
            let isSelected = track.id == selectedTrack
            let heard = Self.heardIDs(of: track, tightened: tightened, tightenedID: tightenedID)
            let standIns = voices.isHeard(on: track) ? Self.standIns(on: track, voices) : [:]
            if let last = kept[track.id], last.isSelected == isSelected, !reselected.contains(track.id),
               last.heard == heard, last.track == track, last.voices == standIns
            {
                rows.append(last.row)
                keptNow[track.id] = last
                continue
            }
            var pieces: [Piece] = []
            var boxes: [ClipBox] = []
            // Which take of how many each clip is. A clip that is in no group has no other takes.
            var takePlaces: [UUID: (number: Int, count: Int)] = [:]
            for group in lookup.takeGroups(on: track.id) {
                for (index, take) in group.enumerated() {
                    takePlaces[take.id] = (index + 1, group.count)
                }
            }
            for clip in track.clips where clip.isActiveTake {
                var segments: [ClipSegment] = []
                for (index, segment) in clip.segments.enumerated() {
                    guard let start = lookup.start(of: segment), let end = lookup.end(of: segment), end > start
                    else { continue }
                    // Only for a clip with a timing fix (Lines or All) is there a tightened sound to ask
                    // for. A clip that is Off may still have one kept for it, and is drawn as recorded.
                    var heard = clip.hasTimingFix ? tightened?(clip.id, index) : nil
                    // A tightened sound is as long as its segment and what it says it has before and after
                    // it. One that is not belongs to a segment that has been cut since, and the piece is
                    // drawn as recorded.
                    if let sound = heard,
                       sound.samples.count != segment.outSample - segment.inSample + sound.lead + sound.tail {
                        heard = nil
                    }
                    let piece = Piece(
                        recordingID: segment.recordingID,
                        inSample: segment.inSample,
                        outSample: segment.outSample,
                        gainDb: segment.gainDb,
                        tightenedID: heard?.id
                    )
                    // A part that carries a volume of its own, as joined parts can, is drawn that much
                    // taller or shorter than the rest of its clip.
                    let shown = levels[piece] ?? Self.scaled(
                        heard.flatMap { Self.exactLevels(ofSamples: 0..<$0.samples.count, in: $0.samples) }
                            ?? Self.exactLevels(of: segment, in: sounds[segment.recordingID])
                            ?? Self.levels(of: segment, in: waveforms[segment.recordingID]),
                        byDb: segment.gainDb
                    )
                    levels[piece] = shown
                    pieces.append(piece)
                    // Where a line slid out of the segment, the sound is heard from that much earlier or
                    // until that much later, and the waveform is of all of it.
                    let before = Double(heard?.lead ?? 0) / Lockstep.sampleRate
                    let after = Double(heard?.tail ?? 0) / Lockstep.sampleRate
                    segments.append(ClipSegment(range: (start - before)...(end + after), levels: shown))
                }
                // A clip whose recording is not in the project has no place in the song.
                guard !segments.isEmpty else { continue }
                var box = ClipBox(
                    id: clip.id,
                    displayName: clip.displayName,
                    segments: segments,
                    muted: clip.muted,
                    isSelected: selectedClips.contains(clip.id),
                    takeCount: takePlaces[clip.id]?.count ?? 1,
                    activeTakeNumber: takePlaces[clip.id]?.number ?? 1
                )
                // What the controls under "Correction" in the panel on the right show for the clip.
                box.correction = ClipCorrection(clip.tighten)
                box.strength = clip.strength
                box.stretches = clip.stretch
                box.volumeDB = clip.gainDb
                box.appliedGainDB = clip.appliedGain(peaks: peaks, voices: voices, on: track).db
                // The feel the clip has chosen, which its right-click menu ticks and the panel shows.
                box.menuFeel = ClipMenu.Feel(clip.feel)
                // The help tag of the bar holds all of the clip's words.
                if showsWords, let text = clip.text, !text.isEmpty {
                    box.helpText = text
                }
                boxes.append(box)
            }
            var row = TrackRow(
                id: track.id,
                name: track.name,
                muted: track.muted,
                isSelected: isSelected,
                clips: boxes
            )
            // What the volume slider in the panel on the right shows for the track.
            row.volumeDB = track.gainDb
            rows.append(row)
            rowsMade += 1
            keptNow[track.id] = KeptRow(
                track: track, isSelected: isSelected, heard: heard, voices: standIns, row: row, pieces: pieces
            )
        }
        kept = keptNow
        // Pieces that are no longer shown are forgotten, once they are as many as the ones that are.
        let shownCount = kept.values.reduce(0) { $0 + $1.pieces.count }
        if levels.count > 2 * shownCount + 64 {
            let shown = Set(kept.values.flatMap(\.pieces))
            levels = levels.filter { shown.contains($0.key) }
        }
        return rows
    }

    /// The id of the tightened sound each segment of each shown clip with a timing fix on a track is drawn
    /// from right now, in the order of the clips and their segments. Nil for a segment drawn as recorded.
    /// What stands in for each recording of a track's clips, by recording id. Asked only for a track whose
    /// Voice is heard.
    private static func standIns(on track: Track, _ voices: TrackVoices) -> [UUID: UUID] {
        var standIns: [UUID: UUID] = [:]
        for clip in track.clips {
            standIns.merge(voices.standIns(for: clip, on: track)) { first, _ in first }
        }
        return standIns
    }

    private static func heardIDs(
        of track: Track,
        tightened: ((_ clipID: UUID, _ segment: Int) -> (id: UUID, samples: [Float], lead: Int, tail: Int)?)?,
        tightenedID: ((_ clipID: UUID, _ segment: Int) -> UUID?)?
    ) -> [UUID?] {
        guard tightened != nil else { return [] }
        var ids: [UUID?] = []
        for clip in track.clips where clip.isActiveTake && clip.hasTimingFix {
            for index in clip.segments.indices {
                ids.append(tightenedID.map { $0(clip.id, index) } ?? tightened?(clip.id, index)?.id)
            }
        }
        return ids
    }

    /// The takes of the line a clip belongs to, one row each in the order they were recorded,
    /// for the list of takes in the panel on the right. Each take lies at its own place in the
    /// song, with the waveform of what it plays. Empty for a clip that has no other takes.
    ///
    /// - Parameter playing: the take that its Play button is playing right now, if any. Its
    ///   row shows the button as Stop.
    static func takeRows(
        ofLineWith clipID: UUID,
        in project: Project,
        waveforms: [UUID: WaveformPyramid],
        playing: UUID? = nil
    ) -> [TakeRow] {
        let takes = project.takes(of: clipID)
        guard takes.count > 1 else { return [] }
        return takes.enumerated().map { index, take in
            var levels = WaveformLevels(minimums: [], maximums: [])
            var range: ClosedRange<Double>?
            if let start = project.start(of: take), let end = project.end(of: take), end > start {
                range = start...end
                levels = Self.levels(of: take, from: start, in: project, waveforms: waveforms)
            }
            return TakeRow(
                number: index + 1,
                displayName: "Take \(index + 1)",
                levels: levels,
                isActive: take.isActiveTake,
                range: range,
                text: take.text ?? "",
                isPlaying: take.id == playing
            )
        }
    }

    /// The waveform of a whole clip as one row of blocks, from where the clip starts to where
    /// it ends. A clip joined from several pieces has silence where its pieces leave a gap, so
    /// every piece keeps its place when the row is spread over the clip's time.
    private static func levels(
        of clip: Clip,
        from clipStart: Double,
        in project: Project,
        waveforms: [UUID: WaveformPyramid]
    ) -> WaveformLevels {
        let blocksPerSecond = Lockstep.sampleRate / Double(WaveformPyramid.baseBlockSize)
        var whole = WaveformLevels(minimums: [], maximums: [])
        for segment in clip.segments {
            guard let start = project.start(of: segment), let end = project.end(of: segment), end > start
            else { continue }
            var piece = levels(of: segment, in: waveforms[segment.recordingID])
            if piece.minimums.isEmpty {
                // A recording without a waveform still takes up its time.
                let blocks = max(Int(((end - start) * blocksPerSecond).rounded()), 0)
                piece = WaveformLevels(
                    minimums: [Float](repeating: 0, count: blocks),
                    maximums: [Float](repeating: 0, count: blocks)
                )
            }
            let gap = Int(((start - clipStart) * blocksPerSecond).rounded()) - whole.minimums.count
            if gap > 0 {
                whole.minimums.append(contentsOf: repeatElement(0, count: gap))
                whole.maximums.append(contentsOf: repeatElement(0, count: gap))
            }
            whole.minimums.append(contentsOf: piece.minimums)
            whole.maximums.append(contentsOf: piece.maximums)
        }
        return whole
    }

    /// A waveform made taller or shorter by a volume in dB. 0 dB gives it back as it is.
    private static func scaled(_ levels: WaveformLevels, byDb gainDb: Double) -> WaveformLevels {
        guard gainDb != 0 else { return levels }
        let gain = Float(pow(10, gainDb / 20))
        return WaveformLevels(minimums: levels.minimums.map { $0 * gain }, maximums: levels.maximums.map { $0 * gain })
    }

    /// The waveform of exactly the samples a segment plays, measured from the recording's sound.
    ///
    /// The window spreads a waveform's blocks evenly over the segment's time. The recording's ready-made
    /// waveform (`WaveformPyramid`) has blocks of 256 samples counted from the recording's first sample, so a
    /// segment that starts or ends in the middle of a block would be drawn with up to 255 samples it does not
    /// play, and everything in it up to 5 ms out of place. Here the segment's own samples are divided into
    /// blocks of as near 256 samples as go evenly into it, so every block is drawn where its samples are heard.
    ///
    /// Nil when there is no sound for all of the segment. The caller then falls back on the ready-made waveform.
    private static func exactLevels(of segment: Segment, in sound: [Float]?) -> WaveformLevels? {
        exactLevels(ofSamples: segment.inSample..<segment.outSample, in: sound)
    }

    /// The same for any stretch of a sound: the samples a segment plays of its recording, or the whole of a
    /// tightened sound, which is the segment's samples with its lines moved.
    private static func exactLevels(ofSamples samples: Range<Int>, in sound: [Float]?) -> WaveformLevels? {
        let length = samples.count
        guard let sound, samples.lowerBound >= 0, length > 0, samples.upperBound <= sound.count else { return nil }
        let blocks = max(Int((Double(length) / Double(WaveformPyramid.baseBlockSize)).rounded()), 1)
        var minimums = [Float](repeating: 0, count: blocks)
        var maximums = [Float](repeating: 0, count: blocks)
        sound.withUnsafeBufferPointer { all in
            guard let first = all.baseAddress else { return }
            for block in 0..<blocks {
                let from = samples.lowerBound + block * length / blocks
                let to = max(samples.lowerBound + (block + 1) * length / blocks, from + 1)
                vDSP_minv(first + from, 1, &minimums[block], vDSP_Length(to - from))
                vDSP_maxv(first + from, 1, &maximums[block], vDSP_Length(to - from))
            }
        }
        return WaveformLevels(minimums: minimums, maximums: maximums)
    }

    /// The finest waveform of the part of a recording that a segment plays.
    private static func levels(of segment: Segment, in waveform: WaveformPyramid?) -> WaveformLevels {
        guard let waveform else { return WaveformLevels(minimums: [], maximums: []) }
        let slice = waveform.slice(level: 0, fromSample: segment.inSample, toSample: segment.outSample)
        return WaveformLevels(minimums: Array(slice.minimums), maximums: Array(slice.maximums))
    }
}

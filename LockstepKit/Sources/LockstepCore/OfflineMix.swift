import Accelerate
import Foundation

/// The sound of the clips as one row of samples: every piece of a plan at its place, at its volume and faded at
/// the edges of its segment, and silence everywhere else. Where pieces lie on top of each other their samples
/// are added. The row is mono, at 48,000 Hz, or two rows, left and right, where a clip is played from its
/// finished sound.
///
/// This is the one place where a recording's samples become the sound of a clip. The player lays out the row it
/// plays with `add`, and whatever writes the clips to a file calls `render`. So what is played and what is
/// exported are made by the same code and cannot differ.
///
/// The whole song's clips, or any stretch of them, straight from the project:
///
///     let row = OfflineMix.render(
///         project,
///         from: firstSample, to: endSample,                 // samples of the song. Left out: the whole song
///         recordings: sounds,                               // the recordings' samples by recording id
///         peaks: recordingPeaks.lookup(in: sounds),         // for the safe limit, see `RecordingPeak`
///         edgeFadeMs: settings[.edgeFadeMs]
///     )
///
/// `row[0]` is sample `firstSample` of the song. A stretch that starts or ends in the middle of a segment gets no
/// fade there, because the fades belong to the segment's own edges: the row is exactly that stretch of the row
/// for the whole song.
///
/// With a plan already at hand (`Project.clipPlaybackPlan`), `render(_:recordings:lengthSamples:fadeSamples:)`
/// makes the row, and `add` lays the pieces into memory the caller owns.
///
/// A plan that holds finished pieces (`ClipPiece.isFinished`, from `clipPlaybackPlan(…, finished:)`) is laid out
/// in stereo, with the finished sounds' samples handed in beside the recordings':
///
///     let row = OfflineMix.renderStereo(
///         plan, recordings: sounds, finished: finishedSamples,   // [UUID: StereoSound], by the sounds' ids
///         lengthSamples: length, fadeSamples: fade
///     )
///
/// A finished piece adds its sound's left to the left row and its right to the right row, at the piece's volume
/// and without fades. Every other piece adds the same samples to both rows, exactly as it is in the mono row.
/// The mono functions know nothing of finished sounds: a finished piece is silent in them.
///
/// What is not in the row: the song, the click, and anything about a muted clip, a muted track or a take that
/// waits. The plan has already left those out.
public enum OfflineMix {
    /// What the clips of a project sound like over a stretch of the song.
    ///
    /// - Parameters:
    ///   - project: the project as it is now. Only its tracks, clips and recordings are read.
    ///   - firstSample: the sample of the song the row starts on.
    ///   - endSample: one past the last sample of the row. Nil is the end of the song.
    ///   - recordings: the sound of the recordings, by recording id: mono samples at 48,000 Hz, sample 0 first.
    ///     A recording that is missing here is silent.
    ///   - peaks: the highest sample of a stretch of a recording, for the safe limit on each clip's volume.
    ///   - edgeFadeMs: how long the fade at every segment edge is, in milliseconds: the setting
    ///     `timing.edgeFadeMs`. 0 is no fade.
    ///   - tightened: the tightened sounds to play in place of segments on tracks with Tighten lines on. Their
    ///     samples are in `recordings` under their own ids. Left out, every clip sounds as it was recorded.
    ///   - voices: which made voice stands in for which recording on which track. Their samples are in
    ///     `recordings` under their own ids, and one whose samples are missing counts as not made. `.none`:
    ///     every clip is read from Max's own recordings.
    /// - Returns: one sample for every sample of the stretch. Empty when the stretch has no length.
    public static func render(
        _ project: Project,
        from firstSample: Int = 0,
        to endSample: Int? = nil,
        recordings: [UUID: [Float]],
        peaks: RecordingPeak,
        edgeFadeMs: Double,
        tightened: TightenedSounds = .none,
        voices: TrackVoices
    ) -> [Float] {
        let end = endSample ?? project.songLengthSamples
        return render(
            project.clipPlaybackPlan(
                from: firstSample, to: end, peaks: peaks, tightened: tightened, voices: voices.having(recordings)
            ),
            recordings: recordings,
            lengthSamples: end - firstSample,
            fadeSamples: EdgeFade.samples(milliseconds: edgeFadeMs)
        )
    }

    /// The row a plan gives.
    ///
    /// - Parameters:
    ///   - pieces: what `Project.clipPlaybackPlan(from:to:peaks:)` gave. `startDelay` counts from the row's
    ///     first sample.
    ///   - lengthSamples: how long the row is. A piece that reaches past its end is cut off there.
    ///   - fadeSamples: the length of the fade at every segment edge, from `EdgeFade.samples(milliseconds:)`.
    public static func render(
        _ pieces: [ClipPiece],
        recordings: [UUID: [Float]],
        lengthSamples: Int,
        fadeSamples: Int
    ) -> [Float] {
        guard lengthSamples > 0 else { return [] }
        var row = [Float](repeating: 0, count: lengthSamples)
        row.withUnsafeMutableBufferPointer { add(pieces, recordings: recordings, to: $0, fadeSamples: fadeSamples) }
        return row
    }

    /// Adds the pieces of a plan to a row the caller owns. What the row already holds stays, and the pieces are
    /// added on top, so hand in silence for the clips alone.
    ///
    /// The player uses this for the row it plays. It makes that row again on every change to the clips, also
    /// while the song plays, so this is quick: only the few samples inside a fade are copied and worked on. The
    /// rest of a piece, nearly all of it, goes straight from the recording into the row, multiplied by the volume
    /// on the way. A piece at 0 dB is added as it is, so with a fade of no length every sample is exactly as it
    /// was recorded.
    ///
    /// A piece is kept inside its recording's samples and inside the row (`playable`), so no plan can make this
    /// read or write outside either.
    ///
    /// - Parameter stretches: when given, the pieces are added only inside these stretches of the row, and the
    ///   rest of the row is left as it is. Every sample inside them gets exactly what it gets when the whole
    ///   pieces are added, fades included. Left out, the whole pieces are added.
    public static func add(
        _ pieces: [ClipPiece],
        recordings: [UUID: [Float]],
        to row: UnsafeMutableBufferPointer<Float>,
        fadeSamples: Int,
        inside stretches: [Range<Int>]? = nil
    ) {
        guard let first = row.baseAddress else { return }
        let stretches = stretches.map { tidy($0, lengthSamples: row.count) }
        for piece in playable(pieces, recordings: recordings, lengthSamples: row.count) {
            let parts = parts(of: piece, inside: stretches)
            guard !parts.isEmpty else { continue }
            recordings[piece.recordingID]?.withUnsafeBufferPointer { sound in
                guard let source = sound.baseAddress else { return }
                for part in parts {
                    add(part, of: source, to: first, fadeSamples: fadeSamples)
                }
            }
        }
    }

    /// The row a plan gives, in stereo. `left` and `right` are each `lengthSamples` long. See `add` for what
    /// each kind of piece puts where.
    ///
    /// - Parameters:
    ///   - finished: the samples of the finished sounds, by the ids the finished pieces name.
    public static func renderStereo(
        _ pieces: [ClipPiece],
        recordings: [UUID: [Float]],
        finished: [UUID: StereoSound],
        lengthSamples: Int,
        fadeSamples: Int
    ) -> StereoSound {
        guard lengthSamples > 0 else { return StereoSound(left: [], right: []) }
        var left = [Float](repeating: 0, count: lengthSamples)
        var right = [Float](repeating: 0, count: lengthSamples)
        left.withUnsafeMutableBufferPointer { left in
            right.withUnsafeMutableBufferPointer { right in
                add(pieces, recordings: recordings, finished: finished, toLeft: left, right: right, fadeSamples: fadeSamples)
            }
        }
        return StereoSound(left: left, right: right)
    }

    /// Adds the pieces of a plan to a left and a right row the caller owns, which are equally long. What the
    /// rows already hold stays.
    ///
    /// A finished piece adds the left side of its finished sound to the left row and the right side to the
    /// right row, at the piece's volume. It gets no fades: a finished sound has its own edges, and its tail has
    /// faded out by itself. Every other piece adds the same samples to both rows, at its volume and faded at
    /// the edges of its segment, exactly as the mono `add` lays it into one row.
    ///
    /// The player uses this for the rows it plays when a clip has a finished sound, so it is as quick as the
    /// mono one: nearly every sample goes straight from its sound into a row.
    ///
    /// - Parameter stretches: when given, the pieces are added only inside these stretches of the rows, as in
    ///   the mono `add`.
    public static func add(
        _ pieces: [ClipPiece],
        recordings: [UUID: [Float]],
        finished: [UUID: StereoSound],
        toLeft left: UnsafeMutableBufferPointer<Float>,
        right: UnsafeMutableBufferPointer<Float>,
        fadeSamples: Int,
        inside stretches: [Range<Int>]? = nil
    ) {
        guard let firstLeft = left.baseAddress, let firstRight = right.baseAddress else { return }
        let length = min(left.count, right.count)
        let stretches = stretches.map { tidy($0, lengthSamples: length) }
        for piece in playable(pieces, recordings: recordings, finished: finished, lengthSamples: length) {
            let parts = parts(of: piece, inside: stretches)
            guard !parts.isEmpty else { continue }
            if piece.isFinished {
                guard let sound = finished[piece.recordingID] else { continue }
                for (side, row) in [(sound.left, firstLeft), (sound.right, firstRight)] {
                    side.withUnsafeBufferPointer { samples in
                        guard let source = samples.baseAddress else { return }
                        for part in parts {
                            add(part, of: source, to: row, fadeSamples: 0)
                        }
                    }
                }
            } else {
                recordings[piece.recordingID]?.withUnsafeBufferPointer { sound in
                    guard let source = sound.baseAddress else { return }
                    for part in parts {
                        add(part, of: source, to: firstLeft, fadeSamples: fadeSamples)
                        add(part, of: source, to: firstRight, fadeSamples: fadeSamples)
                    }
                }
            }
        }
    }

    /// The pieces of a plan that there really is sound for, each kept inside its sound's samples and inside
    /// a row of `lengthSamples`. A piece that starts before the row, or whose sound is missing, is left out.
    ///
    /// The sound of a finished piece is looked for among `finished` only, and kept inside the shorter of its
    /// two sides. The sound of any other piece is looked for among `recordings` only. So with `finished` left
    /// out, as the mono functions leave it, a finished piece is never played.
    ///
    /// The player compares this list with the one it last played, to know whether anything changed.
    public static func playable(
        _ pieces: [ClipPiece],
        recordings: [UUID: [Float]],
        finished: [UUID: StereoSound] = [:],
        lengthSamples: Int
    ) -> [ClipPiece] {
        pieces.compactMap { piece in
            let samples = piece.isFinished
                ? finished[piece.recordingID].map { min($0.left.count, $0.right.count) }
                : recordings[piece.recordingID]?.count
            guard let samples, piece.offset >= 0, piece.startDelay >= 0 else { return nil }
            var kept = piece
            kept.length = min(piece.length, samples - piece.offset, lengthSamples - piece.startDelay)
            return kept.length > 0 ? kept : nil
        }
    }

    /// Adds one piece of a recording to the row at its place, at its volume and faded at the edges of its
    /// segment. The piece must lie inside the recording and inside the row.
    ///
    /// - Parameters:
    ///   - sound: the recording's first sample, or the first sample of one side of a finished sound. It is
    ///     only read.
    ///   - row: the first sample of the row.
    ///   - fadeSamples: the length of the fade at the segment's edges. 0 for a finished piece, which is then
    ///     added as it is from its first sample to its last.
    private static func add(
        _ piece: ClipPiece,
        of sound: UnsafePointer<Float>,
        to row: UnsafeMutablePointer<Float>,
        fadeSamples: Int
    ) {
        let source = sound + piece.offset
        let place = row + piece.startDelay
        let untouched = EdgeFade.untouchedPart(
            fadeSamples,
            ofStretch: piece.length,
            at: piece.segmentBefore,
            ofSegmentWithLength: piece.segmentLength
        )
        var gain = piece.gain
        if !untouched.isEmpty {
            let middle = place + untouched.lowerBound
            if gain == 1 {
                vDSP_vadd(source + untouched.lowerBound, 1, middle, 1, middle, 1, vDSP_Length(untouched.count))
            } else {
                // Multiplies and adds in one go, so a clip with a volume costs no more than one without.
                vDSP_vsma(source + untouched.lowerBound, 1, &gain, middle, 1, middle, 1, vDSP_Length(untouched.count))
            }
        }
        for edge in [0..<untouched.lowerBound, untouched.upperBound..<piece.length] where !edge.isEmpty {
            var faded = Array(UnsafeBufferPointer(start: source + edge.lowerBound, count: edge.count))
            EdgeFade.apply(
                fadeSamples,
                to: &faded,
                at: piece.segmentBefore + edge.lowerBound,
                ofSegmentWithLength: piece.segmentLength
            )
            let end = place + edge.lowerBound
            if gain == 1 {
                vDSP_vadd(faded, 1, end, 1, end, 1, vDSP_Length(edge.count))
            } else {
                vDSP_vsma(faded, 1, &gain, end, 1, end, 1, vDSP_Length(edge.count))
            }
        }
    }
}

// MARK: - A row made from the row before

extension OfflineMix {
    /// How the row of a plan is made when the row of the plan before it is at hand.
    public enum RowChange: Sendable, Equatable {
        /// From silence, with every piece added: `add` or `render`.
        case fromNothing
        /// As a copy of the row before, in which only these stretches are laid again (`layAgain`). They are
        /// in order and do not touch. None at all means the row is the row before.
        case layAgain([Range<Int>])
    }

    /// Says how to make the row of `new` from the row of `old` with the least work, so that it holds the very
    /// samples the row made from nothing holds, bit for bit.
    ///
    /// The player has the row of the clips as they were. After an edit most of that row is still right: a
    /// deleted clip changes only the samples it was heard on. So the pieces that left and the pieces that
    /// arrived are found, and the stretches they cover are what must be laid again:
    ///
    ///     switch OfflineMix.rowChange(from: old, fadeSamples: fade, to: new, fadeSamples: fade, lengthSamples: n) {
    ///     case .fromNothing:
    ///         OfflineMix.add(new, recordings: sounds, to: silence, fadeSamples: fade)
    ///     case .layAgain(let stretches):
    ///         // `copy` holds the samples of the row of `old`
    ///         OfflineMix.layAgain(stretches, of: new, recordings: sounds, to: copy, fadeSamples: fade)
    ///     }
    ///
    /// Where pieces lie on top of each other their samples are added one after the other, and the last digit
    /// of a sum depends on the order. So a piece only counts as still there when it also still comes after
    /// the same pieces: the pieces that stay are in the same order in both plans. A clip that went to another
    /// track without moving in time is, for this, a piece that left and one that arrived.
    ///
    /// The row is made from nothing when the fade is another, when there was no row or will be none, and
    /// when laying the stretches again on a copy would be more work than starting with silence: most of the
    /// row changed, or the project is so small that copying a row as long as the song costs more than adding
    /// its few clips. Copying a sample is counted as a quarter of adding one, which is about what it costs.
    ///
    /// - Parameters:
    ///   - old: the pieces the row at hand was made of, as `playable` gave them.
    ///   - oldFade: the fade length that row was made with, in samples.
    ///   - new: the pieces of the row to make, as `playable` gives them for the same row length.
    ///   - lengthSamples: how long both rows are.
    public static func rowChange(
        from old: [ClipPiece],
        fadeSamples oldFade: Int,
        to new: [ClipPiece],
        fadeSamples newFade: Int,
        lengthSamples: Int
    ) -> RowChange {
        guard oldFade == newFade, !old.isEmpty, !new.isEmpty, lengthSamples > 0 else { return .fromNothing }
        // The pieces at the start and at the end of both plans that are the same need no looking up. After an
        // edit that is nearly all of them.
        var first = 0
        while first < old.count, first < new.count, old[first] == new[first] {
            first += 1
        }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > first, newEnd > first, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        // Between them, every piece of the new plan takes the first equal piece of the old plan that comes
        // after the one taken before it. What is taken is in the same order in both plans.
        var places: [ClipPiece: [Int]] = [:]
        for index in first..<oldEnd {
            places[old[index], default: []].append(index)
        }
        var stays = [Bool](repeating: false, count: oldEnd - first)
        var last = first - 1
        var changed: [Range<Int>] = []
        for piece in new[first..<newEnd] {
            if let place = places[piece]?.first(where: { $0 > last }) {
                stays[place - first] = true
                last = place
            } else {
                changed.append(piece.rowSamples)
            }
        }
        for index in first..<oldEnd where !stays[index - first] {
            changed.append(old[index].rowSamples)
        }
        let stretches = tidy(changed, lengthSamples: lengthSamples)
        guard !stretches.isEmpty else { return .layAgain([]) }
        var toLay = 0
        var all = 0
        for piece in new {
            all += piece.length
            toLay += parts(of: piece, inside: stretches).reduce(0) { $0 + $1.length }
        }
        return toLay + lengthSamples / 4 < all ? .layAgain(stretches) : .fromNothing
    }

    /// Makes stretches of a row hold what a plan says: they are silenced, and every piece that reaches into
    /// them is added again there, in the order of the plan. The rest of the row is not touched.
    ///
    /// With the row of the plan before in `row` and the stretches `rowChange` gave, the row is afterwards the
    /// one `add` makes of `pieces` from silence, bit for bit.
    public static func layAgain(
        _ stretches: [Range<Int>],
        of pieces: [ClipPiece],
        recordings: [UUID: [Float]],
        to row: UnsafeMutableBufferPointer<Float>,
        fadeSamples: Int
    ) {
        let stretches = tidy(stretches, lengthSamples: row.count)
        silence(stretches, in: row)
        add(pieces, recordings: recordings, to: row, fadeSamples: fadeSamples, inside: stretches)
    }

    /// The same for a left and a right row, which are equally long: the stretches are silenced in both, and
    /// the pieces are added again there as the stereo `add` adds them.
    ///
    /// Rows that were one, because no clip had a finished sound, are handed in as two copies of it.
    public static func layAgain(
        _ stretches: [Range<Int>],
        of pieces: [ClipPiece],
        recordings: [UUID: [Float]],
        finished: [UUID: StereoSound],
        toLeft left: UnsafeMutableBufferPointer<Float>,
        right: UnsafeMutableBufferPointer<Float>,
        fadeSamples: Int
    ) {
        let stretches = tidy(stretches, lengthSamples: min(left.count, right.count))
        silence(stretches, in: left)
        silence(stretches, in: right)
        add(
            pieces, recordings: recordings, finished: finished, toLeft: left, right: right,
            fadeSamples: fadeSamples, inside: stretches
        )
    }

    private static func silence(_ stretches: [Range<Int>], in row: UnsafeMutableBufferPointer<Float>) {
        guard let first = row.baseAddress else { return }
        for stretch in stretches {
            vDSP_vclr(first + stretch.lowerBound, 1, vDSP_Length(stretch.count))
        }
    }

    /// Stretches kept inside a row, put in order, with those that overlap or touch made one.
    private static func tidy(_ stretches: [Range<Int>], lengthSamples: Int) -> [Range<Int>] {
        var tidy: [Range<Int>] = []
        for stretch in stretches.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let inside = min(max(stretch.lowerBound, 0), lengthSamples)..<min(max(stretch.upperBound, 0), lengthSamples)
            guard !inside.isEmpty else { continue }
            if let before = tidy.last, inside.lowerBound <= before.upperBound {
                tidy[tidy.count - 1] = before.lowerBound..<max(before.upperBound, inside.upperBound)
            } else {
                tidy.append(inside)
            }
        }
        return tidy
    }

    /// The parts of a piece that lie inside stretches, which are in order and do not touch (`tidy`). The
    /// whole piece when there are no stretches to keep to.
    private static func parts(of piece: ClipPiece, inside stretches: [Range<Int>]?) -> [ClipPiece] {
        guard let stretches else { return [piece] }
        // The first stretch that ends after the piece starts.
        var low = 0
        var high = stretches.count
        while low < high {
            let middle = (low + high) / 2
            if stretches[middle].upperBound <= piece.startDelay {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var parts: [ClipPiece] = []
        let end = piece.startDelay + piece.length
        while low < stretches.count, stretches[low].lowerBound < end {
            if let part = piece.cut(to: stretches[low]) {
                parts.append(part)
            }
            low += 1
        }
        return parts
    }
}

extension FinishedSounds {
    /// The lookup with only the finished sounds there are samples for.
    ///
    /// Whoever plays or exports clips with their finished sounds hands in a lookup and the samples it names.
    /// A sound whose samples are not there cannot be played, and a plan that named it would leave its clip
    /// silent. Asked through this, such a clip is played from its segments, dry, as if it had no finished
    /// sound yet.
    public func having(_ samples: [UUID: StereoSound]) -> FinishedSounds {
        FinishedSounds(sounds.filter { samples[$0.value.id] != nil })
    }
}

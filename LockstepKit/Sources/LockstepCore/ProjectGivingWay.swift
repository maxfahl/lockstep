import Foundation

/// Giving way: the clip that was put somewhere last wins, and what it covers of other lines is cut away.
///
/// The rules, as Max asked for them on 13 November 2026:
///
/// - When a clip is recorded, moved, or has an edge dragged outwards so that it covers part of a clip of
///   another line on the same track, the other line gives way: its clip is cut where it is covered, the way a
///   dragged edge cuts it. Covered at one end, it is shortened. Covered in the middle, it becomes two clips.
///   Covered completely, it is removed.
/// - The takes that wait behind that clip are cut or removed the same way, so the line gives way as a whole.
/// - A line is where its shown clip is. When the shown clip is covered completely, the line goes with all
///   its takes, also a waiting take that reaches further than the shown clip did. And on a side of the new
///   clip where the shown clip has nothing left, the waiting takes that are cut keep nothing either. So no
///   rest of a waiting take is left standing as a clip Max never saw.
/// - A cut leaves no rest shorter than 100 ms (`leastRestSamples`): such a rest is removed with what was
///   covered. When that was all the shown clip had left, the line goes.
/// - What a clip covers is everything from its start to its end, a gap inside a joined clip included.
/// - The takes of the clip's own line are never cut by it. A clip that became a take of a line (`lineToJoin`)
///   therefore leaves that line alone, and still makes every other line give way.
/// - Choosing another take of a line (`chooseTake`) is one more way for a clip to come onto others: the
///   chosen take is now the one that was touched last, and what it covers of other lines gives way.
/// - A muted clip takes its place like any other. Clips on other tracks are never touched.
/// - No recording is changed: a clip that was shortened can be dragged out again as far as its recording
///   goes, and then the clip that replaced it gives way in turn.
///
/// Each function changes the project and nothing else. The app runs it inside `ProjectStore.edit` together
/// with what caused it (the take, the move, the trim, the choice), so both are one undo step.
extension Project {
    /// The shortest rest a cut leaves of a clip that gives way: 100 ms, in samples.
    public static let leastRestSamples = 4_800

    /// Makes every other line on a clip's track give way to that clip: what the clip covers is taken out of
    /// their clips, shown and waiting, by the rules at the top of this file.
    ///
    /// - Parameters:
    ///   - peaks: the highest sample of a stretch of a recording, so a clip the safe limit holds back
    ///     stays as loud as it was when it is cut (see the top of `ProjectClipEdits.swift`).
    ///   - voices: which voice stands in for which recording on which track, so the safe limit is asked
    ///     about the sound each clip is heard from on its track (see the top of `ProjectClipEdits.swift`).
    /// - Returns: true when a clip was cut or removed.
    @discardableResult
    public mutating func giveWay(
        to id: Clip.ID,
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices
    ) -> Bool {
        for track in tracks.indices {
            guard let clip = tracks[track].clips.first(where: { $0.id == id }) else { continue }
            // The recordings of the track's clips, found once for all of them.
            let known = recordings(playedBy: tracks[track].clips)
            guard let span = Self.songSpan(of: clip, recording: { known[$0] }), !span.isEmpty else { return false }
            // The other lines of the track, in the order the track holds the first clip of each. Cutting
            // one line never changes the clips of another, so they can all be read before the first cut.
            var lines: [UUID] = []
            var clipsOfLine: [UUID: [Clip]] = [:]
            for other in tracks[track].clips where other.line != clip.line {
                if clipsOfLine[other.line] == nil { lines.append(other.line) }
                clipsOfLine[other.line, default: []].append(other)
            }
            var gaveWay = false
            for line in lines {
                if giveWay(
                    line: clipsOfLine[line] ?? [], onTrackAt: track, to: span, peaks: peaks, voices: voices,
                    known: known
                ) {
                    gaveWay = true
                }
            }
            return gaveWay
        }
        return false
    }

    /// Makes this clip the take of its line that is drawn and heard, as `setActiveTake` does, and makes
    /// every other line it covers part of give way to it, as to a clip that was just recorded there.
    ///
    /// This is what choosing a take in the takes list, Next Take and Previous Take do. A waiting take can
    /// reach over clips of other lines that the take shown until now did not touch, such as after its line
    /// was moved there. Listening to a take with its Play button is not choosing it, and uses
    /// `setActiveTake` on a copy that only the player gets.
    ///
    /// Choosing the take that is already the one shown cuts nothing.
    ///
    /// - Parameters:
    ///   - peaks: the highest sample of a stretch of a recording, so a clip that gives way stays as
    ///     loud as it was (see the top of `ProjectClipEdits.swift`).
    ///   - voices: which voice stands in for which recording on which track, so the safe limit is asked
    ///     about the sound each clip is heard from on its track (see the top of `ProjectClipEdits.swift`).
    /// - Returns: true when a clip of another line was cut or removed.
    @discardableResult
    public mutating func chooseTake(
        _ id: Clip.ID,
        peaks: RecordingPeak = Clip.unknownPeaks,
        voices: TrackVoices
    ) -> Bool {
        guard let chosen = clip(id) else { return false }
        let wasWaiting = !chosen.isActiveTake
        setActiveTake(id)
        return wasWaiting && giveWay(to: id, peaks: peaks, voices: voices)
    }

    /// Makes one line give way to a clip of another line that covers a stretch of the song.
    ///
    /// The shown clip of the line decides. Covered completely, or left with less than `leastRestSamples`,
    /// it takes the whole line with it. Otherwise every clip of the line that the stretch reaches into is
    /// cut, and keeps a rest only on a side where the shown clip has something left.
    ///
    /// - Parameters:
    ///   - clips: every clip of the line, in the order the track holds them.
    ///   - known: the recordings those clips play (`recordings(playedBy:)`).
    /// - Returns: true when a clip was cut or removed.
    private mutating func giveWay(
        line clips: [Clip],
        onTrackAt track: Int,
        to span: Range<Int>,
        peaks: RecordingPeak,
        voices: TrackVoices,
        known: [UUID: Recording]
    ) -> Bool {
        func songSpan(of clip: Clip) -> Range<Int>? {
            Self.songSpan(of: clip, recording: { known[$0] })
        }
        // The clips the stretch reaches into, and how far they reach together.
        var touched: Set<Clip.ID> = []
        var reach = span
        for clip in clips {
            guard let place = songSpan(of: clip),
                  place.lowerBound < span.upperBound, place.upperBound > span.lowerBound
            else { continue }
            touched.insert(clip.id)
            reach = min(reach.lowerBound, place.lowerBound)..<max(reach.upperBound, place.upperBound)
        }
        guard !touched.isEmpty, let first = clips.first else { return false }

        // The clip that is shown: the one active take, or the one `normalizeTakes` would make it.
        let active = clips.filter(\.isActiveTake)
        let shown = active.count == 1 ? active[0] : takes(of: first.id).last ?? first
        // What the shown clip has left on each side of the stretch. A clip with no place in the song says
        // nothing, and the line is then cut on both sides, as any stretch is taken out.
        var keepsBefore = true
        var keepsAfter = true
        if touched.contains(shown.id) {
            if let rests = rests(of: shown, without: span) {
                keepsBefore = (rests.before?.count ?? 0) >= Project.leastRestSamples
                keepsAfter = (rests.after?.count ?? 0) >= Project.leastRestSamples
            }
        } else if let place = songSpan(of: shown) {
            // The stretch does not reach into it, so it stays whole on the side it lies on.
            keepsBefore = place.upperBound <= span.lowerBound
            keepsAfter = !keepsBefore
        }
        guard keepsBefore || keepsAfter else {
            let line = first.line
            tracks[track].clips.removeAll { $0.line == line }
            return true
        }
        // On a side where the shown clip has nothing left, the stretch is taken out as far as the cut
        // clips reach, so they keep nothing there either.
        let from = keepsBefore ? span.lowerBound : reach.lowerBound
        let to = keepsAfter ? span.upperBound : reach.upperBound
        return !takeOut(
            from..<to, ofClips: touched, onTrackAt: track, peaks: peaks, voices: voices,
            leastRest: Project.leastRestSamples
        ).isEmpty
    }

    /// Clips have just come to lie where they are, by a move or because their track was merged into another.
    /// Each line among them is looked at as a whole, by its shown clip:
    ///
    /// - When that clip starts within 50 ms of where the shown clip of a line that did not move starts, the
    ///   moved line becomes takes of that line, with the moved clip as the one that is shown.
    /// - Every other line the clip covers part of gives way to it.
    ///
    /// Lines that moved together never join each other and never cut each other's takes for being takes:
    /// they kept their distances.
    ///
    /// A clip that gives way is asked about on the track it lies on, which for a clip that just came from
    /// another track is the track it came to: it follows that track's Voice from now on.
    ///
    /// - Parameter ids: every clip that moved, the waiting takes included.
    mutating func land(_ ids: Set<Clip.ID>, peaks: RecordingPeak, voices: TrackVoices) {
        for track in tracks.indices {
            // The lines that landed on this track, in the order the track holds them.
            var landed: [UUID] = []
            for clip in tracks[track].clips where ids.contains(clip.id) && !landed.contains(clip.line) {
                landed.append(clip.line)
            }
            let together = Set(landed)
            // The recordings of the track's clips, found once. Giving way cuts and removes clips, and
            // what is left plays the same recordings.
            let known = landed.isEmpty ? [:] : recordings(playedBy: tracks[track].clips)
            for line in landed {
                let takes = tracks[track].clips.filter { $0.line == line }
                guard let shown = takes.first(where: \.isActiveTake) ?? takes.last else { continue }
                let start = Self.songSpan(of: shown, recording: { known[$0] })?.lowerBound
                if let joined = lineToJoin(onTrackAt: track, start: start, notOf: together, known: known) {
                    for index in tracks[track].clips.indices where tracks[track].clips[index].line == line {
                        tracks[track].clips[index].line = joined
                    }
                    for index in tracks[track].clips.indices where tracks[track].clips[index].line == joined {
                        tracks[track].clips[index].isActiveTake = tracks[track].clips[index].id == shown.id
                    }
                }
                giveWay(to: shown.id, peaks: peaks, voices: voices)
            }
        }
    }
}

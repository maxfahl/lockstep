import Foundation
import Testing
@testable import LockstepCore

/// The row of clips made from the row before it: after an edit only the stretches that changed are laid again,
/// and the row must be the very samples the row made from nothing holds, compared bit for bit.
///
/// The song of these tests is twenty seconds long and has five tracks of six clips, one every three seconds,
/// each track 0.4 s later than the one above it, so three or four clips of different tracks sound at once and
/// the order they are added in decides the last digit. Every clip has a recording of its own, two seconds of
/// made-up voice, and every third clip has a volume. The fade at the edges is the 5 ms Lockstep starts with.
@Suite("Offline mix, a row made from the row before")
struct OfflineMixRowChangeTests {
    static let songSamples = 960_000
    static let fade = 240

    /// Everything the sound of the clips is made of.
    struct Heard {
        var project: Project
        var sounds: [UUID: [Float]]
        var tightened = TightenedSounds()
        var finished = FinishedSounds()
        var finishedSamples: [UUID: StereoSound] = [:]
        var fade = OfflineMixRowChangeTests.fade

        /// The pieces the row is made of, as the player works them out. No voice of these tests goes above a
        /// quarter of full scale, and that is what the safe limit is told for every stretch: measuring each
        /// one took most of the time of these tests.
        var pieces: [ClipPiece] {
            let plan = project.clipPlaybackPlan(
                from: 0, to: OfflineMixRowChangeTests.songSamples,
                peaks: { _, _ in 0.25 }, tightened: tightened,
                finished: finished.having(finishedSamples), voices: .none
            )
            return OfflineMix.playable(
                plan, recordings: sounds, finished: finishedSamples, lengthSamples: OfflineMixRowChangeTests.songSamples
            )
        }

        /// The row made from nothing: one row, or two when a clip is played from its finished sound.
        var rows: [[Float]] {
            let pieces = pieces
            guard pieces.contains(where: \.isFinished) else {
                return [OfflineMix.render(
                    pieces, recordings: sounds, lengthSamples: OfflineMixRowChangeTests.songSamples, fadeSamples: fade
                )]
            }
            let stereo = OfflineMix.renderStereo(
                pieces, recordings: sounds, finished: finishedSamples,
                lengthSamples: OfflineMixRowChangeTests.songSamples, fadeSamples: fade
            )
            return [stereo.left, stereo.right]
        }
    }

    /// Voices that differ from each other, the same on every run.
    static func voice(_ number: Int, count: Int = 96_000) -> [Float] {
        var state = UInt64(number + 1) &* 0x9E37_79B9_7F4A_7C15
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 25) - 0.25
        }
    }

    static func heard() -> Heard {
        var sounds: [UUID: [Float]] = [:]
        var recordings: [Recording] = []
        var tracks: [Track] = []
        var number = 0
        for track in 0..<5 {
            var clips: [Clip] = []
            for place in 0..<6 {
                number += 1
                let recording = Recording(lengthSamples: 96_000, rawStart: Double(place) * 3 + Double(track) * 0.4)
                recordings.append(recording)
                sounds[recording.id] = voice(number)
                clips.append(Clip(
                    name: "Clip \(number)",
                    segments: [Segment(recordingID: recording.id, inSample: 500, outSample: 60_000 + number * 1_000)],
                    gainDb: number % 3 == 0 ? -4.5 : 0
                ))
            }
            tracks.append(Track(name: "Track \(track + 1)", clips: clips))
        }
        return Heard(
            project: Project(songLengthSamples: songSamples, tracks: tracks, recordings: recordings), sounds: sounds
        )
    }

    /// The rows of `after`, made the way the player makes them when it has the rows of `before`: from nothing,
    /// or as a copy of the rows before with the stretches that changed laid again.
    static func rows(of after: Heard, madeFrom before: Heard) -> (rows: [[Float]], change: OfflineMix.RowChange) {
        let old = before.pieces
        let new = after.pieces
        let change = OfflineMix.rowChange(
            from: old, fadeSamples: before.fade, to: new, fadeSamples: after.fade, lengthSamples: songSamples
        )
        guard case .layAgain(let stretches) = change else { return (after.rows, change) }
        let rowsBefore = before.rows
        var left = rowsBefore[0]
        guard new.contains(where: \.isFinished) else {
            // One row is enough again: outside the stretches no finished sound is left, so both sides are alike.
            left.withUnsafeMutableBufferPointer {
                OfflineMix.layAgain(stretches, of: new, recordings: after.sounds, to: $0, fadeSamples: after.fade)
            }
            return ([left], change)
        }
        // One row before means both sides were alike.
        var right = rowsBefore.count > 1 ? rowsBefore[1] : rowsBefore[0]
        left.withUnsafeMutableBufferPointer { left in
            right.withUnsafeMutableBufferPointer { right in
                OfflineMix.layAgain(
                    stretches, of: new, recordings: after.sounds, finished: after.finishedSamples,
                    toLeft: left, right: right, fadeSamples: after.fade
                )
            }
        }
        return ([left, right], change)
    }

    /// True when two sets of rows hold the same bits. `==` would call a silence of -0 the same as one of 0.
    static func sameBits(_ rows: [[Float]], _ others: [[Float]]) -> Bool {
        rows.count == others.count && zip(rows, others).allSatisfy { row, other in
            row.count == other.count && row.withUnsafeBytes { bytes in
                other.withUnsafeBytes { memcmp(bytes.baseAddress, $0.baseAddress, bytes.count) == 0 }
            }
        }
    }

    /// True when the rows of `after` made from the rows of `before` are bit for bit the rows made from nothing.
    /// Also hands back how they were made.
    static func sameAsFromNothing(_ after: Heard, madeFrom before: Heard) -> (same: Bool, change: OfflineMix.RowChange) {
        let made = rows(of: after, madeFrom: before)
        return (sameBits(made.rows, after.rows), made.change)
    }

    /// How many samples the stretches of a change cover. The whole row for a row made from nothing.
    static func samples(of change: OfflineMix.RowChange) -> Int {
        guard case .layAgain(let stretches) = change else { return songSamples }
        return stretches.reduce(0) { $0 + $1.count }
    }

    // MARK: A piece inside a stretch

    @Test(
        "A piece added only inside a stretch is that stretch of the whole piece, in both fades and in the middle",
        arguments: [0.0, -4.5, 3.25]
    )
    func pieceInsideAStretch(gainDb: Double) {
        let id = UUID()
        let sound = Self.voice(40, count: 30_000)
        // A piece that is the whole of its segment, and one that begins and ends inside its segment.
        let whole = ClipPiece(recordingID: id, offset: 2_000, startDelay: 5_000, length: 20_000, gainDb: gainDb)
        let part = ClipPiece(
            recordingID: id, offset: 2_100, startDelay: 5_100, length: 19_800,
            segmentBefore: 100, segmentAfter: 100, gainDb: gainDb
        )
        // What lies under the piece is not silence: the sum depends on it, and it must be the same sum.
        let under = Self.voice(41, count: 30_000)
        for piece in [whole, part] {
            var all = under
            all.withUnsafeMutableBufferPointer {
                OfflineMix.add([piece], recordings: [id: sound], to: $0, fadeSamples: Self.fade)
            }
            let stretches = [
                4_000..<5_050,          // from before the piece into the fade at its start
                5_101..<5_102,          // one sample of that fade
                5_200..<5_300,          // across the end of that fade
                9_001..<17_777,         // the middle
                24_700..<24_800,        // across the start of the fade at its end
                24_950..<26_000         // from inside that fade to after the piece
            ]
            for stretch in stretches {
                var only = under
                only.withUnsafeMutableBufferPointer {
                    OfflineMix.add(
                        [piece], recordings: [id: sound], to: $0, fadeSamples: Self.fade, inside: [stretch]
                    )
                }
                #expect(Array(only[stretch]).map(\.bitPattern) == Array(all[stretch]).map(\.bitPattern))
                // Outside the stretch nothing was added.
                #expect(Array(only[..<stretch.lowerBound]) == Array(under[..<stretch.lowerBound]))
                #expect(Array(only[stretch.upperBound...]) == Array(under[stretch.upperBound...]))
            }
            // All the stretches in one go give the same as one after the other.
            var together = under
            together.withUnsafeMutableBufferPointer {
                OfflineMix.add([piece], recordings: [id: sound], to: $0, fadeSamples: Self.fade, inside: stretches)
            }
            for stretch in stretches {
                #expect(Array(together[stretch]).map(\.bitPattern) == Array(all[stretch]).map(\.bitPattern))
            }
        }
    }

    @Test("A piece cut to a stretch keeps its place in its segment, and one that lies outside is no piece")
    func pieceCutToAStretch() {
        let piece = ClipPiece(
            recordingID: UUID(), offset: 300, startDelay: 1_000, length: 500, segmentBefore: 20, segmentAfter: 30, gainDb: -2
        )
        let cut = piece.cut(to: 1_100..<1_250)
        #expect(cut?.offset == 400)
        #expect(cut?.startDelay == 1_100)
        #expect(cut?.length == 150)
        #expect(cut?.segmentBefore == 120)
        #expect(cut?.segmentAfter == 280)
        #expect(cut?.segmentLength == piece.segmentLength)
        #expect(cut?.gainDb == -2)
        #expect(piece.cut(to: 0..<5_000) == piece)
        #expect(piece.cut(to: 0..<1_000) == nil)
        #expect(piece.cut(to: 1_500..<2_000) == nil)
    }

    // MARK: Edits

    @Test("A deleted clip: only its stretch is laid again, and the row is the one made from nothing")
    func clipDeleted() {
        let before = Self.heard()
        var after = before
        let clip = before.project.tracks[1].clips[2]
        after.project.removeClips([clip.id])

        let result = Self.sameAsFromNothing(after, madeFrom: before)
        #expect(result.same)
        // The clip's own stretch and nothing else.
        let place = before.pieces.first { $0.recordingID == clip.segments[0].recordingID }
        #expect(result.change == .layAgain([place!.startDelay..<(place!.startDelay + place!.length)]))
        // And the other way round, as Undo brings it back.
        #expect(Self.sameAsFromNothing(before, madeFrom: after).same)
        #expect(Self.sameAsFromNothing(before, madeFrom: after).change == result.change)
    }

    @Test("A moved clip: where it was and where it is are laid again")
    func clipMoved() {
        let before = Self.heard()
        var after = before
        let clip = before.project.tracks[0].clips[3]
        after.project.moveClips([clip.id], bySamples: 31_337, trackSteps: 0, voices: .none)
        #expect(after.project != before.project)

        let result = Self.sameAsFromNothing(after, madeFrom: before)
        #expect(result.same)
        // The two places overlap, so they are one stretch: the clip's length and how far it moved.
        #expect(Self.samples(of: result.change) == clip.segments[0].lengthSamples + 31_337)
    }

    @Test("A clip moved to another track at the same place changes the order its samples are added in")
    func clipMovedToAnotherTrack() {
        var before = Self.heard()
        // Three clips on top of each other, so the order of the sum matters on every sample.
        let recording = Recording(lengthSamples: 96_000, rawStart: 0.45)
        before.project.recordings.append(recording)
        before.sounds[recording.id] = Self.voice(77)
        let extra = Clip(segments: [Segment(recordingID: recording.id, inSample: 0, outSample: 90_000)], gainDb: -1.5)
        before.project.tracks[0].clips.append(extra)

        var down = before
        down.project.tracks[0].clips.removeAll { $0.id == extra.id }
        down.project.tracks[3].clips.append(extra)
        #expect(Self.sameAsFromNothing(down, madeFrom: before).same)
        // And back up again: the piece now comes earlier in the plan than pieces that stayed.
        #expect(Self.sameAsFromNothing(before, madeFrom: down).same)
    }

    @Test("Tracks in another order")
    func tracksInAnotherOrder() {
        let before = Self.heard()
        var after = before
        after.project.tracks.swapAt(0, 2)
        #expect(Self.sameAsFromNothing(after, madeFrom: before).same)
        after.project.tracks.swapAt(0, 1)
        #expect(Self.sameAsFromNothing(after, madeFrom: before).same)
    }

    @Test("A muted clip, a clip turned up, and a cut clip")
    func clipMutedTurnedUpAndCut() {
        let before = Self.heard()
        let clip = before.project.tracks[2].clips[1]
        let length = clip.segments[0].lengthSamples

        var muted = before
        muted.project.setClips([clip.id], muted: true)
        var result = Self.sameAsFromNothing(muted, madeFrom: before)
        #expect(result.same)
        #expect(Self.samples(of: result.change) == length)

        var louder = before
        louder.project.tracks[2].clips[1].gainDb = 2.5
        result = Self.sameAsFromNothing(louder, madeFrom: before)
        #expect(result.same)
        #expect(Self.samples(of: result.change) == length)

        // Cut in the middle: the two new edges fade, so the samples around the cut change.
        var cut = before
        let start = before.project.start(of: clip)!
        let halves = cut.project.splitClip(clip.id, at: start + 0.5, voices: .none)
        #expect(halves != nil)
        result = Self.sameAsFromNothing(cut, madeFrom: before)
        #expect(result.same)
        #expect(Self.samples(of: result.change) == length)
        // The second half deleted after the cut: only that half is laid again.
        guard let second = halves.flatMap({ cut.project.clip($0.second) }) else { return }
        var half = cut
        half.project.removeClips([second.id])
        result = Self.sameAsFromNothing(half, madeFrom: cut)
        #expect(result.same)
        #expect(Self.samples(of: result.change) == second.segments[0].lengthSamples)
        #expect(second.segments[0].lengthSamples < length)
    }

    @Test("A muted track and a track turned down are laid again where their clips are")
    func trackMutedAndTurnedDown() {
        let before = Self.heard()
        let ofTrack = before.project.tracks[1].clips.reduce(0) { $0 + $1.segments[0].lengthSamples }

        var muted = before
        muted.project.tracks[1].muted = true
        var result = Self.sameAsFromNothing(muted, madeFrom: before)
        #expect(result.same)
        #expect(Self.samples(of: result.change) == ofTrack)
        #expect(Self.sameAsFromNothing(before, madeFrom: muted).same)

        var quieter = before
        quieter.project.tracks[1].gainDb = -6
        result = Self.sameAsFromNothing(quieter, madeFrom: before)
        #expect(result.same)
        #expect(Self.samples(of: result.change) == ofTrack)
    }

    @Test("A tightened sound takes the place of a recording, also one that starts before its clip")
    func tightenedSoundSwappedIn() {
        var before = Self.heard()
        before.project.tracks[0].clips[4].tighten = .lines
        let clip = before.project.tracks[0].clips[4]
        let length = clip.segments[0].lengthSamples

        // The line slid 700 samples out of the clip at its start, so the sound is that much longer.
        var after = before
        let id = UUID()
        after.sounds[id] = Self.voice(90, count: length + 700)
        after.tightened.set(id, for: clip.segments[0], at: 0, of: clip.id, lead: 700, madeFrom: .recordings)
        var result = Self.sameAsFromNothing(after, madeFrom: before)
        #expect(result.same)
        #expect(Self.samples(of: result.change) == length + 700)

        // The sound is made again and has a new id, with a tail this time.
        var again = after
        let next = UUID()
        again.sounds[next] = Self.voice(91, count: length + 300)
        again.tightened.set(next, for: clip.segments[0], at: 0, of: clip.id, tail: 300, madeFrom: .recordings)
        result = Self.sameAsFromNothing(again, madeFrom: after)
        #expect(result.same)
        #expect(Self.samples(of: result.change) == length + 1_000)

        // Before and After: every tightened sound gone at once.
        var dry = again
        dry.tightened = .none
        #expect(Self.sameAsFromNothing(dry, madeFrom: again).same)
    }

    @Test("A finished sound arrives, is made again and leaves: one row becomes two and one again")
    func finishedSoundArrivesAndLeaves() {
        let dry = Self.heard()
        let clip = dry.project.tracks[1].clips[3]
        let length = clip.segments[0].lengthSamples

        var wet = dry
        let id = UUID()
        wet.finished.set(
            FinishedSounds.Sound(id: id, drySamples: length, tailSamples: 9_000, pieces: clip.segments, madeFrom: .recordings), for: clip.id
        )
        wet.finishedSamples[id] = StereoSound(left: Self.voice(60, count: length + 9_000), right: Self.voice(61, count: length + 9_000))
        var result = Self.sameAsFromNothing(wet, madeFrom: dry)
        #expect(result.same)
        #expect(Self.samples(of: result.change) == length + 9_000)
        #expect(Self.rows(of: wet, madeFrom: dry).rows.count == 2)

        // Another clip is deleted while the row is two.
        var fewer = wet
        fewer.project.removeClips([wet.project.tracks[0].clips[0].id])
        result = Self.sameAsFromNothing(fewer, madeFrom: wet)
        #expect(result.same)

        // The finished sound is made again with a shorter tail.
        var again = fewer
        let next = UUID()
        again.finished.set(
            FinishedSounds.Sound(id: next, drySamples: length, tailSamples: 4_000, pieces: clip.segments, madeFrom: .recordings), for: clip.id
        )
        again.finishedSamples[next] = StereoSound(left: Self.voice(62, count: length + 4_000), right: Self.voice(63, count: length + 4_000))
        result = Self.sameAsFromNothing(again, madeFrom: fewer)
        #expect(result.same)
        #expect(Self.samples(of: result.change) == length + 9_000)

        // And it leaves: the clip is played from its segments, and one row is enough again.
        var left = again
        left.finished = .none
        result = Self.sameAsFromNothing(left, madeFrom: again)
        #expect(result.same)
        #expect(Self.rows(of: left, madeFrom: again).rows.count == 1)
    }

    @Test("The same piece twice, and one of the two taken away")
    func samePieceTwice() {
        var before = Self.heard()
        let twin = before.project.tracks[0].clips[2]
        var copy = twin
        copy.id = UUID()
        copy.line = UUID()
        before.project.tracks[2].clips.append(copy)
        #expect(before.pieces.filter { $0.recordingID == twin.segments[0].recordingID }.count == 2)

        var after = before
        after.project.removeClips([twin.id])
        #expect(Self.sameAsFromNothing(after, madeFrom: before).same)
        #expect(Self.sameAsFromNothing(before, madeFrom: after).same)
    }

    // MARK: When the row is made from nothing

    @Test("Another fade length, no clips before, no clips after, and most of the row changed: made from nothing")
    func madeFromNothing() {
        let before = Self.heard()

        var otherFade = before
        otherFade.fade = 480
        var result = Self.sameAsFromNothing(otherFade, madeFrom: before)
        #expect(result.same)
        #expect(result.change == .fromNothing)

        var empty = before
        empty.project.tracks = [Track(name: "Track 1")]
        #expect(Self.sameAsFromNothing(before, madeFrom: empty).change == .fromNothing)
        #expect(Self.sameAsFromNothing(empty, madeFrom: before).change == .fromNothing)

        // Every clip a little later: laying it all again on a copy is more work than starting with silence.
        var moved = before
        moved.project.moveClips(Set(before.project.tracks.flatMap { $0.clips.map(\.id) }), bySamples: 100, trackSteps: 0, voices: .none)
        result = Self.sameAsFromNothing(moved, madeFrom: before)
        #expect(result.same)
        #expect(result.change == .fromNothing)

        // The same clips again: nothing to lay.
        #expect(OfflineMix.rowChange(
            from: before.pieces, fadeSamples: Self.fade, to: before.pieces, fadeSamples: Self.fade,
            lengthSamples: Self.songSamples
        ) == .layAgain([]))
    }

    @Test("In a small project the row is made from nothing, where copying the row before would be more work")
    func smallProject() {
        var before = Self.heard()
        before.project.tracks = [Track(name: "Track 1", clips: Array(before.project.tracks[0].clips.prefix(2)))]
        var after = before
        after.project.removeClips([before.project.tracks[0].clips[0].id])
        let result = Self.sameAsFromNothing(after, madeFrom: before)
        #expect(result.same)
        #expect(result.change == .fromNothing)
    }

    // MARK: Many edits in a row

    @Test("Forty edits one after the other, each row made from the one before, are each the row made from nothing")
    func manyEditsInARow() {
        var state: UInt64 = 0xD1B5_4A32_D192_ED03
        func next(_ below: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(below))
        }
        var before = Self.heard()
        var laidAgain = 0
        for _ in 0..<40 {
            var after = before
            let track = next(after.project.tracks.count)
            let clips = after.project.tracks[track].clips
            switch next(7) {
            case 0 where clips.count > 2:
                after.project.removeClips([clips[next(clips.count)].id])
            case 1 where !clips.isEmpty:
                after.project.moveClips([clips[next(clips.count)].id], bySamples: next(60_000) - 30_000, trackSteps: 0, voices: .none)
            case 2 where !clips.isEmpty:
                after.project.moveClips([clips[next(clips.count)].id], bySamples: 0, trackSteps: next(3) - 1, voices: .none)
            case 3 where !clips.isEmpty:
                after.project.tracks[track].clips[next(clips.count)].gainDb = Double(next(13)) - 6
            case 4 where !clips.isEmpty:
                after.project.tracks[track].clips[next(clips.count)].muted.toggle()
            case 5:
                after.project.tracks[track].muted.toggle()
            default:
                // A copy of a clip of another track, on this one: the same piece twice.
                let other = after.project.tracks[next(after.project.tracks.count)].clips
                guard !other.isEmpty else { continue }
                var copy = other[next(other.count)]
                copy.id = UUID()
                copy.line = UUID()
                after.project.tracks[track].clips.append(copy)
            }
            let result = Self.sameAsFromNothing(after, madeFrom: before)
            #expect(result.same)
            if case .layAgain = result.change { laidAgain += 1 }
            before = after
        }
        // Most of the edits are small, so most rows were made from the row before.
        #expect(laidAgain > 20)
    }
}

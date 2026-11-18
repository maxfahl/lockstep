import Foundation
import Testing
@testable import LockstepCore

/// A line that has to slide out of its clip to reach its sub-beat, and the first syllable of a line with All
/// below 100 %.
///
/// The song, the recording and its three lines are those of `ClipTighteningTests`: the recording began one
/// second into the song, and a sixteenth of the song falls on every 125 ms of it.
///
/// - Line 1 has sound from 500 to 1,100 ms, so the line is 490 to 1,130 ms. Every syllable is 30 ms late.
/// - Line 2 has sound from 2,000 to 2,600 ms, so the line is 1,990 to 2,630 ms. Every syllable is 20 ms early.
@Suite("A line that slides out of its clip")
struct LineReachTests {
    typealias Fixture = ClipTighteningTests
    static let ms = Fixture.ms
    /// The sample of the song on which the recording's first sample is heard.
    static let place = Fixture.recordingPlace

    /// A clip that starts 10 ms before line 1: the line needs 30 ms and has 10.
    static let tightClip = Fixture.clip(480 * ms..<Fixture.recordingMs * ms)

    /// How far the first line of `tightClip` slides in a project, and how long its sound is before the clip.
    static func firstLine(in project: Project) throws -> (shift: Int, lead: Int, samples: Int) {
        let inputs = try #require(ClipTightening.Inputs(clip: tightClip, in: project, markers: Fixture.markers, voices: .none))
        let made = ClipTightening.render(inputs, levels: Fixture.levels, recordings: [Fixture.recording.id: Fixture.sound])
        let first = try #require(made.first)
        return (try #require(first.lines.first).shiftSamples, first.leadSamples, first.samples?.count ?? 0)
    }

    @Test("A line that needs more room than its clip has slides out of it, and the clip is heard from where the line starts")
    func aLineSlidesOutAtTheStart() throws {
        let ms = Self.ms
        let clip = Self.tightClip
        let project = Fixture.project([clip])
        let made = try Fixture.tighten(project)

        // The whole way: 30 ms, of which the clip had 10.
        #expect(made.lines[clip.id]?[0][0].shiftSamples == -30 * ms)
        let sound = try #require(made.lookup.sound(for: clip.segments[0], at: 0, of: clip.id))
        #expect(sound.leadSamples == 20 * ms)
        #expect(sound.tailSamples == 0)
        #expect(made.sounds[sound.id]?.count == clip.segments[0].lengthSamples + 20 * ms)

        // The piece that plays it starts 20 ms earlier, lasts 20 ms longer and reads the sound from its start.
        let recorded = try #require(project.clipPlaybackPlan(from: 0, voices: .none).first)
        let piece = try #require(project.clipPlaybackPlan(from: 0, tightened: made.lookup, voices: .none).first)
        #expect(piece.recordingID == sound.id)
        #expect(piece.startDelay == recorded.startDelay - 20 * ms)
        #expect(piece.length == recorded.length + 20 * ms)
        #expect(piece.offset == 0)
        #expect(piece.segmentBefore == 0 && piece.segmentAfter == 0)
        // Played from inside the part before the clip, it is read from the right sample.
        let inside = try #require(
            project.clipPlaybackPlan(from: Self.place + 465 * ms, tightened: made.lookup, voices: .none).first
        )
        #expect(inside.startDelay == 0)
        #expect(inside.offset == 5 * ms)
        #expect(inside.segmentBefore == 5 * ms)

        // What is heard: the line's sound, recorded from 500 ms on, now from 470 ms on, so its first syllable
        // (530 ms) stands on the sixteenth at 500 ms. Sample for sample the recorded line.
        let after = Fixture.row(project, sounds: made.sounds, tightened: made.lookup)
        #expect(after[Self.place + 460 * ms..<Self.place + 1_100 * ms].elementsEqual(Fixture.sound[490 * ms..<1_130 * ms]))
        // Before the line starts nothing is heard: not the recording's own sound from before the clip.
        #expect(after[..<(Self.place + 460 * ms)].allSatisfy { $0 == 0 })

        // The clip in the project is as it was, and without the tightened sound it is played as recorded.
        #expect(project.tracks[0].clips[0].segments == clip.segments)
        let before = Fixture.row(project, sounds: made.sounds)
        #expect(before[Self.place + 480 * ms..<Self.place + 1_130 * ms].elementsEqual(Fixture.sound[480 * ms..<1_130 * ms]))
        #expect(before[..<(Self.place + 480 * ms)].allSatisfy { $0 == 0 })
    }

    @Test("A line at the end of its clip slides out of it the same way")
    func aLineSlidesOutAtTheEnd() throws {
        let ms = Self.ms
        // The clip ends 10 ms after line 2's sound, so the line is cut there. It is 20 ms early.
        let clip = Fixture.clip(0..<2_610 * ms)
        let project = Fixture.project([clip])
        let made = try Fixture.tighten(project)
        #expect(made.lines[clip.id]?[0][1].shiftSamples == 20 * ms)
        let sound = try #require(made.lookup.sound(for: clip.segments[0], at: 0, of: clip.id))
        #expect(sound.leadSamples == 0)
        #expect(sound.tailSamples == 20 * ms)
        let recorded = try #require(project.clipPlaybackPlan(from: 0, voices: .none).first)
        let piece = try #require(project.clipPlaybackPlan(from: 0, tightened: made.lookup, voices: .none).first)
        #expect(piece.startDelay == recorded.startDelay)
        #expect(piece.length == recorded.length + 20 * ms)
        // The line's sound, recorded from 2,000 to 2,600 ms, is heard 20 ms later.
        let after = Fixture.row(project, sounds: made.sounds, tightened: made.lookup)
        #expect(after[Self.place + 2_020 * ms..<Self.place + 2_620 * ms]
            .elementsEqual(Fixture.sound[2_000 * ms..<2_600 * ms]))
    }

    @Test("The export of such a clip starts where the line starts, and the start asked for with the tightened sounds is the same")
    func theExportStartsWhereTheLineStarts() throws {
        let ms = Self.ms
        let clip = Self.tightClip
        let project = Fixture.project([clip])
        let made = try Fixture.tighten(project)
        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: made.sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, tightened: made.lookup, voices: .none
        ))
        let first = try #require(ClipExporter.startSample(of: clip.id, in: project, tightened: made.lookup, voices: .none))
        #expect(first == Self.place + 460 * ms)
        #expect(ClipExporter.startSample(of: clip.id, in: project, voices: .none) == Self.place + 480 * ms)
        #expect(export.clipSamples == clip.segments[0].lengthSamples + 20 * ms)
        #expect(export.startFrame == project.resolve.startFrame(forTimelineSample: first))
        let after = Fixture.row(project, sounds: made.sounds, tightened: made.lookup)
        #expect(export.samples[export.paddingSamples..<export.paddingSamples + export.clipSamples]
            .elementsEqual(after[first..<first + export.clipSamples]))
    }

    @Test("The clip before it on the track stops a line, and so does the start of what is kept of the song")
    func aNeighbourStopsALine() throws {
        let ms = Self.ms
        let clip = Self.tightClip
        // Alone, the line goes the whole way.
        #expect(try Self.firstLine(in: Fixture.project([clip])).shift == -30 * ms)

        // A clip of another line that ends 5 ms before this one starts: 400 ms of the recording, 75 ms later.
        let near = Fixture.clip(0..<400 * ms, offset: 75 * ms)
        let stopped = try Self.firstLine(in: Fixture.project([near, clip]))
        #expect(stopped.shift == -15 * ms)
        #expect(stopped.lead == 5 * ms)
        #expect(stopped.samples == clip.segments[0].lengthSamples + 5 * ms)

        // One that touches it leaves the line the 10 ms it has inside its clip, as before.
        let touching = Fixture.clip(0..<400 * ms, offset: 80 * ms)
        let held = try Self.firstLine(in: Fixture.project([touching, clip]))
        #expect(held.shift == -10 * ms)
        #expect(held.lead == 0)
        #expect(held.samples == clip.segments[0].lengthSamples)

        // A take that waits is not shown and stops nothing. Neither does another take of the clip's own line.
        var waiting = touching
        waiting.isActiveTake = false
        #expect(try Self.firstLine(in: Fixture.project([waiting, clip])).shift == -30 * ms)
        var sameLine = touching
        sameLine.line = clip.line
        #expect(try Self.firstLine(in: Fixture.project([sameLine, clip])).shift == -30 * ms)
        // A clip on another track stops nothing either.
        var twoTracks = Fixture.project([clip])
        twoTracks.tracks.append(Track(name: "Track 2", clips: [touching]))
        #expect(try Self.firstLine(in: twoTracks).shift == -30 * ms)

        // The song cut so that 12 ms are left before the clip: the line goes 10 + 12 ms.
        var cut = Fixture.project([clip])
        cut.songPlace = SongPlace(cutStartSamples: Self.place + 468 * ms)
        let atTheCut = try Self.firstLine(in: cut)
        #expect(atTheCut.shift == -22 * ms)
        #expect(atTheCut.lead == 12 * ms)
    }

    @Test("The room around a clip is what is free on its track, and never more than asked for")
    func theRoomAroundAClip() throws {
        let ms = Self.ms
        let clip = Self.tightClip
        let near = Fixture.clip(0..<400 * ms, offset: 75 * ms)
        let project = Fixture.project([near, clip])
        // Before the clip the neighbour, after it the end of the song, one second after the recording's end.
        #expect(project.room(around: clip) == [ClipTightening.Room(before: 5 * ms, after: 48_000)])
        #expect(project.room(around: clip, atMost: 80 * ms) == [ClipTightening.Room(before: 5 * ms, after: 80 * ms)])
        // Before the neighbour the start of the song, after it the clip.
        #expect(project.room(around: near, atMost: 80 * ms) == [ClipTightening.Room(before: 80 * ms, after: 5 * ms)])

        // A clip joined of two pieces: each piece is stopped by the other.
        let joined = Clip(segments: [
            Segment(recordingID: Fixture.recording.id, inSample: 480 * ms, outSample: 1_500 * ms),
            Segment(recordingID: Fixture.recording.id, inSample: 1_520 * ms, outSample: 3_000 * ms),
        ])
        #expect(Fixture.project([joined]).room(around: joined, atMost: 80 * ms) == [
            ClipTightening.Room(before: 80 * ms, after: 20 * ms),
            ClipTightening.Room(before: 20 * ms, after: 80 * ms),
        ])

        // The sound of a clip is made again when something comes close to it, and not when it stays far away.
        func inputs(_ clips: [Clip]) -> ClipTightening.Inputs? {
            ClipTightening.Inputs(clip: clip, in: Fixture.project(clips), markers: Fixture.markers, voices: .none)
        }
        let far = Fixture.clip(0..<200 * ms, offset: 80 * ms)
        #expect(inputs([near, clip]) != inputs([clip]))
        #expect(inputs([far, clip]) == inputs([clip]))
    }

    @Test("With All at 50 % the first syllable of a line moves like the others: half of what the slide left to its sub-beat")
    func theFirstSyllableFollowsTheStrength() throws {
        let ms = Self.ms
        func lines(_ tighten: ClipTighten, strength: Double) throws -> [ClipTightening.Line] {
            var clip = Fixture.clip()
            clip.tighten = tighten
            clip.strength = strength
            let inputs = try #require(ClipTightening.Inputs(
                correcting: clip, in: Fixture.project([clip]), markers: Fixture.markers, voices: .none
            ))
            // The stretcher is never needed here: within each line every syllable moves by the same amount.
            return ClipTightening.render(
                inputs, levels: Fixture.levels, recordings: [Fixture.recording.id: Fixture.sound], stretcher: LinearStretcher()
            )[0].lines
        }
        // Line 1 is 30 ms late. The slide takes it half of the way, 15 ms, and its first syllable then goes
        // half of the 15 ms that are left, with the whole line: 22.5 ms.
        let all = try lines(.all, strength: 0.5)
        #expect(all[0].slideSamples == -15 * ms)
        #expect(all[0].carriedSamples == -15 * ms / 2)
        #expect(all[0].shiftSamples == -15 * ms - 15 * ms / 2)
        // Every syllable of the line was 30 ms late, so every one ends where the first does.
        for syllable in [530, 655, 780, 905] {
            #expect(all[0].map.result(ofSource: syllable * ms) - syllable * ms == -15 * ms - 15 * ms / 2)
        }
        // Line 2 is 20 ms early: 10 ms by the slide and 5 ms more. Line 3 is on the beat and stays.
        #expect(all[1].slideSamples == 10 * ms)
        #expect(all[1].shiftSamples == 15 * ms)
        #expect(all[2].shiftSamples == 0)

        // With Lines only the lines slide, and at 100 % the first syllable is on its sub-beat already.
        let linesOnly = try lines(.lines, strength: 0.5)
        #expect(linesOnly[0].shiftSamples == -15 * ms)
        #expect(linesOnly[0].carriedSamples == 0)
        let whole = try lines(.all, strength: 1)
        #expect(whole[0].shiftSamples == -30 * ms)
        #expect(whole[0].carriedSamples == 0)
    }

    @Test("A syllable that the slide alone put on its sub-beat stays there when the line goes on with its first syllable")
    func theOtherSyllablesAreMeasuredFromTheSlide() {
        // Sixteenths at 3.0, 3.125 and 3.25 s. The first syllable is 30 ms late, the second 15 ms, the third 30 ms.
        let grid = Grid(beats: (0..<40).map { Beat(number: $0, time: 2 + Double($0) * 0.5) })
        func sample(_ time: Double) -> Int { 10_000 + Int(((time - 2.9) * 48_000).rounded()) }
        let line = VoiceLine(
            startSample: sample(2.9), endSample: sample(3.7), markers: [3.03, 3.14, 3.28].map(sample)
        )
        // At 50 % the line slides 15 ms earlier and goes 7.5 ms further with its first syllable.
        let map = SyllableMoves.plan(
            line: line, shiftSamples: -1_080, carriedSamples: -360, songStart: 2.9, grid: grid, strength: 0.5
        )
        // The first and the third are 15 ms late after the slide and move half of that, which the line has
        // done for them. The second stands on its sub-beat after the slide, and is moved back to stay there.
        #expect(map.pairs.map { $0.result - $0.source } == [-1_080, -1_080, -720, -1_080, -1_080])
    }
}

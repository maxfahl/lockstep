import Foundation
import Testing
@testable import LockstepCore

/// The answer of a call that changes what it is called on. Such a call cannot stand inside `#expect` itself.
private func answer<Answer>(_ change: () -> Answer) -> Answer {
    change()
}

/// A twenty-second song with one empty track.
private func song() -> Project {
    Project(songLengthSamples: 960_000)
}

/// Records a clip the way the app does: a new recording whose clip begins `start` seconds into the song and is
/// `seconds` long. Returns the id of the clip.
@discardableResult
private func record(_ start: Double, _ seconds: Double = 1, in project: inout Project, aimedAt aim: Double? = nil) -> UUID {
    let recording = Recording(lengthSamples: Int((seconds * Lockstep.sampleRate).rounded()), rawStart: start)
    return project.addRecording(
        recording,
        samples: 0..<recording.lengthSamples,
        asClipOn: project.tracks[0].id,
        aim: aim.map { RecordAim(place: $0) }, voices: .none
    )!
}

/// The recording a clip's first segment plays.
private func recording(of clipID: UUID, in project: Project) -> UUID {
    project.clip(clipID)!.segments[0].recordingID
}

private func markers(_ samples: Int...) -> [SyllableMarker] {
    samples.map { SyllableMarker(sample: $0, strength: 12) }
}

@Suite("A marked stretch catches on syllables and pauses")
struct ClipSpanCatchingTests {
    /// A clip from 2 s to 4 s with syllables at 0.5 s, 0.9 s and 1.4 s of its recording, and a pause from
    /// 1.1 s to 1.3 s.
    private func line() -> (project: Project, clip: Clip, recording: UUID, markers: [UUID: [SyllableMarker]], pauses: [UUID: [Range<Int>]]) {
        var project = song()
        let id = record(2, 2, in: &project)
        let recording = recording(of: id, in: project)
        return (
            project, project.clip(id)!, recording,
            [recording: markers(24_000, 43_200, 67_200)],
            [recording: [52_800..<62_400]]
        )
    }

    @Test func bothEndsMoveOntoTheNearestSyllableOrPauseEdgeWithinSixtyMilliseconds() {
        let line = line()
        // Dragged from 40 ms before the first syllable to 50 ms after the pause begins.
        let span = ClipSpan.catching(
            2.46..<3.15, in: line.clip, of: line.project, markers: line.markers, pauses: line.pauses
        )
        #expect(span == ClipSpan(recordingID: line.recording, inSample: 24_000, outSample: 52_800))
        // And from 30 ms after the second syllable to 20 ms before the third.
        let word = ClipSpan.catching(
            2.93..<3.38, in: line.clip, of: line.project, markers: line.markers, pauses: line.pauses
        )
        #expect(word == ClipSpan(recordingID: line.recording, inSample: 43_200, outSample: 67_200))
    }

    @Test func anEndWithNothingInReachStaysWhereItWasDragged() {
        let line = line()
        // 100 ms after the first syllable, and 200 ms after the third: nothing within 60 ms of either.
        let span = ClipSpan.catching(
            2.6..<3.6, in: line.clip, of: line.project, markers: line.markers, pauses: line.pauses
        )
        #expect(span == ClipSpan(recordingID: line.recording, inSample: 28_800, outSample: 76_800))
        // The nearer of two points in reach wins: 0.86 s is 40 ms from the syllable at 0.9 s.
        let near = ClipSpan.catching(
            2.86..<3.6, in: line.clip, of: line.project, markers: [line.recording: markers(38_400, 43_200)]
        )
        #expect(near?.inSample == 43_200)
    }

    @Test func theSpanIsKeptInsideWhatTheClipPlaysAndCatchesOnItsEdges() {
        let line = line()
        // Dragged from before the clip to past its end.
        let whole = ClipSpan.catching(1.0..<5.0, in: line.clip, of: line.project, markers: [:])
        #expect(whole == ClipSpan(recordingID: line.recording, inSample: 0, outSample: 96_000))
        // 30 ms inside the clip's start: the edge is in reach.
        let start = ClipSpan.catching(2.03..<2.6, in: line.clip, of: line.project, markers: [:])
        #expect(start?.inSample == 0)
        // A clip whose start was trimmed away plays nothing before its edge.
        var trimmed = line.project
        trimmed.trimClip(line.clip.id, edge: .start, toSongSample: 96_000 + 24_000 + 4_800, voices: .none)
        let cut = ClipSpan.catching(
            2.2..<3.6, in: trimmed.clip(line.clip.id)!, of: trimmed, markers: line.markers
        )
        #expect(cut == ClipSpan(recordingID: line.recording, inSample: 28_800, outSample: 76_800))
    }

    @Test func aStretchOfWhichLessThanTwentyMillisecondsAreLeftGivesNothing() {
        let line = line()
        // Both ends catch on the same syllable.
        #expect(ClipSpan.catching(2.49..<2.52, in: line.clip, of: line.project, markers: line.markers) == nil)
        // Outside the clip.
        #expect(ClipSpan.catching(5.0..<6.0, in: line.clip, of: line.project, markers: line.markers) == nil)
        // 10 ms, with nothing in reach.
        #expect(ClipSpan.catching(2.7..<2.71, in: line.clip, of: line.project, markers: [:]) == nil)
        #expect(ClipSpan.catching(2.7..<2.72, in: line.clip, of: line.project, markers: [:]) != nil)
    }

    @Test func aStretchOverTwoRecordingsOfAJoinedClipIsCutToThePartThatHoldsMostOfIt() throws {
        var project = song()
        let first = record(2, in: &project)
        let second = record(3.5, in: &project)
        let firstRecording = recording(of: first, in: project)
        let secondRecording = recording(of: second, in: project)
        let joined = try #require(answer { project.joinClips([first, second], voices: .none) })
        let clip = try #require(project.clip(joined))

        // 0.3 s of the first part and 0.6 s of the second.
        let late = ClipSpan.catching(2.7..<4.1, in: clip, of: project, markers: [:])
        #expect(late == ClipSpan(recordingID: secondRecording, inSample: 0, outSample: 28_800))
        // 0.6 s of the first part and 0.2 s of the second.
        let early = ClipSpan.catching(2.4..<3.7, in: clip, of: project, markers: [:])
        #expect(early == ClipSpan(recordingID: firstRecording, inSample: 19_200, outSample: 48_000))
        // Only the silence between the parts.
        #expect(ClipSpan.catching(3.1..<3.4, in: clip, of: project, markers: [:]) == nil)
    }

    @Test func onACorrectedClipTheStretchIsHeldAgainstWhereTheSyllablesAreHeard() {
        let line = line()
        // Everything is heard 100 ms later than it was recorded.
        let shift: (Int, Int) -> Int = { _, _ in 4_800 }
        // The first syllable is heard at 2.6 s. Dragged from 2.63 s: it catches.
        let caught = ClipSpan.catching(
            2.63..<3.2, in: line.clip, of: line.project, markers: line.markers, heardShift: shift
        )
        #expect(caught?.inSample == 24_000)
        // With nothing in reach an end is the sample that is heard there: 3.2 s is 1.1 s into the recording.
        #expect(caught?.outSample == 52_800)
    }

    @Test func thePausesOfAClipAreTheQuietStretchesBetweenItsSyllables() {
        let line = line()
        // Sound everywhere but from 1.1 s to 1.3 s, one value for each millisecond.
        var values = [Float](repeating: -20, count: 2_000)
        for index in 1_100..<1_300 { values[index] = -70 }
        let levels = VoiceLevels(values: values, threshold: -50)
        let pauses = ClipSpan.pauses(in: line.clip, markers: line.markers, levels: [line.recording: levels])
        #expect(pauses == [line.recording: [52_800..<62_400]])
        #expect(ClipSpan.pauses(in: line.clip, markers: line.markers, levels: [:]).isEmpty)
    }
}

@Suite("Adding, removing and turning an effect")
struct ProjectEffectsTests {
    @Test func everyKindHasItsNumbersFromTheTable() {
        #expect(ClipEffect.Kind.allCases.map(\.startLevelDb) == [-9, -8, -10, -16, -9, -9, -6, -6, 0, 0, 0, -8])
        #expect(ClipEffect.Kind.allCases.filter(\.isLayer) == [.thick, .lowFourth, .lowOctave, .high, .big, .small, .echoQuarter, .echoEighth, .swell])
        #expect(ClipEffect.Kind.allCases.filter(\.isDouble) == [.thick, .lowFourth, .lowOctave, .high, .big, .small])
        #expect(ClipEffect.Kind.allCases.filter(\.followsBeats) == [.echoQuarter, .echoEighth, .stutter, .swell])
        #expect(ClipEffect.Kind.lowOctave.menuName == "Low, an octave down")
        #expect(Set(ClipEffect.Kind.allCases.map(\.menuName)).count == 12)
    }

    @Test func anEffectOnTheWholeClipStartsAtItsKindsLevelAndIsSetForTheWaitingTakesToo() throws {
        var project = song()
        let first = record(2, in: &project, aimedAt: 2)
        let second = record(2, in: &project, aimedAt: 2)
        let other = record(6, in: &project)
        project.normalizeTakes()
        #expect(project.takeCount(of: second) == 2)

        let id = try #require(answer { project.addEffect(second, kind: .thick) })
        let effect = ClipEffect(id: id, kind: .thick, levelDb: -9)
        #expect(project.clip(second)?.effects == [effect])
        #expect(project.clip(first)?.effects == [effect])
        #expect(project.clip(other)?.effects == [])

        // Its level, held to -24...+6, for the takes too.
        #expect(answer { project.setEffect(id, of: second, levelDb: -3) })
        #expect(project.clip(first)?.effects.first?.levelDb == -3)
        #expect(!answer { project.setEffect(id, of: second, levelDb: -3) })
        #expect(answer { project.setEffect(id, of: second, levelDb: 40) })
        #expect(project.clip(second)?.effects.first?.levelDb == 6)
        #expect(answer { project.setEffect(id, of: second, levelDb: -90) })
        #expect(project.clip(first)?.effects.first?.levelDb == -24)

        #expect(answer { project.removeEffect(id, from: second) })
        #expect(project.clip(second)?.effects == [])
        #expect(project.clip(first)?.effects == [])
        #expect(!answer { project.removeEffect(id, from: second) })
        #expect(answer { project.addEffect(UUID(), kind: .thick) } == nil)
    }

    @Test func anEffectOnAStretchBelongsToItsTakeAlone() throws {
        var project = song()
        let first = record(2, in: &project, aimedAt: 2)
        let second = record(2, in: &project, aimedAt: 2)
        project.normalizeTakes()
        let span = ClipSpan(recordingID: recording(of: second, in: project), inSample: 4_800, outSample: 14_400)

        let id = try #require(answer { project.addEffect(second, kind: .lowOctave, span: span) })
        #expect(project.clip(second)?.effects == [ClipEffect(id: id, kind: .lowOctave, span: span, levelDb: -10)])
        #expect(project.clip(first)?.effects == [])
        #expect(answer { project.setEffect(id, of: second, levelDb: -6) })
        #expect(project.clip(first)?.effects == [])

        // A stretch of a recording the clip does not play, or of less than 20 ms, is refused.
        #expect(answer { project.addEffect(second, kind: .big, span: ClipSpan(recordingID: UUID(), inSample: 0, outSample: 9_600)) } == nil)
        #expect(answer { project.addEffect(second, kind: .big, span: ClipSpan(recordingID: span.recordingID, inSample: 0, outSample: 959)) } == nil)
        // One that reaches past what the clip plays is cut down to it.
        let long = ClipSpan(recordingID: span.recordingID, inSample: 40_000, outSample: 60_000)
        let cut = try #require(answer { project.addEffect(second, kind: .big, span: long) })
        #expect(project.clip(second)?.effects.first { $0.id == cut }?.span?.outSample == 48_000)
    }

    @Test func aKindThatReplacesTheVoiceHasNoLevelToTurn() throws {
        var project = song()
        let clip = record(2, in: &project)
        let id = try #require(answer { project.addEffect(clip, kind: .phone) })
        #expect(project.clip(clip)?.effects.first?.levelDb == 0)
        #expect(!answer { project.setEffect(id, of: clip, levelDb: -6) })
    }

    @Test func aNewTakeStartsWithTheWholeClipEffectsOfTheTakeHeardUntilThen() throws {
        var project = song()
        let first = record(2, in: &project, aimedAt: 2)
        let whole = try #require(answer { project.addEffect(first, kind: .high) })
        let span = ClipSpan(recordingID: recording(of: first, in: project), inSample: 0, outSample: 9_600)
        project.addEffect(first, kind: .lowFourth, span: span)

        let second = record(2, in: &project, aimedAt: 2)
        project.normalizeTakes()
        #expect(project.clip(second)?.effects == [ClipEffect(id: whole, kind: .high, levelDb: -16)])
        // And turning it on the new take reaches the old one.
        #expect(answer { project.setEffect(whole, of: second, levelDb: -12) })
        #expect(project.clip(first)?.effects.first?.levelDb == -12)
        #expect(project.clip(first)?.effects.count == 2)
    }
}

@Suite("Effects through trims, splits, joins and copies")
struct ClipEffectsThroughEditsTests {
    /// A two-second clip at 2 s with a Low double on 0.5 s to 1.0 s of its recording and a Thick double on
    /// the whole of it.
    private func clipWithEffects() -> (project: Project, clip: UUID, recording: UUID, word: UUID, whole: UUID) {
        var project = song()
        let clip = record(2, 2, in: &project)
        let recording = recording(of: clip, in: project)
        let whole = project.addEffect(clip, kind: .thick)!
        let word = project.addEffect(
            clip, kind: .lowOctave, span: ClipSpan(recordingID: recording, inSample: 24_000, outSample: 48_000)
        )!
        return (project, clip, recording, word, whole)
    }

    private func span(_ effect: UUID, of clip: UUID, in project: Project) -> ClipSpan? {
        project.clip(clip)?.effects.first { $0.id == effect }?.span
    }

    @Test func aTrimCutsASpanDownToWhatTheClipStillPlays() {
        var (project, clip, recording, word, whole) = clipWithEffects()
        // The start goes to 0.7 s of the recording.
        project.trimClip(clip, edge: .start, toSongSample: 96_000 + 33_600, voices: .none)
        project.normalizeEffects()
        #expect(span(word, of: clip, in: project) == ClipSpan(recordingID: recording, inSample: 33_600, outSample: 48_000))
        #expect(project.clip(clip)?.effects.map(\.id) == [whole, word])

        // To 10 ms before the span's end: less than 20 ms of it is played, and it goes.
        project.trimClip(clip, edge: .start, toSongSample: 96_000 + 47_520, voices: .none)
        project.normalizeEffects()
        #expect(project.clip(clip)?.effects.map(\.id) == [whole])
        // Dragging the edge out again does not bring it back.
        project.trimClip(clip, edge: .start, toSongSample: 96_000, voices: .none)
        project.normalizeEffects()
        #expect(project.clip(clip)?.effects.map(\.id) == [whole])
    }

    @Test func aSplitThroughASpanLeavesEachPieceTheShareItPlays() throws {
        var (project, clip, recording, word, whole) = clipWithEffects()
        // At 0.75 s of the recording.
        let pieces = try #require(answer { project.splitClip(clip, at: 2.75, voices: .none) })
        project.normalizeEffects()
        #expect(span(word, of: pieces.first, in: project) == ClipSpan(recordingID: recording, inSample: 24_000, outSample: 36_000))
        #expect(span(word, of: pieces.second, in: project) == ClipSpan(recordingID: recording, inSample: 36_000, outSample: 48_000))
        // The effect on the whole clip is on both pieces.
        #expect(project.clip(pieces.first)?.effects.map(\.id) == [whole, word])
        #expect(project.clip(pieces.second)?.effects.map(\.id) == [whole, word])
        // They are two clips now: turning one does not turn the other.
        #expect(answer { project.setEffect(whole, of: pieces.second, levelDb: -3) })
        #expect(project.clip(pieces.first)?.effects.first?.levelDb == -9)
    }

    @Test func aSplitBesideASpanLeavesItOnThePieceThatPlaysIt() throws {
        var (project, clip, _, word, whole) = clipWithEffects()
        // 10 ms into the span: the first piece plays too little of it.
        let pieces = try #require(answer { project.splitClip(clip, at: 2.51, voices: .none) })
        project.normalizeEffects()
        #expect(project.clip(pieces.first)?.effects.map(\.id) == [whole])
        #expect(project.clip(pieces.second)?.effects.map(\.id) == [whole, word])
        #expect(span(word, of: pieces.second, in: project)?.inSample == 24_480)
    }

    @Test func aMarkedStretchDeletedFromTheMiddleOfASpanLeavesBothRests() throws {
        var (project, clip, recording, word, _) = clipWithEffects()
        // 0.6 s to 0.8 s of the recording goes.
        let left = try #require(answer { project.cut(range: 2.6..<2.8, onTrack: project.tracks[0].id, voices: .none) })
        project.normalizeEffects()
        #expect(left.count == 2)
        #expect(span(word, of: left[0], in: project) == ClipSpan(recordingID: recording, inSample: 24_000, outSample: 28_800))
        #expect(span(word, of: left[1], in: project) == ClipSpan(recordingID: recording, inSample: 38_400, outSample: 48_000))
        #expect(left[0] == clip)
    }

    @Test func splittingAndJoiningAgainGivesTheEffectsThereWere() throws {
        var (project, clip, _, _, _) = clipWithEffects()
        let before = try #require(project.clip(clip)?.effects)
        let pieces = try #require(answer { project.splitClip(clip, at: 2.75, voices: .none) })
        project.normalizeEffects()
        let joined = try #require(answer { project.joinClips([pieces.first, pieces.second], voices: .none) })
        project.normalizeEffects()
        #expect(project.clip(joined)?.effects == before)
    }

    @Test func aJoinedClipKeepsTheEffectsOfAllItsPartsEachOnThePartItWasOn() throws {
        var project = song()
        let first = record(2, in: &project)
        let second = record(4, in: &project)
        let firstRecording = recording(of: first, in: project)
        let secondRecording = recording(of: second, in: project)
        let big = try #require(answer { project.addEffect(first, kind: .big) })
        let word = ClipSpan(recordingID: secondRecording, inSample: 9_600, outSample: 19_200)
        let low = try #require(answer { project.addEffect(second, kind: .lowFourth, span: word) })
        let high = try #require(answer { project.addEffect(second, kind: .high) })

        let joined = try #require(answer { project.joinClips([first, second], voices: .none) })
        project.normalizeEffects()
        // Only the first part had Big, and only the second had High: each stays on the part it was on.
        #expect(project.clip(joined)?.effects == [
            ClipEffect(id: big, kind: .big, span: ClipSpan(recordingID: firstRecording, inSample: 0, outSample: 48_000), levelDb: -9),
            ClipEffect(id: low, kind: .lowFourth, span: word, levelDb: -8),
            ClipEffect(id: high, kind: .high, span: ClipSpan(recordingID: secondRecording, inSample: 0, outSample: 48_000), levelDb: -16),
        ])
    }

    @Test func anEffectThatEveryPartHasOnTheWholeOfItStaysOnTheWholeJoinedClip() throws {
        var project = song()
        let first = record(2, in: &project)
        let second = record(4, in: &project)
        let thick = try #require(answer { project.addEffect(first, kind: .thick) })
        project.addEffect(second, kind: .thick)
        let high = try #require(answer { project.addEffect(second, kind: .high) })
        project.addEffect(first, kind: .high)
        // The same kind at another level is not the same effect.
        var louder = project
        let joined = try #require(answer { project.joinClips([first, second], voices: .none) })
        #expect(project.clip(joined)?.effects.map(\.kind) == [.thick, .high])
        #expect(project.clip(joined)?.effects.map(\.span) == [nil, nil])
        #expect(project.clip(joined)?.effects.first?.id == thick)

        louder.setEffect(high, of: second, levelDb: -6)
        let other = try #require(answer { louder.joinClips([first, second], voices: .none) })
        #expect(louder.clip(other)?.effects.map(\.kind) == [.thick, .high, .high])
        #expect(louder.clip(other)?.effects.map { $0.span == nil } == [true, false, false])
        #expect(Set(louder.clip(other)?.effects.map(\.id) ?? []).count == 3)
    }

    @Test func aCopyKeepsItsEffectsAndIsAClipOfItsOwn() throws {
        var (project, clip, _, word, whole) = clipWithEffects()
        let copy = try #require(answer {
            project.paste(project.copyClips([clip]), onTrack: project.tracks[0].id, atSample: 48_000 * 10, voices: .none)
        }.first)
        project.normalizeEffects()
        #expect(project.clip(copy.id)?.effects == project.clip(clip)?.effects)
        #expect(answer { project.removeEffect(word, from: copy.id) })
        #expect(answer { project.setEffect(whole, of: copy.id, levelDb: 0) })
        #expect(project.clip(clip)?.effects.map(\.levelDb) == [-9, -10])
    }

    @Test func theStorePutsTheEffectsRightAfterEveryEdit() async throws {
        let (project, clip, _, word, whole) = clipWithEffects()
        let store = await ProjectStore(project: project)
        await store.edit("Trim Clip") { $0.trimClip(clip, edge: .start, toSongSample: 96_000 + 60_000, voices: .none) }
        #expect(await store.project.clip(clip)?.effects.map(\.id) == [whole])
        await store.undo()
        #expect(await store.project.clip(clip)?.effects.map(\.id) == [whole, word])
    }
}

@Suite("Where the window draws a clip's effects")
struct EffectStretchesTests {
    @Test func aSpanIsGivenAsSongSecondsThatFollowTheClip() throws {
        var project = song()
        let clip = record(2, 2, in: &project)
        let recording = recording(of: clip, in: project)
        let whole = try #require(answer { project.addEffect(clip, kind: .thick) })
        let word = try #require(answer {
            project.addEffect(clip, kind: .lowOctave, span: ClipSpan(recordingID: recording, inSample: 24_000, outSample: 48_000))
        })

        #expect(project.effectStretches(of: project.clip(clip)!, voices: .none) == [
            EffectStretch(id: whole, kind: .thick, seconds: nil),
            EffectStretch(id: word, kind: .lowOctave, seconds: 2.5..<3.0),
        ])
        project.moveClips([clip], bySamples: 48_000, trackSteps: 0, voices: .none)
        #expect(project.effectStretches(of: project.clip(clip)!, voices: .none).last?.seconds == 3.5..<4.0)
    }

    @Test func onACorrectedClipASpanIsDrawnWhereItsSyllablesAreHeard() throws {
        var project = song()
        let clip = record(2, 2, in: &project)
        let recording = recording(of: clip, in: project)
        project.addEffect(clip, kind: .lowOctave, span: ClipSpan(recordingID: recording, inSample: 24_000, outSample: 48_000))
        let shown = try #require(project.clip(clip))
        // Its syllables are heard 50 ms earlier than recorded.
        let heard = project.heardSample(of: shown, voices: .none, shift: { _, _ in -2_400 })
        #expect(heard(recording, 24_000) == 21_600)
        #expect(project.effectStretches(of: shown, voices: .none, heardSample: heard).first?.seconds == 2.45..<2.95)
        // A sample the clip does not play is heard nowhere.
        #expect(heard(recording, 96_000) == nil)
        #expect(heard(UUID(), 0) == nil)
    }
}

@Suite("The layers of each double")
struct DoubleLayersTests {
    @Test func thickIsTwoCopiesOutToTheSidesAndEveryOtherDoubleOneInTheMiddle() {
        #expect(DoubleLayers.plan(for: .thick) == [
            DoubleLayers.Layer(semitones: 0, cents: -9, formantScale: 1, delayMs: 12, side: .left),
            DoubleLayers.Layer(semitones: 0, cents: 9, formantScale: 1, delayMs: 19, side: .right),
        ])
        #expect(DoubleLayers.plan(for: .lowFourth) == [DoubleLayers.Layer(semitones: -5)])
        #expect(DoubleLayers.plan(for: .lowOctave) == [DoubleLayers.Layer(semitones: -12)])
        #expect(DoubleLayers.plan(for: .high) == [DoubleLayers.Layer(semitones: 12)])
        #expect(DoubleLayers.plan(for: .big) == [DoubleLayers.Layer(formantScale: 0.88, delayMs: 15)])
        #expect(DoubleLayers.plan(for: .small) == [DoubleLayers.Layer(formantScale: 1.12, delayMs: 15)])
    }

    @Test func aLayerSaysItsPitchAndItsDelayAsTheMakerOfTheSoundNeedsThem() {
        let left = DoubleLayers.plan(for: .thick)[0]
        #expect(left.pitchSemitones == -0.09)
        #expect(left.delaySamples == 576)
        #expect(DoubleLayers.plan(for: .lowFourth)[0].pitchSemitones == -5)
    }

    @Test func aKindThatIsNoDoubleHasNoLayers() {
        for kind in ClipEffect.Kind.allCases where !kind.isDouble {
            #expect(DoubleLayers.plan(for: kind).isEmpty)
        }
    }
}

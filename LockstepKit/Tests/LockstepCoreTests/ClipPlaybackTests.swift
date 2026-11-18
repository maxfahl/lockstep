import Foundation
import Testing
@testable import LockstepCore

/// What is heard of the clips from a place in the song on, worked out with numbers alone.
@Suite("Clip playback plan")
struct ClipPlaybackTests {
    /// A ten-second song with one track holding these clips.
    private func project(_ recordings: [Recording], _ clips: [Clip]) -> Project {
        Project(songLengthSamples: 480_000, tracks: [Track(name: "Track 1", clips: clips)], recordings: recordings)
    }

    /// A clip that plays one stretch of a recording.
    private func clip(_ recording: Recording, _ samples: Range<Int>, offset: Int = 0, muted: Bool = false) -> Clip {
        Clip(
            segments: [Segment(
                recordingID: recording.id,
                inSample: samples.lowerBound,
                outSample: samples.upperBound,
                offsetSamples: offset
            )],
            muted: muted
        )
    }

    // MARK: Before, across and after the play position

    @Test func aSegmentAfterThePlayPositionStartsAfterAWait() {
        // The recording began 2 s into the song. The clip plays its samples 1,000 to 9,000.
        let recording = Recording(lengthSamples: 48_000, rawStart: 2)
        let project = project([recording], [clip(recording, 1_000..<9_000)])

        // Played from 1 s: the clip starts at sample 97,000 of the song, 49,000 samples later.
        #expect(project.clipPlaybackPlan(from: 48_000, voices: .none) == [
            ClipPiece(recordingID: recording.id, offset: 1_000, startDelay: 49_000, length: 8_000),
        ])
        // Played from the very start of the song.
        #expect(project.clipPlaybackPlan(from: 0, voices: .none) == [
            ClipPiece(recordingID: recording.id, offset: 1_000, startDelay: 97_000, length: 8_000),
        ])
    }

    @Test func aSegmentThePlayPositionIsInsideStartsFromTheRightSample() {
        let recording = Recording(lengthSamples: 48_000, rawStart: 2)
        let project = project([recording], [clip(recording, 1_000..<9_000)])

        // The clip covers samples 97,000 to 105,000 of the song. Played from 100,000, it is 3,000 samples in.
        #expect(project.clipPlaybackPlan(from: 100_000, voices: .none) == [
            ClipPiece(recordingID: recording.id, offset: 4_000, startDelay: 0, length: 5_000, segmentBefore: 3_000),
        ])
        // Exactly on its first sample, all of it plays at once.
        #expect(project.clipPlaybackPlan(from: 97_000, voices: .none) == [
            ClipPiece(recordingID: recording.id, offset: 1_000, startDelay: 0, length: 8_000),
        ])
        // On its last sample, that one sample plays.
        #expect(project.clipPlaybackPlan(from: 104_999, voices: .none) == [
            ClipPiece(recordingID: recording.id, offset: 8_999, startDelay: 0, length: 1, segmentBefore: 7_999),
        ])
    }

    @Test func aSegmentBeforeThePlayPositionIsLeftOut() {
        let recording = Recording(lengthSamples: 48_000, rawStart: 2)
        let project = project([recording], [clip(recording, 1_000..<9_000)])

        // The sample after its last one, and a place well after it.
        #expect(project.clipPlaybackPlan(from: 105_000, voices: .none).isEmpty)
        #expect(project.clipPlaybackPlan(from: 300_000, voices: .none).isEmpty)
    }

    // MARK: What is heard

    @Test func aMutedClipAndAMutedTrackAreLeftOut() {
        let recording = Recording(lengthSamples: 48_000, rawStart: 2)
        var project = project([recording], [
            clip(recording, 0..<4_000, muted: true),
            clip(recording, 10_000..<14_000),
        ])
        #expect(project.clipPlaybackPlan(from: 0, voices: .none) == [
            ClipPiece(recordingID: recording.id, offset: 10_000, startDelay: 106_000, length: 4_000),
        ])

        project.tracks[0].muted = true
        #expect(project.clipPlaybackPlan(from: 0, voices: .none).isEmpty)
    }

    @Test func ofTakesOnTopOfEachOtherOnlyTheActiveOnePlays() {
        // Two takes of the same line, on top of each other. The second is not the active take, so it waits.
        let first = Recording(lengthSamples: 48_000, rawStart: 2)
        let second = Recording(lengthSamples: 48_000, rawStart: 2.1)
        let shown = clip(first, 0..<48_000)
        var other = clip(second, 0..<48_000)
        other.isActiveTake = false
        other.line = shown.line
        var project = project([first, second], [shown, other])

        #expect(project.clipPlaybackPlan(from: 96_000, voices: .none) == [
            ClipPiece(recordingID: first.id, offset: 0, startDelay: 0, length: 48_000),
        ])

        // The other take is chosen, and it is the one that plays.
        project.setActiveTake(other.id)
        #expect(project.clipPlaybackPlan(from: 96_000, voices: .none) == [
            ClipPiece(recordingID: second.id, offset: 0, startDelay: 4_800, length: 48_000),
        ])
    }

    @Test func clipsThatOverlapTooLittleToBeTakesAllPlay() {
        // The end of one line runs 0.1 s into the start of the next. They are two lines, and both are heard.
        let first = Recording(lengthSamples: 48_000, rawStart: 2)
        let second = Recording(lengthSamples: 48_000, rawStart: 2.9)
        var project = project([first, second], [clip(first, 0..<48_000), clip(second, 0..<48_000)])
        project.normalizeTakes()

        #expect(project.clipPlaybackPlan(from: 96_000, voices: .none) == [
            ClipPiece(recordingID: first.id, offset: 0, startDelay: 0, length: 48_000),
            ClipPiece(recordingID: second.id, offset: 0, startDelay: 43_200, length: 48_000),
        ])
    }

    @Test func everySegmentOfAClipOnEveryTrackIsInTheAnswer() {
        let first = Recording(lengthSamples: 48_000, rawStart: 1)
        let second = Recording(lengthSamples: 48_000, rawStart: 4)
        // One clip with a piece cut out of its middle, and a clip on a second track.
        let cut = Clip(segments: [
            Segment(recordingID: first.id, inSample: 0, outSample: 10_000),
            Segment(recordingID: first.id, inSample: 20_000, outSample: 30_000),
        ])
        var project = project([first, second], [cut])
        project.tracks.append(Track(name: "Track 2", clips: [clip(second, 0..<48_000)]))

        #expect(project.clipPlaybackPlan(from: 0, voices: .none) == [
            ClipPiece(recordingID: first.id, offset: 0, startDelay: 48_000, length: 10_000),
            ClipPiece(recordingID: first.id, offset: 20_000, startDelay: 68_000, length: 10_000),
            ClipPiece(recordingID: second.id, offset: 0, startDelay: 192_000, length: 48_000),
        ])
    }

    // MARK: The position rule

    @Test func theDelayAndAMovedClipShiftWhereItPlays() {
        // Sample 0 was heard at 10 s, 0.25 s of that is delay, and the clip was moved 0.5 s later:
        // 10 - 0.25 + (24000 + 48000) / 48000 = 11.25 s, which is sample 540,000.
        let recording = Recording(lengthSamples: 480_000, rawStart: 10, delay: 0.25)
        let moved = clip(recording, 48_000..<144_000, offset: 24_000)
        var project = project([recording], [moved])
        project.songLengthSamples = 960_000

        #expect(project.clipPlaybackPlan(from: 0, voices: .none) == [
            ClipPiece(recordingID: recording.id, offset: 48_000, startDelay: 540_000, length: 96_000),
        ])
        #expect(recording.songSample(ofSample: 48_000, offsetSamples: 24_000) == 540_000)
        // The whole-sample place is the nearest sample to the place in seconds.
        #expect(Double(540_000) / 48_000 == project.start(of: moved.segments[0]))
    }

    @Test func partsThatTouchInTheRecordingTouchInTheSong() {
        // A recording that began between two samples of the song, split in two at its sample 7,001.
        let recording = Recording(lengthSamples: 48_000, rawStart: 1.000_013)
        let split = Clip(segments: [
            Segment(recordingID: recording.id, inSample: 0, outSample: 7_001),
            Segment(recordingID: recording.id, inSample: 7_001, outSample: 48_000),
        ])
        let pieces = project([recording], [split]).clipPlaybackPlan(from: 0, voices: .none)

        #expect(pieces.count == 2)
        // 1.000013 s is sample 48,000.6, so the recording starts on sample 48,001.
        #expect(pieces[0].startDelay == 48_001)
        #expect(pieces[0].startDelay + pieces[0].length == pieces[1].startDelay)
        #expect(pieces[0].offset + pieces[0].length == pieces[1].offset)
    }

    // MARK: Edges

    @Test func aSegmentIsKeptInsideTheSong() {
        // One recording began half a second before the song did, one runs past its end.
        let early = Recording(lengthSamples: 48_000, rawStart: -0.5)
        let late = Recording(lengthSamples: 48_000, rawStart: 9.5)
        let project = project([early, late], [clip(early, 0..<48_000), clip(late, 0..<48_000)])

        #expect(project.clipPlaybackPlan(from: 0, voices: .none) == [
            ClipPiece(recordingID: early.id, offset: 24_000, startDelay: 0, length: 24_000, segmentBefore: 24_000),
            ClipPiece(recordingID: late.id, offset: 0, startDelay: 456_000, length: 24_000, segmentAfter: 24_000),
        ])
        // An end other than the song's own can be given.
        #expect(project.clipPlaybackPlan(from: 0, to: 12_000, voices: .none) == [
            ClipPiece(recordingID: early.id, offset: 24_000, startDelay: 0, length: 12_000, segmentBefore: 24_000, segmentAfter: 12_000),
        ])
        // Nothing plays from the end of the song or after it.
        #expect(project.clipPlaybackPlan(from: 480_000, voices: .none).isEmpty)
        #expect(project.clipPlaybackPlan(from: 500_000, voices: .none).isEmpty)
    }

    @Test func aSegmentIsKeptInsideItsRecording() {
        // A segment that asks for more than the recording holds, at both ends.
        let recording = Recording(lengthSamples: 10_000, rawStart: 1)
        let project = project([recording], [clip(recording, -500..<12_000)])

        #expect(project.clipPlaybackPlan(from: 0, voices: .none) == [
            ClipPiece(recordingID: recording.id, offset: 0, startDelay: 48_000, length: 10_000),
        ])
    }

    @Test func aClipWithNothingToPlayIsLeftOut() {
        let recording = Recording(lengthSamples: 10_000, rawStart: 1)
        let gone = Recording(lengthSamples: 10_000, rawStart: 1)
        let project = project([recording], [
            // Its recording is not in the project.
            clip(gone, 0..<10_000),
            // Its end is before its start.
            Clip(segments: [Segment(recordingID: recording.id, inSample: 5_000, outSample: 4_000)]),
            // No segments at all.
            Clip(),
        ])

        #expect(project.clipPlaybackPlan(from: 0, voices: .none).isEmpty)
    }
}

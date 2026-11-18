import Foundation
import Testing
@testable import LockstepCore

/// The dry sound of one clip: what a finished sound is made from.
///
/// The song, the recording and the made-up voice are those of `ClipExporterTests`: the recording's sample `n` is
/// heard on sample `12,000 + n` of the song.
@Suite("Clip dry sound")
struct ClipDryTests {
    typealias Dry = ClipExporterTests

    @Test("The dry sound is the clip alone as the offline mix has it, from its first sound to its last")
    func clipAlone() throws {
        let recording = Dry.recording()
        let sounds = [recording.id: Dry.voice(96_000)]
        var clip = Clip(segments: [
            Segment(recordingID: recording.id, inSample: 1_000, outSample: 11_000),
            Segment(recordingID: recording.id, inSample: 21_000, outSample: 31_000, gainDb: -2),
        ])
        clip.normalizeGainDb = 1.5
        // A neighbour that overlaps the clip's end is not in its dry sound.
        let project = Dry.project(recording, [clip, Dry.clip(recording, 30_000..<50_000)])
        let peaks = Dry.peaks(of: sounds)

        let dry = try #require(ClipDry.render(clip, in: project, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none))

        #expect(dry.firstSample == 13_000)
        #expect(dry.samples.count == 30_000)
        let alone = Dry.project(recording, [clip])
        #expect(dry.samples == OfflineMix.render(alone, from: 13_000, to: 43_000, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none))
        #expect(dry.samples[10_000..<20_000].allSatisfy { $0 == 0 })
    }

    @Test("The clip's own volume is left out, and what Normalize set is held back by the safe limit without it")
    func clipVolumeIsLeftOut() throws {
        let recording = Dry.recording()
        let sounds = [recording.id: Dry.voice(96_000)]
        let peaks = Dry.peaks(of: sounds)
        // The voice peaks near 0.5 (-6 dBFS), so Normalize's 4 dB fit under the safe limit, and 10 do not.
        var plain = Dry.clip(recording, 1_000..<41_000)
        plain.normalizeGainDb = 4
        var turnedUp = plain
        turnedUp.gainDb = 12
        var turnedDown = plain
        turnedDown.gainDb = -9

        let dry = try #require(ClipDry.render(
            plain, in: Dry.project(recording, [plain]), recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
        ))

        for clip in [turnedUp, turnedDown] {
            let same = ClipDry.render(clip, in: Dry.project(recording, [clip]), recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none)
            #expect(same == dry)
        }
        // With its own volume at 0 the clip is exported as its dry sound.
        let export = try #require(ClipExporter.export(
            plain.id, in: Dry.project(recording, [plain]), recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
        ))
        #expect(Array(export.samples[export.paddingSamples...].prefix(40_000)) == dry.samples)
        #expect(!plain.appliedGain(peaks: peaks).isHeldBack)

        var loud = plain
        loud.normalizeGainDb = 10
        loud.gainDb = -9
        let held = try #require(ClipDry.render(
            loud, in: Dry.project(recording, [loud]), recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
        ))
        // With the clip's own -9 dB counted, nothing would be held back. The dry sound leaves them out, so the
        // limit holds Normalize's 10 dB back to where the highest sample is at -1 dBFS.
        #expect(!loud.appliedGain(peaks: peaks).isHeldBack)
        let highest = held.samples.reduce(0) { max($0, abs($1)) }
        #expect(abs(Double(highest) - pow(10, Clip.safeLimitDb / 20)) < 1e-5)
    }

    @Test("The track's volume and every mute are left out too, and a take that waits is made all the same")
    func heardOrNot() throws {
        let recording = Dry.recording()
        let sounds = [recording.id: Dry.voice(96_000)]
        let clip = Dry.clip(recording, 1_000..<41_000)
        let expected = try #require(ClipDry.render(
            clip, in: Dry.project(recording, [clip]), recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none
        ))
        var hidden = clip
        hidden.muted = true
        hidden.isActiveTake = false
        var project = Dry.project(recording, [hidden])
        project.tracks[0].muted = true
        project.tracks[0].gainDb = -7

        #expect(ClipDry.render(hidden, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none) == expected)
    }

    @Test("A tightened sound stands in for its part, and a line that slid out at the start makes the first sound earlier")
    func tightenedSound() throws {
        let recording = Dry.recording()
        var clip = Dry.clip(recording, 1_000..<41_000)
        clip.tighten = .lines
        let tightID = UUID()
        let tight = Dry.voice(40_150).map { -$0 }
        var tightened = TightenedSounds()
        tightened.set(tightID, for: clip.segments[0], at: 0, of: clip.id, lead: 100, tail: 50, madeFrom: .recordings)

        let dry = try #require(ClipDry.render(
            clip, in: Dry.project(recording, [clip]), recordings: [recording.id: Dry.voice(96_000), tightID: tight],
            peaks: Clip.unknownPeaks, edgeFadeMs: 0, tightened: tightened, voices: .none
        ))

        #expect(dry.firstSample == 12_900)
        #expect(dry.samples == tight)
    }

    @Test("A clip that plays nothing has no dry sound")
    func nothingToPlay() {
        let recording = Dry.recording()
        let sounds = [recording.id: Dry.voice(96_000)]
        let empty = Clip(segments: [])
        let unknown = Clip(segments: [Segment(recordingID: UUID(), inSample: 0, outSample: 1_000)])
        let project = Dry.project(recording, [empty, unknown])

        #expect(ClipDry.render(empty, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none) == nil)
        #expect(ClipDry.render(unknown, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none) == nil)
    }
}

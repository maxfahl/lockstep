import Foundation
import Testing
@testable import LockstepCore

/// The sound of the clips as one row of samples, compared sample for sample.
///
/// The song of these tests is two seconds long. The recording began a quarter of a second into it, so sample `n`
/// of the recording is heard on sample `12,000 + n` of the song.
@Suite("Offline mix")
struct OfflineMixTests {
    static let songSamples = 96_000
    /// The sample of the song on which the recording's first sample is heard.
    static let recordingPlace = 12_000
    /// 5 ms, the fade Lockstep starts with, in samples.
    static let fade = 240

    /// Made-up voice that is the same on every run: every sample between -0.5 and 0.5, and no two stretches alike,
    /// so a piece that lands on the wrong sample is noticed.
    static func voice(_ count: Int) -> [Float] {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) - 0.5
        }
    }

    static func recording() -> Recording {
        Recording(lengthSamples: 48_000, rawStart: Double(recordingPlace) / 48_000)
    }

    /// A project with one track holding these clips.
    static func project(_ recording: Recording, _ clips: [Clip]) -> Project {
        Project(songLengthSamples: songSamples, tracks: [Track(name: "Track 1", clips: clips)], recordings: [recording])
    }

    /// A clip that plays one stretch of the recording.
    static func clip(_ recording: Recording, _ samples: Range<Int>, gainDb: Double = 0) -> Clip {
        Clip(
            segments: [Segment(recordingID: recording.id, inSample: samples.lowerBound, outSample: samples.upperBound)],
            gainDb: gainDb
        )
    }

    /// The row of the whole song.
    static func row(
        _ project: Project,
        _ sounds: [UUID: [Float]],
        fadeMs: Double,
        peaks: RecordingPeak = Clip.unknownPeaks
    ) -> [Float] {
        OfflineMix.render(project, recordings: sounds, peaks: peaks, edgeFadeMs: fadeMs, voices: .none)
    }

    /// The highest sample of a stretch of these sounds, as the app measures it.
    static func peaks(of sounds: [UUID: [Float]]) -> RecordingPeak {
        { id, samples in
            guard let sound = sounds[id] else { return 0 }
            let inside = max(samples.lowerBound, 0)..<min(samples.upperBound, sound.count)
            return inside.isEmpty ? 0 : sound[inside].reduce(0) { max($0, abs($1)) }
        }
    }

    // MARK: The row itself

    @Test("A clip is in the row at its place, and the rest is silence")
    func clipAtItsPlace() {
        let recording = Self.recording()
        let sound = Self.voice(48_000)
        let row = Self.row(Self.project(recording, [Self.clip(recording, 1_000..<41_000)]), [recording.id: sound], fadeMs: 0)

        #expect(row.count == Self.songSamples)
        #expect(row[..<13_000].allSatisfy { $0 == 0 })
        #expect(Array(row[13_000..<53_000]) == Array(sound[1_000..<41_000]))
        #expect(row[53_000...].allSatisfy { $0 == 0 })
    }

    @Test("Clips on top of each other are added, and a muted clip is silent")
    func clipsAddUp() {
        let recording = Self.recording()
        let sound = Self.voice(48_000)
        var muted = Self.clip(recording, 0..<48_000)
        muted.muted = true
        let project = Self.project(recording, [
            Self.clip(recording, 1_000..<3_000),
            // Too short an overlap to matter here: the row is made from the plan, which trusts the take flags.
            Self.clip(recording, 2_000..<4_000),
            muted,
        ])
        let row = Self.row(project, [recording.id: sound], fadeMs: 0)

        #expect(row[13_500] == sound[1_500])
        #expect(row[14_500] == sound[2_500] + sound[2_500])
        #expect(row[15_500] == sound[3_500])
        #expect(row[20_000] == 0)
    }

    // MARK: Split, cut and join sound like the clip before

    @Test("With no fade, a split clip gives the very samples of the clip before the split", arguments: [0.0, -4.0, 3.0])
    func splitIsNotHeard(gainDb: Double) throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(48_000)]
        let clip = Self.clip(recording, 1_000..<41_000, gainDb: gainDb)
        let whole = Self.project(recording, [clip])
        var split = whole
        // Sample 30,000 of the song, in the middle of the clip.
        let done = split.splitClip(clip.id, at: 30_000.0 / 48_000, voices: .none)
        #expect(done != nil)
        #expect(split.tracks[0].clips.count == 2)

        let before = Self.row(whole, sounds, fadeMs: 0)
        let after = Self.row(split, sounds, fadeMs: 0)
        #expect(before == after)
        // There is sound on both sides of the cut, so the comparison means something.
        #expect(before[29_999] != 0)
        #expect(before[30_000] != 0)
    }

    @Test("With the 5 ms fade, a split changes only the 5 ms on each side of the cut, and only downwards")
    func splitFadesOnlyAtTheCut() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(48_000)]
        let clip = Self.clip(recording, 1_000..<41_000)
        let whole = Self.project(recording, [clip])
        var split = whole
        let done = split.splitClip(clip.id, at: 30_000.0 / 48_000, voices: .none)
        #expect(done != nil)

        let before = Self.row(whole, sounds, fadeMs: 5)
        let after = Self.row(split, sounds, fadeMs: 5)
        let aroundTheCut = (30_000 - Self.fade)..<(30_000 + Self.fade)
        #expect(before.indices.allSatisfy { aroundTheCut.contains($0) || before[$0] == after[$0] })
        #expect(aroundTheCut.allSatisfy { abs(after[$0]) <= abs(before[$0]) })
        // The last sample before the cut and the first after it are half a step from silence.
        let step = 1 / Float(Self.fade)
        #expect(abs(after[29_999] - before[29_999] * 0.5 * step) < 1e-7)
        #expect(abs(after[30_000] - before[30_000] * 0.5 * step) < 1e-7)
    }

    @Test("Split and joined again, the clip gives the very samples it gave before, fades included")
    func splitThenJoinIsNotHeard() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(48_000)]
        let clip = Self.clip(recording, 1_000..<41_000, gainDb: -2)
        let whole = Self.project(recording, [clip])
        var changed = whole
        let made = changed.splitClip(clip.id, at: 30_000.0 / 48_000, voices: .none)
        let pieces = try #require(made)
        let done = changed.joinClips([pieces.first, pieces.second], voices: .none)
        #expect(done != nil)
        #expect(changed.tracks[0].clips.count == 1)

        #expect(Self.row(changed, sounds, fadeMs: 5) == Self.row(whole, sounds, fadeMs: 5))
    }

    @Test("A stretch that is cut out is silent, and every sample outside it is as it was")
    func cutLeavesTheRestAlone() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(48_000)]
        let whole = Self.project(recording, [Self.clip(recording, 1_000..<41_000)])
        var cut = whole
        // From sample 24,000 to sample 36,000 of the song.
        let done = cut.cut(range: 0.5..<0.75, onTrack: whole.tracks[0].id, voices: .none)
        #expect(done != nil)
        #expect(cut.tracks[0].clips.count == 2)

        let before = Self.row(whole, sounds, fadeMs: 0)
        let after = Self.row(cut, sounds, fadeMs: 0)
        #expect(after[24_000..<36_000].allSatisfy { $0 == 0 })
        #expect(Array(after[..<24_000]) == Array(before[..<24_000]))
        #expect(Array(after[36_000...]) == Array(before[36_000...]))
    }

    @Test("Three clips joined into one with two gaps give the very samples the three gave, and silence in the gaps")
    func joinedClipWithGaps() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(48_000)]
        // Each at a volume of its own, which the joined clip has to keep for each part.
        let parts = [
            Self.clip(recording, 1_000..<9_000, gainDb: 2),
            Self.clip(recording, 15_000..<22_000, gainDb: -6),
            Self.clip(recording, 30_000..<41_000),
        ]
        let apart = Self.project(recording, parts)
        var joined = apart
        let done = joined.joinClips(Set(parts.map(\.id)), voices: .none)
        #expect(done != nil)
        #expect(joined.tracks[0].clips.count == 1)
        #expect(joined.tracks[0].clips[0].segments.count == 3)

        let before = Self.row(apart, sounds, fadeMs: 5)
        let after = Self.row(joined, sounds, fadeMs: 5)
        #expect(before == after)
        // The gaps: after the first part (ends on sample 21,000 of the song) and after the second (ends on 34,000).
        #expect(after[21_000..<27_000].allSatisfy { $0 == 0 })
        #expect(after[34_000..<42_000].allSatisfy { $0 == 0 })
        // Every part fades in and out by itself, also inside the joined clip.
        #expect(abs(after[27_000]) < abs(sounds[recording.id]![15_000]) / 100)
    }

    @Test("A clip the safe limit holds back sounds the same after a split, to within a millionth")
    func heldBackClipKeepsItsLoudness() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(48_000)]
        let peaks = Self.peaks(of: sounds)
        // The voice peaks near -6 dBFS, so 12 dB more would distort and the safe limit holds the clip back.
        let clip = Self.clip(recording, 1_000..<41_000, gainDb: 12)
        let whole = Self.project(recording, [clip])
        #expect(clip.appliedGain(peaks: peaks).isHeldBack)
        var split = whole
        let done = split.splitClip(clip.id, at: 30_000.0 / 48_000, peaks: peaks, voices: .none)
        #expect(done != nil)

        let before = Self.row(whole, sounds, fadeMs: 0, peaks: peaks)
        let after = Self.row(split, sounds, fadeMs: 0, peaks: peaks)
        #expect(before.indices.allSatisfy { abs(before[$0] - after[$0]) < 1e-6 })
        #expect(before.contains { abs($0) > 0.5 })
    }

    // MARK: A stretch of the song

    @Test(
        "A stretch of the song gives exactly that stretch of the whole song's row, also when it starts or ends inside a fade",
        arguments: [0..<96_000, 13_100..<20_900, 25_000..<60_000, 27_050..<27_060, 40_000..<41_000]
    )
    func stretchOfTheRow(stretch: Range<Int>) throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(48_000)]
        let parts = [
            Self.clip(recording, 1_000..<9_000, gainDb: 2),
            Self.clip(recording, 15_000..<22_000, gainDb: -6),
            Self.clip(recording, 30_000..<41_000),
        ]
        var project = Self.project(recording, parts)
        let done = project.joinClips(Set(parts.map(\.id)), voices: .none)
        #expect(done != nil)

        let whole = Self.row(project, sounds, fadeMs: 5)
        let part = OfflineMix.render(
            project,
            from: stretch.lowerBound,
            to: stretch.upperBound,
            recordings: sounds,
            peaks: Clip.unknownPeaks,
            edgeFadeMs: 5, voices: .none
        )
        #expect(part == Array(whole[stretch]))
    }

    @Test("A recording whose sound is missing, or shorter than the project says, is silent where it is missing")
    func missingSound() {
        let recording = Self.recording()
        let project = Self.project(recording, [Self.clip(recording, 1_000..<41_000)])

        #expect(Self.row(project, [:], fadeMs: 5).allSatisfy { $0 == 0 })
        // Only the first 2,000 samples of the recording are there.
        let short = Self.voice(2_000)
        let row = Self.row(project, [recording.id: short], fadeMs: 0)
        #expect(Array(row[13_000..<14_000]) == Array(short[1_000..<2_000]))
        #expect(row[14_000...].allSatisfy { $0 == 0 })
    }
}

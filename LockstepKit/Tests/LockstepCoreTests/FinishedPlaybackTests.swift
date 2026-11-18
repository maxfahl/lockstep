import Foundation
import Testing
@testable import LockstepCore

/// A clip that is played from its finished sound: what the plan says of it, and what the row in stereo holds.
///
/// The song is ten seconds long. The recording began 2 s into it, so its sample `n` is heard on sample
/// `96,000 + n` of the song. The clip of most tests plays its samples 1,000 to 9,000, which is samples 97,000
/// to 105,000 of the song, and its finished sound rings 2,000 samples longer.
@Suite("Finished sounds in the plan and in the row")
struct FinishedPlaybackTests {
    static let songSamples = 480_000
    static let clipStart = 97_000
    static let dry = 8_000
    static let tail = 2_000

    static func recording() -> Recording {
        Recording(lengthSamples: 48_000, rawStart: 2)
    }

    static func clip(_ recording: Recording, _ samples: Range<Int> = 1_000..<9_000) -> Clip {
        Clip(segments: [Segment(recordingID: recording.id, inSample: samples.lowerBound, outSample: samples.upperBound)])
    }

    static func project(_ recording: Recording, _ clips: [Clip]) -> Project {
        Project(songLengthSamples: songSamples, tracks: [Track(name: "Track 1", clips: clips)], recordings: [recording])
    }

    /// The lookup that says `clip` has a finished sound as long as the clip plus the tail, and that sound's id.
    static func lookup(for clip: Clip, dry: Int = dry, tail: Int = tail) -> (sounds: FinishedSounds, id: UUID) {
        let id = UUID()
        var sounds = FinishedSounds()
        sounds.set(FinishedSounds.Sound(id: id, drySamples: dry, tailSamples: tail, pieces: clip.segments, madeFrom: .recordings), for: clip.id)
        return (sounds, id)
    }

    /// A recording whose samples say where they are.
    static func voice(_ count: Int) -> [Float] {
        (0..<count).map { Float($0 + 1) / 131_072 }
    }

    /// A stand-in for a finished sound: left and right can be told from each other and from the voice.
    static func finished(_ count: Int) -> StereoSound {
        StereoSound(
            left: (0..<count).map { Float($0 + 1) / 262_144 },
            right: (0..<count).map { -Float($0 + 1) / 524_288 }
        )
    }

    // MARK: The plan

    @Test("Without finished sounds the plan is what it was, and no piece is a finished one")
    func planWithoutFinishedSounds() {
        let recording = Self.recording()
        let clip = Self.clip(recording)
        let project = Self.project(recording, [clip])
        let before = [ClipPiece(recordingID: recording.id, offset: 1_000, startDelay: Self.clipStart, length: Self.dry)]

        #expect(project.clipPlaybackPlan(from: 0, voices: .none) == before)
        #expect(project.clipPlaybackPlan(from: 0, finished: .none, voices: .none) == before)
        #expect(before[0].isFinished == false)
        // A finished sound of some other clip changes nothing for this one.
        let other = Self.lookup(for: Self.clip(recording))
        #expect(project.clipPlaybackPlan(from: 0, finished: other.sounds, voices: .none) == before)
    }

    @Test("A clip with a finished sound is one piece from the sound's first sample, as long as the clip plus the tail")
    func oneFinishedPiece() {
        let recording = Self.recording()
        let clip = Self.clip(recording)
        let project = Self.project(recording, [clip])
        let finished = Self.lookup(for: clip)

        #expect(project.clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none) == [
            ClipPiece(
                recordingID: finished.id, offset: 0, startDelay: Self.clipStart, length: Self.dry + Self.tail,
                isFinished: true
            ),
        ])
    }

    @Test("A play position inside the finished sound starts inside it, also inside its tail, and after it nothing plays")
    func fromTheMiddle() {
        let recording = Self.recording()
        let clip = Self.clip(recording)
        let project = Self.project(recording, [clip])
        let finished = Self.lookup(for: clip)

        // 3,000 samples into the clip.
        #expect(project.clipPlaybackPlan(from: 100_000, finished: finished.sounds, voices: .none) == [
            ClipPiece(
                recordingID: finished.id, offset: 3_000, startDelay: 0, length: 7_000, segmentBefore: 3_000,
                isFinished: true
            ),
        ])
        // 500 samples into the tail, where the clip itself has ended.
        #expect(project.clipPlaybackPlan(from: 105_500, finished: finished.sounds, voices: .none) == [
            ClipPiece(
                recordingID: finished.id, offset: 8_500, startDelay: 0, length: 1_500, segmentBefore: 8_500,
                isFinished: true
            ),
        ])
        #expect(project.clipPlaybackPlan(from: 107_000, finished: finished.sounds, voices: .none).isEmpty)
        // A stretch that ends inside the sound cuts the piece there.
        #expect(project.clipPlaybackPlan(from: 96_000, to: 99_000, finished: finished.sounds, voices: .none) == [
            ClipPiece(
                recordingID: finished.id, offset: 0, startDelay: 1_000, length: 2_000, segmentAfter: 8_000,
                isFinished: true
            ),
        ])
    }

    @Test("A finished piece is as loud as its track's volume alone: the clip's volumes are already in the sound")
    func trackVolumeOnly() {
        let recording = Self.recording()
        var clip = Self.clip(recording)
        clip.gainDb = 6
        clip.normalizeGainDb = 3
        clip.segments[0].gainDb = -2
        var project = Self.project(recording, [clip])
        let finished = Self.lookup(for: clip)

        #expect(project.clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none).map(\.gainDb) == [0])
        project.tracks[0].gainDb = -4.5
        #expect(project.clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none).map(\.gainDb) == [-4.5])
        // Dry, the same clip is as loud as its own volumes and the track's together.
        #expect(project.clipPlaybackPlan(from: 0, voices: .none).map(\.gainDb) == [6 + 3 - 2 - 4.5])
    }

    @Test("A muted clip, a clip on a muted track and a take that waits are silent, finished sound or not")
    func mutedClipsStaySilent() {
        let recording = Self.recording()
        var clip = Self.clip(recording)
        let finished = Self.lookup(for: clip)

        clip.muted = true
        #expect(Self.project(recording, [clip]).clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none).isEmpty)
        clip.muted = false
        var mutedTrack = Self.project(recording, [clip])
        mutedTrack.tracks[0].muted = true
        #expect(mutedTrack.clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none).isEmpty)
        clip.isActiveTake = false
        #expect(Self.project(recording, [clip]).clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none).isEmpty)
    }

    @Test("A moved clip keeps its finished sound at its new place, and a trimmed one is played from its segments again")
    func movedAndTrimmed() {
        let recording = Self.recording()
        let clip = Self.clip(recording)
        let finished = Self.lookup(for: clip)

        var moved = clip
        moved.segments[0].offsetSamples = 500
        #expect(Self.project(recording, [moved]).clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none) == [
            ClipPiece(
                recordingID: finished.id, offset: 0, startDelay: Self.clipStart + 500, length: Self.dry + Self.tail,
                isFinished: true
            ),
        ])
        var trimmed = clip
        trimmed.segments[0].inSample = 2_000
        #expect(Self.project(recording, [trimmed]).clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none) == [
            ClipPiece(recordingID: recording.id, offset: 2_000, startDelay: 98_000, length: 7_000),
        ])
    }

    @Test("A clip of several parts is one finished piece from its first sound, and its neighbours are played as before")
    func severalPartsAndNeighbours() {
        let recording = Self.recording()
        let joined = Clip(segments: [
            Segment(recordingID: recording.id, inSample: 4_000, outSample: 6_000, offsetSamples: 3_000),
            Segment(recordingID: recording.id, inSample: 1_000, outSample: 2_000),
        ])
        let neighbour = Self.clip(recording, 20_000..<21_000)
        let project = Self.project(recording, [joined, neighbour])
        // The first sound is the second part's: sample 97,000 of the song. The last is the first part's end, at
        // 105,000.
        let finished = Self.lookup(for: joined, dry: 8_000, tail: 100)

        #expect(project.clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none) == [
            ClipPiece(recordingID: finished.id, offset: 0, startDelay: 97_000, length: 8_100, isFinished: true),
            ClipPiece(recordingID: recording.id, offset: 20_000, startDelay: 116_000, length: 1_000),
        ])
    }

    @Test("Where a line slid out of the clip at its start, the finished sound starts where the tightened one does")
    func tightenedLead() {
        let recording = Self.recording()
        var clip = Self.clip(recording)
        clip.tighten = .lines
        let project = Self.project(recording, [clip])
        var tightened = TightenedSounds()
        tightened.set(UUID(), for: clip.segments[0], at: 0, of: clip.id, lead: 100, tail: 50, madeFrom: .recordings)
        // The dry sound is then 150 samples longer than the clip.
        let finished = Self.lookup(for: clip, dry: Self.dry + 150)

        #expect(project.clipPlaybackPlan(from: 0, tightened: tightened, finished: finished.sounds, voices: .none) == [
            ClipPiece(
                recordingID: finished.id, offset: 0, startDelay: Self.clipStart - 100,
                length: Self.dry + 150 + Self.tail, isFinished: true
            ),
        ])
    }

    @Test("Only finished sounds there are samples for are kept in a lookup")
    func lookupWithSamples() {
        let recording = Self.recording()
        let one = Self.clip(recording)
        let two = Self.clip(recording, 20_000..<21_000)
        var sounds = Self.lookup(for: one).sounds
        let second = FinishedSounds.Sound(id: UUID(), drySamples: 1_000, tailSamples: 0, pieces: two.segments, madeFrom: .recordings)
        sounds.set(second, for: two.id)

        let kept = sounds.having([second.id: Self.finished(1_000)])

        #expect(kept.sounds == [two.id: second])
        #expect(sounds.having([:]) == .none)
    }

    // MARK: The row in stereo

    @Test("A finished piece adds its left to the left and its right to the right, without fades, and any other piece adds the same samples to both")
    func stereoRow() {
        let recording = Self.recording()
        let clip = Self.clip(recording)
        let neighbour = Self.clip(recording, 20_000..<21_000)
        var project = Self.project(recording, [clip, neighbour])
        project.tracks[0].gainDb = -6
        let finished = Self.lookup(for: clip)
        let sounds = [recording.id: Self.voice(48_000)]
        let made = Self.finished(Self.dry + Self.tail)
        let plan = project.clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none)

        let row = OfflineMix.renderStereo(
            plan, recordings: sounds, finished: [finished.id: made], lengthSamples: Self.songSamples, fadeSamples: 240
        )

        #expect(row.left.count == Self.songSamples)
        #expect(row.right.count == Self.songSamples)
        let gain = Float(pow(10, -6.0 / 20))
        let heard = Self.clipStart..<(Self.clipStart + Self.dry + Self.tail)
        // The very first and the very last sample are at full level: the finished sound has its own edges.
        #expect(Array(row.left[heard]) == made.left.map { $0 * gain })
        #expect(Array(row.right[heard]) == made.right.map { $0 * gain })
        // The neighbour, which has no finished sound, is the mono row on both sides, fades and all.
        let mono = OfflineMix.render(
            project.clipPlaybackPlan(from: 0, voices: .none), recordings: sounds, lengthSamples: Self.songSamples, fadeSamples: 240
        )
        #expect(Array(row.left[116_000..<117_000]) == Array(mono[116_000..<117_000]))
        #expect(Array(row.right[116_000..<117_000]) == Array(mono[116_000..<117_000]))
        #expect(mono[116_000] != 0 && abs(mono[116_000]) < abs(sounds[recording.id]![20_000] * gain) / 100)
        // Everything else is silence.
        let silent = row.left.indices.filter { !heard.contains($0) && !(116_000..<117_000).contains($0) }
        #expect(silent.allSatisfy { row.left[$0] == 0 && row.right[$0] == 0 })
    }

    @Test("The tail of a finished sound lies over the clip that follows and is added to it")
    func tailOverTheNextClip() {
        let recording = Self.recording()
        let clip = Self.clip(recording)
        // Starts where the first clip ends, right under its tail.
        let next = Self.clip(recording, 9_000..<12_000)
        let project = Self.project(recording, [clip, next])
        let finished = Self.lookup(for: clip)
        let voice = Self.voice(48_000)
        let made = Self.finished(Self.dry + Self.tail)

        let row = OfflineMix.renderStereo(
            project.clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none),
            recordings: [recording.id: voice], finished: [finished.id: made],
            lengthSamples: Self.songSamples, fadeSamples: 0
        )

        for place in [0, 1, 1_999] {
            #expect(row.left[105_000 + place] == voice[9_000 + place] + made.left[Self.dry + place])
            #expect(row.right[105_000 + place] == voice[9_000 + place] + made.right[Self.dry + place])
        }
        #expect(row.left[107_000] == voice[11_000])
        #expect(row.right[107_000] == voice[11_000])
    }

    @Test("A finished piece is kept inside the samples there are for it, and is silent in a mono row")
    func keptInsideItsSound() {
        let recording = Self.recording()
        let clip = Self.clip(recording)
        let project = Self.project(recording, [clip])
        let finished = Self.lookup(for: clip)
        let plan = project.clipPlaybackPlan(from: 0, finished: finished.sounds, voices: .none)
        let sounds = [recording.id: Self.voice(48_000)]
        // Shorter than the lookup says, and its sides are not the same length.
        var short = Self.finished(6_000)
        short.right.removeLast(1_000)

        #expect(OfflineMix.playable(plan, recordings: sounds, finished: [finished.id: short], lengthSamples: Self.songSamples).map(\.length) == [5_000])
        // Without its samples the piece is not there, also when a recording happened to have its id.
        #expect(OfflineMix.playable(plan, recordings: sounds, finished: [:], lengthSamples: Self.songSamples).isEmpty)
        #expect(OfflineMix.playable(plan, recordings: [finished.id: Self.voice(10_000)], lengthSamples: Self.songSamples).isEmpty)
        let mono = OfflineMix.render(plan, recordings: [finished.id: Self.voice(10_000)], lengthSamples: Self.songSamples, fadeSamples: 0)
        #expect(mono.allSatisfy { $0 == 0 })
        // And a piece that is not finished never reads the finished sounds.
        let dryPlan = project.clipPlaybackPlan(from: 0, voices: .none)
        #expect(OfflineMix.playable(dryPlan, recordings: [:], finished: [recording.id: short], lengthSamples: Self.songSamples).isEmpty)
    }

    @Test("A plan without a finished piece gives the mono row on both sides")
    func stereoRowOfDryClips() {
        let recording = Self.recording()
        var clip = Self.clip(recording)
        clip.gainDb = -3
        let project = Self.project(recording, [clip])
        let sounds = [recording.id: Self.voice(48_000)]
        let plan = project.clipPlaybackPlan(from: 0, voices: .none)

        let row = OfflineMix.renderStereo(plan, recordings: sounds, finished: [:], lengthSamples: Self.songSamples, fadeSamples: 240)

        let mono = OfflineMix.render(plan, recordings: sounds, lengthSamples: Self.songSamples, fadeSamples: 240)
        #expect(row.left == mono)
        #expect(row.right == mono)
    }
}

import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// The clips beside the song, on the real engine without a sound device (see `PlaybackEngineTests`). Nothing can be
/// heard: the tests look at the samples the engine would have sent to the speakers.
///
/// The song of these tests is the one of `PlaybackEngineTests`: sample `n` is `(n + 1) / 65536` on the left and the
/// same, negative, on the right. The clips are mono, so they come out the same on both sides. Half the sum of the
/// two sides is therefore the clips alone, and half their difference is the song alone. The click is off.
///
/// Each test works out for itself what the clips should sound like over the whole song (a "row": one value for
/// every sample of the song, silence where no clip is), and compares what came out with that row.
@Suite("PlaybackEngine, clips")
struct PlaybackEngineClipTests {
    /// How long the song of these tests is, in samples: one second.
    static let songSamples = 48_000

    /// A recording whose samples say where they are: sample `n` is `(n + 1) / 131072`.
    static func voice(samples count: Int) -> [Float] {
        (0..<count).map { Float($0 + 1) / 131_072 }
    }

    /// A recording that is the same value all through, to tell it from `voice` when both sound at once.
    static func hum(samples count: Int) -> [Float] {
        [Float](repeating: 0.25, count: count)
    }

    /// A project with one track holding these clips.
    static func project(_ recordings: [Recording], _ clips: [Clip]) -> Project {
        Project(
            songLengthSamples: songSamples,
            tracks: [Track(name: "Track 1", clips: clips)],
            recordings: recordings
        )
    }

    /// A clip that plays one stretch of a recording.
    static func clip(_ recording: Recording, _ samples: Range<Int>, muted: Bool = false) -> Clip {
        Clip(
            segments: [Segment(recordingID: recording.id, inSample: samples.lowerBound, outSample: samples.upperBound)],
            muted: muted
        )
    }

    /// Silence as long as the song, to lay the expected sound into.
    static func silence() -> [Float] {
        [Float](repeating: 0, count: songSamples)
    }

    /// Adds samples `range` of a recording's sound to a row, with the first of them on sample `place` of the song.
    static func lay(_ sound: [Float], _ range: Range<Int>, at place: Int, into row: inout [Float]) {
        for sample in range where row.indices.contains(place + sample - range.lowerBound) {
            row[place + sample - range.lowerBound] += sound[sample]
        }
    }

    /// What the clips alone put out for each pair of samples that came out of the engine.
    static func clipValues(_ sound: (left: [Float], right: [Float])) -> [Float] {
        zip(sound.left, sound.right).map { ($0 + $1) / 2 }
    }

    /// True when the song came out without a break, counting on from sample `first`.
    static func songInStep(_ sound: (left: [Float], right: [Float]), from first: Int) -> Bool {
        sound.left.indices.allSatisfy {
            PlaybackEngineTests.songSample((sound.left[$0] - sound.right[$0]) / 2) == first + $0
        }
    }

    /// True when every pair of samples holds the song at its place and the clips as `row` says, from `first` on.
    static func inStep(_ sound: (left: [Float], right: [Float]), with row: [Float], from first: Int) -> Bool {
        let values = clipValues(sound)
        return songInStep(sound, from: first) && values.indices.allSatisfy { values[$0] == row[first + $0] }
    }

    /// Lets the song play on for `frames` samples, asked for no faster than a sound device asks for them: ten
    /// milliseconds of sound every ten milliseconds. Gives back what came out, like `renderOffline`.
    ///
    /// Use it for the sound right after the clips were changed while playing. The engine promises the change within
    /// 100 ms of the song, and it counts on those samples taking 100 ms to go by, as they do with a sound device:
    /// the player takes a new row in on a thread of its own, a moment after it was handed over. Asked for sound as
    /// fast as it can make it, the engine is 100 ms further on in a few millionths of a second, now and then before
    /// the player has the row, and the row is then heard late (still in step).
    static func renderAtDeviceSpeed(
        _ engine: PlaybackEngine,
        frames: Int
    ) async throws -> (left: [Float], right: [Float]) {
        let block = 480
        let clock = ContinuousClock()
        let start = clock.now
        var left: [Float] = []
        var right: [Float] = []
        while left.count < frames {
            // Each block is asked for when the sound before it would have been heard, or later, never sooner.
            try await clock.sleep(until: start + .seconds(Double(left.count) / Lockstep.sampleRate))
            let sound = try await engine.renderOffline(frames: min(block, frames - left.count))
            left.append(contentsOf: sound.left)
            right.append(contentsOf: sound.right)
        }
        return (left, right)
    }

    @Test("A clip is heard at its place in the song, also when playback starts in the middle of it")
    func clipPlaysAtItsPlace() async throws {
        // The recording began a quarter of a second into the song, and the clip plays samples 1,000 to 5,000 of it.
        let recording = Recording(lengthSamples: 6_000, rawStart: 0.25)
        let sound = Self.voice(samples: 6_000)
        var row = Self.silence()
        Self.lay(sound, 1_000..<5_000, at: 13_000, into: &row)

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClipsWithoutFades(of: Self.project([recording], [Self.clip(recording, 1_000..<5_000)]), recordings: [recording.id: sound])

        try await engine.play(from: 0)
        let fromTheStart = try await engine.renderOffline(frames: 20_000)
        #expect(Self.inStep(fromTheStart, with: row, from: 0))
        // The clip really is in there: its first and last sample, with silence on either side.
        let values = Self.clipValues(fromTheStart)
        #expect(values[12_999] == 0)
        #expect(values[13_000] == sound[1_000])
        #expect(values[16_999] == sound[4_999])
        #expect(values[17_000] == 0)
        await engine.stop()

        // From 0.3 s, which is inside the clip: the first sample out is the one that belongs there.
        try await engine.play(from: 0.3)
        let fromInside = try await engine.renderOffline(frames: 5_000)
        #expect(Self.inStep(fromInside, with: row, from: 14_400))
        #expect(Self.clipValues(fromInside)[0] == sound[2_400])
    }

    @Test("Jumping while playing moves the song and the clips together")
    func clipsSeekWithTheSong() async throws {
        let recording = Recording(lengthSamples: 40_000, rawStart: 0.1)
        let sound = Self.voice(samples: 40_000)
        var row = Self.silence()
        Self.lay(sound, 0..<40_000, at: 4_800, into: &row)

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClipsWithoutFades(of: Self.project([recording], [Self.clip(recording, 0..<40_000)]), recordings: [recording.id: sound])
        try await engine.play(from: 0)
        _ = try await engine.renderOffline(frames: 1_000)

        try await engine.seek(to: 0.5)
        #expect(Self.inStep(try await engine.renderOffline(frames: 3_000), with: row, from: 24_000))

        try await engine.seek(to: 0.05)
        #expect(Self.inStep(try await engine.renderOffline(frames: 5_000), with: row, from: 2_400))
    }

    @Test("Of takes on top of each other only the active one plays, and a muted clip and a muted track are silent")
    func takesAndMutedClips() async throws {
        // One line recorded twice, the next line running a little into its end, a muted clip, and a clip on a
        // muted track.
        let first = Recording(lengthSamples: 10_000, rawStart: 0.1)
        let second = Recording(lengthSamples: 10_000, rawStart: 0.15)
        let next = Recording(lengthSamples: 10_000, rawStart: 0.34)
        let muted = Recording(lengthSamples: 10_000, rawStart: 0.6)
        let onMutedTrack = Recording(lengthSamples: 10_000, rawStart: 0.3)
        let voice = Self.voice(samples: 10_000)
        let hum = Self.hum(samples: 10_000)
        let sounds = [first.id: voice, second.id: hum, next.id: voice, muted.id: voice, onMutedTrack.id: voice]

        let firstTake = Self.clip(first, 0..<10_000)
        var secondTake = Self.clip(second, 0..<10_000)
        secondTake.line = firstTake.line
        var project = Self.project(
            [first, second, next, muted, onMutedTrack],
            [
                firstTake,
                secondTake,
                Self.clip(next, 0..<10_000),
                Self.clip(muted, 0..<10_000, muted: true),
            ]
        )
        project.tracks.append(Track(name: "Track 2", muted: true, clips: [Self.clip(onMutedTrack, 0..<10_000)]))
        // What the store does after every edit: of the two takes, the one recorded last is the active one.
        project.normalizeTakes()

        // The second take is heard and the first waits. The next line overlaps the second take from 0.34 s to
        // 0.358 s, too little to be a take of it, so the two add up there. The other two are silent.
        var row = Self.silence()
        Self.lay(hum, 0..<10_000, at: 7_200, into: &row)
        Self.lay(voice, 0..<10_000, at: 16_320, into: &row)

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClipsWithoutFades(of: project, recordings: sounds)
        try await engine.play(from: 0)
        let sound = try await engine.renderOffline(frames: 30_000)
        #expect(Self.inStep(sound, with: row, from: 0))
        // Where only the first take lies there is silence, and where both lie only the second is heard.
        #expect(Self.clipValues(sound)[6_000] == 0)
        #expect(Self.clipValues(sound)[8_000] == 0.25)
        #expect(Self.clipValues(sound)[16_800] == voice[480] + 0.25)
        await engine.stop()

        // The first take is chosen, and it is heard in place of the second.
        project.setActiveTake(firstTake.id)
        var chosen = Self.silence()
        Self.lay(voice, 0..<10_000, at: 4_800, into: &chosen)
        Self.lay(voice, 0..<10_000, at: 16_320, into: &chosen)

        await engine.setClipsWithoutFades(of: project, recordings: sounds)
        try await engine.play(from: 0)
        let after = try await engine.renderOffline(frames: 30_000)
        #expect(Self.inStep(after, with: chosen, from: 0))
        #expect(Self.clipValues(after)[6_000] == voice[1_200])
        #expect(Self.clipValues(after)[15_000] == 0)
    }

    @Test("A clip is kept inside the song and inside the sound there is for it")
    func clipsAreKeptInsideTheSongAndTheirSound() async throws {
        // One recording began before the song did, one runs past its end, the file of one is shorter than the
        // project says, and the sound of one is missing.
        let early = Recording(lengthSamples: 5_000, rawStart: -0.05)
        let late = Recording(lengthSamples: 5_000, rawStart: 0.95)
        let short = Recording(lengthSamples: 5_000, rawStart: 0.5)
        let missing = Recording(lengthSamples: 5_000, rawStart: 0.7)
        let voice = Self.voice(samples: 5_000)
        let project = Self.project(
            [early, late, short, missing],
            [early, late, short, missing].map { Self.clip($0, 0..<5_000) }
        )

        var row = Self.silence()
        Self.lay(voice, 2_400..<5_000, at: 0, into: &row)
        Self.lay(voice, 0..<2_400, at: 45_600, into: &row)
        Self.lay(voice, 0..<3_000, at: 24_000, into: &row)

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClipsWithoutFades(
            of: project,
            recordings: [early.id: voice, late.id: voice, short.id: Array(voice[..<3_000])]
        )
        try await engine.play(from: 0)
        let sound = try await engine.renderOffline(frames: Self.songSamples)
        #expect(Self.inStep(sound, with: row, from: 0))
        #expect(Self.clipValues(sound)[0] == voice[2_400])
        #expect(Self.clipValues(sound)[47_999] == voice[2_399])
    }

    @Test("A new clip is heard within 100 ms while the song and the clips already there play on without a break")
    func clipIsAddedWhilePlaying() async throws {
        let old = Recording(lengthSamples: 48_000, rawStart: 0)
        let new = Recording(lengthSamples: 20_000, rawStart: 0.1)
        let voice = Self.voice(samples: 48_000)
        let hum = Self.hum(samples: 20_000)
        var before = Self.silence()
        Self.lay(voice, 0..<48_000, at: 0, into: &before)
        var after = before
        Self.lay(hum, 0..<20_000, at: 4_800, into: &after)

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClipsWithoutFades(of: Self.project([old], [Self.clip(old, 0..<48_000)]), recordings: [old.id: voice])
        try await engine.play(from: 0.1)
        #expect(Self.inStep(try await engine.renderOffline(frames: 3_000), with: before, from: 4_800))

        await engine.setClipsWithoutFades(
            of: Self.project([old, new], [Self.clip(old, 0..<48_000), Self.clip(new, 0..<20_000)]),
            recordings: [old.id: voice, new.id: hum]
        )
        #expect(engine.isPlaying)
        let sound = try await Self.renderAtDeviceSpeed(engine, frames: 9_600)

        // The song never noticed.
        #expect(Self.songInStep(sound, from: 7_800))
        // From some sample within 100 ms (4,800 samples) on, both clips are heard.
        let values = Self.clipValues(sound)
        let firstNew = try #require(values.indices.first { values[$0] == after[7_800 + $0] })
        #expect(firstNew <= 4_800)
        #expect(values[firstNew...].indices.allSatisfy { values[$0] == after[7_800 + $0] })
        // Until that sample the clip that was already there plays on, with no silent sample.
        #expect(values[..<firstNew].indices.allSatisfy { values[$0] == before[7_800 + $0] })
    }

    @Test("A clip that is muted or deleted while playing goes silent within 100 ms, and the others play on")
    func clipIsMutedAndDeletedWhilePlaying() async throws {
        let stays = Recording(lengthSamples: 48_000, rawStart: 0)
        let goes = Recording(lengthSamples: 48_000, rawStart: 0)
        let voice = Self.voice(samples: 48_000)
        let hum = Self.hum(samples: 48_000)
        let sounds = [stays.id: voice, goes.id: hum]
        var alone = Self.silence()
        Self.lay(voice, 0..<48_000, at: 0, into: &alone)
        var both = alone
        Self.lay(hum, 0..<48_000, at: 0, into: &both)

        var project = Self.project([stays, goes], [Self.clip(stays, 0..<48_000), Self.clip(goes, 0..<48_000)])
        let engine = try await PlaybackEngineTests.engine()
        await engine.setClipsWithoutFades(of: project, recordings: sounds)
        try await engine.play(from: 0)
        #expect(Self.inStep(try await engine.renderOffline(frames: 2_000), with: both, from: 0))

        // Muted.
        project.tracks[0].clips[1].muted = true
        await engine.setClipsWithoutFades(of: project, recordings: sounds)
        _ = try await Self.renderAtDeviceSpeed(engine, frames: 4_800)
        #expect(Self.inStep(try await engine.renderOffline(frames: 2_000), with: alone, from: 6_800))

        // Brought back, as an undo would.
        project.tracks[0].clips[1].muted = false
        await engine.setClipsWithoutFades(of: project, recordings: sounds)
        _ = try await Self.renderAtDeviceSpeed(engine, frames: 4_800)
        #expect(Self.inStep(try await engine.renderOffline(frames: 2_000), with: both, from: 13_600))

        // Both deleted: no clips at all.
        project.removeClips(Set(project.tracks[0].clips.map(\.id)))
        await engine.setClipsWithoutFades(of: project, recordings: sounds)
        _ = try await Self.renderAtDeviceSpeed(engine, frames: 4_800)
        #expect(Self.inStep(try await engine.renderOffline(frames: 2_000), with: Self.silence(), from: 20_400))
        #expect(engine.isPlaying)
    }

    @Test("Handing over the same clips again while playing changes nothing that is heard")
    func sameClipsAgain() async throws {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        let voice = Self.voice(samples: 48_000)
        var row = Self.silence()
        Self.lay(voice, 0..<48_000, at: 0, into: &row)
        var project = Self.project([recording], [Self.clip(recording, 0..<48_000)])

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClipsWithoutFades(of: project, recordings: [recording.id: voice])
        try await engine.play(from: 0)
        _ = try await engine.renderOffline(frames: 1_000)

        // A change that has nothing to do with the clips, such as a name.
        project.songName = "Another name"
        project.tracks[0].clips[0].name = "Verse"
        await engine.setClipsWithoutFades(of: project, recordings: [recording.id: voice])
        #expect(Self.inStep(try await engine.renderOffline(frames: 9_600), with: row, from: 1_000))
    }

    @Test("Clips that arrive right after Play, before any sound has come out, are in step too")
    func clipsAreSetRightAfterPlay() async throws {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        let voice = Self.voice(samples: 48_000)
        var row = Self.silence()
        Self.lay(voice, 0..<48_000, at: 0, into: &row)

        let engine = try await PlaybackEngineTests.engine()
        try await engine.play(from: 0.25)
        await engine.setClipsWithoutFades(of: Self.project([recording], [Self.clip(recording, 0..<48_000)]), recordings: [recording.id: voice])
        #expect(engine.isPlaying)

        let sound = try await engine.renderOffline(frames: 9_600)
        #expect(Self.songInStep(sound, from: 12_000))
        let values = Self.clipValues(sound)
        let firstHeard = try #require(values.indices.first { values[$0] != 0 })
        #expect(firstHeard <= 4_800)
        #expect(values[firstHeard...].indices.allSatisfy { values[$0] == row[12_000 + $0] })
    }

    @Test("After the sound device changes, the song and the clips go on together")
    func clipsFollowADeviceChange() async throws {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        let voice = Self.voice(samples: 48_000)
        var row = Self.silence()
        Self.lay(voice, 0..<48_000, at: 0, into: &row)

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClipsWithoutFades(of: Self.project([recording], [Self.clip(recording, 0..<48_000)]), recordings: [recording.id: voice])
        try await engine.play(from: 0.5)
        _ = try await engine.renderOffline(frames: 4_800)

        await engine.announceDeviceChange()
        #expect(await PlaybackEngineTests.waitUntil { await engine.deviceChangesFollowed == 1 })
        #expect(Self.inStep(try await engine.renderOffline(frames: 1_000), with: row, from: 28_800))
    }

    @Test("Loading another song forgets the clips of the old one, and they can be handed over again")
    func loadForgetsTheClips() async throws {
        let recording = Recording(lengthSamples: 10_000, rawStart: 0)
        let voice = Self.voice(samples: 10_000)
        let project = Self.project([recording], [Self.clip(recording, 0..<10_000)])
        var row = Self.silence()
        Self.lay(voice, 0..<10_000, at: 0, into: &row)

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClipsWithoutFades(of: project, recordings: [recording.id: voice])
        await engine.load(song: PlaybackEngineTests.song(samples: 24_000))
        try await engine.play(from: 0)
        #expect(Self.inStep(try await engine.renderOffline(frames: 2_000), with: Self.silence(), from: 0))
        await engine.stop()

        await engine.setClipsWithoutFades(of: project, recordings: [recording.id: voice])
        try await engine.play(from: 0)
        #expect(Self.inStep(try await engine.renderOffline(frames: 2_000), with: row, from: 0))
    }

    @Test("A silent engine puts out no clips either")
    func silentEngineHasNoClips() async throws {
        let recording = Recording(lengthSamples: 48_000, rawStart: 0)
        let engine = try await PlaybackEngineTests.engine(silent: true)
        await engine.setClipsWithoutFades(
            of: Self.project([recording], [Self.clip(recording, 0..<48_000)]),
            recordings: [recording.id: Self.voice(samples: 48_000)]
        )
        try await engine.play(from: 0)
        let quiet = try await engine.renderOffline(frames: 4_800)
        #expect(quiet.left.allSatisfy { $0 == 0 })
        #expect(quiet.right.allSatisfy { $0 == 0 })
        #expect(engine.position == 0.1)
    }

    @Test("Two hundred clips play as one row, each at its place")
    func twoHundredClips() async throws {
        // Two hundred recordings of 200 samples, one starting every 240 samples, each played whole.
        let voice = Self.voice(samples: 200)
        var recordings: [Recording] = []
        var sounds: [UUID: [Float]] = [:]
        var row = Self.silence()
        for number in 0..<200 {
            let recording = Recording(lengthSamples: 200, rawStart: Double(number * 240) / 48_000)
            recordings.append(recording)
            sounds[recording.id] = voice
            Self.lay(voice, 0..<200, at: number * 240, into: &row)
        }

        let engine = try await PlaybackEngineTests.engine()
        await engine.setClipsWithoutFades(of: Self.project(recordings, recordings.map { Self.clip($0, 0..<200) }), recordings: sounds)
        try await engine.play(from: 0)
        #expect(Self.inStep(try await engine.renderOffline(frames: Self.songSamples), with: row, from: 0))
    }
}

extension PlaybackEngine {
    /// Hands over the clips with no fade at their edges, so what comes out can be compared with the recordings
    /// sample for sample. These tests are about where and when the clips are heard. The fade is `EdgeFade`'s.
    fileprivate func setClipsWithoutFades(of project: Project, recordings: [UUID: [Float]]) {
        setClips(of: project, recordings: recordings, edgeFadeMs: 0, voices: .none)
    }
}

import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// A made-up project as big as Max's, for the player: 20 tracks with 20 clips each over a song of three and a
/// half minutes, a recording of its own for every clip, a take that waits behind every third clip, a volume on
/// some, and a tightened sound on three of four. It is the same project on every run.
///
/// The app's `-bigProject` makes a project of this size in a scratch run. This one needs no app, so the engine
/// alone can be timed and compared.
enum BigProjectFixture {
    /// Three and a half minutes.
    static let songSamples = 210 * 48_000
    static let trackCount = 20
    static let clipsOnATrack = 20

    struct Made {
        var project: Project
        /// The sound of every recording and of every tightened sound, by id.
        var sounds: [UUID: [Float]]
        var tightened: TightenedSounds
    }

    /// Twelve made-up voices of four seconds, which all recordings share. Every sample lies between -0.25 and
    /// 0.25 and no two stretches are alike, so a piece on the wrong sample is noticed.
    static func voices() -> [[Float]] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<12).map { _ in
            (0..<192_000).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Float(state >> 40) / Float(1 << 25) - 0.25
            }
        }
    }

    static func make() -> Made {
        let voices = voices()
        var sounds: [UUID: [Float]] = [:]
        var recordings: [Recording] = []
        var tightened = TightenedSounds()
        var tracks: [Track] = []
        var number = 0
        for track in 0..<trackCount {
            var clips: [Clip] = []
            for place in 0..<clipsOnATrack {
                number += 1
                // The clips of a track lie ten and a half seconds apart, and each track a little later than the
                // one above it, so clips of different tracks overlap, as voices on top of each other do.
                let start = Double(place) * 10.5 + Double(track) * 0.37
                let length = 72_000 + (number * 7_919) % 120_000
                let recording = Recording(lengthSamples: 192_000, rawStart: start)
                recordings.append(recording)
                sounds[recording.id] = voices[number % voices.count]
                var clip = Clip(
                    segments: [Segment(recordingID: recording.id, inSample: 0, outSample: length)],
                    gainDb: number % 7 == 0 ? -3 : 0,
                    tighten: number % 4 == 0 ? .off : .lines
                )
                if clip.hasTimingFix {
                    // Its tightened sound: other samples of the same length, under an id of their own.
                    let id = UUID()
                    sounds[id] = voices[(number + 5) % voices.count]
                    tightened.set(id, for: clip.segments[0], at: 0, of: clip.id, madeFrom: .recordings)
                }
                if number % 3 == 0 {
                    // A take that waits behind this one: it is in the project and is not heard.
                    let waiting = Recording(lengthSamples: 192_000, rawStart: start)
                    recordings.append(waiting)
                    sounds[waiting.id] = voices[(number + 1) % voices.count]
                    clips.append(Clip(
                        segments: [Segment(recordingID: waiting.id, inSample: 0, outSample: length)],
                        isActiveTake: false,
                        line: clip.line
                    ))
                }
                clip.name = "Clip \(number)"
                clips.append(clip)
            }
            tracks.append(Track(name: "Track \(track + 1)", clips: clips))
        }
        let project = Project(songLengthSamples: songSamples, tracks: tracks, recordings: recordings)
        return Made(project: project, sounds: sounds, tightened: tightened)
    }

    /// The place of the `number`th clip that is heard, counted through the tracks, as (track, clip).
    static func heardClip(_ number: Int, in project: Project) -> (track: Int, clip: Int) {
        var left = number
        for (track, row) in project.tracks.enumerated() {
            for (clip, value) in row.clips.enumerated() where value.isActiveTake && !value.muted {
                if left == 0 { return (track, clip) }
                left -= 1
            }
        }
        return (0, 0)
    }

    /// An engine with a silent song as long as the big project's, not connected to any sound device.
    static func engine() async throws -> PlaybackEngine {
        let engine = try PlaybackEngine(offlineWithMaximumFrames: 4_096, silent: false)
        await engine.load(song: [Float](repeating: 0, count: 2 * songSamples))
        return engine
    }

    static func milliseconds(_ work: () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await work()
        let parts = (ContinuousClock.now - start).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}

/// How long the player takes to be handed the clips of a big project. Nothing is asserted about the times: they
/// are printed, to be read before and after a change to the engine.
@Suite("PlaybackEngine, a big project")
struct PlaybackEngineBigProjectTests {
    @Test("How long the clips of 20 tracks and 400 clips take to hand over, at first and after one clip is deleted")
    func howLongTheHandoverTakes() async throws {
        let made = BigProjectFixture.make()
        let engine = try await BigProjectFixture.engine()
        var project = made.project
        let length = BigProjectFixture.songSamples
        let peaks = RecordingPeaks()

        // The steps of a handover, each alone, to see which of them the time goes to.
        var plan: [ClipPiece] = []
        let firstPlan = await BigProjectFixture.milliseconds {
            plan = project.clipPlaybackPlan(
                from: 0, to: length, peaks: peaks.lookup(in: made.sounds), tightened: made.tightened, voices: .none
            )
        }
        let nextPlan = await BigProjectFixture.milliseconds {
            plan = project.clipPlaybackPlan(
                from: 0, to: length, peaks: peaks.lookup(in: made.sounds), tightened: made.tightened, voices: .none
            )
        }
        var pieces: [ClipPiece] = []
        let kept = await BigProjectFixture.milliseconds {
            pieces = OfflineMix.playable(plan, recordings: made.sounds, lengthSamples: length)
        }
        let mixed = await BigProjectFixture.milliseconds {
            _ = OfflineMix.render(pieces, recordings: made.sounds, lengthSamples: length, fadeSamples: 240)
        }
        print("""
            Big project, the steps alone: \(pieces.count) pieces. \
            The plan \(Self.text(firstPlan)) ms the first time (the peaks are measured) and \(Self.text(nextPlan)) ms after, \
            the pieces kept inside their sounds \(Self.text(kept)) ms, \
            the whole row mixed from nothing \(Self.text(mixed)) ms
            """)

        // The engine itself: the first row, the same clips again, and one clip deleted, three times.
        let first = try await BigProjectFixture.milliseconds {
            await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        }
        let same = try await BigProjectFixture.milliseconds {
            await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        }
        var deletes: [Double] = []
        for number in [150, 151, 152] {
            let at = BigProjectFixture.heardClip(number, in: project)
            project.tracks[at.track].clips.remove(at: at.clip)
            deletes.append(try await BigProjectFixture.milliseconds {
                await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
            })
        }
        // Thirty clips on six tracks at once, as the Delete Max found slow.
        for track in 0..<6 {
            let firstFive = Set(project.tracks[track].clips.filter(\.isActiveTake).prefix(5).map(\.id))
            project.tracks[track].clips.removeAll { firstFive.contains($0.id) }
        }
        let many = try await BigProjectFixture.milliseconds {
            await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        }
        try await engine.play(from: 100)
        _ = try await engine.renderOffline(frames: 4_096)
        let at = BigProjectFixture.heardClip(200, in: project)
        project.tracks[at.track].clips.remove(at: at.clip)
        let playing = try await BigProjectFixture.milliseconds {
            await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        }
        await engine.stop()
        print("""
            Big project, the engine: the first row \(Self.text(first)) ms, the same clips again \(Self.text(same)) ms, \
            one clip deleted \(deletes.map(Self.text).joined(separator: ", ")) ms, \
            thirty clips on six tracks deleted at once \(Self.text(many)) ms, \
            one clip deleted while the song plays \(Self.text(playing)) ms
            """)
    }

    static func text(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }
}

/// After an edit in a big project the engine makes its row of clips from the row it had. What it then plays must
/// be what a row made from nothing holds, on the real engine without a sound device: nothing can be heard.
///
/// The song of these tests is silence, so what comes out is the clips alone, sample for sample.
@Suite("PlaybackEngine, a row made from the row before")
struct PlaybackEngineChangedRowTests {
    /// What the engine puts out for `frames` samples from a place in the song.
    static func played(
        _ engine: PlaybackEngine, from sample: Int, frames: Int
    ) async throws -> (left: [Float], right: [Float]) {
        try await engine.play(from: Double(sample) / Lockstep.sampleRate)
        let sound = try await engine.renderOffline(frames: frames)
        await engine.stop()
        return sound
    }

    /// The row of the whole song made from nothing, as the offline mix has it.
    static func row(_ made: BigProjectFixture.Made, _ project: Project, fadeMs: Double = 5) -> [Float] {
        OfflineMix.render(
            project, recordings: made.sounds, peaks: RecordingPeaks().lookup(in: made.sounds),
            edgeFadeMs: fadeMs, tightened: made.tightened, voices: .none
        )
    }

    /// True when both sides of what was played are the stretch of `row` that starts on `sample`.
    static func same(_ sound: (left: [Float], right: [Float]), as row: [Float], from sample: Int) -> Bool {
        let expected = Array(row[sample..<(sample + sound.left.count)])
        return sound.left == expected && sound.right == expected
    }

    /// The sample of the song a clip's sound starts on.
    static func start(of clip: Clip, in project: Project) -> Int {
        Int((project.start(of: clip)! * Lockstep.sampleRate).rounded())
    }

    @Test("A deleted clip is gone from what is played and Undo brings it back, each time from the row before")
    func deletedClipAndUndo() async throws {
        let made = BigProjectFixture.make()
        let engine = try await BigProjectFixture.engine()
        let whole = Self.row(made, made.project)
        await engine.setClips(of: made.project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        #expect(await engine.clipRowsMadeFromTheRowBefore == 0)

        var project = made.project
        let at = BigProjectFixture.heardClip(150, in: project)
        let clip = project.tracks[at.track].clips[at.clip]
        let place = Self.start(of: clip, in: project)
        project.tracks[at.track].clips.remove(at: at.clip)
        let without = Self.row(made, project)
        #expect(without != whole)

        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        #expect(await engine.clipRowsMadeFromTheRowBefore == 1)
        // Around the clip that is gone, and far from it, where the row is the copy.
        #expect(Self.same(try await Self.played(engine, from: place - 48_000, frames: 6 * 48_000), as: without, from: place - 48_000))
        #expect(Self.same(try await Self.played(engine, from: 0, frames: 3 * 48_000), as: without, from: 0))
        let nearEnd = BigProjectFixture.songSamples - 4 * 48_000
        #expect(Self.same(try await Self.played(engine, from: nearEnd, frames: 3 * 48_000), as: without, from: nearEnd))

        // Undo: the project as it was.
        await engine.setClips(of: made.project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        #expect(await engine.clipRowsMadeFromTheRowBefore == 2)
        #expect(Self.same(try await Self.played(engine, from: place - 48_000, frames: 6 * 48_000), as: whole, from: place - 48_000))
    }

    @Test("Thirty clips on six tracks deleted at once, a moved clip and a muted track are played as made from nothing")
    func severalEdits() async throws {
        let made = BigProjectFixture.make()
        let engine = try await BigProjectFixture.engine()
        var project = made.project
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)

        for track in 0..<6 {
            let firstFive = Set(project.tracks[track].clips.filter(\.isActiveTake).prefix(5).map(\.id))
            project.removeClips(firstFive)
        }
        let moved = project.tracks[8].clips.first { $0.isActiveTake }!
        project.moveClips([moved.id], bySamples: 20_000, trackSteps: 0, voices: .none)
        project.tracks[10].muted = true
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        #expect(await engine.clipRowsMadeFromTheRowBefore == 1)

        // The first minute holds the deleted clips, the moved one and a part of the muted track.
        let row = Self.row(made, project)
        #expect(Self.same(try await Self.played(engine, from: 0, frames: 60 * 48_000), as: row, from: 0))
    }

    @Test("Another fade length makes the row from nothing, and the next edit starts from that row")
    func anotherFadeLength() async throws {
        let made = BigProjectFixture.make()
        let engine = try await BigProjectFixture.engine()
        var project = made.project
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, edgeFadeMs: 5, voices: .none)
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, edgeFadeMs: 20, voices: .none)
        #expect(await engine.clipRowsMadeFromTheRowBefore == 0)
        #expect(Self.same(
            try await Self.played(engine, from: 0, frames: 5 * 48_000), as: Self.row(made, project, fadeMs: 20), from: 0
        ))

        let at = BigProjectFixture.heardClip(3, in: project)
        project.tracks[at.track].clips.remove(at: at.clip)
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, edgeFadeMs: 20, voices: .none)
        #expect(await engine.clipRowsMadeFromTheRowBefore == 1)
        #expect(Self.same(
            try await Self.played(engine, from: 0, frames: 40 * 48_000), as: Self.row(made, project, fadeMs: 20), from: 0
        ))
    }

    @Test("A finished sound arrives and leaves: the one row becomes two and one again, each from the row before")
    func finishedSoundArrivesAndLeaves() async throws {
        let made = BigProjectFixture.make()
        let engine = try await BigProjectFixture.engine()
        let project = made.project
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)

        let at = BigProjectFixture.heardClip(45, in: project)
        let clip = project.tracks[at.track].clips[at.clip]
        let place = Self.start(of: clip, in: project)
        let length = clip.segments[0].lengthSamples
        let id = UUID()
        var finished = FinishedSounds()
        finished.set(FinishedSounds.Sound(id: id, drySamples: length, tailSamples: 24_000, pieces: clip.segments, madeFrom: .recordings), for: clip.id)
        let voices = BigProjectFixture.voices()
        let samples = [id: StereoSound(left: Array(voices[2][..<(length + 24_000)]), right: Array(voices[9][..<(length + 24_000)]))]

        await engine.setClips(
            of: project, recordings: made.sounds, tightened: made.tightened, finished: finished, finishedSamples: samples, voices: .none
        )
        #expect(await engine.clipRowsMadeFromTheRowBefore == 1)
        let plan = project.clipPlaybackPlan(
            from: 0, to: BigProjectFixture.songSamples, peaks: RecordingPeaks().lookup(in: made.sounds),
            tightened: made.tightened, finished: finished, voices: .none
        )
        let stereo = OfflineMix.renderStereo(
            plan, recordings: made.sounds, finished: samples, lengthSamples: BigProjectFixture.songSamples, fadeSamples: 240
        )
        #expect(stereo.left != stereo.right)
        let from = place - 48_000
        let wet = try await Self.played(engine, from: from, frames: 8 * 48_000)
        #expect(wet.left == Array(stereo.left[from..<(from + 8 * 48_000)]))
        #expect(wet.right == Array(stereo.right[from..<(from + 8 * 48_000)]))

        // The sound leaves again: the clip is played from its segments, as at first.
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        #expect(await engine.clipRowsMadeFromTheRowBefore == 2)
        #expect(Self.same(try await Self.played(engine, from: from, frames: 8 * 48_000), as: Self.row(made, project), from: from))
    }

    @Test("After a ready-made row, and after the song was cut shorter, the row is made from nothing")
    func whenTheRowBeforeIsNotTheClips() async throws {
        let made = BigProjectFixture.make()
        let engine = try await BigProjectFixture.engine()
        var project = made.project
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)

        // A slow take hands the engine a row of its own. It is not made of the clips the engine knew.
        await engine.setClips(row: [Float](repeating: 0.125, count: BigProjectFixture.songSamples))
        var at = BigProjectFixture.heardClip(7, in: project)
        project.tracks[at.track].clips.remove(at: at.clip)
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        #expect(await engine.clipRowsMadeFromTheRowBefore == 0)
        var row = Self.row(made, project)
        #expect(Self.same(try await Self.played(engine, from: 0, frames: 30 * 48_000), as: row, from: 0))

        // The end of the song is cut away: the row the engine has is longer than the song is now.
        let kept = 100 * 48_000
        await engine.keepSong(0..<kept)
        at = BigProjectFixture.heardClip(9, in: project)
        project.tracks[at.track].clips.remove(at: at.clip)
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        #expect(await engine.clipRowsMadeFromTheRowBefore == 0)
        row = Self.row(made, project)
        #expect(Self.same(try await Self.played(engine, from: 0, frames: 30 * 48_000), as: row, from: 0))
        // And the edit after that starts from the row of the cut song.
        at = BigProjectFixture.heardClip(2, in: project)
        project.tracks[at.track].clips.remove(at: at.clip)
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        #expect(await engine.clipRowsMadeFromTheRowBefore == 1)
        row = Self.row(made, project)
        #expect(Self.same(try await Self.played(engine, from: 0, frames: 30 * 48_000), as: row, from: 0))
        let nearEnd = kept - 3 * 48_000
        #expect(Self.same(try await Self.played(engine, from: nearEnd, frames: 2 * 48_000), as: row, from: nearEnd))
    }

    @Test("A clip deleted while the song plays is gone within a tenth of a second, and the song plays on in step")
    func deletedWhilePlaying() async throws {
        let made = BigProjectFixture.make()
        let engine = try await BigProjectFixture.engine()
        var project = made.project
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        let whole = Self.row(made, project)

        // Playback starts a second before a clip, and the clip is deleted before it is reached.
        let at = BigProjectFixture.heardClip(200, in: project)
        let clip = project.tracks[at.track].clips[at.clip]
        let from = Self.start(of: clip, in: project) - 48_000
        try await engine.play(from: Double(from) / Lockstep.sampleRate)
        let first = try await engine.renderOffline(frames: 4_800)
        #expect(Self.same(first, as: whole, from: from))

        project.tracks[at.track].clips.remove(at: at.clip)
        await engine.setClips(of: project, recordings: made.sounds, tightened: made.tightened, voices: .none)
        #expect(await engine.clipRowsMadeFromTheRowBefore == 1)
        let rest = try await PlaybackEngineClipTests.renderAtDeviceSpeed(engine, frames: 3 * 48_000)
        await engine.stop()

        // The first tenth of a second may still be the row before. Until the clip's place the two are the same
        // anyway, and from there on only the new row is silent of the clip.
        let without = Self.row(made, project)
        let later = 4_800
        let heard = (left: Array(rest.left[later...]), right: Array(rest.right[later...]))
        #expect(Self.same(heard, as: without, from: from + 4_800 + later))
        #expect(without[(from + 48_000)...] != whole[(from + 48_000)...])
    }
}

import Foundation
import Testing
@testable import LockstepCore

/// A clip sent with its finished sound, and proof that a clip sent without one is the file it always was.
///
/// The song, the recording and the made-up voice are those of `ClipExporterTests`: the recording's sample `n` is
/// heard on sample `12,000 + n` of the song, and at 25 frames per second a frame is 1,920 samples.
@Suite("Clip exporter, with sound")
struct ClipExporterSoundTests {
    typealias Dry = ClipExporterTests

    /// A stand-in for a finished sound: left and right can be told from each other and from the voice, and
    /// every sample says where it is.
    static func finished(_ count: Int) -> StereoSound {
        StereoSound(
            left: (0..<count).map { Float($0 + 1) / 262_144 },
            right: (0..<count).map { -Float($0 + 1) / 524_288 }
        )
    }

    /// The lookup that says `clip` has a finished sound, and that sound's samples by its id.
    static func sound(for clip: Clip, dry: Int, tail: Int) -> (lookup: FinishedSounds, samples: [UUID: StereoSound]) {
        let id = UUID()
        var lookup = FinishedSounds()
        lookup.set(FinishedSounds.Sound(id: id, drySamples: dry, tailSamples: tail, pieces: clip.segments, madeFrom: .recordings), for: clip.id)
        return (lookup, [id: finished(dry + tail)])
    }

    /// The left and the right side of a file's samples, which lie in turn.
    static func sides(_ samples: [Float]) -> (left: [Float], right: [Float]) {
        (
            stride(from: 0, to: samples.count, by: 2).map { samples[$0] },
            stride(from: 1, to: samples.count, by: 2).map { samples[$0] }
        )
    }

    /// One number for a row of samples: any sample that differs in its last digit, or lies one place off,
    /// gives another number.
    static func fingerprint(_ samples: [Float]) -> UInt64 {
        samples.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1.bitPattern)) &* 0x0000_0100_0000_01B3 }
    }

    /// A clip with everything a dry export has to carry: two parts with a gap, the second moved and with a
    /// volume of its own, a clip volume and a Normalize volume that the safe limit holds back, a tightened
    /// sound that starts before its part and ends after it, and a track volume, which is never in a file.
    static func busyProject() -> (project: Project, clip: Clip, sounds: [UUID: [Float]], tightened: TightenedSounds) {
        let recording = Dry.recording()
        let tightID = UUID()
        var clip = Clip(
            segments: [
                Segment(recordingID: recording.id, inSample: 1_000, outSample: 11_000),
                Segment(recordingID: recording.id, inSample: 21_000, outSample: 31_000, offsetSamples: 300, gainDb: -2),
            ],
            gainDb: 4,
            normalizeGainDb: 3
        )
        clip.tighten = .lines
        var project = Dry.project(recording, [clip])
        project.tracks[0].gainDb = -5
        var tightened = TightenedSounds()
        tightened.set(tightID, for: clip.segments[0], at: 0, of: clip.id, lead: 100, tail: 50, madeFrom: .recordings)
        let sounds = [recording.id: Dry.voice(96_000), tightID: Dry.voice(10_150).map { -$0 }]
        return (project, clip, sounds, tightened)
    }

    // MARK: Without a finished sound

    @Test("A dry export holds the very samples it held before a clip could have a finished sound")
    func dryExportIsUnchanged() throws {
        let made = Self.busyProject()

        let export = try #require(ClipExporter.export(
            made.clip.id, in: made.project, recordings: made.sounds, peaks: Dry.peaks(of: made.sounds),
            edgeFadeMs: 5, tightened: made.tightened, voices: .none
        ))

        // The fingerprint was taken from this very export on 15 November 2026, with the exporter as it was
        // before it was built on `ClipDry`. It is the same on every run: the voice is made up by rule.
        #expect(Self.fingerprint(export.samples) == 11_411_542_172_649_295_845)
        #expect(export.samples.count == 32_640)
        #expect(export.startFrame == 6)
        #expect(export.paddingSamples == 1_380)
        #expect(export.clipSamples == 30_400)
        #expect(export.channels == 1)
        #expect(export.tailSamples == 0)
        #expect(export.lengthSamples == 32_640)
    }

    @Test("A clip without a finished sound, or whose finished sound has no samples, is exported dry")
    func noSoundForThisClip() throws {
        let made = Self.busyProject()
        let peaks = Dry.peaks(of: made.sounds)
        let dry = try #require(ClipExporter.export(
            made.clip.id, in: made.project, recordings: made.sounds, peaks: peaks, edgeFadeMs: 5, tightened: made.tightened, voices: .none
        ))
        let other = Self.sound(for: Dry.clip(Dry.recording(), 0..<1_000), dry: 1_000, tail: 0)
        let own = Self.sound(for: made.clip, dry: 30_400, tail: 4_800)

        let withOthers = ClipExporter.export(
            made.clip.id, in: made.project, recordings: made.sounds, peaks: peaks, edgeFadeMs: 5,
            tightened: made.tightened, finished: other.lookup, finishedSamples: other.samples, voices: .none
        )
        let withoutSamples = ClipExporter.export(
            made.clip.id, in: made.project, recordings: made.sounds, peaks: peaks, edgeFadeMs: 5,
            tightened: made.tightened, finished: own.lookup, finishedSamples: [:], voices: .none
        )

        #expect(withOthers == dry)
        #expect(withoutSamples == dry)
    }

    // MARK: With a finished sound

    @Test("A clip with a finished sound is exported as that sound in stereo, on the frame it starts on dry, with its tail, whole frames long")
    func exportWithSound() throws {
        let recording = Dry.recording()
        let sounds = [recording.id: Dry.voice(96_000)]
        // The clip's own volume is in its finished sound already, and the track's is never in a file.
        var clip = Dry.clip(recording, 1_000..<41_000, gainDb: 6)
        clip.normalizeGainDb = 2
        var project = Dry.project(recording, [clip])
        project.tracks[0].gainDb = -5
        let peaks = Dry.peaks(of: sounds)
        let dry = try #require(ClipExporter.export(clip.id, in: project, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none))
        let made = Self.sound(for: clip, dry: 40_000, tail: 9_000)
        let finished = try #require(made.samples.values.first)

        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: sounds, peaks: peaks, edgeFadeMs: 5,
            finished: made.lookup, finishedSamples: made.samples, voices: .none
        ))

        // Where it goes is where the dry clip goes.
        #expect(export.startFrame == dry.startFrame)
        #expect(export.timecode == dry.timecode)
        #expect(export.paddingSamples == dry.paddingSamples)
        #expect(export.fileName == dry.fileName)
        #expect(export.paddingSamples == 1_480)
        // What it holds: 1,480 samples of silence, the 49,000 of the sound, and silence up to the end of frame 26.
        #expect(export.channels == 2)
        #expect(export.clipSamples == 40_000)
        #expect(export.tailSamples == 9_000)
        #expect(export.lengthSamples == 27 * 1_920)
        #expect(export.samples.count == 2 * 27 * 1_920)
        let sides = Self.sides(export.samples)
        #expect(sides.left[..<1_480].allSatisfy { $0 == 0 })
        #expect(sides.right[..<1_480].allSatisfy { $0 == 0 })
        #expect(Array(sides.left[1_480..<50_480]) == finished.left)
        #expect(Array(sides.right[1_480..<50_480]) == finished.right)
        #expect(sides.left[50_480...].allSatisfy { $0 == 0 })
        #expect(sides.right[50_480...].allSatisfy { $0 == 0 })
    }

    @Test("At every frame rate the file with sound is whole frames long, tail included", arguments: ResolveFrameRate.allCases)
    func wholeFramesAtEveryRate(frameRate: ResolveFrameRate) throws {
        let recording = Dry.recording()
        let sounds = [recording.id: Dry.voice(96_000)]
        let clip = Dry.clip(recording, 1_000..<41_000)
        let project = Dry.project(recording, [clip], frameRate: frameRate)
        let made = Self.sound(for: clip, dry: 40_000, tail: 9_001)
        let perFrame = frameRate.samplesPerFrame

        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0,
            finished: made.lookup, finishedSamples: made.samples, voices: .none
        ))

        #expect(export.lengthSamples.isMultiple(of: perFrame))
        #expect(export.samples.count == 2 * export.lengthSamples)
        #expect(export.paddingSamples == 13_000 % perFrame)
        #expect(export.startFrame == 13_000 / perFrame)
        // Less than one frame of silence after the last sample of the tail.
        let after = export.lengthSamples - export.paddingSamples - export.clipSamples - export.tailSamples
        #expect(after >= 0 && after < perFrame)
        #expect(Self.sides(export.samples).left[export.paddingSamples + 49_000] == Self.finished(49_001).left[49_000])
    }

    @Test("For a line with takes, the shown take is sent with its own finished sound")
    func shownTakeWithSound() throws {
        let recording = Dry.recording()
        let sounds = [recording.id: Dry.voice(96_000)]
        var waiting = Dry.clip(recording, 1_000..<41_000)
        waiting.isActiveTake = false
        var active = Dry.clip(recording, 1_500..<41_500)
        active.line = waiting.line
        var project = Dry.project(recording, [waiting, active])
        project.normalizeTakes()
        let shown = try #require(project.takes(of: waiting.id).first { $0.isActiveTake })
        let made = Self.sound(for: shown, dry: 40_000, tail: 100)

        let export = try #require(ClipExporter.export(
            waiting.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0,
            finished: made.lookup, finishedSamples: made.samples, voices: .none
        ))

        #expect(export.channels == 2)
        #expect(Self.sides(export.samples).left[export.paddingSamples] == Self.finished(1).left[0])
    }
}

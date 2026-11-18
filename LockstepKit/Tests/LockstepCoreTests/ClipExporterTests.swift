import Foundation
import Testing
@testable import LockstepCore

/// One clip made ready for DaVinci Resolve, compared sample for sample with the offline mix of the same clip.
///
/// The song of these tests is four seconds long. The recording began a quarter of a second into it, so sample
/// `n` of the recording is heard on sample `12,000 + n` of the song.
@Suite("Clip exporter")
struct ClipExporterTests {
    static let songSamples = 192_000
    /// The sample of the song on which the recording's first sample is heard.
    static let recordingPlace = 12_000

    /// Made-up voice that is the same on every run: no sample is silent and no two stretches are alike, so a
    /// sound that lands one sample off is noticed.
    static func voice(_ count: Int) -> [Float] {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = Float(state >> 40) / Float(1 << 24) - 0.5
            return value == 0 ? 0.25 : value
        }
    }

    static func recording() -> Recording {
        Recording(lengthSamples: 96_000, rawStart: Double(recordingPlace) / 48_000)
    }

    /// A clip that plays one stretch of the recording.
    static func clip(_ recording: Recording, _ samples: Range<Int>, gainDb: Double = 0) -> Clip {
        Clip(
            segments: [Segment(recordingID: recording.id, inSample: samples.lowerBound, outSample: samples.upperBound)],
            gainDb: gainDb
        )
    }

    /// A project with one track holding these clips, on a Resolve timeline with this frame rate.
    static func project(
        _ recording: Recording,
        _ clips: [Clip],
        frameRate: ResolveFrameRate = .fps25,
        trackName: String = "Double"
    ) -> Project {
        Project(
            songName: "Weighted Silence",
            songLengthSamples: songSamples,
            resolve: ResolveSettings(frameRate: frameRate),
            tracks: [Track(name: trackName, clips: clips)],
            recordings: [recording]
        )
    }

    /// The highest sample of a stretch of these sounds, as the app measures it.
    static func peaks(of sounds: [UUID: [Float]]) -> RecordingPeak {
        { id, samples in
            guard let sound = sounds[id] else { return 0 }
            let inside = max(samples.lowerBound, 0)..<min(samples.upperBound, sound.count)
            return inside.isEmpty ? 0 : sound[inside].reduce(0) { max($0, abs($1)) }
        }
    }

    // MARK: Where the file starts and ends

    @Test("The file starts on a frame, is whole frames long, and holds the offline mix of the clip after its padding")
    func startsOnAFrame() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(96_000)]
        // The clip's first sound is sample 13,000 of the song. At 25 frames per second a frame is 1,920
        // samples, so that is 1,480 samples into frame 6, and the clip's 40,000 samples end inside frame 27.
        let clip = Self.clip(recording, 1_000..<41_000)
        let project = Self.project(recording, [clip])

        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: sounds, peaks: Self.peaks(of: sounds), edgeFadeMs: 5, voices: .none
        ))

        #expect(export.startFrame == 6)
        #expect(export.timecode.text == "01:00:00:06")
        #expect(export.paddingSamples == 1_480)
        #expect(export.clipSamples == 40_000)
        #expect(export.samples.count == 22 * 1_920)
        #expect(export.samples.firstIndex { $0 != 0 } == 1_480)
        let mix = OfflineMix.render(
            project, from: 13_000, to: 53_000, recordings: sounds, peaks: Self.peaks(of: sounds), edgeFadeMs: 5, voices: .none
        )
        #expect(Array(export.samples[1_480..<41_480]) == mix)
        #expect(export.samples[41_480...].allSatisfy { $0 == 0 })
        #expect(export.fileName == "Weighted Silence - Double - 01.00.00.06.wav")
    }

    @Test("At every frame rate the file is whole frames long and the sound sits right after the padding", arguments: ResolveFrameRate.allCases)
    func wholeFramesAtEveryRate(frameRate: ResolveFrameRate) throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(96_000)]
        let clip = Self.clip(recording, 1_000..<41_000)
        let project = Self.project(recording, [clip], frameRate: frameRate)
        let perFrame = frameRate.samplesPerFrame

        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, voices: .none
        ))

        #expect(export.samples.count.isMultiple(of: perFrame))
        #expect(export.paddingSamples == 13_000 % perFrame)
        #expect(export.startFrame == 13_000 / perFrame)
        #expect(export.paddingSamples < perFrame)
        // Less than one frame of silence after the clip's last sample.
        #expect(export.samples.count - export.paddingSamples - export.clipSamples < perFrame)
        #expect(export.samples.firstIndex { $0 != 0 } == export.paddingSamples)
        #expect(Array(export.samples[export.paddingSamples...].prefix(40_000)) == Array(sounds[recording.id]![1_000..<41_000]))
        #expect(export.timecode == project.resolve.timecode(frame: export.startFrame))
    }

    @Test("A clip that starts exactly on a frame has no padding, and one that ends on a frame gets no silence after it")
    func onAFrameThereIsNoPadding() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(96_000)]
        // Sample 15,360 of the song is the start of frame 8, and 19,200 samples are ten frames.
        let clip = Self.clip(recording, 3_360..<22_560)
        let project = Self.project(recording, [clip])

        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, voices: .none
        ))

        #expect(export.paddingSamples == 0)
        #expect(export.startFrame == 8)
        #expect(export.samples == Array(sounds[recording.id]![3_360..<22_560]))
    }

    @Test("A song that starts after 00:00 moves the frame and the padding")
    func songAfterTheTimelineStartCounts() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(96_000)]
        let clip = Self.clip(recording, 1_000..<41_000)
        var project = Self.project(recording, [clip])
        // What a project saved with the song 50 frames after the timeline start opens as.
        project.songPlace = SongPlace(resolveOffsetFrames: 50, samplesPerFrame: 1_920, ofLength: 480_000)

        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, voices: .none
        ))

        #expect(export.startFrame == 56)
        #expect(export.timecode.text == "01:00:02:06")
        #expect(export.paddingSamples == 1_480)
    }

    @Test("With the song's beginning cut away and what is left at 00:00, a clip's timecode counts from the cut")
    func cutSongCounts() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(96_000)]
        let clip = Self.clip(recording, 1_000..<41_000)
        var project = Self.project(recording, [clip])
        let uncut = try #require(ClipExporter.export(
            clip.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, voices: .none
        ))
        // The first 5 frames of the song are cut away, and the song is moved so the cut stands at 00:00.
        project.songPlace = SongPlace()
            .cuttingStart(at: 5 * 1_920, ofLength: project.songLengthSamples)
            .moved(bySamples: -5 * 1_920, ofLength: project.songLengthSamples)
        #expect(project.songPlace.zeroSample == 5 * 1_920)

        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, voices: .none
        ))

        // Five frames earlier on the Resolve timeline, with the same silence before the first sound and
        // the same sound: the clip stayed on its beat of the song.
        #expect(export.startFrame == uncut.startFrame - 5)
        #expect(export.timecode == project.resolve.timecode(frame: uncut.startFrame - 5))
        #expect(export.paddingSamples == uncut.paddingSamples)
        #expect(export.samples == uncut.samples)
        // Cutting alone, with the song left where it was, changes no timecode.
        project.songPlace = SongPlace().cuttingStart(at: 5 * 1_920, ofLength: project.songLengthSamples)
        let cutOnly = try #require(ClipExporter.export(
            clip.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, voices: .none
        ))
        #expect(cutOnly.timecode == uncut.timecode)
    }

    @Test("The start sample is the one the plan plays the clip's first sound on, with its move counted in")
    func startSampleFollowsTheClip() throws {
        let recording = Self.recording()
        var clip = Self.clip(recording, 1_000..<41_000)
        clip.segments[0].offsetSamples = 777
        let project = Self.project(recording, [clip])

        #expect(ClipExporter.startSample(of: clip.id, in: project, voices: .none) == 13_777)
        #expect(project.clipPlaybackPlan(from: 0, voices: .none).first?.startDelay == 13_777)
        #expect(ClipExporter.startSample(of: UUID(), in: project, voices: .none) == nil)
    }

    // MARK: What the file holds

    @Test("The clip's volume is in the file, held back by the safe limit as when it plays")
    func volumeIsApplied() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(96_000)]
        // The voice peaks near 0.5, so 12 dB more would pass the safe limit and is held back.
        var clip = Self.clip(recording, 1_000..<41_000, gainDb: 12)
        clip.segments[0].gainDb = -1
        let project = Self.project(recording, [clip])
        let peaks = Self.peaks(of: sounds)

        let export = try #require(ClipExporter.export(clip.id, in: project, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none))

        #expect(clip.appliedGain(peaks: peaks).isHeldBack)
        let mix = OfflineMix.render(project, from: 13_000, to: 53_000, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none)
        #expect(Array(export.samples[export.paddingSamples...].prefix(40_000)) == mix)
        let limit = Float(pow(10, Clip.safeLimitDb / 20))
        #expect(export.samples.allSatisfy { abs($0) <= limit + 1e-6 })
        #expect(export.samples.contains { abs($0) > 0.6 })
    }

    @Test("A clip of several parts keeps the gap between them as silence")
    func gapsAreSilence() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(96_000)]
        let clip = Clip(segments: [
            Segment(recordingID: recording.id, inSample: 1_000, outSample: 11_000),
            Segment(recordingID: recording.id, inSample: 21_000, outSample: 31_000),
        ])
        let project = Self.project(recording, [clip])

        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none
        ))

        #expect(export.clipSamples == 30_000)
        let sound = Array(export.samples[export.paddingSamples...].prefix(30_000))
        #expect(sound == OfflineMix.render(
            project, from: 13_000, to: 43_000, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none
        ))
        #expect(sound[10_000..<20_000].allSatisfy { $0 == 0 })
        #expect(sound[20_000..<30_000].contains { $0 != 0 })
    }

    @Test("A muted clip, and a clip on a muted track, are exported all the same, and alone")
    func muteIsIgnored() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(96_000)]
        let clip = Self.clip(recording, 1_000..<41_000)
        let heard = Self.project(recording, [clip])
        var muted = clip
        muted.muted = true
        // A neighbour that overlaps the clip's end is not in the export.
        var silenced = Self.project(recording, [muted, Self.clip(recording, 40_000..<60_000)])
        silenced.tracks[0].muted = true

        let expected = ClipExporter.export(clip.id, in: heard, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none)
        let export = ClipExporter.export(clip.id, in: silenced, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none)

        #expect(export != nil)
        #expect(export == expected)
    }

    @Test("For a line with takes, the take that is shown is exported, whichever take was asked for")
    func activeTakeIsExported() throws {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(96_000)]
        var waiting = Self.clip(recording, 1_000..<41_000)
        waiting.isActiveTake = false
        // The second take starts 500 samples later, in another frame position.
        var active = Self.clip(recording, 1_500..<41_500)
        active.line = waiting.line
        var project = Self.project(recording, [waiting, active])
        project.normalizeTakes()
        #expect(project.takeCount(of: waiting.id) == 2)
        let takes = project.takes(of: waiting.id)
        let shown = try #require(takes.first { $0.isActiveTake })

        let asked = ClipExporter.export(waiting.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, voices: .none)
        let direct = ClipExporter.export(shown.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, voices: .none)

        #expect(asked != nil)
        #expect(asked == direct)
        #expect(ClipExporter.startSample(of: waiting.id, in: project, voices: .none) == ClipExporter.startSample(of: shown.id, in: project, voices: .none))
    }

    @Test("There is no export for a clip that is not there, or that has no sound")
    func nothingToExport() {
        let recording = Self.recording()
        let sounds = [recording.id: Self.voice(96_000)]
        let empty = Clip(segments: [])
        let project = Self.project(recording, [empty])

        #expect(ClipExporter.export(UUID(), in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none) == nil)
        #expect(ClipExporter.export(empty.id, in: project, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none) == nil)
    }

    // MARK: The file's name

    @Test("The name holds the song, the track and the timecode, and nothing a file name cannot hold")
    func fileName() throws {
        let timecode = Timecode(hours: 1, minutes: 0, seconds: 16, frames: 0)

        #expect(
            ClipExporter.fileName(songName: "Weighted Silence", trackName: "Double", timecode: timecode)
                == "Weighted Silence - Double - 01.00.16.00.wav"
        )
        let slashed = ClipExporter.fileName(songName: "Weighted Silence", trackName: "Double / lead", timecode: timecode)
        #expect(!slashed.contains("/"))
        #expect(slashed == "Weighted Silence - Double   lead - 01.00.16.00.wav")
        let odd = ClipExporter.fileName(songName: "AC/DC: live\n", trackName: "", timecode: timecode)
        #expect(odd == "AC DC  live - 01.00.16.00.wav")

        // The same name through a whole export.
        let recording = Self.recording()
        let clip = Self.clip(recording, 1_000..<41_000)
        let project = Self.project(recording, [clip], trackName: "Double / lead")
        let export = try #require(ClipExporter.export(
            clip.id, in: project, recordings: [recording.id: Self.voice(96_000)], peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none
        ))
        #expect(!export.fileName.contains("/"))
        #expect(export.fileName == "Weighted Silence - Double   lead - 01.00.00.06.wav")
    }
}

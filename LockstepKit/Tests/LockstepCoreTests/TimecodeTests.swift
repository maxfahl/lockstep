import Foundation
import Testing
@testable import LockstepCore

@Suite("Resolve frame and timecode")
struct TimecodeTests {
    private func tc(_ h: Int, _ m: Int, _ s: Int, _ f: Int) -> Timecode {
        Timecode(hours: h, minutes: m, seconds: s, frames: f)
    }

    @Test func everyRateHasTheSamplesPerFrameOf48kHz() {
        let expected: [ResolveFrameRate: Int] = [
            .fps23_976: 2002, .fps24: 2000, .fps25: 1920, .fps30: 1600, .fps50: 960, .fps60: 800,
        ]
        for rate in ResolveFrameRate.allCases {
            #expect(rate.samplesPerFrame == expected[rate])
        }
    }

    @Test func theDefaultsAreMaxsResolveProject() {
        let settings = ResolveSettings()
        #expect(settings.timelineStart == tc(1, 0, 0, 0))
        #expect(settings.frameRate == .fps25)
    }

    @Test(arguments: ResolveFrameRate.allCases)
    func theSongsFirstSampleIsTheTimelineStartWithNoPadding(rate: ResolveFrameRate) {
        let settings = ResolveSettings(frameRate: rate)
        #expect(settings.startFrame(forTimelineSample: 0) == 0)
        #expect(settings.paddingSamples(forTimelineSample: 0) == 0)
        #expect(settings.timecode(frame: settings.startFrame(forTimelineSample: 0)) == tc(1, 0, 0, 0))
    }

    @Test(arguments: ResolveFrameRate.allCases)
    func aSampleJustBeforeAFrameGetsNearlyAFrameOfPadding(rate: ResolveFrameRate) {
        let settings = ResolveSettings(frameRate: rate)
        let perFrame = rate.samplesPerFrame
        let sample = 10 * perFrame - 1
        #expect(settings.startFrame(forTimelineSample: sample) == 9)
        #expect(settings.paddingSamples(forTimelineSample: sample) == perFrame - 1)
        // One sample later it is exactly on the next frame.
        #expect(settings.startFrame(forTimelineSample: sample + 1) == 10)
        #expect(settings.paddingSamples(forTimelineSample: sample + 1) == 0)
    }

    @Test(arguments: ResolveFrameRate.allCases)
    func paddingIsAlwaysLessThanAFrame(rate: ResolveFrameRate) {
        let settings = ResolveSettings(frameRate: rate)
        for sample in stride(from: -5000, through: 50_000, by: 997) {
            let frame = settings.startFrame(forTimelineSample: sample)
            let padding = settings.paddingSamples(forTimelineSample: sample)
            #expect((0..<rate.samplesPerFrame).contains(padding))
            #expect(frame * rate.samplesPerFrame + padding == sample)
        }
    }

    @Test func aSecondAt23976Is24FramesOf2002Samples() {
        let settings = ResolveSettings(frameRate: .fps23_976)
        let frame = settings.startFrame(forTimelineSample: 24 * 2002 + 5)
        #expect(frame == 24)
        #expect(settings.paddingSamples(forTimelineSample: 24 * 2002 + 5) == 5)
        #expect(settings.timecode(frame: frame) == tc(1, 0, 1, 0))
    }

    @Test func aKnownMomentAt25() {
        // 12.345 s into the song is sample 592,560: frame 308, 1,200 samples in.
        let settings = ResolveSettings()
        #expect(settings.startFrame(forTimelineSample: 592_560) == 308)
        #expect(settings.paddingSamples(forTimelineSample: 592_560) == 1200)
        #expect(settings.timecode(frame: 308).text == "01:00:12:08")
    }

    @Test func countingCrossesTheHour() {
        let settings = ResolveSettings(timelineStart: tc(0, 59, 59, 20), frameRate: .fps25)
        #expect(settings.timecode(frame: 10) == tc(1, 0, 0, 5))
    }

    @Test func aClipBeforeTheTimelineStartRoundsDownToTheFrameBefore() {
        let settings = ResolveSettings()
        #expect(settings.startFrame(forTimelineSample: -1) == -1)
        #expect(settings.paddingSamples(forTimelineSample: -1) == 1919)
        #expect(settings.timecode(frame: -1) == tc(0, 59, 59, 24))
    }

    @Test func formatting() {
        #expect(tc(1, 2, 3, 4).text == "01:02:03:04")
        #expect(tc(23, 59, 59, 59).text == "23:59:59:59")
        #expect(tc(1, 2, 3, 4).fileNameText == "01.02.03.04")
        #expect("\(tc(0, 0, 0, 0))" == "00:00:00:00")
    }

    @Test(arguments: [
        ("01:00:00:00", ResolveFrameRate.fps25, Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0)),
        ("00:59:59:24", .fps25, Timecode(hours: 0, minutes: 59, seconds: 59, frames: 24)),
        ("23:59:59:59", .fps60, Timecode(hours: 23, minutes: 59, seconds: 59, frames: 59)),
        ("10:20:30:23", .fps23_976, Timecode(hours: 10, minutes: 20, seconds: 30, frames: 23)),
        (" 1:0:0:0 ", .fps25, Timecode(hours: 1, minutes: 0, seconds: 0, frames: 0)),
    ])
    func parsingAcceptsValidText(text: String, rate: ResolveFrameRate, expected: Timecode) {
        #expect(Timecode.parse(text, frameRate: rate) == expected)
    }

    @Test(arguments: [
        ("01:00:00:25", ResolveFrameRate.fps25),
        ("01:00:00:24", .fps23_976),
        ("01:00:00:24", .fps24),
        ("01:00:00:30", .fps30),
        ("01:60:00:00", .fps25),
        ("01:00:60:00", .fps25),
        ("24:00:00:00", .fps25),
        ("01:00:00", .fps25),
        ("01:00:00:00:00", .fps25),
        ("01.00.00.00", .fps25),
        ("01:00:00:", .fps25),
        ("001:00:00:00", .fps25),
        ("01:-1:00:00", .fps25),
        ("01:0a:00:00", .fps25),
        ("", .fps25),
    ])
    func parsingRefusesInvalidText(text: String, rate: ResolveFrameRate) {
        #expect(Timecode.parse(text, frameRate: rate) == nil)
    }

    @Test(arguments: ResolveFrameRate.allCases)
    func formattingRoundTrips(rate: ResolveFrameRate) {
        let settings = ResolveSettings(frameRate: rate)
        for frame in stride(from: 0, through: 200_000, by: 7_919) {
            let timecode = settings.timecode(frame: frame)
            #expect(Timecode.parse(timecode.text, frameRate: rate) == timecode)
            #expect(timecode.frameCount(at: rate) - settings.timelineStart.frameCount(at: rate) == frame)
        }
    }

    // MARK: Saving

    @Test func theSettingsAreSavedAsReadableText() throws {
        let settings = ResolveSettings(timelineStart: tc(0, 59, 58, 3), frameRate: .fps23_976)
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""00:59:58:03""#))
        #expect(text.contains(#""23.976""#))
        #expect(try JSONDecoder().decode(ResolveSettings.self, from: data) == settings)
    }

    @Test func aProjectSavedBeforeResolveSettingsOpensWithTheDefaults() throws {
        let old = try JSONDecoder().decode(Project.self, from: Data(#"{"songName":"Old","version":1}"#.utf8))
        #expect(old.songName == "Old")
        #expect(old.resolve == ResolveSettings())

        let partly = try JSONDecoder().decode(
            Project.self, from: Data(#"{"songName":"Old","resolve":{"frameRate":"24"}}"#.utf8))
        #expect(partly.resolve == ResolveSettings(frameRate: .fps24))
    }

    @Test func aProjectKeepsItsResolveSettings() throws {
        var project = Project(songName: "Song")
        project.resolve = ResolveSettings(timelineStart: tc(0, 0, 10, 0), frameRate: .fps60)
        let read = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(read == project)
    }

    @Test func aSongCutAtItsStartInResolveStartsBeforeTheTimeline() throws {
        // Twelve seconds of the song's beginning are cut away in Resolve, so the song's own start lies
        // twelve seconds before the timeline's. Typed in the panel, that is a cut of the song in Lockstep
        // with what is left standing at 00:00.
        var project = Project(songLengthSamples: 60 * 48_000)
        project.songPlace = try #require(project.songPlace(withSongStartTyped: "00:59:48:00"))
        #expect(project.songPlace == SongPlace(cutStartSamples: 12 * 48_000, zeroSample: 12 * 48_000))
        #expect(project.resolveSongStart.text == "00:59:48:00")
        // What is heard twelve seconds into the song is the first thing on the timeline.
        let onTimeline = project.songPlace.timelineSample(forSong: 12 * 48_000)
        let frame = project.resolve.startFrame(forTimelineSample: onTimeline)
        #expect(project.resolve.timecode(frame: frame).text == "01:00:00:00")
        #expect(project.resolve.paddingSamples(forTimelineSample: onTimeline) == 0)
        // Another frame rate keeps the song where it is.
        project.resolve = project.resolve.withFrameRate(.fps50)
        #expect(project.resolveSongStart.text == "00:59:48:00")
        // Text that is no timecode changes nothing.
        #expect(project.songPlace(withSongStartTyped: "soon") == nil)
    }

    @Test func aTimelineThatStartsAtZeroReadsALateTimecodeAsBeforeIt() throws {
        var project = Project(songLengthSamples: 60 * 48_000)
        project.resolve.timelineStart = tc(0, 0, 0, 0)
        project.songPlace = try #require(project.songPlace(withSongStartTyped: "23:59:48:00"))
        #expect(project.songPlace.zeroSample == 12 * 48_000)
        #expect(project.resolveSongStart.text == "23:59:48:00")
    }
}

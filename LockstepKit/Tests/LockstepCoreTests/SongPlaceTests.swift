import Foundation
import Testing
@testable import LockstepCore

@Suite("The song's cut and its place on the timeline")
struct SongPlaceTests {
    /// A song of one minute.
    private let length = 60 * 48_000

    // MARK: Song time and timeline time

    @Test func anUncutSongCountsFromItsOwnStart() {
        let place = SongPlace()
        #expect(place.timelineSeconds(forSong: 12.5) == 12.5)
        #expect(place.songSeconds(forTimeline: 12.5) == 12.5)
        #expect(place.timelineSample(forSong: 480) == 480)
        #expect(place.keptSamples(ofLength: length) == 0..<length)
        #expect(place.shownSeconds(ofLength: length) == 0...60)
    }

    @Test func timesCountFromTheTimelinesZero() {
        // Twelve seconds are cut away and what is left stands at 00:00.
        let place = SongPlace(cutStartSamples: 12 * 48_000, zeroSample: 12 * 48_000)
        #expect(place.zeroSeconds == 12)
        #expect(place.timelineSeconds(forSong: 12) == 0)
        #expect(place.timelineSeconds(forSong: 32.5) == 20.5)
        #expect(place.songSeconds(forTimeline: 20.5) == 32.5)
        #expect(place.timelineSample(forSong: 12 * 48_000 + 7) == 7)
        #expect(place.songSample(forTimeline: 7) == 12 * 48_000 + 7)
        // A count-in before the song is before 00:00.
        #expect(place.timelineSeconds(forSong: 10) == -2)
        // The timeline starts inside the song and still ends where the file does.
        #expect(place.shownSeconds(ofLength: length) == 12...60)
        #expect(place.keptSeconds(ofLength: length) == 12...60)
    }

    @Test func theTwoConversionsUndoEachOther() {
        let place = SongPlace(cutStartSamples: 500_000, zeroSample: 123_457)
        for sample in stride(from: -100_000, through: 3_000_000, by: 99_991) {
            #expect(place.songSample(forTimeline: place.timelineSample(forSong: sample)) == sample)
        }
    }

    // MARK: The limits of the cut

    @Test func theLeftEdgeCutsTheBeginningAndComesBack() {
        let cut = SongPlace().cuttingStart(at: 5 * 48_000, ofLength: length)
        #expect(cut.keptSamples(ofLength: length) == 5 * 48_000..<length)
        // Cutting alone moves nothing: 00:00 is still the song's own first sample.
        #expect(cut.zeroSample == 0)
        #expect(cut.cuttingStart(at: 0, ofLength: length) == SongPlace())
        // Dragged past the start of the song, it stops there.
        #expect(cut.cuttingStart(at: -48_000, ofLength: length) == SongPlace())
    }

    @Test func theRightEdgeCutsTheEndAndComesBack() {
        let cut = SongPlace().cuttingEnd(at: 50 * 48_000, ofLength: length)
        #expect(cut.keptSamples(ofLength: length) == 0..<50 * 48_000)
        #expect(cut.cuttingEnd(at: length, ofLength: length) == SongPlace())
        #expect(cut.cuttingEnd(at: length + 48_000, ofLength: length) == SongPlace())
    }

    @Test func aSecondOfTheSongIsAlwaysLeft() {
        let end = SongPlace().cuttingEnd(at: 20 * 48_000, ofLength: length)
        // The left edge dragged over the right one stops a second before it.
        #expect(end.cuttingStart(at: 30 * 48_000, ofLength: length).keptSamples(ofLength: length)
            == 19 * 48_000..<20 * 48_000)
        // And the right edge dragged over the left one stops a second after it.
        let start = SongPlace().cuttingStart(at: 20 * 48_000, ofLength: length)
        #expect(start.cuttingEnd(at: 0, ofLength: length).keptSamples(ofLength: length)
            == 20 * 48_000..<21 * 48_000)
    }

    @Test func theSongsStartNeverGoesLeftOfZero() {
        let cut = SongPlace().cuttingStart(at: 12 * 48_000, ofLength: length)
        // Moved left as far as was cut, the song stands with its new start at 00:00.
        let atZero = cut.moved(bySamples: -12 * 48_000, ofLength: length)
        #expect(atZero == SongPlace(cutStartSamples: 12 * 48_000, zeroSample: 12 * 48_000))
        #expect(atZero.timelineSample(forSong: atZero.keptSamples(ofLength: length).lowerBound) == 0)
        // Its left edge cannot be dragged back over 00:00 from there, only further in.
        #expect(atZero.cuttingStart(at: 0, ofLength: length) == atZero)
        #expect(atZero.cuttingStart(at: 15 * 48_000, ofLength: length).cutStartSamples == 15 * 48_000)
        // Moved left by more than was cut, the song goes on and what passes 00:00 is cut away too.
        let further = cut.moved(bySamples: -20 * 48_000, ofLength: length)
        #expect(further == SongPlace(cutStartSamples: 20 * 48_000, zeroSample: 20 * 48_000))
        #expect(further.timelineSample(forSong: further.keptSamples(ofLength: length).lowerBound) == 0)
    }

    @Test func aSongThatIsNotCutCanBeMovedSoThatZeroLiesInsideIt() {
        // Dragged ten seconds to the left: 00:00 is ten seconds into the song, and what lies before it is
        // not kept, exactly like a beginning cut away with the edge.
        let moved = SongPlace().moved(bySamples: -10 * 48_000, ofLength: length)
        #expect(moved.zeroSample == 10 * 48_000)
        #expect(moved.keptSamples(ofLength: length) == 10 * 48_000..<length)
        #expect(moved.shownSeconds(ofLength: length) == 10...60)
        #expect(moved.timelineSeconds(forSong: 10) == 0)
        // No click before 00:00, and the click file starts there.
        let row = (0..<length).map { Float($0 % 7) }
        #expect(moved.timelineRow(of: row, ofLength: length) == Array(row[(10 * 48_000)...]))
        // Dragged back to the right the beginning comes back, in one drag or in several.
        #expect(moved.moved(bySamples: 4 * 48_000, ofLength: length)
            == SongPlace(cutStartSamples: 6 * 48_000, zeroSample: 6 * 48_000))
        #expect(moved.moved(bySamples: 10 * 48_000, ofLength: length) == SongPlace())
        // To the right it stops with its own first sample at 00:00.
        #expect(moved.moved(bySamples: 30 * 48_000, ofLength: length) == SongPlace())
        #expect(SongPlace().moved(bySamples: 48_000, ofLength: length) == SongPlace())
    }

    @Test func aSecondIsLeftOfASongMovedFarToTheLeft() {
        #expect(SongPlace().moved(bySamples: -90 * 48_000, ofLength: length).keptSamples(ofLength: length)
            == 59 * 48_000..<length)
        // With the end cut away, the second that is left is the one before that cut.
        let end = SongPlace().cuttingEnd(at: 20 * 48_000, ofLength: length)
        let moved = end.moved(bySamples: -90 * 48_000, ofLength: length)
        #expect(moved.keptSamples(ofLength: length) == 19 * 48_000..<20 * 48_000)
        #expect(moved.zeroSample == 19 * 48_000)
        // A song shorter than that second cannot be moved.
        #expect(SongPlace().moved(bySamples: -1_000, ofLength: 24_000) == SongPlace())
    }

    @Test func aCutSongWithRoomBeforeItMovesInThatRoomAndKeepsItsCut() {
        // The left edge was dragged in by twelve seconds: the song starts twelve seconds after 00:00.
        let cut = SongPlace(cutStartSamples: 12 * 48_000)
        let nearer = cut.moved(bySamples: -5 * 48_000, ofLength: length)
        #expect(nearer == SongPlace(cutStartSamples: 12 * 48_000, zeroSample: 5 * 48_000))
        #expect(nearer.moved(bySamples: 5 * 48_000, ofLength: length) == cut)
        #expect(nearer.moved(bySamples: 30 * 48_000, ofLength: length) == cut)
    }

    @Test func theSongMovesBackAsFarAsItsOwnFirstSample() {
        // What is left stands at 00:00: moved right, its beginning comes back with it.
        let atZero = SongPlace(cutStartSamples: 12 * 48_000, zeroSample: 12 * 48_000)
        #expect(atZero.moved(bySamples: 4 * 48_000, ofLength: length)
            == SongPlace(cutStartSamples: 8 * 48_000, zeroSample: 8 * 48_000))
        #expect(atZero.moved(bySamples: 30 * 48_000, ofLength: length) == SongPlace())
        // A song saved with its first sample after 00:00 goes left like any other, and no further right.
        let late = SongPlace(zeroSample: -96_000)
        #expect(late.moved(bySamples: 48_000, ofLength: length) == late)
        #expect(late.moved(bySamples: -48_000, ofLength: length) == SongPlace(zeroSample: -48_000))
        #expect(late.moved(bySamples: -144_000, ofLength: length)
            == SongPlace(cutStartSamples: 48_000, zeroSample: 48_000))
    }

    @Test func aTypedStartMovesTheSongTheSameWay() {
        // A start twelve seconds before 00:00 cuts those twelve seconds away.
        let before = SongPlace().startingOnTimeline(at: -12 * 48_000, ofLength: length)
        #expect(before == SongPlace(cutStartSamples: 12 * 48_000, zeroSample: 12 * 48_000))
        // Typed back, the beginning is there again, also when the song then starts after 00:00.
        #expect(before.startingOnTimeline(at: 0, ofLength: length) == SongPlace())
        #expect(before.startingOnTimeline(at: 96_000, ofLength: length) == SongPlace(zeroSample: -96_000))
        // A cut made with the edge, with room before the song, is kept.
        let cut = SongPlace(cutStartSamples: 12 * 48_000)
        #expect(cut.startingOnTimeline(at: -5 * 48_000, ofLength: length)
            == SongPlace(cutStartSamples: 12 * 48_000, zeroSample: 5 * 48_000))
    }

    @Test func aPlaceIsHeldInsideTheSong() {
        let wild = SongPlace(cutStartSamples: 90 * 48_000, cutEndSamples: 90 * 48_000, zeroSample: 95 * 48_000)
        let fitted = wild.fitted(toLength: length)
        #expect(fitted.keptSamples(ofLength: length) == 59 * 48_000..<length)
        #expect(fitted.zeroSample == 59 * 48_000)
    }

    // MARK: A marked stretch

    @Test func aMarkedStretchIsHeldToWhatIsLeftOfTheSong() {
        var project = Project(songName: "Song", songLengthSamples: length)
        // Nothing is cut: a stretch is held inside the song.
        #expect(project.keptPart(of: 8...14) == 8...14)
        #expect(project.keptPart(of: -3...70) == 0...60)
        // The first ten seconds and the last ten are cut away.
        project.songPlace = SongPlace(cutStartSamples: 10 * 48_000, cutEndSamples: 10 * 48_000)
        #expect(project.keptPart(of: 8...14) == 10...14)
        #expect(project.keptPart(of: 45...58) == 45...50)
        #expect(project.keptPart(of: 2...58) == 10...50)
        #expect(project.keptPart(of: 20...30) == 20...30)
        // Nothing of it is left.
        #expect(project.keptPart(of: 2...9) == nil)
        #expect(project.keptPart(of: 2...10) == nil)
        #expect(project.keptPart(of: 50...58) == nil)
        // The same for a song dragged left so that 00:00 lies twenty seconds into it.
        project.songPlace = SongPlace().moved(bySamples: -20 * 48_000, ofLength: length)
        #expect(project.keptPart(of: 8...24) == 20...24)
        #expect(project.keptPart(of: 8...14) == nil)
    }

    // MARK: Older projects

    @Test func aProjectSavedBeforeTheSongCouldBeCutOpensAsItWas() throws {
        let old = try JSONDecoder().decode(
            Project.self, from: Data(#"{"songName":"Old","songLengthSamples":2880000,"version":1}"#.utf8))
        #expect(old.songPlace == SongPlace())
        #expect(old.keptSamples == 0..<2_880_000)
    }

    @Test func aSavedStartBeforeTheResolveTimelineBecomesACut() throws {
        // Saved by phase 24.5: the song starts 300 frames (12 seconds at 25) before the timeline does.
        let json = #"{"songLengthSamples":2880000,"resolve":{"timelineStart":"01:00:00:00","frameRate":"25","songOffsetFrames":-300}}"#
        let old = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(old.songPlace == SongPlace(cutStartSamples: 576_000, zeroSample: 576_000))
        #expect(old.resolveSongStart.text == "00:59:48:00")
        // A clip twelve seconds into the song still starts on the first frame of the timeline.
        let frame = old.resolve.startFrame(forTimelineSample: old.songPlace.timelineSample(forSong: 576_000))
        #expect(old.resolve.timecode(frame: frame).text == "01:00:00:00")
        // Saved again, it is read back the same, now from its own field.
        let again = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(old))
        #expect(again == old)
    }

    @Test func aSavedStartAfterTheResolveTimelineKeepsEveryTimecode() throws {
        let json = #"{"songLengthSamples":2880000,"resolve":{"frameRate":"25","songOffsetFrames":50}}"#
        let old = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(old.songPlace == SongPlace(zeroSample: -96_000))
        #expect(old.keptSamples == 0..<2_880_000)
        #expect(old.resolve.startFrame(forTimelineSample: old.songPlace.timelineSample(forSong: 0)) == 50)
        // The timeline still starts with the song's first sample, which now reads 0:02.
        #expect(old.songPlace.shownSeconds(ofLength: old.songLengthSamples) == 0...60)
        #expect(old.songPlace.timelineSeconds(forSong: 0) == 2)
    }

    @Test func theCutIsSavedWithTheProject() throws {
        var project = Project(songName: "Song", songLengthSamples: length)
        project.songPlace = SongPlace(cutStartSamples: 48_000, cutEndSamples: 96_000, zeroSample: 24_000)
        let read = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(read == project)
    }

    // MARK: The click

    @Test func theClickFileStartsAtZeroAndEndsWithWhatIsLeft() {
        let row = (0..<10).map(Float.init)
        #expect(SongPlace().timelineRow(of: row, ofLength: 10) == row)
        let cut = SongPlace(cutStartSamples: 4, cutEndSamples: 3, zeroSample: 2)
        #expect(cut.timelineRow(of: row, ofLength: 10) == [2, 3, 4, 5, 6])
        // A song that starts after 00:00 gets silence up to its first sample.
        #expect(SongPlace(zeroSample: -2).timelineRow(of: row, ofLength: 10) == [0, 0] + row)
    }

    @Test func nothingClicksWhereTheSongIsCutAway() {
        // A beat every half second for ten seconds.
        let grid = Grid(beats: (0..<20).map { Beat(number: $0, time: Double($0) * 0.5) })
        let length = 10 * 48_000
        let whole = ClickRenderer.render(grid: grid, settings: ClickSettings(), lengthSamples: length)
        let kept = 2 * 48_000..<6 * 48_000 + 100
        let cut = ClickRenderer.render(grid: grid, settings: ClickSettings(), lengthSamples: length, keeping: kept)
        #expect(cut.count == length)
        #expect(cut[..<kept.lowerBound].allSatisfy { $0 == 0 })
        #expect(cut[kept.upperBound...].allSatisfy { $0 == 0 })
        // Inside, every click is the one the whole song has, the one on the new start included.
        #expect(Array(cut[kept]) == Array(whole[kept]))
        #expect(cut[kept.lowerBound..<kept.lowerBound + 480].contains { $0 != 0 })
    }
}

import Foundation
import Testing
@testable import LockstepCore

@Suite("ProjectView")
struct ProjectViewTests {
    /// An empty project folder in a temporary place, and the folder to remove afterwards.
    private func makePackage() throws -> (package: ProjectPackage, folder: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockstep-view-tests-\(UUID().uuidString)", isDirectory: true)
        let package = ProjectPackage(url: folder.appendingPathComponent("Song.lockstep", isDirectory: true))
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
        return (package, folder)
    }

    private func makeView() -> ProjectView {
        ProjectView(
            pointsPerSecond: 87.5,
            scrollOffsetSeconds: 41.25,
            rowsScrollPoints: 120,
            trackHeight: 96.4,
            playheadSeconds: 63.512,
            selectedTrackID: UUID(),
            selectedClipIDs: [UUID(), UUID()]
        )
    }

    @Test func aViewComesBackExactlyAsItWasWritten() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let view = makeView()

        try package.write(view)

        #expect(package.readView() == view)
    }

    @Test func itIsKeptBesideTheProjectAsReadableText() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }

        try package.write(makeView())

        #expect(package.viewFile.lastPathComponent == "view.json")
        #expect(package.viewFile.deletingLastPathComponent() == package.url)
        let text = try String(contentsOf: package.viewFile, encoding: .utf8)
        #expect(text.contains("\"pointsPerSecond\" : 87.5"))
        #expect(text.contains("\"playheadSeconds\" : 63.512"))
        // Nothing is left of the file it was written through.
        #expect(!FileManager.default.fileExists(atPath: package.temporaryViewFile.path))
    }

    @Test func aLaterWriteTakesThePlaceOfTheEarlierOne() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        var view = makeView()
        try package.write(view)

        view.playheadSeconds = 12
        view.selectedClipIDs = []
        try package.write(view)

        #expect(package.readView() == view)
    }

    @Test func theSameSelectionAlwaysGivesTheSameText() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clips = (0..<5).map { _ in UUID() }

        try package.write(ProjectView(trackHeight: 80, selectedClipIDs: clips))
        let first = try Data(contentsOf: package.viewFile)
        try package.write(ProjectView(trackHeight: 80, selectedClipIDs: clips.reversed()))

        #expect(try Data(contentsOf: package.viewFile) == first)
    }

    @Test func aProjectFromBeforeHasNoView() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(package.readView() == nil)
    }

    @Test func aDamagedViewIsPassedOver() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data("{ \"pointsPerSecond\": ".utf8).write(to: package.viewFile)
        #expect(package.readView() == nil)

        // A view missing a field is as good as none.
        try Data("{ \"pointsPerSecond\": 40 }".utf8).write(to: package.viewFile)
        #expect(package.readView() == nil)
    }

    @Test func fieldsALaterLockstepAddsAreSkipped() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = """
            {
              "inspectorWidth" : 300,
              "playheadSeconds" : 7,
              "pointsPerSecond" : 20,
              "rowsScrollPoints" : 0,
              "scrollOffsetSeconds" : 3,
              "selectedClipIDs" : [],
              "trackHeight" : 72
            }
            """
        try Data(text.utf8).write(to: package.viewFile)

        let view = try #require(package.readView())
        #expect(view.pointsPerSecond == 20)
        #expect(view.selectedTrackID == nil)
        // A view from before the in and out were kept has neither.
        #expect(view.loopInOut == nil)
    }

    @Test func theLoopsInAndOutAreKeptAsReadableText() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }

        try package.write(ProjectView(trackHeight: 80, loopInOut: LoopInOut(inTime: 12.5, outTime: 31.75)))
        #expect(package.readView()?.loopInOut == LoopInOut(inTime: 12.5, outTime: 31.75))
        let text = try String(contentsOf: package.viewFile, encoding: .utf8)
        #expect(text.contains("\"loopInSeconds\" : 12.5"))
        #expect(text.contains("\"loopOutSeconds\" : 31.75"))

        // An in without an out comes back without one.
        try package.write(ProjectView(trackHeight: 80, loopInOut: LoopInOut(inTime: 4)))
        #expect(package.readView()?.loopInOut == LoopInOut(inTime: 4))
        #expect(try !String(contentsOf: package.viewFile, encoding: .utf8).contains("loopOutSeconds"))
    }
}

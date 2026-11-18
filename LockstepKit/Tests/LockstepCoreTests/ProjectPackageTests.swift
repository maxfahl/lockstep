import Foundation
import Testing
@testable import LockstepCore

@Suite("ProjectPackage")
struct ProjectPackageTests {
    /// A project folder in a temporary place, with an empty `song.wav` in it, and the
    /// folder to remove when the test is done.
    private func makePackage() throws -> (package: ProjectPackage, folder: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockstep-package-tests-\(UUID().uuidString)", isDirectory: true)
        let package = ProjectPackage(url: folder.appendingPathComponent("Song.lockstep", isDirectory: true))
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
        try Data().write(to: package.url.appendingPathComponent(ProjectPackage.songFileName))
        return (package, folder)
    }

    /// A project with something in every field.
    private func makeProject() -> Project {
        let beats = (0..<8).map { Beat(number: $0, time: 0.1 + Double($0) * 0.683_337, estimated: $0 == 5) }
        let grid = Grid(
            beats: beats,
            barStartNumber: 3,
            anchors: [Anchor(from: 1.4666, to: 1.5)],
            tempoLevel: .doubled,
            beatOne: 2.149_674
        )
        return Project(
            songName: "Weighted Silence",
            songLengthSamples: 10_176_000,
            grid: grid,
            click: ClickSettings(isOn: true, sound: .cowbell, volume: 0.35, division: .halfBeats)
        )
    }

    private func write(_ text: String, to package: ProjectPackage) throws {
        try Data(text.utf8).write(to: package.projectFile)
    }

    @Test func aProjectComesBackExactlyAsItWasSaved() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = makeProject()
        try package.write(project)
        #expect(try package.read() == project)
    }

    @Test func aProjectWithoutBeatsComesBackWithoutBeats() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = Project(songName: "New", songLengthSamples: 48_000)
        try package.write(project)
        let read = try package.read()
        #expect(read == project)
        #expect(read.grid == nil)
    }

    @Test func theSavedTextIsIndentedWithItsKeysInOrder() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        try package.write(makeProject())
        let text = try String(contentsOf: package.projectFile, encoding: .utf8)
        #expect(text.hasPrefix("{\n  \"click\""))
        #expect(text.contains("\n  \"version\" : 1"))
        let keys = ["\"click\"", "\"grid\"", "\"songFile\"", "\"songLengthSamples\"", "\"songName\"", "\"version\""]
        let places = try keys.map { try #require(text.range(of: "\n  \($0)") ?? text.range(of: "{\n  \($0)")).lowerBound }
        #expect(places == places.sorted())
    }

    @Test func aProjectSavedBeforeTheClickExistedGetsTheDefaultClick() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(#"{ "version": 1, "songName": "Old", "songFile": "song.wav", "songLengthSamples": 96000 }"#, to: package)
        let project = try package.read()
        #expect(project.songName == "Old")
        #expect(project.songLengthSamples == 96_000)
        #expect(project.click == ClickSettings())
        #expect(project.grid == nil)
    }

    @Test func missingFieldsInsideTheBeatsAndTheClickGetTheirDefaults() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(
            #"""
            {
              "songName": "Old",
              "grid": { "beats": [ { "number": 0, "time": 0.5 }, { "number": 1, "time": 1.0, "estimated": true } ] },
              "click": { "isOn": true }
            }
            """#,
            to: package
        )
        let project = try package.read()
        #expect(project.version == 1)
        #expect(project.songFile == "song.wav")
        #expect(project.grid == Grid(beats: [Beat(number: 0, time: 0.5), Beat(number: 1, time: 1.0, estimated: true)]))
        #expect(project.click == ClickSettings(isOn: true))
    }

    @Test func aFieldThisLockstepDoesNotKnowIsSkipped() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(
            #"""
            {
              "version": 1,
              "songName": "Later",
              "songLengthSamples": 48000,
              "tracks": [ { "name": "Track 1", "clips": [] } ],
              "click": { "isOn": false, "pan": 0.5 },
              "grid": { "beats": [], "swing": 0.2 }
            }
            """#,
            to: package
        )
        let project = try package.read()
        #expect(project.songName == "Later")
        #expect(project.click == ClickSettings())
        #expect(project.grid == Grid())
    }

    @Test func aProjectFromANewerLockstepIsRefusedWithItsOwnMessage() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        // What a newer version holds may be impossible to read. It is still "newer", not "damaged".
        let newer = #"{ "version": 2, "songName": 7, "click": "loud" }"#
        try write(newer, to: package)
        #expect(throws: ProjectPackageError.newerVersion) { try package.read() }
        #expect(ProjectPackageError.newerVersion.message == "This project was made by a newer Lockstep.")
        // Refusing a project changes nothing in it.
        #expect(try String(contentsOf: package.projectFile, encoding: .utf8) == newer)
    }

    @Test func aSaveThatWasCutShortLeavesTheOldProjectWhole() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = makeProject()
        try package.write(saved)
        // Lockstep was killed while writing: only the file beside project.json got half of the new text.
        try Data(#"{ "version": 1, "songName": "Half wri"#.utf8).write(to: package.temporaryProjectFile)
        #expect(try package.read() == saved)

        // The next save is not stopped by what was left behind, and clears it away.
        var changed = saved
        changed.click.isOn = false
        try package.write(changed)
        #expect(try package.read() == changed)
        #expect(!FileManager.default.fileExists(atPath: package.temporaryProjectFile.path))
    }

    @Test func eachWayOfFailingToOpenIsToldApart() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }

        let gone = ProjectPackage(url: folder.appendingPathComponent("Gone.lockstep"))
        #expect(throws: ProjectPackageError.notFound) { try gone.read() }

        // The folder is there, project.json is not.
        #expect(throws: ProjectPackageError.unreadable) { try package.read() }
        try write("this is not a project", to: package)
        #expect(throws: ProjectPackageError.unreadable) { try package.read() }
        try write(#"{ "version": 1, "songLengthSamples": "long" }"#, to: package)
        #expect(throws: ProjectPackageError.unreadable) { try package.read() }

        try package.write(makeProject())
        try FileManager.default.removeItem(at: package.url.appendingPathComponent(ProjectPackage.songFileName))
        #expect(throws: ProjectPackageError.songMissing) { try package.read() }
    }

    @Test func savingIntoAFolderThatIsGoneFails() throws {
        let (package, folder) = try makePackage()
        try FileManager.default.removeItem(at: folder)
        #expect(throws: (any Error).self) { try package.write(makeProject()) }
    }

    @Test func aProjectIsKnownByItsEnding() {
        #expect(ProjectPackage.isProject(URL(fileURLWithPath: "/tmp/Song.lockstep")))
        #expect(ProjectPackage.isProject(URL(fileURLWithPath: "/tmp/Song.LOCKSTEP/")))
        #expect(!ProjectPackage.isProject(URL(fileURLWithPath: "/tmp/Song.m4a")))
        #expect(!ProjectPackage.isProject(URL(fileURLWithPath: "/tmp/Song.lockstep/song.wav")))
    }
}

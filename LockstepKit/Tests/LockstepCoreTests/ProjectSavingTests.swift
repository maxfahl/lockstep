import Foundation
import Testing
@testable import LockstepCore

@Suite("Saving projects")
@MainActor
struct ProjectSavingTests {
    /// A folder for projects in a temporary place. It does not exist yet.
    private func makeProjectsFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lockstep-saving-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
    }

    private func remove(_ projectsFolder: URL) {
        try? FileManager.default.removeItem(at: projectsFolder.deletingLastPathComponent())
    }

    private func makeProject(named name: String = "Song") -> Project {
        let beats = (0..<8).map { Beat(number: $0, time: Double($0) * 0.5) }
        return Project(songName: name, songLengthSamples: 192_000, grid: Grid(beats: beats))
    }

    /// Stands in for the song: a few bytes that can be recognised afterwards.
    private func song(_ text: String) -> (URL) throws -> Void {
        { url in try Data(text.utf8).write(to: url) }
    }

    private func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// A store with a new project on disk, which saves `delay` after a change.
    private func makeStore(in folder: URL, delay: Duration) throws -> (store: ProjectStore, package: ProjectPackage) {
        let project = makeProject()
        let package = try ProjectPackage.create(project, in: folder, writeSong: song("sound"))
        let store = ProjectStore(saveDelay: delay)
        store.open(project, in: package)
        return (store, package)
    }

    // MARK: Making a project

    @Test func aNewProjectHasEveryPartOfTheLayout() throws {
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        let project = makeProject(named: "Weighted Silence")
        let package = try ProjectPackage.create(project, in: folder, writeSong: song("the song"))

        #expect(package.url.standardizedFileURL == folder.appendingPathComponent("Weighted Silence.lockstep").standardizedFileURL)
        #expect(isFolder(package.url))
        #expect(try package.read() == project)
        #expect(try Data(contentsOf: package.url.appendingPathComponent("song.wav")) == Data("the song".utf8))
        #expect(isFolder(package.url.appendingPathComponent("takes")))
        #expect(isFolder(package.url.appendingPathComponent("exports")))
        #expect(isFolder(package.url.appendingPathComponent("cache")))
        let contents = try FileManager.default.contentsOfDirectory(atPath: package.url.path).sorted()
        #expect(contents == ["cache", "exports", "project.json", "song.wav", "takes"])
    }

    @Test func aSecondSongWithTheSameNameGetsItsOwnNumberedProject() throws {
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        let first = try ProjectPackage.create(makeProject(), in: folder, writeSong: song("first"))
        let second = try ProjectPackage.create(makeProject(), in: folder, writeSong: song("second"))
        let third = try ProjectPackage.create(makeProject(), in: folder, writeSong: song("third"))

        #expect(first.url.lastPathComponent == "Song.lockstep")
        #expect(second.url.lastPathComponent == "Song 2.lockstep")
        #expect(third.url.lastPathComponent == "Song 3.lockstep")
        // The song keeps its name inside each of them, and none was written over.
        #expect(try second.read().songName == "Song")
        #expect(try Data(contentsOf: first.url.appendingPathComponent("song.wav")) == Data("first".utf8))
        #expect(try Data(contentsOf: second.url.appendingPathComponent("song.wav")) == Data("second".utf8))
        #expect(try Data(contentsOf: third.url.appendingPathComponent("song.wav")) == Data("third".utf8))

        // A number that became free again is used before a higher one.
        try FileManager.default.removeItem(at: second.url)
        let again = try ProjectPackage.create(makeProject(), in: folder, writeSong: song("again"))
        #expect(again.url.lastPathComponent == "Song 2.lockstep")
    }

    @Test func aProjectThatCouldNotBeMadeLeavesNothingBehind() throws {
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        struct DiskFull: Error {}
        #expect(throws: DiskFull.self) {
            try ProjectPackage.create(makeProject(), in: folder) { _ in throw DiskFull() }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        // The name is still free for the next try.
        let package = try ProjectPackage.create(makeProject(), in: folder, writeSong: song("sound"))
        #expect(package.url.lastPathComponent == "Song.lockstep")
    }

    @Test func aSongNameBecomesAUsableFolderName() {
        #expect(ProjectPackage.folderName(for: "Weighted Silence") == "Weighted Silence")
        #expect(ProjectPackage.folderName(for: "AC/DC: Live") == "AC-DC- Live")
        #expect(ProjectPackage.folderName(for: "  ") == "Untitled")
    }

    // MARK: Saving by itself

    @Test func twoQuickEditsGiveOneWrite() async throws {
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        let (store, package) = try makeStore(in: folder, delay: .milliseconds(200))
        let before = try package.read()

        store.edit("Halve Tempo") { $0.grid?.tempoLevel = .halved }
        store.edit("Turn Click On") { $0.click.isOn = true }
        // Nothing is written at once.
        #expect(store.saveCount == 0)
        #expect(try package.read() == before)

        let deadline = ContinuousClock.now + .seconds(10)
        while store.saveCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Long enough for a second write, had one been waiting.
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.saveCount == 1)
        let saved = try package.read()
        #expect(saved == store.project)
        #expect(saved.grid?.tempoLevel == .halved)
        #expect(saved.click.isOn)

        // A later edit is written again, on its own.
        store.edit("Turn Click Off") { $0.click.isOn = false }
        store.close()
        #expect(store.saveCount == 2)
        #expect(try package.read().click.isOn == false)
    }

    @Test func theWriteThatComesByItselfIsOfTheProjectAsItWasThenAndALaterChangeIsWrittenToo() async throws {
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        let (store, package) = try makeStore(in: folder, delay: .milliseconds(50))
        store.edit("Turn Click On") { $0.click.isOn = true }
        let deadline = ContinuousClock.now + .seconds(10)
        while store.saveCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try package.read().click.isOn)
        // A change right after it gets a write of its own, and closing has nothing left to write.
        store.edit("Halve Tempo") { $0.grid?.tempoLevel = .halved }
        while store.saveCount == 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.saveCount == 2)
        #expect(try package.read() == store.project)
        store.close()
        #expect(store.saveCount == 2)
    }

    @Test func closingRightAfterAChangeLeavesTheNewestProjectOnDisk() async throws {
        // Many times, so that closing sometimes meets the write that came by itself while it is going on,
        // sometimes comes before it and sometimes after. Whichever it is, what is on disk when `close()`
        // returns is the project as it is.
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        let (store, package) = try makeStore(in: folder, delay: .milliseconds(1))
        for round in 0..<40 {
            store.edit("Move Beat") { $0.grid?.anchors.append(Anchor(from: Double(round), to: Double(round) + 0.02)) }
            try await Task.sleep(for: .microseconds(200 * (round % 12)))
            store.edit("Turn Click") { $0.click.isOn.toggle() }
            store.close()
            #expect(try package.read() == store.project)
        }
        // Writes that were still on their way have nothing newer than that.
        try await Task.sleep(for: .milliseconds(100))
        #expect(try package.read() == store.project)
        #expect(store.saveCount <= 80)
    }

    @Test func theLineOfWritesNeverPutsAnOlderProjectOverANewerOne() throws {
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        var project = makeProject()
        let package = try ProjectPackage.create(project, in: folder, writeSong: song("sound"))
        let line = ProjectWriteLine()
        var newer = project
        newer.click.isOn = true
        #expect(try line.write(newer, numbered: 5, to: package))
        // The older change arrives late, as from a write that was started before and got its turn after.
        project.songName = "older"
        #expect(try line.write(project, numbered: 4, to: package) == false)
        #expect(try line.write(newer, numbered: 5, to: package) == false)
        #expect(try package.read() == newer)
        // Another project's folder has its own numbers.
        let other = try ProjectPackage.create(project, in: folder, writeSong: song("sound"))
        #expect(try line.write(project, numbered: 1, to: other))
        #expect(try other.read() == project)
    }

    @Test func recordingsThatAreForgottenAreWrittenWhenClosing() throws {
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        let (store, package) = try makeStore(in: folder, delay: .seconds(3_600))
        store.edit("Record") { project in
            _ = project.addRecording(
                Recording(lengthSamples: 48_000, rawStart: 1), samples: 0..<48_000, asClipOn: project.tracks[0].id, voices: .none
            )
        }
        store.edit("Delete Clip") { $0.removeClips(Set($0.tracks[0].clips.map(\.id))) }
        store.close()
        #expect(try package.read().recordings.count == 1)
        // Nothing has changed since that write but the recordings that are taken out.
        #expect(store.forgetUnusedRecordings().count == 1)
        store.close()
        #expect(try package.read().recordings.isEmpty)
    }

    @Test func closingWritesWhatIsStillWaiting() throws {
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        let (store, package) = try makeStore(in: folder, delay: .seconds(3_600))
        store.edit("Move Beat") { $0.grid?.anchors.append(Anchor(from: 1.0, to: 1.02)) }
        #expect(try package.read().grid?.anchors.isEmpty == true)

        store.close()
        #expect(store.saveCount == 1)
        #expect(try package.read() == store.project)
        #expect(try package.read().grid?.anchors == [Anchor(from: 1.0, to: 1.02)])

        // With nothing waiting, closing writes nothing.
        store.close()
        #expect(store.saveCount == 1)
    }

    @Test func undoRedoAndWhatLockstepWorksOutAreSavedToo() throws {
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        let (store, package) = try makeStore(in: folder, delay: .seconds(3_600))
        store.edit("Halve Tempo") { $0.grid?.tempoLevel = .halved }
        store.close()
        #expect(try package.read().grid?.tempoLevel == .halved)

        store.undo()
        store.close()
        #expect(try package.read().grid?.tempoLevel == .normal)

        store.redo()
        store.close()
        #expect(try package.read().grid?.tempoLevel == .halved)

        store.setDerived { $0.grid?.barStartNumber = 2 }
        store.close()
        #expect(try package.read().grid?.barStartNumber == 2)
        #expect(store.saveCount == 4)
    }

    @Test func switchingProjectsWritesTheOldOneFirst() throws {
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        let (store, first) = try makeStore(in: folder, delay: .seconds(3_600))
        store.edit("Turn Click On") { $0.click.isOn = true }

        let other = makeProject(named: "Other")
        let second = try ProjectPackage.create(other, in: folder, writeSong: song("other"))
        store.open(other, in: second)

        #expect(try first.read().click.isOn)
        #expect(store.package == second)
        // The new project was only opened, so it is not written.
        #expect(store.saveCount == 1)
        store.close()
        #expect(store.saveCount == 1)
        #expect(try second.read() == other)
    }

    @Test func aFailedSaveKeepsTheChangesAndTheNextOneTriesAgain() throws {
        let folder = makeProjectsFolder()
        defer { remove(folder) }
        let (store, package) = try makeStore(in: folder, delay: .seconds(3_600))
        var failures = 0
        store.saveFailed = { _ in failures += 1 }

        // The project's folder is taken away while it is open.
        let aside = folder.appendingPathComponent("aside")
        try FileManager.default.moveItem(at: package.url, to: aside)
        store.edit("Turn Click On") { $0.click.isOn = true }
        store.close()
        #expect(failures == 1)
        #expect(store.saveCount == 0)
        #expect(store.project.click.isOn)
        // Without a new change, nothing is tried again and nothing is reported twice.
        #expect(!FileManager.default.fileExists(atPath: package.url.path))

        // The folder is back. The next edit saves both changes.
        try FileManager.default.moveItem(at: aside, to: package.url)
        store.edit("Halve Tempo") { $0.grid?.tempoLevel = .halved }
        store.close()
        #expect(failures == 1)
        #expect(store.saveCount == 1)
        let saved = try package.read()
        #expect(saved.click.isOn)
        #expect(saved.grid?.tempoLevel == .halved)
    }

    @Test func aProjectWithoutAPlaceOnDiskIsNeverWritten() {
        let store = ProjectStore(project: makeProject(), saveDelay: .milliseconds(1))
        var failures = 0
        store.saveFailed = { _ in failures += 1 }
        store.edit("Turn Click On") { $0.click.isOn = true }
        store.close()
        #expect(store.saveCount == 0)
        #expect(failures == 0)
    }
}

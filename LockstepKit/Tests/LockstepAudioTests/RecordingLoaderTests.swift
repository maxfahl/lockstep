import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// Reading recordings back from a project's `takes` folder. The files are written by `WavWriter`, which is what
/// the recorder writes them with.
@Suite("RecordingLoader")
struct RecordingLoaderTests {
    /// A project folder in a temporary place with an empty `takes` folder in it, and the folder to remove when
    /// the test is done.
    private func makePackage() throws -> (package: ProjectPackage, folder: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockstep-recording-loader-tests-\(UUID().uuidString)", isDirectory: true)
        let package = ProjectPackage(url: folder.appendingPathComponent("Song.lockstep", isDirectory: true))
        try FileManager.default.createDirectory(at: package.takesFolder, withIntermediateDirectories: true)
        return (package, folder)
    }

    /// Sound whose samples say where they are, in steps a 24-bit file holds exactly.
    private func voice(samples count: Int) -> [Float] {
        (0..<count).map { Float($0 + 1) / 131_072 }
    }

    @Test("A recording file reads back sample for sample")
    func readsARecording() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = Recording(lengthSamples: 4_801)
        let sound = voice(samples: 4_801)
        try WavWriter.write(sound, channels: 1, to: package.url.appendingPathComponent(recording.file))

        #expect(try RecordingLoader.read(package.url.appendingPathComponent(recording.file)) == sound)
    }

    @Test("Of a file with two channels the first is kept")
    func keepsTheFirstChannel() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = package.takesFolder.appendingPathComponent("stereo.wav")
        let left = voice(samples: 1_000)
        try WavWriter.write(left.flatMap { [$0, -$0] }, channels: 2, to: url)

        #expect(try RecordingLoader.read(url) == left)
    }

    @Test("A missing file and a file that is not sound are refused")
    func refusesWhatCannotBeRead() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = package.takesFolder.appendingPathComponent("missing.wav")
        let broken = package.takesFolder.appendingPathComponent("broken.wav")
        try Data("not a sound file".utf8).write(to: broken)

        #expect(throws: RecordingLoadError.unreadableFile) { try RecordingLoader.read(missing) }
        #expect(throws: RecordingLoadError.unreadableFile) { try RecordingLoader.read(broken) }
    }

    @Test("All recordings of a project are read by id, and one without a file is left out")
    func readsAllRecordingsOfAProject() async throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Recording(lengthSamples: 2_000)
        let second = Recording(lengthSamples: 500)
        let lost = Recording(lengthSamples: 500)
        try WavWriter.write(voice(samples: 2_000), channels: 1, to: package.url.appendingPathComponent(first.file))
        try WavWriter.write(voice(samples: 500), channels: 1, to: package.url.appendingPathComponent(second.file))

        let sounds = await RecordingLoader.readAll(of: Project(recordings: [first, second, lost]), in: package)
        #expect(sounds == [first.id: voice(samples: 2_000), second.id: voice(samples: 500)])
    }
}

import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

@Suite("BeatCache files")
struct BeatCacheFilesTests {
    /// An empty project folder in a temporary place, and the folder to remove afterwards.
    private func makePackage() throws -> (package: ProjectPackage, folder: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockstep-cache-tests-\(UUID().uuidString)", isDirectory: true)
        let package = ProjectPackage(url: folder.appendingPathComponent("Song.lockstep", isDirectory: true))
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
        return (package, folder)
    }

    /// A cache with awkward numbers in it: ones that have no short decimal form.
    private func makeCache() -> BeatCache {
        let logits = (0..<400).map { Float(sin(Double($0) * 0.37)) * 11.3 - 4.1 }
        let beats = (0..<12).map { 0.123_456_789 + Double($0) * 0.683_337_1 }
        let onsets = (0..<3_000).map { Float(abs(cos(Double($0) * 0.011))) * 7.7 }
        return BeatCache(
            model: BeatModelOutput(logits: logits, beats: beats, barStarts: [beats[1], beats[5], beats[9]]),
            onsets: OnsetCurve(values: onsets)
        )
    }

    @Test func aCacheComesBackExactlyAsItWasWritten() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = makeCache()
        try cache.write(to: package)
        #expect(FileManager.default.fileExists(atPath: package.beatsRawFile.path))
        #expect(FileManager.default.fileExists(atPath: package.onsetFile.path))
        #expect(BeatCache.read(from: package) == cache)
    }

    @Test func aFittingFromTheReadCacheGivesTheSameBeats() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = makeCache()
        try cache.write(to: package)
        let read = try #require(BeatCache.read(from: package))
        let anchors = [Anchor(from: cache.model.beats[3], to: cache.model.beats[3] + 0.02)]
        let before = BeatFinder.refit(cache: cache, settings: .defaults, anchors: anchors, tempoLevel: .normal, beatOne: nil)
        let after = BeatFinder.refit(cache: read, settings: .defaults, anchors: anchors, tempoLevel: .normal, beatOne: nil)
        #expect(after == before)
    }

    @Test func valuesThatAreNotNumbersDoNotStopTheCache() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = BeatCache(
            model: BeatModelOutput(logits: [-.infinity, 1.5, .infinity, -2.25], beats: [0.5], barStarts: [0.5]),
            onsets: OnsetCurve(values: [0, 1, 2])
        )
        try cache.write(to: package)
        #expect(BeatCache.read(from: package) == cache)
    }

    @Test func aMissingOrDamagedCacheReadsAsNone() throws {
        let (package, folder) = try makePackage()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Nothing was written yet.
        #expect(BeatCache.read(from: package) == nil)

        let cache = makeCache()
        try cache.write(to: package)
        try FileManager.default.removeItem(at: package.onsetFile)
        #expect(BeatCache.read(from: package) == nil)

        try cache.write(to: package)
        try Data("not json".utf8).write(to: package.beatsRawFile)
        #expect(BeatCache.read(from: package) == nil)

        // A curve cut off in the middle of a value.
        try cache.write(to: package)
        try Data([1, 2, 3, 4, 5]).write(to: package.onsetFile)
        #expect(BeatCache.read(from: package) == nil)

        // Writing again repairs it, also when the whole cache folder was thrown away.
        try FileManager.default.removeItem(at: package.cacheFolder)
        try cache.write(to: package)
        #expect(BeatCache.read(from: package) == cache)
    }
}

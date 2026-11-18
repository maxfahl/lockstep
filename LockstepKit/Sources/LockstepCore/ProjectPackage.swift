import Foundation

/// A project on disk: one folder per song, which macOS shows as a single file.
///
/// ```
/// <Song name>.lockstep/
///   project.json     the Project value, as readable text
///   song.wav         the imported song, 48 kHz, 24-bit, stereo
///   takes/           recordings, from phase 9
///   exports/         files made for Resolve, from phase 22
///   cache/           what Lockstep worked out and can work out again
///     beats-raw.json   the beat model's answer
///     onset.f32        the onset curve
///     sped-up/         the sound of takes recorded slower, made as fast as the song
///     voices/          the voices of recordings on tracks with a Voice: <way>/<setting>/<recording id>.wav
/// ```
///
/// This type knows where everything lies and reads and writes `project.json`. It never
/// touches sound: `song.wav` and the cache files are written by `LockstepAudio`.
///
///     let package = ProjectPackage(url: folder.appendingPathComponent("Song.lockstep"))
///     let project = try package.read()
///     try package.write(project)
public struct ProjectPackage: Sendable, Hashable {
    /// What a project's name ends with.
    public static let fileExtension = "lockstep"
    /// The name of the kind of file, as the app's Info.plist declares it to macOS.
    public static let typeIdentifier = "se.maxfahl.lockstep.project"
    /// The name the song gets inside every new project.
    public static let songFileName = "song.wav"

    /// The project's folder.
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    /// True for a path that names a project, whether or not anything is there.
    public static func isProject(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

    // MARK: Where things lie

    public var projectFile: URL { url.appendingPathComponent("project.json") }
    public var takesFolder: URL { url.appendingPathComponent("takes", isDirectory: true) }
    public var exportsFolder: URL { url.appendingPathComponent("exports", isDirectory: true) }
    /// Everything in here can be thrown away. Lockstep makes it again.
    public var cacheFolder: URL { url.appendingPathComponent("cache", isDirectory: true) }
    public var beatsRawFile: URL { cacheFolder.appendingPathComponent("beats-raw.json") }
    public var onsetFile: URL { cacheFolder.appendingPathComponent("onset.f32") }
    /// The sped-up sound of every take that was recorded slower, one file per recording. Phase 31.
    public var spedUpFolder: URL { cacheFolder.appendingPathComponent("sped-up", isDirectory: true) }

    /// The sped-up sound of one take that was recorded slower.
    public func spedUpFile(forRecording id: UUID) -> URL {
        spedUpFolder.appendingPathComponent("\(id.uuidString).wav")
    }

    /// The made voices of the recordings on tracks that have a Voice. Phase 37.
    public var voicesFolder: URL { cacheFolder.appendingPathComponent("voices", isDirectory: true) }

    /// What the name of a voice's file ends with while it is being written.
    public static let partialVoiceExtension = "partial"

    /// The voice of one recording, made one way with one setting:
    /// `cache/voices/<way>/<setting>/<recording id>.wav`, for example
    /// `cache/voices/rubberband-r1/d+06p-1.0/<recording id>.wav`. A file that has this name is whole.
    public func voiceFile(for key: VoiceKey) -> URL {
        voiceSettingFolder(for: key).appendingPathComponent("\(key.recordingID.uuidString).wav")
    }

    /// Where one job writes that voice before it is checked and given its name:
    /// `<recording id>.<job id>.partial` in the same folder, so the move into place is one step and two jobs
    /// never write the same file.
    public func partialVoiceFile(for key: VoiceKey, job: UUID) -> URL {
        voiceSettingFolder(for: key).appendingPathComponent(
            "\(key.recordingID.uuidString).\(job.uuidString).\(Self.partialVoiceExtension)"
        )
    }

    /// The folder of one way and one setting.
    private func voiceSettingFolder(for key: VoiceKey) -> URL {
        voicesFolder
            .appendingPathComponent(key.way.folderName, isDirectory: true)
            .appendingPathComponent(key.knobs.folderName, isDirectory: true)
    }

    /// The song of a project, by the name the project gives it.
    public func songFile(of project: Project) -> URL {
        url.appendingPathComponent(project.songFile)
    }

    /// Where `project.json` is written before it takes the place of the old one.
    var temporaryProjectFile: URL { url.appendingPathComponent("project.json.tmp") }

    // MARK: Reading

    /// Reads the project.
    ///
    /// A field that is missing gets its default, and a field this Lockstep does not know
    /// is skipped, so projects from older and slightly newer versions open. Every failure
    /// is a `ProjectPackageError`, and nothing on disk is changed by reading.
    public func read() throws(ProjectPackageError) -> Project {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { throw .notFound }
        guard let data = try? Data(contentsOf: projectFile) else { throw .unreadable }
        let project = try Self.decode(data)
        guard files.fileExists(atPath: songFile(of: project).path) else { throw .songMissing }
        return project
    }

    /// Turns the text of a `project.json` into a project.
    static func decode(_ data: Data) throws(ProjectPackageError) -> Project {
        let decoder = JSONDecoder()
        // The version is looked at first and alone: a newer project may hold things that
        // cannot be read at all, and it should still be told apart from a damaged one.
        guard let header = try? decoder.decode(Header.self, from: data) else { throw .unreadable }
        if let version = header.version, version > Project.currentVersion { throw .newerVersion }
        guard let project = try? decoder.decode(Project.self, from: data) else { throw .unreadable }
        return project
    }

    private struct Header: Decodable {
        var version: Int?
    }

    // MARK: Writing

    /// Saves the project as `project.json`, in place of the one that was there.
    ///
    /// The text is first written to a file beside it and then moved into place in one
    /// step. If Lockstep is killed halfway, the old `project.json` is still whole.
    public func write(_ project: Project) throws {
        let data = try Self.encode(project)
        try data.write(to: temporaryProjectFile)
        guard rename(temporaryProjectFile.path, projectFile.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: projectFile.path,
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)),
            ])
        }
    }

    /// A project as the text of `project.json`: indented, with the keys in alphabetical
    /// order, so the same project always gives the same text and a person can read it.
    static func encode(_ project: Project) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(project)
    }
}

// MARK: Making a new project

extension ProjectPackage {
    /// Makes the project of a newly dropped song in `folder`, which is made too if it is
    /// missing: `<Song name>.lockstep`, or `<Song name> 2.lockstep`, then 3, when that name
    /// is taken. A project that is already there is never touched.
    ///
    /// The song itself is written by the caller, so that nothing here needs to know about
    /// sound: `writeSong` is handed the place where `song.wav` goes.
    ///
    ///     let package = try ProjectPackage.create(project, in: projectsFolder) { url in
    ///         try WavWriter.write(song.samples, channels: 2, to: url)
    ///     }
    ///
    /// If anything fails, what was made of the new project is removed again and the error
    /// is passed on.
    public static func create(
        _ project: Project,
        in folder: URL,
        writeSong: (URL) throws -> Void
    ) throws -> ProjectPackage {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = try makeFolder(named: project.songName, in: folder)
        do {
            for part in [package.takesFolder, package.exportsFolder, package.cacheFolder] {
                try files.createDirectory(at: part, withIntermediateDirectories: false)
            }
            // The song goes first: a project.json that can be read then always has its song.
            try writeSong(package.songFile(of: project))
            try package.write(project)
        } catch {
            try? files.removeItem(at: package.url)
            throw error
        }
        return package
    }

    /// Makes the empty folder of a new project under the first name that is free.
    ///
    /// The folder is made in the same step that finds the name free, so two songs with
    /// the same name can never end up in one project.
    private static func makeFolder(named songName: String, in folder: URL) throws -> ProjectPackage {
        let name = folderName(for: songName)
        var number = 1
        while true {
            let numbered = number == 1 ? name : "\(name) \(number)"
            let url = folder.appendingPathComponent("\(numbered).\(fileExtension)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return ProjectPackage(url: url)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                number += 1
            }
        }
    }

    /// A song's name as a folder name: without the two characters a file name cannot
    /// hold, and never empty.
    static func folderName(for songName: String) -> String {
        let name = songName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled" : name
    }
}

/// Why a project could not be opened.
public enum ProjectPackageError: Error, Equatable, Sendable {
    /// Nothing is at the project's place any more.
    case notFound
    /// `project.json` is missing, damaged, or not a project.
    case unreadable
    /// The project is there, but its song is not.
    case songMissing
    /// The project was saved by a Lockstep that is newer than this one.
    case newerVersion

    /// One plain sentence to show Max.
    public var message: String {
        switch self {
        case .notFound: "This project can no longer be found."
        case .unreadable: "Lockstep could not read this project."
        case .songMissing: "The song file of this project is missing."
        case .newerVersion: "This project was made by a newer Lockstep."
        }
    }
}

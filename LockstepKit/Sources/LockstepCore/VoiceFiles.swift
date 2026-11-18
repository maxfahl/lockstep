import Foundation

// Which made voices are kept on disk and which are removed when a project closes.
//
//     let listing = try FileManager.default.subpathsOfDirectory(atPath: package.voicesFolder.path)
//     for path in VoiceFiles.stale(in: listing, of: project) {
//         try? FileManager.default.removeItem(at: package.voicesFolder.appendingPathComponent(path))
//     }

/// The rule for what `cache/voices` of a project keeps.
public enum VoiceFiles {
    /// What is removed from a project's voices folder when the project closes, as paths inside that folder.
    /// It is worked out from a list of what is there, so it is tested without a disk.
    ///
    /// The folder is laid out as `<way>/<setting>/<recording id>.wav` (`ProjectPackage.voiceFile(for:)`).
    /// Removed are:
    /// - the folder of a way that is not current: a voice made another way is never heard again;
    /// - the folder of a setting that no track of the project has. A track's Voice counts whether it is on
    ///   or off, so switching a Voice off, closing the project and switching it on again makes nothing
    ///   twice. The folder of both knobs in the middle is never kept: nothing is made for that setting;
    /// - in a folder that is kept: a file a job left unfinished (`.partial`), and the voice of a recording
    ///   the project no longer holds.
    ///
    /// Everything else stays: the voice of every recording the project holds, for every setting a track has.
    /// A file in a kept folder that is none of Lockstep's (neither a `.partial` nor a `.wav` named by an id)
    /// is left alone.
    ///
    /// - Parameters:
    ///   - listing: what is in the voices folder, as paths inside it with "/" between the parts: the files,
    ///     with or without the folders themselves, in any order (`FileManager.subpathsOfDirectory` gives
    ///     exactly this). The first part of a path is taken as a way's folder, the second as a setting's.
    ///   - project: the project as it is closed.
    ///   - ways: the ways that are current. The Fast way alone when left out. With Natural, the Natural way
    ///     of the engine and the sample there are now is handed in beside it.
    /// - Returns: the paths to remove, each once and in alphabetical order. A folder that goes is named
    ///   alone, without what is in it.
    public static func stale(in listing: [String], of project: Project, ways: [VoiceWay] = [.fast]) -> [String] {
        let currentWays = Set(ways.map(\.folderName))
        var settings: Set<String> = []
        for track in project.tracks {
            if let knobs = track.voice?.knobs, !knobs.isNeutral { settings.insert(knobs.folderName) }
        }
        let held = Set(project.recordings.map(\.id))

        var stale: Set<String> = []
        for path in listing {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let way = parts.first else { continue }
            guard currentWays.contains(way) else {
                stale.insert(way)
                continue
            }
            guard parts.count >= 2 else { continue }
            let setting = parts[1]
            guard settings.contains(setting) else {
                stale.insert("\(way)/\(setting)")
                continue
            }
            // Only the files of the setting's own folder are Lockstep's to judge.
            guard parts.count == 3 else { continue }
            let file = parts[2]
            let name = file as NSString
            if name.pathExtension == ProjectPackage.partialVoiceExtension {
                stale.insert("\(way)/\(setting)/\(file)")
            } else if name.pathExtension == "wav", let id = UUID(uuidString: name.deletingPathExtension),
                      !held.contains(id) {
                stale.insert("\(way)/\(setting)/\(file)")
            }
        }
        return stale.sorted()
    }
}

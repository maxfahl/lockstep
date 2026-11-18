import Foundation
import LockstepCore

extension LaunchOptions {
    /// The folder exported clips are written to, as Settings has it, or nil when none is
    /// chosen and each project uses its own `exports` folder. Nothing on disk is touched.
    ///
    /// A scratch run keeps to its own folder: a folder from its settings counts only when
    /// it lies inside the scratch folder. Anything else counts as none, so an export of a
    /// scratch run lands in the scratch project and never in a folder of Max's.
    @MainActor
    func exportFolder(in settings: AppSettings) -> URL? {
        guard let chosen = settings.exportFolder else { return nil }
        guard let scratchFolder else { return chosen }
        return chosen.path.hasPrefix(scratchFolder.path + "/") ? chosen : nil
    }

    /// The folder the list of sent clips is written to, for the Lockstep script in DaVinci
    /// Resolve: `~/Library/Application Support/Lockstep/DaVinci`. The script looks for the
    /// list there and nowhere else, so the place is fixed and not a setting.
    ///
    /// A scratch run writes to `DaVinci` in its scratch folder. No script reads that list:
    /// it is there for the agent to read.
    var sendListFolder: URL {
        if let scratchFolder {
            return scratchFolder.appendingPathComponent("DaVinci", isDirectory: true)
        }
        return URL.applicationSupportDirectory.appending(path: "Lockstep/DaVinci", directoryHint: .isDirectory)
    }

    /// DaVinci Resolve's own folder for this user. Resolve makes it the first time it is
    /// opened, so a Mac without it has no Resolve to install a script into.
    ///
    /// A scratch run gets `DaVinci Resolve` in its scratch folder in its place, so pressing
    /// Install in an agent's run never writes into Max's Resolve.
    var resolveFolder: URL {
        if let scratchFolder {
            return scratchFolder.appendingPathComponent("DaVinci Resolve", isDirectory: true)
        }
        return URL.applicationSupportDirectory
            .appending(path: "Blackmagic Design/DaVinci Resolve", directoryHint: .isDirectory)
    }

    /// The folder in which Resolve looks for scripts to list under Workspace > Scripts.
    var resolveScriptsFolder: URL {
        resolveFolder.appending(path: "Fusion/Scripts", directoryHint: .isDirectory)
    }
}

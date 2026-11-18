import Foundation
import LockstepCore
import Observation

/// The Lockstep script in DaVinci Resolve, as the app sees it: whether it is installed and
/// is the one this Lockstep has, and installing it.
///
/// The script itself is `Lockstep.lua` in the app's bundle (`Lockstep/Resources/Lockstep.lua`
/// in the repository). Installing copies it into Resolve's folder of scripts
/// (`LaunchOptions.resolveScriptsFolder`), where Resolve lists it as Workspace > Scripts >
/// Lockstep the next time it starts.
///
/// Nothing is written unless `install` is called, and only the Install button in Settings >
/// DaVinci calls it. A scratch run writes into its scratch folder.
///
/// The Send part owns the one object (`SendModel.resolveScript`). Settings shows `status` and
/// `problem`, and the Send to DaVinci panel says what `status` means for the clips just sent.
@MainActor
@Observable
final class ResolveScriptInstall {
    /// Whether the script is in Resolve, as last looked at (`refresh`).
    private(set) var status: ResolveScript.Status
    /// Why the last Install did not work, in words for Max, or nil.
    private(set) var problem: String?
    /// Called when `status` has changed, so an open Send to DaVinci panel can say the new thing.
    @ObservationIgnored var changed: (@MainActor () -> Void)?

    init() {
        status = Self.statusOnDisk()
    }

    /// The script as this copy of Lockstep has it, or nil when the app was built without it.
    private static var script: Data? {
        guard let url = Bundle.main.url(forResource: "Lockstep", withExtension: "lua") else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func statusOnDisk() -> ResolveScript.Status {
        guard let script else { return .missing }
        return ResolveScript.status(of: script, inScriptsFolder: LaunchOptions.current.resolveScriptsFolder)
    }

    /// Looks again. The script can be removed or replaced from outside while Lockstep runs.
    func refresh() {
        let found = Self.statusOnDisk()
        guard found != status else { return }
        status = found
        changed?()
    }

    /// Install or Update was pressed: puts the script into Resolve's folder of scripts.
    ///
    /// For Max that folder must belong to a Resolve that has been opened at least once: Lockstep
    /// does not make Resolve's own folder, because a script in a folder Resolve never made would
    /// show as installed and never appear in any menu.
    func install() {
        let options = LaunchOptions.current
        let place = (ResolveScript.file(inScriptsFolder: options.resolveScriptsFolder).path as NSString)
            .abbreviatingWithTildeInPath
        defer { refresh() }
        guard let script = Self.script else {
            problem = "This copy of Lockstep has no script in it, so there is nothing to install."
            return
        }
        guard options.isScratch || FileManager.default.fileExists(atPath: options.resolveFolder.path) else {
            problem = "Lockstep found no DaVinci Resolve on this Mac. Open DaVinci Resolve once, then install again."
            return
        }
        do {
            try ResolveScript.install(script, inScriptsFolder: options.resolveScriptsFolder)
            problem = nil
            if options.isScratch {
                // For the agent that started this run and cannot see the pane.
                FileHandle.standardError.write(Data("Lockstep: installed the Resolve script at \(place)\n".utf8))
            }
        } catch {
            problem = "The script could not be written to \(place). \(error.localizedDescription)"
        }
    }
}

import Foundation

/// The Lockstep script as a file in DaVinci Resolve's folder of scripts: whether it is there, and putting it there.
///
/// Resolve lists the scripts it finds in `Fusion/Scripts` under Workspace > Scripts. A script in the `Utility`
/// folder there is listed on every page of Resolve, so `Utility/Lockstep.lua` shows as Workspace > Scripts >
/// Lockstep. Resolve reads the folder when it starts.
///
///     let folder = …/Blackmagic Design/DaVinci Resolve/Fusion/Scripts
///     ResolveScript.status(of: script, inScriptsFolder: folder)     // .missing
///     try ResolveScript.install(script, inScriptsFolder: folder)
///     ResolveScript.status(of: script, inScriptsFolder: folder)     // .current
///
/// `script` is the script as this copy of Lockstep has it. The app reads it from its own bundle and decides
/// which folder is meant, so nothing here knows where Max's Resolve is.
public enum ResolveScript {
    /// The script's file name. Resolve shows it in the menu without the ending.
    public static let fileName = "Lockstep.lua"
    /// The folder, inside Resolve's folder of scripts, whose scripts are listed on every page.
    public static let menuFolder = "Utility"

    public enum Status: Sendable, Equatable {
        /// There is no Lockstep script in Resolve.
        case missing
        /// The script in Resolve is the one this Lockstep has.
        case current
        /// There is a Lockstep script in Resolve, but another one: an older one, most likely.
        case different
    }

    /// Where the script lies in Resolve's folder of scripts.
    public static func file(inScriptsFolder folder: URL) -> URL {
        folder
            .appendingPathComponent(menuFolder, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Whether the script in Resolve's folder is this one, byte for byte.
    public static func status(of script: Data, inScriptsFolder folder: URL) -> Status {
        guard let installed = try? Data(contentsOf: file(inScriptsFolder: folder)) else { return .missing }
        return installed == script ? .current : .different
    }

    /// Puts the script into Resolve's folder, in place of a Lockstep script already there. The folders on the
    /// way are made when they are not there yet.
    public static func install(_ script: Data, inScriptsFolder folder: URL) throws {
        let url = file(inScriptsFolder: folder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: url, options: .atomic)
    }
}

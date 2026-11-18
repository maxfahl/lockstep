import AppKit
import Observation

/// The projects under File > Open Recent, newest first.
///
/// When Lockstep runs for Max this is the Mac's own list of recent documents for the
/// app, the one the Dock's menu shows too. A scratch run must neither show nor change
/// that list, so it keeps a list of its own in the scratch folder's settings.
///
///     recent.note(package.url)     // a project was opened
///     recent.urls                  // what the menu lists
///     recent.remove(url)           // the project is gone
///     recent.clear()               // Clear Menu
@MainActor
@Observable
final class RecentProjects {
    /// How many projects a scratch run's own list holds.
    private static let scratchLimit = 10
    private static let scratchKey = "recentProjectPaths"

    private(set) var urls: [URL]

    /// The scratch folder's settings, or nil when the Mac's own list is used.
    @ObservationIgnored private let scratchSettings: UserDefaults?

    /// - Parameter scratchSettings: the settings of a scratch run, or nil when Lockstep
    ///   runs for Max.
    init(scratchSettings: UserDefaults?) {
        self.scratchSettings = scratchSettings
        if let scratchSettings {
            urls = (scratchSettings.stringArray(forKey: Self.scratchKey) ?? []).map { URL(fileURLWithPath: $0) }
        } else {
            urls = NSDocumentController.shared.recentDocumentURLs
        }
    }

    /// Puts a project that was just opened at the top of the list.
    func note(_ url: URL) {
        let url = url.standardizedFileURL
        var listed = urls.filter { $0.standardizedFileURL != url }
        listed.insert(url, at: 0)
        if let scratchSettings {
            listed = Array(listed.prefix(Self.scratchLimit))
            scratchSettings.set(listed.map(\.path), forKey: Self.scratchKey)
        } else {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            listed = Array(listed.prefix(NSDocumentController.shared.maximumRecentDocumentCount))
        }
        urls = listed
    }

    /// Takes a project that no longer exists off the list.
    func remove(_ url: URL) {
        let url = url.standardizedFileURL
        let kept = urls.filter { $0.standardizedFileURL != url }
        guard kept.count != urls.count else { return }
        if let scratchSettings {
            scratchSettings.set(kept.map(\.path), forKey: Self.scratchKey)
        } else {
            // The Mac's list cannot drop one entry. It is emptied and the others are
            // put back, oldest first, so their order stays.
            NSDocumentController.shared.clearRecentDocuments(nil)
            for url in kept.reversed() {
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            }
        }
        urls = kept
    }

    /// Clear Menu: empties the list.
    func clear() {
        if let scratchSettings {
            scratchSettings.removeObject(forKey: Self.scratchKey)
        } else {
            NSDocumentController.shared.clearRecentDocuments(nil)
        }
        urls = []
    }
}

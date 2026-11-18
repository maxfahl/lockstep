import AppKit
import LockstepUI
import SwiftUI

@main
struct LockstepDesignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Lockstep Design", id: "main") {
            LabContent()
                .frame(
                    minWidth: DesignTokens.Sizes.minimumWindowWidth,
                    minHeight: DesignTokens.Sizes.minimumWindowHeight
                )
        }
        .defaultSize(width: 1200, height: 720)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `-windowSize 900x560` on the command line gives the main window that
    /// content size at start, so pictures can be taken at a known size.
    /// Without the argument nothing here changes the window.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let text = UserDefaults.standard.string(forKey: "windowSize") else { return }
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return }
        let size = NSSize(width: parts[0], height: parts[1])
        // The main window can appear a moment after the app has started, so
        // this looks for it again for up to two seconds.
        Task { @MainActor in
            for _ in 0..<40 {
                if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible }) {
                    window.setContentSize(size)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

import AppKit
import QuartzCore

/// Calls `onFrame` once for every frame the display shows, while it is running.
///
/// The playhead is moved from here while a song plays, so it moves with the
/// display and not with a timer of its own. It runs only while it is needed.
@MainActor
final class FrameTicker: NSObject {
    /// Called on the main thread, once per frame.
    var onFrame: (() -> Void)?

    private var link: CADisplayLink?

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        // The display the Lockstep window is on. It is asked from the screen and not
        // from the window, so the frames keep coming while the window is behind others.
        let window = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        guard let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        onFrame?()
    }
}

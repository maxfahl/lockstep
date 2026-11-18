import AppKit
import LockstepCore
import SwiftUI

extension View {
    /// The window showing this view opens with the size and place it had last time,
    /// fitted onto the screens that are there now. `name` keeps windows apart.
    func remembersWindowFrame(name: String) -> some View {
        background(WindowFrameMemory(name: name))
    }
}

/// An invisible view whose only job is to learn which window it is in.
private struct WindowFrameMemory: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> WindowFrameMemoryView {
        WindowFrameMemoryView(defaultsKey: "window.\(name).frame")
    }

    func updateNSView(_ nsView: WindowFrameMemoryView, context: Context) {}
}

private final class WindowFrameMemoryView: NSView {
    private let defaultsKey: String
    /// The frame Lockstep wants at launch. It is held until the window is on screen.
    private var launchFrame: NSRect?
    /// True until the window has been seen on screen. Until then every change to its
    /// frame comes from SwiftUI or macOS placing it, not from Max.
    private var isLaunching = true
    private var isApplyingFrame = false

    init(defaultsKey: String) {
        self.defaultsKey = defaultsKey
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let window else { return }

        isLaunching = !window.isVisible
        launchFrame = fittedSavedFrame(for: window)
        applyLaunchFrame(to: window)

        center.addObserver(self, selector: #selector(windowFrameDidChange(_:)),
                           name: NSWindow.didMoveNotification, object: window)
        center.addObserver(self, selector: #selector(windowFrameDidChange(_:)),
                           name: NSWindow.didResizeNotification, object: window)
        center.addObserver(self, selector: #selector(windowVisibilityDidChange(_:)),
                           name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    @objc private func windowFrameDidChange(_ notification: Notification) {
        guard let window, !isApplyingFrame else { return }
        if isLaunching {
            if window.isVisible {
                isLaunching = false
            } else {
                // macOS or SwiftUI placed the window after Lockstep did. Put it back.
                applyLaunchFrame(to: window)
                return
            }
        }
        save(window.frame, of: window)
    }

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        if window?.isVisible == true {
            isLaunching = false
        }
    }

    private func applyLaunchFrame(to window: NSWindow) {
        guard let launchFrame, window.frame != launchFrame else { return }
        isApplyingFrame = true
        window.setFrame(launchFrame, display: false)
        isApplyingFrame = false
    }

    private func fittedSavedFrame(for window: NSWindow) -> NSRect? {
        guard let numbers = LaunchOptions.current.settings.array(forKey: defaultsKey) as? [Double],
              numbers.count == 4,
              numbers.allSatisfy(\.isFinite),
              numbers[2] > 0, numbers[3] > 0
        else { return nil }
        let saved = FrameRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])

        let screens = NSScreen.screens.map { screen in
            let area = screen.visibleFrame
            return FrameRect(x: area.minX, y: area.minY, width: area.width, height: area.height)
        }

        // The smallest size can be set on the frame or on the content. Take the larger.
        let contentMinimum = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let minimumWidth = max(window.minSize.width, contentMinimum.width)
        let minimumHeight = max(window.minSize.height, contentMinimum.height)

        guard let fitted = WindowFrameFit.fit(saved, into: screens,
                                              minimumWidth: minimumWidth,
                                              minimumHeight: minimumHeight)
        else { return nil }
        return NSRect(x: fitted.x, y: fitted.y, width: fitted.width, height: fitted.height)
    }

    private func save(_ frame: NSRect, of window: NSWindow) {
        // In full screen the frame is the whole screen, which is not a place to come back to.
        guard !window.styleMask.contains(.fullScreen) else { return }
        LaunchOptions.current.settings.set(
            [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)],
            forKey: defaultsKey)
    }
}

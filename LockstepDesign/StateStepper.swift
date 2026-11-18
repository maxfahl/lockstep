import AppKit
import LockstepUI
import SwiftUI

// Stepping between the design states: which one is shown, the small panel
// beside the window with Previous and Next and a menu of all states, and the
// arrow keys.
//
// `LabContent` owns one `StateStepper` and shows the state it names. The
// panel is put up by `steppedBy(_:)`. The states come from `LabState.all`.

/// Which design state is shown. Changed by the panel's buttons and menu, and
/// by the Left and Right arrow keys.
@MainActor
@Observable
final class StateStepper {
    /// Every state, in the order they are stepped through.
    let states: [LabState]
    /// The place in `states` of the one shown now.
    private(set) var index: Int

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var keyMonitor: Any?

    /// - Parameters:
    ///   - states: Every state. There must be at least one.
    ///   - startingName: The name after the launch argument `-state`. Upper
    ///     and lower case do not matter. Nil, or a name no state has, starts
    ///     on the first state.
    init(states: [LabState], startingName: String?) {
        precondition(!states.isEmpty, "The design lab needs at least one state")
        assert(
            Set(states.map { $0.name.lowercased() }).count == states.count,
            "Two design states have the same name"
        )
        self.states = states
        let wanted = startingName?.lowercased()
        if let wanted, let found = states.firstIndex(where: { $0.name.lowercased() == wanted }) {
            index = found
        } else {
            index = 0
            if let startingName {
                let names = states.map { "\"\($0.name)\"" }.joined(separator: ", ")
                FileHandle.standardError.write(Data(
                    "There is no state called \"\(startingName)\". The states are: \(names).\n".utf8
                ))
            }
        }
    }

    /// The state shown now.
    var state: LabState { states[index] }

    /// "1 of 3" for the state shown now.
    var positionText: String {
        "\(index + 1) of \(states.count)"
    }

    /// Shows the next state (`+1`) or the one before (`-1`). After the last
    /// comes the first again.
    func step(by offset: Int) {
        index = ((index + offset) % states.count + states.count) % states.count
    }

    /// Shows the state with this name, chosen in the panel's menu.
    func show(_ name: String) {
        if let found = states.firstIndex(where: { $0.name == name }) {
            index = found
        }
    }

    // MARK: The panel and the arrow keys

    /// Puts the panel beside `window` and makes the arrow keys step while
    /// `window` has the keyboard. Does nothing the second time.
    fileprivate func showPanel(beside window: NSWindow) {
        guard panel == nil else { return }

        let hostingView = NSHostingView(rootView: StepperPanelView(stepper: self))
        // A panel of this kind never becomes the app's active window, so the
        // main window keeps the keyboard when the panel is clicked.
        let panel = StepperPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        self.panel = panel

        // Placed one turn later, when the window has its final place on screen.
        Task { @MainActor [weak window] in
            guard let window else { return }
            panel.setFrameOrigin(Self.place(for: panel.frame.size, beside: window))
            // A child window always stays in front of its parent, follows it
            // when it is moved, and can still be dragged on its own.
            window.addChildWindow(panel, ordered: .above)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window, event.window === window,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  // While text is being typed the arrows move the text cursor.
                  !(window.firstResponder is NSText)
            else { return event }
            switch event.specialKey {
            case .leftArrow?:
                self.step(by: -1)
                return nil
            case .rightArrow?:
                self.step(by: 1)
                return nil
            default:
                return event
            }
        }
    }

    /// Where the panel first appears: centred under the window, or above it,
    /// or over its bottom edge, whichever is the first that fits on screen.
    private static func place(for size: NSSize, beside window: NSWindow) -> NSPoint {
        let frame = window.frame
        let gap = DesignTokens.Spacing.small
        let x = frame.midX - size.width / 2
        guard let screen = window.screen?.visibleFrame else {
            return NSPoint(x: x, y: frame.minY - gap - size.height)
        }
        let below = frame.minY - gap - size.height
        let above = frame.maxY + gap
        if below >= screen.minY {
            return NSPoint(x: x, y: below)
        }
        if above + size.height <= screen.maxY {
            return NSPoint(x: x, y: above)
        }
        return NSPoint(x: x, y: frame.minY + gap)
    }
}

/// The panel's window. It never takes the keyboard.
private final class StepperPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - What the panel shows

private struct StepperPanelView: View {
    let stepper: StateStepper

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.large) {
            stepButton(symbol: "chevron.left", name: "Previous state", offset: -1)
            stateMenu
            stepButton(symbol: "chevron.right", name: "Next state", offset: 1)
        }
        .padding(DesignTokens.Spacing.panelPadding)
        .glassPanel()
        // Room around the glass, so its soft edge is not cut by the panel's
        // own outline.
        .padding(DesignTokens.Spacing.medium)
        .fixedSize()
        .lockstepLook()
    }

    /// The name of the state shown now and its place in the list. Clicking
    /// it opens a menu of every state, to jump straight to one.
    private var stateMenu: some View {
        Menu {
            ForEach(stepper.states) { state in
                Button(state.name) {
                    stepper.show(state.name)
                }
            }
        } label: {
            VStack(spacing: DesignTokens.Spacing.tight) {
                stableText(stepper.state.name, among: stepper.states.map(\.name))
                    .font(DesignTokens.Fonts.panelTitle)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Text(stepper.positionText)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Choose a state")
    }

    /// A text that takes the width of the widest of `all`, so the panel keeps
    /// its size when the text changes.
    private func stableText(_ text: String, among all: [String]) -> some View {
        ZStack {
            ForEach(all, id: \.self) { Text($0).hidden() }
            Text(text)
        }
        .lineLimit(1)
        .accessibilityElement()
        .accessibilityLabel(text)
    }

    /// Borderless, because the panel is glass and glass must not lie on glass.
    private func stepButton(symbol: String, name: String, offset: Int) -> some View {
        Button {
            stepper.step(by: offset)
        } label: {
            Image(systemName: symbol)
                .font(DesignTokens.Fonts.symbol)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .frame(
                    width: DesignTokens.Sizes.transportButton,
                    height: DesignTokens.Sizes.transportButton
                )
                .background(DesignTokens.Colors.controlFill, in: DesignTokens.Shapes.control)
                .contentShape(DesignTokens.Shapes.control)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }
}

// MARK: - Putting the panel up

extension View {
    /// Puts the stepping panel beside the window this view is in.
    func steppedBy(_ stepper: StateStepper) -> some View {
        background(StepperPanelAttachment(stepper: stepper))
    }
}

/// An invisible view that tells the stepper which window it is in.
private struct StepperPanelAttachment: NSViewRepresentable {
    let stepper: StateStepper

    func makeNSView(context: Context) -> WindowFinder {
        WindowFinder(stepper: stepper)
    }

    func updateNSView(_ nsView: WindowFinder, context: Context) {}

    final class WindowFinder: NSView {
        private let stepper: StateStepper

        init(stepper: StateStepper) {
            self.stepper = stepper
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("WindowFinder is made in code only")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                stepper.showPanel(beside: window)
            }
        }
    }
}

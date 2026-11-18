import AppKit
import SwiftUI

/// The field a track's name is typed in. It takes the place of the name in
/// the track's header (`TrackHeader`, for a track with `isBeingRenamed`), and
/// looks like the field a clip's name is typed in.
///
/// Without `onEnd` it is a picture of how renaming looks at the moment it
/// starts: the whole name is selected, and nothing can be typed. The design
/// lab shows it this way.
///
/// With `onEnd` the system's text field stands in the same place. It takes
/// the keyboard as it appears, with the whole name selected. The typing ends,
/// and `onEnd` is told once, when Return is pressed, when anything else in
/// the window is clicked, when Tab is pressed or when the field is taken
/// away (all with the name as typed), or when Escape is pressed (with nil).
struct TrackNameField: View {
    let name: String
    /// Told when the typing is over: the name as typed, or nil for Escape.
    /// Nil leaves the field a picture.
    var onEnd: (@MainActor (String?) -> Void)? = nil

    var body: some View {
        content
            .font(DesignTokens.Fonts.laneName)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: DesignTokens.Sizes.trackNameFieldHeight)
            .background(DesignTokens.Surfaces.clipNameFieldFill, in: DesignTokens.Shapes.clipNameField)
            .overlay {
                DesignTokens.Shapes.clipNameField.strokeBorder(
                    DesignTokens.Colors.accent,
                    lineWidth: DesignTokens.Lines.clipNameFieldRingWidth
                )
            }
            // The typed name starts where the name stood.
            .padding(.leading, -DesignTokens.Spacing.small)
            .pointerStyle(.horizontalText)
            .modifier(PictureOfTrackName(name: name, isPicture: onEnd == nil))
    }

    @ViewBuilder private var content: some View {
        if let onEnd {
            TypedName(name: name, label: "Track name", onEnd: onEnd)
        } else {
            text
        }
    }

    @ViewBuilder private var text: some View {
        if name.isEmpty {
            Text("Name")
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        } else {
            Text(name)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .background(DesignTokens.Surfaces.clipNameFieldSelection)
        }
    }
}

/// What a screen reader is told about the picture of the field. The real
/// field speaks for itself.
private struct PictureOfTrackName: ViewModifier {
    let name: String
    let isPicture: Bool

    func body(content: Content) -> some View {
        if isPicture {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Track name")
                .accessibilityValue(name)
        } else {
            content
        }
    }
}

/// The system's text field for a name, without a border or a background of
/// its own: `TrackNameField` and `ClipNameField` draw those around it. It
/// takes the keyboard as it appears and tells `onEnd` once when the typing is
/// over, as `TrackNameField` describes.
struct TypedName: View {
    /// What a screen reader calls the field: "Track name" or "Clip name".
    let label: String
    let onEnd: @MainActor (String?) -> Void

    @State private var typed: String
    /// True once `onEnd` was told, so it is told only once however the typing ends.
    @State private var hasEnded = false
    @FocusState private var hasKeyboard: Bool

    init(name: String, label: String, onEnd: @escaping @MainActor (String?) -> Void) {
        self.label = label
        self.onEnd = onEnd
        _typed = State(initialValue: name)
    }

    var body: some View {
        TextField("Name", text: $typed)
            .textFieldStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .focused($hasKeyboard)
            .accessibilityLabel(label)
            .onSubmit { end(with: typed) }
            .onExitCommand { end(with: nil) }
            // Tab would hand the keyboard to another control and leave the field open.
            .onKeyPress(.tab) {
                end(with: typed)
                return .handled
            }
            .onAppear { hasKeyboard = true }
            .onDisappear { end(with: typed) }
            // A click on something that takes no keyboard, which is nearly
            // everything in the window, would leave the field open. The
            // catcher is as large as the field drawn around the text.
            .background {
                ClickAwayCatcher { end(with: typed) }
                    .padding(-DesignTokens.Spacing.small)
            }
    }

    private func end(with name: String?) {
        guard !hasEnded else { return }
        hasEnded = true
        onEnd(name)
    }
}

/// Hears a press of a mouse button anywhere in its window outside the view
/// it lies behind. A text field keeps the keyboard when something that takes
/// no keyboard is clicked, so the field would never learn that the user has
/// turned to something else. The press itself still reaches what was clicked.
///
///     field.background { ClickAwayCatcher { endTyping() } }
///
/// It draws nothing and takes no clicks.
private struct ClickAwayCatcher: NSViewRepresentable {
    let onClickAway: () -> Void

    func makeNSView(context: Context) -> ClickAwayView {
        ClickAwayView()
    }

    func updateNSView(_ view: ClickAwayView, context: Context) {
        view.onClickAway = onClickAway
    }

    static func dismantleNSView(_ view: ClickAwayView, coordinator: ()) {
        view.stopListening()
    }
}

private final class ClickAwayView: NSView {
    var onClickAway: (() -> Void)?

    /// What AppKit gave back when the listening started, needed to stop it.
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopListening()
        guard window != nil else { return }
        // AppKit calls this on the main thread, before the press reaches any view.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.look(at: event)
            return event
        }
    }

    func stopListening() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Clicks go to the text field in front of this view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func look(at event: NSEvent) {
        guard let window, event.window === window else { return }
        guard !bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClickAway?()
    }
}

/// The red dot in the header of the track that is being recorded to.
struct TrackRecordingMark: View {
    var body: some View {
        Image(systemName: "circle.fill")
            .font(DesignTokens.Fonts.symbolSmall)
            .foregroundStyle(DesignTokens.Colors.record)
            .fixedSize()
            .help("Recording to this track")
            .accessibilityLabel("Recording to this track")
    }
}

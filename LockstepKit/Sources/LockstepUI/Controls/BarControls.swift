import Observation
import SwiftUI

// The controls that belong to the whole song rather than to one track or
// clip: the microphone level, the click, snapping and Send to DaVinci.

/// The microphone level: a small microphone symbol and a thin bar filled to a
/// fixed level. The bar is neutral, because colour is kept for timing.
///
/// When the microphone is too loud (`isClipping`), the last piece of the bar
/// lights up in the record red. That piece is part of the bar, so the meter
/// has the same size with and without it.
public struct MicLevelMeter: View {
    private let level: Double
    private let showsSymbol: Bool
    private let isClipping: Bool

    /// - Parameters:
    ///   - level: How full the bar is, from 0 (empty) to 1 (full).
    ///   - showsSymbol: Whether the microphone symbol is shown before the bar.
    ///   - isClipping: Lights the end of the bar: the microphone is too loud.
    public init(level: Double, showsSymbol: Bool = true, isClipping: Bool = false) {
        self.level = min(max(level, 0), 1)
        self.showsSymbol = showsSymbol
        self.isClipping = isClipping
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Spacing.controlGap) {
            if showsSymbol {
                Image(systemName: "mic.fill")
                    .font(DesignTokens.Fonts.symbolSmall)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            Capsule()
                .fill(DesignTokens.Colors.meterTrack)
                .frame(width: DesignTokens.Sizes.meterWidth, height: DesignTokens.Sizes.meterHeight)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(DesignTokens.Colors.meterFill)
                        .frame(width: DesignTokens.Sizes.meterWidth * level)
                }
                .overlay(alignment: .trailing) {
                    if isClipping {
                        MeterClipMark()
                    }
                }
        }
        .help("Microphone level")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(
            "\(Int((level * 100).rounded())) percent" + (isClipping ? ", too loud" : "")
        )
    }
}

/// The microphone level for a meter that moves while a take is recorded.
/// Whoever records changes `level` and `isClipping`, many times a second, and
/// `LiveMicLevelMeter` shows them.
///
/// Only that meter reads them. Do not read them in a view that holds the bar
/// or the timeline: that view would then be worked out again on every frame
/// of a recording.
@MainActor
@Observable
public final class MicLevelReading {
    /// How full the bar is, from 0 (empty) to 1 (full).
    public var level: Double
    /// Lights the end of the bar: the microphone is too loud.
    public var isClipping: Bool

    public init(level: Double = 0, isClipping: Bool = false) {
        self.level = level
        self.isClipping = isClipping
    }
}

/// The microphone level when it follows the microphone by itself: it shows
/// what `reading` says, and it is the only view of the bar that is worked out
/// again while the level moves. It looks exactly like `MicLevelMeter`.
public struct LiveMicLevelMeter: View {
    private let reading: MicLevelReading
    private let showsSymbol: Bool

    public init(reading: MicLevelReading, showsSymbol: Bool = true) {
        self.reading = reading
        self.showsSymbol = showsSymbol
    }

    public var body: some View {
        MicLevelMeter(level: reading.level, showsSymbol: showsSymbol, isClipping: reading.isClipping)
    }
}

/// The click: a button with a metronome that switches the click on and off,
/// and beside it a small arrow that will open the popover with the click's
/// sound, volume and how often it clicks (`ClickPopover`). The popover opens
/// upwards, because the control sits in the bar at the bottom of the window.
///
/// Without `actions` the control is a picture that changes only itself, as in
/// the design lab. With them it shows `isOn` and `settings` as they are handed
/// in and reports what is pressed (`ClickActions`).
public struct ClickControl: View {
    /// Whether the click is on when nobody is told of a press: the control
    /// keeps it.
    @State private var ownIsOn: Bool
    /// Whether the owner says the click is on.
    private let givenIsOn: Bool
    private let settings: ClickSettings
    /// Whether the popover is open, when nobody outside keeps that.
    @State private var showsOwnSettings = false
    private let showsSettingsOutside: Binding<Bool>?
    private let actions: ClickActions?

    /// - Parameters:
    ///   - isOn: Whether the click is on.
    ///   - settings: What the popover shows.
    ///   - showsSettings: Whether the popover is open, kept by the caller, so
    ///     that something other than the arrow can open it. Nil lets the
    ///     control keep it itself: closed until the arrow is pressed.
    ///   - actions: Told when the button is pressed or something is chosen in
    ///     the popover. Nil lets the control change what it shows by itself.
    public init(
        isOn: Bool,
        settings: ClickSettings = ClickSettings(),
        showsSettings: Binding<Bool>? = nil,
        actions: ClickActions? = nil
    ) {
        _ownIsOn = State(initialValue: isOn)
        self.givenIsOn = isOn
        self.settings = settings
        self.showsSettingsOutside = showsSettings
        self.actions = actions
    }

    private var isOn: Bool {
        actions == nil ? ownIsOn : givenIsOn
    }

    private var showsSettings: Binding<Bool> {
        showsSettingsOutside ?? $showsOwnSettings
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Spacing.tight) {
            SymbolButton(
                symbol: "metronome",
                name: "Click",
                font: DesignTokens.Fonts.symbol,
                width: DesignTokens.Sizes.transportButton,
                height: DesignTokens.Sizes.transportButton,
                color: isOn ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary,
                showsOnFill: isOn
            ) {
                if let actions {
                    actions.toggled?()
                } else {
                    ownIsOn.toggle()
                }
            }
            .accessibilityAddTraits(isOn ? .isSelected : [])
            SymbolButton(
                symbol: "chevron.down",
                name: "Click settings",
                font: DesignTokens.Fonts.symbolSmall,
                width: DesignTokens.Sizes.popoverArrowWidth,
                height: DesignTokens.Sizes.transportButton,
                color: DesignTokens.Colors.textSecondary
            ) {
                showsSettings.wrappedValue.toggle()
            }
        }
        .popover(isPresented: showsSettings, arrowEdge: .top) {
            ClickPopover(settings: settings, actions: actions)
        }
    }
}

/// The switch that turns snapping on and off when a clip is moved.
public struct SnappingSwitch: View {
    @State private var isOn: Bool

    public init(isOn: Bool) {
        _isOn = State(initialValue: isOn)
    }

    public var body: some View {
        LabelledSwitch(title: "Snapping", isOn: $isOn)
    }
}

/// Where a button stands, which decides what it is made of.
public enum ButtonSurface: Sendable {
    /// Inside a glass bar, strip, capsule or panel. The button is borderless,
    /// because glass must not lie on glass.
    case insideGlass
    /// Alone on a plain background. The button is the system's prominent
    /// glass button in the accent colour.
    case standalone
}

/// The Send to DaVinci button. Pressing it calls `action`, and does nothing
/// without one, as in the design lab.
public struct SendToDaVinciButton: View {
    private let surface: ButtonSurface
    private let action: (@MainActor () -> Void)?

    public init(surface: ButtonSurface = .insideGlass, action: (@MainActor () -> Void)? = nil) {
        self.surface = surface
        self.action = action
    }

    public var body: some View {
        Group {
            switch surface {
            case .insideGlass:
                Button(action: { action?() }) {
                    label
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .padding(.horizontal, DesignTokens.Spacing.large)
                        .frame(height: DesignTokens.Sizes.transportButton)
                        .background(DesignTokens.Colors.controlFillOn, in: Capsule(style: .continuous))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            case .standalone:
                Button(action: { action?() }) {
                    label
                }
                .buttonStyle(.glassProminent)
                .tint(DesignTokens.Colors.accent)
            }
        }
        .fixedSize()
        .help("Send to DaVinci")
    }

    private var label: some View {
        HStack(spacing: DesignTokens.Spacing.controlGap) {
            Image(systemName: "square.and.arrow.up")
                .font(DesignTokens.Fonts.symbol)
            Text("Send to DaVinci")
                .font(DesignTokens.Fonts.label)
        }
        .lineLimit(1)
    }
}

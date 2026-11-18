import SwiftUI

// The sheet that measures the delay of the headphones and the microphone in
// use. It has three looks: before measuring, with a result, and after a
// measurement that could not hear the ticks.

/// How the last measurement went.
public enum CalibrationOutcome: Sendable, Equatable {
    /// Nothing has been measured since the sheet opened.
    case notMeasured
    /// The delay was measured.
    case measured(milliseconds: Int)
    /// The ticks could not be heard.
    case failed
}

/// What the calibrate sheet shows.
public struct CalibrationContent: Sendable, Equatable {
    /// The name of the headphones in use, as the Mac names them.
    public var headphones: String
    /// The name of the microphone in use, as the Mac names it.
    public var microphone: String
    /// Wireless headphones get the note that their delay changes.
    public var headphonesAreWireless: Bool
    public var outcome: CalibrationOutcome
    /// What the box says after a measurement that failed for another reason
    /// than the ticks not being heard, such as a microphone that could not
    /// be opened. Nil says "Could not hear the ticks. Try again closer or
    /// louder."
    public var failureText: String?

    public init(
        headphones: String,
        microphone: String,
        headphonesAreWireless: Bool,
        outcome: CalibrationOutcome = .notMeasured,
        failureText: String? = nil
    ) {
        self.headphones = headphones
        self.microphone = microphone
        self.headphonesAreWireless = headphonesAreWireless
        self.outcome = outcome
        self.failureText = failureText
    }
}

/// The content of the calibrate sheet. Show it with the system's `sheet`:
///
///     .sheet(isPresented: $showsCalibrate) {
///         CalibrateSheet(content: calibration) { showsCalibrate = false }
///     }
///
/// From the top: the title, the one instruction, the headphones and the
/// microphone the measurement is about, then the result or the failure text
/// in a box, the note for wireless headphones, and the buttons. Start, Try
/// Again and Measure Again call `onStart`, and do nothing without it, as in
/// the design lab. The other button calls `onClose`.
public struct CalibrateSheet: View {
    private let content: CalibrationContent
    private let onStart: (() -> Void)?
    private let onClose: () -> Void

    public init(content: CalibrationContent, onStart: (() -> Void)? = nil, onClose: @escaping () -> Void = {}) {
        self.content = content
        self.onStart = onStart
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xLarge) {
            SheetTitle(title: "Calibrate Delay")
            Text("Hold one headphone against the microphone and press Start.")
                .font(DesignTokens.Fonts.label)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            outcome
            devices
            if content.headphonesAreWireless {
                Text(
                    "Wireless headphones change their delay between sessions. "
                        + "Calibrate again each time you connect them."
                )
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .sheetFrame()
    }

    /// The result or the failure text, in a box. Nothing before the first
    /// measurement.
    @ViewBuilder private var outcome: some View {
        switch content.outcome {
        case .notMeasured:
            EmptyView()
        case .measured(let milliseconds):
            Readout("\(milliseconds)", caption: "Delay:", unit: "ms", size: .large, name: "Measured delay")
                .sheetBox()
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.medium) {
                Image(systemName: "exclamationmark.triangle")
                    .font(DesignTokens.Fonts.symbol)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Text(content.failureText ?? "Could not hear the ticks. Try again closer or louder.")
                    .font(DesignTokens.Fonts.label)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .sheetBox()
        }
    }

    /// The headphones and the microphone the measurement is about. A delay
    /// belongs to this pair only, so the pair is always named.
    private var devices: some View {
        HStack(spacing: DesignTokens.Spacing.xLarge) {
            device(symbol: "headphones", kind: "Headphones", name: content.headphones)
            device(symbol: "mic", kind: "Microphone", name: content.microphone)
        }
    }

    private func device(symbol: String, kind: String, name: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.controlGap) {
            Image(systemName: symbol)
                .font(DesignTokens.Fonts.symbolSmall)
            Text(name)
                .font(DesignTokens.Fonts.label)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(DesignTokens.Colors.textSecondary)
        .help(kind)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind)
        .accessibilityValue(name)
    }

    /// With a result, closing is the main button and measuring again the
    /// other one. Without a result, measuring is the main button.
    private var buttons: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Spacer(minLength: 0)
            switch content.outcome {
            case .notMeasured:
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Start") { onStart?() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { onStart?() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .measured:
                Button("Measure Again") { onStart?() }
                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

extension SampleContent {
    /// Made-up content for the calibrate sheet: wireless headphones and a
    /// microphone, with the outcome the design state shows.
    public static func makeCalibration(outcome: CalibrationOutcome = .notMeasured) -> CalibrationContent {
        CalibrationContent(
            headphones: "AirPods Pro",
            microphone: "RØDE NT-USB+",
            headphonesAreWireless: true,
            outcome: outcome
        )
    }
}

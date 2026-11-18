import LockstepCore
import SwiftUI

/// What the list of measured delays needs from the rest of the app.
struct MeasuredDelaysLink {
    /// Whether this pair of devices can be measured right now: it is the pair the Mac is
    /// using, and nothing stands in the way of opening the calibrate sheet.
    var canRecalibrate: @MainActor (DevicePair) -> Bool = { _ in false }
    /// Opens the calibrate sheet in the main window.
    var recalibrate: @MainActor () -> Void = {}
}

/// "Measured delays" in the Recording pane: one row for every pair of headphones and
/// microphone that was calibrated, with both names, the delay and the date.
///
/// - Recalibrate opens the calibrate sheet in the main window. A delay can only be measured
///   for the devices the Mac is using, so the button works only in the row of that pair.
/// - Remove forgets the delay of that pair. Recordings that already have it keep it.
///
/// A delay cannot be typed here. It is always measured.
struct MeasuredDelaysSection: View {
    let settings: AppSettings
    let link: MeasuredDelaysLink

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Measured delays") {
            let delays = settings.measuredDelays
            if delays.isEmpty {
                Text("No delay has been measured yet. Choose Transport > Calibrate Delay... in the main window.")
                    .foregroundStyle(.secondary)
            }
            ForEach(delays) { entry in
                LabeledContent {
                    HStack {
                        Text("\(Int((entry.delay * 1000).rounded())) ms")
                            .monospacedDigit()
                        Button("Recalibrate") {
                            link.recalibrate()
                            // The sheet is in the main window, which may be behind this one.
                            openWindow(id: "main")
                        }
                        .disabled(!link.canRecalibrate(entry.devices))
                        Button("Remove") {
                            settings.removeDelay(for: entry.devices)
                        }
                    }
                } label: {
                    Text(Self.shown(entry.devices.outputName))
                    Text(detail(of: entry))
                }
            }
        }
    }

    /// The second line of a row: the microphone and when the delay was measured. A
    /// wireless delay from an earlier connection is not in use, and the row says so.
    private func detail(of entry: MeasuredDelay) -> String {
        var parts = [Self.shown(entry.devices.inputName)]
        if entry.measured != .distantPast {
            parts.append(entry.measured.formatted(date: .abbreviated, time: .shortened))
        }
        if settings.delay(for: entry.devices) == nil {
            parts.append("Not in use until measured again")
        }
        return parts.joined(separator: " · ")
    }

    private static func shown(_ name: String) -> String {
        name.isEmpty ? "Unknown" : name
    }
}

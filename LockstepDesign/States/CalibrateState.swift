import LockstepUI
import SwiftUI

extension LabState {
    /// The calibrate sheet before anything is measured: the instruction and
    /// Start. The window behind it says "Not calibrated".
    static let calibrate = LabState("Calibrate") {
        CalibrateStateView(outcome: .notMeasured)
    }

    /// The calibrate sheet with a result, "Delay: 217 ms". The window behind
    /// it shows the same delay.
    static let calibrateDone = LabState("Calibrate done") {
        CalibrateStateView(outcome: .measured(milliseconds: 217))
    }

    /// The calibrate sheet after a measurement that could not hear the ticks.
    static let calibrateFailed = LabState("Calibrate failed") {
        CalibrateStateView(outcome: .failed)
    }
}

/// The whole window with the calibrate sheet opened over it as soon as it is
/// shown. Close and Done close the sheet; the state is opened again by
/// stepping away and back.
private struct CalibrateStateView: View {
    let outcome: CalibrationOutcome
    @State private var showsSheet = false

    /// The delay in the panel on the right agrees with the sheet: the
    /// measured value with a result, "Not calibrated" without one.
    private var content: MainLayoutContent {
        var content = SampleContent.makeMainLayout()
        if case .measured(let milliseconds) = outcome {
            content.delayMilliseconds = milliseconds
        } else {
            content.delayMilliseconds = nil
        }
        return content
    }

    var body: some View {
        LabMainLayout(content: content, showsInspector: true)
            .sheet(isPresented: $showsSheet) {
                CalibrateSheet(content: SampleContent.makeCalibration(outcome: outcome)) {
                    showsSheet = false
                }
            }
            .task { showsSheet = true }
    }
}

import LockstepUI
import SwiftUI

/// What the design lab window shows: one design state at a time, on the
/// window background. The small panel beside the window and the arrow keys
/// step between the states (`StateStepper`). The launch argument
/// `-state <name>` picks the one shown first; without it that is "Main".
///
/// The states are listed in `LabState.all`, where it also says how to add one.
struct LabContent: View {
    /// Which state is shown.
    @State private var stepper = StateStepper(
        states: LabState.all,
        startingName: LabArguments.stateName
    )

    var body: some View {
        ZStack {
            WindowBackground()
            stepper.state.view
                // Each state starts fresh, with nothing kept from the one
                // shown before it.
                .id(stepper.state.name)
        }
        .steppedBy(stepper)
        .lockstepLook()
        .task {
            if LabArguments.isMeasuring {
                await MeasureRun.giveUpUnlessStarted()
            }
        }
    }
}

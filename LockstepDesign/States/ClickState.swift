import LockstepUI
import SwiftUI

extension LabState {
    /// The click popover, open above the click control in the bar at the
    /// bottom: the five sounds, the volume, how often it clicks, the
    /// count-in before recording and the speed a take is recorded at, which
    /// is 100 %. The click is on beats, so 16ths or Triplets under it is
    /// dimmed.
    static let click = LabState("Click") {
        ClickStateView()
    }

    /// The same popover with the click on sub-beats, and those on Triplets:
    /// the row of 16ths and Triplets can be used.
    static let clickOnSubBeats = LabState("Click, on sub-beats") {
        ClickStateView(division: .subBeats, subBeats: .triplets)
    }

    /// The same popover with 85 % chosen in its Record speed row. The bar
    /// under it then has the mark "85 %" right after the Record button.
    static let clickRecordSlower = LabState("Click, record slower") {
        ClickStateView(recordSpeedPercent: 85)
    }
}

/// The whole window with the click popover opened as soon as it is shown.
/// Opening is done here, so the click control knows nothing about the lab.
private struct ClickStateView: View {
    var division: ClickDivision = .beats
    var subBeats: ClickSubBeats = .sixteenths
    var recordSpeedPercent = 100
    @State private var showsClickSettings = false

    var body: some View {
        LabMainLayout(
            content: content,
            showsClickSettings: $showsClickSettings
        )
        // A popover can only open once the control it hangs on is in the
        // window, so it is opened right after the window has drawn.
        .task { showsClickSettings = true }
    }

    /// The sample window with a count-in and a recording speed handed in, so
    /// the popover shows its Count-in and Record speed rows. Two bars, so the
    /// chosen one is not the first. The window is told the speed too, as the
    /// real app tells it, so the bar marks a slower one.
    private var content: MainLayoutContent {
        var content = SampleContent.makeMainLayout()
        content.clickSettings.countInBars = 2
        content.clickSettings.division = division
        content.clickSettings.subBeats = subBeats
        content.clickSettings.recordSpeedPercent = recordSpeedPercent
        content.recordSpeedPercent = recordSpeedPercent
        return content
    }
}

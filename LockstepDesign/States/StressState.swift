import LockstepUI
import SwiftUI

extension LabState {
    /// The window with the heavy content: 12 tracks and 200 clips. It is not a
    /// design. It is what the measured speed run draws (`MeasureRun.swift`).
    static let stress = LabState("Stress") {
        LabMainLayout(content: SampleContent.makeMainLayout(stress: true))
    }
}

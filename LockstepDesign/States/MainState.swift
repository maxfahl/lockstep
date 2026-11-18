import LockstepUI
import SwiftUI

extension LabState {
    /// The window as it is most of the time: a song, four tracks, a selected
    /// clip with five takes, nothing playing.
    static let main = LabState("Main") {
        LabMainLayout(content: SampleContent.makeMainLayout())
    }
}

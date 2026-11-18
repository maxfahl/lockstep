import LockstepUI
import SwiftUI

extension LabState {
    /// The two kinds of message. In the window: a glass bar at the top of
    /// the timeline with one sentence and a close button. Over the window:
    /// the system's alert, "Lockstep could not read this file.", with OK.
    static let message = LabState("Message") {
        MessageStateView()
    }
}

/// The window with a message in it, and the alert opened over it as soon as
/// it is shown. OK closes the alert; the state is opened again by stepping
/// away and back.
private struct MessageStateView: View {
    @State private var showsAlert = false

    private var content: MainLayoutContent {
        var content = SampleContent.makeMainLayout()
        content.message = "Lockstep could not find beats in this song."
        return content
    }

    var body: some View {
        SmallStateWindow(content: content)
            .messageAlert(
                MessageAlert(
                    title: "Lockstep could not read this file.",
                    detail: "The file may be damaged, or it is not a sound file."
                ),
                isPresented: $showsAlert
            )
            .task { showsAlert = true }
    }
}

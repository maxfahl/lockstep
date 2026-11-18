import LockstepUI
import SwiftUI

/// What the Lockstep window holds: `MainLayout` from `LockstepUI`, the very view
/// the design lab shows, fed from the app's model. Nothing is laid out here.
///
/// A sound file dropped anywhere on the window is opened as the song.
struct MainWindow: View {
    let model: AppModel

    var body: some View {
        // Counted for `Scripts/same-behaviour.sh` (`RunCounts`): how often the whole window is worked out.
        let _ = RunCounts.shared.windowWorkedOut()
        // A binding is made on the object that holds what it binds: the height of the tracks is the
        // timeline view's, and whether the alert shows is the window state's.
        @Bindable var timelineView = model.timelineView
        @Bindable var windowState = model.windowState
        ZStack {
            WindowBackground()
            MainLayout(
                content: model.windowContent,
                features: model.features,
                // Not `$timelineView.scale`: a binding made here holds the scale as it is now, so the window
                // would be worked out again, all of it, every time the timeline moves.
                scale: timelineView.scaleBinding,
                trackHeight: $timelineView.trackHeight,
                playhead: model.playhead,
                showsInspector: timelineView.keptInspectorChoice,
                actions: model.layoutActions
            )
        }
        .lockstepLook()
        // The window's title is the open song's name.
        .navigationTitle(model.loadedSounds.song?.name ?? "Lockstep")
        .dropDestination(for: URL.self) { urls, _ in
            model.openingModel.open(dropped: urls)
        }
        .messageAlert(windowState.alert, isPresented: $windowState.showsAlert)
        .task {
            model.openingModel.openLaunchFile()
        }
        // The window is closing. What is still waiting to be saved is written first.
        .onDisappear {
            model.openingModel.saveBeforeClosing()
        }
    }
}


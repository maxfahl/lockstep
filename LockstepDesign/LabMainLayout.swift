import LockstepCore
import LockstepUI
import SwiftUI

extension FeatureSet {
    /// What the lab's windows show unless a state says otherwise: every
    /// feature but the Natural quality of a Voice. Natural is built only if
    /// the measurements of phase 37 justify it, so its switch is shown in
    /// the states that are about it and nowhere else. Every other picture
    /// then shows the Voice section as the app has it without Natural.
    static let lab: FeatureSet = .all.subtracting(.naturalVoice)
}

/// The whole window, as a design state shows it: `MainLayout` with made-up
/// content and every feature of the lab (`FeatureSet.lab`). The real app hosts the same `MainLayout` with
/// its own content and only the features that work.
///
///     LabMainLayout(content: SampleContent.makeMainLayout())
///
/// It keeps the zoom and the playhead, which the real app keeps in its model.
/// The song starts fitted to the width of the window.
struct LabMainLayout: View {
    private let content: MainLayoutContent
    private let features: FeatureSet
    private let showsInspector: Bool?
    private let showsClickSettings: Binding<Bool>?

    @State private var scale = TimelineScale(pointsPerSecond: 0)
    @State private var playhead: PlayheadPosition

    /// - Parameters:
    ///   - content: What the window draws. Start from
    ///     `SampleContent.makeMainLayout()` and change what the state needs.
    ///   - features: What the window shows. Left out, everything but the
    ///     Natural quality of a Voice (`FeatureSet.lab`).
    ///   - showsInspector: `true` or `false` opens or hides the inspector
    ///     whatever the width of the window. Nil lets the width decide.
    ///   - showsClickSettings: Whether the click popover is open, kept by
    ///     the state. Nil leaves it closed until the arrow is pressed.
    init(
        content: MainLayoutContent,
        features: FeatureSet = .lab,
        showsInspector: Bool? = nil,
        showsClickSettings: Binding<Bool>? = nil
    ) {
        self.content = content
        self.features = features
        self.showsInspector = showsInspector
        self.showsClickSettings = showsClickSettings
        _playhead = State(initialValue: PlayheadPosition(seconds: content.timeline.playheadTime))
    }

    var body: some View {
        MainLayout(
            content: content,
            features: features,
            scale: $scale,
            playhead: playhead,
            showsInspector: showsInspector,
            showsClickSettings: showsClickSettings
        )
        // The measured speed run needs this window's own zoom and playhead to
        // zoom, scroll and play. Without `-measure` nothing happens here.
        .task {
            if LabArguments.isMeasuring {
                MeasureRun.start(scale: $scale, playhead: playhead, content: content.timeline)
            }
        }
    }
}

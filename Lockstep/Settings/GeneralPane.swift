import AppKit
import LockstepCore
import SwiftUI

/// The General pane: where projects are saved, whether the last project comes back at
/// start, how the timeline follows the playhead, how fast the app's animations run, and
/// how near a dragged clip must come to something before it snaps to it.
struct GeneralPane: View {
    @Bindable var settings: AppSettings

    /// True when the chosen projects folder cannot be made or written to, so new
    /// projects go to the usual folder instead.
    @State private var cannotUseProjectsFolder = false

    var body: some View {
        // Read here, so the pane is drawn again when it changes.
        let snapDistance = settings[.snapDistancePoints]

        SettingsPaneForm(pane: .general, settings: settings) {
            Section {
                LabeledContent {
                    HStack {
                        Text(shownProjectsFolder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose...") { chooseProjectsFolder() }
                    }
                } label: {
                    Text("Projects folder")
                    Text("New projects are saved here. Projects you already have stay where they are.")
                }
                if cannotUseProjectsFolder {
                    Label {
                        Text("Lockstep cannot use this folder. New projects are saved in \(usualProjectsFolder).")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
                Toggle("Reopen the last project at launch", isOn: $settings[.reopenLastProject])
            }
            Section {
                Picker("Follow the playhead", selection: $settings[.followPlayhead]) {
                    ForEach(SettingKey.followPlayhead.choices, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                Picker("Animation speed", selection: $settings[.animationSpeed]) {
                    ForEach(SettingKey.animationSpeed.choices, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            }
            Section {
                Slider(
                    // The slider counts in decimals and the setting in whole points.
                    value: Binding(
                        get: { Double(snapDistance) },
                        set: { settings[.snapDistancePoints] = Int($0.rounded()) }
                    ),
                    in: Double(SettingKey.snapDistancePoints.limits.lowerBound)...Double(SettingKey.snapDistancePoints.limits.upperBound),
                    step: 1
                ) {
                    Text("Snap distance")
                    Text("How near a clip you drag must come to another clip, the playhead or its recorded place before it snaps there. Now \(snapDistance) points on screen.")
                } minimumValueLabel: {
                    Text("Near")
                } maximumValueLabel: {
                    Text("Far")
                }
            }
        }
        // Tried when the pane opens and whenever another folder is chosen: the folder
        // is made if it is missing, exactly as it would be for the next new project.
        .task(id: settings[.projectFolder]) {
            cannotUseProjectsFolder = LaunchOptions.current.projectsFolder(in: settings).isFallback
        }
    }

    /// The projects folder as the pane writes it, with `~` for the home folder.
    private var shownProjectsFolder: String {
        Self.shown(LaunchOptions.current.chosenProjectsFolder(in: settings))
    }

    /// Where new projects go when the chosen folder cannot be used.
    private var usualProjectsFolder: String {
        Self.shown(LaunchOptions.current.usualProjectsFolder)
    }

    private static func shown(_ folder: URL) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// Choose...: the system's folder panel. The folder that is picked becomes the
    /// projects folder.
    private func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        // A run with -scratch starts in its own folder and not in a folder of Max's.
        panel.directoryURL = LaunchOptions.current.scratchFolder
            ?? LaunchOptions.current.chosenProjectsFolder(in: settings)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings[.projectFolder] = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

extension FollowPlayhead {
    /// The choice as the pane writes it.
    fileprivate var title: String {
        switch self {
        case .toTheMiddle: "To the middle"
        case .smooth: "Smooth"
        case .off: "Off"
        }
    }
}

extension AnimationSpeed {
    /// The choice as the pane writes it.
    fileprivate var title: String {
        switch self {
        case .normal: "Normal"
        case .fast: "Fast"
        case .off: "Off"
        }
    }
}

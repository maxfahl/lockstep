import AppKit
import LockstepCore
import SwiftUI

/// The DaVinci pane: the Resolve timeline a new project starts with (its start timecode
/// and its frame rate), the folder exported clips are written to, and the Lockstep script
/// in DaVinci Resolve, with the button that installs it. Each project keeps its own timeline
/// values after that, and they are changed in the Send to DaVinci panel.
struct DaVinciPane: View {
    @Bindable var settings: AppSettings
    /// The script in Resolve that places sent clips: whether it is there, and installing it.
    let script: ResolveScriptInstall

    /// The timeline start as it stands in the field while Max types. It becomes the
    /// setting as soon as it is a timecode, and never while it is not.
    @State private var typedStart = ""
    @FocusState private var startHasFocus: Bool

    var body: some View {
        // Read here, so the pane is drawn again when they change.
        let storedStart = settings[.defaultTimelineStart]
        let frameRate = settings[.defaultFrameRate]

        SettingsPaneForm(pane: .davinci, settings: settings) {
            Section("New projects") {
                TextField(text: $typedStart, prompt: Text(SettingKey.defaultTimelineStart.defaultValue)) {
                    Text("Timeline start")
                    Text("The timecode your Resolve timeline starts at. Resolve starts a new timeline at 01:00:00:00.")
                }
                .monospacedDigit()
                .focused($startHasFocus)
                .onSubmit { showStoredStart() }
                if typedStartIsWrong {
                    Label {
                        Text("Write it as hours, minutes, seconds and frames, like 01:00:00:00, with the frames below \(frameRate.timecodeFramesPerSecond). Lockstep keeps \(settings.newProjectResolve.timelineStart.text) until then.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
                Picker(selection: $settings[.defaultFrameRate]) {
                    ForEach(SettingKey.defaultFrameRate.choices, id: \.self) { rate in
                        Text(rate.label).tag(rate)
                    }
                } label: {
                    Text("Frame rate")
                    Text("Frames per second of your Resolve timeline.")
                }
            }
            Section {
                LabeledContent {
                    HStack {
                        Text(shownExportFolder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose...") { chooseExportFolder() }
                        Button("Use Project Folder") { settings[.exportFolder] = "" }
                            .disabled(chosenExportFolder == nil)
                    }
                } label: {
                    Text("Export folder")
                    Text("Clips sent to DaVinci are saved here. Without a folder, each project keeps them in its own exports folder.")
                }
            }
            Section {
                LabeledContent {
                    HStack {
                        Text(scriptStatus)
                        Button(script.status == .different ? "Update" : "Install") { script.install() }
                            .disabled(script.status == .current)
                    }
                } label: {
                    Text("Resolve script")
                    Text("Adds Lockstep to the Workspace > Scripts menu of DaVinci Resolve. Choosing it there puts the clips you sent on their tracks, at their timecodes. If Lockstep is not in that menu, quit Resolve and open it again.")
                }
                if let problem = script.problem {
                    Label {
                        Text(problem)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
            } footer: {
                Text("Made for DaVinci Resolve 21.0.4. A later version may no longer run scripts in the free edition, so do not update Resolve while you use this.")
            }
        }
        .onAppear {
            showStoredStart()
            // The script can be removed or replaced from outside while Lockstep runs.
            script.refresh()
        }
        .onChange(of: typedStart) { keepTypedStart() }
        // Restore Defaults, or a frame rate that the frames no longer fit, changed it.
        .onChange(of: storedStart) { showStoredStartUnlessTyping() }
        .onChange(of: frameRate) { fitStartToFrameRate() }
        // Leaving the field puts back what is kept, so it never shows a value that is not in use.
        .onChange(of: startHasFocus) { if !startHasFocus { showStoredStart() } }
    }

    // MARK: The timeline start

    /// True while the field holds something that is not a timecode at the chosen frame rate.
    private var typedStartIsWrong: Bool {
        Timecode.parse(typedStart, frameRate: settings[.defaultFrameRate]) == nil
    }

    /// What was typed becomes the setting when it is a timecode, written the full way.
    private func keepTypedStart() {
        guard let timecode = Timecode.parse(typedStart, frameRate: settings[.defaultFrameRate]) else { return }
        settings[.defaultTimelineStart] = timecode.text
    }

    /// Puts the timeline start that is in use into the field.
    private func showStoredStart() {
        let text = settings.newProjectResolve.timelineStart.text
        if typedStart != text {
            typedStart = text
        }
    }

    /// The same, but not while Max is typing a timecode that already stands for the
    /// stored one ("1:0:0:0" for "01:00:00:00"): the field must not rewrite itself under his fingers.
    private func showStoredStartUnlessTyping() {
        let stored = settings.newProjectResolve.timelineStart
        guard Timecode.parse(typedStart, frameRate: settings[.defaultFrameRate]) != stored else { return }
        showStoredStart()
    }

    /// Another frame rate was chosen. A start whose frame number does not exist at that
    /// rate is put on the full second, and the field shows it.
    private func fitStartToFrameRate() {
        let fitted = settings.newProjectResolve.timelineStart.text
        if settings[.defaultTimelineStart] != fitted {
            settings[.defaultTimelineStart] = fitted
        }
        showStoredStart()
    }

    // MARK: The Resolve script

    /// Whether the script is in Resolve, as the pane writes it.
    private var scriptStatus: String {
        switch script.status {
        case .missing: "Not installed"
        case .current: "Installed"
        case .different: "An older version is installed"
        }
    }

    // MARK: The export folder

    /// The folder in use, or nil when each project uses its own.
    private var chosenExportFolder: URL? {
        LaunchOptions.current.exportFolder(in: settings)
    }

    /// The export folder as the pane writes it, with `~` for the home folder.
    private var shownExportFolder: String {
        guard let folder = chosenExportFolder else { return "Each project's own folder" }
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// Choose...: the system's folder panel. The folder that is picked becomes the export folder.
    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        // A run with -scratch starts in its own folder and not in a folder of Max's.
        if let start = LaunchOptions.current.scratchFolder ?? chosenExportFolder {
            panel.directoryURL = start
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings[.exportFolder] = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

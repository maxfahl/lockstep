import LockstepCore
import LockstepUI
import SwiftUI

/// The settings window: the system's own tabs across the top, one per pane, and in
/// each pane a standard form. Nothing here is drawn by Lockstep itself.
///
///     Settings { SettingsView(settings: model.settings) }
///
/// The window's title is the name of the pane it shows, the window is as tall as that
/// pane needs, and it opens on the pane that was used last. A later phase adds its
/// pane as one more `Tab` here.
struct SettingsView: View {
    let settings: AppSettings
    /// What the Recalibrate buttons in the Recording pane do. Left out, they are greyed out.
    var delays = MeasuredDelaysLink()
    /// The Lockstep script in DaVinci Resolve, which the DaVinci pane shows and installs.
    let resolveScript: ResolveScriptInstall

    /// The pane that was used last. It is kept in the same store as the settings, so a
    /// scratch run remembers its own and leaves Max's alone.
    @AppStorage("settingsSelectedPane", store: LaunchOptions.current.settings)
    private var selectedPane = SettingsPane.general

    var body: some View {
        TabView(selection: $selectedPane) {
            Tab(SettingsPane.general.title, systemImage: "gear", value: SettingsPane.general) {
                GeneralPane(settings: settings)
            }
            Tab(SettingsPane.beatsAndClick.title, systemImage: "metronome", value: SettingsPane.beatsAndClick) {
                BeatsAndClickPane(settings: settings)
            }
            Tab(SettingsPane.recording.title, systemImage: "mic", value: SettingsPane.recording) {
                RecordingPane(settings: settings, delays: delays)
            }
            Tab(SettingsPane.volume.title, systemImage: "speaker.wave.2", value: SettingsPane.volume) {
                VolumePane(settings: settings)
            }
            Tab(SettingsPane.timing.title, systemImage: "waveform.path", value: SettingsPane.timing) {
                TimingPane(settings: settings)
            }
            Tab(SettingsPane.davinci.title, systemImage: "film", value: SettingsPane.davinci) {
                DaVinciPane(settings: settings, script: resolveScript)
            }
            Tab(SettingsPane.shortcuts.title, systemImage: "keyboard", value: SettingsPane.shortcuts) {
                ShortcutsPane()
            }
        }
        .navigationTitle(selectedPane.title)
        .lockstepLook()
    }
}

/// One pane of the settings window: a grouped form of standard controls and, under
/// it, the button that puts this pane's settings back to what they started as.
///
///     SettingsPaneForm(pane: .general, settings: settings) {
///         Section { Toggle("Reopen the last project at launch", isOn: $settings[.reopenLastProject]) }
///     }
///
/// A pane whose values are not kept in `AppSettings` says itself what the button does,
/// and a pane with a long list says how tall it may get before it scrolls:
///
///     SettingsPaneForm(tallestForm: 560, restoreDefaults: { askFirst() }) { ... }
struct SettingsPaneForm<Rows: View>: View {
    /// What "Restore Defaults" does.
    let restoreDefaults: () -> Void
    /// The tallest the form may be. Longer than this, it scrolls. Nil for a form that
    /// is always as tall as its rows.
    let tallestForm: CGFloat?
    let rows: Rows

    /// The distance the system's grouped form keeps to the window's edges.
    private static var inset: CGFloat { 20 }

    /// A pane of settings from `AppSettings`. The button puts this pane's settings back.
    init(pane: SettingsPane, settings: AppSettings, @ViewBuilder rows: () -> Rows) {
        self.init(restoreDefaults: { settings.restoreDefaults(for: pane) }, rows: rows)
    }

    init(tallestForm: CGFloat? = nil, restoreDefaults: @escaping () -> Void, @ViewBuilder rows: () -> Rows) {
        self.restoreDefaults = restoreDefaults
        self.tallestForm = tallestForm
        self.rows = rows()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                rows
            }
            .formStyle(.grouped)
            // As tall as its rows, so the window fits the pane and nothing scrolls,
            // up to the tallest it may be.
            .frame(maxHeight: tallestForm)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Restore Defaults", action: restoreDefaults)
            }
            .padding(.horizontal, Self.inset)
            .padding(.bottom, Self.inset)
        }
        .frame(width: SettingsPane.width)
    }
}

extension SettingsPane {
    /// Every pane is this wide, so the window only changes its height between panes.
    static var width: CGFloat { 520 }
}

extension SettingKey where Value: Comparable {
    /// The lowest and highest value, for the stepper or slider that sets the setting.
    var limits: ClosedRange<Value> {
        range ?? defaultValue...defaultValue
    }
}

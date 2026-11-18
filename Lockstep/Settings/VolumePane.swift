import LockstepCore
import SwiftUI

/// The Volume pane: the loudness Normalize brings clips to, and whether a new recording is normalised by
/// itself as it becomes a clip.
struct VolumePane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        // Read here, so the pane is drawn again when it changes.
        let target = settings[.targetLufs]

        SettingsPaneForm(pane: .volume, settings: settings) {
            Section {
                Slider(value: $settings[.targetLufs], in: SettingKey.targetLufs.limits, step: 1) {
                    Text("Normalize to: \(Int(target.rounded())) LUFS")
                    Text("Clips are brought to this loudness. -18 leaves room for mixing in Resolve.")
                } minimumValueLabel: {
                    Text("-30")
                } maximumValueLabel: {
                    Text("-10")
                }
            }
            Section {
                Toggle("Normalize new recordings automatically", isOn: $settings[.normalizeNewRecordings])
            }
        }
    }
}

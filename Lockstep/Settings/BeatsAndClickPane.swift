import LockstepCore
import LockstepUI
import SwiftUI

/// The Beats and Click pane: how the beats are picked and their lines fitted, what the click of a new
/// song starts with, and whether the first beat of a bar is accented.
struct BeatsAndClickPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        // Read here, so the pane is drawn again when they change.
        let gap = settings[.maxGapBeats]
        let smoothing = settings[.smoothingBeats]
        let limit = settings[.certaintyLimit]
        let limits = SettingKey.certaintyLimit.limits

        SettingsPaneForm(pane: .beatsAndClick, settings: settings) {
            Section {
                Slider(
                    // The slider runs from strict to loose, and the setting is the other way
                    // round: the higher it is, the surer Lockstep must be.
                    value: Binding(
                        get: { -limit },
                        set: { settings[.certaintyLimit] = $0 == 0 ? 0 : -$0 }
                    ),
                    in: -limits.upperBound...(-limits.lowerBound),
                    step: 0.25
                ) {
                    Text("How sure Lockstep must be of a beat")
                    Text("Strict keeps only the beats Lockstep is very sure of. Loose also keeps weaker ones, which can put beat lines where the song has no beat. Where Lockstep finds no beats, it tries again less strictly by itself.")
                } minimumValueLabel: {
                    Text("Strict")
                } maximumValueLabel: {
                    Text("Loose")
                }
                Stepper(value: $settings[.maxGapBeats], in: SettingKey.maxGapBeats.limits) {
                    Text("Fill gaps of up to \(gap) \(gap == 1 ? "beat" : "beats")")
                    Text("Where the song has no drum hits for a while, Lockstep fills in the beats it expects. A longer gap is left without beats.")
                }
                Slider(
                    // The slider counts in decimals and the setting in whole beats.
                    value: Binding(
                        get: { Double(smoothing) },
                        set: { settings[.smoothingBeats] = Int($0.rounded()) }
                    ),
                    in: Double(SettingKey.smoothingBeats.limits.lowerBound)...Double(SettingKey.smoothingBeats.limits.upperBound),
                    step: Double(SettingKey.smoothingBeats.step ?? 1)
                ) {
                    Text("Beat lines follow each drum hit")
                    Text("Smoother ignores small differences between hits. Closer follows every hit, including the app's mistakes.")
                } minimumValueLabel: {
                    Text("Closer")
                } maximumValueLabel: {
                    Text("Smoother")
                }
            }
            Section("New songs") {
                Picker("Click sound", selection: $settings[.clickDefaultSound]) {
                    ForEach(SettingKey.clickDefaultSound.choices, id: \.self) { sound in
                        Text(LockstepUI.ClickSound(sound).title).tag(sound)
                    }
                }
                Slider(value: $settings[.clickDefaultVolume], in: SettingKey.clickDefaultVolume.limits) {
                    Text("Click volume")
                    Text("How loud the click is when a new song is opened. Each song keeps its own volume after that.")
                }
                Picker("Click on", selection: $settings[.clickDefaultDivision]) {
                    ForEach(SettingKey.clickDefaultDivision.choices, id: \.self) { division in
                        Text(LockstepUI.ClickDivision(division).title).tag(division)
                    }
                }
            }
            Section {
                Toggle("Accent on the first beat of a bar", isOn: $settings[.accentBeatOne])
            }
        }
    }
}

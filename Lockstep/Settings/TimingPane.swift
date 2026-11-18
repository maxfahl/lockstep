import LockstepCore
import SwiftUI

/// The Timing pane: how sound is treated in time when it is played and exported. Its first setting is the
/// length of the fade at clip edges, and its second how far from a sub-beat a syllable is left alone. Then
/// come the two numbers for whole lines: the furthest a line may slide, and the pause that separates two
/// lines. Last come the two limits on single syllables, which the correction of a clip with All chosen works
/// within: the furthest a syllable may move, and the most its sound may be stretched or squeezed, which
/// holds for clips with Stretch on.
///
/// The words are the ones the panel on the right uses under "Correction": Lines, All, Strength, Stretch,
/// sub-beats.
///
/// Changing a number here makes the sound of every clip with a timing fix again (`CorrectionModel.tightenSettings`).
///
/// A line may never slide further than the pause leaves room for, or two lines could meet. So the slider for
/// the furthest slide shows the value in force (`AppSettings.maxLineShiftInForceMs`) and cannot be dragged
/// past it, and when the pause is made shorter it follows down.
struct TimingPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        // Read here, so the pane is drawn again when it changes.
        let fade = settings[.edgeFadeMs]
        let deliberate = settings[.deliberatePercent]
        let pause = settings[.linePauseMs]
        let slide = settings.maxLineShiftInForceMs
        let furthestSlide = TightenSettings.furthestShiftMs(forPauseMs: pause)
        let slideLimits = SettingKey.maxLineShiftMs.limits
        let syllableMove = settings[.maxSyllableMoveMs]
        let stretch = settings[.maxStretchPercent]

        SettingsPaneForm(pane: .timing, settings: settings) {
            Section {
                Slider(value: $settings[.edgeFadeMs], in: SettingKey.edgeFadeMs.limits, step: 1) {
                    Text("Fade at clip edges: \(Int(fade.rounded())) ms")
                    Text("A very short fade where a clip starts and ends, so a cut in the middle of a sound does not click. 0 is no fade. Your recordings are not changed.")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("20")
                }
            }
            Section {
                Slider(value: $settings[.deliberatePercent], in: SettingKey.deliberatePercent.limits, step: 1) {
                    Text("A syllable further off than this is left alone: \(Int(deliberate.rounded())) % of the sub-beat spacing")
                    Text("Syllables this far from any sub-beat are treated as deliberate. They are shown in a neutral colour, and the correction does not move them by themselves.")
                } minimumValueLabel: {
                    Text("20")
                } maximumValueLabel: {
                    Text("50")
                }
            }
            Section("Lines") {
                Slider(value: lineSlide, in: slideLimits) {
                    Text("Furthest a line may slide: \(Int(slide.rounded())) ms")
                    Text(
                        "With Lines or All, a line slides toward the sub-beat nearest to its first syllable, and never further than this."
                            + (furthestSlide < slideLimits.upperBound
                                ? " With the pause below, \(Int(furthestSlide)) ms is the most there is room for."
                                : "")
                    )
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("120")
                }
                Slider(value: whole(.linePauseMs), in: SettingKey.linePauseMs.limits) {
                    Text("Pause that separates two lines: \(Int(pause.rounded())) ms")
                } minimumValueLabel: {
                    Text("150")
                } maximumValueLabel: {
                    Text("600")
                }
            }
            Section("Syllables") {
                Slider(value: whole(.maxSyllableMoveMs), in: SettingKey.maxSyllableMoveMs.limits) {
                    Text("Furthest a syllable may move: \(Int(syllableMove.rounded())) ms")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("80")
                }
                Slider(value: whole(.maxStretchPercent), in: SettingKey.maxStretchPercent.limits) {
                    Text("Most a syllable may be stretched or squeezed: \(Int(stretch.rounded())) %")
                    Text("Holds for clips with Stretch on. Lower keeps your voice more natural. Higher lets syllables move further. A clip with Stretch off is never stretched.")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("40")
                }
            }
        }
    }

    /// The slider for the furthest slide: it stands at the value in force, and a drag past what the pause
    /// leaves room for stops there. It lands on whole milliseconds.
    private var lineSlide: Binding<Double> {
        Binding(
            get: { settings.maxLineShiftInForceMs },
            set: {
                settings[.maxLineShiftMs] = min(
                    $0.rounded(),
                    TightenSettings.furthestShiftMs(forPauseMs: settings[.linePauseMs])
                )
            }
        )
    }

    /// A setting for a slider that lands on whole numbers and draws no tick marks. A slider that is given a
    /// step draws a tick for every step, and with a hundred steps or more the ticks run together into a bar.
    private func whole(_ key: SettingKey<Double>) -> Binding<Double> {
        Binding(get: { settings[key] }, set: { settings[key] = $0.rounded() })
    }
}

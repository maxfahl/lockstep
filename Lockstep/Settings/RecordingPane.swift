import LockstepCore
import LockstepSpeech
import SwiftUI

/// The Recording pane: what starting a take over does with the attempt it drops, whether the
/// words of new recordings are written out and in which language, and the delays that were
/// measured for each pair of headphones and microphone.
///
/// The words are written out by whisper.cpp with the speech model of the chosen language. When
/// that model is not installed, or is not whole, the line under the switch says so and how to
/// install it. Clips then simply get no words. The file is looked for each time the pane is
/// drawn. Only its presence and length are checked, which reads none of it.
///
/// The count-in before recording is chosen in the click menu of the main window's bar,
/// not here. It is still one of this pane's settings (`recording.runUpBars`), so
/// Restore Defaults puts it back to one bar.
struct RecordingPane: View {
    @Bindable var settings: AppSettings
    /// What the Recalibrate buttons of the measured delays do. Left out, they are greyed out.
    var delays = MeasuredDelaysLink()

    var body: some View {
        SettingsPaneForm(pane: .recording, settings: settings) {
            Section {
                Toggle(isOn: $settings[.restartKeepsAttempt]) {
                    Text("When restarting, keep the dropped attempt as a clip")
                    Text("Off throws the attempt away. On keeps every attempt as a take you can choose between.")
                }
            }
            Section {
                Toggle(isOn: $settings[.writeOutNewRecordings]) {
                    Text("Write out the words of new recordings")
                    Text(Self.speechModelLine(for: settings[.speechLanguage]))
                }
                Picker("Language of the words", selection: $settings[.speechLanguage]) {
                    ForEach(SettingKey.speechLanguage.choices, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
            }
            MeasuredDelaysSection(settings: settings, link: delays)
        }
    }

    /// The line under the switch: which model writes the words out, or what is wrong with its
    /// file and how to put it right, in the words of `SpeechModelError`.
    private static func speechModelLine(for language: SpeechLanguage) -> String {
        do {
            try SpeechModel.for(language).checkPresence()
        } catch {
            return error.localizedDescription
        }
        switch language {
        case .swedish: return "KB-Whisper, a Swedish speech model, writes out the words on this Mac."
        case .automatic: return "Whisper writes out the words on this Mac and finds the language of each clip."
        }
    }
}

extension SpeechLanguage {
    /// The choice as the pane writes it.
    fileprivate var title: String {
        switch self {
        case .swedish: "Swedish"
        case .automatic: "Any language (found for each clip)"
        }
    }
}

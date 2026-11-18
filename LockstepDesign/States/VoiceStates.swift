import LockstepCore
import LockstepUI
import SwiftUI

// The Voice of a track, in the panel on the right: the section "Voice" between Normalize Track and Sound, in
// the eleven states the design of phase 37 lists, and what its menu holds. A track is selected and no clip in
// all of them. The first seven show the section without the Natural quality, which is how the app has it
// unless Natural is built. The last four show it with the switch "Natural".
//
// The submenu "Voice" of a track's right-click menu is in "Menu track", and the rows of the Send to DaVinci
// panel are in "Send with voices" and the three states after it.

extension LabState {
    /// 1. A track that never had a Voice: the switch is off, the box reads "Custom" and both knobs stand in
    /// the middle, all three dimmed.
    static let voiceNever = LabState("A track that never had a Voice") {
        LabMainLayout(content: LabState.trackWithVoice(nil), showsInspector: true)
    }

    /// 2. The Voice is on with the preset "Darker", and every voice is made: nothing more is said.
    static let voiceOn = LabState("A track with a Voice") {
        LabMainLayout(content: LabState.trackWithVoice(LabState.darkerVoice), showsInspector: true)
    }

    /// 3. A knob was turned after a preset was chosen: the box reads "Custom".
    static let voiceCustom = LabState("A track with a custom Voice") {
        let voice = TrackVoice(knobs: VoiceKnobs(depth: 9, pitch: -1.5))
        return LabMainLayout(content: LabState.trackWithVoice(voice), showsInspector: true)
    }

    /// 4. The Voice is switched off and keeps its setting: the box and the knobs show "Deeper", dimmed.
    static let voiceOff = LabState("A track with its Voice off") {
        var voice = VoicePresets.builtIn[1].voice
        voice.isOn = false
        return LabMainLayout(content: LabState.trackWithVoice(voice), showsInspector: true)
    }

    /// 5. Voices are being made after a knob was let go: the ring in the heading's line, a quarter full,
    /// and the line that says how many clips have theirs.
    static let voicesBeingMade = LabState("Voices being made") {
        LabMainLayout(
            content: LabState.trackWithVoice(LabState.darkerVoice, state: .making(done: 3, of: 12)),
            showsInspector: true
        )
    }

    /// 6. The voice of two clips could not be made: the line says so, with the button Try Again.
    static let voicesFailed = LabState("Voices that could not be made") {
        LabMainLayout(
            content: LabState.trackWithVoice(LabState.darkerVoice, state: .failed(clips: 2)),
            showsInspector: true
        )
    }

    /// 7. A take is going on the track: the whole section is dimmed and deaf, as no voice is made meanwhile.
    static let voiceWhileTakeGoes = LabState("A Voice while a take is going") {
        var content = MainLayoutContent.sampleWithoutSelectedClip()
        content.startRecording(onTrack: 2, at: 26.5, recordedSeconds: 3.4)
        content.micLevel = 0.6
        LabState.giveSelectedTrackVoice(LabState.darkerVoice, in: &content)
        content.canChangeVoice = false
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// 8. With Natural: the switch "Natural" is on and every voice is made.
    static let voiceNatural = LabState("A natural Voice") {
        LabMainLayout(content: LabState.trackWithVoice(LabState.naturalVoice), features: .all, showsInspector: true)
    }

    /// 9. With Natural: the quick voices are heard while the natural ones are made, three clips of twelve
    /// so far.
    static let naturalVoicesBeingMade = LabState("Natural voices being made") {
        LabMainLayout(
            content: LabState.trackWithVoice(LabState.naturalVoice, state: .makingNatural(done: 3, of: 12)),
            features: .all,
            showsInspector: true
        )
    }

    /// 10. With Natural: the voice engine is not installed. The line says so, with a button that opens
    /// Settings > Voices.
    static let naturalWithoutEngine = LabState("Natural without the voice engine") {
        LabMainLayout(
            content: LabState.trackWithVoice(LabState.naturalVoice, state: .noEngine),
            features: .all,
            showsInspector: true
        )
    }

    /// 11. With Natural: Max has not chosen a sample of his voice. The line says so, with the same button.
    static let naturalWithoutSample = LabState("Natural without a voice sample") {
        LabMainLayout(
            content: LabState.trackWithVoice(LabState.naturalVoice, state: .noSample),
            features: .all,
            showsInspector: true
        )
    }

    /// What the Voice menu holds for a track with "Darker", when Max has saved two presets of his own.
    static let menuVoice = LabState("Menu voice") {
        MenuStateSheet(
            hint: "Press the box under Voice in the panel on the right, in A track with a Voice, for the real menu. "
                + "This is what it holds.",
            entries: VoiceMenu(voice: LabState.darkerVoice, ownPresets: LabState.ownVoicePresets.map(\.name)).entries
        )
    }

    // MARK: Made-up Voices

    /// The Voice a track has right after the built-in preset "Darker" was chosen for it.
    static let darkerVoice = VoicePresets.builtIn[0].voice

    /// The same with the switch "Natural" on.
    private static let naturalVoice: TrackVoice = {
        var voice = darkerVoice
        voice.natural = true
        return voice
    }()

    /// The presets Max is made up to have saved himself.
    static let ownVoicePresets = [
        VoicePreset(name: "Villain", knobs: VoiceKnobs(depth: 12, pitch: -2.5)),
        VoicePreset(name: "Kid brother", knobs: VoiceKnobs(depth: -8, pitch: 2)),
    ]

    /// The made-up window with its track selected and no clip, and this Voice on that track.
    private static func trackWithVoice(_ voice: TrackVoice?, state: VoiceState = .ready) -> MainLayoutContent {
        var content = SampleContent.makeMainLayout()
        selectNoClip(in: &content)
        giveSelectedTrackVoice(voice, state: state, in: &content)
        return content
    }

    /// Gives the selected track of the made-up window this Voice, and Max two presets of his own.
    private static func giveSelectedTrackVoice(
        _ voice: TrackVoice?,
        state: VoiceState = .ready,
        in content: inout MainLayoutContent
    ) {
        for index in content.timeline.trackRows.indices where content.timeline.trackRows[index].isSelected {
            content.timeline.trackRows[index].voice = voice
            content.timeline.trackRows[index].voiceState = state
        }
        content.ownVoicePresets = ownVoicePresets
    }
}

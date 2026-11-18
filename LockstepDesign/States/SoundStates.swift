import LockstepCore
import LockstepUI
import SwiftUI

// The Sound of a track and of a clip, in the panel on the right. Two more of its states are older ones: "A
// track selected" is a track without a Sound, where the box reads "None" and there are no knobs, and "One
// clip selected" is a clip on such a track, with the four knobs dimmed.

extension LabState {
    /// A track is selected and no clip, and the track has the Sound "Rap lead": under "Sound" the box shows
    /// its name, and the four knobs stand where that preset starts them.
    static let trackWithSound = LabState("A track with a Sound") {
        var content = SampleContent.makeMainLayout()
        LabState.giveSelectedTrackSound(in: &content)
        LabState.selectNoClip(in: &content)
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// The same right after a knob was turned: the sounds of the track's clips are being made again, a
    /// little under half done, so the small ring stands in the line of the heading "Sound".
    static let soundsBeingMade = LabState("Sounds being made") {
        var content = SampleContent.makeMainLayout()
        LabState.giveSelectedTrackSound(in: &content)
        LabState.selectNoClip(in: &content)
        content.soundRemakeProgress = 0.4
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// What the Sound menu holds for a track with "Rap lead", when Max has saved two presets of his own.
    static let menuSound = LabState("Menu sound") {
        MenuStateSheet(
            hint: "Press the box under Sound in the panel on the right, in A track with a Sound, for the real menu. "
                + "This is what it holds.",
            entries: SoundMenu(soundName: "Rap lead", ownPresets: LabState.ownSoundPresets).entries
        )
    }

    /// One clip is selected on a track with the Sound "Rap lead". Under "Sound" it shows the track's four
    /// knobs, and none is marked: the clip follows its track.
    static let oneClipWithSound = LabState("One clip with a Sound") {
        var content = SampleContent.makeMainLayout()
        LabState.giveSelectedTrackSound(in: &content)
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// The same clip with Space turned for itself, to 60 % where its track has 8 %: the arrow that turns
    /// back stands before the value, and a press on it puts Space back to the track's.
    static let oneClipOwnSpace = LabState("One clip with its own Space") {
        var content = SampleContent.makeMainLayout()
        LabState.giveSelectedTrackSound(in: &content)
        LabState.changeClips(in: &content, where: \.isSelected) { $0.ownKnobs.space = 0.6 }
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// Three clips are selected, on two tracks that both have "Rap lead". One of them has its own Space, so
    /// Space reads "Mixed" and has the mark, and the three other knobs show the value all three share.
    static let severalClipsWithSound = LabState("Several clips with a Sound") {
        var content = SampleContent.makeMainLayout()
        let alsoSelected: Set<String> = ["Writing lines until the morning", "Hook v2"]
        for trackIndex in content.timeline.trackRows.indices
        where content.timeline.trackRows[trackIndex].clips.contains(where: { alsoSelected.contains($0.displayName) }) {
            content.timeline.trackRows[trackIndex].sound = SoundValues.builtIn("Rap lead")
        }
        LabState.changeClips(in: &content, where: { alsoSelected.contains($0.displayName) }) { clip in
            clip.isSelected = true
            if clip.displayName == "Hook v2" {
                clip.ownKnobs.space = 0.4
            }
        }
        // Takes, words and a Resolve start time belong to one clip only.
        content.timeline.takeRows = []
        content.selectedClipText = ""
        content.selectedClipResolveStart = ""
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// The presets Max is made up to have saved himself.
    private static let ownSoundPresets = ["My hook", "Phone verse"]

    /// Gives the selected track of the made-up window the Sound "Rap lead", and Max two presets of his own.
    static func giveSelectedTrackSound(in content: inout MainLayoutContent) {
        for trackIndex in content.timeline.trackRows.indices where content.timeline.trackRows[trackIndex].isSelected {
            content.timeline.trackRows[trackIndex].sound = SoundValues.builtIn("Rap lead")
        }
        content.ownSoundPresets = ownSoundPresets
    }

    /// Selects no clip, so the panel shows the selected track.
    static func selectNoClip(in content: inout MainLayoutContent) {
        changeClips(in: &content, where: \.isSelected) { $0.isSelected = false }
        content.timeline.takeRows = []
        content.selectedClipText = ""
        content.selectedClipResolveStart = ""
    }

    /// Changes every clip of the made-up window that `matches`.
    static func changeClips(
        in content: inout MainLayoutContent,
        where matches: (ClipBox) -> Bool,
        _ change: (inout ClipBox) -> Void
    ) {
        for trackIndex in content.timeline.trackRows.indices {
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices
            where matches(content.timeline.trackRows[trackIndex].clips[clipIndex]) {
                change(&content.timeline.trackRows[trackIndex].clips[clipIndex])
            }
        }
    }
}

import LockstepUI
import SwiftUI

extension LabState {
    /// Exactly one clip is selected. The inspector shows its Resolve start
    /// time, name, full text, volume, the controls under "Correction" (All
    /// chosen, the sub-beats on 16ths, Strength at 70 %, Stretch off) and takes.
    /// The volume is set high, at +9 dB, and is being held back to avoid
    /// clipping, so the mark stands before the number. ("Main" shows the
    /// same clip at 0 dB without it.)
    static let oneClipSelected = LabState("One clip selected") {
        var content = SampleContent.makeMainLayout()
        for trackIndex in content.timeline.trackRows.indices {
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices
            where content.timeline.trackRows[trackIndex].clips[clipIndex].isSelected {
                content.timeline.trackRows[trackIndex].clips[clipIndex].volumeDB = 9
            }
        }
        content.selectedClipVolumeIsHeldBack = true
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// The same clip with Lines chosen, right after the choice was made:
    /// Strength stands at 100 %, Stretch is dimmed because only All moves
    /// single syllables, and the sound is being made again, a little under
    /// half done, so the small ring stands in the line of the heading
    /// "Correction".
    static let oneClipSelectedLines = LabState("One clip selected, lines") {
        var content = SampleContent.makeMainLayout()
        LabState.correctSelectedClips(in: &content, .lines, strength: 1)
        content.clipRemakeProgress = 0.4
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// The same clip with Off chosen: it is heard as recorded, and Strength
    /// and Stretch are both dimmed. The clip keeps its strength, 70 %.
    static let oneClipSelectedOff = LabState("One clip selected, correction off") {
        var content = SampleContent.makeMainLayout()
        LabState.correctSelectedClips(in: &content, .off, strength: 0.7)
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// Gives every selected clip of the made-up window a correction.
    private static func correctSelectedClips(
        in content: inout MainLayoutContent,
        _ correction: ClipCorrection,
        strength: Double
    ) {
        for trackIndex in content.timeline.trackRows.indices {
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices
            where content.timeline.trackRows[trackIndex].clips[clipIndex].isSelected {
                content.timeline.trackRows[trackIndex].clips[clipIndex].correction = correction
                content.timeline.trackRows[trackIndex].clips[clipIndex].strength = strength
            }
        }
    }
}

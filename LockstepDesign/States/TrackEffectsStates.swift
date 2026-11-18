import LockstepCore
import LockstepUI
import SwiftUI

// The effects of a whole track, which every clip of the track gets, in the panel on the right: the track's
// own list, a clip's list with its track's effects before its own, and the rows several selected clips
// share. A track's effect is shown in the panel only, so no clip here has a band or "FX" for one.
//
// Two more of these states are older ones: "A track selected" is a track without a Sound and without
// effects, and "Several clips with effects" is three clips that share one effect at levels that differ.

extension LabState {
    /// A track is selected and no clip. It has the Sound "Rap lead" and no effect: under "Effects" stands
    /// the "+" that adds one, and a quiet line that says every clip of the track gets it.
    static let trackNoEffect = LabState("A track with no effect") {
        LabMainLayout(content: LabState.trackWithEffects([]), showsInspector: true)
    }

    /// The same track with a Thick double and an echo on quarter notes. Each row reads "Every clip" where a
    /// clip's row reads "Whole clip", and its cross removes the effect from the track.
    static let trackTwoEffects = LabState("A track with two effects") {
        LabMainLayout(content: LabState.trackWithEffects([LabState.trackThick, LabState.trackEcho]), showsInspector: true)
    }

    /// What the "+" of a track's Effects holds, and the submenu "Effects" of the track's right-click menu:
    /// the six doubles under "Double", then the two echoes and Phone.
    static let menuTrackEffects = LabState("Menu track effects") {
        MenuStateSheet(
            hint: "Press the + after Effects in the panel on the right, in A track with no effect, for the real menu. "
                + "This is what it holds.",
            entries: EffectsMenu(target: .track).entries
        )
    }

    /// The track has its two effects, and words are marked in one of its clips. The rows stay listed, and
    /// under them the line says that an effect added now goes on the marked words: the "+" opens the menu
    /// of the clips, with "On Words".
    static let trackEffectsWordsMarked = LabState("A track with effects, words marked") {
        var marked = LabState.wordsMarkedContent()
        for index in marked.content.timeline.trackRows.indices where marked.content.timeline.trackRows[index].isSelected {
            marked.content.timeline.trackRows[index].effects = [LabState.trackThick, LabState.trackEcho]
        }
        return ClipSelectedWindow(content: marked.content, zoomOn: marked.zoomOn)
    }

    /// One clip of that track is selected and has changed nothing: its list shows the track's two effects,
    /// each marked "Track", at the track's levels, with the button that switches it off for this clip. The
    /// clip has no band and no "FX": a track's effect is not drawn on the clips.
    static let clipWithTrackEffects = LabState("A clip with effects from its track") {
        ClipSelectedWindow(content: LabState.clipOnTrack(with: [LabState.trackThick, LabState.trackEcho]) { _ in
            [LabState.onClip(LabState.trackThick), LabState.onClip(LabState.trackEcho)]
        })
    }

    /// The same clip with its own level for the Thick double, -3.0 dB where the track has -9.0 dB, and the
    /// echo switched off. Both rows have the arrow that puts the effect back to the track's. The row of the
    /// echo is dimmed, but not its arrow and its button.
    static let clipOwnLevelAndOff = LabState("A clip with its own level and an effect off") {
        ClipSelectedWindow(content: LabState.clipOnTrack(with: [LabState.trackThick, LabState.trackEcho]) { _ in
            [LabState.onClip(LabState.trackThick, levelDB: -3), LabState.onClip(LabState.trackEcho, isOff: true)]
        })
    }

    /// A track with Phone, which has no level, and a Thick double. The clip switched Phone off: its row has
    /// one line, dimmed, and the arrow stands in that line before the button, since there is no value for
    /// it to stand before.
    static let clipTrackPhoneOff = LabState("A clip with Phone from its track, off") {
        ClipSelectedWindow(content: LabState.clipOnTrack(with: [LabState.trackPhone, LabState.trackThick]) { _ in
            [LabState.onClip(LabState.trackPhone, isOff: true), LabState.onClip(LabState.trackThick)]
        })
    }

    /// The clip has the track's Thick double and two effects of its own: a High double on the whole clip
    /// and an echo on its last word. The track's row comes first. The clip's own two are drawn on the clip
    /// as before, "FX" for the High double and a band for the echo, and every slider stands in one line.
    static let clipTrackAndOwnEffects = LabState("An effect from the track and two own") {
        ClipSelectedWindow(content: LabState.clipOnTrack(with: [LabState.trackThick]) { syllables in
            [
                LabState.onClip(LabState.trackThick),
                ClipEffectMark(id: LabState.effectID(34), kind: .high, levelDB: -16),
                ClipEffectMark(
                    id: LabState.effectID(35),
                    kind: .echoQuarter,
                    range: LabState.lastWord(syllables),
                    levelDB: -6
                ),
            ]
        })
    }

    /// Two clips of a track with a Thick double are selected, and each has a High double of its own. They
    /// share both: the track's row, which reads "Mixed" and has the arrow because one of the two has its
    /// own level for it, and the row of the High double, whose cross removes it from both.
    static let severalClipsTrackAndOwn = LabState("Several clips, one from the track and one own") {
        var content = SampleContent.makeMainLayout()
        let alsoSelected = "Writing lines until the morning"
        for trackIndex in content.timeline.trackRows.indices
        where content.timeline.trackRows[trackIndex].clips.contains(where: \.isSelected) {
            content.timeline.trackRows[trackIndex].effects = [LabState.trackThick]
        }
        var number = 50
        LabState.changeClips(in: &content, where: { $0.isSelected || $0.displayName == alsoSelected }) { clip in
            // The clip that is selected from the start is the one with its own level.
            let ownLevel: Double? = clip.isSelected ? -3 : nil
            clip.isSelected = true
            clip.effects = [
                LabState.onClip(LabState.trackThick, levelDB: ownLevel),
                ClipEffectMark(id: LabState.effectID(number), kind: .high, levelDB: -16),
            ]
            number += 1
        }
        var thick = ClipEffectMark(id: LabState.effectID(41), kind: .thick, levelDB: -6)
        thick.ofTrack = ClipEffectMark.OfTrack(isChanged: true, trackLevelDB: -9)
        thick.isMixed = true
        content.selectedClipsEffects = [thick, ClipEffectMark(id: LabState.effectID(42), kind: .high, levelDB: -16)]
        LabState.showSeveralClips(in: &content)
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// Three clips are selected that share no effect: one has a Thick double, one a High double and one an
    /// echo on some words. Under "Effects" there is the "+" alone, and an effect that is added goes on all
    /// three.
    static let severalClipsNothingShared = LabState("Several clips that share no effect") {
        var content = SampleContent.makeMainLayout()
        let alsoSelected: Set<String> = ["Writing lines until the morning", "Hook v2"]
        LabState.changeClips(in: &content, where: { $0.isSelected || alsoSelected.contains($0.displayName) }) { clip in
            guard let range = clip.timeRange else { return }
            let length = range.upperBound - range.lowerBound
            switch clip.displayName {
            case "Writing lines until the morning":
                clip.effects = [ClipEffectMark(id: LabState.effectID(61), kind: .high, levelDB: -16)]
            case "Hook v2":
                clip.effects = [
                    ClipEffectMark(
                        id: LabState.effectID(62),
                        kind: .echoQuarter,
                        range: (range.lowerBound + 0.55 * length)...(range.lowerBound + 0.9 * length),
                        levelDB: -6
                    ),
                ]
            default:
                clip.effects = [ClipEffectMark(id: LabState.effectID(60), kind: .thick, levelDB: -9)]
            }
            clip.isSelected = true
        }
        LabState.showSeveralClips(in: &content)
        return LabMainLayout(content: content, showsInspector: true)
    }

    // MARK: Made-up effects

    /// A Thick double on a track, at the level a Thick double starts at.
    private static let trackThick = ClipEffectMark(id: effectID(31), kind: .thick, levelDB: -9)
    /// An echo on quarter notes on a track, at the level an echo starts at.
    private static let trackEcho = ClipEffectMark(id: effectID(32), kind: .echoQuarter, levelDB: -6)
    /// Phone on a track. It replaces the voice, so it has no level.
    private static let trackPhone = ClipEffectMark(id: effectID(33), kind: .phone, levelDB: 0)

    /// A track's effect as the list of one of the track's clips shows it: at the clip's own level when it
    /// has one, and switched off when the clip is heard without it.
    private static func onClip(_ effect: ClipEffectMark, levelDB: Double? = nil, isOff: Bool = false) -> ClipEffectMark {
        var mark = effect
        mark.levelDB = levelDB ?? effect.levelDB
        mark.ofTrack = ClipEffectMark.OfTrack(isChanged: levelDB != nil || isOff, isOff: isOff, trackLevelDB: effect.levelDB)
        return mark
    }

    /// The made-up window with its track selected and no clip, the Sound "Rap lead" on that track, and
    /// these effects on it.
    private static func trackWithEffects(_ effects: [ClipEffectMark]) -> MainLayoutContent {
        var content = SampleContent.makeMainLayout()
        giveSelectedTrackSound(in: &content)
        selectNoClip(in: &content)
        for index in content.timeline.trackRows.indices where content.timeline.trackRows[index].isSelected {
            content.timeline.trackRows[index].effects = effects
        }
        return content
    }

    /// The window of "Clip selected", zoomed in on the selected clip, whose track has the Sound "Rap lead"
    /// and these effects. `rows` makes the clip's list from where its syllables start: its track's effects
    /// first (`onClip`), then its own.
    private static func clipOnTrack(
        with trackEffects: [ClipEffectMark],
        rows: (_ syllableStarts: [Double]) -> [ClipEffectMark]
    ) -> MainLayoutContent {
        var content = clipWithEffects(rows)
        for index in content.timeline.trackRows.indices where content.timeline.trackRows[index].isSelected {
            content.timeline.trackRows[index].effects = trackEffects
            // With a Sound the panel is a line shorter, which leaves the list more room in the picture.
            content.timeline.trackRows[index].sound = SoundValues.builtIn("Rap lead")
        }
        return content
    }

    /// Takes, words and a Resolve start time belong to one clip only.
    private static func showSeveralClips(in content: inout MainLayoutContent) {
        content.timeline.takeRows = []
        content.selectedClipText = ""
        content.selectedClipResolveStart = ""
    }
}

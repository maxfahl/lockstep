import LockstepCore
import LockstepUI
import SwiftUI

// The effects of a clip: its doubles and its effects on words. The panel on the right lists them under
// "Effects", in the clip part between Correction and Takes, and the clip itself shows where each one is: a
// thin band along its lower edge over the stretch of an effect, and "FX" in its bar for an effect on the
// whole clip.
//
// Most states are zoomed in on the selected clip, as "Clip selected" is, so the bands can be read against
// the clip's syllables. The stretches are laid on those syllables, as a stretch that is dragged over a word
// catches on them in the app.

extension LabState {
    /// One clip is selected and has no effect. Under "Effects" stands the "+" that adds one and a quiet line
    /// that says how. The clip is drawn as every clip was before.
    static let effectsNone = LabState("A clip with no effect") {
        ClipSelectedWindow(content: LabState.clipWithEffects { _ in [] })
    }

    /// The clip has a Thick double on the whole of it: one row that reads "Whole clip", with the level at
    /// -9.0 dB where a Thick double starts, and "FX" in the clip's bar before the take count.
    static let effectsThickWholeClip = LabState("A clip with a Thick double") {
        ClipSelectedWindow(content: LabState.clipWithEffects { _ in
            [ClipEffectMark(id: LabState.effectID(1), kind: .thick, levelDB: -9)]
        })
    }

    /// The clip has a Low double, an octave down, on two words. Its row was clicked, so the row is lit, the
    /// stretch is marked in the timeline and the band's line is brighter. The band has its name.
    static let effectsLowOnWords = LabState("A Low double on two words") {
        var stretch: ClosedRange<Double>?
        var content = LabState.clipWithEffects { syllables in
            var low = ClipEffectMark(
                id: LabState.effectID(2),
                kind: .lowOctave,
                range: syllables[4]...syllables[8],
                levelDB: -10
            )
            low.isSelected = true
            stretch = low.range
            return [low]
        }
        if let stretch, let track = content.timeline.trackRows.first(where: \.isSelected) {
            content.timeline.dragging.markedStretch = MarkedStretch(trackID: track.id, range: stretch)
        }
        return ClipSelectedWindow(content: content)
    }

    /// Three effects on stretches and one on the whole clip. A Low double and a High double overlap on one
    /// word, so their bands lie over each other, the one that starts first lowest. An echo on the last word
    /// shares the lower row. Phone, which replaces the voice, has no level and so no slider.
    static let effectsThree = LabState("Three effects, two overlapping") {
        ClipSelectedWindow(content: LabState.clipWithEffects { LabState.threeEffects($0) })
    }

    /// The same clip in a row as low as Shift and scroll makes it. Named bands would take too much of the
    /// clip there, so every band is a bright line alone.
    static let effectsLowRow = LabState("Effects in a low row") {
        ClipSelectedWindow(
            content: LabState.clipWithEffects { LabState.threeEffects($0) },
            trackHeight: TrackHeight.range.lowerBound
        )
    }

    /// The whole song in view, as "Main" starts, where the selected clip is narrow: the band of the Low
    /// double on two words is too short for its name, and the clip's bar has no room for "FX" beside the
    /// take count.
    static let effectsNarrowClip = LabState("A narrow clip with an effect") {
        LabMainLayout(
            content: LabState.clipWithEffects { syllables in
                [
                    ClipEffectMark(id: LabState.effectID(1), kind: .thick, levelDB: -9),
                    ClipEffectMark(
                        id: LabState.effectID(2),
                        kind: .lowOctave,
                        range: syllables[4]...syllables[8],
                        levelDB: -10
                    ),
                ]
            },
            showsInspector: true
        )
    }

    /// The classic throw: an echo on quarter notes on the last word of the line. One row with its level at
    /// -6.0 dB, where an echo starts, and one band with its name under the last word.
    static let effectsEchoOnLastWord = LabState("An echo on the last word") {
        ClipSelectedWindow(content: LabState.clipWithEffects { syllables in
            [
                ClipEffectMark(
                    id: LabState.effectID(5),
                    kind: .echoQuarter,
                    range: LabState.lastWord(syllables),
                    levelDB: -6
                ),
            ]
        })
    }

    /// The other effects on words, each on a word of its own: Swell and Echo on eighth notes have a level,
    /// and Phone, Stutter and Tape stop, which replace the voice, have a row of one line without a slider.
    static let effectsOnWords = LabState("Effects on words") {
        ClipSelectedWindow(content: LabState.clipWithEffects { syllables in
            [
                ClipEffectMark(id: LabState.effectID(6), kind: .swell, range: syllables[0]...syllables[2], levelDB: -8),
                ClipEffectMark(id: LabState.effectID(7), kind: .phone, range: syllables[3]...syllables[5], levelDB: 0),
                ClipEffectMark(id: LabState.effectID(8), kind: .stutter, range: syllables[6]...syllables[8], levelDB: 0),
                ClipEffectMark(id: LabState.effectID(9), kind: .echoEighth, range: syllables[9]...syllables[11], levelDB: -6),
                ClipEffectMark(id: LabState.effectID(10), kind: .tapeStop, range: LabState.lastWord(syllables), levelDB: 0),
            ]
        })
    }

    /// Words are marked in a clip by dragging over them. A marked stretch takes the selection from the
    /// clips, so the panel is about the track. Under the track's own things it shows "Effects" with the "+"
    /// and one line that says the effect goes on the marked words.
    static let effectsWordsMarked = LabState("Words marked in a clip") {
        let marked = LabState.wordsMarkedContent()
        return ClipSelectedWindow(content: marked.content, zoomOn: marked.zoomOn)
    }

    /// The window of "Words marked in a clip": no clip selected, the last word of the clip that "Clip
    /// selected" selects marked on its track, and the stretch of the song to zoom on.
    static func wordsMarkedContent() -> (content: MainLayoutContent, zoomOn: ClosedRange<Double>?) {
        var content = LabState.clipWithEffects { _ in [] }
        var zoomOn: ClosedRange<Double>?
        for trackIndex in content.timeline.trackRows.indices {
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices
            where content.timeline.trackRows[trackIndex].clips[clipIndex].isSelected {
                let clip = content.timeline.trackRows[trackIndex].clips[clipIndex]
                let starts = (clip.timingMarks?.markers ?? []).map { $0.time - 0.012 }
                zoomOn = clip.timeRange
                content.timeline.trackRows[trackIndex].clips[clipIndex].isSelected = false
                if starts.count > 14 {
                    content.timeline.dragging.markedStretch = MarkedStretch(
                        trackID: content.timeline.trackRows[trackIndex].id, range: LabState.lastWord(starts)
                    )
                }
            }
        }
        // Takes, words and a Resolve start time belong to a selected clip.
        content.timeline.takeRows = []
        content.selectedClipText = ""
        content.selectedClipResolveStart = ""
        return (content, zoomOn)
    }

    /// Three clips are selected, each with a Thick double on the whole of it and a Low double on some of
    /// its words. Under "Effects" there is one row, for the Thick double they share: its level reads
    /// "Mixed", because the three differ, and its button removes it from all three. The doubles on words
    /// are not listed: they belong to each clip's own words.
    static let effectsSeveralClips = LabState("Several clips with effects") {
        var content = SampleContent.makeMainLayout()
        let alsoSelected: Set<String> = ["Writing lines until the morning", "Hook v2"]
        // The level each of the three has for its Thick double.
        var levels: [Double] = [-9, -6, -12]
        for trackIndex in content.timeline.trackRows.indices {
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices {
                var clip = content.timeline.trackRows[trackIndex].clips[clipIndex]
                guard clip.isSelected || alsoSelected.contains(clip.displayName), let range = clip.timeRange else {
                    continue
                }
                clip.isSelected = true
                let length = range.upperBound - range.lowerBound
                clip.effects = [
                    ClipEffectMark(
                        id: LabState.effectID(10 + clipIndex),
                        kind: .thick,
                        levelDB: levels.isEmpty ? -9 : levels.removeFirst()
                    ),
                    ClipEffectMark(
                        id: LabState.effectID(20 + clipIndex),
                        kind: .lowFourth,
                        range: (range.lowerBound + 0.55 * length)...(range.lowerBound + 0.9 * length),
                        levelDB: -8
                    ),
                ]
                content.timeline.trackRows[trackIndex].clips[clipIndex] = clip
            }
        }
        var shared = ClipEffectMark(id: LabState.effectID(40), kind: .thick, levelDB: -9)
        shared.isMixed = true
        content.selectedClipsEffects = [shared]
        // Takes, words and a Resolve start time belong to one clip only.
        content.timeline.takeRows = []
        content.selectedClipText = ""
        content.selectedClipResolveStart = ""
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// What the menu that adds an effect holds: the six doubles under "Double" and the six effects on words
    /// under "On Words". The clip's right-click menu has the same lines under "Effects" ("Menu clip").
    static let menuEffects = LabState("Menu effects") {
        MenuStateSheet(
            hint: "Press the + after Effects in the panel on the right, in A clip with no effect, for the real menu. "
                + "This is what it holds.",
            entries: EffectsMenu().entries
        )
    }

    /// The window of "Clip selected", zoomed-in content with timing marks on the selected clip, and on that
    /// clip the effects `effects` makes from where the clip's syllables start, in song seconds.
    static func clipWithEffects(
        _ effects: (_ syllableStarts: [Double]) -> [ClipEffectMark]
    ) -> MainLayoutContent {
        var content = ClipSelectedContent.make(subBeatsPerBeat: 4, syllables: ClipSelectedContent.sixteenthLine)
        for trackIndex in content.timeline.trackRows.indices {
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices
            where content.timeline.trackRows[trackIndex].clips[clipIndex].isSelected {
                var clip = content.timeline.trackRows[trackIndex].clips[clipIndex]
                // No readout at a marker: these states are about the bands.
                clip.timingMarks?.shownReadout = nil
                // A stretch starts a moment before its first syllable's marker, where the sound begins.
                let starts = (clip.timingMarks?.markers ?? []).map { $0.time - 0.012 }
                clip.effects = starts.count > 14 ? effects(starts) : []
                content.timeline.trackRows[trackIndex].clips[clipIndex] = clip
            }
        }
        return content
    }

    /// A Thick double on the whole clip, a Low and a High double that overlap on one word, an echo on the
    /// last word and Phone on a word between them.
    private static func threeEffects(_ syllables: [Double]) -> [ClipEffectMark] {
        [
            ClipEffectMark(id: effectID(1), kind: .thick, levelDB: -9),
            ClipEffectMark(id: effectID(2), kind: .lowOctave, range: syllables[2]...syllables[6], levelDB: -10),
            ClipEffectMark(id: effectID(3), kind: .high, range: syllables[4]...syllables[8], levelDB: -16),
            ClipEffectMark(id: effectID(4), kind: .phone, range: syllables[9]...syllables[11], levelDB: 0),
            ClipEffectMark(id: effectID(5), kind: .echoQuarter, range: syllables[12]...syllables[14], levelDB: -6),
        ]
    }

    /// The stretch of the clip's last word, a word of two syllables: from where the syllable before the
    /// last starts to where the last one's sound ends. Wide enough for a band to have its name.
    static func lastWord(_ syllables: [Double]) -> ClosedRange<Double> {
        let last = syllables.last ?? 0
        return (syllables.dropLast().last ?? last)...(last + 0.2)
    }

    /// A fixed identity made from a small number, so an effect keeps its id.
    static func effectID(_ number: Int) -> UUID {
        UUID(uuid: (0xEF, 0xFE, 0xC7, 0x00, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, UInt8(number & 0xFF)))
    }
}

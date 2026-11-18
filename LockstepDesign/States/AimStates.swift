import LockstepUI
import SwiftUI

// What a clip's correction aims at: the row "Aim at" under "Correction" in the panel on the right, and the
// timing marks of a clip that aims at another track. All of them show the same made-up window: a track
// "Lead" with a line on it, and right under it a track "Double" with the same line recorded again, selected.

extension LabState {
    /// The double aims at the beat, as every clip starts: the box after "Aim at" reads "The beat", and the
    /// row of sub-beats can be used.
    static let aimAtBeat = LabState("A clip aimed at the beat") {
        LabMainLayout(content: AimContent.make(aimsAtLead: false), showsInspector: true)
    }

    /// The double aims at the track "Lead": the box reads "Lead", and the row of sub-beats is dimmed, because
    /// the clip is held against the lead's syllables and its sub-beats are not used.
    static let aimAtLead = LabState("A clip aimed at Lead") {
        LabMainLayout(content: AimContent.make(aimsAtLead: true), showsInspector: true)
    }

    /// What the menu of the box holds for that clip: "The beat", and under a line the three other tracks,
    /// with "Lead" ticked.
    static let menuAimAt = LabState("Menu aim at") {
        let content = AimContent.make(aimsAtLead: true).timeline
        return MenuStateSheet(
            hint: "Press the box after Aim at in the panel on the right, in A clip aimed at Lead, for the real menu. "
                + "This is what it holds.",
            entries: AimMenu(
                aimTrackID: AimContent.leadTrackID,
                tracks: content.trackRows
                    .filter { $0.id != AimContent.doubleTrackID }
                    .map { AimTrack(id: $0.id, name: $0.name) }
            ).entries
        )
    }

    /// The same clip with Off chosen: it is heard as recorded, so "Aim at", Strength and Stretch are dimmed.
    /// The clip keeps its aim, and its sub-beats stay dimmed.
    static let aimAtLeadOff = LabState("A clip aimed at Lead, correction off") {
        LabMainLayout(content: AimContent.make(aimsAtLead: true, correction: .off), showsInspector: true)
    }

    /// Three clips are selected, on the tracks "Double" and "Ad-libs". The double aims at "Lead" and the two
    /// others at the beat, so the box reads "Mixed". The sub-beats can be used, because some of them aim at
    /// the beat. The menu would list "Lead" and "Lead 2", the tracks none of the three is on.
    static let aimMixed = LabState("Several clips, aim mixed") {
        var content = AimContent.make(aimsAtLead: true)
        let alsoSelected: Set<String> = ["Writing lines until the morning", "Hook v2"]
        for trackIndex in content.timeline.trackRows.indices {
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices
            where alsoSelected.contains(content.timeline.trackRows[trackIndex].clips[clipIndex].displayName) {
                content.timeline.trackRows[trackIndex].clips[clipIndex].isSelected = true
            }
        }
        // Takes, words and a Resolve start time belong to one clip only.
        content.timeline.takeRows = []
        content.selectedClipText = ""
        content.selectedClipResolveStart = ""
        return LabMainLayout(content: content, showsInspector: true)
    }

    /// The timing marks of the double, zoomed in on it, with the lead's clip in the row above. In place of
    /// sub-beat lines the double has a line at every syllable of the lead, strong and with a small bar on
    /// top. A marker is coloured by its distance to its partner: on it, or slightly off. One syllable of the
    /// double has no partner, a word the lead does not have: its marker is neutral, and the readout shown at
    /// it says "No match".
    static let doubleAgainstLead = LabState("A double against its lead") {
        ClipSelectedWindow(content: AimContent.make(aimsAtLead: true))
    }
}

/// The made-up window of the aim states.
enum AimContent {
    /// The track "Lead" of the sample window, which the double aims at.
    static let leadTrackID = track(named: "Lead")
    /// The track "Double" of the sample window, with the selected clip.
    static let doubleTrackID = track(named: "Double")

    /// The double's line, each syllable a little off its sub-beat, mostly late, as a second recording of a
    /// line is. The readout is shown at the eighth, the word the lead does not have.
    private static let doubleLine = [
        FakeSyllable(step: 0, offset: 12),
        FakeSyllable(step: 1, offset: 25),
        FakeSyllable(step: 1, offset: -5),
        FakeSyllable(step: 1, offset: 18),
        FakeSyllable(step: 2, offset: 30),
        FakeSyllable(step: 1, offset: 8),
        FakeSyllable(step: 1, offset: 22),
        FakeSyllable(step: 1, offset: 40, showsReadout: true),
        FakeSyllable(step: 2, offset: 15),
        FakeSyllable(step: 1, offset: -10),
        FakeSyllable(step: 1, offset: 27),
        FakeSyllable(step: 2, offset: 20),
        FakeSyllable(step: 1, offset: 35),
        FakeSyllable(step: 1, offset: 6),
    ]

    /// How far each syllable of the double is from its partner in the lead, in milliseconds, late positive.
    /// Nil for the syllable that has no partner.
    private static let partnerOffsets: [Double?] = [4, 19, -8, 2, 24, -3, 12, nil, 6, -15, 9, 0, 28, -5]

    /// Up to this far from its partner, a syllable counts as on it. Milliseconds.
    private static let onPartnerLimit = 10.0

    /// - Parameters:
    ///   - aimsAtLead: The double aims at the track "Lead". False leaves it aimed at the beat, with the
    ///     marks every clip has.
    ///   - correction: What is chosen of Off, Lines and All for the double.
    static func make(aimsAtLead: Bool, correction: ClipCorrection = .all) -> MainLayoutContent {
        var content = ClipSelectedContent.make(subBeatsPerBeat: 4, syllables: doubleLine)
        var rows = content.timeline.trackRows
        guard let leadIndex = rows.firstIndex(where: { $0.id == leadTrackID }),
              let doubleIndex = rows.firstIndex(where: { $0.id == doubleTrackID }),
              let clipIndex = rows[doubleIndex].clips.firstIndex(where: \.isSelected),
              let range = rows[doubleIndex].clips[clipIndex].timeRange,
              var marks = rows[doubleIndex].clips[clipIndex].timingMarks
        else { return content }

        // Where the lead's syllables are: each of the double's, taken back by its distance to its partner.
        let leadTimes = zip(marks.markers, partnerOffsets).compactMap { marker, offset in
            offset.map { marker.time - $0 / 1000 }
        }

        var double = rows[doubleIndex].clips[clipIndex]
        double.correction = correction
        if aimsAtLead {
            double.aimTrackID = leadTrackID
            for (index, offset) in partnerOffsets.enumerated() where index < marks.markers.count {
                marks.markers[index].offsetMilliseconds = offset ?? 0
                marks.markers[index].timing = offset.map { abs($0) <= onPartnerLimit ? .onBeat : .slightlyOff } ?? .unpaired
            }
            marks.subBeatTimes = []
            marks.leadSyllableTimes = leadTimes
            double.timingMarks = marks
        }
        rows[doubleIndex].clips[clipIndex] = double

        // The lead's own recording of the line, at the same place on its track.
        var lead = ClipBox(
            id: UUID(uuid: (0x51, 0x11, 0xA1, 0x30, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1)),
            displayName: double.displayName,
            segments: [ClipSegment(
                range: range,
                levels: ClipSelectedContent.voiceLevels(syllableStarts: leadTimes, range: range)
            )]
        )
        lead.correction = .all
        lead.strength = 0.7
        rows[leadIndex].clips.append(lead)

        // The lead stands right above its double.
        let leadRow = rows[leadIndex]
        let doubleRow = rows[doubleIndex]
        rows.removeAll { $0.id == leadTrackID || $0.id == doubleTrackID }
        content.timeline.trackRows = [leadRow, doubleRow] + rows
        return content
    }

    /// The id of a track of the sample window.
    private static func track(named name: String) -> UUID {
        SampleContent.make().trackRows.first { $0.name == name }?.id ?? UUID()
    }
}

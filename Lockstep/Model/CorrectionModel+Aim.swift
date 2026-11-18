import Foundation
import LockstepCore
import LockstepUI

/// The aim of a clip's correction: the beat, or another track.
///
/// A double that Max records himself is held against the lead in place of the beat, so the two voices sound
/// like one. The rules are in `LockstepCore` (`Project.aim(of:reach:)`, `SyllableMatch`, `TimingTargets`).
/// This file joins them into the app:
///
/// - Choosing: the row "Aim at" under "Correction" in the panel on the right, Clip > Correction > Aim at the
///   Beat and the submenu Aim at, and the submenu Aim at in a clip's right-click menu all end in
///   `setSelectedClipsAim(_:)`, one step that can be undone.
/// - What is heard: `heldAgainst(_:in:pass:)` gathers the syllables of the aimed track where they are heard,
///   and `tighteningInputs(of:in:pass:)` hands them in. They are part of what the double's sound is made
///   from, so the sound is made again when the lead's sound changes: the lead leads.
/// - What is drawn: `showAims(in:of:)` tells every clip in the window what it aims at, and
///   `timingMarksAgainstLead(of:in:)` measures the syllable markers of such a clip against its partners.
/// - For an agent: `-lockedDouble <wav file>` (`lockDoubleLaunchTrack()`).
///
/// An aim that cannot be followed counts as the beat everywhere: at a track that is gone (deleted or merged
/// away; Undo brings the track back and the aim with it, because the clip keeps the id), at the clip's own
/// track, and at a track whose clips over this one aim back. That last rule is what keeps two clips from
/// waiting for each other's sound for ever.
///
/// Where the lead is heard, and one pass being enough. The lead's syllables are asked for at two moments,
/// and the answer is taken from two places on purpose:
///
/// - While the clips are gone through for the player (`tightenedClips(of:)`), from the sound each lead clip
///   has in force in that very going-through (`soundInForce`): the sound that was made for it, as long as it
///   still plays the same pieces at the same place. `tightenWork.heard` is what the player was handed the
///   time before, and with it the double would see the lead's new sound one going-through late, with nothing
///   to cause that one. So when the lead's sound arrives, the going-through that hands it to the player also
///   finds the double out of date and starts making its sound.
/// - While the markers are drawn, from what is heard right now (`heardLines`), like every other marker.
extension CorrectionModel {
    // MARK: Choosing

    /// What a clip's correction is held against in one going-through of the clips.
    enum HeldAgainst {
        /// The sub-beats of the song, as every clip starts.
        case beat
        /// The syllables of the track it aims at, where they are heard.
        case lead([TimingTargets.Target])
        /// It aims at a track, and the syllables of a recording there are still being looked for.
        case leadNotKnownYet
    }

    /// The tracks the selected clips can aim at, from top to bottom: every track that none of them is on.
    /// The lines of Clip > Correction > Aim at.
    var aimTargets: [MergeTarget] {
        let project = store.project
        let ids = selection.clipIDs
        guard !ids.isEmpty else { return [] }
        return project.tracks
            .filter { track in !track.clips.contains { ids.contains($0.id) } }
            .map { MergeTarget(id: $0.id, name: $0.name) }
    }

    /// Whether the aim can be chosen now: it needs a selected clip.
    var canChooseAim: Bool {
        !selection.clipIDs.isEmpty
    }

    /// Whether every selected clip is held against this track right now, or against the beat for nil,
    /// which ticks its line in the menus. An aim that counts as the beat is the beat here.
    func aimIsChosen(_ trackID: UUID?) -> Bool {
        let project = store.project
        let clips = project.clips(selection.clipIDs)
        let reach = tightenSettings.partnerReach
        return !clips.isEmpty && clips.allSatisfy { project.aim(of: $0, reach: reach) == trackID }
    }

    /// A line was chosen in the row "Aim at" or in one of the menus: the selected clips, and the takes that
    /// wait behind them, aim at this track, or at the beat for nil. One step that can be undone. Their sound
    /// is then made again.
    ///
    /// A selected clip that is on the chosen track itself is left as it is: a clip cannot aim at its own
    /// track. The panel and the menu bar do not offer such a track, but a right-click on one clip of a
    /// selection over several tracks does.
    func setSelectedClipsAim(_ trackID: UUID?) {
        let aimed: Track? = trackID.flatMap { store.project.track($0) }
        let onTrack = Set((aimed?.clips ?? []).map(\.id))
        let ids = selection.clipIDs.subtracting(onTrack)
        changeCorrection("Change Aim") { $0.setClips(ids, aimTrack: trackID) }
    }

    // MARK: What is heard

    /// What a clip's correction is held against right now.
    ///
    /// For a clip whose aim can be followed (`Project.aim(of:reach:)`) it is the syllables of the shown
    /// clips of the aimed track that lie over it, widened by the furthest slide and the furthest move of a
    /// syllable (`TightenSettings.partnerReach`). Each is where it is heard from this going-through on: after
    /// that clip's own correction, and as recorded while its sound is still being made or it is Off. With
    /// Stretch on for the clip, each also says where its note ends, so held notes can be matched. Without it
    /// no note end is used, so none is worked out and the clip's sound does not depend on one.
    func heldAgainst(_ clip: Clip, in project: Project, pass: TighteningPass) -> HeldAgainst {
        // Asked for every corrected clip in every going-through, and nearly all of them aim at the beat.
        guard clip.aimTrack != nil else { return .beat }
        let reach = tightenSettings.partnerReach
        guard project.aim(of: clip, reach: reach) != nil else { return .beat }
        let leads = project.aimedClips(of: clip, reach: reach)
        let markers = syllableMarkers.byRecording
        guard leads.allSatisfy({ $0.segments.allSatisfy { markers[$0.recordingID] != nil } }) else {
            return .leadNotKnownYet
        }
        return .lead(leadSyllables(in: leads, of: project, withNoteEnds: clip.stretchesVoice) { lead, segment in
            guard let made = self.soundInForce(of: lead, in: project, pass: pass),
                  made.segments.indices.contains(segment), made.segments[segment].samples != nil
            else { return nil }
            return made.segments[segment].lines
        })
    }

    /// The tightened sound a clip is heard with from this going-through of the clips on, or nil for a clip
    /// that is heard as recorded. It is the rule of `tightenedClips(of:)`: the sound that was made for the
    /// clip, also one that is out of date, for as long as the clip can be tightened and plays the same
    /// pieces at the same place.
    private func soundInForce(of clip: Clip, in project: Project, pass: TighteningPass) -> TightenWork.MadeClip? {
        guard clip.hasTimingFix, let made = tightenWork.made[clip.id],
              let inputs = tighteningInputs(of: clip, in: project, pass: pass),
              made.inputs.segments == inputs.segments
        else { return nil }
        return made
    }

    /// The syllables of some clips of a track, each where it is heard, in no order.
    ///
    /// - Parameters:
    ///   - withNoteEnds: also says where each syllable's note ends, where the sound of its recording is
    ///     loaded. That needs how loud the recording is, which is read or measured once for each recording
    ///     and then kept.
    ///   - lines: the lines one segment of one of the clips is heard with, each with where its sound goes, or
    ///     nil for a segment that is heard as recorded.
    private func leadSyllables(
        in leads: [Clip],
        of project: Project,
        withNoteEnds: Bool,
        lines: (_ lead: Clip, _ segment: Int) -> [ClipTightening.Line]?
    ) -> [TimingTargets.Target] {
        var targets: [TimingTargets.Target] = []
        for lead in leads {
            let found = project.markers(in: lead, allMarkers: syllableMarkers.byRecording)
            for (index, segment) in lead.segments.enumerated() {
                let inSegment = found
                    .filter {
                        $0.recordingID == segment.recordingID
                            && $0.sample >= segment.inSample && $0.sample < segment.outSample
                    }
                    .sorted { $0.sample < $1.sample }
                guard !inSegment.isEmpty else { continue }
                let heard = lines(lead, index)
                // How far the sound at a place in the recording is moved, in seconds: as the line of the
                // syllable it belongs to is. The end of a note is asked about with its own syllable, because
                // it can lie in the margin after the line's last sound.
                func shift(at sample: Int, ofSyllableAt marker: Int) -> Double {
                    guard let line = heard?.first(where: { marker >= $0.line.startSample && marker < $0.line.endSample })
                    else { return 0 }
                    return Double(line.map.result(ofSource: sample) - sample) / Lockstep.sampleRate
                }
                var ends: [Int]?
                if withNoteEnds, let sound = loadedSounds.sounds[segment.recordingID] {
                    let levels = tightenWork.levels.levels(
                        ofRecording: segment.recordingID, sound: sound, in: store.package
                    )
                    ends = SyllableMatch.noteEnds(of: inSegment.map(\.sample), until: segment.outSample, levels: levels)
                }
                for (place, marker) in inSegment.enumerated() {
                    var target = TimingTargets.Target(
                        time: marker.songTime + shift(at: marker.sample, ofSyllableAt: marker.sample)
                    )
                    if let end = ends?[place] {
                        target.noteEnd = marker.songTime + Double(end - marker.sample) / Lockstep.sampleRate
                            + shift(at: end, ofSyllableAt: marker.sample)
                    }
                    targets.append(target)
                }
            }
        }
        return targets
    }

    // MARK: What is drawn

    /// Called by `showFeels`, so by `showClips`: tells every clip in the rows which track its correction is
    /// held against right now, for the row "Aim at" in the panel on the right and the tick in the clip's
    /// right-click menu. An aim that counts as the beat is shown as the beat, because that is what is heard.
    func showAims(in rows: inout [TrackRow], of project: Project) {
        guard FeatureSet.built.contains(.lockToLead) else { return }
        let reach = tightenSettings.partnerReach
        var aims: [UUID: UUID] = [:]
        for track in project.tracks {
            for clip in track.clips where clip.isActiveTake && clip.aimTrack != nil {
                aims[clip.id] = project.aim(of: clip, reach: reach)
            }
        }
        for row in rows.indices {
            for index in rows[row].clips.indices where rows[row].clips[index].aimTrackID != aims[rows[row].clips[index].id] {
                rows[row].clips[index].aimTrackID = aims[rows[row].clips[index].id]
            }
        }
    }

    /// The timing marks of a clip that is held against another track, or nil for a clip that is held
    /// against the beat.
    ///
    /// Each syllable is judged by its distance to its partner in the aimed track, with both where they are
    /// heard right now, and one without a partner is neutral ("No match"). The partners are found as the
    /// correction finds them (`MarkerDistance.measure`). The lines to judge against are the aimed track's
    /// syllables across the clip, in place of the sub-beats.
    func timingMarksAgainstLead(of clip: Clip, in project: Project) -> ClipTimingMarks? {
        guard clip.aimTrack != nil else { return nil }
        let settings = tightenSettings
        guard project.aim(of: clip, reach: settings.partnerReach) != nil else { return nil }
        let lead = leadSyllables(
            in: project.aimedClips(of: clip, reach: settings.partnerReach), of: project, withNoteEnds: false
        ) { lead, segment in
            self.heardLines(ofSegment: segment, of: lead.id)
        }
        let found = markers(in: clip)
        let times = found.map { shownTime(of: $0, in: clip) }
        let measured = MarkerDistance.measure(
            times: times,
            excluded: Set(found.indices.filter { found[$0].isExcluded }),
            against: .syllables(lead),
            settings: settings
        )
        let shown = found.indices.map { index in
            let timing: LockstepUI.SyllableMarker.Timing = switch (measured[index].offset, measured[index].kind) {
            case (nil, _): .unpaired
            case (_, .onBeat): .onBeat
            default: .slightlyOff
            }
            return LockstepUI.SyllableMarker(
                id: Self.markerID(recording: found[index].recordingID, sample: found[index].sample),
                time: times[index],
                offsetMilliseconds: (measured[index].offset ?? 0) * 1000,
                timing: timing,
                isExcluded: found[index].isExcluded
            )
        }
        var marks = ClipTimingMarks(
            markers: shown,
            subBeatTimes: [],
            subBeatLineFade: Self.subBeatLineFade,
            readoutDelay: Self.markerReadoutDelay
        )
        // The lines across the clip as it is drawn, which is longer where a line slid out of it.
        let reach = heardReach(of: clip)
        if let start = project.start(of: clip), let end = project.end(of: clip), end > start {
            let drawn = (start - reach.before)...(end + reach.after)
            marks.leadSyllableTimes = lead.map(\.time).filter(drawn.contains).sorted()
        } else {
            marks.leadSyllableTimes = []
        }
        return marks
    }

    // MARK: For an agent's run

    /// `-lockedDouble <wav file>`: once the first project is open, the takes given with `-addTake` are in
    /// it and `-tighten`, `-strength` and `-stretch` have acted on the first track, a second track is added
    /// with the file on it as a take aimed at the very start of the song, and its clip gets All at 100 %
    /// aimed at the first track (with Stretch on when `-stretch` was given). One line on standard error
    /// says how it went. An agent that checks the app cannot choose from the row "Aim at", and cannot hear.
    func lockDoubleLaunchTrack() {
        let work = tightenWork
        guard work.lockedDoubleLaunch == nil, let url = LaunchOptions.current.lockedDouble else { return }
        work.lockedDoubleLaunch = Task { [weak self] in
            await self?.takeStatus.ended()
            // The lead first, so the double is matched to it as it is heard, and their lines come in order.
            await self?.launchTightenedFirstTrack()
            guard let line = await self?.lockDoubleForAgent(url) else { return }
            Agent.tell(line)
        }
    }

    /// Does what `-lockedDouble` asks and gives the line that says how it went.
    ///
    /// For every syllable of the double the line gives where it was recorded in the song, where its partner
    /// in the first track is heard or that it has none, and how far it is moved in what is heard, in
    /// milliseconds with the slide of its line included. Negative is earlier.
    private func lockDoubleForAgent(_ url: URL) async -> String {
        let refusal = "could not lock the double \(url.path): "
        guard let lead = store.project.tracks.first else { return refusal + "the project has no track" }
        guard let added = await addTakeOnNewTrack(url) else { return refusal + "no project is open" }
        guard added.problem.isEmpty else { return refusal + added.problem }
        let stretches = LaunchOptions.current.stretches
        // One change, so the sound is made once: All at 100 %, the aim, and Stretch if `-stretch` was given.
        changeCorrection("Change Correction") { project in
            var changed = [
                project.setClips([added.clipID], tighten: .all),
                project.setClips([added.clipID], strength: 1),
                project.setClips([added.clipID], aimTrack: lead.id),
            ]
            if stretches { changed.append(project.setClips([added.clipID], stretch: true)) }
            return changed.contains(true)
        }
        // The syllables of the new recording and of the lead's are found in the background, and the lead's
        // sound may still be on its way. The double is done when both tracks have the sound they ask for.
        let tracks: Set<UUID> = [lead.id, added.trackID]
        let isMade = await waitForAgent(seconds: 120, until: { model in
            let project = model.store.project
            guard let double = project.clip(added.clipID), model.tighteningInputs(of: double, in: project, pass: TighteningPass(voices: model.voice.heard)) != nil
            else { return false }
            let onTracks = Set(project.tracks.filter { tracks.contains($0.id) }.flatMap { $0.clips.map(\.id) })
            return model.clipsToTighten(in: ProjectLookup(project), voices: model.voice.heard)
                .filter { onTracks.contains($0.clip.id) }
                .allSatisfy { model.tightenWork.made[$0.clip.id]?.isMade(from: $0) == true }
        })
        guard isMade, let made = tightenWork.made[added.clipID] else { return refusal + "the sound was not made" }
        let lines = made.segments.flatMap(\.lines)
        var listed: [String] = []
        var paired = 0
        for line in lines {
            for marker in line.line.markers {
                let place = line.songStart + Double(marker - line.line.startSample) / Lockstep.sampleRate
                let moveMs = Double(line.map.result(ofSource: marker) - marker) / Lockstep.sampleRate * 1_000
                if let partner = line.partners[marker] {
                    paired += 1
                    listed.append(String(format: "%.3f s onto %.3f s %+.1f ms", place, partner, moveMs))
                } else {
                    listed.append(String(format: "%.3f s no partner %+.1f ms", place, moveMs))
                }
            }
        }
        let noteEnds = lines.reduce(0) { $0 + $1.matchedNoteEnds }
        let project = store.project
        let aimed = project.clip(added.clipID).flatMap { project.aim(of: $0, reach: tightenSettings.partnerReach) }
        let doubleName = project.track(added.trackID)?.name ?? ""
        let against = aimed == lead.id ? "to the track \"\(lead.name)\"" : "to the beat, because its aim cannot be followed"
        let counts = "\(listed.count) \(listed.count == 1 ? "syllable" : "syllables") in "
            + "\(lines.count) \(lines.count == 1 ? "line" : "lines"), \(paired) paired, "
        let work = "\(noteEnds) note \(noteEnds == 1 ? "end" : "ends") matched, "
            + "\(made.stretchedRuns) \(made.stretchedRuns == 1 ? "run" : "runs") stretched"
        return "locked the double on the track \"\(doubleName)\" \(against): " + counts + work
            + (listed.isEmpty ? "" : ": " + listed.joined(separator: ", "))
    }
}

/// One going-through of the clips for their tightened sounds: what each clip's sound depends on, kept so
/// that a clip others aim at is asked about once. It lasts for one call, and nothing in it is kept after.
@MainActor
final class TighteningPass {
    /// By clip id. A clip that cannot be tightened yet is in here with nil.
    var inputs: [UUID: ClipTightening.Inputs?] = [:]
    /// Which voice stands in for which recording on which track in this going-through: every clip's inputs
    /// name the voices of its own track from it. `.none` for Max's own recordings.
    let voices: TrackVoices

    init(voices: TrackVoices) {
        self.voices = voices
    }
}

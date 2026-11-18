import Foundation
import LockstepCore
import LockstepUI

/// The effects of clips and of tracks: a part of the app's model.
///
/// It holds adding an effect to clips, removing one, turning its level, marking its stretch from its
/// row in the panel, and what the window shows of a clip's effects: the rows under "Effects" in the
/// panel on the right, the bands on the clip and the mark "FX" in its bar. The effects are the six
/// doubles, a second voice made from the take itself, and the six effects on words: two echoes, a
/// phone voice, a stutter, a tape stop and a swell.
///
/// Since phase 36.5 it also holds the effects of a track, which every clip of the track is heard
/// with: adding one, removing one and its level. And what the selected clips change of them for
/// themselves: their own level for a track's effect, switching it off and on, and the mark that puts
/// it back. With several clips selected the panel lists the effects they share
/// (`Project.sharedEffects`), and a row's level and button act on all of them.
///
/// It only edits the project. A clip's finished sound is made from what the project says
/// (`ClipSoundRecipe`), so the sound follows when the clips are handed over (`followClips`), and the
/// part that makes it is the Sound part.
///
/// Where an added effect goes (`addEffect(_:)`):
/// - With a stretch marked in a clip: on that stretch of every shown clip of the track that the
///   stretch crosses, each with a span of its own whose ends are caught on the clip's syllables
///   (`ClipSpan.catching`). The marked stretch is then cleared and those clips are selected, so the
///   panel shows what was added.
/// - Otherwise: on the whole of every selected clip, and on the takes that wait behind them.
///
/// Everything is measured where it is heard: on a clip whose timing is corrected, a stretch is caught
/// and drawn with how far the correction moved each sample (`CorrectionModel.heardShift`), which is
/// also what the clip's sound is made with.
///
/// What the window calls: the menu that adds an effect (as commands, `AppCommand.adding`), the
/// level of an effect (`setEffectLevel`), the button that removes one (`removeEffect`) and a click on
/// an effect's row (`effectRowPressed`). For a track's effect on the selected clips: the button that
/// switches it off and on (`switchEffectOffOrOn`) and the mark that puts it back (`resetEffect`). For
/// a track: the menu that gives it an effect (as commands, `AppCommand.addingToTrack`), an effect's
/// level (`setTrackEffectLevel`) and the button that removes it (`removeTrackEffect`). The rows and
/// the bands it adds in `showEffects`.
@MainActor
final class ClipEffectsModel {
    // The ground it is handed.
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let store: ProjectStore

    // The parts it is handed, and calls directly.
    /// The syllables and pauses a stretch catches on, and how far the correction moved a sample.
    private let correction: CorrectionModel
    /// The pacing of a dragged level, and for `-double` and `-wordEffect` the finished sound that was made.
    private let sound: SoundModel
    /// The marked stretch: clearing it, and marking the stretch of an effect.
    private let clipEditing: ClipEditingModel

    /// The effect whose row in the panel was clicked last, with the stretch that was marked for it.
    /// Its row is lit for as long as that stretch is the marked one and its clip alone is selected.
    private var lit: (clipID: UUID, effectID: UUID, stretch: MarkedStretch)?
    /// Where the effects of each clip with an effect on a stretch are drawn, by clip id, with what
    /// that was worked out from. Working it out reads where the clip's first sound lies, so the answer
    /// is kept while the clip, its tightened sounds and its place are the same.
    private var shown: [UUID: Shown] = [:]

    // What it asks of code that holds it, or of the model's routing. `wireClipEffects` sets them.
    /// Lets the player and the window follow the clips of a project (`followClips(of:)`, the clips'
    /// part).
    var followClips: (Project) -> Void = { _ in }

    init(
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore,
        correction: CorrectionModel,
        sound: SoundModel,
        clipEditing: ClipEditingModel
    ) {
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
        self.correction = correction
        self.sound = sound
        self.clipEditing = clipEditing
    }
}

extension ClipEffectsModel {
    // MARK: Adding an effect

    /// What Undo calls the adding of an effect of a kind.
    private static func addingName(of kind: ClipEffect.Kind) -> String {
        kind.isDouble ? "Add Double" : "Add Effect"
    }

    /// Whether an effect can be added right now: a stretch is marked that crosses a shown clip of its
    /// track, or, with no stretch marked, clips are selected. The menus read it.
    var canAddEffect: Bool {
        guard loadedSounds.song != nil else { return false }
        guard let stretch = selection.markedStretch else { return !selection.clipIDs.isEmpty }
        let project = store.project
        return project.track(stretch.trackID)?.clips.contains { clip in
            clip.isActiveTake && Self.crosses(stretch, clip, in: project)
        } ?? false
    }

    /// Whether the marked stretch crosses this clip, so that an effect added now goes on a stretch of
    /// it. A right-click on such a clip leaves the stretch alone.
    func markedStretchCrosses(_ clipID: UUID) -> Bool {
        let project = store.project
        guard let stretch = selection.markedStretch, let clip = project.clip(clipID),
              project.track(stretch.trackID)?.clips.contains(where: { $0.id == clipID }) == true
        else { return false }
        return Self.crosses(stretch, clip, in: project)
    }

    private static func crosses(_ stretch: MarkedStretch, _ clip: Clip, in project: Project) -> Bool {
        guard let start = project.start(of: clip), let end = project.end(of: clip) else { return false }
        return start < stretch.range.upperBound && end > stretch.range.lowerBound
    }

    /// Adds an effect of a kind, at the level its kind starts with, as one step that can be undone:
    /// on the marked stretch when one is marked, and otherwise on the whole of every selected clip.
    /// Nothing happens during a take, or when there is nothing to put it on.
    func addEffect(_ kind: ClipEffect.Kind) {
        guard takeStatus.phase == nil, loadedSounds.song != nil else { return }
        if let stretch = selection.markedStretch {
            add(kind, on: spans(of: stretch, in: store.project), ofTrack: stretch.trackID)
            return
        }
        let ids = selection.clipIDs
        var changed = store.project
        for id in ids {
            changed.addEffect(id, kind: kind)
        }
        guard changed != store.project else { return }
        store.edit(Self.addingName(of: kind)) { $0 = changed }
        followClips(store.project)
    }

    /// The span each shown clip of a track gets from a marked stretch: the stretch with its ends
    /// caught on the clip's syllables, pauses and edges, as samples of the clip's recording. A clip
    /// the stretch does not cross, or of which it holds less than 20 ms, gets none.
    ///
    /// - Parameter only: the one clip to look at, for `-double` and `-wordEffect`. Left out, every shown
    ///   clip of the track.
    private func spans(
        of stretch: MarkedStretch,
        in project: Project,
        only: UUID? = nil
    ) -> [(clipID: UUID, span: ClipSpan)] {
        guard let track = project.track(stretch.trackID), stretch.range.upperBound > stretch.range.lowerBound
        else { return [] }
        let range = stretch.range.lowerBound..<stretch.range.upperBound
        let tightened = correction.heardTightened
        return track.clips.compactMap { clip in
            guard clip.isActiveTake, only == nil || only == clip.id, Self.crosses(stretch, clip, in: project)
            else { return nil }
            let points = correction.catchPoints(in: clip)
            let span = ClipSpan.catching(
                range, in: clip, of: project, markers: points.markers, pauses: points.pauses,
                heardShift: { [correction] segment, sample in
                    correction.heardShift(
                        ofSample: sample, inSegment: segment, of: clip, tightened: tightened, on: track,
                        voices: correction.voice.heard
                    )
                }
            )
            return span.map { (clip.id, $0) }
        }
    }

    /// Puts an effect on a stretch of each of these clips, as one step. The marked stretch is then
    /// cleared and the clips are selected: the stretch has done its work, and the panel shows the
    /// clips with the effect that was added.
    private func add(_ kind: ClipEffect.Kind, on spans: [(clipID: UUID, span: ClipSpan)], ofTrack trackID: UUID) {
        var changed = store.project
        var added: Set<UUID> = []
        for target in spans where changed.addEffect(target.clipID, kind: kind, span: target.span) != nil {
            added.insert(target.clipID)
        }
        guard !added.isEmpty else { return }
        store.edit(Self.addingName(of: kind)) { $0 = changed }
        lit = nil
        clipEditing.clearMarkedStretch()
        selection.clipIDs = added
        selection.trackID = trackID
        followClips(store.project)
    }
}

extension ClipEffectsModel {
    // MARK: A track's effects

    /// Whether the selected track can be given an effect right now: a song is open. The menus read it.
    var canAddTrackEffect: Bool {
        loadedSounds.song != nil && !loadedSounds.isOpening && selection.recordingTrackID != nil
    }

    /// Gives the selected track an effect of a kind, at the level its kind starts with, as one step
    /// that can be undone, "Add Track Effect". Every clip of the track is heard with it from then on,
    /// also one that is recorded there later. Nothing happens during a take.
    func addTrackEffect(_ kind: ClipEffect.Kind) {
        guard takeStatus.phase == nil, loadedSounds.song != nil, let trackID = selection.recordingTrackID
        else { return }
        var changed = store.project
        guard changed.addTrackEffect(trackID, kind: kind) != nil else { return }
        store.edit("Add Track Effect") { $0 = changed }
        followClips(store.project)
    }

    /// The level of an effect of a track was moved, in the track's rows of the panel. While it is
    /// dragged the track's clips are only made and heard with the new level, paced as a dragged knob of
    /// its Sound is, and nothing in the project changes. Letting go is one step that can be undone,
    /// "Change Effect Level". A clip with its own level for the effect keeps that.
    func setTrackEffectLevel(_ effectID: UUID, of trackID: UUID, _ levelDb: Double, isFinal: Bool) {
        sound.turn("Change Effect Level", isFinal: isFinal) {
            $0.setTrackEffect(effectID, of: trackID, levelDb: levelDb)
        }
    }

    /// The button that removes an effect of a track was pressed: one step that can be undone, "Remove
    /// Track Effect". What the track's clips had changed of it goes with it. Nothing happens during a
    /// take.
    func removeTrackEffect(_ effectID: UUID, from trackID: UUID) {
        guard takeStatus.phase == nil else { return }
        var changed = store.project
        guard changed.removeTrackEffect(effectID, from: trackID) else { return }
        store.edit("Remove Track Effect") { $0 = changed }
        followClips(store.project)
    }
}

extension ClipEffectsModel {
    // MARK: The rows of the panel

    /// The clip whose effects on a stretch the rows under "Effects" list: the one selected clip. Only
    /// its rows can be clicked to mark a stretch. With several selected the panel lists the effects
    /// they share, which are all on the whole clip.
    private var listedClipID: UUID? {
        selection.clipIDs.count == 1 ? selection.clipIDs.first : nil
    }

    /// The row with this id among the rows of the selected clips that stand for an effect on the whole
    /// clip: an effect of their track, or an own one. With one clip selected these are all its
    /// whole-clip effects, and with several the ones they share. Nil for an effect on a stretch, which
    /// is one clip's own alone.
    ///
    /// It is asked anew for every press and every move of a level, because it is an answer about the
    /// project as it is.
    private func wholeClipRow(_ effectID: UUID) -> SharedEffect? {
        store.project.sharedEffects(of: selection.clipIDs).first { $0.id == effectID }
    }

    /// The level of an effect of the selected clips was moved. While it is dragged the clips are only
    /// made and heard with the new level, paced as a dragged knob of the track's Sound is, and nothing
    /// in the project changes. Letting go is one step that can be undone, "Change Effect Level".
    ///
    /// For a clip's own effect it is that effect's level. For an effect of the clips' track it is the
    /// clips' own level for it, which the track's other clips do not get. With several clips selected
    /// every one of them gets the level. An effect on the whole clip gets it on the takes that wait
    /// behind the clip too.
    func setEffectLevel(_ effectID: UUID, _ levelDb: Double, isFinal: Bool) {
        if let row = wholeClipRow(effectID) {
            sound.turn("Change Effect Level", isFinal: isFinal) { $0.setEffects(row, levelDb: levelDb) }
        } else if let clipID = listedClipID {
            sound.turn("Change Effect Level", isFinal: isFinal) { $0.setEffect(effectID, of: clipID, levelDb: levelDb) }
        }
    }

    /// The button that removes an effect of the selected clips was pressed: one step that can be
    /// undone, "Remove Effect". With several clips selected it is removed from all of them, and where
    /// it is an effect of a clip's track it is switched off for that clip ("Switch Effect Off" when no
    /// clip's own effect was among them). Nothing happens during a take.
    func removeEffect(_ effectID: UUID) {
        guard takeStatus.phase == nil else { return }
        var changed = store.project
        if let row = wholeClipRow(effectID) {
            guard changed.removeEffects(row) else { return }
            store.edit(row.members.contains { !$0.isOfTrack } ? "Remove Effect" : "Switch Effect Off") { $0 = changed }
        } else if let clipID = listedClipID {
            guard changed.removeEffect(effectID, from: clipID) else { return }
            store.edit("Remove Effect") { $0 = changed }
            // The stretch that was marked for it marks nothing any more.
            if lit?.clipID == clipID, lit?.effectID == effectID {
                unlight()
            }
        } else {
            return
        }
        followClips(store.project)
    }

    /// The button that switches an effect of their track off was pressed for the selected clips: they
    /// are heard without it, and the track's other clips as before. Pressed again, while it is off on
    /// every one of them, it is on again, with the level each clip had for it. One step that can be
    /// undone, "Switch Effect Off" or "Switch Effect On". Nothing happens during a take.
    func switchEffectOffOrOn(_ effectID: UUID) {
        guard takeStatus.phase == nil, let row = wholeClipRow(effectID) else { return }
        var changed = store.project
        guard changed.setEffects(row, isOff: !row.isOff) else { return }
        store.edit(row.isOff ? "Switch Effect On" : "Switch Effect Off") { $0 = changed }
        followClips(store.project)
    }

    /// The mark of an effect of their track that the selected clips changed for themselves was
    /// pressed: they follow the track with it again, on and at the track's level. One step that can be
    /// undone, "Follow Track Effect". Nothing happens during a take.
    func resetEffect(_ effectID: UUID) {
        guard takeStatus.phase == nil, let row = wholeClipRow(effectID) else { return }
        var changed = store.project
        guard changed.resetEffects(row) else { return }
        store.edit("Follow Track Effect") { $0 = changed }
        followClips(store.project)
    }

    /// The row of an effect of the selected clip was clicked: its stretch is marked in the timeline,
    /// the clip stays selected and the row is lit. A second click on the lit row takes the mark away
    /// again. An effect on the whole clip has no stretch to mark.
    func effectRowPressed(_ effectID: UUID) {
        let project = store.project
        guard takeStatus.phase == nil, let clipID = listedClipID, let clip = project.clip(clipID),
              let track = project.tracks.first(where: { track in track.clips.contains { $0.id == clipID } })
        else { return }
        let wasLit = isLit(effectID, of: clipID)
        if lit != nil {
            unlight()
        }
        guard !wasLit,
              let seconds = stretches(of: clip, in: project).first(where: { $0.id == effectID })?.seconds
        else { return }
        let stretch = MarkedStretch(trackID: track.id, range: seconds.lowerBound...seconds.upperBound)
        lit = (clipID, effectID, stretch)
        clipEditing.markStretch(stretch, ofSelectedClip: clipID)
    }

    /// Whether the row of this effect is lit: its stretch is the one that is marked, for its clip.
    private func isLit(_ effectID: UUID, of clipID: UUID) -> Bool {
        guard let lit, lit.clipID == clipID, lit.effectID == effectID else { return false }
        return selection.markedStretch == lit.stretch && selection.clipIDs == [clipID]
    }

    /// Takes away the stretch that a click on a row marked, when it is still the marked one.
    private func unlight() {
        let was = lit
        lit = nil
        if let was, selection.markedStretch == was.stretch {
            clipEditing.clearMarkedStretch()
        }
    }
}

extension ClipEffectsModel {
    // MARK: What the window shows

    /// Where the effects of a clip are drawn, with what that was worked out from.
    private struct Shown {
        var clip: Clip
        var tightenedIDs: [UUID?]
        var start: Double?
        var stretches: [EffectStretch]
    }

    /// Called by `showClips`, after the marked stretch is settled: gives every track in the rows its
    /// effects and every clip its own, for the rows under "Effects" in the panel on the right, the bands
    /// on the clip and the mark "FX" in its bar.
    ///
    /// A track's effects are shown in the panel only, so of the clips on a track with effects only the
    /// selected ones are given them (`ClipBox.effects`, the track's first and then the clip's own):
    /// the panel lists no other clip, and a clip that is not selected then stays as it was when its
    /// track's effect is turned. On a track without effects a clip is looked at as before there were
    /// any: a pass through a big project is made after every edit.
    ///
    /// - Returns: the effects the selected clips share, one row each, while several are selected
    ///   (`MainLayoutContent.selectedClipsEffects`). Empty with one clip or none.
    func showEffects(in rows: inout [TrackRow], of project: Project) -> [ClipEffectMark] {
        guard !FeatureSet.built.isDisjoint(with: [.doubles, .wordEffects]) else { return [] }
        let showsTrackEffects = FeatureSet.built.contains(.trackEffects)
        let selected = selection.clipIDs
        var kept: [UUID: Shown] = [:]
        for row in rows.indices {
            let track = showsTrackEffects || !rows[row].clips.isEmpty ? project.track(rows[row].id) : nil
            let ofTrack = showsTrackEffects ? track?.effects ?? [] : []
            let trackMarks = ofTrack.map { ClipEffectMark(id: $0.id, kind: $0.kind, levelDB: $0.levelDb) }
            if rows[row].effects != trackMarks {
                rows[row].effects = trackMarks
            }
            guard !rows[row].clips.isEmpty else { continue }
            // The clips that have rows to show: the ones with effects of their own, and on a track with
            // effects the selected ones.
            let listed = Dictionary(
                (track?.clips ?? [])
                    .filter { !$0.effects.isEmpty || (!ofTrack.isEmpty && selected.contains($0.id)) }
                    .map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for index in rows[row].clips.indices {
                var marks: [ClipEffectMark] = []
                if let clip = listed[rows[row].clips[index].id] {
                    if !ofTrack.isEmpty, selected.contains(clip.id) {
                        marks = ofTrack.map { Self.mark(ofTrackEffect: $0, on: clip) }
                    }
                    if !clip.effects.isEmpty {
                        let levels = Dictionary(clip.effects.map { ($0.id, $0.levelDb) }, uniquingKeysWith: { first, _ in first })
                        marks += stretches(of: clip, in: project, keeping: &kept).map { stretch in
                            var mark = ClipEffectMark(
                                id: stretch.id,
                                kind: stretch.kind,
                                range: stretch.seconds.map { $0.lowerBound...$0.upperBound },
                                levelDB: levels[stretch.id] ?? stretch.kind.startLevelDb
                            )
                            mark.isSelected = isLit(stretch.id, of: clip.id)
                            return mark
                        }
                    }
                }
                if rows[row].clips[index].effects != marks {
                    rows[row].clips[index].effects = marks
                }
            }
        }
        // The clips that are gone, or have no effect on a stretch any more, are forgotten.
        shown = kept
        guard showsTrackEffects, selected.count > 1 else { return [] }
        return sharedMarks(of: selected, in: project)
    }

    /// The row of an effect of its track in a clip's list: the level the clip is heard with, and what
    /// the clip changed of the effect for itself.
    private static func mark(ofTrackEffect effect: ClipEffect, on clip: Clip) -> ClipEffectMark {
        let change = clip.effectChanges.isEmpty ? nil : clip.change(ofTrackEffect: effect.id)
        var mark = ClipEffectMark(
            id: effect.id,
            kind: effect.kind,
            levelDB: effect.kind.isLayer ? change?.levelDb ?? effect.levelDb : effect.levelDb
        )
        mark.ofTrack = ClipEffectMark.OfTrack(
            isChanged: change != nil, isOff: change?.isOff ?? false, trackLevelDB: effect.levelDb
        )
        return mark
    }

    /// The rows of the effects several selected clips share (`Project.sharedEffects`). A row has the id
    /// of the effect it stands for on the first clip, which is how its level and its buttons name it
    /// (`wholeClipRow`).
    private func sharedMarks(of ids: Set<UUID>, in project: Project) -> [ClipEffectMark] {
        let shared = project.sharedEffects(of: ids)
        guard !shared.isEmpty else { return [] }
        // The track of each selected clip, to know the level a track gives its effect. Only tracks
        // with effects are gone through.
        var tracks: [UUID: Track] = [:]
        for track in project.tracks where !track.effects.isEmpty {
            for clip in track.clips where ids.contains(clip.id) {
                tracks[clip.id] = track
            }
        }
        return shared.map { row in
            var mark = ClipEffectMark(id: row.id, kind: row.kind, levelDB: row.levelDb)
            mark.isMixed = row.isMixed
            if row.isOfTrack {
                let levels = row.members.compactMap { member in
                    tracks[member.clipID]?.effects.first { $0.id == member.effectID }?.levelDb
                }
                mark.ofTrack = ClipEffectMark.OfTrack(
                    isChanged: row.isChanged,
                    isOff: row.isOff,
                    trackLevelDB: levels.isEmpty ? row.levelDb : levels.reduce(0, +) / Double(levels.count)
                )
            }
            return mark
        }
    }

    /// Where each effect of a clip is heard, in song seconds: none for an effect on the whole clip.
    private func stretches(of clip: Clip, in project: Project) -> [EffectStretch] {
        var kept = shown
        return stretches(of: clip, in: project, keeping: &kept)
    }

    /// The same, kept for the next time: a clip with an effect on a stretch has its answer put into
    /// `kept`, and is given the answer of last time when nothing it came from has changed.
    private func stretches(of clip: Clip, in project: Project, keeping kept: inout [UUID: Shown]) -> [EffectStretch] {
        // An effect on the whole clip has no place to work out.
        // The voices as they were last heard: where the clip's sound starts depends on which tightened sound may
        // be heard on its track, and that on the voice it was made from.
        let voices = correction.voice.heard
        guard clip.effects.contains(where: { $0.span != nil }) else { return project.effectStretches(of: clip, voices: voices) }
        let tightened = correction.heardTightened
        let track = project.tracks.first { $0.clips.contains { $0.id == clip.id } }
        let tightenedIDs = clip.segments.enumerated().map { index, segment in
            clip.hasTimingFix ? tightened.sound(for: segment, at: index, of: clip, on: track, voices: voices)?.id : nil
        }
        let start = project.start(of: clip)
        if let last = shown[clip.id], last.clip == clip, last.tightenedIDs == tightenedIDs, last.start == start {
            kept[clip.id] = last
            return last.stretches
        }
        var heardSample: ((UUID, Int) -> Int?)?
        if clip.hasTimingFix {
            heardSample = project.heardSample(of: clip, tightened: tightened, voices: voices) { [correction] segment, sample in
                correction.heardShift(ofSample: sample, inSegment: segment, of: clip, tightened: tightened, on: track, voices: voices)
            }
        }
        let stretches = project.effectStretches(of: clip, tightened: tightened, voices: voices, heardSample: heardSample)
        kept[clip.id] = Shown(clip: clip, tightenedIDs: tightenedIDs, start: start, stretches: stretches)
        return stretches
    }
}

extension ClipEffectsModel {
    // MARK: For an agent's run

    /// Does what every `-trackEffect`, then every `-clipTrackEffect`, then every `-double` and then every
    /// `-wordEffect` asks, each in the order they were given, and says on standard error how each went.
    /// The Sound part calls it once `-trackSound` and `-clipKnob` have acted
    /// (`SoundModel.soundLaunchTrack`). An agent that checks the app cannot drag over a word or open a
    /// menu, and cannot hear, so each goes through the function the menu or the panel calls.
    func addLaunchEffects() async {
        let options = LaunchOptions.current
        for kind in options.trackEffects {
            Agent.tell(await addTrackEffectForAgent(kind))
        }
        for asked in options.clipTrackEffects {
            Agent.tell(changeTrackEffectOfFirstClipForAgent(asked.kind, levelDb: asked.levelDb))
        }
        for asked in options.doubles + options.wordEffects {
            Agent.tell(await addEffectForAgent(asked.kind, onStretch: asked.stretch))
        }
    }

    /// Waits for the song's beats, for an effect that is placed by them: an echo, a stutter or a swell.
    /// Added sooner, the sound would be made without them, and an echo would have no repeats.
    ///
    /// - Returns: what the line of the effect says when they were not found in time, or nothing.
    private func beatsWaitNote(for kind: ClipEffect.Kind) async -> String {
        guard kind.followsBeats else { return "" }
        let deadline = ContinuousClock.now + .seconds(Self.beatsWaitSeconds)
        while store.project.grid?.beats.isEmpty != false, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return store.project.grid?.beats.isEmpty != false ? ", the song's beats were not found" : ""
    }

    /// Does what `-trackEffect` asks: selects the first track and gives it an effect through the function
    /// the panel's "+" and Track > Effects call, waits until the finished sounds of the track's clips are
    /// made, and gives the line that says how it went.
    private func addTrackEffectForAgent(_ kind: ClipEffect.Kind) async -> String {
        let refusal = "could not give the first track the effect \(kind.rawValue): "
        let waitNote = await beatsWaitNote(for: kind)
        guard loadedSounds.song != nil, takeStatus.phase == nil, let track = store.project.tracks.first else {
            return refusal + "the song is not ready"
        }
        let before = Set(track.effects.map(\.id))
        clipEditing.clearMarkedStretch()
        selection.clipIDs = []
        selection.trackID = track.id
        addTrackEffect(kind)
        guard let now = store.project.track(track.id), let effect = now.effects.first(where: { !before.contains($0.id) })
        else { return refusal + "nothing was added" }
        var line = "gave the track \"\(track.name)\" the effect \(kind.rawValue), "
            + (kind.isLayer ? String(format: "at %.1f dB, ", effect.levelDb) : "which has no level, ")
            + "the track has \(now.effects.count) \(now.effects.count == 1 ? "effect" : "effects"), "
        if let made = await sound.finishedSoundsForAgent(ofTrack: track.id) {
            line += "\(made.made) of \(made.clips) \(made.clips == 1 ? "clip has" : "clips have") a finished sound"
            if let first = made.first {
                line += ", the first clip's sound is \(first.drySamples) samples and its tail \(first.tailSamples) samples"
            }
        } else {
            line += "the finished sounds were not made"
        }
        return line + waitNote + ", undo step: \(store.undoTitle ?? "none")"
    }

    /// Does what `-clipTrackEffect` asks: selects the first clip of the first track and gives it its own
    /// level for the track's first effect of a kind, or switches that effect off for it, through the
    /// functions the row in the panel calls, and gives the line that says how it went.
    ///
    /// - Parameter levelDb: the clip's own level, or nil to switch the effect off for the clip.
    private func changeTrackEffectOfFirstClipForAgent(_ kind: ClipEffect.Kind, levelDb: Double?) -> String {
        let refusal = "could not change the track's effect \(kind.rawValue) for the first clip: "
        guard loadedSounds.song != nil, takeStatus.phase == nil, let track = store.project.tracks.first else {
            return refusal + "the song is not ready"
        }
        guard let clip = track.clips.first(where: \.isActiveTake) else { return refusal + "the first track has no clip" }
        guard let effect = track.effects.first(where: { $0.kind == kind }) else {
            return refusal + "the track \"\(track.name)\" has no such effect"
        }
        if levelDb != nil, !kind.isLayer {
            return refusal + "it has no level"
        }
        clipEditing.clearMarkedStretch()
        selection.clipIDs = [clip.id]
        selection.trackID = track.id
        if let levelDb {
            setEffectLevel(effect.id, levelDb, isFinal: true)
        } else if clip.change(ofTrackEffect: effect.id)?.isOff != true {
            switchEffectOffOrOn(effect.id)
        }
        let change = store.project.clip(clip.id)?.change(ofTrackEffect: effect.id)
        func level(_ value: Double) -> String { String(format: "%.1f dB", value) }
        var has = "the clip follows its track"
        if change?.isOff == true {
            has = "the clip has it switched off"
        } else if let own = change?.levelDb {
            has = "the clip has it at \(level(own))"
        }
        return "changed the track's effect \(kind.rawValue) for the first clip of the track \"\(track.name)\": \(has), "
            + (kind.isLayer ? "the track has it at \(level(effect.levelDb))" : "which has no level")
            + ", undo step: \(store.undoTitle ?? "none")"
    }

    /// How long `-wordEffect` waits for the song's beats before an effect that follows them is added
    /// without them, in seconds.
    private static let beatsWaitSeconds = 120.0

    /// How long `-double` and `-wordEffect` on a stretch wait for the clip's syllables before the
    /// stretch is caught without them, in seconds.
    private static let syllablesWaitSeconds = 60.0

    /// Whether the syllables of every recording of the first clip of the first track are found. True
    /// when there is no such clip, which the line of the effect then says.
    private var firstClipHasSyllables: Bool {
        guard let clip = store.project.tracks.first?.clips.first(where: \.isActiveTake) else { return true }
        return clip.segments.allSatisfy { correction.hasMarkers(ofRecording: $0.recordingID) }
    }

    /// Gives the first clip of the first track an effect, on the whole clip or on a stretch of the
    /// song, waits for the clip's finished sound and gives the line that says how it went.
    ///
    /// An echo, a stutter and a swell are placed by the song's beats, which are found in the
    /// background after the song is opened. So for those it first waits until the beats are there:
    /// added sooner, the clip's sound would be made without them, and an echo would have no repeats.
    ///
    /// The ends of a stretch catch on the clip's syllables, which are found in the background after
    /// the take is added. So an effect on a stretch also waits until they are there: added sooner,
    /// the stretch would catch on the clip's edges only, and the same arguments would give another
    /// stretch from one run to the next.
    private func addEffectForAgent(_ kind: ClipEffect.Kind, onStretch asked: Range<Double>?) async -> String {
        let noun = kind.isDouble ? "double" : "effect"
        let refusal = "could not give the first clip the \(noun) \(kind.rawValue): "
        var waitNote = await beatsWaitNote(for: kind)
        if asked != nil {
            let deadline = ContinuousClock.now + .seconds(Self.syllablesWaitSeconds)
            while !firstClipHasSyllables, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if !firstClipHasSyllables {
                waitNote += ", the clip's syllables were not found"
            }
        }
        guard loadedSounds.song != nil, takeStatus.phase == nil, let track = store.project.tracks.first else {
            return refusal + "the song is not ready"
        }
        guard let clip = track.clips.first(where: \.isActiveTake) else { return refusal + "the first track has no clip" }
        let before = Set(clip.effects.map(\.id))
        func seconds(_ value: Double) -> String { String(format: "%.3f", value) }
        var place = "the whole clip"
        if let asked {
            let stretch = MarkedStretch(trackID: track.id, range: asked.lowerBound...asked.upperBound)
            let spans = spans(of: stretch, in: store.project, only: clip.id)
            guard !spans.isEmpty else {
                return refusal + "the clip plays less than 20 ms of \(seconds(asked.lowerBound)) to \(seconds(asked.upperBound)) s"
            }
            add(kind, on: spans, ofTrack: track.id)
        } else {
            clipEditing.clearMarkedStretch()
            selection.clipIDs = [clip.id]
            selection.trackID = track.id
            addEffect(kind)
        }
        guard let now = store.project.clip(clip.id), let effect = now.effects.first(where: { !before.contains($0.id) })
        else { return refusal + "nothing was added" }
        let heard = stretches(of: now, in: store.project).first { $0.id == effect.id }?.seconds
        if let span = effect.span, let asked {
            place = "samples \(span.inSample) to \(span.outSample) of its recording"
            if let heard {
                place += ", heard from \(seconds(heard.lowerBound)) to \(seconds(heard.upperBound)) s of the song"
            }
            place += " (asked for \(seconds(asked.lowerBound)) to \(seconds(asked.upperBound)) s)"
        }
        var line = "gave the first clip of the track \"\(track.name)\" the \(noun) \(kind.rawValue) on \(place), "
            + (kind.isLayer ? String(format: "at %.1f dB, ", effect.levelDb) : "which has no level, ")
            + "the clip has \(now.effects.count) \(now.effects.count == 1 ? "effect" : "effects"), "
        if let made = await sound.finishedSoundForAgent(ofClip: clip.id) {
            line += "its finished sound is \(made.drySamples + made.tailSamples) samples "
                + "(\(made.drySamples) of the clip and a tail of \(made.tailSamples))"
        } else {
            line += "its finished sound was not made"
        }
        if kind == .echoQuarter || kind == .echoEighth {
            line += ", " + echoRepeatsForAgent(of: effect, ofClip: now, heardFrom: heard?.lowerBound)
        }
        return line + waitNote + ", undo step: \(store.undoTitle ?? "none")"
    }

    /// Where each repeat of an echo of a clip starts, in song seconds, for the line of `-wordEffect`.
    ///
    /// It is read from the recipe the clip's finished sound was made from: the effect's stretch and the
    /// beats, both as samples of the clip's dry sound, through the function the sound itself places its
    /// repeats with (`EchoRepeats`). A sample of the dry sound becomes a song second by where the
    /// stretch's first sample is heard, or by the clip's start for an echo on the whole clip.
    private func echoRepeatsForAgent(of effect: ClipEffect, ofClip clip: Clip, heardFrom start: Double?) -> String {
        guard let recipe = sound.finishedRecipeForAgent(ofClip: clip.id),
              let heard = recipe.effects.first(where: { $0.id == effect.id }),
              let origin = start ?? store.project.start(of: clip)
        else { return "its repeats are not known" }
        let first = heard.span?.lowerBound ?? 0
        let repeats = EchoRepeats.repeats(
            ofSoundAt: Double(first), note: effect.kind == .echoQuarter ? .quarter : .eighth,
            levelDb: ClipEffect.level(clamped: effect.levelDb), beats: recipe.beats
        )
        guard !repeats.isEmpty else { return "it has no repeats" }
        let listed = repeats.map { one in
            String(format: "%.3f s at %.0f dB", origin + (one.position.rounded() - Double(first)) / Lockstep.sampleRate, one.gainDb)
        }
        return "\(repeats.count) \(repeats.count == 1 ? "repeat" : "repeats") at " + listed.joined(separator: ", ")
    }
}

extension AppModel {
    /// Gives `clipEffects` its closures. `wire()` calls it once, when every part is made.
    func wireClipEffects() {
        clipEffects.followClips = { [weak self] project in self?.clips.followClips(of: project) }
    }
}

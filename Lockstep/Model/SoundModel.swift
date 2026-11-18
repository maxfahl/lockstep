import AppKit
import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

/// A track's Sound: a part of the app's model.
///
/// It holds choosing a track's Sound from the presets, turning its four knobs, a clip's own knobs,
/// Max's own presets (which keep a track's effects with its Sound), and the making and keeping of
/// finished sounds.
///
/// A clip on a track with a Sound is not played from its recording. Its finished sound is made
/// ahead, away from the main thread (`ClipDry.render`, then `FinishedSoundRenderer.render`), kept in
/// memory and never in the project, and the player lays it into its row in place of the clip.
/// `followClips` asks `finishedClips(of:tightened:)` what there is, every time it hands the clips
/// to the player, and that one function does all the keeping up:
///
/// - A clip whose kept sound was made from what the clip is now (its `ClipSoundRecipe`) is played
///   finished.
/// - A clip whose sound is missing or out of date has it made, the clips nearest after the playhead
///   first, a few at a time. Until it is there the clip is played with the sound it had, when it
///   still plays the same pieces (a knob, a volume or the Sound changed), and dry otherwise.
/// - Sounds that are done within the same 100 ms are handed to the player together, and take over
///   with a 10 ms crossfade.
/// - Only heard clips are made: not a take that waits, a muted clip or a clip on a muted track. A
///   sound is kept while its clip is not heard, as long as the clip plays the same pieces, and
///   forgotten when the clip is gone.
/// - A clip whose correction is still being made gets its finished sound when the tightened one is
///   there.
///
/// What the window calls: the Sound menu of a track (`soundMenu(_:on:)`), a track's knob
/// (`setTrackKnob`), a knob of the selected clips (`setSelectedClipsKnob`) and its mark
/// (`resetSelectedClipsKnob`). A dragged knob is not an edit: the clips are made for the value under
/// the pointer, and letting go is the one edit. What it shows it adds to the rows in `showSounds`.
@MainActor
final class SoundModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let store: ProjectStore
    private let settings: AppSettings
    private let playhead: PlayheadPosition

    // The parts it is handed, and calls directly.
    private let correction: CorrectionModel
    /// A track's Voice: the samples of the voices, which the safe limit asks about outside a pass.
    private let voice: VoiceModel

    /// What is kept for finished sounds: the ones that are made and the ones being made.
    private let soundWork = SoundWork()
    /// What is kept while a knob is dragged: the pacing a dragged volume slider has.
    private let knobWork = VolumeWork()

    // What it asks of code that holds it, or of the model's routing. `wireSound` sets them.
    /// Lets the player and the window follow the clips of a project (`followClips(of:)`, the clips'
    /// part).
    var followClips: (Project) -> Void = { _ in }
    /// Waits until `-bigProject` has built its project (clip editing, which is made after this part).
    /// Returns at once when it was not given. Only `-trackSound` and `-clipKnob` ask.
    var launchBigProject: () async -> Void = {}

    /// Does what `-double` and `-wordEffect` ask (`addLaunchEffects()`, the effects' part, which is made
    /// after this one). Only `soundLaunchTrack` calls it, as the last step of what an agent's run asked
    /// of a clip's sound, so whoever waits for `launchSounded()` has waited for the effects too.
    var addLaunchEffects: () async -> Void = {}

    /// Does what `-pasteSound` asks (`pasteLaunchSound()`, the part that copies a sound, which is made
    /// after this one). Only `soundLaunchTrack` calls it, after the effects, so the sound that is copied
    /// has them and whoever waits for `launchSounded()` has waited for the paste too.
    var pasteLaunchSound: () async -> Void = {}

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore,
        settings: AppSettings,
        playhead: PlayheadPosition,
        correction: CorrectionModel,
        voice: VoiceModel
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
        self.settings = settings
        self.playhead = playhead
        self.correction = correction
        self.voice = voice
        showOwnPresets()
    }
}

extension SoundModel {
    // MARK: The Sound menu of a track

    /// A line was chosen in the Sound menu of a track: None, a preset, "Save as Preset..." or one of
    /// Max's own under "Delete Preset". Nothing happens during a take.
    func soundMenu(_ command: SoundMenu.Command, on trackID: UUID) {
        guard takeStatus.phase == nil, let track = store.project.track(trackID) else { return }
        switch command {
        case .chosen(nil):
            chooseSound(nil, for: trackID)
        case .chosen(let name?):
            guard let preset = preset(named: name) else { return }
            choosePreset(preset, for: trackID)
        case .saveAsPreset:
            guard let sound = track.sound else { return }
            // A Sound from one of his own presets is most often saved over that preset again.
            let own = SoundPreset.builtIn(named: sound.name) == nil
            guard let name = Self.askPresetName(suggesting: own ? sound.name : "") else { return }
            savePreset(named: name, fromTrack: trackID)
        case .deletePreset(let name):
            if settings.removeOwnPreset(named: name) {
                showOwnPresets()
            }
        }
    }

    /// Gives a track a Sound, or none, as one step that can be undone. The preset is copied onto the
    /// track, so the project never depends on the preset still being there.
    private func chooseSound(_ sound: TrackSound?, for trackID: UUID) {
        var probe = store.project
        guard probe.setTrack(trackID, sound: sound) else { return }
        store.edit("Choose Sound") { $0.setTrack(trackID, sound: sound) }
        followClips(store.project)
    }

    /// Gives a track a preset, as one step that can be undone: its Sound, and for a preset that has
    /// effects, copies of them in place of the track's own. A preset without effects, which every
    /// built-in one is, leaves the track's effects as they are.
    private func choosePreset(_ preset: SoundPreset, for trackID: UUID) {
        var changed = store.project
        guard changed.setTrack(trackID, preset: preset) else { return }
        // The copies have new ids, so the project that was tried is the one that is kept.
        store.edit("Choose Sound") { $0 = changed }
        followClips(store.project)
    }

    /// The preset with this name: a built-in one, or one of Max's own.
    private func preset(named name: String) -> SoundPreset? {
        SoundPreset.builtIn(named: name) ?? settings[.ownPresets].presets.first {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    /// Keeps a track's Sound, its character and its four knobs, and the track's effects, as one of
    /// Max's own presets under this name. The track's Sound then has that name, so the menu ticks the
    /// preset that was just saved: one step that can be undone, which leaves the preset where it is.
    /// The track's effects stay the ones they are, so what its clips changed of them still holds.
    ///
    /// A name that is empty or a built-in preset's is refused, with a message that says why.
    func savePreset(named name: String, fromTrack trackID: UUID) {
        guard takeStatus.phase == nil, let track = store.project.track(trackID), var sound = track.sound
        else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.saveOwnPreset(named: name, from: sound, effects: track.effects) else {
            windowState.showAlert(MessageAlert(
                title: "The preset was not saved.",
                detail: name.isEmpty
                    ? "A preset needs a name."
                    : "\u{201C}\(name)\u{201D} is the name of a built-in preset. Choose another name."
            ))
            return
        }
        showOwnPresets()
        sound.name = name
        chooseSound(sound, for: trackID)
    }

    /// Asks for the name of a preset with the system's own prompt. Nil when Max cancelled.
    private static func askPresetName(suggesting name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Save as Preset"
        alert.informativeText = "The track's Sound is kept under this name, with its four knobs as they stand "
            + "and the track's effects, for every project."
        let field = NSTextField(string: name)
        field.placeholderString = "Name"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Hands the window the names of Max's own presets, for the Sound menu.
    private func showOwnPresets() {
        let names = settings[.ownPresets].presets.map(\.name)
        if windowState.content.ownSoundPresets != names {
            windowState.content.ownSoundPresets = names
        }
    }

    // MARK: The knobs

    /// A knob of a track's Sound was moved. While it is dragged the track's clips are only made and
    /// heard with the new value, and nothing in the project changes. Letting go is one step that can
    /// be undone, "Change Sound".
    ///
    /// - Parameter value: from 0 to 1. It is kept in whole percent, which is what the knob shows.
    func setTrackKnob(_ trackID: UUID, _ knob: SoundKnob, _ value: Double, isFinal: Bool) {
        guard var knobs = store.project.track(trackID)?.sound?.knobs else { return }
        knobs[knob] = value
        turn("Change Sound", isFinal: isFinal) { $0.setTrack(trackID, knobs: knobs) }
    }

    /// A knob of the selected clips was moved: every one of them gets the value as its own, whatever
    /// its track has, and so do the takes that wait behind them. Dragging and letting go as for a
    /// track's knob. The step is "Change Clip Sound".
    func setSelectedClipsKnob(_ knob: SoundKnob, _ value: Double, isFinal: Bool) {
        setKnob(knob, to: value, onClips: selection.clipIDs, isFinal: isFinal)
    }

    /// Turns one knob for these clips themselves. `-clipKnob` comes here too.
    private func setKnob(_ knob: SoundKnob, to value: Double, onClips ids: Set<UUID>, isFinal: Bool) {
        guard !ids.isEmpty else { return }
        turn("Change Clip Sound", isFinal: isFinal) { $0.setClips(ids, knob: knob, to: value) }
    }

    /// The mark of a knob the selected clips turned for themselves was pressed: they follow their
    /// track with that knob again, as one step that can be undone.
    func resetSelectedClipsKnob(_ knob: SoundKnob) {
        let ids = selection.clipIDs
        guard !ids.isEmpty else { return }
        turn("Reset Knob", isFinal: true) { $0.resetClips(ids, knob: knob) }
    }

    /// One move of a knob. While the knob is dragged the change is not made in the project: it is
    /// kept beside it (`SoundWork.dragged`) and applied to whatever the player is handed, so the
    /// finished sounds are made for the value under the pointer, the clips nearest the playhead
    /// first. The moves are paced as a dragged volume slider's are. Letting go makes the change in
    /// the project, as one step that can be undone, when it changes anything.
    ///
    /// The level of a clip's effect is turned with it too (`ClipEffectsModel.setEffectLevel`): it
    /// changes a clip's finished sound in the same way a knob does.
    ///
    /// - Parameter change: makes the change in the project it is handed and says whether anything
    ///   changed.
    func turn(_ name: String, isFinal: Bool, _ change: @escaping (inout Project) -> Bool) {
        knobWork.dropWaiting()
        // A turned knob is an edit, and nothing is edited while a take is going.
        guard takeStatus.phase == nil else {
            soundWork.dragged = nil
            return
        }
        guard !isFinal else {
            knobWork.lastHeardAt = nil
            soundWork.dragged = nil
            var probe = store.project
            if change(&probe) {
                store.edit(name) { _ = change(&$0) }
            }
            // Also when the knob was put back where it started and nothing was edited.
            followClips(store.project)
            return
        }
        soundWork.dragged = { _ = change(&$0) }
        knobWork.hear { [weak self] in
            guard let self else { return }
            self.followClips(self.store.project)
        }
    }
}

extension SoundModel {
    // MARK: What is heard

    /// What the player is handed besides the project and the tightened sounds: which finished sound
    /// is played in place of which clip, the samples of those sounds, and how long the clips that
    /// were heard fade into these.
    struct HeardFinished {
        var finished: FinishedSounds
        var samples: [UUID: StereoSound]
        var crossfadeMs: Double
    }

    /// The finished sounds of a project as they are heard from now on, and the work of keeping them
    /// up to date. `followClips` calls it right after `correction.tightenedClips(of:)`, with the
    /// project that is heard.
    ///
    /// The crossfade is asked for only when the finished sounds are not the ones that were heard
    /// before: a sound was made, a track got its Sound or lost it. A clip that was only moved keeps
    /// its sound, and the change is the clean cut it always was.
    ///
    /// - Parameter heard: what `correction.tightenedClips` answered for the same project. The dry
    ///   sound of a clip is made from the tightened sounds it names.
    func finishedClips(of project: Project, tightened heard: CorrectionModel.HeardClips) -> HeardFinished {
        let work = soundWork
        var project = project
        // A knob that is being dragged counts as turned, in whatever project comes by.
        work.dragged?(&project)
        let edgeFadeMs = settings[.edgeFadeMs]
        work.forgetRecipes(unlessFor: project, edgeFadeMs: edgeFadeMs)
        // The voices of this pass: a finished sound is made from the sound its clip is read from on its track,
        // and the safe limit asks about that sound.
        let voices = heard.voices
        let peaks = loadedSounds.clipPeaks(with: voice.current.samples)
        let context = SoundWork.Context(
            project: project, recordings: heard.recordings, tightened: heard.tightened, edgeFadeMs: edgeFadeMs,
            voices: voices
        )
        let now = playhead.seconds

        var finished = FinishedSounds()
        var samples: [UUID: StereoSound] = [:]
        var wanted: Set<UUID> = []
        var waiting: Set<UUID> = []
        var jobs: [SoundWork.Job] = []
        var existing: [UUID: (clip: Clip, track: Track)] = [:]
        for track in project.tracks {
            for clip in track.clips {
                existing[clip.id] = (clip, track)
                // Only what is heard, and only what has a sound to be made: a Sound on its track, an
                // effect on its track or one of its own. The check comes before the recipe, so a project
                // without a Sound costs nothing here. A clip that switched off every effect of a track
                // without a Sound has a recipe of nil and is played as recorded.
                guard !track.muted, !clip.muted, clip.isActiveTake,
                      track.sound != nil || !track.effects.isEmpty || !clip.effects.isEmpty,
                      let recipe = recipe(
                          of: clip, on: track, in: project, tightened: heard.tightened, edgeFadeMs: edgeFadeMs, peaks: peaks,
                          voices: voices
                      )
                else { continue }
                wanted.insert(clip.id)
                let kept = work.made[clip.id]
                if kept?.recipe != recipe {
                    waiting.insert(clip.id)
                    // The dry sound is made from the tightened one, so it waits for it.
                    if !(clip.hasTimingFix && correction.tightenedSoundIsAwaited(of: clip.id)),
                       work.making[clip.id] != recipe
                    {
                        jobs.append(SoundWork.Job(
                            clip: clip,
                            recipe: recipe,
                            context: context,
                            peaks: Self.peakTable(of: clip, on: track, peaks: peaks, voices: voices),
                            order: Self.order(of: clip, in: project, playhead: now)
                        ))
                    }
                }
                // Until the new sound is there, the one before it is heard on, when the clip still plays
                // the pieces it was made from: a knob, a volume or the Sound changed, and the clip did not. And
                // only while the voice it was made from may still be heard on the clip's track: after the Voice
                // is switched off, undone or the clip moved, the clip is heard dry until its sound is made again.
                if let kept, FinishedSounds([clip.id: kept.sound]).sound(for: clip, on: track, voices: voices) != nil {
                    finished.set(kept.sound, for: clip.id)
                    samples[kept.sound.id] = kept.samples
                }
            }
        }
        work.wanted = wanted
        work.waiting = waiting
        // A sound is kept while its clip is not heard, for as long as the clip plays the same pieces,
        // so a track that is unmuted, or given its Sound back, has its sounds at once.
        work.made = work.made.filter { id, made in
            existing[id].map { FinishedSounds([id: made.sound]).sound(for: $0.clip, on: $0.track, voices: voices) != nil } ?? false
        }
        work.memo = work.memo.filter { existing[$0.key] != nil }
        // What still waited from the last time is not wanted any more, or is among these again.
        work.pending = jobs.sorted { $0.order < $1.order }
        startMaking()

        let crossfadeMs = finished == work.heard ? 0 : LineRenderer.crossfadeMs
        work.heard = finished
        work.heardVoices = voices
        return HeardFinished(finished: finished, samples: samples, crossfadeMs: crossfadeMs)
    }

    /// The finished sound of one clip for an export, as the clip is heard: the lookup and the samples
    /// `ClipExporter.export` takes. Both are empty for a clip that has no sound to be made, which is
    /// then exported as before.
    ///
    /// A clip whose sound is not made yet, or is out of date, has it made here and now, so the export
    /// waits for it, as it waits for a tightened sound (`correction.tightenedExport`).
    ///
    /// - Parameter voiced: the sound the clip is read from, chosen once by the send
    ///   (`SendModel.clipExport`): the voices of the clip's track with their samples, or `.none` for Max's own
    ///   voice. The safe limit asks about the same sound. A sound made from another source than the
    ///   player's is not kept in its place.
    func finishedExport(
        of clipID: UUID, in project: Project, voiced: VoicedClips
    ) -> (finished: FinishedSounds, samples: [UUID: StereoSound]) {
        let work = soundWork
        let edgeFadeMs = settings[.edgeFadeMs]
        let dry = correction.tightenedExport(of: clipID, in: project, voiced: voiced)
        let voices = voiced.voices.having(dry.recordings)
        let peaks = loadedSounds.clipPeaks(with: voiced.samples)
        guard let chosen = ClipExporter.clipToExport(clipID, in: project),
              let track = project.tracks.first(where: { track in track.clips.contains { $0.id == chosen.clip.id } }),
              let recipe = recipe(
                  of: chosen.clip, on: track, in: project, tightened: dry.tightened, edgeFadeMs: edgeFadeMs, peaks: peaks,
                  voices: voices
              )
        else { return (.none, [:]) }
        let clip = chosen.clip
        let made: SoundWork.Made
        if let kept = work.made[clip.id], kept.recipe == recipe {
            made = kept
        } else {
            guard let sound = ClipDry.render(
                clip, in: project, recordings: dry.recordings, peaks: peaks, edgeFadeMs: edgeFadeMs, tightened: dry.tightened,
                voices: voices
            ) else { return (.none, [:]) }
            made = SoundWork.Made(
                recipe: recipe, clip: clip, drySamples: sound.samples.count,
                samples: FinishedSoundRenderer.render(recipe, dry: sound.samples)
            )
            // The player can use it too, and is handed it a moment later, when it was made from what the
            // player hears.
            if recipe.dry.madeFrom == VoiceSources(voice.heard.standIns(for: clip, on: track), onTrack: track.id) {
                work.made[clip.id] = made
                followSoundsSoon()
            }
        }
        return (FinishedSounds([clip.id: made.sound]), [made.sound.id: made.samples])
    }

    // MARK: Making the sound

    /// The recipe of a clip's finished sound, or nil for a clip that needs none. It is worked out
    /// once and kept for as long as nothing it is made from changes: the clip, its track's Sound and
    /// effects and the tightened sounds that stand in for its segments here, and the beats, the
    /// recordings and the fade length for all clips at once (`SoundWork.forgetRecipes`). The clips are handed to the
    /// player after every edit, and working out the recipes of a few hundred clips again each time
    /// would be felt.
    private func recipe(
        of clip: Clip,
        on track: Track,
        in project: Project,
        tightened: TightenedSounds,
        edgeFadeMs: Double,
        peaks: RecordingPeak,
        voices: TrackVoices
    ) -> ClipSoundRecipe? {
        let work = soundWork
        // The tightened sounds that may be heard for the clip on its track, as the plan asks for them.
        let tightenedIDs = clip.segments.enumerated().map { index, segment in
            clip.hasTimingFix ? tightened.sound(for: segment, at: index, of: clip, on: track, voices: voices)?.id : nil
        }
        // The voices that stand in for its recordings there are part of what the recipe is remembered by.
        let standIns = voices.standIns(for: clip, on: track)
        // Only a stutter reads the clip's sub-beats: one of the clip's own, or one its track gives it.
        let hasStutter = track.effects(heardOn: clip).contains { $0.kind == .stutter }
        let grid = hasStutter ? correction.grid(for: clip, in: project) : .sixteenths
        if let memo = work.memo[clip.id], memo.clip == clip, memo.sound == track.sound,
           memo.effects == track.effects, memo.tightenedIDs == tightenedIDs, memo.grid == grid,
           memo.standIns == standIns, memo.trackID == track.id
        {
            return memo.recipe
        }
        // An effect on a stretch of a clip whose timing is corrected is made where its syllables are
        // heard, not where they were recorded. How far the correction moved them belongs to the
        // tightened sounds, which the recipe is remembered by. A track's effect is never on a stretch,
        // so asking the clip's own is enough to know.
        var heardSample: ((UUID, Int) -> Int?)?
        if clip.hasTimingFix, clip.effects.contains(where: { $0.span != nil }) {
            heardSample = project.heardSample(of: clip, tightened: tightened, voices: voices) { [correction] segment, sample in
                correction.heardShift(ofSample: sample, inSegment: segment, of: clip, tightened: tightened, on: track, voices: voices)
            }
        }
        let recipe = ClipSoundRecipe(
            of: clip, in: project, tightened: tightened, edgeFadeMs: edgeFadeMs, peaks: peaks, grid: grid,
            heardSample: heardSample, voices: voices
        )
        work.memo[clip.id] = SoundWork.Memo(
            clip: clip, sound: track.sound, effects: track.effects, tightenedIDs: tightenedIDs, grid: grid,
            standIns: standIns, trackID: track.id, recipe: recipe
        )
        return recipe
    }

    /// The highest samples the safe limit asks about for this clip, measured here so that the making
    /// away from the main thread can answer the same question without the model. On a track whose Voice is
    /// heard the question is put about the voice that stands in, by its id, as the dry sound will ask it.
    private static func peakTable(
        of clip: Clip, on track: Track, peaks: RecordingPeak, voices: TrackVoices
    ) -> [SoundWork.Stretch: Float] {
        var table: [SoundWork.Stretch: Float] = [:]
        for segment in clip.segments where segment.outSample > segment.inSample {
            let id = voices.soundID(forRecording: segment.recordingID, on: track) ?? segment.recordingID
            let stretch = SoundWork.Stretch(recordingID: id, first: segment.inSample, end: segment.outSample)
            table[stretch] = peaks(id, segment.inSample..<segment.outSample)
        }
        return table
    }

    /// Where a clip stands in the line of sounds to be made: the clips that end after the playhead
    /// first, the nearest first, and then the ones before it, the nearest first.
    private static func order(of clip: Clip, in project: Project, playhead: Double) -> Double {
        let start = project.start(of: clip) ?? 0
        let end = project.end(of: clip) ?? start
        return end >= playhead ? max(start - playhead, 0) : 1_000_000 + playhead - end
    }

    /// Starts making the sounds that wait, a few at a time. One sound at a time is made for a clip: a
    /// newer recipe of a clip whose sound is being made waits until that one is done. So while a knob
    /// is dragged, the sound for the value a moment ago is finished and heard, and the value under the
    /// pointer comes after it.
    private func startMaking() {
        let work = soundWork
        while work.making.count < SoundWork.atATime,
              let index = work.pending.firstIndex(where: { work.making[$0.clip.id] == nil })
        {
            let job = work.pending.remove(at: index)
            work.making[job.clip.id] = job.recipe
            Task { [weak self] in
                let sound = await Self.finishedSound(for: job)
                self?.finishedSoundMade(sound, for: job)
            }
        }
    }

    /// The slow part: the dry sound of the clip, and its finished sound from that. Nil for a clip that
    /// plays nothing.
    @concurrent
    private nonisolated static func finishedSound(
        for job: SoundWork.Job
    ) async -> (drySamples: Int, samples: StereoSound)? {
        let table = job.peaks
        let dry = ClipDry.render(
            job.clip,
            in: job.context.project,
            recordings: job.context.recordings,
            peaks: { recordingID, samples in
                table[SoundWork.Stretch(recordingID: recordingID, first: samples.lowerBound, end: samples.upperBound)] ?? 0
            },
            edgeFadeMs: job.context.edgeFadeMs,
            tightened: job.context.tightened, voices: job.context.voices
        )
        guard let dry else { return nil }
        return (dry.samples.count, FinishedSoundRenderer.render(job.recipe, dry: dry.samples))
    }

    /// The finished sound of a clip is done. It is kept, also when the clip wants a newer one by now:
    /// it is nearer to that than the sound before it, and is heard until the newer one is made. The
    /// clips are handed to the player again a moment later, and the next sound that waits is started.
    private func finishedSoundMade(_ sound: (drySamples: Int, samples: StereoSound)?, for job: SoundWork.Job) {
        let work = soundWork
        work.making[job.clip.id] = nil
        if let sound {
            work.made[job.clip.id] = SoundWork.Made(
                recipe: job.recipe, clip: job.clip, drySamples: sound.drySamples, samples: sound.samples
            )
            followSoundsSoon()
        }
        startMaking()
    }

    /// Hands the clips to the player again 100 ms from now. The sounds of a track's clips are done one
    /// after the other, and they are then handed over together: the player lays out its row once for
    /// all that came in that time, not once for each.
    private func followSoundsSoon() {
        let work = soundWork
        guard !work.followIsWaiting else { return }
        work.followIsWaiting = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(SoundWork.handOverMs))
            guard let self else { return }
            self.soundWork.followIsWaiting = false
            guard self.loadedSounds.song != nil else { return }
            self.followClips(self.store.project)
        }
    }
}

extension SoundModel {
    // MARK: What the window shows

    /// Called by `showClips`: gives every track in the rows its Sound and every clip the knobs it
    /// turned for itself, for the section "Sound" of the panel on the right, and shows the small ring
    /// in that section's heading while finished sounds of what the panel shows are being made.
    func showSounds(in rows: inout [TrackRow], of project: Project) {
        for row in rows.indices {
            guard let track = project.track(rows[row].id) else { continue }
            let sound = track.sound.map { SoundValues(name: $0.name, knobs: $0.knobs) }
            if rows[row].sound != sound {
                rows[row].sound = sound
            }
            guard !rows[row].clips.isEmpty else { continue }
            let knobs = Dictionary(track.clips.map { ($0.id, $0.knobs) }, uniquingKeysWith: { first, _ in first })
            for index in rows[row].clips.indices {
                let own = knobs[rows[row].clips[index].id] ?? ClipKnobs()
                if rows[row].clips[index].ownKnobs != own {
                    rows[row].clips[index].ownKnobs = own
                }
            }
        }
        // The panel shows the selected clips, or the selected track when no clip is selected.
        var shown = selection.clipIDs
        if shown.isEmpty, let track = selection.trackID.flatMap({ project.track($0) }) {
            shown = Set(track.clips.map(\.id))
        }
        let progress = remakeProgress(ofClips: shown)
        if windowState.content.soundRemakeProgress != progress {
            windowState.content.soundRemakeProgress = progress
        }
    }

    /// How far the finished sounds of these clips have come in being made, from 0 to 1, for the small
    /// ring in the panel on the right. Nil when every one of them has its sound, or none has a sound
    /// to be made. It is as it was when the clips were last handed to the player.
    private func remakeProgress(ofClips ids: Set<UUID>) -> Double? {
        let wanted = ids.intersection(soundWork.wanted)
        let waiting = wanted.intersection(soundWork.waiting)
        guard !waiting.isEmpty else { return nil }
        return Double(wanted.count - waiting.count) / Double(wanted.count)
    }
}

extension SoundModel {
    // MARK: A project opens

    /// A song or a project is about to be shown in place of what was open, and the store has not
    /// opened it yet: the finished sounds, and a knob that was being dragged, belonged to the old one.
    /// What the window shows was just made anew, so it is handed the names of Max's presets again.
    func projectWillOpen() {
        showOwnPresets()
        knobWork.dropWaiting()
        knobWork.lastHeardAt = nil
        let work = soundWork
        work.dragged = nil
        work.made = [:]
        work.pending = []
        work.memo = [:]
        work.heard = .none
        work.heardVoices = .none
        work.wanted = []
        work.waiting = []
    }
}

extension SoundModel {
    // MARK: For an agent's run

    /// Does what `-trackSound`, `-clipKnob`, `-double` and `-wordEffect` ask, in that order, once the
    /// first project is open, the takes given with `-addTake` are in it, `-tighten`, `-strength` and
    /// `-stretch` have acted and `-bigProject` has built its project, and says on standard error how each
    /// went. An agent that checks the app cannot open the menu or drag a knob, and cannot hear, so all go
    /// through the functions the panel calls. The doubles and the effects on words are the effects'
    /// part's to add (`addLaunchEffects`); they are started from here so that they come after the Sound
    /// and the knob, and one wait covers all four.
    ///
    /// `-trackEffect` and `-clipTrackEffect` are the effects' part's too. It carries them out before the
    /// doubles, in that order, so the same wait covers them.
    func soundLaunchTrack() {
        let work = soundWork
        let options = LaunchOptions.current
        guard work.launch == nil,
              options.trackSound != nil || options.clipKnob != nil || !options.doubles.isEmpty
              || !options.wordEffects.isEmpty || options.pasteSound != nil
              || !options.trackEffects.isEmpty || !options.clipTrackEffects.isEmpty
        else { return }
        work.launch = Task { [weak self] in
            // Until the takes are added the track has no clip to make a sound for.
            await self?.takeStatus.ended()
            await self?.correction.launchTightened()
            // With `-bigProject` the Sound goes to the first track of the big project, clips and all.
            await self?.launchBigProject()
            if let name = options.trackSound, let line = await self?.soundFirstTrackForAgent(name) {
                Agent.tell(line)
            }
            if let knob = options.clipKnob, let line = self?.turnFirstClipKnobForAgent(knob.knob, to: knob.value) {
                Agent.tell(line)
            }
            await self?.addLaunchEffects()
            await self?.pasteLaunchSound()
        }
    }

    /// Waits until what `-trackSound`, `-clipKnob`, `-double` and `-wordEffect` asked for is done. Returns at once when
    /// none was given. `-sendClip` is to wait for it, so the clip it sends has its sound.
    func launchSounded() async {
        await soundWork.launch?.value
    }

    /// Does what `-trackSound` asks and gives the line that says how it went.
    private func soundFirstTrackForAgent(_ name: String) async -> String {
        let refusal = "could not give the first track the Sound \"\(name)\": "
        guard let preset = preset(named: name) else {
            return refusal + "there is no preset with that name ("
                + (SoundPreset.builtIn + settings[.ownPresets].presets).map(\.name).joined(separator: ", ") + ")"
        }
        guard loadedSounds.song != nil, takeStatus.phase == nil, let track = store.project.tracks.first else {
            return refusal + "the song is not ready"
        }
        let started = ContinuousClock.now
        soundMenu(.chosen(preset.name), on: track.id)
        let deadline = started + .seconds(120)
        while !soundsAreMade(ofTrack: track.id) {
            guard ContinuousClock.now < deadline else { return refusal + "the finished sounds were not made" }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let took = ContinuousClock.now - started
        let now = store.project.track(track.id)
        let clips = now?.clips.filter(\.isActiveTake) ?? []
        let made = clips.filter { heardSound(of: $0, on: now) != nil }
        let knobs = now?.sound?.knobs ?? preset.knobs
        func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }
        var line = "gave the track \"\(track.name)\" the Sound \"\(now?.sound?.name ?? preset.name)\": "
            + "squeeze \(percent(knobs.squeeze)) %, tone \(percent(knobs.tone)) %, "
            + "warmth \(percent(knobs.warmth)) %, space \(percent(knobs.space)) %, "
            + "\(made.count) of \(clips.count) \(clips.count == 1 ? "clip has" : "clips have") a finished sound, "
            + String(format: "made in %.0f ms", Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1_000)
        if let first = clips.first, let sound = heardSound(of: first, on: now) {
            line += ", the first clip's sound is \(sound.drySamples) samples and its tail \(sound.tailSamples) samples"
        }
        // Only a preset of the scratch folder's own can have effects: the line of a built-in one is as it was.
        if !preset.effects.isEmpty {
            let effects = (now?.effects ?? []).map { effect in
                effect.kind.isLayer ? String(format: "%@ at %.1f dB", effect.kind.menuName, effect.levelDb) : effect.kind.menuName
            }
            line += ", the track has the preset's \(effects.count == 1 ? "effect" : "effects") \(effects.joined(separator: ", "))"
        }
        return line + ", undo step: \(store.undoTitle ?? "none")"
    }

    /// Whether every heard clip of a track has the finished sound it wants, and the player was handed
    /// them.
    private func soundsAreMade(ofTrack trackID: UUID) -> Bool {
        let work = soundWork
        let ids = Set(store.project.track(trackID)?.clips.map(\.id) ?? [])
        return work.waiting.isDisjoint(with: ids) && !work.followIsWaiting
            && work.making.keys.allSatisfy { !ids.contains($0) }
    }

    /// Waits until a clip has the finished sound it wants and the player was handed it, and gives that
    /// sound: its lengths, as the player knows them. Nil for a clip that has no sound to be made, or
    /// whose sound was not made in two minutes. `-double` says the length in its line.
    func finishedSoundForAgent(ofClip clipID: UUID) async -> FinishedSounds.Sound? {
        let work = soundWork
        let deadline = ContinuousClock.now + .seconds(120)
        while work.waiting.contains(clipID) || work.followIsWaiting || work.making[clipID] != nil {
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let project = store.project
        let track = project.tracks.first { $0.clips.contains { $0.id == clipID } }
        return project.clip(clipID).flatMap { heardSound(of: $0, on: track) }
    }

    /// The finished sound the player was last handed for a clip, asked as the plan asks it: on its track, with
    /// the voices of that pass.
    private func heardSound(of clip: Clip, on track: Track?) -> FinishedSounds.Sound? {
        soundWork.heard.sound(for: clip, on: track, voices: soundWork.heardVoices)
    }

    /// Waits until every heard clip of a track has the finished sound it wants and the player was handed
    /// them, and says how many of the track's shown clips then have one, with the first clip's. Nil
    /// when they were not made in two minutes. `-trackEffect` says both in its line.
    func finishedSoundsForAgent(ofTrack trackID: UUID) async -> (made: Int, clips: Int, first: FinishedSounds.Sound?)? {
        let deadline = ContinuousClock.now + .seconds(120)
        while !soundsAreMade(ofTrack: trackID) {
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let track = store.project.track(trackID)
        let clips = track?.clips.filter(\.isActiveTake) ?? []
        let made = clips.filter { heardSound(of: $0, on: track) != nil }
        return (made.count, clips.count, clips.first.flatMap { heardSound(of: $0, on: track) })
    }

    /// The recipe the finished sound a clip has was made from, or nil for a clip without one. Ask after
    /// `finishedSoundForAgent(ofClip:)` has answered. `-wordEffect` reads where an echo's repeats are
    /// from it, so its line says what the sound holds.
    func finishedRecipeForAgent(ofClip clipID: UUID) -> ClipSoundRecipe? {
        soundWork.made[clipID]?.recipe
    }

    /// Does what `-clipKnob` asks and gives the line that says how it went.
    private func turnFirstClipKnobForAgent(_ knob: SoundKnob, to value: Double) -> String {
        let refusal = "could not turn the knob \(knob.rawValue) of the first clip: "
        guard loadedSounds.song != nil, takeStatus.phase == nil, let track = store.project.tracks.first else {
            return refusal + "the song is not ready"
        }
        guard let clip = track.clips.first(where: \.isActiveTake) else { return refusal + "the first track has no clip" }
        setKnob(knob, to: value, onClips: [clip.id], isFinal: true)
        func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded())) %" } ?? "not set" }
        let own = store.project.clip(clip.id)?.knobs[knob]
        let ofTrack = store.project.track(track.id)?.sound?.knobs[knob]
        return "turned the knob \(knob.rawValue) of the first clip of the track \"\(track.name)\": "
            + "the clip has \(percent(own)), "
            + (ofTrack == nil ? "the track has no Sound" : "the track has \(percent(ofTrack))")
            + ", undo step: \(store.undoTitle ?? "none")"
    }
}

/// What the model keeps for finished sounds: the ones that are made, the ones being made and the ones
/// that wait to be made. Nothing in the window watches it.
@MainActor
final class SoundWork {
    /// How many finished sounds are made at the same time, each on a background task of its own.
    static let atATime = 4
    /// How long the player waits for more finished sounds before it is handed the ones that are done,
    /// in milliseconds.
    static let handOverMs = 100

    /// The finished sound of one clip, and what it was made from.
    struct Made {
        var recipe: ClipSoundRecipe
        /// How the player and the export know it: its id, its lengths and the pieces it was made from.
        /// A sound that is made again gets a new id, which is how the player knows that it has changed.
        var sound: FinishedSounds.Sound
        var samples: StereoSound

        /// - Parameter clip: the clip as it was when the sound was made.
        init(recipe: ClipSoundRecipe, clip: Clip, drySamples: Int, samples: StereoSound) {
            self.recipe = recipe
            sound = FinishedSounds.Sound(
                id: UUID(),
                drySamples: drySamples,
                tailSamples: max(samples.left.count - drySamples, 0),
                pieces: clip.segments,
                madeFrom: recipe.dry.madeFrom
            )
            self.samples = samples
        }
    }

    /// What the making of a sound reads besides the clip and its recipe. It is the same for every
    /// sound that is asked for at one time.
    struct Context: Sendable {
        var project: Project
        /// The sound of the recordings, with the tightened sounds among them.
        var recordings: [UUID: [Float]]
        var tightened: TightenedSounds
        var edgeFadeMs: Double
        /// Which voice stands in for which recording on which track: the voices of the pass. Their samples are
        /// in `recordings`.
        var voices: TrackVoices
    }

    /// A stretch of a recording whose highest sample was measured.
    struct Stretch: Hashable, Sendable {
        var recordingID: UUID
        var first: Int
        var end: Int
    }

    /// One finished sound to be made.
    struct Job: Sendable {
        var clip: Clip
        var recipe: ClipSoundRecipe
        var context: Context
        var peaks: [Stretch: Float]
        /// Its place in the line: the lowest first.
        var order: Double
    }

    /// The recipe of a clip, with what it was worked out from.
    struct Memo {
        var clip: Clip
        var sound: TrackSound?
        /// The effects of the clip's track, which the clip is heard with unless it switched one off.
        var effects: [ClipEffect]
        var tightenedIDs: [UUID?]
        var grid: SubBeatGrid
        /// The voices that stood in for the clip's recordings on its track, and that track.
        var standIns: [UUID: UUID]
        var trackID: UUID
        var recipe: ClipSoundRecipe?
    }

    /// The finished sounds that are made, by clip id.
    var made: [UUID: Made] = [:]
    /// The recipes of the sounds that are being made, by clip id.
    var making: [UUID: ClipSoundRecipe] = [:]
    /// The sounds that wait to be made, the next one first.
    var pending: [Job] = []
    /// Which finished sounds are heard: what the player was last handed, or will be when the take ends.
    var heard = FinishedSounds.none
    /// The voices of the pass `heard` was worked out in, which every question about it is asked with.
    var heardVoices = TrackVoices.none
    /// The clips that should have a finished sound, and those of them that still wait for it, for the
    /// ring in the panel. `SoundModel.finishedClips` keeps both.
    var wanted: Set<UUID> = []
    var waiting: Set<UUID> = []
    /// True while a handing over of the clips is waiting to happen.
    var followIsWaiting = false
    /// The change a knob that is being dragged would make, or nil between drags.
    var dragged: ((inout Project) -> Void)?
    /// The recipes that are worked out, by clip id, and what all of them were worked out from.
    var memo: [UUID: Memo] = [:]
    private var memoGrid: Grid?
    private var memoRecordings: [Recording] = []
    private var memoEdgeFadeMs = 0.0
    /// The work `-trackSound` and `-clipKnob` asked for, while it is going on and after.
    var launch: Task<Void, Never>?

    /// Forgets every recipe when something all of them may be made from has changed: the song's
    /// beats, the recordings (where they lie, after a newly measured delay) or the fade length.
    func forgetRecipes(unlessFor project: Project, edgeFadeMs: Double) {
        guard memoGrid != project.grid || memoRecordings != project.recordings || memoEdgeFadeMs != edgeFadeMs
        else { return }
        memo = [:]
        memoGrid = project.grid
        memoRecordings = project.recordings
        memoEdgeFadeMs = edgeFadeMs
    }
}

extension AppModel {
    /// Gives `sound` its closures. `wire()` calls it once, when every part is made.
    func wireSound() {
        sound.followClips = { [weak self] project in self?.clips.followClips(of: project) }
        sound.addLaunchEffects = { [weak self] in await self?.clipEffects.addLaunchEffects() }
        sound.pasteLaunchSound = { [weak self] in await self?.soundCopy.pasteLaunchSound() }
        sound.launchBigProject = { [weak self] in await self?.clipEditing.bigProjectLaunch?.value }
    }
}

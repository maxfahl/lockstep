import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI
import Observation
import Synchronization

/// Correction: a part of the app's model.
///
/// It holds the correction of clips: Off, Lines and All with the strength and Stretch, the
/// tightened sound and its making, the syllable markers and their marks on the selected clip, and
/// sixteenths or triplets.
@MainActor
final class CorrectionModel {
    // The ground it is handed. Not private, because the part is in two files (`CorrectionModel+Aim.swift`).
    let selection: Selection
    let loadedSounds: LoadedSounds
    let takeStatus: TakeStatus
    let store: ProjectStore
    let settings: AppSettings

    // The parts it is handed, and calls directly.
    /// A track's Voice: which voice stands in for which recording on which track, and the voices' samples. A
    /// tightened sound is made from the sound its clip is read from on its track.
    let voice: VoiceModel

    /// The syllable markers of the open project's recordings. Not private, because the aim at another
    /// track is in a file of its own (`CorrectionModel+Aim.swift`) and reads them, like the next one.
    let syllableMarkers = SyllableMarkers()
    /// What is kept for Tighten lines: the tightened sounds, and Before or After.
    let tightenWork = TightenWork()

    /// Adds a sound file to a new track under the last one, as a take aimed at the very start of the
    /// song, and answers the track and the clip or why not (`addTakeOnNewTrack(fromFile:)`, the
    /// transport). `-lockedDouble` asks for it.
    var addTakeOnNewTrack: (URL) async -> (trackID: UUID, clipID: UUID, problem: String)? = { _ in nil }

    // What it asks of code that holds it, or of the model's routing. `wireCorrection` sets them.
    /// Lets the player and the window follow the clips of a project (`followClips(of:)`, the clips'
    /// part).
    var followClips: (Project) -> Void = { _ in }

    /// Shows the clips of a project in the window, without telling the player (`showClips(of:)`,
    /// the clips' part).
    var showClips: (Project) -> Void = { _ in }

    /// Runs a handing over of the clips that a remade sound asked for, so the line of the edit that
    /// caused it can note the pass (`timeLaterPass(_:)`, clip editing, which holds this part).
    var timeLaterPass: (() -> Void) -> Void = { $0() }

    init(
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore,
        settings: AppSettings,
        voice: VoiceModel
    ) {
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
        self.settings = settings
        self.voice = voice
    }
}

/// The correction of timing, which the panel on the right sets for the selected clips under "Correction".
///
/// A clip is Off, Lines or All (`Clip.tighten`). With Lines each whole line slides toward the sub-beat nearest
/// to its first syllable. With All the lines slide the same way and then single syllables move toward their
/// sub-beats. Strength (`Clip.strength`) is how much of either is applied, and Stretch (`Clip.stretch`) says
/// whether the voice may be stretched to move syllables that run together. It is one sound, made by the same
/// code, so everything below that says "tightened" is about all of it. A clip has a timing fix when it is not
/// Off (`Clip.hasTimingFix`). All of it is kept for each clip and saved with the project. The clip's
/// sub-beats are further down, under "The feel".
///
/// A line that lies close to an edge of its clip slides out of the clip when it has to, up to the clip next
/// to it on the track or the end of what is kept of the song. The clip in the project stays as it is. Its
/// tightened sound is then longer than the clip, and the clip is heard, shown and exported that much longer
/// (`heardSoundToDraw`, `heardReach(of:)`, `heardTightened`).
///
/// The tightened sound of a clip is made away from the main thread (`ClipTightening` of `LockstepCore`) and
/// kept in memory, never in the project. `followClips` asks `tightenedClips(of:)` what there is, every time it
/// hands the clips to the player, and that one function does all the keeping up:
///
/// - A clip whose sound was made from what the clip is now (`ClipTightening.Inputs`) is played tightened.
/// - A clip whose sound is missing or out of date has its sound made. When it is done, the clips are handed
///   over again and the new sound takes over, with a 10 ms crossfade. Until then the clip is played as
///   recorded, or, when only something else than the clip itself changed (the strength, an excluded syllable,
///   a setting, the beats), with the sound it had.
/// - A clip that is switched to Off is played as recorded and keeps the sound that was made for it. Chosen
///   Lines or All again, it has that sound back at once, when nothing the sound depends on has changed. That
///   is what makes Clip > Correction On or Off (T) a quick way to compare.
/// - Sounds of clips that are gone, or that were moved or cut while they were Off, are forgotten.
///
/// So the sound is made again whenever something it depends on changes: the clip is moved or cut, the
/// recordings are moved by a new measured delay, a syllable is excluded, the choice, Strength or Stretch is
/// changed, a setting changes (`tightenSettings`), the sub-beats of the clip are changed. All
/// of those come through `followClips`. Two things do not, and they are watched for here
/// (`watchTighteningInputs`): syllable markers that have just been found, and a change of the beats.
///
/// What the window calls:
/// - the buttons Off, Lines and All and Clip > Correction: `setSelectedClipsCorrection(_:)`,
/// - Clip > Correction On or Off: `toggleCorrection()`,
/// - the slider Strength: `setSelectedClipsStrength(_:)`, and `remakeProgress(ofClips:)` for the ring,
/// - the switch Stretch: `setSelectedClipsStretch(_:)`,
/// - drawing: `ShownClips` gives every clip in the window its own values, and
///   `heardLines(ofSegment:of:)`, `heardShift(ofMarkerAt:inSegment:of:)`, `heardSoundToDraw(ofSegment:of:)`
///   and `heardReach(of:)` say how a clip is heard right now, so it can be drawn the same way.
extension CorrectionModel {
    // MARK: The settings

    /// The numbers the timing fixes work with: how long a pause separates two lines, the furthest a line may
    /// slide, how far off counts as meant, the furthest a single syllable may move and the most its sound may
    /// be stretched or squeezed, as Settings > Timing has them. The furthest slide is the one in force: never
    /// more than the pause leaves room for. This is the one place that reads them, and
    /// `BeatsModel.followSettings` reads it to hear of a change, after which the tightened sounds are made again.
    var tightenSettings: TightenSettings {
        TightenSettings(
            linePauseMs: settings[.linePauseMs],
            maxLineShiftMs: settings.maxLineShiftInForceMs,
            deliberatePercent: settings[.deliberatePercent],
            maxSyllableMoveMs: settings[.maxSyllableMoveMs],
            maxStretchPercent: settings[.maxStretchPercent]
        )
    }

    // MARK: The controls

    /// Makes one change to the correction of clips, as one step that can be undone, and hands the clips to
    /// the player again. Nothing happens during a take, or when the change changes nothing.
    ///
    /// The sound of the clips is then made again, away from the main thread. Until it is there the clips are
    /// heard as they were before the change, and the song plays on.
    ///
    /// - Parameter change: makes the change in the project it is handed and says whether anything changed.
    func changeCorrection(_ name: String, _ change: (inout Project) -> Bool) {
        var probe = store.project
        guard takeStatus.phase == nil, change(&probe) else { return }
        store.edit(name) { _ = change(&$0) }
        followClips(store.project)
    }

    /// Chooses Off, Lines or All for clips, and for the takes that wait behind them.
    func setCorrection(_ choice: ClipTighten, onClips ids: Set<UUID>) {
        changeCorrection("Change Correction") { $0.setClips(ids, tighten: choice) }
    }

    /// One of Off, Lines and All was pressed in the panel on the right, or chosen under Clip > Correction:
    /// the selected clips get that choice.
    func setSelectedClipsCorrection(_ choice: ClipTighten) {
        setCorrection(choice, onClips: selection.clipIDs)
    }

    /// Whether a command of Clip > Correction is the choice every selected clip has, which ticks its item.
    func correctionIsChosen(_ command: AppCommand) -> Bool {
        guard let choice = command.correction else { return false }
        let clips = store.project.clips(selection.clipIDs)
        return !clips.isEmpty && clips.allSatisfy { $0.tighten == choice }
    }

    /// Whether every selected clip is corrected, with Lines or All. The Clip menu ticks Correction On or Off
    /// while it is.
    var selectedClipsAreCorrected: Bool {
        let clips = store.project.clips(selection.clipIDs)
        return !clips.isEmpty && clips.allSatisfy(\.hasTimingFix)
    }

    /// Clip > Correction On or Off: Off when every selected clip is corrected, and otherwise each of them
    /// gets the choice it had last, which is All for a clip that never had one. A clip that goes back on has
    /// its sound at once, because the sound is kept while the clip is Off.
    func toggleCorrection() {
        let ids = selection.clipIDs
        let on = !selectedClipsAreCorrected
        changeCorrection(on ? "Turn Correction On" : "Turn Correction Off") { $0.setClips(ids, corrected: on) }
    }

    /// Sets how much of the correction is applied to clips, from 0 to 1, for the clips and for the takes that
    /// wait behind them. It is kept in whole percent, which is what the slider shows.
    func setStrength(_ strength: Double, onClips ids: Set<UUID>) {
        changeCorrection("Change Strength") { $0.setClips(ids, strength: strength) }
    }

    /// The slider Strength in the panel on the right was let go: the selected clips get that strength.
    func setSelectedClipsStrength(_ strength: Double) {
        setStrength(strength, onClips: selection.clipIDs)
    }

    /// The switch Stretch in the panel on the right was switched: the voice of the selected clips may be
    /// stretched and squeezed, or may not.
    func setSelectedClipsStretch(_ on: Bool) {
        let ids = selection.clipIDs
        changeCorrection(on ? "Turn Stretch On" : "Turn Stretch Off") { $0.setClips(ids, stretch: on) }
    }

    /// How far the sound of these clips has come in being made again, from 0 to 1, for the small ring in the
    /// panel on the right. Nil when every one of them has its sound, or none has a timing fix. It is as it
    /// was when the clips were last handed to the player, which is also when the window is drawn again.
    func remakeProgress(ofClips ids: Set<UUID>) -> Double? {
        let wanted = ids.intersection(tightenWork.wanted)
        let waiting = wanted.intersection(tightenWork.waiting)
        guard !waiting.isEmpty else { return nil }
        return Double(wanted.count - waiting.count) / Double(wanted.count)
    }

    // MARK: What is heard

    /// What the player is handed besides the project: the sound of the recordings together with the
    /// tightened sounds, which tightened sound stands in for which segment, and how long the clips that were
    /// heard fade into these.
    struct HeardClips {
        var recordings: [UUID: [Float]]
        var tightened: TightenedSounds
        var crossfadeMs: Double
        /// Which voice stands in for which recording on which track in this pass, the one value every rule of
        /// the pass is handed. Their samples are in `recordings`.
        var voices: TrackVoices
    }

    /// The tightened clips of a project as they are heard from now on, and the work of keeping them up to
    /// date. `followClips` calls it before it shows the clips and hands them to the player.
    ///
    /// The crossfade is asked for only when the tightened sounds are not the ones that were heard before:
    /// a sound was made or went out of date, a clip was switched to Off or back.
    /// Every other change to the clips is the clean cut it always was.
    ///
    /// An older sound is heard on only while `TrackVoices.mayBeHeardOn` allows it: one made from a voice that
    /// no longer stands in on the clip's track (the Voice was switched off, undone or taken away, or the clip
    /// was moved) is dropped at once, and the clip is heard from what stands in now until its sound is made
    /// again.
    ///
    /// - Parameters:
    ///   - lookup: the project, as the lookup table of this pass.
    ///   - voiced: what `voice.voicedClips(of:)` answered for the same pass. The voices' samples are handed on
    ///     among the recordings', as the tightened sounds' are.
    func tightenedClips(of lookup: ProjectLookup, voiced: VoicedClips) -> HeardClips {
        let work = tightenWork
        let project = lookup.project
        let voices = voiced.voices
        var recordings = loadedSounds.sounds
        if !voiced.samples.isEmpty {
            recordings.merge(voiced.samples) { recording, _ in recording }
        }
        var tightened = TightenedSounds()
        var wanted: Set<UUID> = []
        // The clips that should have a sound and do not have it yet, for the ring in the panel.
        var waiting: Set<UUID> = []
        for entry in clipsToTighten(in: lookup, voices: voices) {
            let clip = entry.clip
            let inputs = entry.inputs
            wanted.insert(clip.id)
            var kept = work.made[clip.id]
            // A sound made from a voice that may no longer be heard on the clip's track is never heard again.
            if let sound = kept, !sound.inputs.sources.voices.isEmpty {
                let track = lookup.trackID(ofClip: clip.id).flatMap(lookup.track)
                if track.map({ !voices.mayBeHeardOn(madeFrom: sound.inputs.sources, for: clip, on: $0) }) ?? true {
                    kept = nil
                }
            }
            if let sound = kept, sound.isMade(from: entry) {
                // The inputs were not worked out again since the sound was last seen to be good, or they
                // came out the same. The next time the number alone says so.
                if sound.stamp != entry.stamp {
                    work.made[clip.id]?.stamp = entry.stamp
                }
                // What the clip depends on went back to what its sound was made from. A newer one is not needed.
                if !work.making.isEmpty {
                    work.making.removeValue(forKey: clip.id)?.task.cancel()
                }
            } else {
                waiting.insert(clip.id)
                // Out of date, or not made yet: the sound is made.
                if work.making[clip.id]?.isMaking(from: entry) != true {
                    makeTightenedSound(for: inputs, stamp: entry.stamp, voices: voiced.samples)
                }
                // Until it is there, the sound before it is heard on when it is of the same pieces at the same
                // place: the strength, an excluded syllable, a setting or the beats changed, and the clip did
                // not. So a move of the slider is one change in the ear, from the old sound to the new. A clip
                // that was moved or cut is heard as recorded until its sound is there.
                if let sound = kept, sound.inputs.segments != inputs.segments {
                    work.made[clip.id] = nil
                    kept = nil
                }
            }
            guard let made = kept else { continue }
            for (index, segment) in clip.segments.enumerated() where made.segments.indices.contains(index) {
                guard let id = made.ids[index], let samples = made.segments[index].samples else { continue }
                recordings[id] = samples
                tightened.set(
                    id, for: segment, at: index, of: clip.id,
                    lead: made.segments[index].leadSamples, tail: made.segments[index].tailSamples,
                    madeFrom: made.inputs.sources
                )
            }
        }
        work.wanted = wanted
        work.waiting = waiting
        // A clip that is Off keeps the sound that was made for it, for as long as it plays the same pieces at
        // the same place, so it has the sound back at once when Lines or All is chosen again. The sounds of
        // clips that are gone, or that were moved or cut while they were Off, are forgotten.
        // Only a sound that no clip asks for is looked at, and in most passes there is none.
        for (id, sound) in work.made where !wanted.contains(id) {
            if lookup.clip(id)?.segments.map(Self.withoutVolume) != sound.inputs.segments {
                work.made[id] = nil
            }
        }
        for id in work.making.keys where !wanted.contains(id) {
            work.making.removeValue(forKey: id)?.task.cancel()
        }
        // The loudness of a recording is forgotten with the recording, so only when the recordings changed.
        if work.levelsKeptFor != project.recordings {
            work.levelsKeptFor = project.recordings
            work.levels.forget(allBut: Set(project.recordings.map(\.id)))
        }
        // Also while no clip can be tightened yet: the beats or the syllables that are missing are what is
        // listened for.
        if project.hasClipWithTimingFix {
            watchTighteningInputs()
        }
        let crossfadeMs = tightened == work.heard ? 0 : LineRenderer.crossfadeMs
        work.heard = tightened
        return HeardClips(recordings: recordings, tightened: tightened, crossfadeMs: crossfadeMs, voices: voices)
    }

    /// `tightenedClips(of:voiced:)` with the voices as they were last heard, for whoever needs the clips as they
    /// are heard outside a pass: the row of voices a take recorded slower is handed.
    func tightenedClips(of lookup: ProjectLookup) -> HeardClips {
        tightenedClips(of: lookup, voiced: voice.current)
    }

    /// A segment as a tightened sound remembers it: without the volume of its own, which changes nothing
    /// about where its lines and syllables go (`ClipTightening.Inputs.segments`).
    private static func withoutVolume(_ segment: Segment) -> Segment {
        var plain = segment
        plain.gainDb = 0
        return plain
    }

    /// The tightened sound of one clip for an export, with the recordings' sound, as the clip is heard. A
    /// clip that is Off is exported as recorded.
    ///
    /// A clip whose sound is not made yet, or is out of date, has it made here and now, so the export waits
    /// for it. That takes a moment for one clip. The one thing that cannot be waited for is the search for a
    /// new recording's syllables: until they are found the clip has no lines to slide and is exported as recorded.
    ///
    /// - Parameter voiced: the sound the clip is read from, chosen once by the send (`SendModel.clipExport`):
    ///   the voices of the clip's track with their samples, or `.none` for a dry send in Max's own voice.
    ///   With `.none` the inputs are those of the recordings, so the sound made here is another one than the
    ///   player's. It is kept apart (`TightenWork.madeDry`) and never handed to the player. The recordings
    ///   handed back hold the voices' samples.
    func tightenedExport(
        of clipID: UUID, in project: Project, voiced: VoicedClips
    ) -> (recordings: [UUID: [Float]], tightened: TightenedSounds) {
        let work = tightenWork
        var sounds = loadedSounds.sounds
        sounds.merge(voiced.samples) { recording, _ in recording }
        let voices = voiced.voices.having(sounds)
        guard let chosen = ClipExporter.clipToExport(clipID, in: project), chosen.clip.hasTimingFix,
              let inputs = tighteningInputs(of: chosen.clip, in: project, pass: TighteningPass(voices: voices))
        else { return (sounds, .none) }
        let clip = chosen.clip
        // Made from what the player hears, the sound is the player's own and is kept in its place. Made from
        // another source (Max's own voice under a Voice, or a voice the player is not handed yet) it is kept
        // beside it, so the heard one is not made again at the next pass and the panel does not make this one
        // again after every change.
        let isHeard = inputs.voices == voice.heard.standIns(for: clip, on: chosen.track)
        let made: TightenWork.MadeClip
        if let kept = work.made[clip.id], kept.inputs == inputs {
            made = kept
        } else if !isHeard, let kept = work.madeDry[clip.id], kept.inputs == inputs {
            made = kept
        } else {
            var levels: [UUID: VoiceLevels] = [:]
            for id in inputs.recordings.keys {
                guard let sound = loadedSounds.sounds[id] else { continue }
                levels[id] = work.levels.levels(ofRecording: id, sound: sound, in: store.package)
            }
            let stretcher = CountingStretcher()
            made = TightenWork.MadeClip(
                inputs,
                ClipTightening.render(inputs, levels: levels, recordings: sounds, stretcher: stretcher),
                stamp: nil,
                stretchedRuns: stretcher.count
            )
            // The player can use it too, and is handed it a moment later, when it was made from what the player
            // hears.
            if isHeard {
                work.making.removeValue(forKey: clip.id)?.task.cancel()
                work.made[clip.id] = made
                followTighteningSoon()
            } else {
                work.madeDry[clip.id] = made
            }
        }
        var recordings = sounds
        var tightened = TightenedSounds()
        for (index, segment) in clip.segments.enumerated() where made.segments.indices.contains(index) {
            guard let id = made.ids[index], let samples = made.segments[index].samples else { continue }
            recordings[id] = samples
            tightened.set(
                id, for: segment, at: index, of: clip.id,
                lead: made.segments[index].leadSamples, tail: made.segments[index].tailSamples,
                madeFrom: made.inputs.sources
            )
        }
        return (recordings, tightened)
    }

    /// The made tightened sound of a clip whose segment's sound has this id: the one the player has, or the
    /// one made for a send apart from it (`TightenWork.madeDry`). Nil when neither is that sound.
    private func madeSound(named id: UUID, ofSegment index: Int, of clipID: UUID) -> TightenWork.MadeClip? {
        [tightenWork.made[clipID], tightenWork.madeDry[clipID]].lazy.compactMap { $0 }.first { made in
            made.segments.indices.contains(index) && made.ids[index] == id
        }
    }

    /// The Send to DaVinci panel closed: the tightened sounds made for it apart from the player's are not
    /// wanted any more.
    func forgetSendSounds() {
        tightenWork.madeDry = [:]
    }

    // MARK: How a clip is heard, for whoever draws it

    /// The lines of one segment of a clip as they are heard right now, each with how far it has slid and,
    /// in its map, where its syllables went. Nil when the segment is heard as recorded: its clip has no
    /// timing fix, nothing in it moves, or its tightened sound is not made yet.
    func heardLines(ofSegment index: Int, of clipID: UUID) -> [ClipTightening.Line]? {
        guard tightenWork.heard.sounds[TightenedSounds.Key(clipID: clipID, segment: index)] != nil,
              let made = tightenWork.made[clipID], made.segments.indices.contains(index)
        else { return nil }
        return made.segments[index].lines
    }

    /// How far a syllable is moved in what is heard right now, in seconds. Negative is earlier. 0 when its
    /// segment is heard as recorded. Add it to the marker's song time to draw the marker where it sounds.
    ///
    /// - Parameter sample: the marker's place in its recording, in samples.
    func heardShift(ofMarkerAt sample: Int, inSegment index: Int, of clipID: UUID) -> Double {
        guard let lines = heardLines(ofSegment: index, of: clipID),
              let line = lines.first(where: { sample >= $0.line.startSample && sample < $0.line.endSample })
        else { return 0 }
        return Double(line.map.result(ofSource: sample) - sample) / Lockstep.sampleRate
    }

    /// How many samples later than recorded a sample of one segment of a clip is heard, when these tightened
    /// sounds stand in for the clip's segments. Negative is earlier. 0 when the segment is played as recorded
    /// there: the clip has no timing fix, nothing in it moves, or the tightened sound it names is not the one
    /// that is kept.
    ///
    /// An effect on a stretch of a clip is caught, made and drawn with it (`ClipSpan.catching`,
    /// `Project.heardSample(of:tightened:shift:)`), so the effect stays on its syllables when the correction
    /// moves them. It asks about the tightened sounds it is handed and not about what is heard right now,
    /// because a clip's finished sound is also made for an export, from a tightened sound the player was
    /// not handed yet.
    ///
    /// The sound is asked for on the clip's track with the voices of the same pass (`track`, `voices`), so a
    /// sound made from a voice that may no longer be heard there moves nothing, as the plan does not play it.
    func heardShift(
        ofSample sample: Int, inSegment index: Int, of clip: Clip, tightened: TightenedSounds,
        on track: Track?, voices: TrackVoices
    ) -> Int {
        guard clip.hasTimingFix, clip.segments.indices.contains(index),
              let sound = tightened.sound(for: clip.segments[index], at: index, of: clip, on: track, voices: voices),
              let made = madeSound(named: sound.id, ofSegment: index, of: clip.id),
              let line = made.segments[index].lines.first(where: {
                  sample >= $0.line.startSample && sample < $0.line.endSample
              })
        else { return 0 }
        return line.map.result(ofSource: sample) - sample
    }

    /// What an end of a marked stretch catches on in a clip: the syllables of the clip's recordings, and the
    /// pauses between them, both by recording id (`ClipSpan.catching`, `ClipSpan.pauses`). A recording whose
    /// syllables are not found yet, or whose sound is not loaded, gives none, and a stretch on it stays where
    /// it was dragged.
    func catchPoints(in clip: Clip) -> (markers: [UUID: [LockstepCore.SyllableMarker]], pauses: [UUID: [Range<Int>]]) {
        var markers: [UUID: [LockstepCore.SyllableMarker]] = [:]
        var levels: [UUID: VoiceLevels] = [:]
        for id in Set(clip.segments.map(\.recordingID)) {
            markers[id] = syllableMarkers.byRecording[id]
            if let sound = loadedSounds.sounds[id] {
                levels[id] = tightenWork.levels.levels(ofRecording: id, sound: sound, in: store.package)
            }
        }
        return (markers, ClipSpan.pauses(in: clip, markers: markers, levels: levels))
    }

    /// The tightened sound of one segment of a clip as it is heard right now, for whoever draws its waveform,
    /// with the id it has in the player. A sound that is made again gets a new id, so a waveform drawn from
    /// it can be kept for as long as the id stays. Nil when the segment is heard as recorded.
    ///
    /// The sound is as many samples as the segment plays, with `lead` samples before them and `tail` after
    /// them where a line slid out of the segment. The segment is drawn that much longer.
    func heardSoundToDraw(ofSegment index: Int, of clipID: UUID) -> (id: UUID, samples: [Float], lead: Int, tail: Int)? {
        guard let heard = tightenWork.heard.sounds[TightenedSounds.Key(clipID: clipID, segment: index)],
              let made = tightenWork.made[clipID], made.segments.indices.contains(index),
              let samples = made.segments[index].samples
        else { return nil }
        return (heard.id, samples, made.segments[index].leadSamples, made.segments[index].tailSamples)
    }

    /// The id `heardSoundToDraw(ofSegment:of:)` gives for a segment, or nil when it gives nothing, without
    /// the sound itself. Whoever keeps what it drew asks this to see whether the sound is still the one it
    /// drew from.
    func heardSoundID(ofSegment index: Int, of clipID: UUID) -> UUID? {
        guard let heard = tightenWork.heard.sounds[TightenedSounds.Key(clipID: clipID, segment: index)],
              let segments = tightenWork.made[clipID]?.segments, segments.indices.contains(index),
              segments[index].samples != nil
        else { return nil }
        return heard.id
    }

    /// How far a clip is heard past its own start and end right now, in seconds: where its first line slid
    /// out of it at the start, or its last at the end. Both 0 for a clip that is heard inside its own edges.
    func heardReach(of clip: Clip) -> (before: Double, after: Double) {
        let first = heardSoundToDraw(ofSegment: 0, of: clip.id)
        let last = heardSoundToDraw(ofSegment: clip.segments.count - 1, of: clip.id)
        return (
            Double(first?.lead ?? 0) / Lockstep.sampleRate,
            Double(last?.tail ?? 0) / Lockstep.sampleRate
        )
    }

    /// Which tightened sound is heard in place of which piece of which clip right now, as the player was last
    /// handed it. Whoever asks where a clip's first sound lies hands this on, so the answer is where the clip
    /// is heard.
    var heardTightened: TightenedSounds {
        tightenWork.heard
    }

    /// Whether a clip should have a tightened sound and still waits for it, as it was when the clips were
    /// last gone through (`tightenedClips(of:)`). The finished sound of such a clip is made from the tightened
    /// one, so `SoundModel` waits for it.
    func tightenedSoundIsAwaited(of clipID: UUID) -> Bool {
        tightenWork.waiting.contains(clipID)
    }

    // MARK: Making the sound

    /// What the tightened sound of a clip depends on right now. Nil while the clip cannot be tightened: the
    /// song's beats are not found yet, or the syllables of one of its recordings are still being looked for.
    /// Such a clip is heard as recorded, and no sound is made for it until both are there.
    ///
    /// A clip that aims at another track is held against that track's syllables where they are heard
    /// (`heldAgainst`, in `CorrectionModel+Aim.swift`). Those depend on the sound that track's clips have,
    /// and so on what they depend on in turn, which is why the answers of one going-through are kept.
    ///
    /// - Parameter pass: the answers of this going-through of the clips, by clip. Left out, it is a
    ///   going-through of this one clip.
    ///   The pass also says which voice stands in for which recording on which track (`TighteningPass.voices`):
    ///   the voices of this pass, or `.none` for a dry send in Max's own voice.
    func tighteningInputs(
        of clip: Clip,
        in project: Project,
        pass: TighteningPass
    ) -> ClipTightening.Inputs? {
        let voices = pass.voices
        if let known = pass.inputs[clip.id] { return known }
        let markers = syllableMarkers.byRecording
        var inputs: ClipTightening.Inputs?
        if clip.segments.allSatisfy({ markers[$0.recordingID] != nil }) {
            switch heldAgainst(clip, in: project, pass: pass) {
            case .beat:
                // The clip's grid is part of what its sound is made from, so changed sub-beats make the
                // sound again. So is what the clip says for itself, which the inputs read from it: Lines or
                // All, its strength, and Stretch. A clip with Stretch off gets the stretch limit 0 there,
                // whatever Settings > Timing says.
                inputs = ClipTightening.Inputs(
                    correcting: clip,
                    in: project,
                    markers: markers,
                    settings: tightenSettings,
                    perBeat: grid(for: clip, in: project).perBeat, voices: voices
                )
            case .lead(let syllables):
                inputs = ClipTightening.Inputs(
                    correcting: clip, in: project, markers: markers, settings: tightenSettings, aimedAt: syllables, voices: voices
                )
            case .leadNotKnownYet:
                // The syllables of the track it aims at are still being looked for. As with its own.
                inputs = nil
            }
        }
        pass.inputs[clip.id] = .some(inputs)
        return inputs
    }

    /// Every clip with a timing fix that can be tightened, the takes that wait included, with what its sound
    /// depends on. The inputs are worked out again only for the tracks that changed since the last time
    /// (`TighteningInputsMemory`), and each entry is exactly what `tighteningInputs(of:in:pass:)` gives.
    ///
    /// A clip that aims at another track is held against that track's syllables where they are heard in
    /// this very going-through (`heldAgainst`, in `CorrectionModel+Aim.swift`). They are handed to the
    /// memory, which works such a clip's track out every time: the lead's sound can change while the
    /// double's own track stays as it is, and the double must then be found out of date.
    ///
    /// - Parameter voices: the voices of this pass (`VoicedClips.voices`), whose ids are part of the inputs.
    func clipsToTighten(in lookup: ProjectLookup, voices: TrackVoices) -> [TighteningInputsMemory.Entry] {
        let markers = syllableMarkers.byRecording
        let project = lookup.project
        // One going-through: a clip that others aim at is asked about once, not once for each of them.
        let pass = TighteningPass(voices: voices)
        return tightenWork.inputsMemory.inputs(
            in: lookup,
            markers: markers,
            settings: tightenSettings,
            // The clip's grid is part of what its sound is made from, so changed sub-beats make the sound again.
            perBeat: { [syllableMarkers] clip in
                syllableMarkers.feels.grid(for: clip, in: project, markers: markers).perBeat
            },
            aimedAt: { [self] clip in
                switch heldAgainst(clip, in: project, pass: pass) {
                case .beat: .beat
                case .lead(let syllables): .lead(syllables)
                case .leadNotKnownYet: .leadNotKnownYet
                }
            }, voices: voices
        )
    }

    /// Starts making the tightened sound of a clip, away from the main thread. A sound that was being made
    /// for the same clip from older inputs is given up.
    ///
    /// - Parameters:
    ///   - stamp: the number the inputs have in the memory of inputs (`TighteningInputsMemory.Entry`).
    ///   - voices: the samples of the voices of this pass, by the id they stand in under. The sound is made
    ///     from the voice each recording's inputs name (`inputs.voices`).
    private func makeTightenedSound(for inputs: ClipTightening.Inputs, stamp: Int, voices: [UUID: [Float]]) {
        let work = tightenWork
        work.making.removeValue(forKey: inputs.clipID)?.task.cancel()
        // The sounds of the clip's own recordings, asked for one by one: going through every loaded sound
        // for each clip was a third of what a change of Strength on thirty clips took in a big project.
        var needed: [UUID: [Float]] = [:]
        for id in inputs.recordings.keys {
            needed[id] = loadedSounds.sounds[id]
        }
        // And the voices that stand in for them, which the sound is made from in their place.
        for id in inputs.voices.values {
            needed[id] = voices[id]
        }
        let package = store.package
        let levels = work.levels
        let stretcher = CountingStretcher()
        let task = Task { [weak self] in
            let segments = await Self.tightenedSound(
                for: inputs, sounds: needed, in: package, levels: levels, stretcher: stretcher
            )
            guard let segments, !Task.isCancelled else { return }
            self?.tightenedSoundMade(segments, for: inputs, stamp: stamp, stretchedRuns: stretcher.count)
        }
        work.making[inputs.clipID] = TightenWork.Making(inputs: inputs, stamp: stamp, task: task)
    }

    /// The slow part: measures how loud the recordings are, where that is not known yet, finds the lines,
    /// their slides and where their syllables go, and builds the sound. Nil when it was given up on the way.
    ///
    /// - Parameter stretcher: what stretches the sound where syllables run together. It is handed in because
    ///   this runs away from the main thread, where nothing of the model can be reached.
    @concurrent
    private nonisolated static func tightenedSound(
        for inputs: ClipTightening.Inputs,
        sounds: [UUID: [Float]],
        in package: ProjectPackage?,
        levels: VoiceLevelStore,
        stretcher: any TimeStretcher
    ) async -> [ClipTightening.SegmentSound]? {
        var known: [UUID: VoiceLevels] = [:]
        // The levels are the recordings' own, never a made voice's: lines and pauses are found in what Max
        // recorded, and hold for every voice of it.
        for id in inputs.recordings.keys {
            guard let sound = sounds[id] else { continue }
            guard !Task.isCancelled else { return nil }
            known[id] = levels.levels(ofRecording: id, sound: sound, in: package)
        }
        guard !Task.isCancelled else { return nil }
        return ClipTightening.render(inputs, levels: known, recordings: sounds, stretcher: stretcher)
    }

    /// The tightened sound of a clip is done. It is kept, unless the clip has changed again in the meantime,
    /// and the clips are handed to the player again so it is heard.
    private func tightenedSoundMade(
        _ segments: [ClipTightening.SegmentSound],
        for inputs: ClipTightening.Inputs,
        stamp: Int,
        stretchedRuns: Int
    ) {
        let work = tightenWork
        guard let making = work.making[inputs.clipID], making.stamp == stamp || making.inputs == inputs else { return }
        work.making[inputs.clipID] = nil
        work.made[inputs.clipID] = TightenWork.MadeClip(inputs, segments, stamp: making.stamp, stretchedRuns: stretchedRuns)
        followTighteningSoon()
    }

    /// Hands the clips to the player again a moment from now. The sounds of several clips are often done at
    /// nearly the same moment, and they are then handed over together, not one by one.
    ///
    /// An edit of many clips (a move, a paste, a change of Strength) has all their sounds made again at the
    /// same time, and they are done one after the other within a tenth of a second or so. Each handing over
    /// works the window out again, so it waits until no sound is being made any more, and at the longest
    /// `followTogetherWait` from the first sound that was done. A sound that is made alone is handed over
    /// at once, as before.
    private func followTighteningSoon() {
        let work = tightenWork
        guard !work.followIsWaiting else { return }
        work.followIsWaiting = true
        Task { [weak self] in
            await Task.yield()
            let latest = ContinuousClock.now + Self.followTogetherWait
            while let model = self, !model.tightenWork.making.isEmpty, ContinuousClock.now < latest {
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard let self else { return }
            self.tightenWork.followIsWaiting = false
            guard self.loadedSounds.song != nil else { return }
            self.timeLaterPass { self.followClips(self.store.project) }
        }
    }

    /// The longest a sound that is done waits for the others that are still being made, before the clips
    /// are handed over with it: long enough for the sounds of one edit to come together, and too short to
    /// be heard as a wait.
    private static let followTogetherWait = Duration.milliseconds(120)

    // MARK: Markers and beats

    /// Listens for the next change of the two things a tightened sound depends on that do not come through
    /// `followClips`: the syllable markers, which are found in the background, and the beats.
    private func watchTighteningInputs() {
        guard !tightenWork.isWatching else { return }
        tightenWork.isWatching = true
        withObservationTracking(
            {
                _ = syllableMarkers.byRecording
                _ = store.project.grid
            },
            onChange: Self.tighteningInputsChangeReport(to: self)
        )
    }

    /// What is called when the markers or the project are about to change. It is made here, outside the main
    /// actor, and comes back to the model on the main actor a moment later, when the new value is in place.
    private nonisolated static func tighteningInputsChangeReport(to model: CorrectionModel) -> @Sendable () -> Void {
        { [weak model] in
            Task { @MainActor in
                model?.tighteningInputsChanged()
            }
        }
    }

    /// The markers or the project have changed. When that leaves a tightened sound out of date, the clips are
    /// handed to the player again, which also starts making the sound again.
    private func tighteningInputsChanged() {
        let work = tightenWork
        work.isWatching = false
        let project = store.project
        // With no clip that has a timing fix there is nothing to keep up. The next switch-on listens again.
        guard loadedSounds.song != nil, project.hasClipWithTimingFix else { return }
        watchTighteningInputs()
        let isOutOfDate = clipsToTighten(in: ProjectLookup(project), voices: voice.heard).contains { entry in
            work.made[entry.clip.id]?.isMade(from: entry) != true
                && work.making[entry.clip.id]?.isMaking(from: entry) != true
        }
        if isOutOfDate {
            followClips(project)
        }
    }

    // MARK: For an agent's run

    /// Whether the syllables of a recording are found. `-bigProject` adds its clips once those of all its
    /// recordings are, so their sounds are made once and not again for every recording that arrives.
    func hasMarkers(ofRecording id: UUID) -> Bool {
        syllableMarkers.byRecording[id] != nil
    }

    /// Whether no tightened sound is being made or waited for, as it was when the clips were last handed
    /// to the player. `-bigProject` and `-timeEdits` wait for it, so no sound is still being made when the
    /// next edit is timed.
    var soundsAreSettled: Bool {
        tightenWork.making.isEmpty && tightenWork.waiting.isEmpty && !tightenWork.followIsWaiting
    }

    /// Chooses Lines at 100 % for every clip of the first track, once the first project is open and the takes
    /// given with `-addTake` are in it, and says on standard error which lines were found and how far each
    /// slid. An agent that checks the app cannot press the button, and cannot hear.
    func tightenLaunchTrack() {
        let work = tightenWork
        guard !work.launchTaken, LaunchOptions.current.tightens else { return }
        work.launchTaken = true
        work.launch = Task { [weak self] in
            // Until the takes are added the track has no clip to tighten.
            await self?.takeStatus.ended()
            await self?.voice.launchVoiced()
            guard let line = await self?.tightenFirstTrackForAgent() else { return }
            FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
        }
    }

    /// Waits until what `-tighten`, `-strength` and `-lockedDouble` asked for is done. Returns at once when
    /// none was given. `-sendClip` waits for it, so the clip it sends is the one with its lines slid and its
    /// syllables moved.
    ///
    /// The locked double is waited for too, because it adds a take: while that take is being added nothing
    /// else may change the project, and `-sendClip` and `-trackSound` refuse with "the song is not ready".
    func launchTightened() async {
        await launchTightenedFirstTrack()
        await tightenWork.lockedDoubleLaunch?.value
    }

    /// Waits until what `-tighten` and `-strength` asked of the first track is done. The locked double
    /// waits for this and not for `launchTightened()`, which waits for the double itself.
    func launchTightenedFirstTrack() async {
        // `-trackVoice` acts before the correction, so whoever waits for the correction waits for it too.
        await voice.launchVoiced()
        await tightenWork.launch?.value
        await tightenWork.strengthLaunch?.value
    }

    /// Chooses All for every clip of the first track, with the strength `-strength` gave, once the first
    /// project is open and the takes given with `-addTake` are in it, and says on standard error which
    /// syllables moved and how far. The strength also scales the slide of the lines.
    /// An agent that checks the app cannot drag the slider, and cannot hear.
    func strengthenLaunchTrack() {
        let work = tightenWork
        guard work.strengthLaunch == nil, let strength = LaunchOptions.current.strength else { return }
        // With `-tighten` as well, the lines slide first, so the two lines on standard error come in that order.
        let tightening = work.launch
        work.strengthLaunch = Task { [weak self] in
            await self?.takeStatus.ended()
            await self?.voice.launchVoiced()
            await tightening?.value
            guard let line = await self?.strengthenFirstTrackForAgent(to: strength) else { return }
            FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
        }
    }

    /// Does what `-strength` asks and gives the line that says how it went.
    ///
    /// For every syllable that moved by itself the line gives where it was recorded in the song and how far
    /// it moved, in milliseconds, the slide of its line not counted. Negative is earlier. The first syllable
    /// of a line is listed like the others: its own move is the part of the line's move that is not the
    /// slide (`ClipTightening.Line.slideSamples`).
    private func strengthenFirstTrackForAgent(to strength: Double) async -> String {
        let refusal = "could not set the strength of the first track: "
        let ready = await firstTrackForAgent()
        guard let track = ready.track else { return refusal + ready.problem }
        let ids = Set(track.clips.map(\.id))
        let stretches = LaunchOptions.current.stretches
        // One change, so the sound is made once: All, the strength, and Stretch if `-stretch` was given.
        changeCorrection("Change Correction") { project in
            var changed = [project.setClips(ids, tighten: .all), project.setClips(ids, strength: strength)]
            if stretches { changed.append(project.setClips(ids, stretch: true)) }
            return changed.contains(true)
        }
        guard await soundIsMadeForAgent(ofTrack: track.id) else { return refusal + "the sound was not made" }
        let project = store.project
        let clips = project.track(track.id)?.clips ?? []
        let made = clips.compactMap { tightenWork.made[$0.id] }
        let lines = made.flatMap { $0.segments.flatMap(\.lines) }
        var syllables = 0
        var moved: [String] = []
        for line in lines {
            for marker in line.line.markers {
                syllables += 1
                let own = line.map.result(ofSource: marker) - marker - line.slideSamples
                guard own != 0 else { continue }
                let place = line.songStart + Double(marker - line.line.startSample) / Lockstep.sampleRate
                moved.append(String(format: "%.3f s %+.1f ms", place, Double(own) / Lockstep.sampleRate * 1_000))
            }
        }
        let excluded = clips.reduce(0) { count, clip in
            count + project.markers(in: clip, allMarkers: syllableMarkers.byRecording).count(where: \.isExcluded)
        }
        let runs = made.reduce(0) { $0 + $1.stretchedRuns }
        // What was asked for, as the clips keep it. A track without clips has nothing that could say.
        let percent = Int((min(max(strength, 0), 1) * 100).rounded())
        return "set the strength of the track \"\(track.name)\" to \(percent) %: "
            + "\(syllables) \(syllables == 1 ? "syllable" : "syllables") in "
            + "\(lines.count) \(lines.count == 1 ? "line" : "lines") of "
            + "\(clips.count) \(clips.count == 1 ? "clip" : "clips"), "
            + "\(moved.count) moved, \(excluded) excluded, "
            + "\(runs) \(runs == 1 ? "run" : "runs") stretched"
            + (moved.isEmpty ? "" : ": " + moved.joined(separator: ", "))
    }

    /// Waits until the first track's clips can get a timing fix, and gives the track, or what is in the way.
    ///
    /// A fix needs the song's beats and the recordings' syllables, and both are found in the background.
    private func firstTrackForAgent() async -> (track: Track?, problem: String) {
        guard await waitForAgent(seconds: 300, until: { $0.store.project.grid?.beats.isEmpty == false }) else {
            return (nil, "the beats of the song were not found")
        }
        guard let track = store.project.tracks.first else { return (nil, "the project has no track") }
        let recordings = Set(track.clips.flatMap { $0.segments.map(\.recordingID) })
        guard await waitForAgent(seconds: 60, until: { model in
            recordings.allSatisfy { model.syllableMarkers.byRecording[$0] != nil }
        }) else {
            return (nil, "the syllables of its recordings were not found")
        }
        guard takeStatus.phase == nil else { return (nil, "a take is going") }
        return (track, "")
    }

    /// Waits until every clip of a track has the sound its timing fix asks for. False when that took too long.
    private func soundIsMadeForAgent(ofTrack trackID: UUID) async -> Bool {
        await waitForAgent(seconds: 60, until: { model in
            let project = model.store.project
            let onTrack = Set(project.track(trackID)?.clips.map(\.id) ?? [])
            return model.clipsToTighten(in: ProjectLookup(project), voices: model.voice.heard)
                .filter { onTrack.contains($0.clip.id) }
                .allSatisfy { model.tightenWork.made[$0.clip.id]?.isMade(from: $0) == true }
        })
    }

    /// Does what `-tighten` asks and gives the line that says how it went.
    private func tightenFirstTrackForAgent() async -> String {
        let refusal = "could not tighten the first track: "
        let ready = await firstTrackForAgent()
        guard let track = ready.track else { return refusal + ready.problem }
        let ids = Set(track.clips.map(\.id))
        let stretches = LaunchOptions.current.stretches
        // Lines at 100 %, so every line slides the whole way, as `-tighten` always meant. Stretch, if
        // `-stretch` was given, changes nothing that is heard until All is chosen.
        changeCorrection("Change Correction") { project in
            var changed = [project.setClips(ids, tighten: .lines), project.setClips(ids, strength: 1)]
            if stretches { changed.append(project.setClips(ids, stretch: true)) }
            return changed.contains(true)
        }
        guard await soundIsMadeForAgent(ofTrack: track.id) else {
            return refusal + "the tightened sound was not made"
        }
        let clips = store.project.track(track.id)?.clips ?? []
        let lines = clips.flatMap { tightenWork.made[$0.id]?.segments.flatMap(\.lines) ?? [] }
        let listed = lines.map { String(format: "%.3f s %+.1f ms", $0.songStart, $0.shiftMs) }.joined(separator: ", ")
        return "tightened the track \"\(track.name)\": \(lines.count) \(lines.count == 1 ? "line" : "lines") in "
            + "\(clips.count) \(clips.count == 1 ? "clip" : "clips")" + (lines.isEmpty ? "" : ": " + listed)
    }

    /// Looks every 50 ms whether something has happened, for so many seconds at most.
    func waitForAgent(seconds: Double, until isDone: (CorrectionModel) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !isDone(self) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}

/// Syllable markers: where each syllable of a recording starts.
///
/// They are found once per recording and kept in the project's cache (`SyllableMarkers`).
/// The model asks for them at the two moments a recording comes into the window: when a
/// take has just become a clip (`findMarkers(ofRecording:sound:)`, called by `keep`), and
/// when a project is opened (`findMarkers(ofOpenedRecordings:in:)`, called by `show`).
///
/// What draws them (the timing marks, further down) reads `markers(in:)`, which gives the markers
/// inside a clip with their song times, and measures each against the beats with
/// `MarkerDistance`.
///
/// A click on a marker leaves that syllable out of the timing fixes, or takes it back in
/// (`markerClicked(_:inClip:)`). There is no menu command for it: it is done with the pointer only.
extension CorrectionModel {
    /// A syllable marker of a clip was clicked: the syllable is excluded from the timing fixes, or taken
    /// back in when it was excluded, as one step that can be undone. Its marker is then drawn hollow, the
    /// syllable stays where it was recorded, and the sound of its clip is made again.
    ///
    /// The exclusion is kept with the recording (`Recording.excludedMarkers`), so it survives a split, a
    /// join and a move of the clip. Nothing happens during a take.
    ///
    /// - Parameter markerID: the marker's id in the window, as `showMarkers` gave it.
    func markerClicked(_ markerID: UUID, inClip clipID: UUID) {
        let project = store.project
        guard FeatureSet.built.contains(.quantize), takeStatus.phase == nil, let clip = project.clip(clipID),
              let marker = markers(in: clip).first(where: {
                  Self.markerID(recording: $0.recordingID, sample: $0.sample) == markerID
              }),
              let found = syllableMarkers.byRecording[marker.recordingID]
        else { return }
        let excludes = !marker.isExcluded
        store.edit(excludes ? "Exclude Syllable" : "Include Syllable") { project in
            guard let index = project.recordings.firstIndex(where: { $0.id == marker.recordingID }) else { return }
            project.recordings[index].setExcluded(excludes, markerAt: marker.sample, among: found)
        }
        followClips(store.project)
    }

    /// The markers that fall inside a clip, each with the moment it sounds in the song.
    /// Empty until the markers of the clip's recordings are known.
    func markers(in clip: Clip) -> [ClipMarker] {
        store.project.markers(in: clip, allMarkers: syllableMarkers.byRecording)
    }

    /// A take has just become a clip: its markers are found in the background and kept
    /// in the project, so they are there when the clip is selected.
    func findMarkers(ofRecording id: UUID, sound: [Float]) {
        guard let package = store.package else { return }
        syllableMarkers.find(ofRecording: id, sound: sound, in: package)
    }

    /// A project has just been opened: the markers of its recordings are read from its
    /// cache, and found for every recording that has none there.
    func findMarkers(ofOpenedRecordings sounds: [UUID: [Float]], in package: ProjectPackage) {
        syllableMarkers.open(package, recordings: store.project.recordings, sounds: sounds)
    }
}

/// The feel, which the interface calls "Sub-beats": whether a clip's timing is measured against sixteenths
/// or triplets.
///
/// `grid(for:in:)` is the one place the app asks. The colours and distances of the syllable markers and the
/// sub-beat lines (the timing marks), the slides of Tighten lines (the correction of timing) and the small "3" in
/// a clip's bar (`showFeels`) all read it, so they always agree.
///
/// For a clip on Auto the answer comes from the clip's syllables, and is kept until they or the beats change
/// (`FeelMemory`).
///
/// Choosing: only a clip has a feel. It is chosen under "Correction" in the panel on the right, in
/// Clip > Sub-beats and in the clip's right-click menu, for the selected clips: 16ths, Triplets or Auto. All
/// of them perform one of three commands (`AppCommand.clipFeel`), and each choice is one step that can be
/// undone. The feel is saved with the project, in each clip. The song had a choice of its own until Max
/// took it away in phase 27.
extension CorrectionModel {
    // MARK: Choosing

    /// Whether a feel command can act: it needs a selected clip.
    func canChooseFeel(_ command: AppCommand) -> Bool {
        command.clipFeel != nil && !selection.clipIDs.isEmpty
    }

    /// Whether a feel command is the choice in force, which ticks its menu item: the feel that every
    /// selected clip has.
    func feelIsChosen(_ command: AppCommand) -> Bool {
        guard let feel = command.clipFeel else { return false }
        let clips = store.project.clips(selection.clipIDs)
        return !clips.isEmpty && clips.allSatisfy { $0.feel == feel }
    }

    /// Carries out a feel command.
    func chooseFeel(_ command: AppCommand) {
        if let feel = command.clipFeel { setSelectedClipsFeel(feel) }
    }

    /// Gives the selected clips a feel, 16ths, Triplets or Auto, as one step that can be undone. Nothing
    /// happens when they all have it already. The clips are then drawn and handed to the player again, so
    /// the markers are measured against the new grid and the tightened sounds are made again.
    func setSelectedClipsFeel(_ feel: ClipFeel) {
        let ids = selection.clipIDs
        var probe = store.project
        guard probe.setClips(ids, feel: feel) else { return }
        store.edit("Change Clip Sub-beats") { $0.setClips(ids, feel: feel) }
        followClips(store.project)
    }

    // MARK: The grid of a clip

    /// The grid a clip's timing is measured against right now: the one it has chosen, or on Auto what its
    /// syllables say. On Auto a clip is on sixteenths until its syllables are found.
    func grid(for clip: Clip, in project: Project) -> SubBeatGrid {
        syllableMarkers.feels.grid(for: clip, in: project, markers: syllableMarkers.byRecording)
    }

    /// Called by `showClips`: tells every clip in the rows whether its grid is triplets, which puts the small
    /// "3" in its bar, and which feel it has chosen, which its right-click menu ticks and the panel shows.
    ///
    /// The choice itself is in the rows already (`ShownClips` reads it from the clip). What is set here is
    /// the "3", which only a clip whose grid is triplets has, so most rows are left as they were made.
    func showFeels(in rows: inout [TrackRow], of lookup: ProjectLookup) {
        let project = lookup.project
        for row in rows.indices {
            for index in rows[row].clips.indices {
                guard let clip = lookup.clip(rows[row].clips[index].id) else { continue }
                // Only the take that is drawn has a bar to put the "3" in, and only such a take is in a row.
                let isTriplet = grid(for: clip, in: project) == .triplets
                if rows[row].clips[index].isTriplet != isTriplet {
                    rows[row].clips[index].isTriplet = isTriplet
                }
            }
        }
        // Only clips on Auto are remembered, so in most projects there is nothing to forget.
        if !syllableMarkers.feels.isEmpty {
            syllableMarkers.feels.forget(allBut: Set(project.tracks.flatMap { $0.clips.map(\.id) }))
        }
        // What each clip aims at stands in the same row of the panel and the same menu as its sub-beats.
        showAims(in: &rows, of: project)
    }
}

/// The timing marks of the selected clips, as the timeline draws them: a marker at every
/// syllable, coloured by how far it is from the nearest sub-beat, and the sub-beat lines to
/// judge the markers against.
///
/// `showClips` calls `showMarkers(in:of:)` with the rows it has made. Only selected clips get
/// marks, and only the take that is drawn is ever in a row. The marks are worked out again
/// by themselves when the markers of a recording arrive from the background, and when the
/// setting for what counts as deliberately off is changed.
///
/// Where a marker is drawn is decided in one place, `shownTime(of:in:)`.
extension CorrectionModel {
    /// The moment of the song at which a marker is drawn and measured against the beats.
    ///
    /// It is where the syllable sounds with the clip where it is now. Anything that
    /// moves a syllable when it is played is added here, so the marker stands where the
    /// syllable is heard. On a clip with a timing fix that is the slide of the
    /// syllable's line and the syllable's own move, for as long as the tightened clip is what
    /// is heard: until the tightened sound is made, the marker stands as recorded.
    func shownTime(of marker: ClipMarker, in clip: Clip) -> Double {
        let segment = clip.segments.firstIndex { segment in
            segment.recordingID == marker.recordingID
                && marker.sample >= segment.inSample && marker.sample < segment.outSample
        }
        guard let segment else { return marker.songTime }
        return marker.songTime + heardShift(ofMarkerAt: marker.sample, inSegment: segment, of: clip.id)
    }

    /// Called by `showClips`: gives every selected clip in the rows its timing marks.
    func showMarkers(in rows: inout [TrackRow], of lookup: ProjectLookup) {
        guard FeatureSet.built.contains(.timingMarkers) else { return }
        watchMarkers()
        let deliberatePercent = settings[.deliberatePercent]
        // The beats' own times, which the sub-beat lines leave out: made once for all the selected clips,
        // and only when one is selected.
        var beatTimes: Set<Double>?
        for row in rows.indices {
            for index in rows[row].clips.indices where rows[row].clips[index].isSelected {
                guard let clip = lookup.clip(rows[row].clips[index].id) else { continue }
                if beatTimes == nil {
                    beatTimes = Set(lookup.project.grid?.beats.map(\.time) ?? [])
                }
                let marks = timingMarks(
                    of: clip,
                    in: lookup,
                    beatTimes: beatTimes ?? [],
                    deliberatePercent: deliberatePercent
                )
                if rows[row].clips[index].timingMarks != marks {
                    rows[row].clips[index].timingMarks = marks
                }
            }
        }
    }

    /// The song's beats have changed: they were found, one was moved, or the tempo was halved or
    /// doubled. The markers of the selected clips are measured against the new beats.
    ///
    /// It happens a moment later, because this is also called in the middle of an edit, before the
    /// new beats are in the store. Without it a clip selected before the beats were found kept
    /// neutral markers until something else redrew it.
    ///
    /// For a clip whose sub-beats are on Auto, new beats can also change whether it counts in triplets,
    /// selected or not, so with such a clip the clips are drawn again whatever is selected.
    ///
    /// The store's project is not read here but in the moment after: this is called while the store is
    /// changing that very project (new beats are put in it), and reading it then stops the app.
    func remeasureMarkers() {
        guard FeatureSet.built.contains(.timingMarkers) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let hasClipOnAuto = store.project.tracks.contains { $0.clips.contains { $0.feel == .auto } }
            guard !selection.clipIDs.isEmpty || hasClipOnAuto else { return }
            showClips(store.project)
        }
    }

    /// The marks of one clip. Without beats to measure against, every marker is neutral.
    private func timingMarks(
        of clip: Clip,
        in lookup: ProjectLookup,
        beatTimes: Set<Double>,
        deliberatePercent: Double
    ) -> ClipTimingMarks {
        let project = lookup.project
        // A clip that aims at another track is judged against that track's syllables, not the sub-beats.
        if let marks = timingMarksAgainstLead(of: clip, in: project) { return marks }
        let grid = project.grid
        // Four sub-beats to a beat, or six for a clip whose grid is triplets.
        let perBeat = self.grid(for: clip, in: project).perBeat
        let markers = lookup.markers(in: clip, allMarkers: syllableMarkers.byRecording).map { marker in
            let time = shownTime(of: marker, in: clip)
            var offset: Double?
            var timing = LockstepUI.SyllableMarker.Timing.deliberate
            if let grid,
               let nearest = MarkerDistance.nearestSubBeat(to: time, grid: grid, perBeat: perBeat)
            {
                let distance = time - nearest.subBeatTime
                offset = distance
                timing = switch MarkerDistance.classify(
                    offset: distance,
                    spacing: nearest.spacing,
                    deliberatePercent: deliberatePercent
                ) {
                case .onBeat: .onBeat
                case .slightlyOff: .slightlyOff
                case .deliberate: .deliberate
                }
            }
            return LockstepUI.SyllableMarker(
                id: Self.markerID(recording: marker.recordingID, sample: marker.sample),
                time: time,
                offsetMilliseconds: (offset ?? 0) * 1000,
                timing: timing,
                isExcluded: marker.isExcluded,
                // Where the song has no beats there is no distance to read.
                hasDistance: offset != nil
            )
        }
        return ClipTimingMarks(
            markers: markers,
            subBeatTimes: Self.subBeatLines(
                of: clip, in: lookup, beatTimes: beatTimes, perBeat: perBeat, reach: heardReach(of: clip)
            ),
            subBeatLineFade: Self.subBeatLineFade,
            readoutDelay: Self.markerReadoutDelay
        )
    }

    /// How long the pointer rests at a marker before its distance is shown, in seconds.
    static let markerReadoutDelay = 0.15

    /// The distance between two sub-beat lines, in points, over which the lines fade in
    /// while zooming in: none at 12 points and closer, full strength from 16 points on.
    static let subBeatLineFade: ClosedRange<CGFloat> = 12...16

    /// The sub-beats across a clip, in song seconds, without the beats themselves, which the
    /// timeline already draws. There are none where the song has no beats.
    ///
    /// - Parameters:
    ///   - beatTimes: the times of the song's beats.
    ///   - perBeat: how many parts the clip's grid cuts a beat into: 4 for sixteenths, 6 for triplets.
    ///   - reach: how far the clip is heard past its own start and end, in seconds (`heardReach(of:)`). A
    ///     line that slid out of the clip has its first syllable there, on a sub-beat, and that sub-beat's
    ///     line is drawn too.
    private static func subBeatLines(
        of clip: Clip,
        in lookup: ProjectLookup,
        beatTimes: Set<Double>,
        perBeat: Int,
        reach: (before: Double, after: Double)
    ) -> [Double] {
        guard let grid = lookup.project.grid, let start = lookup.start(of: clip), let end = lookup.end(of: clip),
              end > start
        else { return [] }
        return grid.subBeats(perBeat: perBeat, in: (start - reach.before)...(end + reach.after))
            .filter { !beatTimes.contains($0) }
    }

    /// The identity of a marker in the window. It is made from the recording and the place
    /// in it, so a marker keeps its identity when its clip is moved, split or drawn again.
    static func markerID(recording: UUID, sample: Int) -> UUID {
        var bytes = recording.uuid
        withUnsafeMutableBytes(of: &bytes) { raw in
            withUnsafeBytes(of: UInt64(truncatingIfNeeded: sample).littleEndian) { place in
                for index in 0..<8 {
                    raw[8 + index] ^= place[index]
                }
            }
        }
        return UUID(uuid: bytes)
    }

    // MARK: Drawing again when something the marks are made from changes

    /// Listens once for the next change of the found markers or of the setting. Called
    /// every time the marks are made, and it does nothing while it is already listening.
    private func watchMarkers() {
        guard !syllableMarkers.isWatched else { return }
        syllableMarkers.isWatched = true
        withObservationTracking(
            {
                _ = syllableMarkers.byRecording
                _ = settings[.deliberatePercent]
            },
            onChange: Self.markersChangeReport(to: self)
        )
    }

    /// What is called when the found markers or the setting are about to change. It is made here,
    /// outside the main actor, and comes back to the model on the main actor a moment
    /// later, when the new value is in place.
    private nonisolated static func markersChangeReport(to model: CorrectionModel) -> @Sendable () -> Void {
        { [weak model] in
            Task { @MainActor in
                guard let model else { return }
                model.syllableMarkers.isWatched = false
                model.showClips(model.store.project)
            }
        }
    }
}

/// What the model keeps for tightening: the tightened sounds that are made and the ones being made.
@MainActor
@Observable
final class TightenWork {
    /// The tightened sound of one clip, and what it was made from.
    struct MadeClip {
        var inputs: ClipTightening.Inputs
        /// One for every segment of the clip: its lines with their slides, and the sound if a line moved.
        var segments: [ClipTightening.SegmentSound]
        /// The id each segment's sound is handed to the player under, or nil for a segment without one. A
        /// sound that is made again gets a new id, which is how the player knows that it has changed.
        var ids: [UUID?]
        /// How many pieces of the clip's sound went through the stretcher: the runs of syllables that run
        /// together and moved by different amounts. 0 when pauses took up every move.
        var stretchedRuns: Int
        /// The number the inputs had in the memory of inputs when the sound was last seen to be made from
        /// them, or nil for a sound that was made for an export. See `isMade(from:)`.
        var stamp: Int?

        init(
            _ inputs: ClipTightening.Inputs,
            _ segments: [ClipTightening.SegmentSound],
            stamp: Int?,
            stretchedRuns: Int
        ) {
            self.inputs = inputs
            self.segments = segments
            ids = segments.map { $0.samples == nil ? nil : UUID() }
            self.stamp = stamp
            self.stretchedRuns = stretchedRuns
        }

        /// Whether the sound was made from what the clip depends on now. The same number says yes at once
        /// (`TighteningInputsMemory.Entry.stamp`). Only when the inputs were worked out again are they compared.
        func isMade(from entry: TighteningInputsMemory.Entry) -> Bool {
            stamp == entry.stamp || inputs == entry.inputs
        }
    }

    /// The tightened sound of a clip while it is being made.
    struct Making {
        var inputs: ClipTightening.Inputs
        /// The number the inputs have in the memory of inputs.
        var stamp: Int
        var task: Task<Void, Never>

        /// Whether the sound is being made from what the clip depends on now.
        func isMaking(from entry: TighteningInputsMemory.Entry) -> Bool {
            stamp == entry.stamp || inputs == entry.inputs
        }
    }

    /// The tightened sounds that are made, by clip id.
    @ObservationIgnored var made: [UUID: MadeClip] = [:]
    /// The ones that are being made, by clip id.
    @ObservationIgnored fileprivate var making: [UUID: Making] = [:]
    /// The tightened sounds made for a send from another source than the player's, by clip id: in Max's own
    /// voice for a dry send of a clip whose track has a Voice. One for each clip of the open Send to DaVinci
    /// panel, never handed to the player, and forgotten when the panel closes (`forgetSendSounds`).
    @ObservationIgnored fileprivate var madeDry: [UUID: MadeClip] = [:]
    /// Which tightened sounds are heard: what the player was last handed, or will be when the take ends.
    @ObservationIgnored fileprivate var heard = TightenedSounds.none
    /// How loud each recording is, measured once and kept for as long as the project has the recording.
    @ObservationIgnored let levels = VoiceLevelStore()
    /// The recordings `levels` was last tidied for.
    @ObservationIgnored fileprivate var levelsKeptFor: [Recording] = []
    /// What the sound of every clip depends on, kept for each track so that an edit works out again only
    /// the tracks it changed.
    @ObservationIgnored fileprivate var inputsMemory = TighteningInputsMemory()
    /// The clips that should have a tightened sound, and those of them that still wait for it, for the ring
    /// in the panel. `CorrectionModel.tightenedClips` keeps both.
    @ObservationIgnored fileprivate var wanted: Set<UUID> = []
    @ObservationIgnored fileprivate var waiting: Set<UUID> = []
    /// True while a handing over of the clips is waiting to happen.
    @ObservationIgnored fileprivate var followIsWaiting = false
    /// True while the markers and the beats are being listened to.
    @ObservationIgnored fileprivate var isWatching = false
    /// True once what `-tighten` asked for was started.
    @ObservationIgnored fileprivate var launchTaken = false
    /// The work `-tighten` asked for, while it is going on and after.
    @ObservationIgnored fileprivate var launch: Task<Void, Never>?
    /// The work `-strength` asked for, while it is going on and after.
    @ObservationIgnored fileprivate var strengthLaunch: Task<Void, Never>?
    /// The work `-lockedDouble` asked for, while it is going on and after.
    @ObservationIgnored var lockedDoubleLaunch: Task<Void, Never>?
}

extension Project {
    /// Whether any clip's timing is corrected (`Clip.hasTimingFix`).
    var hasClipWithTimingFix: Bool {
        tracks.contains { $0.clips.contains(where: \.hasTimingFix) }
    }
}

/// The real stretcher, counting how many pieces of sound it was asked to stretch. One is made for every
/// clip whose sound is built, so the count is that clip's. Safe to use from any thread.
final class CountingStretcher: TimeStretcher {
    private let stretcher = RubberBandStretcher()
    private let runs = Mutex(0)

    /// How many pieces went through the stretcher so far.
    var count: Int {
        runs.withLock { $0 }
    }

    func stretch(_ samples: [Float], keyFrames: [(source: Int, target: Int)], outputLength: Int) -> [Float] {
        runs.withLock { $0 += 1 }
        return stretcher.stretch(samples, keyFrames: keyFrames, outputLength: outputLength)
    }
}

/// How loud each recording is, as the search for lines wants it (`VoiceLevels`), by recording id.
///
/// The numbers are the recording's loudness curve, which was kept in the project when the recording was
/// made. They are read from there, or measured again when the file is gone. Either takes a moment, so they
/// are asked for away from the main thread, and kept. Safe to use from any thread.
final class VoiceLevelStore: Sendable {
    private let known = Mutex<[UUID: VoiceLevels]>([:])

    /// - Parameter sound: the recording's samples: mono, 48,000 Hz.
    func levels(ofRecording id: UUID, sound: [Float], in package: ProjectPackage?) -> VoiceLevels {
        known.withLock { known in
            if let kept = known[id] { return kept }
            let envelope = package.flatMap { VoiceEnvelope.read(forRecording: id, lengthSamples: sound.count, from: $0) }
                ?? VoiceEnvelope.envelope(of: sound)
            let levels = VoiceLevels(
                values: envelope.values,
                threshold: envelope.noiseFloor + VoiceEnvelope.clearlyAboveDecibels,
                hopSamples: VoiceEnvelope.hopSamples
            )
            known[id] = levels
            return levels
        }
    }

    /// Forgets the recordings a project no longer has.
    func forget(allBut ids: Set<UUID>) {
        known.withLock { known in
            guard known.keys.contains(where: { !ids.contains($0) }) else { return }
            known = known.filter { ids.contains($0.key) }
        }
    }
}

extension ClipCorrection {
    /// The choice as the panel on the right shows it.
    init(_ tighten: ClipTighten) {
        switch tighten {
        case .off: self = .off
        case .lines: self = .lines
        case .all: self = .all
        }
    }
}

extension ClipTighten {
    /// The choice that a button of the panel on the right stands for.
    init(_ correction: ClipCorrection) {
        switch correction {
        case .off: self = .off
        case .lines: self = .lines
        case .all: self = .all
        }
    }
}

// The feel as the project keeps it and as the window's controls show it: the same choices under two names.

extension ClipMenu.Feel {
    init(_ feel: ClipFeel) {
        switch feel {
        case .sixteenths: self = .sixteenths
        case .triplets: self = .triplets
        case .auto: self = .auto
        }
    }
}

extension ClipFeel {
    init(_ shown: ClipMenu.Feel) {
        switch shown {
        case .sixteenths: self = .sixteenths
        case .triplets: self = .triplets
        case .auto: self = .auto
        }
    }
}

extension AppModel {
    /// Gives `correction` its closures. `wire()` calls it once, when every part is made.
    func wireCorrection() {
        correction.followClips = { [weak self] project in self?.clips.followClips(of: project) }
        correction.showClips = { [weak self] project in self?.clips.showClips(of: project) }
        correction.timeLaterPass = { [weak self] pass in self?.clipEditing.timeLaterPass(pass) ?? pass() }
        correction.addTakeOnNewTrack = { [weak self] url in await self?.transport.addTakeOnNewTrack(fromFile: url) }
    }
}

import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

// What the window is handed: what it draws, the tables of what its controls do, and the two
// right-click menus, which turn a choice into a command. All of it is routing: each line reads
// from, or calls, the part or the ground object that holds the thing.
extension AppModel {
    /// What the window draws: `content`, with the snapping button as the setting says.
    /// The setting is read here and not copied into `content`, so the button can never
    /// show anything but the setting, whoever changes it.
    var windowContent: MainLayoutContent {
        var shown = windowState.content
        shown.snappingIsOn = settings[.snapping]
        shown.snapChoices = settings.snapChoices
        // The Send to DaVinci panel and its button, read here for the same reason.
        shown.send = send.sendSheet
        shown.canSendToDaVinci = send.canSendSelectedClip
        // Paste Sound in the right-click menus is greyed out until a sound is copied, read here for the
        // same reason.
        shown.canPasteSound = soundCopy.copied != nil
        // Whether the song is selected, read here for the same reason: whoever selects a clip or
        // a track lets go of the song (`Selection`), and the window then shows that at once.
        shown.timeline.songIsSelected = selection.songIsSelected
        return shown
    }

    /// What the window's controls do. The window hands them to `MainLayout`.
    var layoutActions: MainLayoutActions {
        var actions = MainLayoutActions()
        actions.transport = { [weak self] button in
            switch button {
            case .play: self?.perform(.playStop)
            case .record: self?.perform(.record)
            case .loop: self?.perform(.loop)
            }
        }
        actions.seek = { [weak self] seconds in
            guard let self else { return }
            self.transport.seek(to: self.playheadModel.snappedPlayheadPlace(seconds))
        }
        actions.rulerDragged = { [weak self] drag in self?.playheadModel.rulerDragged(drag) }
        actions.timelineWidthChanged = { [weak self] width in self?.timelineView.timelineWidth = Double(width) }
        // Kept across a restart (the view's memory in `TimelineViewModel`).
        actions.rowsPosition = timelineView.rowsPosition
        actions.inspectorChosen = { [weak self] isShown in self?.timelineView.inspectorChosen(isShown) }
        actions.timeFollowsPlayhead = true
        actions.tempo = tempo
        actions.micLevel = micLevel
        actions.timelinePinchesAndScrolls = true
        actions.beatMoved = { [weak self] move in self?.beats.moveBeat(from: move.from, to: move.to) }
        actions.songDragged = { [weak self] drag in self?.songPlace.songDragged(drag) }
        actions.beatOneChosen = { [weak self] seconds in self?.beats.setBeatOne(nearest: seconds) }
        actions.songCommand = { [weak self] command in
            switch command {
            case .createClickTrack: self?.perform(.createClickTrack)
            case .findBeatsAgain: self?.perform(.findBeatsAgain)
            case .halveTempo: self?.perform(.halveTempo)
            case .doubleTempo: self?.perform(.doubleTempo)
            }
        }
        actions.messageClosed = { [weak self] in self?.windowState.content.message = nil }
        actions.trackTapped = { [weak self] trackID, seconds in
            self?.clipEditing.timeEdit("Click in a track's row") { self?.clipEditing.trackRowClicked(on: trackID, at: seconds) }
        }
        actions.clipCommand = { [weak self] command, clipID in self?.clipMenuCommand(command, on: clipID) }
        actions.clipCommandIsEnabled = { [weak self] command, clipID in
            self?.clipMenuCommandIsEnabled(command, on: clipID) ?? false
        }
        actions.tracks = trackActions
        actions.calibration = calibrationActions
        actions.send = sendActions
        actions.clips = clipActions
        actions.snappingPressed = { [weak self] in self?.perform(.snapping) }
        actions.snapChoicesChanged = { [weak self] choices in self?.setSnapChoices(choices) }
        actions.clipVolumeChanged = { [weak self] volume, isFinal in self?.volume.setSelectedClipVolume(volume, isFinal: isFinal) }
        actions.songHeaderPressed = { [weak self] in self?.songVolume.selectSong() }
        actions.songVolumeChanged = { [weak self] volume, isFinal in self?.songVolume.setSongVolume(volume, isFinal: isFinal) }
        var tighten = TightenActions()
        tighten.correctionChosen = { [weak self] correction in self?.perform(.choosing(ClipTighten(correction))) }
        tighten.subBeatsChosen = { [weak self] feel in self?.perform(.choosing(ClipFeel(feel))) }
        tighten.strengthChanged = { [weak self] strength in
            self?.clipEditing.timeEdit("Change Strength") { self?.correction.setSelectedClipsStrength(strength) }
        }
        tighten.stretchChanged = { [weak self] isOn in
            self?.clipEditing.timeEdit("Switch Stretch") { self?.correction.setSelectedClipsStretch(isOn) }
        }
        tighten.aimChosen = { [weak self] trackID in self?.aimSelectedClips(at: trackID) }
        actions.tighten = tighten
        actions.sound = soundActions
        actions.voice = voiceActions
        actions.effects = effectsActions
        var takes = TakesActions()
        takes.countPressed = { [weak self] clipID in self?.takes.selectClip(withTakeCount: clipID) }
        takes.rowPressed = { [weak self] number in self?.takes.takeRowPressed(number) }
        takes.playPressed = { [weak self] number in self?.transport.playOrStopTake(number) }
        takes.deleteOtherTakesPressed = { [weak self] in self?.takes.deleteOtherTakes() }
        actions.takes = takes
        var click = ClickActions()
        click.toggled = { [weak self] in self?.perform(.clickOnOff) }
        click.soundChosen = { [weak self] sound in self?.click.chooseClickSound(LockstepCore.ClickSound(sound)) }
        click.volumeChanged = { [weak self] volume, isFinal in self?.click.setClickVolume(volume, isFinal: isFinal) }
        click.divisionChosen = { [weak self] division in
            self?.click.chooseClickDivision(LockstepCore.ClickDivision(division))
        }
        click.subBeatsChosen = { [weak self] subBeats in self?.click.chooseClickSubBeats(SubBeatGrid(subBeats)) }
        click.countInChosen = { [weak self] bars in self?.click.chooseCountIn(bars) }
        click.recordSpeedChosen = { [weak self] percent in self?.click.chooseRecordSpeed(percent) }
        actions.click = click
        return actions
    }

    /// What the track list does: its headers and the button under the last track.
    private var trackActions: TrackActions {
        var tracks = TrackActions()
        tracks.newTrackPressed = { [weak self] in self?.perform(.newTrack) }
        tracks.headerPressed = { [weak self] trackID in self?.tracks.selectTrack(trackID) }
        tracks.mutePressed = { [weak self] trackID in
            self?.clipEditing.timeEdit("Mute button of a track") { self?.tracks.toggleMute(ofTrack: trackID) }
        }
        tracks.volumeChanged = { [weak self] trackID, volume, isFinal in
            self?.trackVolume.setTrackVolume(trackID, volume, isFinal: isFinal)
        }
        tracks.nameDoubleClicked = { [weak self] trackID in self?.tracks.startRenamingTrack(trackID) }
        tracks.renameEnded = { [weak self] trackID, name in self?.tracks.endRenamingTrack(trackID, as: name) }
        tracks.dragged = { [weak self] move in self?.tracks.trackDragged(move) }
        tracks.menuCommand = { [weak self] command, trackID in self?.trackMenuCommand(command, on: trackID) }
        return tracks
    }

    /// What the section "Sound" of the panel on the right does: the Sound menu of a track and the knobs
    /// of a track and of the selected clips. A knob reports every move, and only the one it is let go
    /// with is an edit, which is timed like the others.
    /// What the section "Voice" of the panel and the submenu "Voice" of a track's right-click menu report. A
    /// knob that is still being dragged changes nothing: letting go is the edit. Natural is not built, so its
    /// switch and the button that opens its settings pane are never shown and lead nowhere.
    private var voiceActions: VoiceActions {
        var voice = VoiceActions()
        voice.switched = { [weak self] trackID, isOn in
            self?.clipEditing.timeEdit(isOn ? "Turn Voice On" : "Turn Voice Off") {
                self?.voice.switchVoice(of: trackID, on: isOn)
            }
        }
        voice.menuCommand = { [weak self] command, trackID in
            self?.clipEditing.timeEdit("Voice menu of a track") { self?.voice.voiceMenu(command, on: trackID) }
        }
        voice.knobChanged = { [weak self] trackID, knob, value, isFinal in
            guard isFinal else { return }
            self?.clipEditing.timeEdit("Change Voice") { self?.voice.turnKnob(knob, of: trackID, to: value, isFinal: true) }
        }
        voice.tryAgainPressed = { [weak self] trackID in self?.voice.tryAgain(on: trackID) }
        return voice
    }

    private var soundActions: SoundActions {
        var sound = SoundActions()
        sound.menuCommand = { [weak self] command, trackID in
            self?.clipEditing.timeEdit("Sound menu of a track") { self?.sound.soundMenu(command, on: trackID) }
        }
        sound.trackKnobChanged = { [weak self] trackID, knob, value, isFinal in
            guard isFinal else { self?.sound.setTrackKnob(trackID, knob, value, isFinal: false); return }
            self?.clipEditing.timeEdit("Change Sound") { self?.sound.setTrackKnob(trackID, knob, value, isFinal: true) }
        }
        sound.clipKnobChanged = { [weak self] knob, value, isFinal in
            guard isFinal else { self?.sound.setSelectedClipsKnob(knob, value, isFinal: false); return }
            self?.clipEditing.timeEdit("Change Clip Sound") { self?.sound.setSelectedClipsKnob(knob, value, isFinal: true) }
        }
        sound.clipKnobReset = { [weak self] knob in
            self?.clipEditing.timeEdit("Reset Knob") { self?.sound.resetSelectedClipsKnob(knob) }
        }
        return sound
    }

    /// What the section "Effects" of the panel on the right does, for clips and for a track, and the
    /// same menus on a clip and on a track. A kind chosen in a menu is carried out as its command, so the
    /// menu bar, the panel and the right-click menu all do the same. A level reports every move, and only
    /// the one it is let go with is an edit, which is timed like the others.
    private var effectsActions: EffectsActions {
        var effects = EffectsActions()
        effects.addChosen = { [weak self] kind in
            guard let command = AppCommand.adding(kind) else { return }
            self?.perform(command)
        }
        effects.addChosenInClipMenu = { [weak self] kind, clipID in self?.clipMenuEffectChosen(kind, on: clipID) }
        effects.levelChanged = { [weak self] effectID, level, isFinal in
            guard isFinal else { self?.clipEffects.setEffectLevel(effectID, level, isFinal: false); return }
            self?.clipEditing.timeEdit("Change Effect Level") {
                self?.clipEffects.setEffectLevel(effectID, level, isFinal: true)
            }
        }
        effects.removePressed = { [weak self] effectID in
            self?.clipEditing.timeEdit("Remove Effect") { self?.clipEffects.removeEffect(effectID) }
        }
        effects.rowPressed = { [weak self] effectID in self?.clipEffects.effectRowPressed(effectID) }
        effects.offPressed = { [weak self] effectID in
            self?.clipEditing.timeEdit("Switch Effect Off or On") { self?.clipEffects.switchEffectOffOrOn(effectID) }
        }
        effects.resetPressed = { [weak self] effectID in
            self?.clipEditing.timeEdit("Follow Track Effect") { self?.clipEffects.resetEffect(effectID) }
        }
        effects.trackAddChosen = { [weak self] kind, trackID in self?.trackEffectChosen(kind, on: trackID) }
        effects.trackLevelChanged = { [weak self] trackID, effectID, level, isFinal in
            guard isFinal else {
                self?.clipEffects.setTrackEffectLevel(effectID, of: trackID, level, isFinal: false)
                return
            }
            self?.clipEditing.timeEdit("Change Effect Level") {
                self?.clipEffects.setTrackEffectLevel(effectID, of: trackID, level, isFinal: true)
            }
        }
        effects.trackRemovePressed = { [weak self] trackID, effectID in
            self?.clipEditing.timeEdit("Remove Track Effect") {
                self?.clipEffects.removeTrackEffect(effectID, from: trackID)
            }
        }
        return effects
    }

    /// What the clips in the window do when they are used with the pointer.
    var clipActions: ClipActions {
        var clips = ClipActions()
        clips.barDragged = { [weak self] drag in self?.clipEditing.clipBarDragged(drag) }
        clips.edgeDragged = { [weak self] drag in self?.clipEditing.clipEdgeDragged(drag) }
        clips.nameDoubleClicked = { [weak self] clipID in self?.clipEditing.startRenamingClip(clipID) }
        clips.renameEnded = { [weak self] clipID, name in self?.clipEditing.endRenamingClip(clipID, as: name) }
        clips.stretchDragged = { [weak self] drag in self?.clipEditing.stretchDragged(drag) }
        clips.markerClicked = { [weak self] clipID, markerID in self?.correction.markerClicked(markerID, inClip: clipID) }
        return clips
    }

    /// What the delay readout and the buttons of the calibrate sheet do.
    var calibrationActions: CalibrationActions {
        var calibration = CalibrationActions()
        calibration.readoutPressed = { [weak self] in self?.perform(.calibrateDelay) }
        calibration.startPressed = { [weak self] in self?.calibration.startCalibration() }
        calibration.closed = { [weak self] in self?.calibration.closeCalibrateSheet() }
        return calibration
    }

    /// What the Send to DaVinci button and the panel's buttons and fields do.
    var sendActions: SendActions {
        var send = SendActions()
        send.buttonPressed = { [weak self] in self?.perform(.sendToDaVinci) }
        send.copyPressed = { [weak self] clipID in self?.send.copySendTimecode(of: clipID) }
        send.showInFinderPressed = { [weak self] in self?.send.showSendFilesInFinder() }
        send.fileToDrag = { [weak self] clipID in self?.send.sendFileOnDisk(of: clipID) }
        send.timelineStartChanged = { [weak self] text in self?.send.sendTimelineStartTyped(text) }
        send.frameRateChosen = { [weak self] rate in self?.send.sendFrameRateChosen(rate) }
        send.songStartChanged = { [weak self] text in self?.send.sendSongStartTyped(text) }
        send.timecodeHint = { [weak self] text in self?.send.sendTimecodeHint(for: text) }
        send.withSoundChanged = { [weak self] isOn in self?.send.setSendWithSound(isOn) }
        send.closed = { [weak self] in self?.send.closeSendPanel() }
        return send
    }

    /// What the list of measured delays in the settings window asks and does. Recalibrate
    /// is offered only for the pair the Mac is using, because that is the only pair a
    /// measurement can be made with.
    var measuredDelaysLink: MeasuredDelaysLink {
        MeasuredDelaysLink(
            canRecalibrate: { [weak self] devices in
                guard let self else { return false }
                return calibration.currentDevices?.key == devices.key && canPerform(.calibrateDelay)
            },
            recalibrate: { [weak self] in self?.perform(.calibrateDelay) }
        )
    }

    // MARK: The right-click menus

    /// A command was chosen in the right-click menu of a track's header. That track is
    /// selected first, and the command then acts on it like the same command in the
    /// Track menu.
    private func trackMenuCommand(_ command: TrackMenu.Command, on trackID: UUID) {
        guard takeStatus.phase == nil, store.project.track(trackID) != nil else { return }
        tracks.selectTrack(trackID)
        switch command {
        case .rename: perform(.renameTrack)
        case .duplicate: perform(.duplicateTrack)
        case .duplicateWithClips: perform(.duplicateTrackWithClips)
        case .mergeInto(let targetID): tracks.mergeSelectedTrack(into: targetID)
        case .mute: perform(.muteTrack)
        case .normalize: perform(.normalizeTrack)
        // The track was selected above and no clip is, so both act on the track.
        case .copySound: perform(.copySound)
        case .pasteSound: perform(.pasteSound)
        case .delete: perform(.deleteTrack)
        }
    }

    /// A kind was chosen for a track: with the "+" of its Effects in the panel on the right, or under
    /// Effects in its right-click menu. That track is selected first, as for the other lines of that
    /// menu, and the kind is then carried out as its command of Track > Effects.
    private func trackEffectChosen(_ kind: ClipEffect.Kind, on trackID: UUID) {
        guard takeStatus.phase == nil, store.project.track(trackID) != nil,
              let command = AppCommand.addingToTrack(kind)
        else { return }
        tracks.selectTrack(trackID)
        perform(command)
    }

    /// Mute Clip, Delete Other Takes or Delete was chosen in a clip's right-click menu. A right-click on a
    /// clip that is not selected acts on that clip, and selects it.
    private func clipMenuCommand(_ command: ClipMenu.Command, on clipID: UUID) {
        guard takeStatus.phase == nil else { return }
        if !selection.clipIDs.contains(clipID) {
            selection.clipIDs = [clipID]
            clips.showClips(of: store.project)
        }
        switch command {
        case .rename: perform(.renameClip)
        case .splitAtPlayhead: perform(.splitAtPlayhead)
        case .joinClips: perform(.joinClips)
        case .muteClip: perform(.muteClip)
        case .normalize: perform(.normalize)
        case .feel(let feel): perform(.choosing(ClipFeel(feel)))
        case .aim(let trackID): aimSelectedClips(at: trackID)
        // A sound is copied from one clip: the one that was right-clicked, also when it is one of
        // several selected clips. It is pasted on all of them.
        case .copySound: soundCopy.copySound(ofClip: clipID)
        case .pasteSound: perform(.pasteSound)
        case .deleteOtherTakes: perform(.deleteOtherTakes)
        case .sendToDaVinci: send.sendClip(clipID)
        case .delete: perform(.delete)
        }
    }

    /// A kind was chosen under Effects in a clip's right-click menu. With words marked in that clip the
    /// effect goes on them, so the stretch is left alone. Otherwise a right-click on a clip that is not
    /// selected acts on that clip, and selects it, as the other commands of the menu do.
    private func clipMenuEffectChosen(_ kind: ClipEffect.Kind, on clipID: UUID) {
        guard takeStatus.phase == nil, let command = AppCommand.adding(kind) else { return }
        if !clipEffects.markedStretchCrosses(clipID), !selection.clipIDs.contains(clipID) {
            selection.clipIDs = [clipID]
            clips.showClips(of: store.project)
        }
        perform(command)
    }

    /// Whether Split at Playhead or Join Clips can act for the clip that was
    /// right-clicked, by the rules of the same commands in the Edit menu. A right-click on
    /// a clip that is not selected acts on that clip alone.
    func clipMenuCommandIsEnabled(_ command: ClipMenu.Command, on clipID: UUID) -> Bool {
        guard takeStatus.phase == nil, calibration.calibrationSheet == nil else { return false }
        let ids: Set<UUID> = selection.clipIDs.contains(clipID) ? selection.clipIDs : [clipID]
        switch command {
        case .splitAtPlayhead:
            // The playhead as it was last looked at, which nothing watches. See `ClipWork.playheadSeconds`.
            let seconds = clipEditing.clipWork.playheadSeconds
            return ids.contains { store.project.canSplit(clip: $0, at: seconds) }
        case .joinClips:
            return store.project.canJoin(ids)
        case .rename, .muteClip, .normalize, .feel, .aim, .copySound, .pasteSound, .deleteOtherTakes, .sendToDaVinci,
             .delete:
            return true
        }
    }

    /// A line was chosen in the row "Aim at" of the panel on the right, in Clip > Correction > Aim at, or
    /// in the Aim at submenu of a clip's right-click menu: the selected clips aim at that track, or at the
    /// beat for nil. By the rules of the commands of Clip > Correction, and timed like every other edit.
    func aimSelectedClips(at trackID: UUID?) {
        guard canPerform(.aimAtBeat) else { return }
        clipEditing.timeEdit("Change Aim") { correction.setSelectedClipsAim(trackID) }
    }
}

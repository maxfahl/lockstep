import Foundation

// A found sound, taken along: a preset that gives a track its effects with its Sound, and Copy Sound and Paste
// Sound.
//
//     store.edit("Choose Sound") { $0.setTrack(trackID, preset: preset) }      // the Sound, and its effects
//
//     let copied = project.copiedSound(ofClip: clipID)                         // what one clip is heard with
//     let copied = project.copiedSound(ofTrack: trackID)                       // a track's Sound and effects
//     store.edit("Paste Sound") { $0.pasteSound(copied, onClips: selection) }
//     store.edit("Paste Sound") { $0.pasteSound(copied, onTrack: trackID) }
//     project.hasAnotherSound(than: copied, onTracksOf: selection)             // the paste cannot change that
//
// Each edit says whether it changed anything, so the app leaves out an undo step for a change of nothing. A
// copied sound holds values and no ids, so it can be pasted in another project.
//
// The rules:
// - A track's effects that are replaced, by a preset that has effects or by a sound pasted on the track, are
//   new effects with ids of their own, and what the track's clips changed of the old ones is taken away.
//   Effects that are replaced by the same kinds at the same levels are left as they are, so choosing a preset
//   twice, or pasting twice, changes nothing the second time.
// - A sound pasted on clips never changes their track: its Sound and its effects stay, and each clip is
//   brought to the copied sound with what a clip has of its own (its knobs, its changes of the track's
//   effects, its own effects on the whole clip).
// - A sound pasted on a track makes every clip of it follow the track.
// - Effects on a stretch are no part of a sound: they are never copied and a paste leaves them where they are.
// - The takes that wait behind a clip get what the clip gets, as with its knobs and its effects.

/// What Copy Sound keeps: how one clip, or one track, sounds.
public struct CopiedSound: Sendable, Equatable {
    /// One copied effect: its kind and its level.
    public typealias Effect = SoundPreset.Effect

    /// The Sound, with the four knobs as the clip is heard. Nil: no Sound.
    public var sound: TrackSound?
    /// Each effect on the whole clip that is heard, in the order they are applied.
    public var effects: [Effect]

    public init(sound: TrackSound?, effects: [Effect]) {
        self.sound = sound
        self.effects = effects
    }
}

extension Project {
    // MARK: A preset

    /// Gives a track a preset: its Sound, as `setTrack(_:sound:)` does, and when the preset has effects,
    /// copies of them in place of the track's own. A preset without effects, which every built-in one is,
    /// leaves the track's effects as they are.
    ///
    /// - Returns: false when the track has exactly that already, or the project has no such track.
    @discardableResult
    public mutating func setTrack(_ id: Track.ID, preset: SoundPreset) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return false }
        var changed = setTrack(id, sound: preset.sound)
        if !preset.effects.isEmpty, replaceEffects(ofTrackAt: index, with: preset.effects) { changed = true }
        return changed
    }

    /// Puts these effects in place of a track's own, each a new effect with an id of its own, and takes away
    /// what the track's clips, the takes that wait included, changed of the ones that went.
    ///
    /// - Returns: false, with nothing changed, when the track has those kinds at those levels already.
    private mutating func replaceEffects(ofTrackAt index: Int, with effects: [SoundPreset.Effect]) -> Bool {
        guard tracks[index].effects.map(SoundPreset.Effect.init) != effects else { return false }
        let gone = Set(tracks[index].effects.map(\.id))
        tracks[index].effects = effects.map { ClipEffect(kind: $0.kind, levelDb: $0.levelDb) }
        for clip in tracks[index].clips.indices where !tracks[index].clips[clip].effectChanges.isEmpty {
            tracks[index].clips[clip].effectChanges.removeAll { gone.contains($0.effectID) }
        }
        return true
    }

    // MARK: Copy Sound

    /// What a clip is heard with: its track's Sound with the clip's own knobs over the track's, and every
    /// effect on the whole clip of `effects(heardOn:)` with its level. Effects on a stretch are not part of
    /// a sound. Nil when the project has no such clip.
    public func copiedSound(ofClip id: Clip.ID) -> CopiedSound? {
        for track in tracks {
            guard let clip = track.clips.first(where: { $0.id == id }) else { continue }
            let sound = track.sound.map {
                TrackSound(name: $0.name, character: $0.character, knobs: clip.knobs.over($0.knobs))
            }
            let heard = track.effects(heardOn: clip).filter { $0.span == nil }
            return CopiedSound(sound: sound, effects: heard.map(SoundPreset.Effect.init))
        }
        return nil
    }

    /// What a track gives its clips: its Sound and its effects. Nil when the project has no such track.
    public func copiedSound(ofTrack id: Track.ID) -> CopiedSound? {
        track(id).map { CopiedSound(sound: $0.sound, effects: $0.effects.map(SoundPreset.Effect.init)) }
    }

    // MARK: Paste Sound

    /// Makes the clips with these ids heard with a copied sound, as far as a clip can be: its track keeps its
    /// Sound and its effects.
    ///
    /// The knobs: each becomes the clip's own value where it differs from its track's, and follows the track
    /// where it is the same. On a track without a Sound all four are the clip's own, and count when the track
    /// gets one. A copied sound without a Sound leaves the knobs alone.
    ///
    /// The effects: each effect of the clip's track goes with a copied effect of the same kind, the first of
    /// a kind with the first, and gets the copied level as the clip's own (no change where that is the
    /// track's level). A track's effect without a partner is switched off for the clip. The clip's own
    /// effects on the whole clip go with the copied ones that are left in the same way: one with a partner
    /// gets its level, one without is removed, and a copied effect that is still left is added as the clip's
    /// own. So afterwards the clip is heard, on the whole of it, with exactly the copied kinds and levels.
    /// Its effects on a stretch stay.
    ///
    /// The takes that wait behind each clip get the same, and an added effect has one id on all of them.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func pasteSound(_ copied: CopiedSound, onClips ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return false }
        // The lines: each clip with the takes that wait behind it, and the ids its added effects get.
        var freshIDs: [UUID: [UUID]] = [:]
        for id in ids where freshIDs[id] == nil && clip(id) != nil {
            let fresh = copied.effects.map { _ in UUID() }
            freshIDs[id] = fresh
            for take in takes(of: id) {
                freshIDs[take.id] = fresh
            }
        }
        var changed = false
        for track in tracks.indices {
            let sound = tracks[track].sound
            let effects = tracks[track].effects
            for index in tracks[track].clips.indices {
                guard let fresh = freshIDs[tracks[track].clips[index].id] else { continue }
                let before = tracks[track].clips[index]
                var clip = before
                clip.paste(copied, trackSound: sound, trackEffects: effects, freshIDs: fresh)
                if clip != before {
                    tracks[track].clips[index] = clip
                    changed = true
                }
            }
        }
        return changed
    }

    /// Gives a track a copied sound: that Sound, or none, and those effects in place of its own. Every clip of
    /// the track then follows the track: the knobs it turned for itself, what it changed of the track's
    /// effects and its own effects on the whole clip are taken away, from the takes that wait too. Effects
    /// on a stretch stay. Without that, the clip the sound was copied from would be heard with its own double
    /// and the track's on top.
    ///
    /// - Returns: false when nothing changed, or the project has no such track.
    @discardableResult
    public mutating func pasteSound(_ copied: CopiedSound, onTrack id: Track.ID) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return false }
        var changed = setTrack(id, sound: copied.sound)
        if replaceEffects(ofTrackAt: index, with: copied.effects) { changed = true }
        for clip in tracks[index].clips.indices {
            let before = tracks[index].clips[clip]
            guard !before.knobs.isEmpty || !before.effectChanges.isEmpty || before.effects.contains(where: { $0.span == nil })
            else { continue }
            tracks[index].clips[clip].knobs = ClipKnobs()
            tracks[index].clips[clip].effectChanges = []
            tracks[index].clips[clip].effects.removeAll { $0.span == nil }
            changed = true
        }
        return changed
    }

    /// Whether any of the clips with these ids is on a track whose Sound a paste on the clips cannot make the
    /// copied one: the track has no Sound and the copied sound has one, the other way round, or the two are
    /// of different characters. The clips then get the knobs and the effects all the same, and the app says
    /// that the track's Sound is still its own.
    public func hasAnotherSound(than copied: CopiedSound, onTracksOf ids: Set<UUID>) -> Bool {
        tracks.contains { track in
            track.sound?.character != copied.sound?.character && track.clips.contains { ids.contains($0.id) }
        }
    }
}

extension Clip {
    /// Brings this clip to a copied sound, by the rules of `Project.pasteSound(_:onClips:)`.
    ///
    /// - Parameters:
    ///   - trackSound: the Sound of the clip's track, or nil when it has none.
    ///   - trackEffects: the effects of the clip's track.
    ///   - freshIDs: the id an added effect gets, for each copied effect.
    fileprivate mutating func paste(
        _ copied: CopiedSound,
        trackSound: TrackSound?,
        trackEffects: [ClipEffect],
        freshIDs: [UUID]
    ) {
        if let wanted = copied.sound?.knobs.inWholePercent {
            for knob in SoundKnob.allCases {
                knobs[knob] = trackSound?.knobs[knob] == wanted[knob] ? nil : wanted[knob]
            }
        }

        // The copied effects that have no partner yet, by kind, the first of a kind first.
        var left: [ClipEffect.Kind: [Int]] = [:]
        for (place, effect) in copied.effects.enumerated() {
            left[effect.kind, default: []].append(place)
        }
        func partner(of kind: ClipEffect.Kind) -> SoundPreset.Effect? {
            guard let place = left[kind]?.first else { return nil }
            left[kind]?.removeFirst()
            return copied.effects[place]
        }

        for effect in trackEffects {
            let place = effectChanges.firstIndex { $0.effectID == effect.id }
            var change = place.map { effectChanges[$0] } ?? ClipEffectChange(effectID: effect.id)
            if let partner = partner(of: effect.kind) {
                change.isOff = false
                change.levelDb = effect.kind.isLayer && partner.levelDb != effect.levelDb ? partner.levelDb : nil
            } else {
                change.isOff = true
            }
            // A change that is there keeps its place, so a clip that has the sound already stays as it is.
            switch (place, change.changesNothing) {
            case let (place?, true): effectChanges.remove(at: place)
            case let (place?, false): effectChanges[place] = change
            case (nil, false): effectChanges.append(change)
            case (nil, true): break
            }
        }

        var own: [ClipEffect] = []
        for var effect in effects {
            guard effect.span == nil else {
                own.append(effect)
                continue
            }
            guard let partner = partner(of: effect.kind) else { continue }
            effect.levelDb = partner.levelDb
            own.append(effect)
        }
        for place in left.values.flatMap({ $0 }).sorted() {
            let effect = copied.effects[place]
            own.append(ClipEffect(id: freshIDs[place], kind: effect.kind, levelDb: effect.levelDb))
        }
        effects = own
    }
}

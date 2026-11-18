import Foundation

// A track's effects, what a clip changed of them for itself, and the effects several clips share.
//
// A track holds effects that every clip of it is heard with, as it holds a Sound. A clip follows its track
// with each of them, unless it has its own level for one or switched it off:
//
//     store.edit("Add Track Effect") { $0.addTrackEffect(trackID, kind: .thick) }
//     store.edit("Change Effect Level") { $0.setTrackEffect(effectID, of: trackID, levelDb: -6) }
//     store.edit("Remove Track Effect") { $0.removeTrackEffect(effectID, from: trackID) }
//     store.edit("Change Effect Level") { $0.setClips(selection, trackEffect: effectID, levelDb: -3) }
//     store.edit("Switch Effect Off") { $0.setClips(selection, trackEffect: effectID, isOff: true) }
//     store.edit("Follow Track Effect") { $0.resetClips(selection, trackEffect: effectID) }
//
//     project.effects(heardOn: clip)        // the one list a clip's sound is made from: its track's, then its own
//     project.sharedEffects(of: selection)  // the rows of the panel's Effects section for the selected clips
//
// Each edit says whether it changed anything, so the app leaves out an undo step for a change of nothing.
// The rules, which follow the ones a clip's knobs have (`ProjectSounds.swift`):
// - A track's effect is on the whole of every clip: it never has a span. Its id is its own within the track,
//   and a clip's own effect (`Clip.effects`, `ProjectEffects.swift`) never has the id of a track's effect.
// - A clip's change reaches the takes that wait behind it, and a new take starts with the changes of the take
//   that was heard until then (`addRecording`).
// - A split keeps the changes on both pieces, a joined clip keeps the first clip's, and a copy keeps them: the
//   pieces and the copies are made from the clip as it is.
// - A change that names an effect the clip's track does not have counts for nothing and is kept, as a clip's
//   knobs are kept on a track without a Sound. So a clip that is moved to another track follows that track's
//   effects, and has its changes back when it is moved home. Only `removeTrackEffect` takes changes away.
// - Duplicate Track keeps the track's effects with their ids, so the copied clips' changes still hold: two
//   tracks can hold an effect with the same id, which is why a change is only ever taken from the clips of
//   the track that was named. After Merge Into, the clips that came follow the effects of the track they
//   came to (`ProjectTracks.swift`).

/// One effect that every one of some clips has on the whole clip: one row of the panel's Effects section while
/// those clips are selected. Asked about one clip, it is one of that clip's whole-clip effects.
public struct SharedEffect: Sendable, Equatable, Identifiable {
    /// The effect of one clip that a shared effect stands for.
    public struct Member: Sendable, Equatable {
        public var clipID: Clip.ID
        /// The id of the clip's own effect, or of its track's.
        public var effectID: ClipEffect.ID
        /// Whether it is an effect of the clip's track. Otherwise it is the clip's own.
        public var isOfTrack: Bool

        public init(clipID: Clip.ID, effectID: ClipEffect.ID, isOfTrack: Bool) {
            self.clipID = clipID
            self.effectID = effectID
            self.isOfTrack = isOfTrack
        }
    }

    /// The id of the effect it stands for on the first of the clips. It is the row's id: no two shared
    /// effects of one answer have the same, and it stays while the clips and their effects stay.
    public var id: ClipEffect.ID
    public var kind: ClipEffect.Kind
    /// The effect of each clip it stands for, in the order the project holds the clips: track by track from
    /// the top, and each track's clips in the order of its list.
    public var members: [Member]
    /// The level: the mean of what the clips have. 0 for a kind without a level.
    public var levelDb: Double
    /// Whether the clips' levels differ, which the row shows as "Mixed".
    public var isMixed: Bool
    /// Whether it is an effect of its track on every clip.
    public var isOfTrack: Bool
    /// Whether it is an effect of its track that is switched off on every clip.
    public var isOff: Bool
    /// Whether any clip changed anything of it for itself: its own level for an effect of its track, or off.
    public var isChanged: Bool

    public init(
        id: ClipEffect.ID,
        kind: ClipEffect.Kind,
        members: [Member],
        levelDb: Double,
        isMixed: Bool = false,
        isOfTrack: Bool = false,
        isOff: Bool = false,
        isChanged: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.members = members
        self.levelDb = levelDb
        self.isMixed = isMixed
        self.isOfTrack = isOfTrack
        self.isOff = isOff
        self.isChanged = isChanged
    }
}

extension ClipEffect {
    /// The effect without a span: as it is on a track, where every effect is on the whole of every clip.
    var onWholeClip: ClipEffect {
        guard span != nil else { return self }
        var whole = self
        whole.span = nil
        return whole
    }
}

extension Clip {
    /// What the clip changed for itself of one effect of its track, or nil when it follows its track with it.
    public func change(ofTrackEffect effectID: ClipEffect.ID) -> ClipEffectChange? {
        effectChanges.first { $0.effectID == effectID && !$0.changesNothing }
    }

    /// Changes what the clip says about one effect of its track, starting from a change of nothing when it
    /// said nothing. What then changes nothing is not kept.
    ///
    /// - Returns: whether the clip says something else than before.
    fileprivate mutating func changeTrackEffect(
        _ effectID: ClipEffect.ID,
        _ change: (inout ClipEffectChange) -> Void
    ) -> Bool {
        let place = effectChanges.firstIndex { $0.effectID == effectID }
        let before = place.map { effectChanges[$0] } ?? ClipEffectChange(effectID: effectID)
        var after = before
        change(&after)
        guard after != before else { return false }
        switch (place, after.changesNothing) {
        case let (place?, true): effectChanges.remove(at: place)
        case let (place?, false): effectChanges[place] = after
        case (nil, false): effectChanges.append(after)
        case (nil, true): return false
        }
        return true
    }
}

extension Track {
    /// The effects a clip of this track is heard with: `Project.effects(heardOn:)` for whoever has the track
    /// in hand. The clip is read as it is handed in and is not looked for.
    public func effects(heardOn clip: Clip) -> [ClipEffect] {
        guard !effects.isEmpty else { return clip.effects }
        var heard: [ClipEffect] = []
        heard.reserveCapacity(effects.count + clip.effects.count)
        for effect in effects {
            let change = clip.effectChanges.isEmpty ? nil : clip.change(ofTrackEffect: effect.id)
            if change?.isOff == true { continue }
            var effect = effect.onWholeClip
            if effect.kind.isLayer, let level = change?.levelDb {
                effect.levelDb = level
            }
            heard.append(effect)
        }
        return heard + clip.effects
    }
}

extension Project {
    // MARK: What a clip is heard with

    /// The one list a clip's sound is made from: its track's effects in the track's order, each left out when
    /// the clip switched it off and with the clip's own level when it set one, and then the clip's own effects
    /// (`Clip.effects`). A track's effect keeps its id.
    ///
    /// The clip is found by its id and read as it is handed in, as `chainParameters(of:)` does, so a level
    /// that is being dragged can be asked about before it is in the project. A clip the project does not have
    /// is heard with its own effects alone.
    public func effects(heardOn clip: Clip) -> [ClipEffect] {
        // Most projects have no effect on any track: then no clip is looked for.
        guard tracks.contains(where: { !$0.effects.isEmpty }),
              let track = tracks.first(where: { track in track.clips.contains { $0.id == clip.id } })
        else { return clip.effects }
        return track.effects(heardOn: clip)
    }

    // MARK: A track's effects

    /// Gives a track an effect, at the end of its list and at the level its kind starts at. Every clip of the
    /// track is heard with it from then on, also one that is recorded or moved there later.
    ///
    /// Any kind may be a track's effect. Which ones a track's menu offers is `ClipEffect.Kind.forTracks`.
    ///
    /// - Returns: the id of the new effect. Nil, with nothing changed, when the project has no such track.
    @discardableResult
    public mutating func addTrackEffect(_ trackID: Track.ID, kind: ClipEffect.Kind) -> ClipEffect.ID? {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return nil }
        let effect = ClipEffect(kind: kind, levelDb: kind.startLevelDb)
        tracks[index].effects.append(effect)
        return effect.id
    }

    /// Takes an effect off a track, and takes away what the track's clips changed of it for themselves, the
    /// takes that wait included.
    ///
    /// - Returns: false, with nothing changed, when the track has no such effect.
    @discardableResult
    public mutating func removeTrackEffect(_ effectID: ClipEffect.ID, from trackID: Track.ID) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }),
              let place = tracks[index].effects.firstIndex(where: { $0.id == effectID })
        else { return false }
        tracks[index].effects.remove(at: place)
        for clip in tracks[index].clips.indices where !tracks[index].clips[clip].effectChanges.isEmpty {
            tracks[index].clips[clip].effectChanges.removeAll { $0.effectID == effectID }
        }
        return true
    }

    /// Sets how loud the layer of a track's effect is, held to -24...+6 dB. A clip with its own level for the
    /// effect keeps that.
    ///
    /// - Returns: false, with nothing changed, when the track has no such effect, the effect is at that level
    ///   already, or its kind replaces the voice and has no level.
    @discardableResult
    public mutating func setTrackEffect(_ effectID: ClipEffect.ID, of trackID: Track.ID, levelDb: Double) -> Bool {
        let level = ClipEffect.level(clamped: levelDb)
        guard let index = tracks.firstIndex(where: { $0.id == trackID }),
              let place = tracks[index].effects.firstIndex(where: { $0.id == effectID }),
              tracks[index].effects[place].kind.isLayer, tracks[index].effects[place].levelDb != level
        else { return false }
        tracks[index].effects[place].levelDb = level
        return true
    }

    // MARK: A clip's changes

    /// Gives the clips with these ids their own level for an effect of their track, held to -24...+6 dB. Like
    /// a clip's knob, the value is the clip's own also when it equals the track's: the clip no longer follows
    /// the track with that effect's level. Whether the clip switched the effect off stays as it is.
    ///
    /// The takes that wait behind a chosen clip get the same. A clip whose track does not have the effect is
    /// left alone.
    ///
    /// - Returns: whether any clip was changed. False for a kind that replaces the voice and has no level.
    @discardableResult
    public mutating func setClips(_ ids: Set<UUID>, trackEffect effectID: ClipEffect.ID, levelDb: Double) -> Bool {
        let level = ClipEffect.level(clamped: levelDb)
        let holders = clips(ids, onTracksWith: effectID) { $0.kind.isLayer }
        guard !holders.isEmpty else { return false }
        return changeTakes(of: holders) { clip in
            clip.changeTrackEffect(effectID) { $0.levelDb = level }
        }
    }

    /// Switches an effect of their track off for the clips with these ids, or on again: the other clips of the
    /// track are heard with it as before. A clip's own level for the effect is kept while it is off.
    ///
    /// The takes that wait behind a chosen clip get the same. A clip whose track does not have the effect is
    /// left alone.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func setClips(_ ids: Set<UUID>, trackEffect effectID: ClipEffect.ID, isOff: Bool) -> Bool {
        let holders = clips(ids, onTracksWith: effectID)
        guard !holders.isEmpty else { return false }
        return changeTakes(of: holders) { clip in
            clip.changeTrackEffect(effectID) { $0.isOff = isOff }
        }
    }

    /// Takes away what the clips with these ids changed of an effect of their track: they follow the track
    /// with it again, on and at the track's level. The takes that wait behind a chosen clip are put back too.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func resetClips(_ ids: Set<UUID>, trackEffect effectID: ClipEffect.ID) -> Bool {
        let holders = clips(ids, onTracksWith: effectID)
        guard !holders.isEmpty else { return false }
        return changeTakes(of: holders) { clip in
            clip.changeTrackEffect(effectID) { $0 = ClipEffectChange(effectID: effectID) }
        }
    }

    /// Those of the clips with these ids whose track has the effect with this id, and has it as `allowed`
    /// says.
    private func clips(
        _ ids: Set<UUID>,
        onTracksWith effectID: ClipEffect.ID,
        where allowed: (ClipEffect) -> Bool = { _ in true }
    ) -> Set<UUID> {
        var holders: Set<UUID> = []
        for track in tracks {
            guard let effect = track.effects.first(where: { $0.id == effectID }), allowed(effect) else { continue }
            for clip in track.clips where ids.contains(clip.id) {
                holders.insert(clip.id)
            }
        }
        return holders
    }

    // MARK: Several clips: the effects they share

    /// The effects the clips with these ids share, one for each row of the panel's Effects section.
    ///
    /// Each clip has a list of effects on the whole clip: its track's in the track's order, also the ones it
    /// switched off, and then its own that have no span. The clips share an effect when each of them has one
    /// of the same kind, whether it is the clip's own or its track's: the first of a kind in one clip goes
    /// with the first of that kind in the others, the second with the second. A kind that not every clip has
    /// is not listed, and an effect on a stretch never is: it belongs to one take's words.
    ///
    /// The answer is in the order of the first clip's list, the first clip being the first one the project
    /// holds (`SharedEffect.members`). Asked about one clip it is that clip's whole list, so the rows of one
    /// clip and of several are made the same way. Empty when none of the ids is a clip.
    public func sharedEffects(of ids: Set<UUID>) -> [SharedEffect] {
        guard !ids.isEmpty else { return [] }
        var lists: [[WholeClipEffect]] = []
        for track in tracks {
            for clip in track.clips where ids.contains(clip.id) {
                lists.append(Project.wholeClipEffects(of: clip, on: track))
            }
        }
        guard let first = lists.first else { return [] }

        // For each clip, its effects of each kind in the order of its list.
        let byKind = lists.map { list in Dictionary(grouping: list, by: \.kind) }
        var met: [ClipEffect.Kind: Int] = [:]
        var shared: [SharedEffect] = []
        for effect in first {
            let ordinal = met[effect.kind, default: 0]
            met[effect.kind] = ordinal + 1
            let partners = byKind.compactMap { kinds -> WholeClipEffect? in
                guard let ofKind = kinds[effect.kind], ofKind.count > ordinal else { return nil }
                return ofKind[ordinal]
            }
            guard partners.count == lists.count else { continue }
            let levels = partners.map(\.levelDb)
            shared.append(SharedEffect(
                id: effect.member.effectID,
                kind: effect.kind,
                members: partners.map(\.member),
                levelDb: effect.kind.isLayer ? levels.reduce(0, +) / Double(levels.count) : 0,
                isMixed: effect.kind.isLayer && levels.contains { $0 != levels[0] },
                isOfTrack: partners.allSatisfy(\.member.isOfTrack),
                isOff: partners.allSatisfy(\.isOff),
                isChanged: partners.contains(where: \.isChanged)
            ))
        }
        return shared
    }

    /// One effect on the whole of a clip as `sharedEffects(of:)` goes through them.
    private struct WholeClipEffect {
        var member: SharedEffect.Member
        var kind: ClipEffect.Kind
        /// The level the clip has it at: its own for an effect of its track when it set one.
        var levelDb: Double
        var isOff = false
        var isChanged = false
    }

    /// A clip's effects on the whole clip: its track's, also the ones it switched off, and then its own.
    private static func wholeClipEffects(of clip: Clip, on track: Track) -> [WholeClipEffect] {
        let ofTrack = track.effects.map { effect in
            let change = clip.change(ofTrackEffect: effect.id)
            return WholeClipEffect(
                member: SharedEffect.Member(clipID: clip.id, effectID: effect.id, isOfTrack: true),
                kind: effect.kind,
                levelDb: effect.kind.isLayer ? change?.levelDb ?? effect.levelDb : effect.levelDb,
                isOff: change?.isOff ?? false,
                isChanged: change != nil
            )
        }
        let own = clip.effects.filter { $0.span == nil }.map { effect in
            WholeClipEffect(
                member: SharedEffect.Member(clipID: clip.id, effectID: effect.id, isOfTrack: false),
                kind: effect.kind,
                levelDb: effect.levelDb
            )
        }
        return ofTrack + own
    }

    /// Sets the level of a shared effect on every clip it stands for: the level of a clip's own effect, and
    /// the clip's own level for an effect of its track. The takes that wait behind each clip get the same.
    ///
    /// - Returns: whether any clip was changed. False for a kind that replaces the voice and has no level.
    @discardableResult
    public mutating func setEffects(_ shared: SharedEffect, levelDb: Double) -> Bool {
        guard shared.kind.isLayer else { return false }
        var changed = false
        for (effectID, clips) in Project.clipsByTrackEffect(of: shared) {
            if setClips(clips, trackEffect: effectID, levelDb: levelDb) { changed = true }
        }
        for member in shared.members where !member.isOfTrack {
            if setEffect(member.effectID, of: member.clipID, levelDb: levelDb) { changed = true }
        }
        return changed
    }

    /// Removes a shared effect from every clip it stands for: a clip's own effect is removed, and an effect of
    /// its track is switched off for that clip. The takes that wait behind each clip get the same.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func removeEffects(_ shared: SharedEffect) -> Bool {
        var changed = setEffects(shared, isOff: true)
        for member in shared.members where !member.isOfTrack {
            if removeEffect(member.effectID, from: member.clipID) { changed = true }
        }
        return changed
    }

    /// Switches a shared effect off, or on again, on every clip that has it from its track. A clip's own
    /// effect cannot be switched off and is left as it is.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func setEffects(_ shared: SharedEffect, isOff: Bool) -> Bool {
        var changed = false
        for (effectID, clips) in Project.clipsByTrackEffect(of: shared) {
            if setClips(clips, trackEffect: effectID, isOff: isOff) { changed = true }
        }
        return changed
    }

    /// Makes every clip that has a shared effect from its track follow the track with it again: on, and at
    /// the track's level. A clip's own effect is left as it is.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func resetEffects(_ shared: SharedEffect) -> Bool {
        var changed = false
        for (effectID, clips) in Project.clipsByTrackEffect(of: shared) {
            if resetClips(clips, trackEffect: effectID) { changed = true }
        }
        return changed
    }

    /// The clips a shared effect stands for an effect of their track on, by that effect: clips of two tracks
    /// have two effects.
    private static func clipsByTrackEffect(of shared: SharedEffect) -> [(effectID: ClipEffect.ID, clips: Set<UUID>)] {
        var order: [ClipEffect.ID] = []
        var clips: [ClipEffect.ID: Set<UUID>] = [:]
        for member in shared.members where member.isOfTrack {
            if clips[member.effectID] == nil { order.append(member.effectID) }
            clips[member.effectID, default: []].insert(member.clipID)
        }
        return order.map { ($0, clips[$0] ?? []) }
    }
}

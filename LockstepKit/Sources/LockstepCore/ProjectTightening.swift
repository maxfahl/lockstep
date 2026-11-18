import Foundation

// Setting the correction of clips: the buttons Off, Lines and All, the slider "Strength" and the switch
// "Stretch" under "Correction" in the panel on the right.
//
// All of it is kept for each clip (`Clip.tighten`, `Clip.strength`, `Clip.stretch`), and the panel sets it
// for every selected clip at once:
//
//     store.edit("Change Correction") { $0.setClips(selection, tighten: .lines) }
//     store.edit("Change Strength") { $0.setClips(selection, strength: 0.6) }
//     store.edit("Turn Stretch On") { $0.setClips(selection, stretch: true) }
//     store.edit("Turn Correction Off") { $0.setClips(selection, corrected: false) }   // the T key
//
// The clip's sub-beats are set the same way by `setClips(_:feel:)` in `ProjectFeel.swift`.
//
// What a clip's correction aims at is set here too: the row "Aim at", the beat or another track.
//
//     store.edit("Change Aim") { $0.setClips(selection, aimTrack: lead.id) }     // nil is the beat
//     project.aim(of: clip, reach: settings.partnerReach)     // the track it is held against now, or nil
//     project.aimedClips(of: clip, reach: settings.partnerReach)     // the lead's clips to take syllables from

extension Project {
    /// Chooses Off, Lines or All for the clips with these ids.
    ///
    /// The takes that wait behind a chosen clip get the same, so stepping to another take of the line does
    /// not quietly change how the line is corrected.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func setClips(_ ids: Set<UUID>, tighten: ClipTighten) -> Bool {
        changeTakes(of: ids) { clip in
            guard clip.tighten != tighten else { return false }
            clip.tighten = tighten
            return true
        }
    }

    /// Switches the correction of the clips with these ids on or off without choosing anew: off is Off, and
    /// on gives each clip the choice it had last, Lines or All (`Clip.tightenWhenOn`). The takes that wait
    /// behind a chosen clip are switched too, each to its own last choice.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func setClips(_ ids: Set<UUID>, corrected: Bool) -> Bool {
        changeTakes(of: ids) { clip in
            let tighten = corrected ? clip.tightenWhenOn : .off
            guard clip.tighten != tighten else { return false }
            clip.tighten = tighten
            return true
        }
    }

    /// Lets the voice of the clips with these ids be stretched and squeezed, or not. The takes that wait
    /// behind a chosen clip get the same.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func setClips(_ ids: Set<UUID>, stretch: Bool) -> Bool {
        changeTakes(of: ids) { clip in
            guard clip.stretch != stretch else { return false }
            clip.stretch = stretch
            return true
        }
    }

    /// Sets how much of the correction is applied to the clips with these ids: how much of the way their
    /// lines slide and, with All, their syllables move.
    ///
    /// The strength is held between 0 and 1 and kept in whole percent, which is what the slider shows. The
    /// takes that wait behind a chosen clip get the same, as with `setClips(_:tighten:)`.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func setClips(_ ids: Set<UUID>, strength: Double) -> Bool {
        let strength = (min(max(strength, 0), 1) * 100).rounded() / 100
        return changeTakes(of: ids) { clip in
            guard clip.strength != strength else { return false }
            clip.strength = strength
            return true
        }
    }

    /// Aims the correction of the clips with these ids at a track, or at the beat with nil. The takes that
    /// wait behind a chosen clip get the same.
    ///
    /// Any id is kept as it is given. Whether the aim can be followed is asked when the clip is corrected
    /// (`aim(of:)`), so an aim at a track that is deleted comes back with the track on undo.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func setClips(_ ids: Set<UUID>, aimTrack: UUID?) -> Bool {
        changeTakes(of: ids) { clip in
            guard clip.aimTrack != aimTrack else { return false }
            clip.aimTrack = aimTrack
            return true
        }
    }

    /// The track a clip's correction is held against right now, or nil when it is the beat.
    ///
    /// It is the clip's `aimTrack`, except where that cannot be followed, which counts as the beat:
    /// - The track is gone.
    /// - It is the clip's own track.
    /// - The aims come back: a clip of the aimed track that lies over this one aims at this clip's track,
    ///   straight back or by way of further tracks. Each would wait for where the other is heard, and
    ///   neither would ever be settled. All the clips of such a ring count as aiming at the beat.
    ///
    /// - Parameters:
    ///   - clip: the clip. It is looked up on its track by its id, so a copy with other settings is fine.
    ///   - reach: how far past its own edges a clip is held against the other track, in seconds
    ///     (`TightenSettings.partnerReach`). Two clips this close count as lying over each other.
    public func aim(of clip: Clip, reach: Double = 0) -> UUID? {
        guard let aimed = clip.aimTrack, track(aimed) != nil,
              let own = tracks.first(where: { track in track.clips.contains { $0.id == clip.id } }),
              own.id != aimed
        else { return nil }
        // Follows the aims from clip to clip. Every clip is looked at once, so this ends.
        var seen: Set<UUID> = [clip.id]
        var waiting = [clip]
        while let next = waiting.popLast() {
            for lead in aimedClips(of: next, reach: reach) where seen.insert(lead.id).inserted {
                if lead.aimTrack == own.id { return nil }
                waiting.append(lead)
            }
        }
        return aimed
    }

    /// The clips a clip is held against when it aims at a track: the shown clips of that track that lie over
    /// it, in the order the track holds them. None for a clip that aims at the beat, at its own track, or at
    /// a track that is gone.
    ///
    /// Takes that wait are not among them: they are neither heard nor drawn, so nothing is held against them.
    ///
    /// - Parameter reach: how far past the clip's own edges to look, in seconds.
    public func aimedClips(of clip: Clip, reach: Double = 0) -> [Clip] {
        guard let aimed = clip.aimTrack, let start = start(of: clip), let end = end(of: clip),
              let own = tracks.first(where: { track in track.clips.contains { $0.id == clip.id } }),
              own.id != aimed
        else { return [] }
        let reach = reach.isFinite ? max(reach, 0) : 0
        return clips(on: aimed, overlapping: start - reach..<max(end, start) + reach).filter(\.isActiveTake)
    }

    /// Changes the clips with these ids and every other take of their lines. `change` says whether it
    /// changed the clip it was handed. A clip's own knobs are set through it too (`ProjectSounds.swift`).
    mutating func changeTakes(of ids: Set<UUID>, _ change: (inout Clip) -> Bool) -> Bool {
        // With more than a few clips, their takes are asked of a lookup table: one pass through the
        // project, where asking the project for each clip goes through its recordings every time.
        let takeIDs: [UUID]
        if ids.count > 4 {
            let lookup = ProjectLookup(self)
            takeIDs = ids.flatMap { lookup.takes(of: $0).map(\.id) }
        } else {
            takeIDs = ids.flatMap { takes(of: $0).map(\.id) }
        }
        let all = Set(takeIDs).union(ids)
        var changed = false
        for track in tracks.indices {
            for clip in tracks[track].clips.indices where all.contains(tracks[track].clips[clip].id) {
                if change(&tracks[track].clips[clip]) { changed = true }
            }
        }
        return changed
    }
}

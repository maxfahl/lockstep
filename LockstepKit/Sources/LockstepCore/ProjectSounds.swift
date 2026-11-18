import Foundation

// Choosing a track's Sound and turning its knobs: the section "Sound" in the panel on the right, for a track
// and for clips.
//
// A track has a Sound or none. A clip follows its track, unless one of its own knobs is turned:
//
//     store.edit("Choose Sound") { $0.setTrack(trackID, sound: SoundPreset.builtIn[0].sound) }
//     store.edit("Choose Sound") { $0.setTrack(trackID, sound: nil) }                  // None
//     store.edit("Change Sound") { $0.setTrack(trackID, knobs: knobs) }                // a knob let go
//     store.edit("Change Clip Sound") { $0.setClips(selection, knob: .space, to: 0.6) }
//     store.edit("Reset Knob") { $0.resetClips(selection, knob: .space) }              // back to the track's value
//
//     project.chainParameters(of: clip)      // what the voice chain is handed for this clip, nil without a Sound
//
// Each function says whether it changed anything, so the app leaves out an undo step for a change of nothing.
// What the other edits do with a Sound and with knobs:
// - A split keeps a clip's knobs on both pieces, a joined clip keeps the first clip's, and a copy keeps them:
//   the pieces and the copies are made from the clip as it is (`ProjectClipEdits.swift`, `ProjectCopies.swift`).
// - A new take starts with the knobs of the take that was heard until then (`addRecording`).
// - Duplicate Track keeps the Sound. After Merge Into, the clips that came follow the Sound of the track they
//   came to and keep their own knobs (`ProjectTracks.swift`).

/// One of the four knobs of a Sound.
public enum SoundKnob: String, Sendable, CaseIterable {
    case squeeze, tone, warmth, space
}

extension SoundKnobs {
    /// The position of one knob.
    public subscript(knob: SoundKnob) -> Double {
        get {
            switch knob {
            case .squeeze: squeeze
            case .tone: tone
            case .warmth: warmth
            case .space: space
            }
        }
        set {
            switch knob {
            case .squeeze: squeeze = newValue
            case .tone: tone = newValue
            case .warmth: warmth = newValue
            case .space: space = newValue
            }
        }
    }

    /// A knob position as it is kept: between 0 and 1, in whole percent, which is what the panel shows.
    /// Something that is no number counts as 0.
    public static func wholePercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (min(max(value, 0), 1) * 100).rounded() / 100
    }

    /// The four knobs as they are kept (`wholePercent`).
    public var inWholePercent: SoundKnobs {
        SoundKnobs(
            squeeze: SoundKnobs.wholePercent(squeeze),
            tone: SoundKnobs.wholePercent(tone),
            warmth: SoundKnobs.wholePercent(warmth),
            space: SoundKnobs.wholePercent(space)
        )
    }
}

extension ClipKnobs {
    /// What the clip turned one knob to. Nil: the clip follows its track with it.
    public subscript(knob: SoundKnob) -> Double? {
        get {
            switch knob {
            case .squeeze: squeeze
            case .tone: tone
            case .warmth: warmth
            case .space: space
            }
        }
        set {
            switch knob {
            case .squeeze: squeeze = newValue
            case .tone: tone = newValue
            case .warmth: warmth = newValue
            case .space: space = newValue
            }
        }
    }

    /// The four knobs a clip is heard with on a track that has these: its own where it turned one, and the
    /// track's otherwise.
    public func over(_ track: SoundKnobs) -> SoundKnobs {
        SoundKnobs(
            squeeze: squeeze ?? track.squeeze,
            tone: tone ?? track.tone,
            warmth: warmth ?? track.warmth,
            space: space ?? track.space
        )
    }
}

extension Project {
    // MARK: A track's Sound

    /// Gives a track a Sound, or takes it away with nil. The knobs are kept in whole percent.
    ///
    /// The clips of the track keep the knobs they turned for themselves, also while the track has no Sound:
    /// they count again when it gets one.
    ///
    /// - Returns: false when the track has exactly that already, or the project has no such track.
    @discardableResult
    public mutating func setTrack(_ id: Track.ID, sound: TrackSound?) -> Bool {
        let sound = sound.map { TrackSound(name: $0.name, character: $0.character, knobs: $0.knobs.inWholePercent) }
        guard let index = tracks.firstIndex(where: { $0.id == id }), tracks[index].sound != sound else { return false }
        tracks[index].sound = sound
        return true
    }

    /// Turns the knobs of a track's Sound: all four as they are now, which is what a dragged knob hands over
    /// when it is let go. The Sound keeps its name and its character.
    ///
    /// - Returns: false when the knobs are there already, the track has no Sound, or the project has no such
    ///   track.
    @discardableResult
    public mutating func setTrack(_ id: Track.ID, knobs: SoundKnobs) -> Bool {
        let knobs = knobs.inWholePercent
        guard let index = tracks.firstIndex(where: { $0.id == id }),
              let sound = tracks[index].sound, sound.knobs != knobs
        else { return false }
        tracks[index].sound?.knobs = knobs
        return true
    }

    // MARK: A clip's own knobs

    /// Turns one knob for the clips with these ids themselves, whatever their tracks have it at. The value is
    /// held between 0 and 1 and kept in whole percent.
    ///
    /// The takes that wait behind a chosen clip get the same, as with `setClips(_:tighten:)`, so stepping to
    /// another take of the line does not quietly change how the line sounds. A clip on a track without a
    /// Sound keeps the value until its track gets one.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func setClips(_ ids: Set<UUID>, knob: SoundKnob, to value: Double) -> Bool {
        let value = SoundKnobs.wholePercent(value)
        return changeTakes(of: ids) { clip in
            guard clip.knobs[knob] != value else { return false }
            clip.knobs[knob] = value
            return true
        }
    }

    /// Puts one knob of the clips with these ids back to their track's value: the clips follow their tracks
    /// with it again. The takes that wait behind a chosen clip are put back too.
    ///
    /// - Returns: whether any clip was changed.
    @discardableResult
    public mutating func resetClips(_ ids: Set<UUID>, knob: SoundKnob) -> Bool {
        changeTakes(of: ids) { clip in
            guard clip.knobs[knob] != nil else { return false }
            clip.knobs[knob] = nil
            return true
        }
    }

    // MARK: What a clip is heard with

    /// The four knobs a clip is heard with: its own over its track's. Nil when its track has no Sound, or the
    /// project has no such clip.
    public func knobs(of clip: Clip) -> SoundKnobs? {
        guard let sound = tracks.first(where: { track in track.clips.contains { $0.id == clip.id } })?.sound
        else { return nil }
        return clip.knobs.over(sound.knobs)
    }

    /// The numbers of the voice chain for a clip: its track's character with the clip's own knobs over the
    /// track's, through the one table (`SoundCharacter.parameters`). Nil when the track has no Sound, so the
    /// chain is skipped, or the project has no such clip.
    ///
    /// The clip is found by its id and read as it was handed in, so a knob that is being dragged can be asked
    /// about before it is in the project.
    public func chainParameters(of clip: Clip) -> ChainParameters? {
        guard let sound = tracks.first(where: { track in track.clips.contains { $0.id == clip.id } })?.sound
        else { return nil }
        return sound.character.parameters(clip.knobs.over(sound.knobs))
    }
}

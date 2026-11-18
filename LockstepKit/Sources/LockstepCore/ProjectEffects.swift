import Foundation

// The effects of a clip: adding one, removing one, turning its level, and what the other edits do with them.
//
//     store.edit("Add Double") { $0.addEffect(clipID, kind: .thick) }                   // on the whole clip
//     store.edit("Add Double") { $0.addEffect(clipID, kind: .lowOctave, span: span) }   // on a stretch
//     store.edit("Change Effect Level") { $0.setEffect(effectID, of: clipID, levelDb: -6) }
//     store.edit("Remove Effect") { $0.removeEffect(effectID, from: clipID) }
//
//     project.effectStretches(of: clip, voices: voices)     // where the window draws each effect, in song seconds
//
// The rules:
// - An effect belongs to its clip, and its id is its own within that clip. So an effect is always named
//   together with its clip: the two pieces of a split, and a clip and its copy, hold effects with the same
//   ids and are still turned one by one.
// - An effect on the whole clip is set for the takes that wait behind the clip too, under the same id, and a
//   new take starts with the whole-clip effects of the take that was heard until then (`addRecording`). An
//   effect on a stretch belongs to its take alone: another take is another recording with other words.
// - A span names samples of a recording, so it stays on its word when the clip is moved or corrected. When
//   the clip is trimmed, cut or shortened by another clip, the span is cut down to what the clip still plays,
//   and the effect goes when less than 20 ms of it is played (`normalizeEffects`, which `ProjectStore` runs
//   after every edit). An edge dragged out again does not bring a span back: Undo does.
// - A split leaves both pieces every effect, and `normalizeEffects` then leaves each piece what it plays.
// - A joined clip keeps the effects of all its parts, each where it was heard (`joinedEffects`).
// - A copy keeps them.

/// One effect of a clip as the window draws it.
public struct EffectStretch: Sendable, Equatable, Identifiable {
    /// The effect's id.
    public var id: ClipEffect.ID
    public var kind: ClipEffect.Kind
    /// Where its stretch is heard, in song seconds. Nil: the effect is on the whole clip.
    public var seconds: Range<Double>?

    public init(id: ClipEffect.ID, kind: ClipEffect.Kind, seconds: Range<Double>?) {
        self.id = id
        self.kind = kind
        self.seconds = seconds
    }
}

extension Clip {
    /// What the clip plays of a span: the span cut down to the first and the last of its samples that a
    /// segment of the clip plays, and how many of its samples are played. Nil when none is.
    func played(_ span: ClipSpan) -> (span: ClipSpan, samples: Int)? {
        var first = Int.max
        var last = Int.min
        var samples = 0
        for segment in segments where segment.recordingID == span.recordingID {
            let from = max(segment.inSample, span.inSample)
            let to = min(segment.outSample, span.outSample)
            guard to > from else { continue }
            first = min(first, from)
            last = max(last, to)
            samples += to - from
        }
        guard samples > 0 else { return nil }
        return (ClipSpan(recordingID: span.recordingID, inSample: first, outSample: last), samples)
    }

    /// The place in `effects` of the effect that stands for `effect` on this clip: the one with its id, or,
    /// for a take that got its effects another way, the first one on the whole clip of the same kind at the
    /// same level.
    fileprivate func place(ofWhole effect: ClipEffect) -> Int? {
        effects.firstIndex { $0.id == effect.id }
            ?? effects.firstIndex { $0.span == nil && $0.kind == effect.kind && $0.levelDb == effect.levelDb }
    }
}

extension Project {
    // MARK: Adding, removing and turning

    /// Gives a clip an effect, at the level its kind starts at.
    ///
    /// Without a span the effect is on the whole clip, and the takes that wait behind the clip get it too.
    /// With a span it is on that stretch of this clip alone. The span is cut down to what the clip plays.
    ///
    /// - Returns: the id of the new effect. Nil, with nothing changed, when the project has no such clip, or
    ///   the clip plays less than 20 ms of the span.
    @discardableResult
    public mutating func addEffect(_ clipID: Clip.ID, kind: ClipEffect.Kind, span: ClipSpan? = nil) -> ClipEffect.ID? {
        guard let clip = clip(clipID) else { return nil }
        var effect = ClipEffect(kind: kind, levelDb: kind.startLevelDb)
        guard let span else {
            _ = changeTakes(of: [clipID]) { take in
                take.effects.append(effect)
                return true
            }
            return effect.id
        }
        guard let played = clip.played(span), played.samples >= ClipSpan.leastSamples else { return nil }
        effect.span = played.span
        changeClip(clipID) { $0.effects.append(effect) }
        return effect.id
    }

    /// Takes an effect off a clip. One on the whole clip is taken off the takes that wait behind it too.
    ///
    /// - Returns: false, with nothing changed, when the clip has no such effect.
    @discardableResult
    public mutating func removeEffect(_ effectID: ClipEffect.ID, from clipID: Clip.ID) -> Bool {
        guard let effect = clip(clipID)?.effects.first(where: { $0.id == effectID }) else { return false }
        guard effect.span == nil else {
            changeClip(clipID) { clip in clip.effects.removeAll { $0.id == effectID } }
            return true
        }
        return changeTakes(of: [clipID]) { take in
            guard let place = take.place(ofWhole: effect) else { return false }
            take.effects.remove(at: place)
            return true
        }
    }

    /// Sets how loud the layer of an effect is, held to -24...+6 dB. For an effect on the whole clip the
    /// takes that wait behind the clip get the same.
    ///
    /// - Returns: false, with nothing changed, when the clip has no such effect, the effect is at that
    ///   level already, or its kind replaces the voice and has no level.
    @discardableResult
    public mutating func setEffect(_ effectID: ClipEffect.ID, of clipID: Clip.ID, levelDb: Double) -> Bool {
        let level = ClipEffect.level(clamped: levelDb)
        guard let effect = clip(clipID)?.effects.first(where: { $0.id == effectID }),
              effect.kind.isLayer, effect.levelDb != level
        else { return false }
        guard effect.span == nil else {
            changeClip(clipID) { clip in
                for index in clip.effects.indices where clip.effects[index].id == effectID {
                    clip.effects[index].levelDb = level
                }
            }
            return true
        }
        return changeTakes(of: [clipID]) { take in
            guard let place = take.place(ofWhole: effect) else { return false }
            take.effects[place].levelDb = level
            return true
        }
    }

    /// Changes the clip with this id, on whichever track it is.
    private mutating func changeClip(_ id: Clip.ID, _ change: (inout Clip) -> Void) {
        for track in tracks.indices {
            guard let index = tracks[track].clips.firstIndex(where: { $0.id == id }) else { continue }
            change(&tracks[track].clips[index])
            return
        }
    }

    // MARK: Keeping spans on what their clips play

    /// Makes the rule for spans true again: every effect on a stretch covers only what its clip plays, and
    /// one of which the clip plays less than 20 ms is gone.
    ///
    /// A trim, a split, a deleted stretch and a clip that gives way all change what a clip plays, and none of
    /// them looks at the effects. `ProjectStore` calls this after every edit, right after `normalizeTakes()`,
    /// and when a project is opened. Calling it on a project that is already right changes nothing.
    public mutating func normalizeEffects() {
        for track in tracks.indices {
            for index in tracks[track].clips.indices {
                let clip = tracks[track].clips[index]
                guard clip.effects.contains(where: { $0.span != nil }) else { continue }
                let kept = clip.effects.compactMap { effect -> ClipEffect? in
                    guard let span = effect.span else { return effect }
                    guard let played = clip.played(span), played.samples >= ClipSpan.leastSamples else { return nil }
                    var effect = effect
                    effect.span = played.span
                    return effect
                }
                if kept != clip.effects {
                    tracks[track].clips[index].effects = kept
                }
            }
        }
    }

    // MARK: Join Clips

    /// The effects of the clip that joining these parts gives, in the order of the parts and of each part's
    /// own list:
    ///
    /// - An effect on a stretch stays as it is.
    /// - An effect that every part has on the whole of it, the same kind at the same level, is one effect on
    ///   the whole joined clip, with the first part's id.
    /// - An effect that only some parts have on the whole of them is heard where it was: it becomes an effect
    ///   on the stretch that part plays, one for each of the part's segments.
    /// - The two shares of an effect that a split divided are one effect again when they still touch, so
    ///   joining what was split gives the clip there was.
    ///
    /// The takes that wait behind the parts keep the effects they have.
    static func joinedEffects(of parts: [Clip]) -> [ClipEffect] {
        guard let first = parts.first, parts.contains(where: { !$0.effects.isEmpty }) else { return [] }

        // For each part, the places of its whole-clip effects that stand for one on the whole joined clip.
        var kept = [Set<Int>](repeating: [], count: parts.count)
        for (place, effect) in first.effects.enumerated() where effect.span == nil {
            var partners: [Int] = []
            for (part, clip) in parts.enumerated().dropFirst() {
                let partner = clip.effects.indices.first { index in
                    let other = clip.effects[index]
                    return !kept[part].contains(index) && other.span == nil
                        && other.kind == effect.kind && other.levelDb == effect.levelDb
                }
                guard let partner else { break }
                partners.append(partner)
            }
            guard partners.count == parts.count - 1 else { continue }
            kept[0].insert(place)
            for (offset, partner) in partners.enumerated() {
                kept[offset + 1].insert(partner)
            }
        }

        var joined: [ClipEffect] = []
        func add(_ effect: ClipEffect) {
            if let span = effect.span, let index = joined.firstIndex(where: { other in
                guard let otherSpan = other.span else { return false }
                return other.id == effect.id && other.kind == effect.kind && other.levelDb == effect.levelDb
                    && otherSpan.recordingID == span.recordingID
                    && otherSpan.inSample <= span.outSample && span.inSample <= otherSpan.outSample
            }), let otherSpan = joined[index].span {
                joined[index].span = ClipSpan(
                    recordingID: span.recordingID,
                    inSample: min(otherSpan.inSample, span.inSample),
                    outSample: max(otherSpan.outSample, span.outSample)
                )
                return
            }
            var effect = effect
            if joined.contains(where: { $0.id == effect.id }) {
                effect.id = UUID()
            }
            joined.append(effect)
        }
        for (part, clip) in parts.enumerated() {
            for (place, effect) in clip.effects.enumerated() {
                if kept[part].contains(place) {
                    if part == 0 { add(effect) }
                } else if effect.span != nil {
                    add(effect)
                } else {
                    for segment in clip.segments where segment.outSample > segment.inSample {
                        var onPart = effect
                        onPart.span = ClipSpan(
                            recordingID: segment.recordingID, inSample: segment.inSample, outSample: segment.outSample
                        )
                        add(onPart)
                    }
                }
            }
        }
        return joined
    }

    // MARK: Where an effect is heard

    /// Answers where a sample of a recording is heard in a clip's dry sound, counted from the dry sound's
    /// first sample, or nil for a sample the clip does not play. It is what `ClipSoundRecipe.init` and
    /// `effectStretches(of:)` place an effect on a stretch with.
    ///
    /// A sample that two segments of the clip play is heard where the first of them plays it.
    ///
    /// - Parameters:
    ///   - tightened: the tightened sounds there are: a line that slid out of the clip at its start makes the
    ///     dry sound begin earlier.
    ///   - voices: the voices the clip is heard with. A tightened sound made from a voice that may not be
    ///     heard on the clip's track is not heard (`TrackVoices.mayBeHeardOn`), so it moves nothing.
    ///   - shift: how many samples later than recorded a sample of the clip's segment at `segment` is heard
    ///     through the clip's correction. Negative is earlier. Left out, everything is heard as recorded,
    ///     which is right for a clip whose timing is not corrected or whose tightened sound is not made yet.
    public func heardSample(
        of clip: Clip,
        tightened: TightenedSounds = .none,
        voices: TrackVoices,
        shift: @escaping (_ segment: Int, _ sample: Int) -> Int = { _, _ in 0 }
    ) -> (_ recordingID: UUID, _ sample: Int) -> Int? {
        guard let first = dryExtent(of: clip, tightened: tightened, voices: voices)?.firstSample else {
            return { _, _ in nil }
        }
        var places: [(index: Int, recordingID: UUID, samples: Range<Int>, origin: Int)] = []
        for (index, segment) in clip.segments.enumerated() where segment.outSample > segment.inSample {
            guard let recording = recording(segment.recordingID) else { continue }
            places.append((
                index, segment.recordingID, segment.inSample..<segment.outSample,
                recording.songSample(ofSample: 0, offsetSamples: segment.offsetSamples)
            ))
        }
        return { recordingID, sample in
            guard let place = places.first(where: { $0.recordingID == recordingID && $0.samples.contains(sample) })
            else { return nil }
            return place.origin + sample + shift(place.index, sample) - first
        }
    }

    /// The effects a clip is heard with as the making of its sound needs them, in the order they are applied:
    /// its track's and then its own (`effects(heardOn:)`), each span as samples of the dry sound. An effect on
    /// a stretch that is not heard is left out.
    func heardEffects(
        of clip: Clip,
        heardSample: (_ recordingID: UUID, _ sample: Int) -> Int?
    ) -> [ClipSoundRecipe.HeardEffect] {
        placed(effects(heardOn: clip), on: clip, heardSample: heardSample)
    }

    /// These effects of a clip with each span as samples of the clip's dry sound, in the list's order. An
    /// effect on a stretch that is not heard is left out.
    private func placed(
        _ effects: [ClipEffect],
        on clip: Clip,
        heardSample: (_ recordingID: UUID, _ sample: Int) -> Int?
    ) -> [ClipSoundRecipe.HeardEffect] {
        effects.compactMap { effect in
            guard let span = effect.span else {
                return ClipSoundRecipe.HeardEffect(id: effect.id, kind: effect.kind, levelDb: effect.levelDb)
            }
            // A span ends one past its last sample, which may be one the clip does not play: the last
            // sample is asked about.
            guard let played = clip.played(span)?.span,
                  let from = heardSample(played.recordingID, played.inSample),
                  let last = heardSample(played.recordingID, played.outSample - 1), last >= max(from, 0)
            else { return nil }
            return ClipSoundRecipe.HeardEffect(
                id: effect.id, kind: effect.kind, levelDb: effect.levelDb, span: max(from, 0)..<last + 1
            )
        }
    }

    /// What the window draws of a clip's own effects, in the list's order: each effect with the stretch of the
    /// song its span is heard on, or with none for an effect on the whole clip. An effect on a stretch that
    /// is not heard is left out. The effects of the clip's track are not among them: those are shown in the
    /// panel only.
    ///
    /// The seconds are where the stretch is heard now, so they follow the clip when it is moved and its
    /// syllables when its timing is corrected.
    ///
    /// - Parameters:
    ///   - tightened: the tightened sounds that are heard, as for `heardSample(of:tightened:voices:shift:)`.
    ///   - voices: the voices the clip is heard with, as for `heardSample(of:tightened:voices:shift:)`.
    ///   - heardSample: where a sample of a recording is heard in the clip's dry sound: the same answer the
    ///     clip's recipe is made with. Left out, everything is heard as recorded.
    public func effectStretches(
        of clip: Clip,
        tightened: TightenedSounds = .none,
        voices: TrackVoices,
        heardSample: ((_ recordingID: UUID, _ sample: Int) -> Int?)? = nil
    ) -> [EffectStretch] {
        guard clip.effects.contains(where: { $0.span != nil }) else {
            return clip.effects.map { EffectStretch(id: $0.id, kind: $0.kind, seconds: nil) }
        }
        guard let first = dryExtent(of: clip, tightened: tightened, voices: voices)?.firstSample else { return [] }
        let heard = placed(
            clip.effects, on: clip,
            heardSample: heardSample ?? self.heardSample(of: clip, tightened: tightened, voices: voices)
        )
        return heard.map { effect in
            EffectStretch(
                id: effect.id,
                kind: effect.kind,
                seconds: effect.span.map { span in
                    Double(first + span.lowerBound) / Lockstep.sampleRate
                        ..< Double(first + span.upperBound) / Lockstep.sampleRate
                }
            )
        }
    }
}

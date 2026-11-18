import Foundation

// The recipe of a clip's finished sound, worked out from the project.
//
//     let recipe = ClipSoundRecipe(
//         of: clip, in: heardProject,
//         tightened: tightened,                      // the tightened sounds that stand in for its segments
//         voices: voices,                            // the voices that stand in on its track. `.none`: Max's own
//         edgeFadeMs: settings[.edgeFadeMs],
//         peaks: recordingPeaks.lookup(in: sounds),  // for the safe limit, see `RecordingPeak`
//         grid: feels.grid(for: clip, in: heardProject, markers: markers)
//     )
//     // nil: the clip needs no finished sound, and is played and sent as before phase 33
//
// Whoever keeps finished sounds keeps each with the recipe it was made from. A clip whose recipe is still the
// same is played from the sound there is, and one whose recipe changed has its sound made again.

extension ClipSoundRecipe {
    /// How many beats after the end of a clip are handed over with the beats: an echo's repeats lie at most
    /// two bars after their sound, and the beat after the last repeat says where it lies between two beats.
    static let beatsAfter = 2 * Grid.beatsPerBar + 2

    /// The recipe of a clip's finished sound, or nil for a clip that needs none: no Sound on its track and no
    /// effect that is heard, its track's or its own, or nothing to play.
    ///
    /// What is in it, and so what makes the sound again when it changes:
    /// - What the dry sound is made from (`DryIdentity`): the segments, the tightened sounds that stand in for
    ///   them, the voices that stand in for their recordings on the clip's track, the fades and the volume
    ///   before the chain. Where the clip lies in the song is not in it: a segment says where it lies
    ///   against the clip's first sound.
    /// - The chain's numbers: the track's character with the clip's own knobs over the track's
    ///   (`Project.chainParameters(of:)`).
    /// - The clip's own volume, which is applied after the chain.
    /// - The effects the clip is heard with, its track's and then its own (`Project.effects(heardOn:)`), each
    ///   with its stretch as samples of the dry sound.
    /// - The beats, as samples of the dry sound, only when the chain has an echo or an effect follows the
    ///   beats (an echo, a stutter or a swell). So a clip without those is not made again when it is moved, and one
    ///   with them is. The beats are the ones from just before the clip to two bars after it.
    /// - The clip's sub-beats per beat, only when it has a stutter. Otherwise 4, whatever the clip's feel.
    ///
    /// - Parameters:
    ///   - clip: the clip. It is found in the project by its id and read as it is handed in, so a knob that
    ///     is being dragged can be asked about before it is in the project.
    ///   - project: the project that is heard.
    ///   - tightened: the tightened sounds there are. Only a clip whose timing is corrected uses them.
    ///   - edgeFadeMs: the fade at every segment edge, in milliseconds: the setting `timing.edgeFadeMs`.
    ///   - peaks: the highest sample of a stretch of a recording, for the safe limit on the volume before the
    ///     chain. It is asked about the sound the clip is read from on its track (`TrackVoices.peaks`).
    ///   - voices: which voice stands in for which recording on which track. With `.none` the recipe
    ///     is of the finished sound made from Max's own recordings, whatever Voice the clip's track has.
    ///     The same lookup the dry sound is made with, filtered by `TrackVoices.having`, so the recipe never
    ///     names a voice whose samples were not there.
    ///   - grid: the grid the clip's timing is measured against (`Project.grid(for:markers:)`), for a stutter.
    ///   - heardSample: where a sample of a recording is heard in the clip's dry sound, counted from the dry
    ///     sound's first sample, or nil where it is not heard. An effect on a stretch is placed with it, and
    ///     is left out when its stretch is not heard. Whoever makes the sound of a clip whose timing is
    ///     corrected hands in `Project.heardSample(of:tightened:voices:shift:)` with how far the correction moved
    ///     each sample, so the effect stays on its syllables. Left out, everything is heard as recorded.
    public init?(
        of clip: Clip,
        in project: Project,
        tightened: TightenedSounds = .none,
        edgeFadeMs: Double,
        peaks: RecordingPeak = Clip.unknownPeaks,
        grid: SubBeatGrid = .sixteenths,
        heardSample: ((_ recordingID: UUID, _ sample: Int) -> Int?)? = nil,
        voices: TrackVoices
    ) {
        guard !clip.segments.isEmpty else { return nil }
        let chain = project.chainParameters(of: clip)
        // Where a sample is heard is only worked out for a clip that has an effect on a stretch.
        // A track's effect is never on a stretch, so asking the clip's own is enough to know.
        let effects = clip.effects.contains { $0.span != nil }
            ? project.heardEffects(
                of: clip, heardSample: heardSample ?? project.heardSample(of: clip, tightened: tightened, voices: voices)
            )
            : project.effects(heardOn: clip).map { HeardEffect(id: $0.id, kind: $0.kind, levelDb: $0.levelDb) }
        guard chain != nil || !effects.isEmpty else { return nil }

        // What Normalize set, held back by the safe limit, without the clip's own volume: the volume the
        // player's plan gives the clip when its own volume is 0.
        var unturned = clip
        unturned.gainDb = 0
        // The clip's track, for what stands in for its recordings there. Only looked for when anything does:
        // with no voices at all, a tightened sound made from a voice is not heard on any track.
        let track = voices.isEmpty
            ? nil
            : project.tracks.first { track in track.clips.contains { $0.id == clip.id } }

        var beats: [Double] = []
        let followsBeats = chain?.echo != nil || effects.contains { $0.kind.followsBeats }
        if followsBeats, let song = project.grid, !song.beats.isEmpty,
           let extent = project.dryExtent(of: clip, tightened: tightened, voices: voices) {
            let start = Double(extent.firstSample) / Lockstep.sampleRate
            let end = Double(extent.firstSample + extent.lengthSamples) / Lockstep.sampleRate
            let first = max((song.lastIndex(atOrBefore: start) ?? 0) - 1, 0)
            let last = min((song.lastIndex(atOrBefore: end) ?? 0) + Self.beatsAfter, song.beats.count - 1)
            beats = song.beats[first...last].map { $0.time * Lockstep.sampleRate - Double(extent.firstSample) }
        }

        self.init(
            dry: DryIdentity(
                segments: project.segmentsAgainstFirstSound(of: clip),
                // The tightened sounds the dry sound is made from: those the plan plays, so a sound made from a
                // voice that is not heard here is not named either.
                tightenedIDs: clip.segments.enumerated().map { index, segment in
                    clip.hasTimingFix
                        ? tightened.sound(for: segment, at: index, of: clip, on: track, voices: voices)?.id
                        : nil
                },
                fadeSamples: EdgeFade.samples(milliseconds: edgeFadeMs),
                gainDb: track.map { unturned.appliedGain(peaks: peaks, voices: voices, on: $0).db }
                    ?? unturned.appliedGain(peaks: peaks).db,
                sources: track.map { voices.standIns(for: clip, on: $0) } ?? [:],
                onTrack: track?.id
            ),
            chain: chain,
            clipGainDb: clip.gainDb,
            effects: effects,
            beats: beats,
            perBeat: effects.contains { $0.kind == .stutter } ? grid.perBeat : SubBeatGrid.sixteenths.perBeat
        )
    }
}

extension Project {
    /// A clip's segments with their places counted from the clip's first sound in place of the song: each
    /// one's `offsetSamples` says where sample 0 of its recording would lie, in samples after the start of
    /// the clip's first segment. So a clip that was only moved gives the same answer, and one whose parts
    /// lie differently against each other does not.
    func segmentsAgainstFirstSound(of clip: Clip) -> [Segment] {
        guard let first = clip.segments.first else { return [] }
        let known = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func origin(_ segment: Segment) -> Int? {
            known[segment.recordingID]?.songSample(ofSample: 0, offsetSamples: segment.offsetSamples)
        }
        let start = origin(first).map { $0 + first.inSample }
        return clip.segments.map { segment in
            var placed = segment
            if let start, let origin = origin(segment) {
                placed.offsetSamples = origin - start
            } else {
                // A recording the project does not have has no place in the song. How far the segment was
                // moved against the first one still tells two clips apart.
                placed.offsetSamples = segment.offsetSamples - first.offsetSamples
            }
            return placed
        }
    }

    /// Where the dry sound of a clip lies: the sample of the song its first sound is on, and how many samples
    /// it lasts. Nil for a clip that plays nothing.
    ///
    /// It is read from the clip alone as `ClipDry` has it, which the dry sound itself and the export of a clip
    /// are made from, so a line that slid out of the clip at its start makes the first sound earlier here too.
    func dryExtent(
        of clip: Clip,
        tightened: TightenedSounds,
        voices: TrackVoices
    ) -> (firstSample: Int, lengthSamples: Int)? {
        ClipDry.alone(clip, in: self, peaks: Clip.unknownPeaks, tightened: tightened, voices: voices).map {
            ($0.firstSample, $0.lengthSamples)
        }
    }
}

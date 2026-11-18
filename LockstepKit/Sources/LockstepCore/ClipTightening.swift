import Foundation

// The correction of a clip's timing, from a clip to what is heard.
//
// The steps before this file each do one thing: `LineFinder` finds the lines of a clip, `LineShift` finds how
// far one line should slide, `LineRenderer` builds the sound of one segment with its lines slid. This file puts
// them together for a whole clip, and says how the result gets into what is played and exported.
//
//     // 1. What the corrected sound of a clip depends on, with the clip's own choices read from it: Off,
//     //    Lines or All, its strength and Stretch. Two of these that are equal give the same sound.
//     let inputs = ClipTightening.Inputs(
//         correcting: clip, in: project, markers: markersByRecording, settings: settings, perBeat: 4
//     )
//
//     // 2. The sound, one answer per segment. This is the slow part: do it away from the main thread. The
//     //    stretcher is what moves single syllables. Without one, or with Lines, only whole lines slide.
//     let made = ClipTightening.render(inputs, levels: levelsByRecording, recordings: sounds, stretcher: stretcher)
//
//     //    The values can also be given one by one, which the tests do:
//     let inputs = ClipTightening.Inputs(
//         clip: clip, in: project, markers: markersByRecording, settings: settings,
//         strength: 0.6, lineStrength: 1
//     )
//
//     //    A clip that aims at another track is held against that track's syllables where they are heard,
//     //    which the app hands in. With none handed in, or an aim that cannot be followed, it is the beat.
//     let inputs = ClipTightening.Inputs(
//         correcting: double, in: project, markers: markersByRecording, settings: settings,
//         aimedAt: leadSyllables                       // `TimingTargets.Target`s, in song seconds
//     )
//
//     //    On a track with a Voice the sound is made from the voice that stands in for each recording. The
//     //    voices' samples are in `sounds` with the recordings'. With `.none` it is made from Max's
//     //    own recordings, which is what a dry send asks for.
//     let inputs = ClipTightening.Inputs(
//         correcting: clip, in: project, markers: markersByRecording, settings: settings, voices: voices
//     )
//
//     // 3. Each segment that changed gets an id of its own, and its samples go in with the recordings' samples.
//     //    A line that slid past an edge of the clip makes the sound longer than the segment, by `leadSamples`
//     //    before it and `tailSamples` after it, and the lookup has to know.
//     var tightened = TightenedSounds()
//     for (index, segment) in made.enumerated() {
//         guard let samples = segment.samples else { continue }      // no line moved: the recording is played
//         let id = UUID()
//         sounds[id] = samples
//         tightened.set(
//             id, for: clip.segments[index], at: index, of: clip.id,
//             lead: segment.leadSamples, tail: segment.tailSamples,
//             madeFrom: VoiceSources(inputs.voices, onTrack: track.id)   // the voices it was made from
//         )
//     }
//
//     // 4. The player and the export take the lookup. Left out, the clips are heard as they were recorded.
//     //    A sound made from a voice that no longer stands in on the clip's track is not heard.
//     project.clipPlaybackPlan(from: 0, peaks: peaks, tightened: tightened, voices: voices)

/// The numbers the correction works with. They start as the values below and become Max's settings.
public struct TightenSettings: Sendable, Equatable {
    /// How long a pause must be to separate two lines, in milliseconds: the setting `timing.linePauseMs`.
    public var linePauseMs: Double
    /// The furthest a line may slide, in milliseconds: the setting `timing.maxLineShiftMs`.
    public var maxLineShiftMs: Double
    /// How far from a sub-beat counts as meant to be off, as a percentage of the sub-beat spacing: the setting
    /// `timing.deliberatePercent`.
    public var deliberatePercent: Double
    /// The furthest a single syllable may move, in milliseconds: the setting `timing.maxSyllableMoveMs`.
    public var maxSyllableMoveMs: Double
    /// The most the sound between two syllables may be stretched or squeezed, as a percentage: the setting
    /// `timing.maxStretchPercent`, for a clip with Stretch on. 0 for every other clip
    /// (`ClipTightening.Inputs(correcting:)`), which is never stretched.
    public var maxStretchPercent: Double

    public init(
        linePauseMs: Double = LineFinder.defaultPauseMs,
        maxLineShiftMs: Double = LineShift.defaultMaxShiftMs,
        deliberatePercent: Double = MarkerDistance.defaultDeliberatePercent,
        maxSyllableMoveMs: Double = SyllableMoves.defaultMaxMoveMs,
        maxStretchPercent: Double = SyllableMoves.defaultMaxStretchPercent
    ) {
        self.linePauseMs = linePauseMs
        self.maxLineShiftMs = maxLineShiftMs
        self.deliberatePercent = deliberatePercent
        self.maxSyllableMoveMs = maxSyllableMoveMs
        self.maxStretchPercent = maxStretchPercent
    }

    /// The numbers that hold single syllables back, as `SyllableMoves.plan` takes them.
    public var syllableLimits: SyllableMoves.Limits {
        SyllableMoves.Limits(
            deliberatePercent: deliberatePercent,
            maxMoveMs: maxSyllableMoveMs,
            maxStretchPercent: maxStretchPercent
        )
    }

    /// How far from a syllable of a double a syllable of the lead may be and still be the one it belongs to,
    /// in seconds: the furthest a line may slide plus the furthest a syllable may move. A lead syllable
    /// further away than this from every syllable of a clip plays no part in correcting it.
    public var partnerReach: Double {
        let reach = (max(maxLineShiftMs, 0) + max(maxSyllableMoveMs, 0)) / 1_000
        return reach.isFinite ? reach : 0
    }

    /// The furthest a line may slide when lines are separated by a pause of this length, in whole
    /// milliseconds: `(pause - 60) / 2`. The 60 ms are what the two lines keep of the pause, as in
    /// `maxShiftSamples`. The setting for the furthest slide is never allowed above this.
    public static func furthestShiftMs(forPauseMs pauseMs: Double) -> Double {
        let taken = LineFinder.marginBeforeMs + LineFinder.marginAfterMs + 2 * LineRenderer.crossfadeMs
        return max(((pauseMs - taken) / 2).rounded(.down), 0)
    }

    /// The furthest a line really slides, in samples: what the setting says, but never so far that two
    /// neighbouring lines could meet. Two lines have at least a pause between their sounds. Of that pause each
    /// line keeps its margins (10 ms and 30 ms), and each needs a crossfade of 10 ms, so what is left of the
    /// pause is shared by the two.
    public var maxShiftSamples: Int {
        func samples(_ milliseconds: Double) -> Int {
            let samples = (milliseconds * Lockstep.sampleRate / 1_000).rounded(.down)
            guard samples.isFinite, samples > 0, samples < 1e9 else { return 0 }
            return Int(samples)
        }
        let taken = LineFinder.marginBeforeMs + LineFinder.marginAfterMs + 2 * LineRenderer.crossfadeMs
        return min(samples(maxLineShiftMs), max(samples(linePauseMs) - samples(taken), 0) / 2)
    }
}

/// Which tightened sound is played in place of which segment of which clip.
///
/// The tightened sound of a segment is a row of samples of its own, kept with the recordings' samples under an
/// id of its own. It is as long as the segment, or longer when a line slid past an edge of its clip: it then
/// starts `leadSamples` before the segment and ends `tailSamples` after it. This says which id stands in for
/// which segment. A segment that is not in here is played from its recording, as it was recorded.
///
/// An entry remembers the stretch of the recording it was made from. When the segment has been cut or swapped
/// since, the entry no longer fits and is not used.
public struct TightenedSounds: Sendable, Equatable {
    /// One segment of one clip: the clip, and the segment's place in `clip.segments`.
    public struct Key: Sendable, Hashable {
        public var clipID: UUID
        public var segment: Int

        public init(clipID: UUID, segment: Int) {
            self.clipID = clipID
            self.segment = segment
        }
    }

    /// The tightened sound of one segment.
    public struct Sound: Sendable, Equatable {
        /// The id its samples are kept under, among the recordings' samples.
        public var id: UUID
        /// The stretch of the recording it was made from: sample `leadSamples` of the sound is `inSample` of
        /// the recording.
        public var recordingID: UUID
        public var inSample: Int
        public var outSample: Int
        /// How many samples the sound has before the segment's first one: how far a line slid out of the
        /// segment at its start. 0 for a sound that starts where the segment does.
        public var leadSamples: Int
        /// How many samples the sound has after the segment's last one.
        public var tailSamples: Int
        /// The voices it was made from, if any, and the track they were the voices of. A sound made from a
        /// voice is heard only while that voice may be (`TrackVoices.mayBeHeardOn`).
        public var sources: VoiceSources

        public init(
            id: UUID,
            recordingID: UUID,
            inSample: Int,
            outSample: Int,
            leadSamples: Int = 0,
            tailSamples: Int = 0,
            sources: VoiceSources
        ) {
            self.id = id
            self.recordingID = recordingID
            self.inSample = inSample
            self.outSample = outSample
            self.leadSamples = leadSamples
            self.tailSamples = tailSamples
            self.sources = sources
        }
    }

    public var sounds: [Key: Sound]

    public init(_ sounds: [Key: Sound] = [:]) {
        self.sounds = sounds
    }

    /// No tightened sound at all: every clip is heard as it was recorded.
    public static let none = TightenedSounds()

    public var isEmpty: Bool { sounds.isEmpty }

    /// Says that the samples kept under `id` are the tightened sound of this segment of this clip.
    ///
    /// - Parameters:
    ///   - lead: how many of the samples lie before the segment's first one (`SegmentSound.leadSamples`).
    ///   - tail: how many lie after its last one (`SegmentSound.tailSamples`).
    ///   - sources: what it was made from: the inputs' voices (`ClipTightening.Inputs.voices`) and the track
    ///     the clip was on, or `.recordings`. Never left out, so a sound made from a voice is always known
    ///     as one, and never heard once that voice no longer stands in.
    public mutating func set(
        _ id: UUID,
        for segment: Segment,
        at index: Int,
        of clipID: UUID,
        lead: Int = 0,
        tail: Int = 0,
        madeFrom sources: VoiceSources
    ) {
        sounds[Key(clipID: clipID, segment: index)] = Sound(
            id: id,
            recordingID: segment.recordingID,
            inSample: segment.inSample,
            outSample: segment.outSample,
            leadSamples: max(lead, 0),
            tailSamples: max(tail, 0),
            sources: sources
        )
    }

    /// The tightened sound that is heard in place of a segment of a clip on a track, or nil when the segment
    /// is played from what stands in for its recording: there is none, the one there is was made from another
    /// stretch, or it was made from a voice that may no longer be heard there (`TrackVoices.mayBeHeardOn`):
    /// the Voice was switched off, taken off or undone, or the clip was moved to another track.
    ///
    /// The plan of what is played, and so the dry sound, the export and the recipe of a finished sound, ask
    /// this one.
    ///
    /// - Parameter track: the track the clip is heard on. Nil for a clip on no track, where only a sound made
    ///   from the recordings is heard.
    public func sound(
        for segment: Segment,
        at index: Int,
        of clip: Clip,
        on track: Track?,
        voices: TrackVoices
    ) -> Sound? {
        guard let sound = sound(for: segment, at: index, of: clip.id),
              voices.mayBeHeard(madeFrom: sound.sources, for: clip, on: track)
        else { return nil }
        return sound
    }

    /// The tightened sound made for a segment, or nil when there is none or the one there is was made from
    /// another stretch than the segment plays now. It says nothing about the voice it was made from: what is
    /// heard is `sound(for:at:of:on:voices:)`.
    public func sound(for segment: Segment, at index: Int, of clipID: UUID) -> Sound? {
        guard let sound = sounds[Key(clipID: clipID, segment: index)],
              sound.recordingID == segment.recordingID,
              sound.inSample == segment.inSample,
              sound.outSample == segment.outSample
        else { return nil }
        return sound
    }
}

/// The timing fixes of one clip: finds its lines, how far each slides and where its syllables go, and builds
/// the sound.
public enum ClipTightening {
    /// Everything the tightened sound of a clip depends on, besides the recordings' sound itself, which never
    /// changes. Two of these that are equal give the same sound, so a sound that was made is good for as long
    /// as the inputs it was made from are the inputs of the clip.
    ///
    /// It changes with the clip's place, a cut, the recording's measured delay, the syllable markers and which
    /// of them Max excluded, the beats, the settings, the room around the clip when something is close to
    /// it, and what the clip says for itself: how far its lines slide, how far single syllables move and
    /// whether its voice may be stretched. It does not change with the clip's volume, its name or whether it
    /// is muted.
    ///
    /// For a clip that is held against another track (`aimedAt`) it changes with that track's syllables near
    /// the clip in place of the beats: when the lead is moved, cut or corrected anew, its syllables are
    /// heard elsewhere, the inputs of the double differ, and its sound is made again. The lead leads.
    ///
    /// On a track with a Voice it changes when a voice arrives for one of the clip's recordings and when the
    /// voice that stands in changes (`voices`): the sound is made from the voice, so it is made again.
    public struct Inputs: Sendable, Equatable {
        public var clipID: UUID
        /// The clip's segments, each with its own volume left out.
        public var segments: [Segment]
        /// The recordings the segments play, by id.
        public var recordings: [UUID: Recording]
        /// The syllable markers of those recordings, by recording id. A recording whose markers are not known
        /// yet has none here, and its lines stay where they are.
        public var markers: [UUID: [SyllableMarker]]
        /// The beats of the song. No beats for a clip that is held against another track: it does not depend
        /// on them, so new beats do not make its sound again.
        public var grid: Grid
        /// How many sub-beats a beat has: 4 for sixteenths. Always 4 for a clip that is held against another
        /// track, which has no use for it.
        public var perBeat: Int
        /// The syllables of the track the clip is held against, where they are heard, earliest first. Only
        /// those near the clip (`TightenSettings.partnerReach`). Nil for a clip that is held against the
        /// beat.
        public var aimedAt: [TimingTargets.Target]?
        public var settings: TightenSettings
        /// How much of the way to its sub-beat each syllable goes by itself, from 0 to 1: the clip's
        /// `syllableStrength`. At 0 no single syllable moves.
        public var strength: Double
        /// How much of the way each whole line slides, from 0 to 1: the clip's `lineStrength`. At 0 every
        /// line stays where it was recorded.
        public var lineStrength: Double
        /// How far the sound of each segment may reach past the segment's own edges, in the order of
        /// `segments`: what is free around the clip, and never more than the furthest a line may slide
        /// (`Project.room(around:atMost:)`). A line that needs it slides out of its clip this far.
        public var rooms: [Room]
        /// The sound each recording is read from where that is not the recording itself: the id of the voice
        /// that stands in for it on the clip's track, by recording id (`TrackVoices.standIns(for:on:)`).
        /// `render` reads those samples in place of the recording's. Empty for a clip that is read from
        /// Max's own recordings, and the inputs are then the ones of before a track could have a Voice.
        ///
        /// Only the samples come from the voice. The markers, the levels, the pauses and the lines stay
        /// the recording's own: the voice is taken to have its syllables where the recording has them.
        public var voices: [UUID: UUID]
        /// The track whose voices `voices` names, or nil when it names none. A clip with a voice that is moved
        /// to another track has other inputs there, so its sound is made again from that track's voices.
        public var voicesTrackID: UUID?

        /// What a sound made from these inputs was made from, as it is handed in with (`TightenedSounds.set`).
        public var sources: VoiceSources { VoiceSources(voices, onTrack: voicesTrackID) }

        /// What the clip is held against: the syllables of another track, or the sub-beats of the song.
        public var targets: TimingTargets {
            aimedAt.map { .times($0) } ?? .subBeats(grid: grid, perBeat: perBeat)
        }

        /// The inputs of a clip as it is set: its lines slide and its syllables move by its strength as its
        /// choice of Off, Lines or All says, and its voice is stretched only with Stretch on. With Stretch
        /// off the stretch limit is 0 for this clip, whatever Settings > Timing says, so its syllables move
        /// as far as pauses allow and no further.
        ///
        /// A clip that aims at another track is held against the syllables handed in. It is held against
        /// the beat, as every clip was before, when none are handed in or its aim cannot be followed
        /// (`Project.aim(of:)`): the track is gone, is its own, or aims back.
        ///
        /// Nil as the other `init` is.
        ///
        /// - Parameters:
        ///   - aimedAt: the syllables of the track the clip aims at, where they are heard right now
        ///     (after that track's own correction), each with where its note ends if that is known. The app
        ///     knows where they are heard. Nil while it does not, and for a clip that aims at the beat.
        ///   - voices: which voice stands in for which recording on which track. With `.none` the
        ///     sound is made from Max's own recordings, whatever Voice the clip's track has. The same lookup
        ///     `render` is then handed the samples for, filtered by `TrackVoices.having`: inputs that name a
        ///     voice whose samples are missing give no sound at all, and the clip is heard uncorrected.
        public init?(
            correcting clip: Clip,
            in project: Project,
            markers: [UUID: [SyllableMarker]],
            settings: TightenSettings = TightenSettings(),
            perBeat: Int = 4,
            aimedAt: [TimingTargets.Target]? = nil,
            voices: TrackVoices
        ) {
            var settings = settings
            if !clip.stretchesVoice { settings.maxStretchPercent = 0 }
            let followed = aimedAt != nil && project.aim(of: clip, reach: settings.partnerReach) != nil
            self.init(
                clip: clip,
                in: project,
                markers: markers,
                settings: settings,
                perBeat: perBeat,
                strength: clip.syllableStrength,
                lineStrength: clip.lineStrength,
                aimedAt: followed ? aimedAt : nil,
                voices: voices
            )
        }

        /// Nil when there is nothing to tighten against or nothing to tighten: the song's beats are not found
        /// yet, or the clip plays nothing. A clip that is held against another track needs no beats.
        ///
        /// - Parameters:
        ///   - tightenLines: false keeps every line where it was recorded, whatever `lineStrength` says.
        ///   - aimedAt: the syllables of another track to hold the clip against, in any order, or nil for
        ///     the beat. Whether the clip's aim can be followed is not asked here.
        ///   - voices: which voice stands in for which recording on which track. With `.none` the
        ///     sound is made from Max's own recordings.
        public init?(
            clip: Clip,
            in project: Project,
            markers: [UUID: [SyllableMarker]],
            settings: TightenSettings = TightenSettings(),
            perBeat: Int = 4,
            strength: Double = 0,
            tightenLines: Bool = true,
            lineStrength: Double = 1,
            aimedAt: [TimingTargets.Target]? = nil,
            voices: TrackVoices
        ) {
            guard !clip.segments.isEmpty else { return nil }
            let known = Dictionary(project.recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let track = project.tracks.first { track in track.clips.contains { $0.id == clip.id } }
            self.init(
                clip: clip,
                grid: project.grid,
                recording: { known[$0] },
                markers: markers,
                settings: settings,
                perBeat: perBeat,
                strength: strength,
                lineStrength: tightenLines ? lineStrength : 0,
                rooms: ShownPlaces(of: track, recording: { known[$0] })
                    .room(around: clip, kept: project.keptSamples, atMost: settings.maxShiftSamples),
                aimedAt: aimedAt,
                voices: track.map { voices.standIns(for: clip, on: $0) } ?? [:],
                voicesTrack: track?.id
            )
        }

        /// The inputs from their parts, for whoever has the project's recordings and the clip's rooms at
        /// hand already (`TighteningInputsMemory`). The two other `init`s give exactly this for a clip.
        ///
        /// - Parameters:
        ///   - grid: the beats of the song, or nil when they are not found. Not asked for when the clip is
        ///     held against another track.
        ///   - recording: the project's recording with an id, or nil when it has none.
        ///   - markers: the markers of every recording, by recording id. Only the clip's are kept.
        ///   - rooms: `Project.room(around:atMost:)` of the clip, with `settings.maxShiftSamples` as the most.
        ///   - aimedAt: the syllables of another track to hold the clip against, in any order, or nil for
        ///     the beat. Whether the clip's aim can be followed is not asked here.
        ///   - voices: `TrackVoices.standIns(for:on:)` of the clip on its track, or nothing for Max's own
        ///     recordings.
        ///   - voicesTrack: the clip's track, whose voices those are.
        init?(
            clip: Clip,
            grid beats: Grid?,
            recording: (UUID) -> Recording?,
            markers: [UUID: [SyllableMarker]],
            settings: TightenSettings,
            perBeat: Int,
            strength: Double,
            lineStrength: Double,
            rooms: [Room],
            aimedAt: [TimingTargets.Target]? = nil,
            voices: [UUID: UUID],
            voicesTrack: UUID?
        ) {
            guard let first = clip.segments.first, let last = clip.segments.last else { return nil }
            let grid: Grid
            if let aimedAt {
                // Only the lead syllables that could be a partner of one of the clip's are kept. So the
                // sound is not made again when the lead changes somewhere else in the song.
                var near = aimedAt.filter(\.time.isFinite)
                if let start = recording(first.recordingID)?
                    .songTime(ofSample: first.inSample, offsetSamples: first.offsetSamples),
                    let end = recording(last.recordingID)?
                    .songTime(ofSample: last.outSample, offsetSamples: last.offsetSamples)
                {
                    let reach = settings.partnerReach + SyllableMatch.sameSeconds
                    near = near.filter { $0.time >= start - reach && $0.time <= end + reach }
                }
                self.aimedAt = near.sorted { $0.time < $1.time }
                grid = Grid()
            } else {
                guard let beats, !beats.beats.isEmpty else { return nil }
                self.aimedAt = nil
                grid = beats
            }
            clipID = clip.id
            segments = clip.segments.map { segment in
                var plain = segment
                plain.gainDb = 0
                return plain
            }
            var recordings: [UUID: Recording] = [:]
            var found: [UUID: [SyllableMarker]] = [:]
            for segment in clip.segments where recordings[segment.recordingID] == nil {
                recordings[segment.recordingID] = recording(segment.recordingID)
                found[segment.recordingID] = markers[segment.recordingID]
            }
            self.recordings = recordings
            self.markers = found
            self.grid = grid
            self.perBeat = aimedAt == nil ? perBeat : 4
            self.settings = settings
            self.strength = strength
            self.lineStrength = lineStrength
            self.rooms = rooms
            // Only what the clip plays is kept, so a voice of another recording never makes its sound again.
            self.voices = voices.filter { recordings[$0.key] != nil }
            voicesTrackID = self.voices.isEmpty ? nil : voicesTrack
        }
    }

    /// One line of a segment, and where it goes.
    public struct Line: Sendable, Equatable {
        /// The line, in samples of its recording.
        public var line: VoiceLine
        /// Where its sound goes: the line slid by the shift it really gets, which is 0 for a line that stays.
        /// From `render`, a line whose syllables were moved has a pair for each of them as well.
        public var map: TimeMap
        /// When the line starts in the song as it was recorded, before it slides, in song seconds.
        public var songStart: Double
        /// How much of the shift is the first syllable's own move, in samples. The first syllable has no
        /// sound before it to give or take, so when it moves by itself the whole line goes with it. 0 while
        /// only lines slide.
        public var carriedSamples: Int
        /// For a clip that is held against another track: when the partner of each paired syllable is heard,
        /// in song seconds, by the syllable's sample position in the recording. A syllable that is not in
        /// here has no partner and is left alone. Empty for a clip that is held against the beat.
        public var partners: [Int: Double]

        public init(
            line: VoiceLine,
            map: TimeMap,
            songStart: Double,
            carriedSamples: Int = 0,
            partners: [Int: Double] = [:]
        ) {
            self.line = line
            self.map = map
            self.songStart = songStart
            self.carriedSamples = carriedSamples
            self.partners = partners
        }

        /// How many ends of held notes were moved onto the ends of the lead's notes: the pairs of the map
        /// that are neither an edge of the line nor one of its syllables (`SyllableMoves.noteEnds`).
        public var matchedNoteEnds: Int {
            let syllables = Set(line.markers)
            return map.pairs.dropFirst().dropLast().filter { !syllables.contains($0.source) }.count
        }

        /// How far the line's sound moves as a whole, in samples: its slide, and what it goes on with its
        /// first syllable. Negative is earlier.
        public var shiftSamples: Int { map.shiftSamples }
        /// The same in milliseconds.
        public var shiftMs: Double { Double(shiftSamples) / Lockstep.sampleRate * 1_000 }
        /// How far the line slides as a line, in samples: the clip's strength as a share of the way to where
        /// its first syllable stands on its sub-beat. What a syllable moves beyond this is its own move.
        public var slideSamples: Int { shiftSamples - carriedSamples }
        /// The same in milliseconds.
        public var slideMs: Double { Double(slideSamples) / Lockstep.sampleRate * 1_000 }
    }

    /// The tightened version of one segment.
    public struct SegmentSound: Sendable, Equatable {
        /// The segment's lines, earliest first, each with the shift it got.
        public var lines: [Line]
        /// The tightened sound: `leadSamples`, then as many samples as the segment plays, then
        /// `tailSamples`. Nil when no line moves, and the segment is played from its recording.
        public var samples: [Float]?
        /// How many samples the sound has before the segment's first one: how far a line slid out of the
        /// segment at its start. 0 when every line stayed inside.
        public var leadSamples: Int
        /// How many samples the sound has after the segment's last one.
        public var tailSamples: Int

        public init(lines: [Line], samples: [Float]?, leadSamples: Int = 0, tailSamples: Int = 0) {
            self.lines = lines
            self.samples = samples
            self.leadSamples = leadSamples
            self.tailSamples = tailSamples
        }
    }

    /// The lines of every segment of the clip, one list per segment in the order of the segments, each line
    /// with the shift it gets.
    ///
    /// A line slides toward the place where its first syllable lands on the sub-beat nearest to it
    /// (`LineShift.toFirstSyllable`): `inputs.lineStrength` of the way, and no further than the settings
    /// allow. A line without syllables, or whose first syllable is in a stretch of the song without beats,
    /// stays. A syllable Max excluded does not count as the first. With `inputs.lineStrength` at 0, every
    /// line stays.
    ///
    /// A line may slide out of its segment, as far as there is room around it (`inputs.rooms`): up to the
    /// clip before or after it on the track, and up to the ends of what is kept of the song. So a line at
    /// the very start of its clip reaches its sub-beat all the same, and the clip is heard and shown that
    /// much longer.
    ///
    /// Where single syllables move too (`inputs.strength` above 0, with lines that slide less than the whole
    /// way), the first syllable moves like the others: the same share of what the slide left to its
    /// sub-beat. It has no sound before it that could give or take the move, so the whole line makes it with
    /// it, and the line says how much of its shift that is (`Line.carriedSamples`).
    ///
    /// The maps here hold the move of the line as a whole. Where the single syllables inside it go is added
    /// by `render`, which knows whether their sound could be built.
    ///
    /// A clip that is held against another track (`inputs.aimedAt`) slides each line by the one distance that
    /// suits most of its syllables (`SyllableMatch.slide`), by the same share and within the same limits.
    /// Each line then says who its syllables are paired with (`Line.partners`). Where single syllables move
    /// too, the first syllable's move onto its partner is made by the whole line at every strength: the
    /// slide suits most syllables and need not put the first one on its partner, and nothing lies before it
    /// that could give or take what is left.
    ///
    /// - Parameter levels: how loud each recording is, by recording id (see `VoiceLevels`). A segment whose
    ///   recording is missing here has no lines.
    public static func lines(of inputs: Inputs, levels: [UUID: VoiceLevels]) -> [[Line]] {
        let limit = inputs.settings.maxShiftSamples
        let targets = inputs.targets
        return inputs.segments.enumerated().map { index, segment in
            guard let recording = inputs.recordings[segment.recordingID], let level = levels[recording.id] else {
                return []
            }
            let room = inputs.rooms.indices.contains(index) ? inputs.rooms[index] : .none
            let markers = inputs.markers[recording.id] ?? []
            let excluded = recording.excludedSamples(among: markers)
            let first = max(segment.inSample, 0)
            let found = LineFinder.lines(
                in: first..<max(segment.outSample, first),
                levels: level,
                markers: markers.map(\.sample),
                pauseMs: inputs.settings.linePauseMs
            )
            return found.map { line in
                let times = line.markers.filter { !excluded.contains($0) }.map {
                    recording.songTime(ofSample: $0, offsetSamples: segment.offsetSamples)
                }
                let whole = LineShift.slide(
                    markerTimes: times, targets: targets, reachMs: inputs.settings.partnerReach * 1_000
                )
                // The strength is a share of the whole way, and the limit is counted after it: at half
                // strength a line 100 ms off slides 50 ms, not half of the 80 ms the limit would leave.
                let share = min(max(inputs.lineStrength, 0), 1)
                // Held to the limit in whole samples, so that rounding cannot push two lines that slide
                // toward each other as far as they may into each other's crossfade. Then held to the room
                // there is around the segment.
                func held(_ asked: Int) -> Int {
                    LineRenderer.allowedShift(min(max(asked, -limit), limit), of: line, in: segment, room: room)
                }
                let slide = held(TimeMap.samples(ofShift: whole * share))
                var shift = slide
                let songStart = recording.songTime(ofSample: line.startSample, offsetSamples: segment.offsetSamples)
                var partners: [Int: Double] = [:]
                if inputs.aimedAt != nil {
                    // Who each syllable is paired with, measured where the slide put it. The plan of the
                    // line's syllables asks the same question with the same slide, and gets the same answer.
                    let wanted = SyllableMoves.wanted(
                        of: line,
                        slideSamples: slide,
                        songStart: songStart,
                        targets: targets,
                        strength: inputs.strength,
                        excluded: excluded,
                        limits: inputs.settings.syllableLimits
                    )
                    partners = wanted.partners.mapValues(\.time)
                    // The first syllable's own move onto its partner, which the whole line makes with it.
                    if share > 0, inputs.strength > 0,
                       let first = line.markers.filter({ !excluded.contains($0) }).min(),
                       let own = wanted.moves[first] {
                        shift = held(slide + own)
                    }
                } else if share > 0, share < 1, inputs.strength > 0, let firstSyllable = times.min() {
                    // The first syllable's own move, measured where the slide put it, as every other
                    // syllable's is. At the whole way it already stands on its sub-beat, and with lines that
                    // stay it stays.
                    let own = SyllableMoves.wantedMove(
                        at: firstSyllable + Double(slide) / Lockstep.sampleRate,
                        grid: inputs.grid,
                        perBeat: inputs.perBeat,
                        strength: inputs.strength,
                        limits: inputs.settings.syllableLimits
                    )
                    shift = held(slide + own)
                }
                return Line(
                    line: line,
                    map: TimeMap(line: line, shiftSamples: shift),
                    songStart: songStart,
                    carriedSamples: shift - slide,
                    partners: partners
                )
            }
        }
    }

    /// The tightened version of every segment of the clip, in the order of the segments.
    ///
    /// - Parameters:
    ///   - levels: how loud each recording is, by recording id.
    ///   - recordings: the sound of the recordings, by recording id: mono samples at 48,000 Hz. They are only
    ///     read. A segment whose recording is missing here gets no sound. For a recording a voice stands in
    ///     for (`inputs.voices`), the voice's samples are read, which are in here under the voice's id: the
    ///     voice is moved exactly as the recording would be, because the lines, the plan of the syllables
    ///     and the pauses are all worked out from the recording. A voice whose samples are missing gets no
    ///     sound either: nothing is ever made from another sound than the inputs name.
    ///   - stretcher: what stretches sound where syllables run together. With one, and `inputs.strength`
    ///     above 0, single syllables are moved toward their sub-beats inside each line (`SyllableMoves`), or
    ///     onto their partners for a clip that is held against another track, and the lines that come back
    ///     say where each went. Without one, or with the strength at 0, only whole
    ///     lines slide, and the answer is sample for sample what it is without this parameter. A stretcher
    ///     is also handed in for a clip with Stretch off: its stretch limit is 0, so no plan asks for a
    ///     stretch, and what moves is built from pauses alone.
    public static func render(
        _ inputs: Inputs,
        levels: [UUID: VoiceLevels],
        recordings: [UUID: [Float]],
        stretcher: (any TimeStretcher)? = nil
    ) -> [SegmentSound] {
        let targets = inputs.targets
        return zip(inputs.segments, lines(of: inputs, levels: levels)).map { segment, slid in
            guard let sound = recordings[inputs.voices[segment.recordingID] ?? segment.recordingID] else {
                return SegmentSound(lines: slid, samples: nil)
            }
            var lines = slid
            var quantized = [[Float]?](repeating: nil, count: lines.count)
            if let stretcher, inputs.strength > 0,
               let recording = inputs.recordings[segment.recordingID], let level = levels[recording.id] {
                let excluded = recording.excludedSamples(among: inputs.markers[recording.id] ?? [])
                for index in lines.indices {
                    let map = SyllableMoves.plan(
                        line: lines[index].line,
                        shiftSamples: lines[index].shiftSamples,
                        carriedSamples: lines[index].carriedSamples,
                        songStart: lines[index].songStart,
                        targets: targets,
                        strength: inputs.strength,
                        excluded: excluded,
                        limits: inputs.settings.syllableLimits,
                        // The same loudness the sound is built from below, so the plan and the sound agree
                        // on where the pauses are.
                        levels: level
                    )
                    // A line gets the map with its syllables only together with the sound that was built
                    // from it. So what is drawn from the map is always what is heard.
                    guard let moved = LineRenderer.quantized(
                        line: lines[index].line, map: map, recording: sound, levels: level, stretcher: stretcher
                    ) else { continue }
                    lines[index].map = map
                    quantized[index] = moved
                }
            }
            guard lines.contains(where: { $0.shiftSamples != 0 }) || quantized.contains(where: { $0 != nil }) else {
                return SegmentSound(lines: lines, samples: nil)
            }
            // How far the lines reach past the segment's edges. `lines(of:)` let them go no further than
            // there is room, so this much the sound may be longer than the segment.
            var lead = 0
            var tail = 0
            for line in lines {
                let start = max(line.line.startSample, segment.inSample)
                let end = min(line.line.endSample, segment.outSample)
                guard end > start else { continue }
                lead = max(lead, segment.inSample - (start + line.shiftSamples))
                tail = max(tail, end + line.shiftSamples - segment.outSample)
            }
            return SegmentSound(
                lines: lines,
                samples: LineRenderer.render(
                    segment: segment,
                    recording: sound,
                    lines: lines.map(\.line),
                    maps: lines.map(\.map),
                    quantized: quantized,
                    lead: lead,
                    tail: tail
                ),
                leadSamples: lead,
                tailSamples: tail
            )
        }
    }
}

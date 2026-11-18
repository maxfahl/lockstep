import Foundation

/// What the tightened sound of every clip of a project depends on, worked out again only where something
/// changed.
///
/// After every edit the app asks which clips have a timing fix and what each one's sound is made from
/// (`ClipTightening.Inputs`), to see which sounds are still good. Working that out for every clip of a
/// project with several hundred of them took most of the time an edit took (15 November 2026), though a
/// Delete of thirty clips changes the inputs of a few tracks at most. This keeps the answers of the last
/// time, for each track:
///
///     var memory = TighteningInputsMemory()
///     let entries = memory.inputs(
///         in: lookup, markers: markersByRecording, settings: settings,
///         perBeat: { clip in feels.grid(for: clip, in: lookup.project, markers: markersByRecording).perBeat }
///     )
///     for entry in entries { ... entry.clip, entry.inputs, entry.stamp ... }
///
/// The entries are every clip with a timing fix that can be tightened, the takes that wait included, in the
/// order of the tracks and of each track's clips. Each holds exactly the inputs
/// `ClipTightening.Inputs(correcting:in:markers:settings:perBeat:)` gives for that clip.
///
/// What is kept, and when it is worked out again:
/// - The inputs of a clip depend on the clip, on the shown clips of its own track (the room around it), and
///   on what is the same for every clip: the recordings, the syllable markers, the beats, the settings and
///   what is left of the song. So a track whose clips are the same as last time keeps its answers.
/// - When any of the things that are the same for every clip has changed, everything is worked out again.
/// - A clip that is held against another track (`Clip.aimTrack`) depends on that track's syllables where
///   they are heard, which only the app knows and which change without the clip's own track changing. So a
///   track with such a clip is worked out every time, when the app hands those syllables in (`aimedAt`).
/// - On a track whose Voice is heard, the inputs also name the voice that stands in for each recording
///   (`voices`). A track keeps its answers while the same voices stand in for its recordings, and is worked
///   out again when one arrives or changes. A track without a Voice is asked one question for this.
///
/// Keep one for as long as a project is open. It is kept in memory only.
public struct TighteningInputsMemory: Sendable {
    /// One clip with a timing fix and what its sound is made from.
    public struct Entry: Sendable {
        public var clip: Clip
        public var inputs: ClipTightening.Inputs
        /// A number that stands for these inputs: two entries with the same stamp, from the same memory,
        /// have equal inputs. An entry that is worked out again gets a new one, also when its inputs came
        /// out equal. So whoever keeps something made from the inputs can first compare the stamps, which is
        /// one number, and compare the inputs themselves only when the stamps differ.
        public var stamp: Int
    }

    /// What a clip that aims at another track is held against in one going-through of the clips.
    public enum Aim: Sendable {
        /// The sub-beats of the song: its aim cannot be followed.
        case beat
        /// The syllables of the track it aims at, where they are heard.
        case lead([TimingTargets.Target])
        /// The syllables of a recording of that track are still being looked for. The clip cannot be
        /// tightened yet and is left out, as one whose own syllables are not found.
        case leadNotKnownYet
    }

    /// What is the same for every clip of the project.
    private struct Ground: Equatable, Sendable {
        var recordings: [Recording]
        var markers: [UUID: [SyllableMarker]]
        var grid: Grid?
        var settings: TightenSettings
        var kept: Range<Int>
    }

    /// The answers for one track, and the clips they were worked out from.
    private struct Kept: Sendable {
        var clips: [Clip]
        /// What stood in for the track's recordings when the answers were worked out.
        var voices: [UUID: UUID]
        var entries: [Entry]
    }

    private var ground: Ground?
    private var tracks: [UUID: Kept] = [:]
    private var lastStamp = 0

    /// How many times the inputs of a clip have been worked out. A test reads it to see that only what
    /// changed is worked out again.
    public private(set) var builds = 0

    public init() {}

    /// Every clip with a timing fix that can be tightened, with what its sound depends on.
    ///
    /// - Parameters:
    ///   - lookup: the project, as a lookup table.
    ///   - markers: the syllable markers of every recording, by recording id. A clip with a segment whose
    ///     recording has none here yet cannot be tightened and is left out.
    ///   - settings: the numbers of Settings > Timing.
    ///   - perBeat: how many sub-beats a beat has for a clip: 4 for sixteenths, 6 for triplets. It is asked
    ///     only for a clip whose inputs are worked out, and must depend on nothing but the clip, the
    ///     recordings, the markers and the beats.
    ///   - aimedAt: for a clip that aims at another track, what it is held against right now: the syllables
    ///     of that track where they are heard, which only the app knows. Left out, every clip is held
    ///     against the beat. It is asked only for a clip with an aim.
    ///   - voices: which voice stands in for which recording on which track. With `.none` every
    ///     clip's inputs are those of Max's own recordings. Filtered by `TrackVoices.having` with the
    ///     samples the sounds are then made from.
    public mutating func inputs(
        in lookup: ProjectLookup,
        markers: [UUID: [SyllableMarker]],
        settings: TightenSettings,
        perBeat: (Clip) -> Int,
        aimedAt: ((Clip) -> Aim)? = nil,
        voices: TrackVoices
    ) -> [Entry] {
        let project = lookup.project
        let now = Ground(
            recordings: project.recordings,
            markers: markers,
            grid: project.grid,
            settings: settings,
            kept: project.keptSamples
        )
        if ground != now {
            ground = now
            tracks = [:]
        }
        var result: [Entry] = []
        var seen: Set<UUID> = []
        for track in project.tracks {
            seen.insert(track.id)
            // What a clip with an aim is held against can change while its own track stays as it is.
            let followsAnotherTrack = aimedAt != nil
                && track.clips.contains { $0.hasTimingFix && $0.aimTrack != nil }
            let standIns = Self.standIns(on: track, voices)
            if !followsAnotherTrack, let kept = tracks[track.id], kept.clips == track.clips,
               kept.voices == standIns {
                result += kept.entries
                continue
            }
            let entries = self.entries(
                of: track, in: lookup, markers: markers, settings: settings, perBeat: perBeat, aimedAt: aimedAt,
                voices: standIns
            )
            tracks[track.id] = Kept(clips: track.clips, voices: standIns, entries: entries)
            result += entries
        }
        if tracks.count != seen.count {
            tracks = tracks.filter { seen.contains($0.key) }
        }
        return result
    }

    /// What stands in for the recordings of a track's clips with a timing fix, by recording id. Nothing, at
    /// the cost of one question, for a track whose Voice is not heard.
    private static func standIns(on track: Track, _ voices: TrackVoices) -> [UUID: UUID] {
        guard voices.isHeard(on: track) else { return [:] }
        var standIns: [UUID: UUID] = [:]
        for clip in track.clips where clip.hasTimingFix {
            for segment in clip.segments where standIns[segment.recordingID] == nil {
                standIns[segment.recordingID] = voices.soundID(forRecording: segment.recordingID, on: track)
            }
        }
        return standIns
    }

    /// The entries of one track, worked out from nothing.
    ///
    /// - Parameter voices: what stands in for the track's recordings (`standIns(on:_:)`).
    private mutating func entries(
        of track: Track,
        in lookup: ProjectLookup,
        markers: [UUID: [SyllableMarker]],
        settings: TightenSettings,
        perBeat: (Clip) -> Int,
        aimedAt: ((Clip) -> Aim)?,
        voices: [UUID: UUID]
    ) -> [Entry] {
        guard track.clips.contains(where: \.hasTimingFix) else { return [] }
        let project = lookup.project
        let shown = ShownPlaces(of: track, recording: lookup.recording)
        let kept = project.keptSamples
        var entries: [Entry] = []
        for clip in track.clips where clip.hasTimingFix {
            // A clip whose syllables are not all found yet has no lines to slide.
            guard clip.segments.allSatisfy({ markers[$0.recordingID] != nil }) else { continue }
            // As `Inputs(correcting:in:markers:settings:perBeat:aimedAt:)`: with Stretch off the stretch
            // limit is 0, and a clip is held against another track only when its aim can be followed.
            var own = settings
            if !clip.stretchesVoice { own.maxStretchPercent = 0 }
            var targets: [TimingTargets.Target]?
            if clip.aimTrack != nil, let aimedAt {
                switch aimedAt(clip) {
                case .beat:
                    break
                case .lead(let heard):
                    if project.aim(of: clip, reach: own.partnerReach) != nil { targets = heard }
                case .leadNotKnownYet:
                    continue
                }
            }
            let made = ClipTightening.Inputs(
                clip: clip,
                grid: project.grid,
                recording: lookup.recording,
                markers: markers,
                settings: own,
                // A clip that is held against another track has no use for the sub-beats and is not asked.
                perBeat: targets == nil ? perBeat(clip) : 4,
                strength: clip.syllableStrength,
                lineStrength: clip.lineStrength,
                rooms: shown.room(around: clip, kept: kept, atMost: own.maxShiftSamples),
                aimedAt: targets,
                voices: voices,
                voicesTrack: track.id
            )
            guard let made else { continue }
            builds += 1
            lastStamp += 1
            entries.append(Entry(clip: clip, inputs: made, stamp: lastStamp))
        }
        return entries
    }
}

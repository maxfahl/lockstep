import Foundation
import LockstepCore

/// The loudness of a stretch of audio, ready to draw: the lowest and highest
/// sample value in each block, from -1 to 1. The blocks are spread evenly over
/// whatever time range the owner of the levels covers.
public struct WaveformLevels: Sendable, Equatable {
    public var minimums: [Float]
    public var maximums: [Float]

    public init(minimums: [Float], maximums: [Float]) {
        self.minimums = minimums
        self.maximums = maximums
    }
}

/// A song's waveform at every level of detail, for a song row that is zoomed
/// and scrolled. The row takes the level that fits the zoom and only the blocks
/// that are on screen, so drawing costs the same for a whole song and for a
/// tenth of a second of it.
///
///     content.songWaveform = SongWaveform(pyramid)
public struct SongWaveform: Sendable, Equatable {
    public let pyramid: WaveformPyramid
    /// Tells one prepared waveform from another without comparing millions of numbers.
    private let id = UUID()

    public init(_ pyramid: WaveformPyramid) {
        self.pyramid = pyramid
    }

    public static func == (lhs: SongWaveform, rhs: SongWaveform) -> Bool {
        lhs.id == rhs.id
    }

    /// The blocks to draw for what a viewport shows, and the stretch of the
    /// song they are spread over. Nil when nothing of the song is on screen.
    func levels(in viewport: TimelineViewport) -> (levels: WaveformLevels, range: ClosedRange<Double>)? {
        let pointsPerSecond = viewport.scale.pointsPerSecond
        guard pointsPerSecond > 0 else { return nil }
        let level = pyramid.levels(forSamplesPerPoint: Lockstep.sampleRate / pointsPerSecond)
        let slice = pyramid.slice(
            level: level,
            fromSample: Int((viewport.visibleRange.lowerBound * Lockstep.sampleRate).rounded(.down)),
            toSample: Int((viewport.visibleRange.upperBound * Lockstep.sampleRate).rounded(.up))
        )
        guard !slice.minimums.isEmpty, slice.endSeconds > slice.startSeconds else { return nil }
        return (
            WaveformLevels(minimums: Array(slice.minimums), maximums: Array(slice.maximums)),
            slice.startSeconds...slice.endSeconds
        )
    }
}

/// One beat of the song's grid.
public struct BeatLine: Sendable, Equatable {
    /// Song seconds.
    public var time: Double
    /// The first beat of a bar, drawn a little stronger.
    public var isBarStart: Bool
    /// No clean drum hit backed this beat, so the app is unsure of it.
    public var isEstimated: Bool
    /// The number of the bar this beat starts, counted from 1, which the ruler
    /// writes at it. Nil lets the ruler count the bar starts itself, which
    /// comes out one too low after every bar start that has no line, such as
    /// one inside a stretch without beats. The design lab leaves it nil.
    public var barNumber: Int?

    public init(time: Double, isBarStart: Bool, isEstimated: Bool, barNumber: Int? = nil) {
        self.time = time
        self.isBarStart = isBarStart
        self.isEstimated = isEstimated
        self.barNumber = barNumber
    }
}

/// One unbroken piece of a clip: where it sits in the song and how loud it is.
public struct ClipSegment: Sendable, Equatable {
    /// Song seconds.
    public var range: ClosedRange<Double>
    /// Spread over `range`.
    public var levels: WaveformLevels

    public init(range: ClosedRange<Double>, levels: WaveformLevels) {
        self.range = range
        self.levels = levels
    }
}

/// One clip on a track. A clip joined from several pieces has one segment per
/// piece, with the space between them left empty.
public struct ClipBox: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The name shown in the clip's bar: the name Max typed, or else the
    /// start of the clip's words. Empty for a clip that has neither yet.
    public var displayName: String
    public var segments: [ClipSegment]
    public var muted: Bool
    public var isSelected: Bool
    public var takeCount: Int
    /// Counted from 1.
    public var activeTakeNumber: Int
    /// 0 leaves the clip as recorded.
    public var volumeDB: Double
    /// The clip's lines run in triplets, three to a beat.
    public var isTriplet: Bool
    /// The clip's sub-beats, which its right-click menu ticks and the panel
    /// on the right shows: 16ths, Triplets or Auto. It need not be what
    /// `isTriplet` says: a clip on Auto is in triplets when its syllables say
    /// so. Nil, which is what a clip starts with, stands for Triplets for a
    /// clip in triplets and 16ths for every other. Set it after making the
    /// clip.
    public var menuFeel: ClipMenu.Feel?
    /// How much of the clip's timing is corrected: the choice of Off, Lines
    /// or All in the panel on the right. Set it after making the clip.
    public var correction: ClipCorrection = .off
    /// How much of the correction is applied, from 0 to 1: the slider
    /// "Strength". Set it after making the clip.
    public var strength: Double = 1
    /// The clip's voice may be stretched and squeezed: the switch "Stretch".
    /// Set it after making the clip.
    public var stretches = false
    /// What the clip's correction is held against: the id of the track it
    /// aims at, which the row "Aim at" in the panel on the right names. Nil,
    /// which is what a clip starts with, is the beat. An aim that counts as
    /// the beat, such as one at a track that is gone, is nil here too. Set
    /// it after making the clip.
    public var aimTrackID: UUID?
    /// The syllable markers drawn on the clip, with the lines to judge them
    /// against: the sub-beats, or the syllables of the track the clip aims
    /// at. It is filled in only for a selected clip. Nil draws none.
    public var timingMarks: ClipTimingMarks?
    /// The clip's name is being typed: its bar shows a text field in place
    /// of the name and the marks.
    public var isBeingRenamed: Bool
    /// The clip's words are being worked out right now, so its bar says so
    /// where the name will be. Set it after making the clip.
    public var isWritingOutWords = false
    /// What the help tag of the clip's bar says: all of the clip's words,
    /// where the bar itself has room for the first few only. Nil, which is
    /// what a clip starts with, makes the tag say `displayName`. Set it
    /// after making the clip.
    public var helpText: String?
    /// The volume the clip is really played with, in dB, which sets how tall
    /// its waveform is drawn. It can differ from `volumeDB`: it has what
    /// Normalize set in it, and it is lower when the safe limit holds the
    /// clip back. Nil draws the waveform by `volumeDB`. Set it after making
    /// the clip.
    public var appliedGainDB: Double?
    /// The knobs of its track's Sound the clip turned for itself, each from 0
    /// to 1. Nil, which every knob of a clip starts as, follows the track.
    /// The panel on the right marks a knob that is set here. Set it after
    /// making the clip.
    public var ownKnobs = ClipKnobs()
    /// The effects the clip is listed with under "Effects" in the panel on
    /// the right: first the effects of its track (marks with `ofTrack`, each
    /// with what the clip changed of it), then the clip's own, its doubles
    /// and its effects on words. Only its own are drawn on the clip
    /// (`ownEffects`): one on a stretch as a band along the clip's lower
    /// edge, one on the whole clip as the mark "FX" in the clip's bar.
    /// Empty, which is what a clip starts with, for a clip without effects
    /// on a track without any. The effects of its track need only be here
    /// while the clip is selected, because only the panel shows them: the
    /// app leaves them out of every other clip, so a track's effect that is
    /// turned changes no clip that is not selected. Set it after making the
    /// clip.
    public var effects: [ClipEffectMark] = []
    /// The clip's own effects, without the ones that come from its track.
    /// The bands on the clip and the mark "FX" are about these alone.
    public var ownEffects: [ClipEffectMark] {
        effects.filter { $0.ofTrack == nil }
    }
    /// The edge of the clip that is being dragged right now, to trim the
    /// clip. It is drawn lit for as long as the drag lasts, wherever the
    /// pointer is. Nil, which is what a clip starts with, when none is.
    public var trimmedEdge: ClipEdge?

    public init(
        id: UUID,
        displayName: String,
        segments: [ClipSegment],
        muted: Bool = false,
        isSelected: Bool = false,
        takeCount: Int = 1,
        activeTakeNumber: Int = 1,
        volumeDB: Double = 0,
        isTriplet: Bool = false,
        timingMarks: ClipTimingMarks? = nil,
        isBeingRenamed: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.segments = segments
        self.muted = muted
        self.isSelected = isSelected
        self.takeCount = takeCount
        self.activeTakeNumber = activeTakeNumber
        self.volumeDB = volumeDB
        self.isTriplet = isTriplet
        self.timingMarks = timingMarks
        self.isBeingRenamed = isBeingRenamed
    }
}

/// One track and the clips on it.
public struct TrackRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var muted: Bool
    public var isSelected: Bool
    public var clips: [ClipBox]
    /// The track's own volume in dB, from -24 to +12. 0 plays its clips as
    /// loud as their own volumes say. The panel on the right shows it while
    /// the track is selected and no clip is. Set it after making the track.
    public var volumeDB: Double = 0
    /// The track's Sound: its name and its four knobs, which the panel on the
    /// right shows while the track is selected, and under each clip of the
    /// track. Nil, which every track starts as, is a track without a Sound.
    /// Set it after making the track.
    public var sound: SoundValues?
    /// The track's effects, which every clip of the track gets: the rows
    /// the panel on the right lists under "Effects" while the track is
    /// selected. They have no stretch and no `ofTrack`. Empty, which every
    /// track starts as, for a track without effects. Set it after making
    /// the track.
    public var effects: [ClipEffectMark] = []
    /// The track's Voice: its switch, the name of its preset and its two
    /// knobs, which the panel on the right shows while the track is
    /// selected, and whose preset the track's right-click menu ticks. Nil,
    /// which every track starts as, is a track that never had a Voice. Set
    /// it after making the track.
    public var voice: TrackVoice?
    /// How far the voices of the track's clips have come, which the section
    /// "Voice" says in its quiet line. Set it after making the track.
    public var voiceState: VoiceState = .ready
    /// The track's name is being typed: its header shows a text field in
    /// place of the name. Set it after making the track.
    public var isBeingRenamed = false
    /// The recording that is going to this track right now, or nil. Set it
    /// after making the track. See `TrackRecording`.
    public var recording: TrackRecording?

    public init(id: UUID, name: String, muted: Bool = false, isSelected: Bool = false, clips: [ClipBox]) {
        self.id = id
        self.name = name
        self.muted = muted
        self.isSelected = isSelected
        self.clips = clips
    }
}

/// One take of the selected clip.
public struct TakeRow: Sendable, Equatable, Identifiable {
    /// Counted from 1.
    public var number: Int
    public var displayName: String
    /// Spread over `range`, or over the selected clip's time when the take
    /// has no range of its own.
    public var levels: WaveformLevels
    public var isActive: Bool
    /// Where this take lies in the song, in song seconds. Takes of one line
    /// start and end a little apart from each other. Nil puts the take at the
    /// selected clip's time.
    public var range: ClosedRange<Double>?
    /// The words of the take. Empty when it has none yet.
    public var text: String
    /// This take is being played with the song right now, from its own Play
    /// button: the button shows a stop symbol. At most one take plays.
    public var isPlaying: Bool

    public var id: Int { number }

    public init(
        number: Int,
        displayName: String,
        levels: WaveformLevels,
        isActive: Bool,
        range: ClosedRange<Double>? = nil,
        text: String = "",
        isPlaying: Bool = false
    ) {
        self.number = number
        self.displayName = displayName
        self.levels = levels
        self.isActive = isActive
        self.range = range
        self.text = text
        self.isPlaying = isPlaying
    }
}

/// Everything the timeline and the controls around it draw. The design lab
/// fills it with made-up numbers, the real app fills it from the project.
public struct TimelineContent: Sendable, Equatable {
    public var songName: String
    /// The song is selected: its header has the mark a selected track has,
    /// and the panel on the right shows the song. Set it after making the
    /// content.
    public var songIsSelected = false
    /// Seconds: the length of the song file, whatever is cut away of it.
    public var songLength: Double
    /// What is cut away of the song and which moment of it stands at the
    /// timeline's 00:00. As it starts, nothing is cut and 00:00 is the song's
    /// first sample. Set it after making the content.
    public var songPlace = SongPlace()
    /// Spread over the whole song.
    public var songLevels: WaveformLevels
    /// The song's waveform at every level of detail. When set, the song row
    /// draws from it, at the level that fits the zoom, and `songLevels` is not
    /// used. The design lab leaves it nil and draws its made-up `songLevels`.
    public var songWaveform: SongWaveform?
    public var beatLines: [BeatLine]
    /// Stretches of the grid the app is unsure about, in song seconds.
    public var uncertainRanges: [ClosedRange<Double>]
    /// Stretches between two real beats where the app placed no beats, in song seconds.
    public var unfilledGaps: [ClosedRange<Double>]
    public var trackRows: [TrackRow]
    /// The takes of the selected clip, empty when no clip is selected.
    public var takeRows: [TakeRow]
    /// Song seconds.
    public var playheadTime: Double
    /// The tempo at the playhead, ready to show, such as "91.4".
    public var tempoText: String
    /// The playhead time, ready to show, such as "0:20".
    public var timeText: String
    /// What is drawn while something is dragged, and the loop region. Empty
    /// most of the time.
    public var dragging = TimelineDragging()
    /// Set while the song's beats are being found: the song row shows a
    /// progress ring and this text under the song's name. Nil otherwise.
    public var beatFinding: BeatFindingProgress?
    /// Draws this beat line, given by its song seconds, as if the pointer
    /// were over it. The design lab uses it for pictures. Nil follows the
    /// real pointer.
    public var shownHoveredBeat: Double?
    /// Draws this edge of the song as if the pointer were over it. The design
    /// lab uses it for pictures. Nil follows the real pointer.
    public var shownHoveredSongEdge: SongDrag.Part?
    /// When set, and the song is zoomed so far out that its beat lines would
    /// stand closer together than this many points, only the bar lines are
    /// drawn. Nil draws every beat line at every zoom, as the design lab does.
    public var closestBeatLineSpacing: CGFloat?

    public init(
        songName: String,
        songLength: Double,
        songLevels: WaveformLevels,
        beatLines: [BeatLine],
        uncertainRanges: [ClosedRange<Double>],
        unfilledGaps: [ClosedRange<Double>],
        trackRows: [TrackRow],
        takeRows: [TakeRow],
        playheadTime: Double,
        tempoText: String,
        timeText: String
    ) {
        self.songName = songName
        self.songLength = songLength
        self.songLevels = songLevels
        self.beatLines = beatLines
        self.uncertainRanges = uncertainRanges
        self.unfilledGaps = unfilledGaps
        self.trackRows = trackRows
        self.takeRows = takeRows
        self.playheadTime = playheadTime
        self.tempoText = tempoText
        self.timeText = timeText
    }
}

extension TimelineContent {
    /// The part of the song that is left after cutting, in song seconds: what
    /// the song row draws, with an edge at each end.
    public var keptRange: ClosedRange<Double> {
        songPlace.keptSeconds(ofLength: songLengthSamples)
    }

    /// The song seconds the main timeline covers: from its 00:00 to the end
    /// of the song file.
    public var shownRange: ClosedRange<Double> {
        songPlace.shownSeconds(ofLength: songLengthSamples)
    }

    private var songLengthSamples: Int {
        Int((max(songLength, 0) * Lockstep.sampleRate).rounded())
    }

    /// The content of a window that has no song yet.
    public static let empty = TimelineContent(
        songName: "",
        songLength: 0,
        songLevels: WaveformLevels(minimums: [], maximums: []),
        beatLines: [],
        uncertainRanges: [],
        unfilledGaps: [],
        trackRows: [],
        takeRows: [],
        playheadTime: 0,
        tempoText: "",
        timeText: "0:00"
    )
}

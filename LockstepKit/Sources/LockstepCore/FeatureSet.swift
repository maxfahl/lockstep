/// The features of Lockstep, one member each.
///
/// The real app shows a control only when its feature is in `built`. The design
/// lab shows everything, as if every feature were finished.
public struct FeatureSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let song = FeatureSet(rawValue: 1 << 0)
    public static let beats = FeatureSet(rawValue: 1 << 1)
    public static let click = FeatureSet(rawValue: 1 << 2)
    public static let recording = FeatureSet(rawValue: 1 << 3)
    public static let restart = FeatureSet(rawValue: 1 << 4)
    public static let takes = FeatureSet(rawValue: 1 << 5)
    public static let calibration = FeatureSet(rawValue: 1 << 6)
    public static let tracks = FeatureSet(rawValue: 1 << 7)
    public static let moveClips = FeatureSet(rawValue: 1 << 8)
    public static let clipEditing = FeatureSet(rawValue: 1 << 9)
    public static let volume = FeatureSet(rawValue: 1 << 10)
    public static let clipText = FeatureSet(rawValue: 1 << 11)
    public static let timingMarkers = FeatureSet(rawValue: 1 << 12)
    public static let tightenLines = FeatureSet(rawValue: 1 << 13)
    public static let quantize = FeatureSet(rawValue: 1 << 14)
    public static let feel = FeatureSet(rawValue: 1 << 15)
    public static let sendToDaVinci = FeatureSet(rawValue: 1 << 16)
    public static let loop = FeatureSet(rawValue: 1 << 17)
    /// The Resolve start time of the selected clip, on its own. It is shown before the
    /// rest of Send to DaVinci is finished, and `sendToDaVinci` shows it as well.
    public static let resolveStart = FeatureSet(rawValue: 1 << 18)
    /// A track's Sound and a clip's knobs: the section "Sound" in the panel on the right.
    public static let voiceSound = FeatureSet(rawValue: 1 << 19)
    /// The doubles of a clip: the section "Effects" in the panel on the right with the six kinds under
    /// "Double", the same menu in a clip's right-click menu, and the marks of effects on a clip.
    public static let doubles = FeatureSet(rawValue: 1 << 20)
    /// The effects on words: the six kinds under "On Words" in the menu that adds an effect. The section
    /// "Effects" and the marks on a clip are shown with this or with `doubles`.
    public static let wordEffects = FeatureSet(rawValue: 1 << 21)
    /// A clip's correction can aim at another track in place of the beat: the row "Aim at" under
    /// "Correction" in the panel on the right.
    public static let lockToLead = FeatureSet(rawValue: 1 << 22)
    /// Effects on a whole track: the section "Effects" of a selected track in the panel on the right, the
    /// submenu "Effects" in a track's right-click menu, a track's effects in the list of a clip, and the
    /// effects several selected clips share.
    public static let trackEffects = FeatureSet(rawValue: 1 << 23)
    /// Copy Sound and Paste Sound: the two commands in the Edit menu, and the two lines in the right-click
    /// menus of a clip and of a track.
    public static let soundCopy = FeatureSet(rawValue: 1 << 24)
    /// A track's Voice: the section "Voice" of a selected track in the panel on the right with its switch,
    /// its presets and the knobs Depth and Pitch, the submenu "Voice" of the Track menu and of a track's
    /// right-click menu, and the new states of a row in the Send to DaVinci panel. Phase 37.
    public static let trackVoice = FeatureSet(rawValue: 1 << 25)
    /// The Natural quality of a Voice: the switch "Natural" in the section "Voice", and the pane Voices of
    /// the settings window. It is built only if the measurements of phase 37 justify it.
    public static let naturalVoice = FeatureSet(rawValue: 1 << 26)

    /// Every feature. The design lab shows the app with this set.
    public static let all: FeatureSet = [
        .song, .beats, .click, .recording, .restart, .takes, .calibration, .tracks,
        .moveClips, .clipEditing, .volume, .clipText, .timingMarkers, .tightenLines,
        .quantize, .feel, .sendToDaVinci, .loop, .resolveStart, .voiceSound, .doubles, .wordEffects,
        .lockToLead, .trackEffects, .soundCopy, .trackVoice, .naturalVoice,
    ]

    /// The features finished so far. Each phase adds its member as its last change.
    public static let built: FeatureSet = [
        .song, .beats, .click, .recording, .restart, .takes, .calibration, .tracks, .moveClips, .clipEditing, .volume,
        .resolveStart, .sendToDaVinci, .clipText, .timingMarkers, .tightenLines, .quantize, .feel, .loop,
        .voiceSound, .doubles, .lockToLead, .wordEffects, .soundCopy,
        .trackEffects,
    ]
}

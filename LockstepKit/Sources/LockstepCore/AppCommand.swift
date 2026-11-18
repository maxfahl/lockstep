/// Everything the user can trigger in Lockstep, one case each.
///
/// The menu bar is built from this list, so a command is in exactly one menu
/// and nothing can be triggered only by a shortcut. Each phase adds the cases
/// of its own commands. Things done by dragging are not commands.
public enum AppCommand: String, CaseIterable, Sendable {
    case openSong
    /// A submenu, not a single action: the menu bar lists the recent projects under it.
    case openRecent
    case createClickTrack
    /// Opens the panel that exports the selected clip for DaVinci Resolve and shows where it goes there.
    case sendToDaVinci
    /// Copies the selected clips: of each line the take that is shown. While text is typed, Edit > Copy copies
    /// the text instead.
    case copyClips
    /// Puts copies of the copied clips on the selected track, the first one's start at the playhead. While text
    /// is typed, Edit > Paste pastes text instead.
    case pasteClips
    /// Copies how the selected clip sounds: its track's Sound with the clip's own knobs, and every effect it
    /// is heard with on the whole clip. With no clip selected it copies the selected track's Sound and effects.
    case copySound
    /// Makes the selected clips sound like the copied sound, or, with no clip selected, gives it to the
    /// selected track, whose clips then all follow the track.
    case pasteSound
    /// Removes the marked stretch from its track, or else the selected clips. The app
    /// gives its menu item a title that says which.
    case delete
    /// Turns snapping on or off for clips that are dragged. Its menu item is ticked while it is on.
    case snapping
    /// The four choices of Edit > Snap To, each switched on or off by itself: what a dragged clip catches
    /// on while snapping is on. Its menu item is ticked while it is on.
    case snapToGrid
    case snapToClipEdges
    case snapToPlayhead
    case snapToRecordedPlace
    /// The four units of the snapping grid, in the same submenu. The one in force is ticked.
    case snapGridSubBeats
    case snapGridHalfBeats
    case snapGridBeats
    case snapGridBars
    /// Cuts the clip under the playhead in two: every selected clip the playhead crosses,
    /// or, with no clip selected, the clip under the playhead on the selected track.
    case splitAtPlayhead
    /// Makes one clip of the selected clips, when they stand in a row on one track.
    case joinClips
    /// Takes the marked stretch of a track away again. Nothing in the project changes.
    case clearMarkedStretch
    case playStop
    /// Moves the playhead to where the last take started in the song, or to the start of the song when it
    /// already stands there or nothing has been recorded since the project was opened.
    case goBack
    /// Moves the playhead straight to the start of what is kept of the song.
    case goToStart
    /// The six steps of the playhead along the beats: to the nearest sub-beat, half beat or beat before it
    /// or after it (`PlayheadStep`).
    case previousSubBeat
    case nextSubBeat
    case previousHalfBeat
    case nextHalfBeat
    case previousBeat
    case nextBeat
    /// Move the playhead back or forth by the width the timeline shows, and the timeline with it.
    case previousScreen, nextScreen
    /// The four jumps of the playhead between clips (`ClipJump`): to the start of the clip before or after it
    /// on the selected track, and to the nearest clip on the track above or below. The clip landed on is
    /// selected.
    case previousClip
    case nextClip
    case clipAbove
    case clipBelow
    case clickOnOff
    /// Starts a take. While a take is going, the count-in included, it starts the take over.
    case record
    /// Opens the sheet that measures how late the headphones and the microphone are.
    case calibrateDelay
    /// Switches Loop on for the marked stretch, or off again.
    case loop
    /// Put the start or the end of the loop at the playhead: of the loop that plays while Loop is on, and of
    /// the marked stretch while it is off. Clear Loop In and Out takes the stretch away and switches Loop off.
    case setLoopIn, setLoopOut, clearLoopInAndOut
    case zoomIn
    case zoomOut
    /// Shows the whole song across the width of the timeline.
    case zoomToFit
    /// Makes the rows of all vocal tracks one step taller, or one step lower.
    case tallerTracks
    case lowerTracks
    case findBeatsAgain
    case halveTempo
    case doubleTempo
    case thisIsBeatOne
    /// Adds an empty track under the last one and selects it.
    case newTrack
    /// Lets the name of the selected track be typed.
    case renameTrack
    /// Makes an empty copy of the selected track right below it, with the same settings.
    case duplicateTrack
    /// The same, with a copy of every clip that plays the same recordings.
    case duplicateTrackWithClips
    /// A submenu, not a single action: the menu bar lists the other tracks under it, and
    /// choosing one moves the selected track's clips there and removes the selected track.
    case mergeInto
    /// Mutes the selected track, or lets it be heard again.
    case muteTrack
    /// Removes the selected track and its clips. Not offered for the only track.
    case deleteTrack
    /// Brings every clip on the selected track to the same loudness.
    case normalizeTrack
    /// Track > Voice: switches the selected track's Voice on or off. A track that never had a Voice gets one.
    case trackVoiceOnOff
    /// Track > Voice: gives the selected track the built-in preset Darker, Deeper or Lighter, switched on. Max's
    /// own presets are in the Voice menus of the panel and of a track's right-click menu.
    case trackVoiceDarker
    case trackVoiceDeeper
    case trackVoiceLighter
    /// The nine effects of Track > Effects: the six doubles under "Double", then an echo on quarter or eighth
    /// notes and a phone voice. Each goes on the selected track, and every clip of the track is then heard
    /// with it, also one that is recorded there later.
    case trackDoubleThick
    case trackDoubleLowFourth
    case trackDoubleLowOctave
    case trackDoubleHigh
    case trackDoubleBig
    case trackDoubleSmall
    case trackEchoQuarter
    case trackEchoEighth
    case trackPhone
    case muteClip
    /// Makes the take recorded after the active one the active take of the selected clip.
    case nextTake
    /// Makes the take recorded before the active one the active take of the selected clip.
    case previousTake
    /// Removes every take of the selected clip except the active one.
    case deleteOtherTakes
    /// Lets the name of the selected clip be typed in its bar.
    case renameClip
    /// Brings the selected clips to the same loudness.
    case normalize
    /// Has the speech model write out the words of the selected clips once more, for when the
    /// result was poor or the setting was off when they were recorded.
    case writeOutWords
    /// Clip > Correction On or Off: switches the selected clips between Off and the choice each had last,
    /// Lines or All, which is the quick way to compare a clip with its recording. Its menu item is ticked
    /// while every selected clip is corrected. It is kept under the name of the command it took the place
    /// of, Tighten Lines, so a key Max gave that one is still its key.
    case correctionOnOff = "tightenLines"
    /// The three choices of Clip > Correction, for the selected clips: as recorded, whole lines slid, or
    /// lines slid and syllables moved. The one the selected clips have is ticked.
    case correctionOff
    case correctionLines
    case correctionAll
    /// Clip > Correction > Aim at the Beat: the correction of the selected clips is held against the beat
    /// again, as every clip starts. Ticked while every selected clip is.
    case aimAtBeat
    /// A submenu, not a single action: Clip > Correction > Aim at lists the tracks the selected clips can
    /// aim at, and choosing one holds their correction against that track's syllables, so a double lands
    /// on its lead.
    case aimAt
    /// The three choices of Clip > Sub-beats, for the selected clips: a beat is counted in four parts
    /// (sixteenths), in three (triplets), or as each clip's own syllables say (Auto). The one the selected
    /// clips have is ticked.
    ///
    /// The song had three such commands and the clip a fourth, "Sub-beats: Song", until the song's choice
    /// went in phase 27. A key Max saved for one of those is kept under a name no command has, so it is
    /// never looked up.
    case clipFeelSixteenths
    case clipFeelTriplets
    case clipFeelAuto
    /// The six doubles of Clip > Effects > Double: a second voice made from the take itself. Each goes on the
    /// words that are marked in a clip, or else on the whole of every selected clip.
    case doubleThick
    case doubleLowFourth
    case doubleLowOctave
    case doubleHigh
    case doubleBig
    case doubleSmall
    /// The six effects of Clip > Effects > On Words: an echo on quarter or eighth notes, a phone voice, a
    /// stutter, a tape stop and a swell. Each goes on the words that are marked in a clip, or else on the
    /// whole of every selected clip.
    case wordEchoQuarter
    case wordEchoEighth
    case wordPhone
    case wordStutter
    case wordTapeStop
    case wordSwell

    /// The title in the menu, as the list of commands writes it.
    public var title: String {
        switch self {
        case .openSong: "Open..."
        case .openRecent: "Open Recent"
        case .createClickTrack: "Create Click Track..."
        case .sendToDaVinci: "Send to DaVinci..."
        case .copyClips: "Copy"
        case .pasteClips: "Paste"
        case .copySound: "Copy Sound"
        case .pasteSound: "Paste Sound"
        case .delete: "Delete"
        case .snapping: "Snapping"
        case .snapToGrid: "Snap To: Grid"
        case .snapToClipEdges: "Snap To: Clip Edges"
        case .snapToPlayhead: "Snap To: Playhead"
        case .snapToRecordedPlace: "Snap To: Recorded Place"
        case .snapGridSubBeats: "Snap Grid: Sub-beats"
        case .snapGridHalfBeats: "Snap Grid: Half Beats"
        case .snapGridBeats: "Snap Grid: Beats"
        case .snapGridBars: "Snap Grid: Bars"
        case .splitAtPlayhead: "Split at Playhead"
        case .joinClips: "Join Clips"
        case .clearMarkedStretch: "Clear Marked Stretch"
        case .playStop: "Play or Stop"
        case .goBack: "Go Back"
        case .goToStart: "Go to Start"
        case .previousSubBeat: "Previous Sub-beat"
        case .nextSubBeat: "Next Sub-beat"
        case .previousHalfBeat: "Previous Half Beat"
        case .nextHalfBeat: "Next Half Beat"
        case .previousBeat: "Previous Beat"
        case .nextBeat: "Next Beat"
        case .previousScreen: "Previous Screen"
        case .nextScreen: "Next Screen"
        case .previousClip: "Previous Clip"
        case .nextClip: "Next Clip"
        case .clipAbove: "Clip Above"
        case .clipBelow: "Clip Below"
        case .clickOnOff: "Click On or Off"
        case .record: "Record"
        case .calibrateDelay: "Calibrate Delay..."
        case .loop: "Loop"
        case .setLoopIn: "Set Loop In"
        case .setLoopOut: "Set Loop Out"
        case .clearLoopInAndOut: "Clear Loop In and Out"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomToFit: "Zoom to Fit"
        case .tallerTracks: "Taller Tracks"
        case .lowerTracks: "Lower Tracks"
        case .findBeatsAgain: "Find Beats Again"
        case .halveTempo: "Halve Tempo"
        case .doubleTempo: "Double Tempo"
        case .thisIsBeatOne: "This Is Beat 1"
        case .newTrack: "New Track"
        case .renameTrack: "Rename Track"
        case .duplicateTrack: "Duplicate Track"
        case .duplicateTrackWithClips: "Duplicate Track with Clips"
        case .mergeInto: "Merge Into"
        case .muteTrack: "Mute Track"
        case .deleteTrack: "Delete Track"
        case .normalizeTrack: "Normalize Track"
        case .trackVoiceOnOff: "Voice On or Off"
        case .trackVoiceDarker, .trackVoiceDeeper, .trackVoiceLighter: "Voice: \(voicePresetName ?? "")"
        case .trackDoubleThick, .trackDoubleLowFourth, .trackDoubleLowOctave, .trackDoubleHigh, .trackDoubleBig,
             .trackDoubleSmall:
            "Track Double: \(trackEffectKind?.menuName ?? "")"
        case .trackEchoQuarter, .trackEchoEighth, .trackPhone:
            "Track Effect: \(trackEffectKind?.menuName ?? "")"
        case .correctionOnOff: "Correction On or Off"
        case .correctionOff: "Correction: Off"
        case .correctionLines: "Correction: Lines"
        case .correctionAll: "Correction: All"
        case .aimAtBeat: "Aim at the Beat"
        case .aimAt: "Aim at"
        case .muteClip: "Mute Clip"
        case .nextTake: "Next Take"
        case .previousTake: "Previous Take"
        case .deleteOtherTakes: "Delete Other Takes"
        case .renameClip: "Rename Clip"
        case .normalize: "Normalize"
        case .writeOutWords: "Write Out Words Again"
        case .clipFeelSixteenths: "Sub-beats: 16ths"
        case .clipFeelTriplets: "Sub-beats: Triplets"
        case .clipFeelAuto: "Sub-beats: Auto"
        case .doubleThick, .doubleLowFourth, .doubleLowOctave, .doubleHigh, .doubleBig, .doubleSmall:
            "Double: \(effectKind?.menuName ?? "")"
        case .wordEchoQuarter, .wordEchoEighth, .wordPhone, .wordStutter, .wordTapeStop, .wordSwell:
            "On Words: \(effectKind?.menuName ?? "")"
        }
    }

    /// The submenu a command stands in, and its title there, or nil for a command that stands in its menu
    /// itself. The sub-beat choices stand in a "Sub-beats" submenu, where "Sub-beats: 16ths" is just "16ths",
    /// the three choices of the correction in a "Correction" submenu, and the doubles and the effects on
    /// words in "Effects", where each of the two has a submenu of its own (`innerSubmenu`). Track > Effects
    /// is a submenu "Effects" too, in the Track menu: the doubles in a submenu of their own and the two echoes
    /// and Phone under it.
    public var submenu: (title: String, itemTitle: String)? {
        switch self {
        case .trackVoiceOnOff: ("Voice", "Voice On or Off")
        case .trackVoiceDarker, .trackVoiceDeeper, .trackVoiceLighter: ("Voice", voicePresetName ?? "")
        case .trackDoubleThick, .trackDoubleLowFourth, .trackDoubleLowOctave, .trackDoubleHigh, .trackDoubleBig,
             .trackDoubleSmall, .trackEchoQuarter, .trackEchoEighth, .trackPhone:
            ("Effects", trackEffectKind?.menuName ?? "")
        case .doubleThick, .doubleLowFourth, .doubleLowOctave, .doubleHigh, .doubleBig, .doubleSmall,
             .wordEchoQuarter, .wordEchoEighth, .wordPhone, .wordStutter, .wordTapeStop, .wordSwell:
            ("Effects", effectKind?.menuName ?? "")
        case .correctionOff: ("Correction", "Off")
        case .correctionLines: ("Correction", "Lines")
        case .correctionAll: ("Correction", "All")
        case .aimAtBeat: ("Correction", "Aim at the Beat")
        case .aimAt: ("Correction", "Aim at")
        case .clipFeelSixteenths: ("Sub-beats", "16ths")
        case .clipFeelTriplets: ("Sub-beats", "Triplets")
        case .clipFeelAuto: ("Sub-beats", "Auto")
        case .snapToGrid: ("Snap To", "Grid")
        case .snapToClipEdges: ("Snap To", "Clip Edges")
        case .snapToPlayhead: ("Snap To", "Playhead")
        case .snapToRecordedPlace: ("Snap To", "Recorded Place")
        case .snapGridSubBeats: ("Snap To", "Grid in Sub-beats")
        case .snapGridHalfBeats: ("Snap To", "Grid in Half Beats")
        case .snapGridBeats: ("Snap To", "Grid in Beats")
        case .snapGridBars: ("Snap To", "Grid in Bars")
        default: nil
        }
    }

    /// The submenu inside its submenu that a command stands in, or nil for a command that stands in its
    /// submenu itself. Clip > Effects holds the doubles under "Double" and the effects on words under
    /// "On Words", as the menu in the panel does. Track > Effects holds the doubles under "Double" and its
    /// three other kinds in the submenu itself.
    public var innerSubmenu: String? {
        if let kind = trackEffectKind {
            return kind.isDouble ? "Double" : nil
        }
        return effectKind.map { $0.isDouble ? "Double" : "On Words" }
    }

    /// The kind of effect a command of Clip > Effects adds, or nil for every other command.
    public var effectKind: ClipEffect.Kind? {
        switch self {
        case .doubleThick: .thick
        case .doubleLowFourth: .lowFourth
        case .doubleLowOctave: .lowOctave
        case .doubleHigh: .high
        case .doubleBig: .big
        case .doubleSmall: .small
        case .wordEchoQuarter: .echoQuarter
        case .wordEchoEighth: .echoEighth
        case .wordPhone: .phone
        case .wordStutter: .stutter
        case .wordTapeStop: .tapeStop
        case .wordSwell: .swell
        default: nil
        }
    }

    /// The command that adds an effect of a kind. Every kind has one.
    public static func adding(_ kind: ClipEffect.Kind) -> AppCommand? {
        allCases.first { $0.effectKind == kind }
    }

    /// The kind of effect a command of Track > Effects gives the selected track, or nil for every other
    /// command.
    public var trackEffectKind: ClipEffect.Kind? {
        switch self {
        case .trackDoubleThick: .thick
        case .trackDoubleLowFourth: .lowFourth
        case .trackDoubleLowOctave: .lowOctave
        case .trackDoubleHigh: .high
        case .trackDoubleBig: .big
        case .trackDoubleSmall: .small
        case .trackEchoQuarter: .echoQuarter
        case .trackEchoEighth: .echoEighth
        case .trackPhone: .phone
        default: nil
        }
    }

    /// The command that gives the selected track an effect of a kind, or nil for a kind Track > Effects does
    /// not offer: stutter, tape stop and swell are for single words.
    public static func addingToTrack(_ kind: ClipEffect.Kind) -> AppCommand? {
        allCases.first { $0.trackEffectKind == kind }
    }

    /// True for a command that starts a new group inside its submenu: a dividing line stands above it.
    /// The units of the grid stand under the four things to snap to, and what the correction aims at under
    /// the three choices of how much is corrected.
    public var startsGroupInSubmenu: Bool {
        self == .snapGridSubBeats || self == .aimAtBeat || self == .trackVoiceDarker
    }

    /// The name of the built-in preset of a Voice a command of Track > Voice chooses, or nil for every other
    /// command.
    public var voicePresetName: String? {
        switch self {
        case .trackVoiceDarker: VoicePresets.builtIn[0].name
        case .trackVoiceDeeper: VoicePresets.builtIn[1].name
        case .trackVoiceLighter: VoicePresets.builtIn[2].name
        default: nil
        }
    }

    /// The unit of the snapping grid a command of Edit > Snap To chooses, or nil for every other command.
    public var snapGridUnit: SnapGridUnit? {
        switch self {
        case .snapGridSubBeats: .subBeats
        case .snapGridHalfBeats: .halfBeats
        case .snapGridBeats: .beats
        case .snapGridBars: .bars
        default: nil
        }
    }

    /// What a command of Edit > Snap To switches on and off, or nil for every other command.
    public var snapChoice: WritableKeyPath<SnapChoices, Bool>? {
        switch self {
        case .snapToGrid: \.grid
        case .snapToClipEdges: \.clipEdges
        case .snapToPlayhead: \.playhead
        case .snapToRecordedPlace: \.recordedPlace
        default: nil
        }
    }

    /// The step of the playhead a command takes, or nil for every other command.
    public var playheadStep: (direction: StepDirection, step: PlayheadStep)? {
        switch self {
        case .previousSubBeat: (.back, .subBeat)
        case .nextSubBeat: (.forward, .subBeat)
        case .previousHalfBeat: (.back, .halfBeat)
        case .nextHalfBeat: (.forward, .halfBeat)
        case .previousBeat: (.back, .beat)
        case .nextBeat: (.forward, .beat)
        default: nil
        }
    }

    /// The jump between clips a command makes, or nil for every other command.
    public var clipJump: ClipJump? {
        switch self {
        case .previousClip: .previous
        case .nextClip: .next
        case .clipAbove: .above
        case .clipBelow: .below
        default: nil
        }
    }

    /// True for a command that only changes how the timeline is shown: the zoom in time and the height of
    /// the track rows. It changes nothing in the project, so a name that is being typed stays as it is.
    public var changesOnlyTheView: Bool {
        switch self {
        case .zoomIn, .zoomOut, .zoomToFit, .tallerTracks, .lowerTracks: true
        default: false
        }
    }

    /// The feel a command of Clip > Sub-beats chooses, or nil for every other command.
    public var clipFeel: ClipFeel? {
        switch self {
        case .clipFeelSixteenths: .sixteenths
        case .clipFeelTriplets: .triplets
        case .clipFeelAuto: .auto
        default: nil
        }
    }

    /// The choice a command of Clip > Correction makes, or nil for every other command.
    public var correction: ClipTighten? {
        switch self {
        case .correctionOff: .off
        case .correctionLines: .lines
        case .correctionAll: .all
        default: nil
        }
    }

    /// The command of Clip > Correction that makes a choice.
    public static func choosing(_ correction: ClipTighten) -> AppCommand {
        switch correction {
        case .off: .correctionOff
        case .lines: .correctionLines
        case .all: .correctionAll
        }
    }

    /// The command of Clip > Sub-beats that chooses a feel.
    public static func choosing(_ feel: ClipFeel) -> AppCommand {
        switch feel {
        case .sixteenths: .clipFeelSixteenths
        case .triplets: .clipFeelTriplets
        case .auto: .clipFeelAuto
        }
    }

    /// The one menu the command is in.
    public var menu: CommandMenu {
        switch self {
        case .openSong, .openRecent, .createClickTrack, .sendToDaVinci: .file
        case .copyClips, .pasteClips: .edit
        case .copySound, .pasteSound: .edit
        case .delete, .snapping: .edit
        case .snapToGrid, .snapToClipEdges, .snapToPlayhead, .snapToRecordedPlace: .edit
        case .snapGridSubBeats, .snapGridHalfBeats, .snapGridBeats, .snapGridBars: .edit
        case .splitAtPlayhead, .joinClips, .clearMarkedStretch: .edit
        case .playStop, .goBack, .goToStart, .clickOnOff, .record: .transport
        case .previousScreen, .nextScreen: .transport
        case .previousSubBeat, .nextSubBeat, .previousHalfBeat, .nextHalfBeat, .previousBeat, .nextBeat: .transport
        case .previousClip, .nextClip, .clipAbove, .clipBelow: .transport
        case .calibrateDelay, .loop: .transport
        case .setLoopIn, .setLoopOut, .clearLoopInAndOut: .transport
        case .zoomIn, .zoomOut, .zoomToFit, .tallerTracks, .lowerTracks: .view
        case .findBeatsAgain, .halveTempo, .doubleTempo, .thisIsBeatOne: .song
        case .clipFeelSixteenths, .clipFeelTriplets, .clipFeelAuto: .clip
        case .newTrack, .renameTrack, .duplicateTrack, .duplicateTrackWithClips, .mergeInto, .muteTrack,
             .deleteTrack, .normalizeTrack: .track
        case .trackVoiceOnOff, .trackVoiceDarker, .trackVoiceDeeper, .trackVoiceLighter: .track
        case .trackDoubleThick, .trackDoubleLowFourth, .trackDoubleLowOctave, .trackDoubleHigh, .trackDoubleBig,
             .trackDoubleSmall, .trackEchoQuarter, .trackEchoEighth, .trackPhone: .track
        case .muteClip, .nextTake, .previousTake, .deleteOtherTakes, .renameClip, .normalize,
             .writeOutWords, .correctionOnOff, .correctionOff, .correctionLines, .correctionAll,
             .aimAtBeat, .aimAt: .clip
        case .doubleThick, .doubleLowFourth, .doubleLowOctave, .doubleHigh, .doubleBig, .doubleSmall: .clip
        case .wordEchoQuarter, .wordEchoEighth, .wordPhone, .wordStutter, .wordTapeStop, .wordSwell: .clip
        }
    }

    /// The shortcut the command starts with, or nil for a command without one.
    /// From phase 8 the user can change it.
    public var defaultShortcut: Shortcut? {
        switch self {
        case .openSong: Shortcut("o", modifiers: [.command])
        case .createClickTrack: Shortcut("k", modifiers: [.shift, .command])
        case .sendToDaVinci: Shortcut("e", modifiers: [.command])
        case .copyClips: Shortcut("c", modifiers: [.command])
        case .pasteClips: Shortcut("v", modifiers: [.command])
        // Copy and Paste with Option, as copying a style is in apps that have one.
        case .copySound: Shortcut("c", modifiers: [.option, .command])
        case .pasteSound: Shortcut("v", modifiers: [.option, .command])
        case .delete: Shortcut(Shortcut.delete)
        case .snapping: Shortcut("n")
        case .splitAtPlayhead: Shortcut("b", modifiers: [.command])
        case .joinClips: Shortcut("j", modifiers: [.command])
        case .clearMarkedStretch: Shortcut(Shortcut.escape)
        case .playStop: Shortcut(Shortcut.space)
        case .goBack: Shortcut(Shortcut.return)
        case .goToStart: Shortcut(Shortcut.return, modifiers: [.shift])
        case .previousSubBeat: Shortcut(Shortcut.left)
        case .nextSubBeat: Shortcut(Shortcut.right)
        case .previousHalfBeat: Shortcut(Shortcut.left, modifiers: [.command])
        case .nextHalfBeat: Shortcut(Shortcut.right, modifiers: [.command])
        case .previousBeat: Shortcut(Shortcut.left, modifiers: [.shift, .command])
        case .nextBeat: Shortcut(Shortcut.right, modifiers: [.shift, .command])
        case .previousScreen: Shortcut(Shortcut.left, modifiers: [.option])
        case .nextScreen: Shortcut(Shortcut.right, modifiers: [.option])
        // The four keys under the left hand, laid out like arrow keys.
        case .previousClip: Shortcut("a")
        case .nextClip: Shortcut("d")
        case .clipAbove: Shortcut("w")
        case .clipBelow: Shortcut("s")
        case .clickOnOff: Shortcut("c")
        case .record: Shortcut("r")
        case .zoomIn: Shortcut("+", modifiers: [.command])
        case .zoomOut: Shortcut("-", modifiers: [.command])
        // As on the Fairlight page of DaVinci Resolve.
        case .zoomToFit: Shortcut("z", modifiers: [.shift])
        // The heights are changed with Shift and scroll. The two commands are there so that
        // nothing can be reached by scrolling only.
        case .tallerTracks, .lowerTracks: nil
        case .newTrack: Shortcut("n", modifiers: [.shift, .command])
        case .duplicateTrack: Shortcut("d", modifiers: [.command])
        case .duplicateTrackWithClips: Shortcut("d", modifiers: [.shift, .command])
        case .muteTrack: Shortcut("m")
        case .deleteTrack: Shortcut(Shortcut.delete, modifiers: [.command])
        case .normalizeTrack: Shortcut("l", modifiers: [.shift, .command])
        case .correctionOnOff: Shortcut("t")
        // Off, Lines and All start without shortcuts, as the sub-beat choices do.
        case .correctionOff, .correctionLines, .correctionAll: nil
        // The aim starts without a shortcut too. Its submenu of tracks cannot have one.
        case .aimAtBeat, .aimAt: nil
        case .normalize: Shortcut("l", modifiers: [.command])
        case .muteClip: Shortcut("m", modifiers: [.shift])
        case .nextTake: Shortcut(Shortcut.down, modifiers: [.option])
        case .previousTake: Shortcut(Shortcut.up, modifiers: [.option])
        case .calibrateDelay: nil
        case .loop: Shortcut("l")
        // As in DaVinci Resolve.
        case .setLoopIn: Shortcut("i")
        case .setLoopOut: Shortcut("o")
        case .clearLoopInAndOut: Shortcut("x", modifiers: [.option])
        case .openRecent, .findBeatsAgain, .halveTempo, .doubleTempo, .thisIsBeatOne, .renameTrack,
             .mergeInto, .deleteOtherTakes, .renameClip, .writeOutWords: nil
        // The choices of what to snap to start without shortcuts, like the sub-beat choices below.
        case .snapToGrid, .snapToClipEdges, .snapToPlayhead, .snapToRecordedPlace,
             .snapGridSubBeats, .snapGridHalfBeats, .snapGridBeats, .snapGridBars: nil
        // The sub-beat choices start without shortcuts. Max gives them some in Settings if he wants.
        case .clipFeelSixteenths, .clipFeelTriplets, .clipFeelAuto: nil
        // The doubles and the effects on words start without shortcuts too.
        case .doubleThick, .doubleLowFourth, .doubleLowOctave, .doubleHigh, .doubleBig, .doubleSmall: nil
        case .wordEchoQuarter, .wordEchoEighth, .wordPhone, .wordStutter, .wordTapeStop, .wordSwell: nil
        // So do the effects of a track.
        case .trackDoubleThick, .trackDoubleLowFourth, .trackDoubleLowOctave, .trackDoubleHigh, .trackDoubleBig,
             .trackDoubleSmall, .trackEchoQuarter, .trackEchoEighth, .trackPhone: nil
        // And a track's Voice, as the design asks: its knobs have no commands either.
        case .trackVoiceOnOff, .trackVoiceDarker, .trackVoiceDeeper, .trackVoiceLighter: nil
        }
    }

    /// True for Copy and Paste of clips, which share their item in the Edit menu with the Copy and Paste of
    /// text. When one cannot act on clips, its key goes on to the text that can be selected or typed in.
    public var isAlsoTextCommand: Bool {
        self == .copyClips || self == .pasteClips
    }

    /// False for a command that is a submenu. It has no action of its own that a
    /// shortcut could trigger, so it is given none and Settings shows no field for it.
    public var takesShortcut: Bool {
        self != .openRecent && self != .mergeInto && self != .aimAt
    }

    /// True for a command that switches something on and off, or is one of a few choices. Its menu item is
    /// ticked while that is on, or while it is the choice in force. The app says whether it is.
    public var isToggle: Bool {
        self == .snapping || self == .correctionOnOff || self == .loop || self == .aimAtBeat
            || clipFeel != nil || correction != nil || snapChoice != nil || snapGridUnit != nil
    }

    /// The feature that must be built for the command to be in its menu.
    public var feature: FeatureSet {
        switch self {
        case .openSong, .openRecent, .playStop, .goBack, .zoomIn, .zoomOut, .zoomToFit: .song
        case .goToStart, .previousScreen, .nextScreen: .song
        case .tallerTracks, .lowerTracks: .recording
        case .previousSubBeat, .nextSubBeat, .previousHalfBeat, .nextHalfBeat, .previousBeat, .nextBeat: .beats
        case .previousClip, .nextClip, .clipAbove, .clipBelow: .tracks
        case .clickOnOff, .createClickTrack: .click
        case .record, .delete, .muteClip: .recording
        case .calibrateDelay: .calibration
        case .loop: .loop
        case .setLoopIn, .setLoopOut, .clearLoopInAndOut: .loop
        case .findBeatsAgain, .halveTempo, .doubleTempo, .thisIsBeatOne: .beats
        case .newTrack, .renameTrack, .duplicateTrack, .duplicateTrackWithClips, .mergeInto, .muteTrack,
             .deleteTrack: .tracks
        case .nextTake, .previousTake, .deleteOtherTakes: .takes
        case .snapping, .renameClip: .moveClips
        case .copyClips, .pasteClips: .moveClips
        case .copySound, .pasteSound: .soundCopy
        case .snapToGrid, .snapToClipEdges, .snapToPlayhead, .snapToRecordedPlace,
             .snapGridSubBeats, .snapGridHalfBeats, .snapGridBeats, .snapGridBars: .moveClips
        case .normalize, .normalizeTrack: .volume
        case .correctionOnOff, .correctionOff, .correctionLines, .correctionAll: .tightenLines
        case .aimAtBeat, .aimAt: .lockToLead
        case .splitAtPlayhead, .joinClips, .clearMarkedStretch: .clipEditing
        case .sendToDaVinci: .sendToDaVinci
        case .writeOutWords: .clipText
        case .clipFeelSixteenths, .clipFeelTriplets, .clipFeelAuto: .feel
        case .doubleThick, .doubleLowFourth, .doubleLowOctave, .doubleHigh, .doubleBig, .doubleSmall: .doubles
        case .wordEchoQuarter, .wordEchoEighth, .wordPhone, .wordStutter, .wordTapeStop, .wordSwell: .wordEffects
        // A track's effect needs the kind itself to be built too, as the same line in the panel's menu does.
        case .trackDoubleThick, .trackDoubleLowFourth, .trackDoubleLowOctave, .trackDoubleHigh, .trackDoubleBig,
             .trackDoubleSmall: [.trackEffects, .doubles]
        case .trackEchoQuarter, .trackEchoEighth, .trackPhone: [.trackEffects, .wordEffects]
        case .trackVoiceOnOff, .trackVoiceDarker, .trackVoiceDeeper, .trackVoiceLighter: .trackVoice
        }
    }

    /// The commands of one menu that are shown when `built` is finished, in
    /// the order of the list.
    public static func commands(in menu: CommandMenu, built: FeatureSet) -> [AppCommand] {
        allCases.filter { $0.menu == menu && built.isSuperset(of: $0.feature) }
    }
}

/// A menu of the menu bar that holds Lockstep commands. A phase adds a menu
/// together with its first command.
public enum CommandMenu: String, CaseIterable, Sendable {
    case file
    case edit
    case view
    case transport
    case song
    case track
    case clip

    /// The title in the menu bar.
    public var title: String {
        switch self {
        case .file: "File"
        case .edit: "Edit"
        case .view: "View"
        case .transport: "Transport"
        case .song: "Song"
        case .track: "Track"
        case .clip: "Clip"
        }
    }
}

/// A key with the modifier keys held down with it.
///
/// `key` is one lowercase character ("o", "+"), or one of the names below for
/// a key that has no character. A shortcut can be made from either spelling,
/// and from the character a key press reports, and always ends up the same:
///
///     Shortcut("K", modifiers: [.command]) == Shortcut("k", modifiers: [.command])
///     Shortcut(" ") == Shortcut(Shortcut.space)
///     Shortcut("\r").key        // "return"
///
/// `savedText` is the shortcut as one line of text, which is how it is kept
/// in the settings: "shift+command+k", "space", "command++".
public struct Shortcut: Codable, Hashable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Sendable {
        case control
        case option
        case shift
        case command
    }

    /// The space bar.
    public static let space = "space"
    /// The Home key (Fn-Left Arrow on a keyboard without one).
    public static let home = "home"
    /// The End key (Fn-Right Arrow on a keyboard without one).
    public static let end = "end"
    public static let pageUp = "pageup"
    public static let pageDown = "pagedown"
    public static let `return` = "return"
    public static let tab = "tab"
    public static let escape = "escape"
    /// The Delete key above Return, which removes backwards.
    public static let delete = "delete"
    /// The key that removes forwards (Fn-Delete on a keyboard without one).
    public static let forwardDelete = "forwarddelete"
    public static let up = "up"
    public static let down = "down"
    public static let left = "left"
    public static let right = "right"

    /// How many function keys have a name: F1 to F20.
    public static let functionKeyCount = 20

    /// The name of a function key: "f1" for F1, up to "f20".
    public static func functionKey(_ number: Int) -> String {
        "f\(number)"
    }

    /// Every name a key without a character can have.
    public static let keyNames: Set<String> = Set(namesByCharacter.values)

    /// The names of the keys without a character of their own, by the character a
    /// key press reports for them. The arrows and the keys after them report
    /// characters from a range Apple set aside for function keys.
    private static let namesByCharacter: [Character: String] = {
        var names: [Character: String] = [
            " ": space,
            "\r": `return`,
            "\t": tab,
            "\u{19}": tab,
            "\u{1B}": escape,
            "\u{7F}": delete,
            "\u{08}": delete,
            "\u{F728}": forwardDelete,
            "\u{F700}": up,
            "\u{F701}": down,
            "\u{F702}": left,
            "\u{F703}": right,
            "\u{F729}": home,
            "\u{F72B}": end,
            "\u{F72C}": pageUp,
            "\u{F72D}": pageDown,
        ]
        for number in 1...functionKeyCount {
            // F1 reports U+F704, and the others follow it in order.
            if let scalar = Unicode.Scalar(UInt32(0xF703 + number)) {
                names[Character(scalar)] = functionKey(number)
            }
        }
        return names
    }()

    public var key: String
    /// Always in the order of `Modifier.allCases` and without repeats, so two
    /// shortcuts with the same keys are equal.
    public var modifiers: [Modifier]

    public init(_ key: String, modifiers: [Modifier] = []) {
        self.key = Self.spelling(of: key)
        self.modifiers = Modifier.allCases.filter(modifiers.contains)
    }

    /// The one spelling of a key: its name when it has no character of its own,
    /// otherwise lowercase.
    private static func spelling(of key: String) -> String {
        if key.count == 1, let name = namesByCharacter[Character(key)] {
            return name
        }
        return key.lowercased()
    }

    /// True when the key is one character or one of the names above. Only such a
    /// shortcut can be shown in a menu.
    public var hasKnownKey: Bool {
        key.count == 1 || Self.keyNames.contains(key)
    }

    /// The shortcut as one line of text: the modifiers in their fixed order, then
    /// the key, joined by "+".
    public var savedText: String {
        (modifiers.map(\.rawValue) + [key]).joined(separator: "+")
    }

    /// Reads `savedText` back. The modifiers may come in any order and in any case.
    /// Nil for text that is not a shortcut.
    public init?(savedText: String) {
        var rest = Substring(savedText.lowercased())
        var modifiers: [Modifier] = []
        // A modifier is taken off the front only while something is left after it,
        // so the key "+" in "command++" stays the key.
        while let modifier = Modifier.allCases.first(where: {
            rest.hasPrefix($0.rawValue + "+") && rest.count > $0.rawValue.count + 1
        }) {
            modifiers.append(modifier)
            rest = rest.dropFirst(modifier.rawValue.count + 1)
        }
        self.init(String(rest), modifiers: modifiers)
        guard hasKnownKey else { return nil }
    }

    /// True for a shortcut without Command, Option or Control, such as Space
    /// or Shift-M. Pressing one while typing must type, not trigger a command.
    public var isPlainKey: Bool {
        !modifiers.contains { $0 != .shift }
    }

    /// True for a shortcut that a text field uses itself while it is typed in: a plain key, and an arrow,
    /// Delete, Home or End with any modifier keys, because Command-Left moves to the start of the line and
    /// Option-Delete removes a word. While a field is typed in, such a key goes to the field and not to a
    /// command.
    public var isTextKey: Bool {
        isPlainKey || Self.textMovingKeys.contains(key)
    }

    /// The keys that move through text or remove it, also with modifier keys held.
    private static let textMovingKeys: Set<String> = [left, right, up, down, home, end, delete, forwardDelete]

    /// True for Return, Escape and Tab, with or without modifier keys: the keys that a sheet, an alert and a
    /// popover answer to themselves (the default button, Cancel, the next control).
    public var isDialogKey: Bool {
        key == Self.return || key == Self.escape || key == Self.tab
    }
}

import Foundation
import LockstepCore

/// What Lockstep was asked to do when it was started, read once from its launch arguments.
///
/// - `-scratch <folder>`: keep everything in this folder instead of Max's own places.
///   Settings go to `<folder>/Settings.plist` and projects to `<folder>/Projects`.
///   `~/Music/Lockstep` and Max's settings are neither read nor written, and no last
///   project is reopened.
/// - `-open <path>`: open this file at start: a song, or a `.lockstep` project.
/// - `-silent`: nothing reaches the speakers; playback and positions work the same.
/// - `-clickFile <path>`: as soon as the beats of the opened song are found, write its click
///   file to this path, without a save panel, and say on standard error whether it worked.
/// - `-addTake <path>`: once the file given with `-open` is open, add this 48,000 Hz WAV file to
///   it as if it had just been recorded with Record pressed at the very start of the song, and
///   say on standard error whether it worked. For checking what happens after a take without
///   a microphone. It can be given more than once: the files are added in the order given, one
///   after the other. They are all aimed at the same place, so they become takes of one line.
///   `-addTake <path>@<seconds>` aims the file at that place in the song instead: its first
///   sample is heard there. A file aimed at another place than a clip that is already there is
///   no take of it, and the clip gives way where the new one covers it.
/// - `-playhead <seconds>`: once the file given with `-open` is open, and the takes given with
///   `-addTake` are in it, put the playhead at this place in the song, and say so on standard
///   error. For an agent that cannot click in the timeline. It counts only together with `-scratch`.
/// - `-songVolume <dB>`: once the file given with `-open` is open, select the song and give it this
///   volume (from -24 to 0), through the same code as a click on the song's header and the volume
///   slider in the panel on the right, and say so on standard error. For an agent that cannot
///   click or drag. It counts only together with `-scratch`.
/// - `-trackVolume <dB>`: once the file given with `-open` is open, and the takes given with
///   `-addTake` are in it, select the first track and give it this volume (from -24 to +12),
///   through the same code as a click on the track's header and the volume slider in the panel on
///   the right, and say so on standard error. For an agent that cannot click or drag. It counts
///   only together with `-scratch`.
/// - `-trackVoice <preset or knobs>`: once the file given with `-open` is open and the takes given
///   with `-addTake` are in it, and before `-tighten`, `-strength` and `-stretch`, give the first track
///   that Voice (a preset's name such as `Darker`, or knobs such as `depth=8,pitch=-1.5`) through the
///   code of the panel's menu and knobs, wait until the voices of the track's shown clips are made
///   (ten minutes at most), and say so on standard error. It counts only together with `-scratch`.
/// - `-trackVoiceOff`: after everything else, switch the first track's Voice off through the code of
///   the switch, and say so. It takes no value, so it goes last. It counts only together with `-scratch`.
/// - `-trackSound <preset name>`: once the file given with `-open` is open, the takes given with
///   `-addTake` are in it and `-tighten`, `-strength` and `-stretch` have acted, give the first track
///   that preset as its Sound (a built-in one, or one of the scratch folder's own, which gives the
///   track its effects too), through the code the Sound menu in the panel on the right
///   uses, wait until the finished sounds of the track's clips are made, and say so on standard
///   error. For an agent that cannot open the menu and cannot hear. It counts only together with
///   `-scratch`.
/// - `-clipKnob <knob>=<percent>`: after `-trackSound`, turn that knob (`squeeze`, `tone`, `warmth`
///   or `space`, from 0 to 100) for the first clip of the first track itself, through the code the
///   knob in the panel uses, and say on standard error what the clip has and what its track has. It
///   counts only together with `-scratch`.
/// - `-trackEffect <kind>`: after `-trackSound` and `-clipKnob`, select the first track and give it
///   that effect (`thick`, `lowFourth`, `lowOctave`, `high`, `big`, `small`, `echoQuarter`,
///   `echoEighth` or `phone`), which every clip of the track is then heard with, through the code the
///   "+" of a track's Effects in the panel uses, wait until the finished sounds of the track's clips
///   are made, and say so on standard error. An echo waits for the song's beats first. Given several
///   times, the effects are added in that order. It counts only together with `-scratch`.
/// - `-clipTrackEffect <kind>=<dB>` or `-clipTrackEffect <kind>=off`: after every `-trackEffect`, give
///   the first clip of the first track its own level (from -24 to +6) for the track's first effect of
///   that kind, or switch that effect off for the clip, through the code its row in the panel uses,
///   and say on standard error what the clip has and what its track has. It may be given several
///   times. It counts only together with `-scratch`.
/// - `-double <kind>` or `-double <kind>@<from>-<to>`: after `-trackSound` and `-clipKnob`, give the
///   first clip of the first track that double (`thick`, `lowFourth`, `lowOctave`, `high`, `big` or
///   `small`), on the whole clip or on the stretch between those song seconds, whose ends catch on
///   syllables as a marked stretch's do, through the code the menu uses, wait until the clip's
///   finished sound is made, and say so on standard error. Given several times, the doubles are
///   added in that order. It counts only together with `-scratch`.
/// - `-wordEffect <kind>` or `-wordEffect <kind>@<from>-<to>`: after the doubles, give the first clip
///   of the first track that effect on words (`echoQuarter`, `echoEighth`, `phone`, `stutter`,
///   `tapeStop` or `swell`) the same way, and say so on standard error, for an echo with the song
///   seconds of every repeat. An echo, a stutter and a swell wait for the song's beats first. Given
///   several times, they are added in that order. It counts only together with `-scratch`.
/// - `-pasteSound clips` or `-pasteSound track`: after `-trackSound`, `-clipKnob` and every `-double`
///   and `-wordEffect`, copy the sound of the first clip of the first track (Copy Sound) and paste it
///   on every other shown clip of that track, or on the track itself (Paste Sound), and say on
///   standard error what was copied, how many clips changed and the undo step. Only with `-scratch`.
/// - `-sendClip <path>`: once the file given with `-open` is open, and the takes given with
///   `-addTake` are in it, export the first clip of the first track for DaVinci Resolve exactly as
///   the Send to DaVinci panel would, write the file to this path, and say on standard error where
///   the clip goes. The list for the Lockstep script in DaVinci Resolve is written as well, to
///   `DaVinci/clips.lua` in the scratch folder, and a second line says so. For an agent that cannot
///   select a clip. It counts only together with `-scratch`, and the path must lie inside the scratch folder.
///   The clip is sent with its sound, as the switch "With sound" of the panel stands in a fresh scratch
///   folder, and after `-trackSound` and `-clipKnob` have acted.
/// - `-sendDry`: together with `-sendClip`, switch "With sound" off first, through the code the switch in
///   the Send to DaVinci panel uses, so the clip is sent dry. It counts only together with `-scratch`.
/// - `-clipText <text>`: once the file given with `-open` is open, and the takes given with
///   `-addTake` are in it, put these words on the first clip of the first track, the way the
///   speech model's answer would, and say so on standard error. For an agent, whose run never
///   loads the speech model. It counts only together with `-scratch`.
/// - `-lockedDouble <path>`: once the file given with `-open` is open, the takes given with `-addTake`
///   are in it and `-tighten`, `-strength` and `-stretch` have acted on the first track, add a second
///   track with this 48,000 Hz WAV file on it as a take aimed at the very start of the song, give its
///   clip All at 100 % aimed at the first track (with Stretch on when `-stretch` is given), wait for
///   its sound, and say on standard error where each of its syllables is, where its partner in the
///   first track is heard or that it has none, how far it moved, and how many note ends were matched.
///   For an agent, which cannot choose from the row "Aim at" and cannot hear. It counts only together
///   with `-scratch`.
/// - `-tighten`: once the file given with `-open` is open, and the takes given with `-addTake` are
///   in it, choose Lines at 100 % for every clip of the first track, and say on standard error where
///   each line that was found starts in the song and how many milliseconds it slid. `-sendClip` then
///   sends the tightened clip. For an agent, which cannot press the button and cannot hear. It counts
///   only together with `-scratch`.
/// - `-strength <percent>`: once the file given with `-open` is open, and the takes given with
///   `-addTake` are in it, choose All for every clip of the first track with this many percent (0 to
///   100) as its strength, wait for the sound to be made, and say on standard error where each
///   syllable that moved was recorded in the song, how many milliseconds it moved by itself, and how
///   many runs of syllables went through the stretcher. The strength also scales the slide of the
///   lines. `-sendClip` then sends the clip with its syllables moved. For an agent, which cannot drag
///   the slider and cannot hear. It counts only together with `-scratch`.
/// - `-stretch`: together with `-tighten` or `-strength`, also switch Stretch on for those clips, so
///   their voice may be stretched up to the limit in Settings > Timing. Without it the clips keep
///   Stretch off, as every clip starts, and `-strength` reports no run stretched. It counts only
///   together with `-scratch`.
/// - `-loop <start>,<end>`: once the beats of the file given with `-open` are found, switch Loop on
///   for this stretch of the song, given as two numbers of seconds with a comma between them, as if
///   the stretch had been marked and Loop pressed, and say on standard error which region it became.
///   For an agent that cannot drag in the timeline. It counts only together with `-scratch`.
/// - `-loopTake <path>`: once Loop is on for the stretch given with `-loop`, add this 48,000 Hz WAV
///   file as if it had just been recorded with Loop on and the count-in off, its first sample heard
///   on the loop's start: every time round in it becomes a take, and one line on standard error says
///   where each landed. For checking what happens after a loop recording without a microphone. It
///   counts only together with `-scratch` and `-loop`.
/// - `-recordTake <path>`: once the file given with `-open` is open, its beats are found and the other
///   launch arguments have acted, make a take as Max does, with this 48,000 Hz WAV file in the microphone's
///   place: Record, the count-in, some seconds of recording, Record again for a restart, once more with the
///   dropped attempt kept, then Stop, and say on standard error how each step went. The microphone is never
///   opened and macOS is never asked for it (`TransportModel+RecordTake.swift`). For checking the code that records
///   without a microphone. It counts only together with `-scratch` and `-open`.
/// - `-recordSpeed <percent>`: 90 or 85. Once the file given with `-open` is open, choose that recording
///   speed, as the Record speed row of the click menu does, so the take of `-recordTake` is recorded
///   slower. It counts only together with `-scratch`.
/// - `-deleteClip`: once the file given with `-open` is open, the takes given with `-addTake` are in
///   it, and what `-tighten` and `-strength` asked for is done, select the first clip of the first
///   track and delete it the way the Delete key does, and say on standard error how many milliseconds
///   after the key press each step was done, the drawing of the window included. For an agent that
///   measures how fast an edit is, and cannot select a clip. It counts only together with `-scratch`.
/// - `-pasteClip`: once the file given with `-open` is open, the takes given with `-addTake` are in
///   it and the playhead is where `-playhead` put it, select the first clip of the first track, copy
///   it and paste it as Edit > Copy and Edit > Paste do, and say on standard error where the copy
///   landed. For an agent that cannot select a clip. It counts only together with `-scratch`.
/// - `-selectRect <start>,<end>,<tracks>`: once the file given with `-open` is open, the takes given with
///   `-addTake` are in it and `-bigProject` has built its project, make the drag that selects clips on
///   several tracks: from the first track at the first song second to the second one, that many tracks
///   down counted from the first, through the code the pointer's drag uses, and say on standard error how
///   many clips are selected on how many tracks (`ClipEditingModel+SelectRect.swift`). With 1 for the
///   tracks the drag stays in its row and marks a stretch. For an agent that cannot drag. It counts
///   only together with `-scratch`.
/// - `-middleDrag`: once the file given with `-open` is open, the takes given with `-addTake` are in it and
///   the beats are found, add the clips of Debug > Add Test Clips, zoom in, make a few drags with the middle
///   mouse button (and one with two fingers on the trackpad) through the timeline's own catcher, and say on
///   standard error how the window kept up with each. For an agent that cannot move the pointer
///   (`TimelineViewModel.swift`). It counts only together with `-scratch`.
/// - `-bigProject`: once the file given with `-open` is open and its beats are found, fill the project up to
///   a size like Max's own: twenty tracks, four hundred lines, about two hundred and fifty more takes waiting
///   behind them, each take with a recording, words and a correction, and say on standard error what was
///   made and how long it took (`BigTestProject.swift`). For measuring edits in a project that is big enough
///   to be slow. It counts only together with `-scratch` and `-open`.
/// - `-timeEdits`: once `-bigProject` has built its project, or the takes given with `-addTake` are in, make
///   a fixed list of edits through the code the pointer and the keys use, and say on standard error how many
///   milliseconds each took, the drawing of the window included (`ClipEditingModel+TimeEdits.swift`). It
///   counts only together with `-scratch`.
///
/// The rest of the app reads `LaunchOptions.current`:
/// - `settings` wherever it would use `UserDefaults.standard`.
/// - `fileToOpen`: open it through the app's own open function after the window is up.
/// - `isSilent`: create the engine as `PlaybackEngine(silent: LaunchOptions.current.isSilent)`.
/// - `projectsFolder(in:)`: where a new song's project is made.
/// - `scratchFolder`: when set, never reopen the last project.
/// - `clickFile`: where the click file goes once the beats are found, without asking.
/// - `takesToAdd`: the sound files to add as takes once the first file is open, in this order.
struct LaunchOptions {
    /// The folder given with `-scratch`, or nil when Lockstep runs for Max.
    let scratchFolder: URL?
    /// The file given with `-open`, or nil.
    let fileToOpen: URL?
    /// True when `-silent` was given.
    let isSilent: Bool
    /// The path given with `-clickFile`, or nil.
    let clickFile: URL?
    /// The files given with `-addTake`, in the order given. Empty when there was none.
    let takesToAdd: [TakeToAdd]

    /// One file given with `-addTake`, and the place in the song it is aimed at.
    struct TakeToAdd {
        var url: URL
        /// The place, in song seconds: the number after "@", or 0, the very start of the song.
        var place: Double
    }
    /// The place in the song given with `-playhead`, in seconds, or nil. Always nil without `-scratch`.
    let playhead: Double?
    /// The volume for the song given with `-songVolume`, in dB, or nil. Always nil without `-scratch`.
    let songVolume: Double?
    /// The volume for the first track given with `-trackVolume`, in dB, or nil. Always nil without `-scratch`.
    let trackVolume: Double?
    /// The Voice given with `-trackVoice`: a preset's name or knobs, or nil. Always nil without `-scratch`.
    let trackVoice: String?
    /// True when `-trackVoiceOff` was given. Always false without `-scratch`.
    let trackVoiceOff: Bool
    /// The name of the preset given with `-trackSound`, or nil. Always nil without `-scratch`.
    let trackSound: String?
    /// The knob and its value, from 0 to 1, given with `-clipKnob`, or nil. Always nil without `-scratch`.
    let clipKnob: (knob: SoundKnob, value: Double)?
    /// The kinds given with `-trackEffect`, in the order they were given. Always empty without `-scratch`.
    let trackEffects: [ClipEffect.Kind]
    /// What was given with `-clipTrackEffect`, in the order it was given: the kind of the track's effect,
    /// and the clip's own level for it in dB, or nil to switch it off for the clip. Always empty without
    /// `-scratch`.
    let clipTrackEffects: [(kind: ClipEffect.Kind, levelDb: Double?)]
    /// The doubles given with `-double`, in the order they were given: each kind, and the stretch of
    /// the song it goes on in song seconds, or nil for the whole clip. Always empty without `-scratch`.
    let doubles: [(kind: ClipEffect.Kind, stretch: Range<Double>?)]
    /// The effects on words given with `-wordEffect`, in the order they were given, each as a double
    /// of `doubles` is. Always empty without `-scratch`.
    let wordEffects: [(kind: ClipEffect.Kind, stretch: Range<Double>?)]
    /// Where `-pasteSound` pastes the sound of the first clip of the first track: on the other shown
    /// clips of that track, or on the track. Nil when it was not given. Always nil without `-scratch`.
    let pasteSound: PasteSoundTarget?

    /// What `-pasteSound` is given.
    enum PasteSoundTarget: String {
        case clips, track
    }
    /// The path given with `-sendClip`, or nil. Always nil without `-scratch`.
    let clipToSend: URL?
    /// True when `-sendDry` was given. Always false without `-scratch`.
    let sendsDry: Bool
    /// The words given with `-clipText`, or nil. Always nil without `-scratch`.
    let clipText: String?
    /// True when `-tighten` was given. Always false without `-scratch`.
    let tightens: Bool
    /// The strength given with `-strength`, from 0 to 1, or nil. Always nil without `-scratch`.
    let strength: Double?
    /// True when `-stretch` was given. Always false without `-scratch`.
    let stretches: Bool
    /// The path given with `-lockedDouble`, or nil. Always nil without `-scratch`.
    let lockedDouble: URL?
    /// The stretch given with `-loop`, in song seconds, or nil. Always nil without `-scratch`.
    let loop: ClosedRange<Double>?
    /// The path given with `-loopTake`, or nil. Always nil without `-scratch` and `-loop`.
    let loopTake: URL?
    /// The path given with `-recordTake`, or nil. Always nil without `-scratch` and `-open`.
    let recordTake: URL?
    /// The speed given with `-recordSpeed`, in percent (90 or 85), or nil. Always nil without `-scratch`.
    let recordSpeed: Int?
    /// True when `-deleteClip` was given. Always false without `-scratch`.
    let deletesClip: Bool
    /// True when `-pasteClip` was given. Always false without `-scratch`.
    let pastesClip: Bool
    /// What `-selectRect` gave: where the drag starts and ends, in song seconds, and how many tracks it
    /// covers, counted from the first. Nil when it was not given. Always nil without `-scratch`.
    let selectRect: (start: Double, end: Double, tracks: Int)?
    /// True when `-middleDrag` was given. Always false without `-scratch`.
    let dragsTimeline: Bool
    /// True when `-bigProject` was given. Always false without `-scratch` and `-open`.
    let buildsBigProject: Bool
    /// True when `-timeEdits` was given. Always false without `-scratch`.
    let timesEdits: Bool
    /// Where settings are kept: the scratch folder's own store, or Max's standard settings.
    let settings: UserDefaults

    var isScratch: Bool { scratchFolder != nil }

    /// Where projects go when no other folder is chosen in Settings, or when the chosen
    /// one cannot be used: `Projects` in the scratch folder, or `~/Music/Lockstep` when
    /// Lockstep runs for Max.
    var usualProjectsFolder: URL {
        if let scratchFolder {
            return scratchFolder.appendingPathComponent("Projects", isDirectory: true)
        }
        return URL.musicDirectory.appendingPathComponent("Lockstep", isDirectory: true)
    }

    /// The projects folder as Settings has it. Nothing on disk is touched.
    ///
    /// A scratch run keeps to its own folder: a folder from its settings counts only when
    /// it lies inside the scratch folder, and anything else, the default included, is
    /// `Projects` in the scratch folder.
    @MainActor
    func chosenProjectsFolder(in settings: AppSettings) -> URL {
        let chosen = settings.projectFolder
        guard let scratchFolder else { return chosen }
        let isInside = chosen.path.hasPrefix(scratchFolder.path + "/")
        return isInside ? chosen : usualProjectsFolder
    }

    /// Where the projects of new songs are made: the folder chosen in Settings, which is
    /// made if it is not there yet, or the usual folder when the chosen one cannot be
    /// made or written to. This is the only place that chooses, so a scratch run cannot
    /// end up among Max's projects.
    @MainActor
    func projectsFolder(in settings: AppSettings) -> ProjectsFolder {
        let chosen = chosenProjectsFolder(in: settings)
        let files = FileManager.default
        do {
            try files.createDirectory(at: chosen, withIntermediateDirectories: true)
        } catch {
            return ProjectsFolder(url: usualProjectsFolder, isFallback: chosen != usualProjectsFolder)
        }
        guard files.isWritableFile(atPath: chosen.path) else {
            return ProjectsFolder(url: usualProjectsFolder, isFallback: chosen != usualProjectsFolder)
        }
        return ProjectsFolder(url: chosen, isFallback: false)
    }

    /// Read on the main actor, where the window and the app's model live, because the
    /// settings store cannot be handed between threads.
    @MainActor static let current = LaunchOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        var scratchPath: String?
        var openPath: String?
        var clickPath: String?
        var takePaths: [String] = []
        var playheadSeconds: Double?
        var songVolumeDb: Double?
        var trackVolumeDb: Double?
        var trackSoundName: String?
        var trackVoiceAsked: String?
        var trackVoiceOffAsked = false
        var clipKnobAsked: (knob: SoundKnob, value: Double)?
        var trackEffectsAsked: [ClipEffect.Kind] = []
        var clipTrackEffectsAsked: [(kind: ClipEffect.Kind, levelDb: Double?)] = []
        var doublesAsked: [(kind: ClipEffect.Kind, stretch: Range<Double>?)] = []
        var wordEffectsAsked: [(kind: ClipEffect.Kind, stretch: Range<Double>?)] = []
        var pasteSoundAsked: PasteSoundTarget?
        var sendPath: String?
        var sendDry = false
        var words: String?
        var silent = false
        var tighten = false
        var strengthPercent: Double?
        var stretch = false
        var loopStretch: ClosedRange<Double>?
        var loopTakePath: String?
        var lockedDoublePath: String?
        var recordTakePath: String?
        var recordSpeedPercent: Int?
        var deleteClip = false
        var pasteClip = false
        var selectRectAsked: (start: Double, end: Double, tracks: Int)?
        var middleDrag = false
        var bigProject = false
        var timeEdits = false

        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let argument = arguments[index]
            let next = arguments.index(after: index)
            switch argument {
            case "-scratch":
                scratchPath = Self.value(after: argument, at: next, in: arguments)
                index = next
            case "-open":
                openPath = Self.value(after: argument, at: next, in: arguments)
                index = next
            case "-silent":
                silent = true
            case "-clickFile":
                clickPath = Self.value(after: argument, at: next, in: arguments)
                index = next
            case "-addTake":
                takePaths.append(Self.value(after: argument, at: next, in: arguments))
                index = next
            case "-playhead":
                guard let seconds = Double(Self.value(after: argument, at: next, in: arguments)), seconds.isFinite
                else { Self.stop("-playhead needs a number of seconds after it") }
                playheadSeconds = seconds
                index = next
            case "-songVolume":
                guard let volumeDb = Double(Self.value(after: argument, at: next, in: arguments)), volumeDb.isFinite
                else { Self.stop("-songVolume needs a number of dB after it") }
                songVolumeDb = volumeDb
                index = next
            case "-trackVolume":
                guard let volumeDb = Double(Self.value(after: argument, at: next, in: arguments)), volumeDb.isFinite
                else { Self.stop("-trackVolume needs a number of dB after it") }
                trackVolumeDb = volumeDb
                index = next
            case "-trackVoice":
                trackVoiceAsked = Self.value(after: argument, at: next, in: arguments)
            case "-trackVoiceOff":
                trackVoiceOffAsked = true
            case "-trackSound":
                trackSoundName = Self.value(after: argument, at: next, in: arguments)
                index = next
            case "-clipKnob":
                let parts = Self.value(after: argument, at: next, in: arguments).split(separator: "=")
                guard parts.count == 2, let knob = SoundKnob(rawValue: String(parts[0])),
                      let percent = Double(parts[1]), (0...100).contains(percent)
                else { Self.stop("-clipKnob needs squeeze, tone, warmth or space, then = and a number from 0 to 100") }
                clipKnobAsked = (knob, percent / 100)
                index = next
            case "-trackEffect":
                guard let kind = ClipEffect.Kind(rawValue: Self.value(after: argument, at: next, in: arguments)),
                      AppCommand.addingToTrack(kind) != nil
                else {
                    Self.stop(
                        "-trackEffect needs thick, lowFourth, lowOctave, high, big, small, echoQuarter, echoEighth or phone"
                    )
                }
                trackEffectsAsked.append(kind)
                index = next
            case "-clipTrackEffect":
                let parts = Self.value(after: argument, at: next, in: arguments).split(separator: "=")
                guard parts.count == 2, let kind = ClipEffect.Kind(rawValue: String(parts[0])),
                      parts[1] == "off" || Double(parts[1]).map({ (-24...6).contains($0) }) == true
                else {
                    Self.stop(
                        "-clipTrackEffect needs the kind of an effect of the track, then = and a number of dB "
                            + "from -24 to 6, or off, like thick=-6 or phone=off"
                    )
                }
                clipTrackEffectsAsked.append((kind, Double(parts[1])))
                index = next
            case "-double":
                guard let asked = Self.effect(Self.value(after: argument, at: next, in: arguments)), asked.kind.isDouble
                else {
                    Self.stop(
                        "-double needs thick, lowFourth, lowOctave, high, big or small, "
                            + "alone or with @ and two song seconds with a dash between, like lowOctave@1.2-1.9"
                    )
                }
                doublesAsked.append(asked)
                index = next
            case "-wordEffect":
                guard let asked = Self.effect(Self.value(after: argument, at: next, in: arguments)), !asked.kind.isDouble
                else {
                    Self.stop(
                        "-wordEffect needs echoQuarter, echoEighth, phone, stutter, tapeStop or swell, "
                            + "alone or with @ and two song seconds with a dash between, like echoQuarter@1.2-1.9"
                    )
                }
                wordEffectsAsked.append(asked)
                index = next
            case "-pasteSound":
                guard let target = PasteSoundTarget(rawValue: Self.value(after: argument, at: next, in: arguments))
                else { Self.stop("-pasteSound needs clips or track") }
                pasteSoundAsked = target
                index = next
            case "-sendClip":
                sendPath = Self.value(after: argument, at: next, in: arguments)
                index = next
            case "-sendDry":
                sendDry = true
            case "-clipText":
                words = Self.value(after: argument, at: next, in: arguments)
                index = next
            case "-tighten":
                tighten = true
            case "-stretch":
                stretch = true
            case "-deleteClip":
                deleteClip = true
            case "-pasteClip":
                pasteClip = true
            case "-selectRect":
                let parts = Self.value(after: argument, at: next, in: arguments).split(separator: ",")
                guard parts.count == 3, let start = Double(parts[0]), let end = Double(parts[1]),
                      let tracks = Int(parts[2]), start.isFinite, end.isFinite, tracks >= 1
                else {
                    Self.stop("-selectRect needs two numbers of seconds and a number of tracks after it, as in -selectRect 2,8,3")
                }
                selectRectAsked = (start, end, tracks)
                index = next
            case "-middleDrag":
                middleDrag = true
            case "-bigProject":
                bigProject = true
            case "-timeEdits":
                timeEdits = true
            case "-strength":
                guard let percent = Double(Self.value(after: argument, at: next, in: arguments)),
                      (0...100).contains(percent)
                else { Self.stop("-strength needs a number from 0 to 100 after it") }
                strengthPercent = percent
                index = next
            case "-loopTake":
                loopTakePath = Self.value(after: argument, at: next, in: arguments)
                index = next
            case "-lockedDouble":
                lockedDoublePath = Self.value(after: argument, at: next, in: arguments)
                index = next
            case "-recordTake":
                recordTakePath = Self.value(after: argument, at: next, in: arguments)
                index = next
            case "-recordSpeed":
                guard let percent = Int(Self.value(after: argument, at: next, in: arguments)),
                      SlowTime.percents.contains(percent), percent < 100
                else { Self.stop("-recordSpeed needs 90 or 85 after it") }
                recordSpeedPercent = percent
                index = next
            case "-loop":
                let ends = Self.value(after: argument, at: next, in: arguments).split(separator: ",").map { Double($0) }
                guard ends.count == 2, let from = ends[0], let to = ends[1], from.isFinite, to.isFinite, to > from
                else { Self.stop("-loop needs two numbers of seconds after it, as in -loop 12.5,20") }
                loopStretch = from...to
                index = next
            default:
                break
            }
            index = arguments.index(after: index)
        }

        isSilent = silent
        fileToOpen = openPath.map(Self.fileURL(for:))
        clickFile = clickPath.map(Self.fileURL(for:))
        takesToAdd = takePaths.map(Self.takeToAdd(from:))
        // Only an agent's run moves the playhead by itself. Max's own start never does.
        playhead = scratchPath == nil ? nil : playheadSeconds
        // The same for the song's volume: in Max's own run only the slider in the window sets it.
        songVolume = scratchPath == nil ? nil : songVolumeDb
        trackVolume = scratchPath == nil ? nil : trackVolumeDb
        // The same for a track's Sound and a clip's knob: in Max's own run only the panel sets them.
        trackSound = scratchPath == nil ? nil : trackSoundName
        // A track's Voice too: in Max's own run only the panel and the menus set it.
        trackVoice = scratchPath == nil ? nil : trackVoiceAsked
        trackVoiceOff = scratchPath != nil && trackVoiceOffAsked
        clipKnob = scratchPath == nil ? nil : clipKnobAsked
        // The same for a track's effect and a clip's change of it: in Max's own run only the panel and
        // the menus make them.
        trackEffects = scratchPath == nil ? [] : trackEffectsAsked
        clipTrackEffects = scratchPath == nil ? [] : clipTrackEffectsAsked
        // The same for a double: in Max's own run only the menus add one.
        doubles = scratchPath == nil ? [] : doublesAsked
        wordEffects = scratchPath == nil ? [] : wordEffectsAsked
        pasteSound = scratchPath == nil ? nil : pasteSoundAsked
        // The same for sending a clip: only an agent's run writes a file nobody asked for in the window.
        clipToSend = scratchPath == nil ? nil : sendPath.map(Self.fileURL(for:))
        // And for sending dry: in Max's own run only the switch in the Send to DaVinci panel chooses it.
        sendsDry = scratchPath != nil && sendDry
        // And for words on a clip: in Max's own run only the speech model writes them.
        clipText = scratchPath == nil ? nil : words
        // And for Lines: in Max's own run only the buttons in the window choose it.
        tightens = scratchPath != nil && tighten
        // And for the strength: in Max's own run only the slider in the window sets it.
        strength = scratchPath == nil ? nil : strengthPercent.map { $0 / 100 }
        // And for Stretch: in Max's own run only the switch in the window sets it.
        stretches = scratchPath != nil && stretch
        // And for a double locked to its lead: in Max's own run only he records one and aims it.
        lockedDouble = scratchPath == nil ? nil : lockedDoublePath.map(Self.fileURL(for:))
        // And for Loop: in Max's own run only the Loop command switches it.
        loop = scratchPath == nil ? nil : loopStretch
        loopTake = scratchPath == nil || loopStretch == nil ? nil : loopTakePath.map(Self.fileURL(for:))
        // And for a take from a file: in Max's own run a take is made with the microphone and by him.
        // Without a file to open there is no song to record over.
        recordTake = scratchPath == nil || openPath == nil ? nil : recordTakePath.map(Self.fileURL(for:))
        // And for the recording speed: in Max's own run only the click menu chooses it.
        recordSpeed = scratchPath == nil ? nil : recordSpeedPercent
        // And for deleting a clip: in Max's own run only he deletes.
        deletesClip = scratchPath != nil && deleteClip
        // And for pasting a clip: in Max's own run only he copies and pastes.
        pastesClip = scratchPath != nil && pasteClip
        // And for a rectangle that selects clips: in Max's own run only his pointer drags one.
        selectRect = scratchPath == nil ? nil : selectRectAsked
        // And for dragging the timeline: in Max's own run only his mouse drags it.
        dragsTimeline = scratchPath != nil && middleDrag
        // And for the big test project: Max's own projects are never filled with made-up clips. Without a
        // file to open there is no song to lay the clips along.
        buildsBigProject = scratchPath != nil && openPath != nil && bigProject
        // And for timing a list of edits: in Max's own run only he edits.
        timesEdits = scratchPath != nil && timeEdits

        guard let scratchPath else {
            scratchFolder = nil
            settings = .standard
            return
        }
        let folder = Self.fileURL(for: scratchPath)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Self.stop("could not create the scratch folder \(folder.path): \(error.localizedDescription)")
        }
        // A suite name that is an absolute path makes macOS keep the settings in that
        // file (with ".plist" added), so nothing lands among Max's own settings.
        guard let store = UserDefaults(suiteName: folder.appendingPathComponent("Settings").path) else {
            Self.stop("could not keep settings in the scratch folder \(folder.path)")
        }
        scratchFolder = folder
        settings = store
    }

    /// Reads `<kind>` or `<kind>@<from>-<to>`, as `-double` and `-wordEffect` take it: the kind of
    /// effect, and the stretch between those two song seconds or nil for the whole clip. Nil for
    /// anything written another way.
    private static func effect(_ value: String) -> (kind: ClipEffect.Kind, stretch: Range<Double>?)? {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard let name = parts.first, let kind = ClipEffect.Kind(rawValue: String(name)), parts.count <= 2 else {
            return nil
        }
        guard parts.count == 2 else { return (kind, nil) }
        let ends = parts[1].split(separator: "-", omittingEmptySubsequences: false).map { Double($0) }
        guard ends.count == 2, let from = ends[0], let to = ends[1], from.isFinite, to.isFinite, from < to else {
            return nil
        }
        return (kind, from..<to)
    }

    private static func value(after option: String, at index: Int, in arguments: [String]) -> String {
        guard index < arguments.endIndex, !arguments[index].isEmpty else {
            stop("\(option) needs a value after it")
        }
        return arguments[index]
    }

    /// What `-addTake` was given: a path, or a path with "@" and a number of seconds after it. A name that
    /// has an "@" in it with something else than a number after it is a path as it stands.
    private static func takeToAdd(from value: String) -> TakeToAdd {
        if let at = value.lastIndex(of: "@"), let seconds = Double(value[value.index(after: at)...]),
           seconds.isFinite, seconds >= 0, at != value.startIndex {
            return TakeToAdd(url: fileURL(for: String(value[..<at])), place: seconds)
        }
        return TakeToAdd(url: fileURL(for: value), place: 0)
    }

    private static func fileURL(for path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let url = URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL
        // macOS writes "/tmp/x" for "/private/tmp/x" only when x exists. A file that is still to be written
        // must be spelled the same way as the folder it lies in, or it looks like a place outside that folder.
        // So the part of the path that exists is spelled the system's way and the rest is added to it.
        var missing: [String] = []
        var existing = url
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return missing.reduce(existing.standardizedFileURL) { $0.appendingPathComponent($1) }
    }

    /// Quits at once. Running on with Max's own settings after a broken `-scratch`
    /// would put his work at risk, which is what `-scratch` exists to prevent.
    private static func stop(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Lockstep: \(message)\n".utf8))
        exit(64)
    }
}

/// Where the projects of new songs are made right now.
struct ProjectsFolder: Equatable {
    var url: URL
    /// True when the folder chosen in Settings cannot be used and this is the usual
    /// folder in its place. The General pane then says so.
    var isFallback: Bool
}

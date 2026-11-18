import Foundation
import Observation

// MARK: The choices of settings that are one of a few

/// How the timeline keeps the playhead in view while the song plays.
public enum FollowPlayhead: String, CaseIterable, SettingValue {
    /// When the playhead leaves the right edge, the timeline glides so that the
    /// playhead stands in the middle of it (`PlayheadFollow`).
    case toTheMiddle
    /// The playhead stays in place and the song moves under it.
    case smooth
    /// The timeline stays where it is.
    case off

    /// Until 14 November 2026 the first choice was "by page", stored as "byPage". To the
    /// middle took its place, so a stored "by page" is read as that.
    public init?(stored: Any) {
        guard let text = stored as? String else { return nil }
        if text == "byPage" {
            self = .toTheMiddle
        } else {
            self.init(rawValue: text)
        }
    }
}

/// How fast the app's own animations run.
public enum AnimationSpeed: String, CaseIterable, SettingValue {
    case normal
    case fast
    case off

    /// What the length of every animation is multiplied by.
    public var factor: Double {
        switch self {
        case .normal: 1
        case .fast: 0.5
        case .off: 0
        }
    }
}

extension ClickSound: SettingValue {}
extension ClickDivision: SettingValue {}

/// The language the words of clips are written out in: Settings > Recording > "Language of the words".
public enum SpeechLanguage: String, CaseIterable, SettingValue {
    /// Swedish, with KB-Whisper, which knows Swedish far better than a model for many languages.
    case swedish
    /// Whatever language is spoken, which the multilingual Whisper model finds by itself.
    case automatic

    /// What a fresh install starts with: Swedish when the Mac's own language is Swedish, otherwise
    /// the language each clip is found to be in.
    public static func ofTheMac(preferredLanguages: [String] = Locale.preferredLanguages) -> SpeechLanguage {
        preferredLanguages.first?.hasPrefix("sv") == true ? .swedish : .automatic
    }
}

// MARK: Every setting

// Every setting, one key per row. This is the one
// place that knows a setting's name, what it starts as and how far it can go. A later
// phase adds its settings here and to `AppSettings.keys`.

extension SettingKey where Value == String {
    /// Where the projects of new songs are made, as a path. `~` is the home folder.
    /// Read it as a folder with `AppSettings.projectFolder`.
    public static var projectFolder: SettingKey {
        SettingKey("general.projectFolder", pane: .general, default: "~/Music/Lockstep")
    }
}

extension SettingKey where Value == Bool {
    /// Whether Lockstep starts with the project that was open last.
    public static var reopenLastProject: SettingKey {
        SettingKey("general.reopenLastProject", pane: .general, default: true)
    }

    /// Whether the first beat of each bar gets the stronger version of the click's sound.
    public static var accentBeatOne: SettingKey {
        SettingKey("click.accentBeatOne", pane: .beatsAndClick, default: true)
    }

    /// Whether a clip that is dragged catches on the edges of other clips, on the
    /// playhead and on the place it was recorded. It is switched in the main window
    /// (Edit > Snapping, and the button in the bar), not in the settings window.
    public static var snapping: SettingKey {
        SettingKey("editing.snapping", pane: .general, default: true)
    }

    /// What starting a take over (Record pressed during the take) does with the attempt it drops. Off deletes it. On keeps
    /// it as a clip, like a recording that was stopped.
    public static var restartKeepsAttempt: SettingKey {
        SettingKey("recording.restartKeepsAttempt", pane: .recording, default: false)
    }

    /// Whether a new recording is brought to the target loudness (`targetLufs`) by itself, as it becomes a
    /// clip. Off leaves it as loud as it was recorded, until Normalize is chosen for it.
    public static var normalizeNewRecordings: SettingKey {
        SettingKey("volume.normalizeNewRecordings", pane: .volume, default: true)
    }

    /// Whether the words of a new recording are written out by themselves, with the speech model of
    /// `speechLanguage`. The pieces left by a split or a cut, and clips found without words when a project
    /// opens, follow it too. Off leaves clips without words until Write Out Words Again is chosen for them.
    public static var writeOutNewRecordings: SettingKey {
        SettingKey("speech.writeOutNewRecordings", pane: .recording, default: true)
    }
}

extension SettingKey where Value == SpeechLanguage {
    /// The language the words of clips are written out in. Until it is chosen it is the Mac's own language
    /// when that is Swedish, and found for each clip otherwise. An install from before this setting keeps
    /// Swedish (`AppSettings.keepSwedishWordsOfAnEarlierInstall`).
    public static var speechLanguage: SettingKey {
        SettingKey(
            "speech.language",
            pane: .recording,
            default: SpeechLanguage.ofTheMac(),
            choices: SpeechLanguage.allCases
        )
    }
}

extension SettingKey where Value == FollowPlayhead {
    public static var followPlayhead: SettingKey {
        SettingKey("general.followPlayhead", pane: .general, default: .toTheMiddle, choices: FollowPlayhead.allCases)
    }
}

extension SettingKey where Value == AnimationSpeed {
    public static var animationSpeed: SettingKey {
        SettingKey("general.animationSpeed", pane: .general, default: .normal, choices: AnimationSpeed.allCases)
    }
}

extension SettingKey where Value == Int {
    /// The longest run of missing beats that is filled in with estimated ones. 0 fills nothing.
    public static var maxGapBeats: SettingKey {
        SettingKey("beats.maxGapBeats", pane: .beatsAndClick, default: 32, range: 0...64)
    }

    /// How many beats the smooth tempo curve looks at around each beat: an odd number.
    /// A smaller one follows each drum hit more closely.
    public static var smoothingBeats: SettingKey {
        SettingKey("beats.smoothingBeats", pane: .beatsAndClick, default: 17, range: 9...33, step: 2)
    }

    /// How near a dragged clip must come to a snap point to catch on it, in points on
    /// screen. It is a distance on screen so that snapping feels the same at every zoom.
    public static var snapDistancePoints: SettingKey {
        SettingKey("editing.snapDistancePoints", pane: .general, default: 8, range: 2...20)
    }

    /// How many bars the count-in before recording lasts. 0 is off: recording starts at once.
    public static var runUpBars: SettingKey {
        SettingKey("recording.runUpBars", pane: .recording, default: 1, choices: [0, 1, 2, 4])
    }

    /// The speed the song is played at while a take is recorded, in percent of its own: 100, 90 or 85. Below
    /// 100 the take is recorded slower and sped up afterwards (`SlowTime`). Like `snapping` it is switched in
    /// the main window (the bar's click menu), so it is not among `AppSettings.keys`.
    public static var recordSpeedPercent: SettingKey {
        SettingKey("recording.speedPercent", pane: .recording, default: 100, choices: SlowTime.percents)
    }
}

extension SettingKey where Value == ClickSound {
    /// The sound the click of a new song starts with.
    public static var clickDefaultSound: SettingKey {
        SettingKey("click.defaultSound", pane: .beatsAndClick, default: .woodblock, choices: ClickSound.allCases)
    }
}

extension SettingKey where Value == Double {
    /// How sure the beat model must be of a beat for Lockstep to take it, as the model's own
    /// value: 0 is "more sure than not", higher is stricter, lower is looser. The loosest it
    /// goes is the floor of `BeatPicker`, below which the model's values say nothing, and the
    /// strictest is as far above 0 as that is below it. `BeatPicker.pick` reads it.
    public static var certaintyLimit: SettingKey {
        let loosest = Double(BeatPicker.floor)
        return SettingKey("beats.certaintyLimit", pane: .beatsAndClick, default: 0, range: loosest...(-loosest))
    }

    /// The volume the click of a new song starts with, from 0 (silent) to 1 (full).
    public static var clickDefaultVolume: SettingKey {
        SettingKey("click.defaultVolume", pane: .beatsAndClick, default: 0.7, range: 0...1)
    }

    /// How long the fade at every edge of a clip's sound is, in milliseconds, so a cut in the middle of a
    /// sound does not click. 0 is no fade. `EdgeFade` applies it.
    public static var edgeFadeMs: SettingKey {
        SettingKey("timing.edgeFadeMs", pane: .timing, default: 5, range: 0...20)
    }

    /// How far from the nearest sub-beat a syllable must be to count as meant that way, as a percentage of
    /// the sub-beat spacing. Such a syllable is shown in a neutral colour. `MarkerDistance.classify` reads it.
    public static var deliberatePercent: SettingKey {
        SettingKey(
            "timing.deliberatePercent",
            pane: .timing,
            default: MarkerDistance.defaultDeliberatePercent,
            range: 20...50
        )
    }

    /// The furthest the correction may slide a line, in milliseconds. 0 slides nothing. What really counts is
    /// `AppSettings.maxLineShiftInForceMs`, which also keeps it within what the pause between lines leaves room for.
    public static var maxLineShiftMs: SettingKey {
        SettingKey("timing.maxLineShiftMs", pane: .timing, default: LineShift.defaultMaxShiftMs, range: 0...120)
    }

    /// How long a pause in the voice must be to separate two lines, in milliseconds. `LineFinder` reads it.
    public static var linePauseMs: SettingKey {
        SettingKey("timing.linePauseMs", pane: .timing, default: LineFinder.defaultPauseMs, range: 150...600)
    }

    /// The furthest the correction may move a single syllable toward its sub-beat, in milliseconds.
    /// 0 moves no syllable. `SyllableMoves` reads it.
    public static var maxSyllableMoveMs: SettingKey {
        SettingKey("timing.maxSyllableMoveMs", pane: .timing, default: SyllableMoves.defaultMaxMoveMs, range: 0...80)
    }

    /// The most the sound between two syllables may be stretched or squeezed, as a percentage: at 25 its
    /// length stays between 1 / 1.25 and 1.25 of what it was. At 0 nothing is stretched, and syllables move
    /// only where a pause can take up the change. `SyllableMoves` reads it.
    public static var maxStretchPercent: SettingKey {
        SettingKey(
            "timing.maxStretchPercent",
            pane: .timing,
            default: SyllableMoves.defaultMaxStretchPercent,
            range: 0...40
        )
    }

    /// The loudness Normalize brings a clip to, in LUFS. -18 leaves room for mixing in Resolve. Changing it
    /// changes no clip that is already normalised: it counts the next time Normalize runs.
    public static var targetLufs: SettingKey {
        SettingKey("volume.targetLufs", pane: .volume, default: -18, range: -30...(-10))
    }
}

extension SettingKey where Value == ClickDivision {
    /// How often the click of a new song sounds.
    public static var clickDefaultDivision: SettingKey {
        SettingKey("click.defaultDivision", pane: .beatsAndClick, default: .beats, choices: ClickDivision.allCases)
    }
}

// MARK: The settings

/// Lockstep's settings: the one place the app reads them from and changes them in.
///
///     let settings = AppSettings(store: .standard)
///     settings[.maxGapBeats]                  // 32, or what Max chose, never outside 0...64
///     settings[.followPlayhead] = .smooth     // kept at once
///     settings.restoreDefaults(for: .general)
///
/// - A setting nobody changed, or whose stored value cannot be read, is its default.
/// - A stored value outside the limits is read as the nearest allowed value, and a
///   value outside the limits is stored as the nearest allowed value.
/// - A view that reads a setting is drawn again when that setting changes, and so is
///   told whatever reads it inside `withObservationTracking`.
/// - A form binds to a setting with `$settings[.maxGapBeats]`, given
///   `@Bindable var settings: AppSettings`.
///
/// The values are kept in the `UserDefaults` it is given, under each key's name. Tests
/// hand it a throwaway suite. The shortcuts are not here: `ShortcutStore` keeps them.
@MainActor
@Observable
public final class AppSettings {
    /// Every setting, for what is done to all settings of a pane at once. A setting that
    /// is missing here is left out of Restore Defaults.
    ///
    /// `snapping`, `recordSpeedPercent` and `sendWithSound` are left out on purpose: they are switched
    /// in the main window and in the Send to DaVinci panel, so Restore Defaults in a pane that does not
    /// show them must not change them.
    public nonisolated static let keys: [any AnySettingKey] = [
        SettingKey<String>.projectFolder,
        SettingKey<Bool>.reopenLastProject,
        SettingKey<FollowPlayhead>.followPlayhead,
        SettingKey<AnimationSpeed>.animationSpeed,
        SettingKey<Int>.snapDistancePoints,
        SettingKey<Int>.maxGapBeats,
        SettingKey<Int>.smoothingBeats,
        SettingKey<Double>.certaintyLimit,
        SettingKey<ClickSound>.clickDefaultSound,
        SettingKey<Double>.clickDefaultVolume,
        SettingKey<ClickDivision>.clickDefaultDivision,
        SettingKey<Bool>.accentBeatOne,
        SettingKey<Int>.runUpBars,
        SettingKey<Bool>.restartKeepsAttempt,
        SettingKey<MeasuredDelays>.measuredDelays,
        SettingKey<Bool>.writeOutNewRecordings,
        SettingKey<SpeechLanguage>.speechLanguage,
        SettingKey<Double>.targetLufs,
        SettingKey<Bool>.normalizeNewRecordings,
        SettingKey<Double>.edgeFadeMs,
        SettingKey<Double>.deliberatePercent,
        SettingKey<Double>.maxLineShiftMs,
        SettingKey<Double>.linePauseMs,
        SettingKey<Double>.maxSyllableMoveMs,
        SettingKey<Double>.maxStretchPercent,
        SettingKey<String>.defaultTimelineStart,
        SettingKey<ResolveFrameRate>.defaultFrameRate,
        SettingKey<String>.exportFolder,
    ]

    @ObservationIgnored private let store: UserDefaults
    /// One counter per setting that was read or changed, by the setting's name. Reading a
    /// setting reads its counter and changing it raises the counter. That is what tells
    /// the readers of one setting, and only them, that it has changed.
    @ObservationIgnored private var changeCounts: [String: ChangeCount] = [:]
    /// The wireless pairs of devices whose delay was measured in the connection that is still going, by the
    /// pair's key. Only these wireless delays are in use (see `delay(for:)` in `MeasuredDelays.swift`). It is
    /// kept in memory only, so it is empty whenever the app starts: a delay from an earlier session is then
    /// never taken for a fresh one.
    var wirelessDelaysInUse: Set<String> = []

    public init(store: UserDefaults) {
        self.store = store
        keepSwedishWordsOfAnEarlierInstall()
    }

    /// The name of the mark that says the language of the words was settled for an earlier install.
    nonisolated static let speechLanguageSettledKey = "speech.languageSettled"

    /// Until 18 November 2026 every clip was written out in Swedish, and there was no setting for it. A
    /// store that already holds settings from that time is given Swedish, so an earlier install goes on as
    /// it was whatever the Mac's own language is. A fresh store is left to the default. Either way this is
    /// done once: the mark it leaves keeps Restore Defaults and later starts from doing it again.
    private func keepSwedishWordsOfAnEarlierInstall() {
        guard store.object(forKey: Self.speechLanguageSettledKey) == nil else { return }
        let earlierNames = Self.keys.map(\.name) + ["lastProjectPath"]
        let isEarlierInstall = earlierNames.contains { store.object(forKey: $0) != nil }
        if isEarlierInstall, store.object(forKey: SettingKey<SpeechLanguage>.speechLanguage.name) == nil {
            store.set(SpeechLanguage.swedish.rawValue, forKey: SettingKey<SpeechLanguage>.speechLanguage.name)
        }
        store.set(true, forKey: Self.speechLanguageSettledKey)
    }

    /// The value of a setting, and the way to change it.
    public subscript<Value>(key: SettingKey<Value>) -> Value {
        get {
            _ = changeCount(of: key.name).value
            guard let stored = store.object(forKey: key.name), let value = Value(stored: stored) else {
                return key.defaultValue
            }
            return key.fitted(value)
        }
        set {
            let value = key.fitted(newValue)
            // A slider that is dragged sends the same value many times over.
            guard value != self[key] else { return }
            store.set(value.storedForm, forKey: key.name)
            changeCount(of: key.name).value += 1
        }
    }

    /// Puts every setting of one pane back to what it started as. The other panes keep
    /// what they have.
    public func restoreDefaults(for pane: SettingsPane) {
        for key in Self.keys where key.pane == pane {
            store.removeObject(forKey: key.name)
            changeCount(of: key.name).value += 1
        }
    }

    /// The folder of `general.projectFolder`, with `~` written out. A path that does not
    /// start at the root or at `~` names no folder, and counts as the default.
    public var projectFolder: URL {
        let key = SettingKey<String>.projectFolder
        var path = (self[key] as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = (key.defaultValue as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// The furthest a line may slide right now, in milliseconds: `timing.maxLineShiftMs`, held at what the
    /// pause between lines leaves room for (`TightenSettings.furthestShiftMs(forPauseMs:)`), so two lines can
    /// never meet. The setting itself is kept as Max set it: when the pause is made longer again, his value
    /// counts again. The correction and the Timing pane both read this.
    public var maxLineShiftInForceMs: Double {
        min(self[.maxLineShiftMs], TightenSettings.furthestShiftMs(forPauseMs: self[.linePauseMs]))
    }

    private func changeCount(of name: String) -> ChangeCount {
        if let count = changeCounts[name] {
            return count
        }
        let count = ChangeCount()
        changeCounts[name] = count
        return count
    }
}

/// How many times one setting was changed. Only that it changes matters, not the number.
@MainActor
@Observable
private final class ChangeCount {
    var value = 0
}

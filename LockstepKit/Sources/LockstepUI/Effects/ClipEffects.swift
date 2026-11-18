import Foundation
import LockstepCore

// What the window shows of effects: a double, or an effect on words, on the whole clip or on a stretch of it,
// and an effect of a whole track, which every clip of the track has. The panel on the right lists them under
// the heading "Effects" (`EffectsList`), and a clip shows where each of its own is (`ClipEffectBands`, and
// the mark "FX" in the clip's bar).

/// One effect, as the window shows it: one row of a list under "Effects". Like the other display types it
/// holds finished values: the stretch is where it is heard in the song, whatever the clip's timing
/// correction did to it.
///
/// The same type serves the four kinds of row there are:
/// - a clip's own effect, in the clip's list (`ClipBox.effects`): nothing more set;
/// - an effect of the clip's track, in the clip's list, before the clip's own: `ofTrack` set, with the
///   level the clip is heard with in `levelDB`;
/// - an effect of a track, in the track's list (`TrackRow.effects`): nothing more set, and no stretch;
/// - an effect several selected clips share (`MainLayoutContent.selectedClipsEffects`): no stretch,
///   `isMixed` where their levels differ, and `ofTrack` when it is the track's effect on every one of them.
public struct ClipEffectMark: Sendable, Equatable, Identifiable {
    /// What a track's effect has on a clip, or on several selected clips: what they changed of it for
    /// themselves. As `SoundKnobSlider.OfClip` is for a knob.
    public struct OfTrack: Sendable, Equatable {
        /// The clip changed something of this effect for itself, its level or that it is switched off, or,
        /// of several selected clips, at least one did. The row then has the mark that puts it back.
        public var isChanged: Bool
        /// The clip is heard without this effect, or, of several selected clips, every one of them is.
        public var isOff: Bool
        /// The level the track gives the effect, in dB, which is where the row goes when its mark is
        /// pressed. For clips on tracks that differ, the average.
        public var trackLevelDB: Double

        public init(isChanged: Bool = false, isOff: Bool = false, trackLevelDB: Double) {
            self.isChanged = isChanged
            self.isOff = isOff
            self.trackLevelDB = trackLevelDB
        }
    }

    /// The effect's own id. A track's effect has the same id in the track's list and in the list of every
    /// clip of the track. A row that several clips share has an id its owner made for the row.
    public var id: UUID
    public var kind: ClipEffect.Kind
    /// The stretch of the clip the effect is on, in song seconds, where it is heard. Nil: the whole clip.
    public var range: ClosedRange<Double>?
    /// How loud its layer is, in dB, from -24 to +6. Not shown for a kind without a level.
    public var levelDB: Double
    /// Its stretch is the one marked in the timeline right now: its row in the panel is lit, and its band
    /// on the clip has a brighter line around it. Set it after making the mark.
    public var isSelected = false
    /// Set for an effect that comes from the clip's track, nil for a clip's own effect and for a row of
    /// the track's own list. Such a row reads "Track" where an own one reads "Whole clip", and has a button
    /// that switches the effect off for the clip in place of the one that removes. The clip itself draws
    /// nothing for it: no band and no "FX". Set it after making the mark.
    public var ofTrack: OfTrack?
    /// The level reads "Mixed": several selected clips share this effect at levels that differ. `levelDB`
    /// is then where the knob stands, their average. Set it after making the mark.
    public var isMixed = false

    public init(id: UUID, kind: ClipEffect.Kind, range: ClosedRange<Double>? = nil, levelDB: Double) {
        self.id = id
        self.kind = kind
        self.range = range
        self.levelDB = levelDB
    }
}

extension ClipEffect.Kind {
    /// The six doubles of phase 34, in the order of the menu.
    public static let doubles: [ClipEffect.Kind] = [.thick, .lowFourth, .lowOctave, .high, .big, .small]
    /// The six effects on words of phase 35, in the order of the menu.
    public static let onWords: [ClipEffect.Kind] = [.echoQuarter, .echoEighth, .phone, .stutter, .tapeStop, .swell]
    /// The nine kinds the menu of a track offers, in its order: the six doubles, the two echoes and Phone.
    /// Stutter, tape stop and swell are left out, because on a whole clip they give nothing useful.
    public static let forTracks: [ClipEffect.Kind] = doubles + [.echoQuarter, .echoEighth, .phone]

    /// The kind's line in the menu that adds an effect.
    public var menuTitle: String {
        switch self {
        case .thick: "Thick"
        case .lowFourth: "Low, a fourth down"
        case .lowOctave: "Low, an octave down"
        case .high: "High"
        case .big: "Big"
        case .small: "Small"
        case .echoQuarter: "Echo, quarter notes"
        case .echoEighth: "Echo, eighth notes"
        case .phone: "Phone"
        case .stutter: "Stutter"
        case .tapeStop: "Tape stop"
        case .swell: "Swell"
        }
    }

    /// The kind's name where there is little room: in its row in the panel and in its band on the clip.
    public var shortName: String {
        switch self {
        case .lowFourth: "Low fourth"
        case .lowOctave: "Low octave"
        case .echoQuarter: "Echo 1/4"
        case .echoEighth: "Echo 1/8"
        case .thick, .high, .big, .small, .phone, .stutter, .tapeStop, .swell: menuTitle
        }
    }

    /// Whether the kind has a level. A kind that replaces the voice has none, and its row shows no slider.
    public var hasLevel: Bool {
        switch self {
        case .phone, .stutter, .tapeStop: false
        case .thick, .lowFourth, .lowOctave, .high, .big, .small, .echoQuarter, .echoEighth, .swell: true
        }
    }
}

/// What the section "Effects" of the panel on the right, and the same menus on a clip and on a track, tell
/// their owner. The owner then changes the clips or the track, so the window shows the new effects:
///
///     var effects = EffectsActions()
///     effects.addChosen = { kind in model.addEffect(kind) }
///     effects.addChosenInClipMenu = { kind, clipID in model.addEffect(kind, rightClicked: clipID) }
///     effects.levelChanged = { effectID, levelDB, isFinal in ... }
///     effects.removePressed = { effectID in ... }
///     effects.rowPressed = { effectID in ... }
///     effects.trackAddChosen = { kind, trackID in ... }
///     effects.trackLevelChanged = { trackID, effectID, levelDB, isFinal in ... }
///     effects.trackRemovePressed = { trackID, effectID in ... }
///     effects.offPressed = { effectID in ... }
///     effects.resetPressed = { effectID in ... }
///     actions.effects = effects
///
/// In the clip part of the panel a row is named by the id of its mark alone, because the rows are about the
/// selected clips: a clip's own effect and a track's effect by the effect's id, and a row several clips
/// share by the id its owner gave the row. In the track part a row is named with its track. Every action
/// left nil leaves its control changing only what it shows, as in the design lab.
public struct EffectsActions {
    /// A kind was chosen in the menu of the heading "Effects", in the clip part of the panel, or in the
    /// track part while words are marked in a clip of the track. The owner puts it on the marked stretch
    /// when one is marked on a clip, and otherwise on the whole of every selected clip.
    public var addChosen: (@MainActor (ClipEffect.Kind) -> Void)?

    /// A kind was chosen under "Effects" in the right-click menu of the clip with this id.
    public var addChosenInClipMenu: (@MainActor (ClipEffect.Kind, UUID) -> Void)?

    /// The level of a row in the clip part was moved: the level it stands at, in dB. `isFinal` is false
    /// while the slider is still being moved and true once it is let go, so one drag can be one change. For
    /// a clip's own effect it is that effect's level. For a track's effect (a mark with `ofTrack`) it is
    /// the selected clips' own level for it. For a row several clips share it is the level of all of them.
    public var levelChanged: (@MainActor (_ effectID: UUID, _ levelDB: Double, _ isFinal: Bool) -> Void)?

    /// The button that removes was pressed on a row in the clip part: a clip's own effect, or a row several
    /// clips share, which the owner removes from all of them (a track's effect among them is switched off
    /// for that clip).
    public var removePressed: (@MainActor (_ effectID: UUID) -> Void)?

    /// The row of an effect was clicked. The owner marks the effect's stretch in the timeline. Only the rows
    /// of one clip's own effects are clicked: a track's effect and a shared row have no stretch.
    public var rowPressed: (@MainActor (_ effectID: UUID) -> Void)?

    /// A kind was chosen for the track with this id: in the menu of the heading "Effects" in the track part
    /// of the panel, while no words are marked, or under "Effects" in the track's right-click menu. The
    /// owner gives the track that effect, which every clip of it then has.
    public var trackAddChosen: (@MainActor (ClipEffect.Kind, _ trackID: UUID) -> Void)?

    /// The level of an effect of the track with this id was moved, in the track part of the panel.
    /// `isFinal` as for `levelChanged`.
    public var trackLevelChanged: (@MainActor (_ trackID: UUID, _ effectID: UUID, _ levelDB: Double, _ isFinal: Bool) -> Void)?

    /// The button that removes was pressed on an effect of the track with this id, in the track part.
    public var trackRemovePressed: (@MainActor (_ trackID: UUID, _ effectID: UUID) -> Void)?

    /// The button that switches a track's effect off was pressed on a row in the clip part. The owner
    /// switches the effect off for the selected clips, or on again when it is off (`OfTrack.isOff`).
    public var offPressed: (@MainActor (_ effectID: UUID) -> Void)?

    /// The mark of a track's effect the selected clips changed for themselves was pressed. The owner takes
    /// their change away: they follow their track with that effect again, on and at the track's level.
    public var resetPressed: (@MainActor (_ effectID: UUID) -> Void)?

    public init() {}
}

/// Where an effect is, as its row in the panel writes it.
public enum EffectPlace {
    /// What the row of a track's effect reads in the track's own list, where a clip's row reads
    /// "Whole clip": the effect is on every clip of the track.
    public static let everyClip = "Every clip"
    /// What the row of a track's effect reads in the list of a clip: the effect comes from the clip's track.
    public static let track = "Track"

    /// "Whole clip" for an effect without a stretch. For a stretch, where it starts and ends on the
    /// timeline, to a tenth of a second, with a dash between: "0:17.2–0:18.1".
    ///
    /// - Parameters:
    ///   - range: The stretch in song seconds, or nil for the whole clip.
    ///   - zeroSeconds: The song second that stands at the timeline's 00:00, which is 0 until the song is
    ///     cut or moved.
    public static func text(for range: ClosedRange<Double>?, zeroSeconds: Double = 0) -> String {
        guard let range else { return "Whole clip" }
        return "\(time(range.lowerBound - zeroSeconds))–\(time(range.upperBound - zeroSeconds))"
    }

    /// Minutes, seconds and tenths, written with a point on every Mac: "0:17.2". The tenth shown is the
    /// nearest one.
    private static func time(_ seconds: Double) -> String {
        let tenths = seconds.isFinite ? Int((abs(seconds) * 10).rounded()) : 0
        let sign = seconds < 0 && tenths > 0 ? "-" : ""
        let wholeSeconds = tenths / 10
        let remainder = wholeSeconds % 60
        return "\(sign)\(wholeSeconds / 60):\(remainder < 10 ? "0" : "")\(remainder).\(tenths % 10)"
    }
}

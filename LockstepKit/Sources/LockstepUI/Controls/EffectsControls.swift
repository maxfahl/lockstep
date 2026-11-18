import LockstepCore
import SwiftUI

// The controls under the heading "Effects" in the panel on the right: the small button in the heading's line
// that opens the menu an effect is added from, and the list of effects, one row each. The list serves a
// clip, a track and several selected clips.
//
// Each explains itself in one sentence when the pointer rests on it.

/// The small "+" in the line of the heading "Effects". A press opens the menu an effect is chosen from
/// (`EffectsMenu`). For clips, the effect goes on the words that are marked in a clip, or else on the whole
/// of every selected clip. For a track (`target`), it goes on the track, and every clip of the track gets it.
///
/// Without `onChosen`, as in the design lab, choosing a line does nothing.
public struct AddEffectButton: View {
    private let features: FeatureSet
    private let target: EffectsMenu.Target
    private let onChosen: (@MainActor (ClipEffect.Kind) -> Void)?

    /// - Parameters:
    ///   - features: Which kinds the menu holds. See `EffectsMenu`.
    ///   - target: What the effect goes on, which decides the menu's lines and the help tag. Clips, unless
    ///     said.
    ///   - onChosen: Told which kind was chosen.
    public init(
        features: FeatureSet = .all,
        target: EffectsMenu.Target = .clips,
        onChosen: (@MainActor (ClipEffect.Kind) -> Void)? = nil
    ) {
        self.features = features
        self.target = target
        self.onChosen = onChosen
    }

    public var body: some View {
        Menu {
            EffectsMenu(features: features, target: target, onChosen: onChosen)
        } label: {
            Image(systemName: "plus")
                .font(DesignTokens.Fonts.symbolSmall)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .frame(width: DesignTokens.Sizes.smallButton, height: DesignTokens.Sizes.headingButtonHeight)
                .background(DesignTokens.Colors.controlFill, in: DesignTokens.Shapes.control)
                .contentShape(DesignTokens.Shapes.control)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(
            target == .track
                ? "Add an effect to this track. Every clip of the track gets it."
                : "Add an effect to the words you marked in a clip, or to the whole of the selected clips."
        )
        .accessibilityLabel("Add effect")
    }
}

/// A list of effects, one row each, in the order it is given. It is the list of one clip, of a track or of
/// several selected clips (`Subject`).
///
/// A row has two lines. The kind's name, after it in small text where the effect is, and at the right a
/// small button. Under it "Level" with the level's slider and its value in dB. A kind without a level has
/// the first line alone.
///
/// - A clip's own effect reads "Whole clip", or the time of its stretch on the timeline, and its button
///   removes it. The row whose stretch is marked in the timeline is lit (`ClipEffectMark.isSelected`), and a
///   click on a row asks for its stretch to be marked.
/// - An effect of the clip's track (`ClipEffectMark.ofTrack`) reads "Track". Its button switches the effect
///   off for this clip and on again: the symbol is in the accent colour while the effect is on. Switched
///   off, the row is dimmed, but not the button. A small arrow that turns back, the mark a clip's knob has,
///   stands before the level's value while the clip changed anything of the effect, its level or off, and a
///   press on it puts the effect back to the track's, on and at the track's level. In a row without a level
///   the arrow stands in the first line, before the button. While a list holds a track's effect, every row
///   of it keeps the arrow's place, so the sliders stand in one line.
/// - A track's own row reads "Every clip", and its button removes the effect from the track.
/// - A row several clips share reads "Whole clip" and its button removes the effect from all of them, or,
///   when it is the track's effect on every one of them, it is the row of a track's effect above. Its level
///   reads "Mixed" while the clips differ (`ClipEffectMark.isMixed`), and moving it gives all the same.
///
/// Without `actions`, as in the design lab, a click on a clip's own row lights that row, a slider changes
/// what it shows and brings the arrow, the arrow and the button that switches off work on the row alone,
/// and the button that removes does nothing.
public struct EffectsList: View {
    /// Whose effects the list shows, which decides what a row reads and whom it reports to.
    public enum Subject: Sendable, Equatable {
        /// One clip: the effects of its track first, then its own.
        case clip
        /// The track with this id: the effects every clip of it gets.
        case track(UUID)
        /// Several selected clips: the effects they share.
        case clips
    }

    /// The lowest and highest level of an effect, in dB.
    public static let levelRange: ClosedRange<Double> = -24...6

    private let effects: [ClipEffectMark]
    private let zeroSeconds: Double
    private let subject: Subject
    private let actions: EffectsActions?
    /// The row that was clicked last, while the list has no owner.
    @State private var keptSelection: UUID?

    /// - Parameters:
    ///   - effects: The rows, from top to bottom.
    ///   - zeroSeconds: The song second at the timeline's 00:00, so a stretch is written in the time the
    ///     window shows.
    ///   - subject: Whose effects they are. One clip's, unless said.
    ///   - actions: Who is told. Left out, the list changes only what it shows.
    public init(
        effects: [ClipEffectMark],
        zeroSeconds: Double = 0,
        subject: Subject = .clip,
        actions: EffectsActions? = nil
    ) {
        self.effects = effects
        self.zeroSeconds = zeroSeconds
        self.subject = subject
        self.actions = actions
        _keptSelection = State(initialValue: effects.first(where: \.isSelected)?.id)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            ForEach(effects) { effect in
                row(for: effect)
            }
        }
    }

    private func row(for effect: ClipEffectMark) -> EffectRow {
        let id = effect.id
        var onLevelChange: (@MainActor (Double, Bool) -> Void)?
        var onRemove: (@MainActor () -> Void)?
        var onOff: (@MainActor () -> Void)?
        var onReset: (@MainActor () -> Void)?
        switch subject {
        case .track(let trackID):
            if let changed = actions?.trackLevelChanged {
                onLevelChange = { levelDB, isFinal in changed(trackID, id, levelDB, isFinal) }
            }
            if let pressed = actions?.trackRemovePressed {
                onRemove = { pressed(trackID, id) }
            }
        case .clip, .clips:
            if let changed = actions?.levelChanged {
                onLevelChange = { levelDB, isFinal in changed(id, levelDB, isFinal) }
            }
            if let pressed = actions?.removePressed {
                onRemove = { pressed(id) }
            }
            if let pressed = actions?.offPressed {
                onOff = { pressed(id) }
            }
            if let pressed = actions?.resetPressed {
                onReset = { pressed(id) }
            }
        }
        // Only a clip's own effect has a stretch a click could mark.
        var onPress: (@MainActor () -> Void)?
        if subject == .clip, effect.ofTrack == nil {
            if let pressed = actions?.rowPressed {
                onPress = { pressed(id) }
            } else {
                onPress = { keptSelection = id }
            }
        }
        return EffectRow(
            effect: effect,
            wording: wording(for: effect),
            hasOwner: actions != nil,
            keepsMarkPlace: effects.contains { $0.ofTrack != nil },
            isLit: onPress != nil && (actions == nil ? keptSelection == id : effect.isSelected),
            onPress: onPress,
            onLevelChange: onLevelChange,
            onRemove: onRemove,
            onOff: onOff,
            onReset: onReset
        )
    }

    /// What the row of this effect reads and says, which follows whose list it is and whether the effect
    /// comes from a track.
    private func wording(for effect: ClipEffectMark) -> EffectRowWording {
        switch (subject, effect.ofTrack != nil) {
        case (.track, _):
            EffectRowWording(
                place: EffectPlace.everyClip,
                placeHelp: "This effect is on every clip of the track.",
                levelHelp: "How loud this effect is on every clip of the track.",
                removeHelp: "Remove this effect from the track."
            )
        case (.clip, false):
            EffectRowWording(
                place: EffectPlace.text(for: effect.range, zeroSeconds: zeroSeconds),
                placeHelp: effect.range == nil ? "This effect is on the whole clip." : "Where this effect is, on the timeline.",
                levelHelp: "How loud this effect is, beside the voice.",
                removeHelp: "Remove this effect from the clip."
            )
        case (.clip, true):
            EffectRowWording(
                place: EffectPlace.track,
                placeHelp: "This effect comes from the clip's track.",
                levelHelp: "How loud this effect is on this clip.",
                offHelp: "Switch this effect off for this clip only.",
                onHelp: "Switched off for this clip. Click to hear it again.",
                markHelp: "Changed for this clip only. Click to follow the track again."
            )
        case (.clips, false):
            EffectRowWording(
                place: EffectPlace.text(for: nil),
                placeHelp: "Each selected clip has this effect on the whole of it.",
                levelHelp: "How loud this effect is on the selected clips.",
                removeHelp: "Remove this effect from the selected clips. Where it comes from a clip's track, it is switched off for that clip."
            )
        case (.clips, true):
            EffectRowWording(
                place: EffectPlace.track,
                placeHelp: "This effect comes from the track of each selected clip.",
                levelHelp: "How loud this effect is on the selected clips.",
                offHelp: "Switch this effect off for the selected clips only.",
                onHelp: "Switched off for the selected clips. Click to hear it again.",
                markHelp: "Changed for these clips only. Click to follow the track again."
            )
        }
    }
}

/// What one row of the list reads and says in its help tags.
private struct EffectRowWording {
    /// Where the effect is, after its name.
    var place: String
    var placeHelp: String
    var levelHelp: String
    /// The help tag of the button that removes. Not used by the row of a track's effect in a clip's list.
    var removeHelp = ""
    /// The help tag of the button that switches off, while the effect is on.
    var offHelp = ""
    /// The same button's help tag while the effect is off.
    var onHelp = ""
    /// The help tag of the mark that puts the effect back to the track's.
    var markHelp = ""
}

/// One effect in the list. See `EffectsList`.
private struct EffectRow: View {
    private let effect: ClipEffectMark
    private let wording: EffectRowWording
    /// The list has an owner, who says what the row shows. Without one the row keeps it itself.
    private let hasOwner: Bool
    /// The list holds a track's effect, so every row keeps the place of the mark before its value.
    private let keepsMarkPlace: Bool
    private let isLit: Bool
    /// What a click on the row does. Nil for a row that cannot be clicked.
    private let onPress: (@MainActor () -> Void)?
    private let onLevelChange: (@MainActor (_ levelDB: Double, _ isFinal: Bool) -> Void)?
    private let onRemove: (@MainActor () -> Void)?
    private let onOff: (@MainActor () -> Void)?
    private let onReset: (@MainActor () -> Void)?

    // What the row keeps while the list has no owner.
    @State private var keptLevelDB: Double
    @State private var keptIsMixed: Bool
    @State private var keptHasOwnLevel: Bool
    @State private var keptIsOff: Bool
    /// Where the slider stands while it is being moved, so it follows the pointer without waiting for the
    /// owner.
    @State private var heldLevelDB: Double?

    /// The mark of a clip's knob: a small arrow that turns back.
    private static let markSymbol = "arrow.uturn.backward"

    /// How far the lit backing reaches out past the row on both sides, so the row's text and slider stay in
    /// line with the rows above and under the list.
    private static let backingReach = DesignTokens.Spacing.small

    init(
        effect: ClipEffectMark,
        wording: EffectRowWording,
        hasOwner: Bool,
        keepsMarkPlace: Bool,
        isLit: Bool,
        onPress: (@MainActor () -> Void)?,
        onLevelChange: (@MainActor (_ levelDB: Double, _ isFinal: Bool) -> Void)?,
        onRemove: (@MainActor () -> Void)?,
        onOff: (@MainActor () -> Void)?,
        onReset: (@MainActor () -> Void)?
    ) {
        self.effect = effect
        self.wording = wording
        self.hasOwner = hasOwner
        self.keepsMarkPlace = keepsMarkPlace
        self.isLit = isLit
        self.onPress = onPress
        self.onLevelChange = onLevelChange
        self.onRemove = onRemove
        self.onOff = onOff
        self.onReset = onReset
        let isOff = effect.ofTrack?.isOff ?? false
        _keptLevelDB = State(initialValue: Self.held(effect.levelDB))
        _keptIsMixed = State(initialValue: effect.isMixed)
        _keptIsOff = State(initialValue: isOff)
        // A row that starts changed and not switched off was changed in its level.
        _keptHasOwnLevel = State(initialValue: (effect.ofTrack?.isChanged ?? false) && !isOff)
    }

    private static func held(_ levelDB: Double) -> Double {
        min(max(levelDB, EffectsList.levelRange.lowerBound), EffectsList.levelRange.upperBound)
    }

    private var isOfTrack: Bool { effect.ofTrack != nil }

    private var shownLevelDB: Double {
        hasOwner ? heldLevelDB ?? Self.held(effect.levelDB) : keptLevelDB
    }

    private var shownIsMixed: Bool {
        hasOwner ? heldLevelDB == nil && effect.isMixed : keptIsMixed
    }

    /// The clips are heard without this effect of their track.
    private var shownIsOff: Bool {
        guard let ofTrack = effect.ofTrack else { return false }
        return hasOwner ? ofTrack.isOff : keptIsOff
    }

    /// The clips changed something of this effect of their track, so the mark is shown.
    private var shownIsChanged: Bool {
        guard let ofTrack = effect.ofTrack else { return false }
        return hasOwner ? heldLevelDB != nil || ofTrack.isChanged : keptHasOwnLevel || keptIsOff
    }

    private var level: Binding<Double> {
        Binding(
            get: { shownLevelDB },
            set: { levelDB in
                if hasOwner {
                    heldLevelDB = levelDB
                    onLevelChange?(levelDB, false)
                } else {
                    // Moving the slider gives every clip the level it shows, as the clip's own.
                    keptLevelDB = levelDB
                    keptIsMixed = false
                    keptHasOwnLevel = isOfTrack
                }
            }
        )
    }

    /// The slider was let go: the level it stands at is the one that counts.
    private func settle() {
        guard let final = heldLevelDB else { return }
        onLevelChange?(final, true)
        heldLevelDB = nil
    }

    /// The mark was pressed: the clips follow their track with this effect again, on and at its level.
    private func reset() {
        if hasOwner {
            heldLevelDB = nil
            onReset?()
        } else if let ofTrack = effect.ofTrack {
            keptLevelDB = Self.held(ofTrack.trackLevelDB)
            keptIsMixed = false
            keptHasOwnLevel = false
            keptIsOff = false
        }
    }

    /// The button that switches a track's effect off for the clips was pressed.
    private func switchOffOrOn() {
        if hasOwner {
            onOff?()
        } else {
            keptIsOff.toggle()
        }
    }

    private var dimming: Double {
        shownIsOff ? DesignTokens.Opacity.unavailable : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.medium) {
                Text(effect.kind.shortName)
                    .font(DesignTokens.Fonts.label)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(dimming)
                Text(wording.place)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
                    .help(wording.placeHelp)
                    .opacity(dimming)
                Spacer(minLength: 0)
                if isOfTrack {
                    if !effect.kind.hasLevel {
                        // A row without a level has no value for the mark to stand before.
                        SymbolButton(
                            symbol: Self.markSymbol,
                            name: wording.markHelp,
                            font: DesignTokens.Fonts.symbolSmall,
                            width: DesignTokens.Sizes.sliderMarkButton,
                            height: DesignTokens.Sizes.sliderMarkButton,
                            action: reset
                        )
                        .opacity(shownIsChanged ? 1 : 0)
                        .allowsHitTesting(shownIsChanged)
                        .accessibilityHidden(!shownIsChanged)
                    }
                    SymbolButton(
                        symbol: "power",
                        name: shownIsOff ? "Switch effect on" : "Switch effect off",
                        font: DesignTokens.Fonts.symbolSmall,
                        width: DesignTokens.Sizes.sliderMarkButton,
                        height: DesignTokens.Sizes.sliderMarkButton,
                        color: shownIsOff ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.accent,
                        help: shownIsOff ? wording.onHelp : wording.offHelp,
                        action: switchOffOrOn
                    )
                } else {
                    SymbolButton(
                        symbol: "xmark",
                        name: "Remove effect",
                        font: DesignTokens.Fonts.symbolSmall,
                        width: DesignTokens.Sizes.sliderMarkButton,
                        height: DesignTokens.Sizes.sliderMarkButton,
                        color: DesignTokens.Colors.textSecondary,
                        help: wording.removeHelp,
                        action: { onRemove?() }
                    )
                }
            }
            if effect.kind.hasLevel {
                HStack(spacing: DesignTokens.Spacing.medium) {
                    Text("Level")
                        .font(DesignTokens.Fonts.label)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(dimming)
                    Spacer(minLength: 0)
                    ValueSlider(
                        name: wording.levelHelp,
                        value: level,
                        range: EffectsList.levelRange,
                        width: SliderWidth.compact.points,
                        valueText: shownIsMixed ? "Mixed" : ClipVolumeControl.text(for: shownLevelDB),
                        widestValueText: ClipVolumeControl.text(for: EffectsList.levelRange.lowerBound),
                        mark: keepsMarkPlace ? Self.markSymbol : nil,
                        markName: wording.markHelp,
                        showsMark: shownIsChanged,
                        onMarkPressed: reset,
                        onHoldChange: { isHeld in
                            if !isHeld { settle() }
                        },
                        isUnavailable: shownIsOff
                    )
                    // A double-click puts the level at 0 dB, as on every volume slider. Only for an owner
                    // that listens.
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            heldLevelDB = nil
                            onLevelChange?(0, true)
                        },
                        isEnabled: hasOwner && onLevelChange != nil && !shownIsOff
                    )
                    .onDisappear { settle() }
                }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.small)
        .padding(.horizontal, Self.backingReach)
        .background(isLit ? DesignTokens.Colors.controlFillOn : Color.clear, in: DesignTokens.Shapes.control)
        .contentShape(DesignTokens.Shapes.control)
        .gesture(TapGesture().onEnded { onPress?() }, isEnabled: onPress != nil)
        .padding(.horizontal, -Self.backingReach)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(effect.kind.menuTitle), \(wording.place)\(shownIsOff ? ", switched off" : "")")
        .accessibilityAddTraits(isLit ? .isSelected : [])
    }
}

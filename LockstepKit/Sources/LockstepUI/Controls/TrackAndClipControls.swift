import SwiftUI

// The volume of a clip, the widths a slider can have, and at the end the two
// controls of a track in the panel on the right. The controls that
// tighten a clip are in `TightenControls.swift`. The clip's Resolve start time
// is `ResolveStartReadout`, with the other readouts.

/// The width of a slider.
public enum SliderWidth: Sendable {
    /// For a bar, a strip or a panel.
    case normal
    /// For a narrow place such as a track header (layout C).
    case compact

    var points: CGFloat {
        switch self {
        case .normal: DesignTokens.Sizes.sliderWidth
        case .compact: DesignTokens.Sizes.sliderWidthCompact
        }
    }
}

/// The volume of a clip: a slider from -12 to +12 dB with its value after it,
/// such as "+4.0 dB". The song's volume and a track's volume are the same
/// control with another range and name (`range`, `name`): the song can only
/// be turned down, from -24 to 0 dB, and a track goes from -24 to +12 dB.
///
/// Two things it can also show:
/// - Held back: the clip is played more quietly than the slider says, because
///   its loudest moment would otherwise go over the safe limit. A small arrow
///   against a line stands before the value.
/// - Mixed: several clips with different volumes are selected. The value reads
///   "Mixed" until the slider is moved, which gives every clip the same volume.
///
/// Without `onChange`, as in the design lab, moving the slider changes only
/// what it shows. With it, the control shows the volume it is given and
/// reports every move, and a double-click reports 0 dB:
///
///     ClipVolumeControl(volumeDB: clip.volumeDB) { volumeDB, isFinal in
///         model.setSelectedClipVolume(volumeDB, isFinal: isFinal)
///     }
public struct ClipVolumeControl: View {
    /// The lowest and highest volume, in dB.
    public static let range: ClosedRange<Double> = -12...12

    @State private var volumeDB: Double
    @State private var isMixed: Bool
    private let isHeldBack: Bool
    private let width: SliderWidth
    private let shownRange: ClosedRange<Double>
    private let name: String
    /// What the owner says the volume is, and whether it is mixed.
    private let given: (volumeDB: Double, isMixed: Bool)
    private let onChange: (@MainActor (_ volumeDB: Double, _ isFinal: Bool) -> Void)?
    /// Where the slider stands while it is being moved. Kept here so the
    /// slider follows the pointer without waiting for the owner.
    @State private var heldVolumeDB: Double?

    /// - Parameters:
    ///   - volumeDB: Inside `range`. 0 leaves the clip as recorded. For
    ///     several clips with different volumes, where the knob should stand
    ///     (their average).
    ///   - range: The lowest and highest volume, in dB. A clip's unless said.
    ///   - name: What the slider is called in its help tag.
    ///   - isHeldBack: Shows the mark for a volume that is being held back to
    ///     avoid clipping.
    ///   - isMixed: Shows "Mixed" in place of the number.
    ///   - onChange: Told the volume the slider stands at, in dB. `isFinal`
    ///     is false while the slider is still being moved and true once it
    ///     is let go, so one drag can be one change. A double-click tells 0,
    ///     final. Nil lets the control change what it shows by itself.
    public init(
        volumeDB: Double,
        range: ClosedRange<Double> = ClipVolumeControl.range,
        name: String = "Clip volume",
        width: SliderWidth = .normal,
        isHeldBack: Bool = false,
        isMixed: Bool = false,
        onChange: (@MainActor (_ volumeDB: Double, _ isFinal: Bool) -> Void)? = nil
    ) {
        let volumeDB = min(max(volumeDB, range.lowerBound), range.upperBound)
        shownRange = range
        self.name = name
        _volumeDB = State(initialValue: volumeDB)
        _isMixed = State(initialValue: isMixed)
        self.isHeldBack = isHeldBack
        self.width = width
        self.given = (volumeDB, isMixed)
        self.onChange = onChange
    }

    /// The volume to draw: the owner's when it is told of moves, unless the
    /// slider is being moved right now. The control's own otherwise.
    private var shownVolumeDB: Double {
        onChange == nil ? volumeDB : heldVolumeDB ?? given.volumeDB
    }

    private var shownIsMixed: Bool {
        onChange == nil ? isMixed : heldVolumeDB == nil && given.isMixed
    }

    private var value: Binding<Double> {
        guard let onChange else { return $volumeDB }
        return Binding(
            get: { shownVolumeDB },
            set: { volumeDB in
                heldVolumeDB = volumeDB
                onChange(volumeDB, false)
            }
        )
    }

    /// The slider was let go: the value it stands at is the one that counts.
    private func settle() {
        guard let final = heldVolumeDB else { return }
        onChange?(final, true)
        heldVolumeDB = nil
    }

    public var body: some View {
        ValueSlider(
            name: name,
            value: value,
            range: shownRange,
            width: width.points,
            valueText: shownIsMixed ? "Mixed" : Self.text(for: shownVolumeDB),
            widestValueText: Self.text(for: shownRange.lowerBound),
            mark: isHeldBack ? "arrow.down.to.line" : nil,
            markName: "Held back so the clip does not distort.",
            onHoldChange: { isHeld in
                if !isHeld { settle() }
            }
        )
        // Moving the slider gives every selected clip the volume it shows,
        // so the value is no longer mixed.
        .onChange(of: volumeDB) {
            isMixed = false
        }
        // A double-click puts the clip back as it was recorded. Only for an
        // owner that listens.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                heldVolumeDB = nil
                onChange?(0, true)
            },
            isEnabled: onChange != nil
        )
        .onDisappear { settle() }
    }

    /// "+4.0 dB", "-3.5 dB", and "0.0 dB" without a sign. The level of an effect is written the same way.
    static func text(for volumeDB: Double) -> String {
        let tenths = (volumeDB * 10).rounded() / 10
        if tenths == 0 { return "0.0 dB" }
        let sign = tenths > 0 ? "+" : "-"
        // Written with a point on every Mac, like the tempo beside it. The
        // system's own number style would write "+4,0 dB" on a Swedish Mac.
        return "\(sign)\(String(format: "%.1f", abs(tenths))) dB"
    }
}

/// The switch "Mute" of the selected track, in the panel on the right. On, the track is not heard, which is
/// what the lit mute button in the track's header shows too. The same as Track > Mute Track.
public struct TrackMuteSwitch: View {
    @State private var keptIsMuted: Bool
    private let givenIsMuted: Bool
    private let onChange: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - isMuted: Whether the track is muted.
    ///   - onChange: Told that the switch was switched: the owner then mutes the track or lets it be heard
    ///     again. Left out, the switch only changes how it looks.
    public init(isMuted: Bool, onChange: (@MainActor () -> Void)? = nil) {
        _keptIsMuted = State(initialValue: isMuted)
        givenIsMuted = isMuted
        self.onChange = onChange
    }

    private var isMuted: Binding<Bool> {
        Binding(
            get: { onChange == nil ? keptIsMuted : givenIsMuted },
            set: { isMuted in
                if let onChange { onChange() } else { keptIsMuted = isMuted }
            }
        )
    }

    public var body: some View {
        LabelledSwitch(title: "Mute", isOn: isMuted, help: "Mutes the track, or lets it be heard again")
    }
}

/// The "Normalize Track" button of the selected track, in the panel on the right: it brings every clip of
/// the track to the target loudness. The same as Track > Normalize Track. Pressing the button calls
/// `action`, and does nothing without one.
public struct NormalizeTrackButton: View {
    private let action: (@MainActor () -> Void)?

    public init(action: (@MainActor () -> Void)? = nil) {
        self.action = action
    }

    public var body: some View {
        PanelButton(title: "Normalize Track", help: "Bring every clip of the track to the target loudness") {
            action?()
        }
    }
}

import LockstepUI
import SwiftUI

extension LabState {
    /// Every shared control side by side, also the sizes and kinds the main
    /// window does not use yet. It was the component sheet `-layout controls`
    /// of phase 2.
    static let controls = LabState("Controls") {
        ControlsSheet()
    }
}

/// Every shared control in a row, each with its name under it, on the plain
/// window background.
private struct ControlsSheet: View {
    private let content = SampleContent.make()
    /// As wide as a row of the panel on the right, for a control that fills the width it is given.
    private static let panelRowWidth = DesignTokens.Sizes.inspectorWidth - 2 * DesignTokens.Spacing.panelPadding

    var body: some View {
        ScrollView {
            FlowLayout(
                spacing: DesignTokens.Spacing.xxLarge,
                rowSpacing: DesignTokens.Spacing.xxLarge
            ) {
                named("Transport") { TransportControls() }
                named("Transport, all active") {
                    TransportControls(isPlaying: true, isRecording: true, isLooping: true)
                }
                named("Transport, recording slower") { TransportControls(recordSpeedPercent: 85) }
                named("Time") { TimeReadout(content.timeText) }
                named("Tempo") { TempoReadout(content.tempoText) }
                named("Delay") { DelayReadout(milliseconds: 12) }
                named("Delay, not calibrated") { DelayReadout(milliseconds: nil) }
                named("Time, large") { TimeReadout(content.timeText, size: .large) }
                named("Tempo, large") { TempoReadout(content.tempoText, size: .large) }
                named("Delay, large") { DelayReadout(milliseconds: 12, size: .large) }
                named("Delay, not calibrated, large") { DelayReadout(milliseconds: nil, size: .large) }
                named("Microphone level") { MicLevelMeter(level: 0.6) }
                named("Click, on") { ClickControl(isOn: true) }
                named("Click, off") { ClickControl(isOn: false) }
                named("Send to DaVinci, in a bar") { SendToDaVinciButton() }
                named("Send to DaVinci, alone") { SendToDaVinciButton(surface: .standalone) }
                named("Snapping") { SnappingSwitch(isOn: true) }
                named("Snapping, in the bar") { SnappingButton(isOn: true) }
                named("Snapping, in the bar, off") { SnappingButton(isOn: false) }
                named("Snap To, the menu's arrow") { SnapToButton() }
                named("Correction") { CorrectionChoice(correction: .all) }
                named("Correction, off") { CorrectionChoice(correction: .off) }
                named("Correction, mixed") { CorrectionChoice(correction: nil) }
                named("Sub-beats of a clip") { ClipSubBeatsChoice(subBeats: .sixteenths) }
                named("Sub-beats of a clip, auto") { ClipSubBeatsChoice(subBeats: .auto) }
                named("Sub-beats of a clip, mixed") { ClipSubBeatsChoice(subBeats: nil) }
                named("Strength") { StrengthSlider(strength: 0.7) }
                named("Strength, compact") { StrengthSlider(strength: 0.7, width: .compact) }
                named("Strength, mixed") { StrengthSlider(strength: 0.45, isMixed: true) }
                named("Stretch") { StretchSwitch(isOn: true) }
                named("Stretch, off") { StretchSwitch(isOn: false) }
                named("Stretch, mixed") { StretchSwitch(isOn: nil) }
                named("Mute") { TrackMuteSwitch(isMuted: false) }
                named("Mute, on") { TrackMuteSwitch(isMuted: true) }
                named("Normalize Track") { NormalizeTrackButton() }
                named("Sound being made") { TightenProgressRing(progress: 0.4) }
                named("Sound of a track") { SoundMenuButton(soundName: "Rap lead").frame(width: Self.panelRowWidth) }
                named("Sound of a track, none") { SoundMenuButton(soundName: nil).frame(width: Self.panelRowWidth) }
                named("Knob of a track") { SoundKnobSlider(knob: .squeeze, value: 0.7) }
                named("Knob of a clip, following its track") {
                    SoundKnobSlider(knob: .space, value: 0.08, ofClip: .init(isTurned: false, trackValue: 0.08))
                }
                named("Knob of a clip, turned for itself") {
                    SoundKnobSlider(knob: .space, value: 0.6, ofClip: .init(isTurned: true, trackValue: 0.08))
                }
                named("Knob of clips, mixed") {
                    SoundKnobSlider(
                        knob: .space, value: 0.3, isMixed: true, ofClip: .init(isTurned: true, trackValue: 0.08)
                    )
                }
                named("Finished sounds being made") { SoundProgressRing(progress: 0.4) }
                named("Clip volume") { ClipVolumeControl(volumeDB: 4) }
                named("Clip volume, compact") { ClipVolumeControl(volumeDB: -3.5, width: .compact) }
                named("Clip volume, held back") { ClipVolumeControl(volumeDB: 9, isHeldBack: true) }
                named("Clip volume, mixed") { ClipVolumeControl(volumeDB: 1.3, isMixed: true) }
                named("Song volume") { ClipVolumeControl(volumeDB: -6, range: -24...0, name: "Song volume") }
                named("Track volume") { ClipVolumeControl(volumeDB: 4.5, range: -24...12, name: "Track volume") }
                named("Resolve start time") { ResolveStartReadout("01:00:20:12") }
                named("Resolve start time, large") { ResolveStartReadout("01:00:20:12", size: .large) }
            }
            .padding(DesignTokens.Spacing.xxLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One control with its name under it.
    private func named(_ name: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(spacing: DesignTokens.Spacing.medium) {
            control()
            Text(name)
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        }
    }
}

/// Places views in a row and starts a new row when the next one does not fit.
/// The views of a row stand on the same bottom line, so their names line up.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = makeRows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in makeRows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + row.height),
                    anchor: .bottomLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func makeRows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthWithView = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if widthWithView > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row(indices: [index], width: size.width, height: size.height)
            } else {
                row.indices.append(index)
                row.width = widthWithView
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

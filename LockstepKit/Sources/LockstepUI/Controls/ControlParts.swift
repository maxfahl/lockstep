import SwiftUI

// The pieces the shared controls are made of. They are used only inside this
// folder. A layout uses the finished controls in the other files.
//
// Every control here is borderless, so it can sit inside a glass bar or panel
// without putting glass on glass.

/// A square button that shows one symbol.
struct SymbolButton: View {
    /// The SF Symbol to show.
    let symbol: String
    /// The name, read out by VoiceOver, and the help tag when `help` is left out.
    let name: String
    var font: Font = DesignTokens.Fonts.symbol
    var width: CGFloat = DesignTokens.Sizes.smallButton
    var height: CGFloat = DesignTokens.Sizes.smallButton
    var color: Color = DesignTokens.Colors.textPrimary
    /// Draws the light backing of a control that is switched on.
    var showsOnFill: Bool = false
    /// The help tag, when it says more than the name.
    var help: String? = nil
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(color)
                .frame(width: width, height: height)
                .background(
                    showsOnFill ? DesignTokens.Colors.controlFillOn : Color.clear,
                    in: DesignTokens.Shapes.control
                )
                .contentShape(DesignTokens.Shapes.control)
        }
        .buttonStyle(.plain)
        .help(help ?? name)
        .accessibilityLabel(name)
    }
}

/// A choice between a few named options, shown side by side, with the chosen
/// one on a lighter backing.
struct SegmentedChoice<Value: Hashable>: View {
    /// The name of the choice, read out by VoiceOver, and the help tag when `help` is left out.
    let name: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    /// What the pointer is told when it rests on the choice: one sentence that says what it does. Nil shows
    /// the name.
    var help: String? = nil
    /// The options share the width the choice is given, each as wide as the others, as two choices that
    /// stand under each other in the panel on the right do. False leaves the choice as wide as its words.
    var fillsWidth = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.tight) {
            ForEach(options, id: \.value) { option in
                let isChosen = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(DesignTokens.Fonts.label)
                        .foregroundStyle(
                            isChosen ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary
                        )
                        .lineLimit(1)
                        .padding(.horizontal, fillsWidth ? DesignTokens.Spacing.small : DesignTokens.Spacing.medium)
                        .frame(maxWidth: fillsWidth ? .infinity : nil)
                        .frame(height: DesignTokens.Sizes.smallButton)
                        .background(
                            isChosen ? DesignTokens.Colors.controlFillOn : Color.clear,
                            in: DesignTokens.Shapes.control
                        )
                        .contentShape(DesignTokens.Shapes.control)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .padding(DesignTokens.Spacing.tight)
        .background(DesignTokens.Colors.controlFill, in: DesignTokens.Shapes.control)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .help(help ?? name)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }
}

/// What a box that opens a menu shows: the chosen line's words, and two small arrows at its right end. It
/// fills the width it is given and is as high as a small button. Use it as the label of a `Menu`.
struct MenuBoxLabel: View {
    /// The words of the chosen line.
    let text: String
    /// Draws the words quieter, for words that name no line of the menu, such as "Mixed".
    var isQuiet = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Text(text)
                .font(DesignTokens.Fonts.label)
                .foregroundStyle(isQuiet ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(DesignTokens.Fonts.symbolSmall)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.Sizes.smallButton, alignment: .leading)
        .background(DesignTokens.Colors.controlFill, in: DesignTokens.Shapes.control)
        .contentShape(DesignTokens.Shapes.control)
    }
}

/// A small switch with its title beside it.
struct LabelledSwitch: View {
    /// The title beside the switch, also the help tag when `help` is left out.
    let title: String
    @Binding var isOn: Bool
    /// What the pointer is told when it rests on the switch: one sentence that says what it does. Nil shows
    /// the title.
    var help: String? = nil

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(DesignTokens.Fonts.label)
            .foregroundStyle(DesignTokens.Colors.textPrimary)
            .tint(DesignTokens.Colors.accent)
            .fixedSize()
            .help(help ?? title)
    }
}

/// A slider with its value written after it. The value keeps the width of its
/// widest text, so the slider does not move when the number changes.
struct ValueSlider: View {
    /// The name shown as the help tag.
    let name: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let width: CGFloat
    /// The value as text, such as "70 %".
    let valueText: String
    /// The widest text the value can become, such as "100 %".
    let widestValueText: String
    /// A small symbol shown right before the value, for something the number
    /// alone does not say, such as a volume that is being held back. Nil
    /// shows none.
    var mark: String? = nil
    /// What the mark means, shown as its help tag.
    var markName: String = ""
    /// False keeps the mark's place empty: the mark is not drawn and cannot be pressed, and the slider
    /// stands where it would with the mark. Rows under each other whose marks come and go, such as the four
    /// knobs of a clip's Sound, then keep their sliders in one line.
    var showsMark = true
    /// What a press on the mark does. With it the mark is a button. Nil leaves it a picture.
    var onMarkPressed: (() -> Void)? = nil
    /// Told `true` when the slider is taken hold of and `false` when it is
    /// let go, so an owner can treat one drag as one change. Nil tells nobody.
    var onHoldChange: ((Bool) -> Void)? = nil
    /// What the pointer is told when it rests on the slider: one sentence that says what it does. Nil shows
    /// the name.
    var help: String? = nil
    /// Dims the slider and its value and makes the slider deaf, while what it sets counts for nothing. The
    /// mark stays as bright as ever and can still be pressed: it is the way back.
    var isUnavailable = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Slider(value: $value, in: range) { isHeld in
                onHoldChange?(isHeld)
            }
                .controlSize(.small)
                .tint(DesignTokens.Colors.accent)
                .frame(width: width)
                .accessibilityLabel(name)
                .disabled(isUnavailable)
                .opacity(isUnavailable ? DesignTokens.Opacity.unavailable : 1)
            HStack(spacing: DesignTokens.Spacing.small) {
                if let mark {
                    markView(mark)
                        .opacity(showsMark ? 1 : 0)
                        .allowsHitTesting(showsMark)
                        .accessibilityHidden(!showsMark)
                }
                Text(widestValueText)
                    .hidden()
                    .overlay(alignment: .trailing) {
                        Text(valueText)
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                    }
                    .font(DesignTokens.Fonts.value)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(isUnavailable ? DesignTokens.Opacity.unavailable : 1)
            }
        }
        .help(help ?? name)
    }

    /// The mark before the value: a picture, or a button when a press on it does something. The button is
    /// the same symbol in a square that is easier to hit.
    @ViewBuilder private func markView(_ mark: String) -> some View {
        let symbol = Image(systemName: mark)
            .font(DesignTokens.Fonts.symbolSmall)
            .foregroundStyle(DesignTokens.Colors.textPrimary)
        if let onMarkPressed {
            Button(action: onMarkPressed) {
                symbol
                    .frame(width: DesignTokens.Sizes.sliderMarkButton, height: DesignTokens.Sizes.sliderMarkButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(markName)
            .accessibilityLabel(markName)
        } else {
            symbol
                .help(markName)
                .accessibilityLabel(markName)
        }
    }
}

/// A small ring that fills while something is being made in the background. It stands in the line of a
/// heading in the panel on the right, and its owner takes it away when the making is done.
struct MakingRing: View {
    /// How far the making has come, from 0 to 1.
    let progress: Double
    /// What is being made, shown as the help tag and read out by VoiceOver.
    let name: String

    var body: some View {
        ProgressView(value: min(max(progress, 0), 1))
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .tint(DesignTokens.Colors.accent)
            .help(name)
            .accessibilityLabel(name)
    }
}

// The parts every section of the panel on the right is laid out with. `Inspector` builds its sections from
// them, and so does a section that is a view of its own (`VoiceSection`), so all sections look the same.

/// The heading of a section of the panel, with what belongs in its line at the right: the name of what the
/// section is about, a readout or a small control.
struct PanelHeading<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Text(title)
                .font(DesignTokens.Fonts.panelTitle)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .fixedSize()
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// What a control of the panel is, written before it or above it.
struct PanelLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(DesignTokens.Fonts.label)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// One line of the panel: what the control is on the left, the control on the right.
struct PanelRow<Control: View>: View {
    let label: String
    let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            PanelLabel(label)
            Spacer(minLength: 0)
            control
        }
    }
}

/// One quiet line of small text under a heading of the panel, which says what there is to do or what is
/// being done. A long one goes on over more lines.
struct PanelQuietLine: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(DesignTokens.Fonts.caption)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A button of the panel with words on it, on the fill of a control, as wide as its words.
struct PanelButton: View {
    let title: String
    /// What the pointer is told when it rests on the button.
    let help: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DesignTokens.Fonts.label)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, DesignTokens.Spacing.medium)
                .frame(height: DesignTokens.Sizes.smallButton)
                .background(DesignTokens.Colors.controlFill, in: DesignTokens.Shapes.control)
                .contentShape(DesignTokens.Shapes.control)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
        .accessibilityLabel(title)
    }
}

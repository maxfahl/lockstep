import SwiftUI

// The bar along the top of a clip, and the small things in it. `ClipView`
// puts the bar on the clip; nothing else uses what is in this file.

/// A part of a clip that the pointer can be over. `ClipView` answers the
/// pointer differently on each.
public enum ClipPart: Sendable, Equatable {
    /// The waveform under the bar.
    case body
    /// The bar, which is the handle the clip is dragged by.
    case bar
    /// The take count in the bar, which is the button that opens the takes.
    case takeCount
    /// The left edge of the clip, over its whole height. A drag from it
    /// trims the start of the clip.
    case startEdge
    /// The right edge of the clip. A drag from it trims the end of the clip.
    case endEdge
}

// MARK: - What fits

/// Which parts of a clip bar are shown at a given width.
///
/// A bar never shows a part cut in half, and never a name cut down to a
/// letter or two. When the clip gets narrower, whole parts go, the least
/// important first:
///
/// 1. the volume ("+4 dB"), which the height of the waveform shows too;
/// 2. the triplet mark;
/// 3. the mute mark, because a muted clip is dimmed anyway;
/// 4. the mark "FX" of an effect on the whole clip, which nothing else on
///    the clip shows;
/// 5. the name, when there is less room for it than
///    `DesignTokens.Sizes.clipNameMinimumWidth` (a name that is shorter than
///    that is shown as long as all of it fits);
/// 6. the take count, last, because it is a button.
///
/// A clip too narrow for any of them shows the bar alone. That is on
/// purpose: with a whole song in view a line is 10 to 40 points wide, and
/// no name can be read in that. The name is then in the help tag of the
/// bar, and in the inspector when the clip is selected.
///
/// A clip whose words are being worked out has no name yet. Its bar shows
/// three dots in the name's place, and "Writing out words…" after them when
/// there is room (`WritingOutWordsMark`).
///
/// The widths are counted, not measured, so that zooming does not have to
/// lay out text for every clip to find out what fits.
struct ClipBarFit: Equatable, Sendable {
    private(set) var showsTakeCount = false
    private(set) var showsName = false
    private(set) var showsMuteMark = false
    /// "FX", for a clip with an effect on the whole of it.
    private(set) var showsEffectsMark = false
    private(set) var showsTripletMark = false
    private(set) var showsVolume = false
    /// The dots of a clip whose words are being worked out. Such a clip has
    /// no name yet, so they stand where the name will be.
    private(set) var showsWritingOutDots = false
    /// The words "Writing out words…" after those dots.
    private(set) var showsWritingOutText = false

    /// - Parameters:
    ///   - clip: The clip whose bar it is.
    ///   - width: The width of the part of the bar that can be seen.
    init(clip: ClipBox, width: CGFloat) {
        let character = DesignTokens.Sizes.clipBarCharacterWidth
        let gap = DesignTokens.Spacing.small
        // The room a mark with a shape around it needs beside its text.
        let shape = 2 * DesignTokens.Spacing.small
        var room = width - 2 * DesignTokens.Spacing.clipBarPadding
        var isFirstPart = true

        // Takes the room for one part when it is there, with a gap to the
        // parts that are already in.
        func fits(_ partWidth: CGFloat) -> Bool {
            let needed = partWidth + (isFirstPart ? 0 : gap)
            guard room >= needed else { return false }
            room -= needed
            isFirstPart = false
            return true
        }

        // In the order of importance, the opposite of the list above.
        if clip.takeCount > 1 {
            showsTakeCount = fits(CGFloat(ClipBar.takeCountText(for: clip).count) * character + shape)
        }
        if !clip.displayName.isEmpty {
            let wholeName = CGFloat(clip.displayName.count) * character
            showsName = fits(min(wholeName, DesignTokens.Sizes.clipNameMinimumWidth))
        }
        if clip.isWritingOutWords, clip.displayName.isEmpty {
            showsWritingOutDots = fits(2 * character)
            if showsWritingOutDots {
                showsWritingOutText = fits(CGFloat(WritingOutWords.text.count) * character)
            }
        }
        if ClipBar.wholeClipEffects(of: clip) != nil {
            showsEffectsMark = fits(CGFloat(ClipBar.effectsMarkText.count) * character)
        }
        if clip.muted {
            showsMuteMark = fits(2 * character)
        }
        if clip.isTriplet {
            showsTripletMark = fits(character + shape)
        }
        if let volume = ClipBar.volumeText(for: clip) {
            showsVolume = fits(CGFloat(volume.count) * character)
        }
    }

    /// Something is shown at the left end of the bar.
    var hasLeadingParts: Bool { showsMuteMark || showsName || showsWritingOutDots }
    /// Something is shown at the right end of the bar.
    var hasTrailingParts: Bool { showsVolume || showsEffectsMark || showsTripletMark || showsTakeCount }
}

// MARK: - The bar

/// The bar along the top of a clip. From the left: a mute mark on a muted
/// clip and the name. From the right: the take count, the triplet mark, the
/// mark "FX" of an effect on the whole clip and the volume. `ClipBarFit`
/// decides which of them there is room for.
///
/// The bar is the handle a clip is dragged by, so the pointer becomes an
/// open hand over it. Over the take count it becomes a pointing hand.
struct ClipBar: View {
    @Environment(\.timelinePalette) private var palette

    let clip: ClipBox
    /// The width of the bar, which is the width of the drawn part of the clip.
    let width: CGFloat
    /// How much of the bar's left end cannot be seen, because it lies beyond
    /// the edge of the screen. The name starts after it.
    let hiddenLeading: CGFloat
    /// How much of the bar's right end cannot be seen, because it lies
    /// beyond the edge of the screen or under the next clip. The marks end
    /// before it.
    let hiddenTrailing: CGFloat
    /// False leaves the bar empty, for a clip that is being renamed: the
    /// name field lies over the bar then.
    let showsParts: Bool
    /// The part of the clip the pointer is over.
    let pointer: ClipPart?
    /// Set while the pointer is over the take count.
    @Binding var isPointerOverTakeCount: Bool
    /// What pressing the take count does. Nil leaves it doing nothing.
    var onTakeCount: (@MainActor () -> Void)?

    var body: some View {
        let fit = ClipBarFit(clip: clip, width: showsParts ? width - hiddenLeading - hiddenTrailing : 0)
        HStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.small) {
                if fit.showsMuteMark {
                    muteMark
                }
                if fit.showsName {
                    name
                }
                if fit.showsWritingOutDots {
                    WritingOutWordsMark(showsText: fit.showsWritingOutText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DesignTokens.Spacing.small) {
                if fit.showsVolume {
                    volumeMark
                }
                if fit.showsEffectsMark {
                    effectsMark
                }
                if fit.showsTripletMark {
                    tripletMark
                }
                if fit.showsTakeCount {
                    takeCountButton
                }
            }
            .fixedSize()
            // The gap between the two ends is there only when both have
            // something, so a lone take count gets by with the least room.
            .padding(
                .leading,
                fit.hasLeadingParts && fit.hasTrailingParts ? DesignTokens.Spacing.small : 0
            )
        }
        // The part of the bar that cannot be seen is skipped, so the name
        // and the marks stay in view.
        .padding(.leading, DesignTokens.Spacing.clipBarPadding + hiddenLeading)
        .padding(.trailing, DesignTokens.Spacing.clipBarPadding + hiddenTrailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DesignTokens.Sizes.clipBarHeight)
        .clipped()
        .clipBarSurface(isSelected: clip.isSelected, isHighlighted: pointer == .bar)
        .contentShape(Rectangle())
        .pointerStyle(.grabIdle)
        .modifier(HelpTag(text: clip.helpText ?? clip.displayName))
    }

    private var name: some View {
        Text(clip.displayName)
            .font(DesignTokens.Fonts.clipName)
            .foregroundStyle(palette.clipBarText)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityHidden(true)
    }

    /// A crossed-out speaker on a clip that is muted itself. A clip that is
    /// only dimmed because its track is muted does not have it.
    private var muteMark: some View {
        Image(systemName: "speaker.slash.fill")
            .font(DesignTokens.Fonts.clipBadge)
            .foregroundStyle(palette.clipBarBadge)
            .fixedSize()
            .help("Muted")
            .accessibilityHidden(true)
    }

    /// "+4 dB" or "-3.5 dB" on a clip that is turned up or down.
    @ViewBuilder private var volumeMark: some View {
        if let text = Self.volumeText(for: clip) {
            Text(text)
                .font(DesignTokens.Fonts.clipBadge)
                .foregroundStyle(palette.clipBarBadge)
                .fixedSize()
                .help("Clip volume")
                .accessibilityHidden(true)
        }
    }

    /// "FX" on a clip with an effect on the whole of it, such as a Thick
    /// double. An effect on a stretch has a band on the clip instead. The
    /// help tag names the effects.
    @ViewBuilder private var effectsMark: some View {
        if let names = Self.wholeClipEffects(of: clip) {
            Text(Self.effectsMarkText)
                .font(DesignTokens.Fonts.clipBadge)
                .foregroundStyle(palette.clipBarBadge)
                .fixedSize()
                .help("On the whole clip: \(names)")
                .accessibilityHidden(true)
        }
    }

    /// The mark of a clip whose lines run in triplets: a "3" in a thin ring,
    /// so it is not taken for a take number.
    private var tripletMark: some View {
        Text("3")
            .font(DesignTokens.Fonts.clipBadge)
            .foregroundStyle(palette.clipBarBadge)
            .padding(.horizontal, DesignTokens.Spacing.small)
            .frame(height: DesignTokens.Sizes.clipBadgeHeight)
            .overlay {
                Capsule(style: .continuous).strokeBorder(
                    palette.clipBarBadge,
                    lineWidth: DesignTokens.Lines.clipBadgeRingWidth
                )
            }
            .fixedSize()
            .help("Triplets")
            .accessibilityHidden(true)
    }

    /// "3/5" for a clip with several takes: take 3 of 5 is the one that
    /// plays. It is the button that shows the takes in the panel on the
    /// right, so it has a backing that lights up under the pointer.
    /// Pressing it calls `onTakeCount`.
    private var takeCountButton: some View {
        let isHot = pointer == .takeCount
        return Button(action: { onTakeCount?() }) {
            Text(Self.takeCountText(for: clip))
                .font(DesignTokens.Fonts.clipBadge)
                .foregroundStyle(isHot ? palette.clipBarText : palette.clipBarBadge)
                .padding(.horizontal, DesignTokens.Spacing.small)
                .frame(height: DesignTokens.Sizes.clipBadgeHeight)
                .background(
                    isHot
                        ? DesignTokens.Surfaces.clipBarButtonFillHovered
                        : DesignTokens.Surfaces.clipBarButtonFill,
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isPointerOverTakeCount = $0 }
        // The button goes away when the clip gets too narrow for it. Then
        // nothing would say that the pointer has left it.
        .onDisappear { isPointerOverTakeCount = false }
        .pointerStyle(.link)
        .help("Take \(clip.activeTakeNumber) of \(clip.takeCount). Show the takes in the panel.")
        .accessibilityLabel("Show takes")
    }

    /// What the mark of an effect on the whole clip reads.
    nonisolated static let effectsMarkText = "FX"

    /// The names of the clip's effects that are on the whole of it, such as
    /// "Thick, High", or nil for a clip without one.
    nonisolated static func wholeClipEffects(of clip: ClipBox) -> String? {
        let names = clip.ownEffects.filter { $0.range == nil }.map(\.kind.menuTitle)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// "3/5": the take that plays and how many there are.
    nonisolated static func takeCountText(for clip: ClipBox) -> String {
        "\(clip.activeTakeNumber)/\(clip.takeCount)"
    }

    /// "+4 dB", "-3.5 dB", or nil for a clip that is as loud as recorded.
    nonisolated static func volumeText(for clip: ClipBox) -> String? {
        let tenths = (clip.volumeDB * 10).rounded() / 10
        guard tenths != 0 else { return nil }
        let sign = tenths > 0 ? "+" : "-"
        // Written with a point on every Mac, like the tempo in the bar. The
        // system's own number style would write "-3,5 dB" on a Swedish Mac.
        let isWhole = tenths == tenths.rounded()
        return "\(sign)\(String(format: isWhole ? "%.0f" : "%.1f", abs(tenths))) dB"
    }
}

/// A help tag, left out when there is no text for it.
private struct HelpTag: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else {
            content.help(text)
        }
    }
}

// MARK: - Renaming

/// Where the name field of a clip that is being renamed goes.
struct ClipNameFieldPlace: Equatable, Sendable {
    /// The field's left edge, counted from the left edge of the clip's own view.
    var minX: CGFloat
    var width: CGFloat
}

/// The field a clip's name is typed in. It lies over the clip's bar, takes
/// the bar's place and has the bar's colour around it, so the bar seems to
/// have become a field.
///
/// Without `onEnd` it is a picture of how renaming looks at the moment it
/// starts: the whole name is selected, and nothing can be typed. The design
/// lab shows it this way.
///
/// With `onEnd` the system's text field stands in the same place (`TypedName`,
/// the one a track's name is typed in). It takes the keyboard as it appears,
/// with the whole name selected. The typing ends, and `onEnd` is told once,
/// when Return is pressed, when anything else in the window is clicked, when
/// Tab is pressed or when the field is taken away (all with the name as
/// typed), or when Escape is pressed (with nil).
struct ClipNameField: View {
    let name: String
    let place: ClipNameFieldPlace
    /// The clip is selected, so the bar around the field has that colour.
    let isSelected: Bool
    /// Told when the typing is over: the name as typed, or nil for Escape.
    /// Nil leaves the field a picture.
    var onEnd: (@MainActor (String?) -> Void)? = nil

    var body: some View {
        content
            .font(DesignTokens.Fonts.clipName)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(DesignTokens.Surfaces.clipNameFieldFill, in: DesignTokens.Shapes.clipNameField)
            .overlay {
                DesignTokens.Shapes.clipNameField.strokeBorder(
                    DesignTokens.Colors.accent,
                    lineWidth: DesignTokens.Lines.clipNameFieldRingWidth
                )
            }
            .padding(DesignTokens.Spacing.tight)
            .frame(width: place.width, height: DesignTokens.Sizes.clipBarHeight)
            .clipBarSurface(isSelected: isSelected)
            .offset(x: place.minX)
            .pointerStyle(.horizontalText)
            .modifier(PictureOfClipName(name: name, isPicture: onEnd == nil))
    }

    @ViewBuilder private var content: some View {
        if let onEnd {
            TypedName(name: name, label: "Clip name", onEnd: onEnd)
        } else {
            text
        }
    }

    @ViewBuilder private var text: some View {
        if name.isEmpty {
            Text("Name")
                .foregroundStyle(DesignTokens.Colors.textTertiary)
        } else {
            Text(name)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .background(DesignTokens.Surfaces.clipNameFieldSelection)
        }
    }
}

/// What a screen reader is told about the picture of the field. The real
/// field speaks for itself.
private struct PictureOfClipName: ViewModifier {
    let name: String
    let isPicture: Bool

    func body(content: Content) -> some View {
        if isPicture {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Clip name")
                .accessibilityValue(name)
        } else {
            content
        }
    }
}

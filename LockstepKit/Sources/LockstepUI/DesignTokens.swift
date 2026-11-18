import SwiftUI

/// Every colour, type size, spacing, corner radius and height the views use.
///
/// The rule: no view in `LockstepUI` writes a colour or a size itself. It takes
/// a value from here, so the whole look can be tuned in this one file.
///
/// The app is dark only. Every colour below is a fixed value, so none of them
/// changes with the Mac's light or dark setting.
///
/// What is drawn inside a timeline (waveforms, beat lines, clips, the ruler,
/// the playhead) has two sets of colours: one for glass rows and one for the
/// plain rows of a timeline that lies on a glass panel. Those are in
/// `TimelinePalette`, which a view reads from the environment.
public enum DesignTokens {

    // MARK: - Colours

    public enum Colors {

        // Backgrounds. Used by `WindowBackground`, and by `laneSurface()` and
        // `laneHeaderSurface()` when rows are plain (not glass).

        /// Behind everything in a window.
        public static let windowBackground = Color(hex: 0x0B0B0E)
        /// A timeline row (the song, a track, a take) when rows are plain.
        public static let laneBackground = Color(hex: 0x141418)
        /// The header to the left of a row when rows are plain.
        public static let laneHeaderBackground = Color(hex: 0x19191E)
        /// A thin dividing line between two areas that are not glass.
        public static let separator = Color.white.opacity(0.10)
        /// Behind a small control that sits on a plain surface, such as a value box.
        public static let controlFill = Color.white.opacity(0.08)
        /// Behind a control that is switched on, and behind the chosen part of
        /// a choice such as Before / After. Lighter than `controlFill`.
        public static let controlFillOn = Color.white.opacity(0.16)
        /// Over a row that the pointer rests on, when a click on the row does
        /// something: a take's row in the takes list.
        public static let rowHover = Color.white.opacity(0.08)

        // Text and symbols. Used by every label, readout, button symbol and
        // header. They are fixed light tones, readable on glass and on the
        // plain dark rows.

        /// Names, readouts, the main symbol of a button.
        public static let textPrimary = Color.white.opacity(0.92)
        /// Units ("BPM", "ms"), captions, a switched-off symbol, "Not calibrated".
        public static let textSecondary = Color.white.opacity(0.62)
        /// The faintest text that must still be readable: hints, placeholders.
        public static let textTertiary = Color.white.opacity(0.42)

        // The accent. The one colour besides the neutrals: the selected track's
        // mark, a switched-on control, the prominent button. Clip waveforms use
        // it too, through `TimelinePalette`.

        /// The accent colour.
        public static let accent = Color(hex: 0x8A8FFF)
        /// The mark in a track header that says recordings go to this track.
        public static let selectedTrackMark = accent

        // Record. The only red in the app: the Record button and, later, the
        // take being recorded.

        /// The record red.
        public static let record = Color(hex: 0xFF453A)

        // A recording in progress, drawn on its track. All of it is the
        // record red, at different strengths.

        /// The body of the clip that is being recorded, behind its waveform.
        public static let recordingClipFill = record.opacity(0.20)
        /// The bar of the clip that is being recorded. Dark enough for light text.
        public static let recordingClipBar = Color(hex: 0x8E2A25)
        /// The outline of the clip that is being recorded, and the line at
        /// the place where the recording starts.
        public static let recordingClipOutline = record.opacity(0.85)

        // Timing. The three colours of the syllable markers (worked out in the
        // next design phase, used from the markers phase on). They differ in
        // lightness as well as hue, brightest for "on the beat", so they can be
        // told apart with red-green colour blindness. No other element may use
        // these colours. They are chosen against the dark row. Right on top of
        // a clip's waveform they are close to it in lightness, so a marker
        // needs a dark edge or a place above the waveform.

        /// A syllable that is on the beat. The brightest of the three.
        public static let timingOnBeat = Color(hex: 0x8CF0CE)
        /// A syllable that is slightly off. Middle lightness.
        public static let timingSlightlyOff = Color(hex: 0xF09A2E)
        /// A syllable far from any sub-beat, so off on purpose. The darkest.
        public static let timingNeutral = Color(hex: 0x82828E)
        /// The dark edge around a syllable marker, and the inside of a hollow
        /// one. It keeps a marker readable where it lies on a waveform.
        public static let timingMarkerEdge = Color(hex: 0x0B0B0E, opacity: 0.85)
        /// Behind the readout at a marker ("23 ms late"). Plain and dark,
        /// because the row under it is glass.
        public static let timingReadoutBackground = Color(hex: 0x0B0B0E, opacity: 0.90)

        // The microphone level meter. Neutral on purpose: colour means timing.

        /// The empty part of the level meter.
        public static let meterTrack = Color.white.opacity(0.12)
        /// The filled part of the level meter.
        public static let meterFill = Color.white.opacity(0.72)

        // Dragging. What is drawn while a clip is moved, a stretch is marked
        // or a track is moved up or down. All of it is the accent or a
        // neutral: the timing colours and the record red stay what they are.

        /// Inside the faint mark at the place a clip was recorded, shown
        /// while the clip is moved.
        public static let recordedPlaceFill = accent.opacity(0.08)
        /// The dashed outline of that mark.
        public static let recordedPlaceOutline = accent.opacity(0.60)
        /// Behind a clip that is lifted, so the row under it does not show
        /// through its see-through body.
        public static let liftedClipBacking = Color(hex: 0x17182E)
        /// Behind a track header that is lifted.
        public static let liftedHeaderFill = Color(hex: 0x24242B)
        /// The shadow under anything that is lifted.
        public static let liftShadow = Color.black.opacity(0.55)
        /// The line at the point a moved clip snapped to.
        public static let snapLine = accent
        /// The band over a marked stretch of a track.
        public static let markedStretchFill = accent.opacity(0.24)
        /// The thin edges of a marked stretch, and of the loop region.
        public static let markedStretchEdge = Color(hex: 0xB4B8FF)
        /// The loop region in the ruler.
        public static let loopRegionFill = accent.opacity(0.34)
        /// The loop's in and out in the ruler while Loop is off: a faint
        /// band, much quieter than a loop that plays.
        public static let loopInOutFill = accent.opacity(0.10)
        /// The bracket at the loop's in and at its out while Loop is off.
        public static let loopInOutMark = Color(hex: 0xB4B8FF).opacity(0.85)
        /// The line that shows where a track that is being moved will land.
        public static let trackLandingLine = accent
        /// Laid over the row of a track while its header is dragged away.
        public static let movedTrackVeil = Color.black.opacity(0.40)
        /// The end of the level meter when the microphone is too loud. It is
        /// the record red, because the sound that clips is the recording.
        public static let meterClipMark = record

        // Effects on a clip. The band along the bottom of a clip over the stretch an effect is on. All of
        // it is neutral: colour on a clip means timing, and the accent is the waveform under the band.

        /// Behind a band. Dark and see-through, so the kind's name can be read on the waveform and the
        /// waveform still shows through.
        public static let effectBandFill = Color(hex: 0x0B0B0E, opacity: 0.55)
        /// The thin line around a band.
        public static let effectBandEdge = Color.white.opacity(0.50)
        /// The line around the band whose row is lit in the panel on the right.
        public static let effectBandEdgeSelected = Color.white.opacity(0.95)
        /// The kind's name in a band.
        public static let effectBandText = Color.white.opacity(0.88)
        /// A band that is too low for a name, in a low row or under many others: a bright line alone.
        public static let effectBandLine = Color.white.opacity(0.80)
        /// The dark edge around such a line, which keeps it readable where it lies on a waveform, as the
        /// edge of a syllable marker does.
        public static let effectBandLineEdge = Color(hex: 0x0B0B0E, opacity: 0.85)

        // The beat line under the pointer.

        /// A beat line that can be dragged, while the pointer is over it.
        /// Bright and neutral, like the playhead.
        public static let beatLineHovered = Color.white.opacity(0.92)
    }

    // MARK: - Type

    /// Fixed type sizes. Every one uses digits of equal width, so numbers do
    /// not jitter when they change.
    public enum Fonts {

        // Readouts: time, tempo, delay, Resolve start time.

        /// A readout at its normal size ("0:20", "91.4", "12 ms").
        public static let readout = Font.system(size: 13, weight: .medium).monospacedDigit()
        /// A large, technical-looking readout (layout C).
        public static let readoutLarge = Font.system(size: 28, weight: .medium, design: .monospaced)
        /// The unit or caption next to a normal readout ("BPM", "ms").
        public static let readoutUnit = Font.system(size: 10, weight: .medium).monospacedDigit()
        /// The unit or caption next to a large readout.
        public static let readoutUnitLarge = Font.system(size: 11, weight: .semibold).monospacedDigit()
        /// The timecode in the Send to DaVinci panel. The largest text in the app.
        public static let timecodeLarge = Font.system(size: 44, weight: .medium, design: .monospaced)

        // Controls and panels.

        /// The text of a control: a button title, a switch label, a choice.
        public static let label = Font.system(size: 12, weight: .regular).monospacedDigit()
        /// The value next to a slider ("70 %", "+4.0 dB").
        public static let value = Font.system(size: 11, weight: .regular).monospacedDigit()
        /// A heading inside a panel, such as the inspector's sections.
        public static let panelTitle = Font.system(size: 12, weight: .semibold).monospacedDigit()
        /// Small secondary text under or beside something.
        public static let caption = Font.system(size: 10, weight: .regular).monospacedDigit()
        /// The title at the top of a sheet.
        public static let sheetTitle = Font.system(size: 15, weight: .semibold).monospacedDigit()
        /// The words in the middle of the window before a song is dropped.
        public static let emptyWindowTitle = Font.system(size: 20, weight: .medium)

        // Symbols (SF Symbols) in buttons.

        /// A transport symbol: Play, Record, Loop.
        public static let symbolLarge = Font.system(size: 16, weight: .medium)
        /// A symbol in an ordinary control: the click toggle, Send to DaVinci.
        public static let symbol = Font.system(size: 13, weight: .medium)
        /// A small symbol: a track's mute button, the arrow that opens a popover, "+".
        public static let symbolSmall = Font.system(size: 10, weight: .semibold)

        // The timeline.

        /// The name of the song, a track or a take in its row header.
        public static let laneName = Font.system(size: 12, weight: .semibold).monospacedDigit()
        /// The name of a clip in its bar.
        public static let clipName = Font.system(size: 10, weight: .medium).monospacedDigit()
        /// The small marks in a clip bar: the take count "3/5", the triplet "3".
        public static let clipBadge = Font.system(size: 9, weight: .semibold).monospacedDigit()
        /// The kind's name in the band of an effect on a clip.
        public static let effectBandName = Font.system(size: 8, weight: .semibold).monospacedDigit()
        /// Bar numbers and time marks in the ruler.
        public static let rulerLabel = Font.system(size: 10, weight: .regular).monospacedDigit()
    }

    // MARK: - Spacing

    public enum Spacing {

        // The general steps, for padding and gaps that have no name below.

        public static let tight: CGFloat = 2
        public static let small: CGFloat = 4
        public static let medium: CGFloat = 8
        public static let large: CGFloat = 12
        public static let xLarge: CGFloat = 16
        public static let xxLarge: CGFloat = 24

        // Chrome: bars, panels, the floating capsule.

        /// From the window's edge to a glass bar, panel or capsule that floats inside it.
        public static let windowInset: CGFloat = 8
        /// Inside a glass bar or capsule, left and right of its content.
        public static let barPadding: CGFloat = 12
        /// Inside a glass panel, around its content.
        public static let panelPadding: CGFloat = 12
        /// Between two controls that belong together (Play and Record).
        public static let controlGap: CGFloat = 6
        /// Between two groups of controls in a bar (transport and readouts).
        public static let groupGap: CGFloat = 20
        /// Between two sections of a panel.
        public static let sectionGap: CGFloat = 16

        // The timeline.

        /// Between two rows, and between a row's header and its body.
        public static let laneGap: CGFloat = 3
        /// Inside a row header, around its content.
        public static let headerPadding: CGFloat = 8
        /// Above and below the clips inside a track row.
        public static let clipInset: CGFloat = 2
        /// Inside a clip bar, left and right of the name.
        public static let clipBarPadding: CGFloat = 5
    }

    // MARK: - Corner radii

    public enum Radius {
        /// A glass bar or strip.
        public static let bar: CGFloat = 14
        /// A glass panel, such as the inspector.
        public static let panel: CGFloat = 16
        /// A timeline row and its header.
        public static let lane: CGFloat = 8
        /// A clip, and the top corners of its bar.
        public static let clip: CGFloat = 5
        /// The field inside a clip bar that the clip's name is typed in.
        public static let clipNameField: CGFloat = 3
        /// A small control drawn by us, such as a value box.
        public static let control: CGFloat = 6
    }

    // MARK: - Shapes

    /// The outlines that go with the radii above, so no view builds its own.
    public enum Shapes {
        /// A glass bar or strip.
        public static var bar: RoundedRectangle {
            RoundedRectangle(cornerRadius: Radius.bar, style: .continuous)
        }
        /// A glass panel.
        public static var panel: RoundedRectangle {
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        }
        /// A timeline row or its header.
        public static var lane: RoundedRectangle {
            RoundedRectangle(cornerRadius: Radius.lane, style: .continuous)
        }
        /// A whole clip: its fill and its outline.
        public static var clip: RoundedRectangle {
            RoundedRectangle(cornerRadius: Radius.clip, style: .continuous)
        }
        /// The bar on top of a clip: round at the top, square where it meets the waveform.
        public static var clipBar: UnevenRoundedRectangle {
            UnevenRoundedRectangle(
                topLeadingRadius: Radius.clip,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Radius.clip,
                style: .continuous
            )
        }
        /// The field inside a clip bar that the clip's name is typed in.
        public static var clipNameField: RoundedRectangle {
            RoundedRectangle(cornerRadius: Radius.clipNameField, style: .continuous)
        }
        /// A small control drawn by us.
        public static var control: RoundedRectangle {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        }
    }

    // MARK: - Sizes

    public enum Sizes {

        // The window.

        public static let minimumWindowWidth: CGFloat = 900
        public static let minimumWindowHeight: CGFloat = 560

        // Chrome.

        /// A glass bar across the top with normal readouts.
        public static let barHeight: CGFloat = 52
        /// A glass bar across the top with large readouts (layout C).
        public static let barHeightLarge: CGFloat = 72
        /// The slim strip along the bottom (layout A).
        public static let stripHeight: CGFloat = 44
        /// The floating transport capsule (layout B).
        public static let floatingBarHeight: CGFloat = 52
        /// The inspector panel on the right (layout B).
        public static let inspectorWidth: CGFloat = 240

        // Controls.

        /// The square a transport button fills.
        public static let transportButton: CGFloat = 30
        /// The square a small button fills, such as a track's mute button.
        public static let smallButton: CGFloat = 22
        /// The narrow button with the small arrow that opens a popover, beside
        /// the click toggle, and the one that opens the Snap To menu beside
        /// the snapping button. As tall as a transport button.
        public static let popoverArrowWidth: CGFloat = 14
        /// The microphone level meter.
        public static let meterWidth: CGFloat = 72
        public static let meterHeight: CGFloat = 4
        /// The piece at the end of the level meter that lights up when the
        /// microphone is too loud.
        public static let meterClipMarkWidth: CGFloat = 6
        /// A slider in a bar, strip or panel (strength, clip volume).
        public static let sliderWidth: CGFloat = 120
        /// A small slider inside a track header (layout C).
        public static let sliderWidthCompact: CGFloat = 72
        /// The square of a mark before a slider's value that is a button, such as the one that puts a
        /// clip's knob back to its track's value.
        public static let sliderMarkButton: CGFloat = 16

        /// The small button in the line of a heading in the panel on the right, such as the one that adds
        /// an effect: as wide as a small button and as low as the heading's own line.
        public static let headingButtonHeight: CGFloat = 16

        // What opens on top of the window.

        /// The popover with the click's sound, volume and how often it clicks.
        public static let clickPopoverWidth: CGFloat = 240
        /// A sheet: Calibrate, Send to DaVinci.
        public static let sheetWidth: CGFloat = 460
        /// A small field that holds a timecode such as "01:00:00:00".
        public static let timecodeFieldWidth: CGFloat = 104
        /// One clip in the Send to DaVinci panel's list, when several clips are sent.
        public static let sendClipRowHeight: CGFloat = 36
        /// How many clips that list shows before it scrolls.
        public static let sendClipRowsShown = 6
        /// The widest a message at the top of the window may be.
        public static let messageBannerMaximumWidth: CGFloat = 520
        /// The height of a message at the top of the window.
        public static let messageBannerHeight: CGFloat = 36

        // Timeline rows.

        /// The ruler with bar numbers.
        public static let rulerHeight: CGFloat = 24
        /// The song row.
        public static let songLaneHeight: CGFloat = 64
        /// A vocal track row, until its height is changed with Shift and scroll.
        public static let trackLaneHeight: CGFloat = 72
        /// The lowest a vocal track row can be made: half of `trackLaneHeight`.
        /// The clip's bar and a strip of waveform still fit.
        public static let trackLaneMinimumHeight: CGFloat = 36
        /// The tallest a vocal track row can be made: four times `trackLaneHeight`.
        public static let trackLaneMaximumHeight: CGFloat = 288
        /// One take in the small takes timeline.
        public static let takeLaneHeight: CGFloat = 32
        /// One take when its row also shows the take's words above the waveform.
        public static let takeLaneHeightWithText: CGFloat = 40
        /// The line for the take's words at the top of such a row.
        public static let takeTextLineHeight: CGFloat = 14
        /// The row under the last track that holds the "New Track" button.
        public static let newTrackRowHeight: CGFloat = 28

        // Row headers.

        /// The header column of the main timeline.
        public static let headerWidth: CGFloat = 180
        /// The narrow header column of the takes list in the panel on the
        /// right: room for a take's Play button, its number with two digits
        /// and the tick of the take that is chosen.
        public static let headerWidthNarrow: CGFloat = 68
        /// The coloured mark in the header of the selected track.
        public static let selectedTrackMarkWidth: CGFloat = 3

        // Clips.

        /// The bar on top of a clip.
        public static let clipBarHeight: CGFloat = 16
        /// A mark in a clip bar that has a shape around it: the take count
        /// "3/5" and the triplet "3".
        public static let clipBadgeHeight: CGFloat = 12
        /// The least room a clip's name is shown in, about six letters. With
        /// less room the bar shows no name at all, instead of one or two
        /// letters and an ellipsis.
        public static let clipNameMinimumWidth: CGFloat = 36
        /// The room one letter or digit in a clip bar is counted to take when
        /// the bar works out what fits. It is a little more than the real
        /// width, so what is counted to fit does fit.
        public static let clipBarCharacterWidth: CGFloat = 6
        /// The least width of the field a clip's name is typed in. On a
        /// narrower clip the field reaches out past the clip's right edge.
        public static let clipNameFieldMinimumWidth: CGFloat = 120
        /// How far in from the left or the right edge of a clip the pointer
        /// takes hold of that edge, to trim the clip. A clip narrower than
        /// four times this has narrower edges (`ClipEdgeZone`).
        public static let clipEdgeGrabWidth: CGFloat = 6
        /// The bright bar along an edge of a clip that the pointer is over,
        /// or that is being dragged.
        public static let clipEdgeHandleWidth: CGFloat = 3

        // Effects on a clip.

        /// The band of an effect on a stretch of a clip, when it has room for the kind's name.
        public static let effectBandHeight: CGFloat = 10
        /// The same band as a line alone, where named bands would take too much of the clip.
        public static let effectBandLineHeight: CGFloat = 3
        /// Between two bands that lie over each other, and under the lowest one.
        public static let effectBandGap: CGFloat = 1
        /// From the clip's lower edge and its ends to a band, so the band stays inside the outline.
        public static let effectBandInset: CGFloat = 3
        /// The share of the height under a clip's bar the named bands may take together. With more, every
        /// band is a line alone.
        public static let effectBandsShareOfBody: CGFloat = 0.45
        /// The corner of a band.
        public static let effectBandCorner: CGFloat = 2

        // Timing markers on a selected clip.

        /// The dot on top of a syllable marker.
        public static let markerDotDiameter: CGFloat = 7
        /// The tick under the dot. Its left edge is where the syllable starts.
        public static let markerTickHeight: CGFloat = 9
        /// How far to the left and right of a marker the pointer brings up
        /// its readout.
        public static let markerHoverReach: CGFloat = 5
        /// The zoom, in points per second, from which a marker has its dot.
        /// Further out the dots of neighbouring syllables would run together,
        /// so a marker is a tick alone.
        public static let markerDotsFromZoom: Double = 40
        /// The zoom, in points per second, from which markers are drawn at
        /// all. Further out even the ticks would run together.
        public static let markerTicksFromZoom: Double = 10
        /// The least distance between two sub-beat lines. Zoomed out so far
        /// that they would lie closer, they are not drawn.
        public static let subBeatLineMinimumSpacing: CGFloat = 5
        /// The small bar on top of a line at a lead syllable, right under the
        /// clip's bar: how wide it is, centred on the line.
        public static let leadSyllableCapWidth: CGFloat = 7
        /// How high that small bar is. It fits in the room between the
        /// clip's bar and the dots of the markers.
        public static let leadSyllableCapHeight: CGFloat = 2

        // The ruler and the playhead.

        /// The tick at a beat.
        public static let rulerBeatTickHeight: CGFloat = 5
        /// The taller tick at the start of a bar.
        public static let rulerBarTickHeight: CGFloat = 10
        /// The least distance between two bar numbers before labels are skipped.
        public static let rulerMinimumLabelSpacing: CGFloat = 40
        /// The small head of the playhead, drawn in the ruler.
        public static let playheadHeadWidth: CGFloat = 9
        public static let playheadHeadHeight: CGFloat = 7

        // Right-click menus. The menus themselves are the system's; these
        // size the plain list that shows a menu's contents in the design lab,
        // and what a right-click hits.

        /// The plain list of a menu's contents.
        public static let menuListingWidth: CGFloat = 260
        /// The column on the left of that list that holds a tick.
        public static let menuTickColumnWidth: CGFloat = 14
        /// How wide the strip around a beat line is that a right-click hits.
        public static let beatLineMenuTargetWidth: CGFloat = 7

        // Dragging.

        /// How far up a lifted clip is drawn from the row it is over.
        public static let clipLift: CGFloat = 3
        /// How soft the shadow under a lifted clip or track header is.
        public static let liftShadowRadius: CGFloat = 8
        /// How far below a lifted clip or track header its shadow falls.
        public static let liftShadowOffset: CGFloat = 4
        // Recording and beat lines under the pointer.

        /// How near a beat line the pointer must be, to either side, for the
        /// line to light up as something that can be dragged.
        public static let beatLineGrabDistance: CGFloat = 3.5
        /// How near an edge of the song the pointer must be, to either side,
        /// for the edge to light up as something that can be dragged.
        public static let songEdgeGrabDistance: CGFloat = 5
        /// The least width at which the clip that is being recorded shows
        /// the word "Recording" in its bar.
        public static let recordingClipLabelMinimumWidth: CGFloat = 84
        /// The height of the field a track's name is typed in.
        public static let trackNameFieldHeight: CGFloat = 20
    }

    // MARK: - Lines

    /// Line widths and dash patterns. The colours of these lines are in
    /// `TimelinePalette`.
    public enum Lines {
        /// A beat line through the rows.
        public static let beatWidth: CGFloat = 1
        /// A bar line through the rows. Stronger by colour, not by width.
        public static let barWidth: CGFloat = 1
        /// The dash of an estimated beat, and of the beats in an uncertain stretch.
        public static let estimatedBeatDash: [CGFloat] = [3, 3]
        /// The playhead.
        public static let playheadWidth: CGFloat = 1
        /// A tick in the ruler.
        public static let rulerTickWidth: CGFloat = 1
        /// The outline of a clip.
        public static let clipOutlineWidth: CGFloat = 1
        /// The stronger outline of a selected clip.
        public static let clipOutlineSelectedWidth: CGFloat = 2
        /// The least height of a waveform, so silence shows as a thin line
        /// instead of nothing.
        public static let waveformSilenceHeight: CGFloat = 1
        /// The thin ring around the triplet "3" in a clip bar.
        public static let clipBadgeRingWidth: CGFloat = 1
        /// The ring around the field a clip's name is typed in.
        public static let clipNameFieldRingWidth: CGFloat = 1
        /// A sub-beat line across a selected clip. Fainter than a beat line
        /// by colour, not by width.
        public static let subBeatWidth: CGFloat = 1
        /// A line at a syllable of the track a selected clip aims at. Told
        /// from a sub-beat line by its strength and the small bar on top.
        public static let leadSyllableWidth: CGFloat = 1
        /// The tick of a syllable marker.
        public static let markerTickWidth: CGFloat = 1
        /// The dark edge around a syllable marker.
        public static let markerEdgeWidth: CGFloat = 1
        /// The ring of a hollow marker, and the light ring around the marker
        /// whose readout is shown.
        public static let markerRingWidth: CGFloat = 1.5
        /// The thin line around the band of an effect on a clip.
        public static let effectBandEdgeWidth: CGFloat = 1
        /// A dividing line between two plain areas.
        public static let separatorWidth: CGFloat = 1

        // Dragging.

        /// The outline of the mark at the place a clip was recorded.
        public static let recordedPlaceOutlineWidth: CGFloat = 1
        /// The dash of that outline.
        public static let recordedPlaceDash: [CGFloat] = [4, 3]
        /// The line at the point a moved clip snapped to.
        public static let snapLineWidth: CGFloat = 1
        /// The snap line when the point is the playhead. The playhead is
        /// drawn on top of it, so it is wider and shows on both sides.
        public static let snapLineOnPlayheadWidth: CGFloat = 3
        /// The edges of a marked stretch and of the loop region.
        public static let markedStretchEdgeWidth: CGFloat = 1
        /// The upright of the bracket at the loop's in or out while Loop is
        /// off, and its two short arms.
        public static let loopInOutMarkWidth: CGFloat = 1.5
        /// How far the arms of that bracket reach into the stretch.
        public static let loopInOutMarkArm: CGFloat = 5
        /// The line that shows where a moved track will land.
        public static let trackLandingLineWidth: CGFloat = 2
        /// The line on a track at the place where the recording starts.
        public static let recordOriginWidth: CGFloat = 2
        /// A beat line while the pointer is over it.
        public static let beatHoveredWidth: CGFloat = 3
        /// The edge of the song where its beginning or end is cut away, and
        /// either edge while the pointer is over it.
        public static let songEdgeWidth: CGFloat = 3
    }

    // MARK: - Opacity

    public enum Opacity {
        /// A muted clip, and every clip on a muted track.
        public static let muted: Double = 0.38
        /// A take's row when the take is about to be deleted.
        public static let aboutToBeDeleted: Double = 0.3
        /// A control that cannot be used right now, such as Strength while the correction is Off.
        public static let unavailable: Double = 0.5
    }
}

extension Color {
    /// A fixed colour from its six-digit code, such as `0x8A8FFF`. Only the
    /// design values are written this way.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

import LockstepCore
import SwiftUI

/// Which right-click menus the main timeline attaches: the clip's on every
/// clip, the track's on every track header, the song's on the song row and
/// the beat line's on the beat lines of the song row.
///
///     MainTimeline(content: content, scale: $scale, playhead: playhead,
///                  menus: TimelineMenus(features: features))
///
/// Choosing a command does nothing yet, except the commands about the beats,
/// which report to `onSongCommand` and `onBeatOne`, and Mute Clip and Delete
/// in the clip's menu, which report to `onClipCommand`. What a menu ticks and
/// greys out is read from the content where the content says it (a muted
/// clip, the number of takes), and is a fixed value where it does not yet.
public struct TimelineMenus: Sendable {
    public var showsClipMenu: Bool
    public var showsTrackMenu: Bool
    /// What the song's menu ticks. Nil leaves the song row without a menu.
    public var song: SongMenu.Values?
    public var showsBeatMenu: Bool
    /// Told when Find Beats Again, Halve Tempo or Double Tempo is chosen in
    /// the song's menu. Nil leaves them doing nothing.
    public var onSongCommand: (@MainActor (SongMenu.Command) -> Void)?
    /// Told the song seconds of the beat line whose "This Is Beat 1" was
    /// chosen. Nil leaves the command doing nothing.
    public var onBeatOne: (@MainActor (Double) -> Void)?
    /// The features whose commands the clip's menu holds. See
    /// `ClipMenu.Values.features`. Left alone, it holds every command.
    public var clipMenuFeatures: FeatureSet = .all
    /// Told when Mute Clip, Delete Other Takes or Delete is chosen in a clip's menu, with the id
    /// of the clip that was right-clicked. Nil leaves them doing nothing.
    public var onClipCommand: (@MainActor (ClipMenu.Command, UUID) -> Void)?
    /// Asked whether Split at Playhead and Join Clips can act right now, for
    /// the clip with this id, when its menu is made. Nil leaves it to what
    /// the content says. See `ClipMenu.init`.
    public var clipCommandIsEnabled: (@MainActor (ClipMenu.Command, UUID) -> Bool)?
    /// Told which kind was chosen under Effects in a clip's menu, with the
    /// id of the clip that was right-clicked. Nil leaves the kinds doing
    /// nothing.
    public var onClipEffect: (@MainActor (ClipEffect.Kind, UUID) -> Void)?
    /// The features whose commands the track's menu holds. See
    /// `TrackMenu.Values.features`. Left alone, it holds every command.
    public var trackMenuFeatures: FeatureSet = .all
    /// Told which kind was chosen under Effects in a track's menu, with the
    /// id of the track whose header was right-clicked. Nil leaves the kinds
    /// doing nothing.
    public var onTrackEffect: (@MainActor (ClipEffect.Kind, UUID) -> Void)?
    /// Told which line was chosen under Voice in a track's menu, with the
    /// id of the track whose header was right-clicked. Nil leaves the lines
    /// doing nothing.
    public var onTrackVoice: (@MainActor (VoiceMenu.Command, UUID) -> Void)?
    /// The names of Max's own presets of a Voice, which the submenu Voice of
    /// a track's menu lists under the built-in ones.
    public var ownVoicePresets: [String] = []
    /// False greys out the submenu Voice in the menu of every track, as
    /// while a take is going.
    public var canChangeVoice = true
    /// False greys out Copy Sound in the menus of every clip and track.
    public var canCopySound = true
    /// False greys out Paste Sound in the menus of every clip and track.
    public var canPasteSound = true

    public init(
        showsClipMenu: Bool = false,
        showsTrackMenu: Bool = false,
        song: SongMenu.Values? = nil,
        showsBeatMenu: Bool = false
    ) {
        self.showsClipMenu = showsClipMenu
        self.showsTrackMenu = showsTrackMenu
        self.song = song
        self.showsBeatMenu = showsBeatMenu
    }

    /// No menus at all.
    public static let none = TimelineMenus()

    /// The menus that belong to a set of features: the clip's menu comes
    /// with `recording` or `clipEditing` and holds the commands of the
    /// features given, the track's comes with `tracks`, the song's and the
    /// beat line's with `beats`. In the song's menu, "Create Click Track..."
    /// comes with `click`.
    public init(features: FeatureSet) {
        var song: SongMenu.Values?
        if features.contains(.beats) {
            var values = SongMenu.Values()
            values.showsCreateClickTrack = features.contains(.click)
            song = values
        }
        self.init(
            showsClipMenu: !features.isDisjoint(with: [.recording, .clipEditing]),
            showsTrackMenu: features.contains(.tracks),
            song: song,
            showsBeatMenu: features.contains(.beats)
        )
        clipMenuFeatures = features
        trackMenuFeatures = features
    }
}

extension ClipMenu.Values {
    /// What the menu of a clip shows, as far as the content says it: Mute
    /// Clip is ticked for a muted clip, the Sub-beats submenu ticks the clip's
    /// choice (`ClipBox.menuFeel`), or where the content does not say it
    /// Triplets for a clip in triplets and 16ths otherwise, Delete Other Takes needs more than one take, and Join Clips needs
    /// this clip and at least one more on its track to be selected. Split at
    /// Playhead is always offered until the playhead is known here. The Aim
    /// at submenu lists `aimTracks`, the other tracks, and ticks the one the
    /// clip aims at (`ClipBox.aimTrackID`).
    init(showing clip: ClipBox, on track: TrackRow, aimTracks: [AimTrack] = []) {
        self.init(
            isMuted: clip.muted,
            feel: clip.menuFeel ?? (clip.isTriplet ? .triplets : .sixteenths),
            canSplit: true,
            canJoin: clip.isSelected && track.clips.count(where: \.isSelected) > 1,
            hasOtherTakes: clip.takeCount > 1
        )
        self.aimTracks = aimTracks
        // An aim at a track the clip cannot aim at reads as the beat, as in the panel on the right.
        aimTrackID = aimTracks.first { $0.id == clip.aimTrackID }?.id
    }
}

extension TrackMenu.Values {
    /// What the menu of a track shows: Mute Track is ticked for a muted
    /// track, Merge Into lists the other tracks, the last track left
    /// cannot be deleted, and the submenu Voice ticks the track's preset
    /// (`TrackRow.voice`).
    init(showing track: TrackRow, among tracks: [TrackRow]) {
        let others = tracks.filter { $0.id != track.id }
        self.init(
            isMuted: track.muted,
            otherTrackNames: others.map(\.name),
            canDelete: tracks.count > 1
        )
        otherTrackIDs = others.map(\.id)
        voice = track.voice
    }
}

extension View {
    /// The clip's menu on a right-click, or no menu for nil.
    @ViewBuilder
    func clipMenu(
        ifShown values: ClipMenu.Values?,
        onCommand: (@MainActor (ClipMenu.Command) -> Void)? = nil,
        isEnabled: (@MainActor (ClipMenu.Command) -> Bool)? = nil,
        onEffect: (@MainActor (ClipEffect.Kind) -> Void)? = nil
    ) -> some View {
        if let values {
            clipMenu(values, onCommand: onCommand, isEnabled: isEnabled, onEffect: onEffect)
        } else {
            self
        }
    }

    /// The track's menu on a right-click, or no menu for nil.
    @ViewBuilder
    func trackMenu(
        ifShown values: TrackMenu.Values?,
        onCommand: (@MainActor (TrackMenu.Command) -> Void)? = nil,
        onEffect: (@MainActor (ClipEffect.Kind) -> Void)? = nil,
        onVoice: (@MainActor (VoiceMenu.Command) -> Void)? = nil
    ) -> some View {
        if let values {
            trackMenu(values, onCommand: onCommand, onEffect: onEffect, onVoice: onVoice)
        } else {
            self
        }
    }

    /// The song's menu on a right-click, or no menu for nil.
    @ViewBuilder
    func songMenu(
        ifShown values: SongMenu.Values?,
        onCommand: (@MainActor (SongMenu.Command) -> Void)? = nil
    ) -> some View {
        if let values {
            songMenu(values, onCommand: onCommand)
        } else {
            self
        }
    }
}

/// The strips around the beat lines of one row that open the beat line's
/// menu on a right-click. Lay it over the row's content, at its left edge.
///
/// A strip is a few points wide. When the song is zoomed far out the beat
/// lines stand so close that the strips would cover most of the row, and a
/// right-click meant for the row would nearly always hit a beat line. So the
/// strips are there only while they cover a third of the row at most. Zoomed
/// in far enough to tell the beat lines apart, every one of them has its menu.
struct BeatLineMenuTargets: View {
    /// The beats, in song seconds, in time order.
    let times: [Double]
    let viewport: TimelineViewport
    /// Told the song seconds of the beat line whose "This Is Beat 1" was chosen.
    var onBeatOne: (@MainActor (Double) -> Void)?

    /// The strips may cover one part in this many of the row.
    private static let leastRoomPerStrip: CGFloat = 3

    var body: some View {
        let shown = shownTimes
        ForEach(shown, id: \.self) { time in
            BeatLineMenuTarget()
                .beatMenu(onThisIsBeatOne: beatOneAction(for: time))
                .offset(x: viewport.lineX(for: time) - DesignTokens.Sizes.beatLineMenuTargetWidth / 2)
        }
    }

    /// What "This Is Beat 1" does in the menu of the beat line at `time`.
    private func beatOneAction(for time: Double) -> (@MainActor () -> Void)? {
        guard let onBeatOne else { return nil }
        return { onBeatOne(time) }
    }

    /// The beats on screen, or none when they stand too close.
    private var shownTimes: [Double] {
        let visible = viewport.visibleRange
        let onScreen = times.filter { visible.contains($0) }
        let width = viewport.x(for: visible.upperBound) - viewport.x(for: visible.lowerBound)
        let needed = CGFloat(onScreen.count) * DesignTokens.Sizes.beatLineMenuTargetWidth * Self.leastRoomPerStrip
        return needed <= width ? onScreen : []
    }
}

import LockstepCore
import SwiftUI

/// The row of one vocal track: its header (`TrackHeader`) and its clips, each
/// a `ClipView`.
///
///     Timeline(lanes: [AnyTimelineLane(SongLane(...))] + TrackLane.lanes(for: content.trackRows), ...)
///
/// `TrackLane.lanes(for:)` also puts the "New Track" row under the last track.
///
/// A track that is being recorded to (`TrackRow.recording`) also shows that
/// recording, in red, in front of its clips (`RecordingClip`).
///
/// Clips that overlap: a clip that starts later is drawn in front of one that
/// starts earlier, and the earlier one is told where it is covered, so it
/// keeps its name and marks clear of the overlap (see `ClipView`). Clips of
/// two lines seldom overlap: a clip that is recorded, moved or dragged out over
/// another makes it give way. The takes of one line lie on top of each other,
/// and only one of them is in the track's clips.
///
/// The take count: in a window whose owner listens for the takes
/// (`MainLayoutActions.takes`), a press on a clip's take count is reported, and
/// the owner selects the clip, so its takes show in the panel on the right.
/// Anywhere else the count does nothing.
///
/// The height: `DesignTokens.Sizes.trackLaneHeight` unless `rowHeight` says
/// otherwise. The header and the clips fill whatever height the row has.
public struct TrackLane: TimelineLane {
    private let track: TrackRow
    private let rowHeight: CGFloat
    private let shownPointers: [UUID: ClipPart]
    private let headerMenu: TrackMenu.Values?
    private let showsClipMenu: Bool
    private let clipMenuFeatures: FeatureSet
    private let onClipCommand: (@MainActor (ClipMenu.Command, UUID) -> Void)?
    private let clipCommandIsEnabled: (@MainActor (ClipMenu.Command, UUID) -> Bool)?
    private let onClipEffect: (@MainActor (ClipEffect.Kind, UUID) -> Void)?
    private let onTrackEffect: (@MainActor (ClipEffect.Kind, UUID) -> Void)?
    private let onTrackVoice: (@MainActor (VoiceMenu.Command, UUID) -> Void)?
    private let canCopySound: Bool
    private let canPasteSound: Bool
    private let aimTracks: [AimTrack]
    private let actions: TrackActions?
    private let clipActions: ClipActions?

    /// - Parameters:
    ///   - track: The track to show.
    ///   - rowHeight: The height of the row, between
    ///     `DesignTokens.Sizes.trackLaneMinimumHeight` and
    ///     `trackLaneMaximumHeight`. Left out, it is `trackLaneHeight`.
    ///   - shownPointers: Draws a clip as if the pointer were over a part of
    ///     it, by the clip's id. See `ClipView`'s `shownPointer`. The design
    ///     lab uses it for pictures.
    ///   - headerMenu: What the right-click menu of the track's header shows.
    ///     Nil leaves the header without a menu.
    ///   - showsClipMenu: Gives every clip its right-click menu.
    ///   - clipMenuFeatures: The features whose commands the clip's menu
    ///     holds. Left out, it holds every command.
    ///   - onClipCommand: Told when Mute Clip, Delete Other Takes or Delete is chosen in a clip's
    ///     menu, with the id of that clip. Left out, they do nothing.
    ///   - clipCommandIsEnabled: Asked whether Split at Playhead and Join
    ///     Clips can act for a clip, when its menu is made. Left out, the
    ///     track's content decides.
    ///   - onClipEffect: Told which kind was chosen under Effects in a
    ///     clip's menu, with the id of that clip. Left out, it does nothing.
    ///   - onTrackEffect: Told which kind was chosen under Effects in the
    ///     menu of the track's header, with the id of the track. Left out,
    ///     it does nothing.
    ///   - canCopySound: False greys out Copy Sound in the menus of the
    ///     track's clips. The header's menu has its own value (`headerMenu`).
    ///   - canPasteSound: The same for Paste Sound.
    ///   - aimTracks: The other tracks, from top to bottom: the lines of the
    ///     Aim at submenu in a clip's menu. Left out, it lists only "The beat".
    ///   - actions: Who is told when something in the track's header is
    ///     used. Left out, the header is a picture.
    ///   - clipActions: Who is told when the typing of a clip's name ends.
    ///     Left out, the name field of a clip is a picture.
    public init(
        _ track: TrackRow,
        rowHeight: CGFloat = DesignTokens.Sizes.trackLaneHeight,
        shownPointers: [UUID: ClipPart] = [:],
        headerMenu: TrackMenu.Values? = nil,
        showsClipMenu: Bool = false,
        clipMenuFeatures: FeatureSet = .all,
        onClipCommand: (@MainActor (ClipMenu.Command, UUID) -> Void)? = nil,
        clipCommandIsEnabled: (@MainActor (ClipMenu.Command, UUID) -> Bool)? = nil,
        onClipEffect: (@MainActor (ClipEffect.Kind, UUID) -> Void)? = nil,
        onTrackEffect: (@MainActor (ClipEffect.Kind, UUID) -> Void)? = nil,
        onTrackVoice: (@MainActor (VoiceMenu.Command, UUID) -> Void)? = nil,
        canCopySound: Bool = true,
        canPasteSound: Bool = true,
        aimTracks: [AimTrack] = [],
        actions: TrackActions? = nil,
        clipActions: ClipActions? = nil
    ) {
        self.track = track
        self.rowHeight = rowHeight
        self.shownPointers = shownPointers
        self.headerMenu = headerMenu
        self.showsClipMenu = showsClipMenu
        self.clipMenuFeatures = clipMenuFeatures
        self.onClipCommand = onClipCommand
        self.clipCommandIsEnabled = clipCommandIsEnabled
        self.onClipEffect = onClipEffect
        self.onTrackEffect = onTrackEffect
        self.onTrackVoice = onTrackVoice
        self.canCopySound = canCopySound
        self.canPasteSound = canPasteSound
        self.aimTracks = aimTracks
        self.actions = actions
        self.clipActions = clipActions
    }

    public var id: UUID { track.id }

    public var height: CGFloat { rowHeight }

    /// A track's row shows the same while its track, its height, its menus
    /// and the pointers it is drawn with are the same, and the same things
    /// are listened for. The closures themselves are taken to do the same:
    /// they tell an owner about a track or a clip by its id.
    public func showsSame(as other: TrackLane) -> Bool {
        track == other.track
            && rowHeight == other.rowHeight
            && shownPointers == other.shownPointers
            && headerMenu == other.headerMenu
            && showsClipMenu == other.showsClipMenu
            && clipMenuFeatures == other.clipMenuFeatures
            && canCopySound == other.canCopySound
            && canPasteSound == other.canPasteSound
            && (onClipCommand == nil) == (other.onClipCommand == nil)
            && (clipCommandIsEnabled == nil) == (other.clipCommandIsEnabled == nil)
            && TrackActions.listensForTheSame(actions, other.actions)
            && (clipActions?.renameEnded == nil) == (other.clipActions?.renameEnded == nil)
    }

    public func header() -> some View {
        TrackHeader(
            track: track,
            menu: headerMenu,
            actions: actions,
            onMenuEffect: headerEffectReport,
            onMenuVoice: headerVoiceReport
        )
    }

    /// What a line chosen under Voice in the menu of the track's header reports to.
    private var headerVoiceReport: (@MainActor (VoiceMenu.Command) -> Void)? {
        guard let onTrackVoice else { return nil }
        let id = track.id
        return { command in onTrackVoice(command, id) }
    }

    /// What a kind chosen under Effects in the menu of the track's header reports to.
    private var headerEffectReport: (@MainActor (ClipEffect.Kind) -> Void)? {
        guard let onTrackEffect else { return nil }
        let id = track.id
        return { kind in onTrackEffect(kind, id) }
    }

    public func content(in viewport: TimelineViewport) -> some View {
        TrackLaneBody(
            track: track,
            viewport: viewport,
            shownPointers: shownPointers,
            showsClipMenu: showsClipMenu,
            clipMenuFeatures: clipMenuFeatures,
            onClipCommand: onClipCommand,
            clipCommandIsEnabled: clipCommandIsEnabled,
            onClipEffect: onClipEffect,
            canCopySound: canCopySound,
            canPasteSound: canPasteSound,
            aimTracks: aimTracks,
            onRenameEnd: clipActions?.renameEnded
        )
    }

    /// The rows for a list of tracks, from top to bottom, with the row that
    /// holds the "New Track" button under the last one. `rowHeight` is the
    /// height of every track's row. `showsNewTrackRow`
    /// leaves that last row out, for the real app before tracks can be added.
    /// `menus` says whether the headers and the clips get their right-click
    /// menus. `actions` says who is told when a header or the "New Track"
    /// button is used, and `clipActions` who is told when the typing of a
    /// clip's name ends. Left out, they are pictures.
    public static func lanes(
        for tracks: [TrackRow],
        rowHeight: CGFloat = DesignTokens.Sizes.trackLaneHeight,
        showsNewTrackRow: Bool = true,
        menus: TimelineMenus = .none,
        actions: TrackActions? = nil,
        clipActions: ClipActions? = nil
    ) -> [AnyTimelineLane] {
        tracks.map { track in
            AnyTimelineLane(TrackLane(
                track,
                rowHeight: rowHeight,
                headerMenu: menus.showsTrackMenu ? headerMenu(of: track, among: tracks, menus: menus) : nil,
                showsClipMenu: menus.showsClipMenu,
                clipMenuFeatures: menus.clipMenuFeatures,
                onClipCommand: menus.onClipCommand,
                clipCommandIsEnabled: menus.clipCommandIsEnabled,
                onClipEffect: menus.onClipEffect,
                onTrackEffect: menus.onTrackEffect,
                onTrackVoice: menus.onTrackVoice,
                canCopySound: menus.canCopySound,
                canPasteSound: menus.canPasteSound,
                // A clip cannot aim at its own track.
                aimTracks: menus.showsClipMenu && menus.clipMenuFeatures.contains(.lockToLead)
                    ? tracks.filter { $0.id != track.id }.map { AimTrack(id: $0.id, name: $0.name) }
                    : [],
                actions: actions,
                clipActions: clipActions
            ))
        }
            + (showsNewTrackRow ? [AnyTimelineLane(NewTrackLane(onPress: actions?.newTrackPressed))] : [])
    }
}

extension TrackLane {
    /// What the menu of a track's header shows, with the commands of the
    /// features the menus were given.
    private static func headerMenu(
        of track: TrackRow,
        among tracks: [TrackRow],
        menus: TimelineMenus
    ) -> TrackMenu.Values {
        var values = TrackMenu.Values(showing: track, among: tracks)
        values.features = menus.trackMenuFeatures
        values.ownVoicePresets = menus.ownVoicePresets
        values.canChangeVoice = menus.canChangeVoice
        values.canCopySound = menus.canCopySound
        values.canPasteSound = menus.canPasteSound
        return values
    }
}

/// The clips of one track, each at its place in the song.
private struct TrackLaneBody: View {
    @Environment(\.takeCountListener) private var takeCountListener

    let track: TrackRow
    let viewport: TimelineViewport
    let shownPointers: [UUID: ClipPart]
    let showsClipMenu: Bool
    let clipMenuFeatures: FeatureSet
    let onClipCommand: (@MainActor (ClipMenu.Command, UUID) -> Void)?
    let clipCommandIsEnabled: (@MainActor (ClipMenu.Command, UUID) -> Bool)?
    let onClipEffect: (@MainActor (ClipEffect.Kind, UUID) -> Void)?
    let canCopySound: Bool
    let canPasteSound: Bool
    let aimTracks: [AimTrack]
    let onRenameEnd: (@MainActor (UUID, String?) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(clipsOnScreen) { placed in
                ClipView(
                    clip: placed.clip,
                    viewport: viewport,
                    isOnMutedTrack: track.muted,
                    coveredFrom: placed.coveredFrom,
                    shownPointer: shownPointers[placed.clip.id],
                    onTakeCount: takeCountReport(for: placed.clip),
                    onRenameEnd: renameEndReport(for: placed.clip)
                )
                .clipMenu(
                    ifShown: showsClipMenu ? menuValues(for: placed.clip) : nil,
                    onCommand: commandReport(for: placed.clip),
                    isEnabled: enabledQuestion(for: placed.clip),
                    onEffect: effectReport(for: placed.clip)
                )
                // The name field of a clip that is being renamed may reach
                // over its neighbours, so that clip is drawn in front.
                .zIndex(placed.clip.isBeingRenamed ? 1 : 0)
            }
            // The recording that is going to this track right now, in front
            // of the clips it is recorded over.
            if let recording = track.recording {
                RecordingClip(recording: recording, viewport: viewport)
                    .zIndex(2)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.clipInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What a press on the take count of a clip reports to.
    private func takeCountReport(for clip: ClipBox) -> (@MainActor () -> Void)? {
        guard let takeCountListener else { return nil }
        let id = clip.id
        return { takeCountListener.pressed?(id) }
    }

    /// What the name field of a clip tells when the typing is over, or nil
    /// for a field that is a picture.
    private func renameEndReport(for clip: ClipBox) -> (@MainActor (String?) -> Void)? {
        guard let onRenameEnd else { return nil }
        let id = clip.id
        return { name in onRenameEnd(id, name) }
    }

    /// What the menu of a clip ticks and greys out, with the commands of
    /// the features it was given.
    private func menuValues(for clip: ClipBox) -> ClipMenu.Values {
        var values = ClipMenu.Values(showing: clip, on: track, aimTracks: aimTracks)
        values.features = clipMenuFeatures
        values.canCopySound = canCopySound
        values.canPasteSound = canPasteSound
        return values
    }

    /// Who the menu of a clip asks whether Split at Playhead and Join Clips
    /// can act, or nil when the track's content decides.
    private func enabledQuestion(for clip: ClipBox) -> (@MainActor (ClipMenu.Command) -> Bool)? {
        guard let clipCommandIsEnabled else { return nil }
        let id = clip.id
        return { command in clipCommandIsEnabled(command, id) }
    }

    /// What a command chosen in the menu of a clip reports to.
    private func commandReport(for clip: ClipBox) -> (@MainActor (ClipMenu.Command) -> Void)? {
        guard let onClipCommand else { return nil }
        let id = clip.id
        return { command in onClipCommand(command, id) }
    }

    /// What a kind chosen under Effects in the menu of a clip reports to.
    private func effectReport(for clip: ClipBox) -> (@MainActor (ClipEffect.Kind) -> Void)? {
        guard let onClipEffect else { return nil }
        let id = clip.id
        return { kind in onClipEffect(kind, id) }
    }

    /// A clip and where the next clip on the track begins to lie over it.
    private struct PlacedClip: Identifiable {
        let clip: ClipBox
        /// Song seconds, or nil when no later clip lies over this one.
        let coveredFrom: Double?

        var id: UUID { clip.id }
    }

    /// The clips that get a view, in the order they start, so a clip that
    /// starts later lies in front of one that starts earlier.
    ///
    /// Only the clips that touch the part of the song that is on screen get a
    /// view. A project can hold a few hundred clips, and zoomed in most of
    /// them are far away.
    private var clipsOnScreen: [PlacedClip] {
        let inOrder = track.clips
            .compactMap { clip in clip.timeRange.map { (clip: clip, range: $0) } }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        var placed: [PlacedClip] = []
        for (index, entry) in inOrder.enumerated() where entry.range.overlaps(viewport.visibleRange) {
            let nextStart = index + 1 < inOrder.count ? inOrder[index + 1].range.lowerBound : nil
            let isCovered = nextStart.map { $0 < entry.range.upperBound } ?? false
            placed.append(PlacedClip(clip: entry.clip, coveredFrom: isCovered ? nextStart : nil))
        }
        return placed
    }
}

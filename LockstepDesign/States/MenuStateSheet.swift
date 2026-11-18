import LockstepCore
import LockstepUI
import SwiftUI

/// What every right-click menu state shows: a short stretch of the timeline
/// (the song row and the track "Double" around its selected clip), and beside
/// it one menu's contents as a plain list, with a line above that says how to
/// open the real menu.
///
/// The menus are the system's own. An open menu is a separate window that
/// appears only on a real right-click, so no state can show it open at
/// launch. All four real menus are attached to the stretch of timeline: a
/// right-click on the clip, the track header, a beat line or the song row
/// opens the one that belongs there.
struct MenuStateSheet: View {
    /// The line above, saying what to right-click.
    let hint: String
    /// The menu whose contents are listed.
    let entries: [MenuEntry]

    private let content: TimelineContent
    /// The track shown under the song row.
    private let track: TrackRow
    @State private var scale = TimelineScale(pointsPerSecond: 0)
    @State private var playhead: PlayheadPosition

    init(hint: String, entries: [MenuEntry]) {
        self.hint = hint
        self.entries = entries
        let content = SampleContent.make()
        self.content = content
        track = content.trackRows.first(where: \.isSelected) ?? content.trackRows[0]
        _playhead = State(initialValue: PlayheadPosition(seconds: content.playheadTime))
    }

    /// The stretch of the song shown: the selected clip with some room on
    /// both sides, and the playhead.
    static let range: ClosedRange<Double> = 14...22

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            Text(hint)
                .font(DesignTokens.Fonts.label)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xxLarge) {
                timeline
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    MenuListing(column)
                }
            }
        }
        .padding(DesignTokens.Spacing.xxLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// How many lines of a menu the window shows under the hint at the size the pictures are made at,
    /// with a divider counted as a line.
    private static let linesThatFit = 32

    /// The menu's lines as they are listed: in one list, or, for a menu with more lines than the window
    /// shows, in two lists side by side that read as one, the second going on where the first stops.
    ///
    /// The clip's menu outgrew the window when it got "Aim at" on top of "Effects", and its picture lost
    /// its first and last commands. The lists are divided between two of the menu's own lines, never inside
    /// a submenu, where that leaves the longer list shortest.
    private var columns: [[MenuEntry]] {
        let lines = entries.map(Self.lines)
        let total = lines.reduce(0, +)
        guard total > Self.linesThatFit, entries.count > 1 else { return [entries] }
        var cut = 1
        var longest = Int.max
        var above = 0
        for index in 1..<entries.count {
            above += lines[index - 1]
            if max(above, total - above) < longest {
                longest = max(above, total - above)
                cut = index
            }
        }
        var first = Array(entries[..<cut])
        var second = Array(entries[cut...])
        // A divider at the cut would be a line at the edge of a list, dividing nothing.
        if case .divider = first.last { first.removeLast() }
        if case .divider = second.first { second.removeFirst() }
        return [first, second]
    }

    /// How many lines an entry takes in the list, the lines of its submenu included.
    private static func lines(_ entry: MenuEntry) -> Int {
        switch entry {
        case .command, .divider: 1
        case .submenu(_, let entries): 1 + entries.map(lines).reduce(0, +)
        }
    }

    private var timeline: some View {
        Timeline(
            lanes: [
                AnyTimelineLane(MenuSongLane(
                    song: SongLane(content: content),
                    beatTimes: content.beatLines.map(\.time)
                )),
                AnyTimelineLane(MenuTrackLane(
                    track: track,
                    otherTrackNames: content.trackRows.filter { $0.id != track.id }.map(\.name),
                    trackCount: content.trackRows.count
                )),
            ],
            scale: $scale,
            range: Self.range,
            beats: content.beats,
            playhead: playhead
        ) { viewport, beats in
            TimelineRuler(viewport: viewport, beats: beats)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension MenuStateSheet {
    /// The menu values of the selected clip, as the clip state lists them:
    /// one clip selected, so Join Clips is greyed out; five takes, so Delete
    /// Other Takes is not.
    nonisolated static func clipValues(_ clip: ClipBox) -> ClipMenu.Values {
        ClipMenu.Values(
            isMuted: clip.muted,
            feel: clip.isTriplet ? .triplets : .sixteenths,
            canSplit: true,
            canJoin: false,
            hasOtherTakes: clip.takeCount > 1
        )
    }
}

/// The song row with the song's menu on it, and the beat line menu on each
/// beat line.
private struct MenuSongLane: TimelineLane {
    let song: SongLane
    let beatTimes: [Double]

    var id: String { song.id }
    var height: CGFloat { song.height }
    var isPinned: Bool { true }

    func header() -> some View {
        song.header()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .songMenu(SongMenu.Values())
    }

    func content(in viewport: TimelineViewport) -> some View {
        song.content(in: viewport)
            .contentShape(Rectangle())
            .songMenu(SongMenu.Values())
            .overlay(alignment: .topLeading) {
                ForEach(beatTimes.filter { viewport.visibleRange.contains($0) }, id: \.self) { time in
                    BeatLineMenuTarget()
                        .beatMenu()
                        .offset(x: viewport.lineX(for: time) - DesignTokens.Sizes.beatLineMenuTargetWidth / 2)
                }
            }
    }
}

/// One track row with the track's menu on its header and the clip menu on
/// each of its clips.
private struct MenuTrackLane: TimelineLane {
    let track: TrackRow
    let otherTrackNames: [String]
    let trackCount: Int

    var id: UUID { track.id }
    var height: CGFloat { DesignTokens.Sizes.trackLaneHeight }

    func header() -> some View {
        TrackHeader(track: track)
            .contentShape(Rectangle())
            .trackMenu(TrackMenu.Values(
                isMuted: track.muted,
                otherTrackNames: otherTrackNames,
                canDelete: trackCount > 1
            ))
    }

    func content(in viewport: TimelineViewport) -> some View {
        GlassGroup {
            ZStack(alignment: .topLeading) {
                ForEach(track.clips.filter { $0.timeRange?.overlaps(viewport.visibleRange) ?? false }) { clip in
                    ClipView(clip: clip, viewport: viewport, isOnMutedTrack: track.muted)
                        .clipMenu(MenuStateSheet.clipValues(clip))
                }
            }
            .padding(.vertical, DesignTokens.Spacing.clipInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

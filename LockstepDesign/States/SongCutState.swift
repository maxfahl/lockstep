import LockstepCore
import LockstepUI
import SwiftUI

// The song with its beginning or its end cut away, and moved so that the
// timeline's 00:00 lies inside it. In the real app the edges and the song are
// dragged. Here the content says what is left.

extension LabState {
    /// How much of the beginning the states cut away: up to a bar start a
    /// little into the song, as a cut on the beat is.
    private static func cutPoint(in content: MainLayoutContent) -> Int {
        Int((content.barStart(atOrAfter: 8) * Lockstep.sampleRate).rounded())
    }

    /// The beginning of the song is cut away and the song has not been
    /// moved. The song starts in an edge, a little into the row. Before the
    /// edge the row is empty: no waveform and no beat lines, there and in
    /// the track rows. The ruler has no ticks there either.
    static let songCutAtStart = LabState("Song cut at the start") {
        var content = MainLayoutContent.sampleWithoutSelectedClip()
        content.timeline.songPlace = SongPlace(cutStartSamples: cutPoint(in: content))
        return SmallStateWindow(content: content, zoom: SmallStateWindow.Zoom(pointsPerSecond: 40, startSeconds: 0))
    }

    /// The end of the song is cut away. The song ends in an edge, and the
    /// rest of the row, up to where the song file ends, is empty.
    static let songCutAtEnd = LabState("Song cut at the end") {
        var content = MainLayoutContent.sampleWithoutSelectedClip()
        let length = content.timeline.songLength
        content.timeline.songPlace = SongPlace(
            cutEndSamples: Int(((length - content.barStart(atOrAfter: length - 12)) * Lockstep.sampleRate).rounded())
        )
        content.timeline.playheadTime = max(length - 20, 0)
        return SmallStateWindow(
            content: content,
            zoom: SmallStateWindow.Zoom(pointsPerSecond: 40, startSeconds: max(length - 24, 0))
        )
    }

    /// The beginning is cut away and the song is moved so that what is left
    /// starts at 00:00: the timeline starts inside the song, at the cut. The
    /// bar numbers are still the song's own, so the first one in the ruler is
    /// not 1. The playhead stands twelve seconds after 00:00 and the time
    /// says so.
    static let songAtZero = LabState("Song at 00:00") {
        var content = MainLayoutContent.sampleWithoutSelectedClip()
        let cut = cutPoint(in: content)
        content.timeline.songPlace = SongPlace(cutStartSamples: cut, zeroSample: cut)
        content.timeline.playheadTime = content.timeline.songPlace.songSeconds(forTimeline: 12)
        content.timeline.timeText = "0:12"
        return SmallStateWindow(
            content: content,
            zoom: SmallStateWindow.Zoom(pointsPerSecond: 40, startSeconds: content.timeline.songPlace.zeroSeconds)
        )
    }

    /// The pointer is over the left edge of a song whose beginning is cut
    /// away: the edge is bright. The arrows beside it stand in for the
    /// pointer, which a picture of the window does not show. Move the real
    /// pointer over either end of the song to see the real thing, also on a
    /// song that is not cut.
    static let songEdgeHover = LabState("Song edge hover") {
        var content = MainLayoutContent.sampleWithoutSelectedClip()
        content.timeline.songPlace = SongPlace(cutStartSamples: cutPoint(in: content))
        content.timeline.shownHoveredSongEdge = .start
        return SmallStateWindow(content: content, zoom: SmallStateWindow.Zoom(pointsPerSecond: 40, startSeconds: 0))
    }
}

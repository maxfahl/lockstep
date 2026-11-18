import LockstepCore
import LockstepUI
import SwiftUI

/// The whole window for the recording states and the small states. It is
/// `MainLayout` like `LabMainLayout`, and adds two things those states need:
/// a zoom to start at, so a short stretch of the song fills the window, and a
/// choice of features, for the window before a song is dropped.
///
///     SmallStateWindow(content: content, zoom: .around(20, pointsPerSecond: 40))
struct SmallStateWindow: View {
    /// Where the timeline starts.
    struct Zoom {
        var pointsPerSecond: Double
        var startSeconds: Double

        /// The whole song fitted to the width.
        static let wholeSong = Zoom(pointsPerSecond: 0, startSeconds: 0)

        /// Zoomed in, with `seconds` a little to the right of the left edge.
        static func around(_ seconds: Double, pointsPerSecond: Double) -> Zoom {
            Zoom(pointsPerSecond: pointsPerSecond, startSeconds: max(seconds - 320 / pointsPerSecond, 0))
        }
    }

    private let content: MainLayoutContent
    private let features: FeatureSet
    private let showsInspector: Bool?

    @State private var scale: TimelineScale
    @State private var playhead: PlayheadPosition

    init(
        content: MainLayoutContent,
        features: FeatureSet = .all,
        zoom: Zoom = .wholeSong,
        showsInspector: Bool? = nil
    ) {
        self.content = content
        self.features = features
        self.showsInspector = showsInspector
        _scale = State(initialValue: TimelineScale(
            pointsPerSecond: zoom.pointsPerSecond,
            scrollOffsetSeconds: zoom.startSeconds
        ))
        let position = PlayheadPosition(seconds: content.timeline.playheadTime)
        // A time readout that follows the playhead counts from the timeline's 00:00.
        position.place = content.timeline.songPlace
        _playhead = State(initialValue: position)
    }

    var body: some View {
        MainLayout(
            content: content,
            features: features,
            scale: $scale,
            playhead: playhead,
            showsInspector: showsInspector
        )
    }
}

extension MainLayoutContent {
    /// The made-up window content with no clip selected, so the picture
    /// shows only what the state is about.
    static func sampleWithoutSelectedClip() -> MainLayoutContent {
        var content = SampleContent.makeMainLayout()
        for trackIndex in content.timeline.trackRows.indices {
            for clipIndex in content.timeline.trackRows[trackIndex].clips.indices {
                content.timeline.trackRows[trackIndex].clips[clipIndex].isSelected = false
            }
        }
        content.timeline.takeRows = []
        content.selectedClipText = ""
        content.selectedClipResolveStart = ""
        return content
    }

    /// The start of the first bar at or after `seconds`, or `seconds` itself
    /// when the song has no such bar.
    func barStart(atOrAfter seconds: Double) -> Double {
        timeline.beatLines.first { $0.isBarStart && $0.time >= seconds }?.time ?? seconds
    }

    /// Made-up loudness for a recording: borrowed from the first clip.
    var borrowedLevels: WaveformLevels {
        timeline.trackRows.first?.clips.first?.segments.first?.levels
            ?? WaveformLevels(minimums: [], maximums: [])
    }

    /// Starts a recording on the track at `trackIndex`, at the first bar at
    /// or after `seconds`. With `recordedSeconds` nil the song is still in
    /// the run-up, a little before that bar. Otherwise that much has been
    /// recorded, and the playhead stands at the end of it.
    mutating func startRecording(onTrack trackIndex: Int, at seconds: Double, recordedSeconds: Double?) {
        let origin = barStart(atOrAfter: seconds)
        let playheadTime = recordedSeconds.map { origin + $0 } ?? max(origin - 1.2, 0)
        timeline.trackRows[trackIndex].recording = TrackRecording(
            origin: origin,
            recordedUntil: recordedSeconds.map { origin + $0 },
            levels: recordedSeconds == nil ? WaveformLevels(minimums: [], maximums: []) : borrowedLevels
        )
        timeline.playheadTime = playheadTime
        timeline.timeText = "0:\(Int(playheadTime) < 10 ? "0" : "")\(Int(playheadTime))"
        isPlaying = true
        isRunningUp = recordedSeconds == nil
        isRecording = recordedSeconds != nil
    }
}

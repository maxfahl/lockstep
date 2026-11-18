import LockstepUI
import SwiftUI

extension LabState {
    /// The window before a song is dropped: the words "Drop a song here" in
    /// the middle and nothing else. It is shown with the one feature a
    /// first window has, the song. No other feature would add anything:
    /// without a song the window shows only the words.
    static let empty = LabState("Empty") {
        SmallStateWindow(content: .empty, features: [.song])
    }

    /// A song was just dropped and its beats are being found: the song row
    /// has its waveform and no beat lines, and under the song's name a ring,
    /// a little under half full, with "Finding beats" after it. The bar at
    /// the bottom has no tempo yet.
    static let findingBeats = LabState("Finding beats") {
        var content = MainLayoutContent.sampleWithoutSelectedClip()
        content.timeline.beatLines = []
        content.timeline.uncertainRanges = []
        content.timeline.unfilledGaps = []
        content.timeline.trackRows = []
        content.timeline.tempoText = ""
        content.timeline.playheadTime = 0
        content.timeline.timeText = "0:00"
        content.timeline.beatFinding = BeatFindingProgress(phaseName: "Finding beats", fraction: 0.4)
        return SmallStateWindow(content: content, showsInspector: false)
    }

    /// The delay was never measured: in the panel on the right the delay
    /// reads "Not calibrated" with a warning triangle before it.
    static let notCalibrated = LabState("Not calibrated") {
        var content = SampleContent.makeMainLayout()
        content.delayMilliseconds = nil
        return SmallStateWindow(content: content, showsInspector: true)
    }
}

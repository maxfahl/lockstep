import Foundation

/// Listening to one take of a line with the song: which stretch of the song is played.
///
/// A take is heard in its place, with the song, the click and every other clip, the way it would sound if it
/// were the chosen one. The stretch starts where the line starts, with no bar before it: Max hears the takes
/// one after another and wants each at once. It ends half a second after the line.
///
///     let line = project.takes(of: clip.id)
///     if let stretch = TakeAudition.stretch(ofLine: line, in: project) {
///         engine.play(from: stretch.lowerBound)   // and stop at stretch.upperBound
///     }
///
/// Nothing here changes the project: which take is heard is for the caller to arrange.
public enum TakeAudition {
    /// How long the song plays on after the end of the line, in seconds.
    public static let secondsAfter = 0.5

    /// The stretch of the song that is played to hear a take of this line, in song seconds: from the earliest
    /// start of the line's takes to half a second after their latest end, and never outside the song. It is the same for every take of the line, so
    /// going from one take to another starts at the same place.
    ///
    /// Nil when none of the takes has a place in the song, or the stretch would be empty.
    public static func stretch(ofLine takes: [Clip], in project: Project) -> ClosedRange<Double>? {
        var line: ClosedRange<Double>?
        for take in takes {
            guard let start = project.start(of: take), let end = project.end(of: take), end > start else { continue }
            line = min(line?.lowerBound ?? start, start)...max(line?.upperBound ?? end, end)
        }
        guard let line else { return nil }
        let songLength = Double(project.songLengthSamples) / Lockstep.sampleRate
        let start = max(line.lowerBound, 0)
        let end = min(line.upperBound + secondsAfter, songLength)
        return end > start ? start...end : nil
    }
}

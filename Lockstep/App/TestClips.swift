#if DEBUG
import Foundation
import LockstepCore

/// A heavy project for trying how the window keeps up: twelve tracks and two hundred clips.
/// Only in debug builds, where Debug > Add Test Clips makes it. The Lockstep that Max uses
/// from day to day, a release build, does not contain it.
///
/// All the clips play the same short made-up recording, each from another place in the
/// song, so one small file is enough.
enum TestClips {
    static let trackCount = 12
    static let clipCount = 200

    /// How long the made-up recording is, in samples: a second and a half.
    static let recordingLength = 72_000

    /// The made-up recording: three short quiet hums with silence between them, so a clip
    /// shows a waveform with a shape, and is not loud if the song is played.
    static func sound() -> [Float] {
        (0..<recordingLength).map { sample in
            let burst = Double(sample % 24_000) / 24_000
            guard burst < 0.6 else { return 0 }
            let swell = sin(.pi * burst / 0.6)
            return Float(0.1 * swell * sin(2 * .pi * 220 * Double(sample) / Lockstep.sampleRate))
        }
    }

    /// Adds the recording to a project, tracks until there are twelve, and two hundred clips
    /// of the recording, spread over the tracks and over the whole song.
    ///
    /// The clips on one track lie one after the other and never overlap, so none of them
    /// becomes a take of another. In a short song they are cut shorter to fit. Each track
    /// starts a little later than the one above it, so the clips do not stand in columns.
    static func add(to project: inout Project, playing recording: Recording) {
        project.recordings.append(recording)
        while project.tracks.count < trackCount {
            project.addTrack()
        }
        let perTrack = (clipCount + trackCount - 1) / trackCount
        // The room each clip has on its track, and how much of it the clip fills.
        let room = max(project.songLengthSamples / perTrack, 1)
        let length = min(recording.lengthSamples, max(room * 4 / 5, 1))
        for clip in 0..<clipCount {
            let track = clip % trackCount
            let stagger = (room - length) * track / trackCount
            let place = (clip / trackCount) * room + stagger
            project.tracks[track].clips.append(Clip(segments: [
                Segment(recordingID: recording.id, inSample: 0, outSample: length, offsetSamples: place),
            ]))
        }
    }
}
#endif

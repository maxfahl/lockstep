import Foundation
import LockstepCore

/// The click of a whole song as a WAV file, for placing next to the song in Resolve.
///
///     let url = folder.appendingPathComponent(ClickFile.defaultName(songName: project.songName))
///     try await ClickFile.write(for: project, to: url)
///
/// The file is mono, 48,000 Hz, 24-bit. It starts at the timeline's 00:00, which is the start
/// of the Resolve timeline, and ends where what is left of the song ends (`SongPlace`): for a
/// song that is not cut, at song time zero and exactly as long as the song. It holds the click as Max hears it: the project's sound, how often it clicks
/// and its volume, and the accent on the first beat of a bar as Settings has it. Whether
/// the click is on does not matter.
public enum ClickFile {
    /// The name the save panel suggests: the song's name as the header shows it, spaces kept.
    public static func defaultName(songName: String) -> String {
        "click_\(songName).wav"
    }

    /// Lays out the click of the project's song and writes it to `url`, replacing a file
    /// already there. The work never runs on the main thread, whoever calls it. A song
    /// without beats gives a silent file of the same length.
    @concurrent
    public static func write(
        for project: Project,
        to url: URL,
        accentBeatOne: Bool = SettingKey<Bool>.accentBeatOne.defaultValue
    ) async throws {
        let gain = project.click.gain
        var samples = ClickRenderer.render(
            grid: project.grid,
            settings: project.click,
            lengthSamples: project.songLengthSamples,
            accentBeatOne: accentBeatOne,
            keeping: project.keptSamples
        )
        samples = project.songPlace.timelineRow(of: samples, ofLength: project.songLengthSamples)
        for index in samples.indices {
            samples[index] *= gain
        }
        try WavWriter.write(samples, channels: 1, to: url)
    }
}

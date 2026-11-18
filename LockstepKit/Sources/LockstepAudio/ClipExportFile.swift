import Foundation
import LockstepCore

extension ClipExporter {
    /// Writes an export into a folder under its own name (`ClipExport.fileName`) and gives back where it is.
    /// The folder is made when it is not there yet. A file of the same name is replaced.
    ///
    /// The file is a plain WAV: 48,000 Hz, 24-bit, with nothing in it but the format and the sound: mono, or
    /// stereo for a clip that is sent with its finished sound (`ClipExport.channels`). It
    /// carries no timecode. The timecode is shown to Max, who places the file by hand.
    ///
    /// When this returns, the whole file is on disk under its final name: `WavWriter.write` puts it beside
    /// its place first and moves it in only when it is complete. So a half-written file is never seen, and a
    /// file that is handed on right after this call is a real one.
    @discardableResult
    public static func write(_ export: ClipExport, toFolder folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(export.fileName, isDirectory: false)
        try write(export, to: url)
        return url
    }

    /// Writes an export to a file of the caller's choosing, replacing a file already there. The folder the
    /// file lies in is made when it is not there yet.
    public static func write(_ export: ClipExport, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WavWriter.write(export.samples, channels: export.channels, to: url)
    }
}

import Foundation

// How a made voice is named on disk: by how it was made, with which setting, of which recording.
//
//     let key = VoiceKey(recordingID: recording.id, knobs: voice.knobs, way: .fast)
//     package.voiceFile(for: key)        // cache/voices/<way>/<setting>/<recording id>.wav

/// How a voice was made, as far as its files are concerned: everything that can change the sound. A voice
/// made one way is never taken for one made another way, because each way has a folder of its own.
public struct VoiceWay: Codable, Sendable, Hashable {
    /// The method: "rubberband" for Fast. "seed-vc" or "soulx-svc" would be Natural, which is not built.
    public var method: String
    /// Raised by whoever changes anything that changes the sound: the method, a setting of it, the helper's
    /// resampling, a package's version.
    public var revision: Int
    /// The sample of Max's voice the voice was made toward. Natural only.
    public var sampleID: UUID?

    public init(method: String, revision: Int, sampleID: UUID? = nil) {
        self.method = method
        self.revision = revision
        self.sampleID = sampleID
    }

    /// The Fast way: Rubber Band through `VoiceShifter`, made by `VoiceMaker.fast`. Its files lie in
    /// `rubberband-r1`.
    ///
    /// Whoever changes the sound of a Fast voice raises the revision here, in the same change: a change to the
    /// settings `VoiceShifter` gives Rubber Band (its options, its mirrored ends, its loudness match), to the
    /// Rubber Band source in `CRubberBand`, or to how the knobs are turned into semitones and a formant scale
    /// (`VoiceMaker.formantScale(of:)`). The voices kept the old way are then never taken for new ones, and
    /// `VoiceFiles.tidy` removes their folder when the project closes.
    public static let fast = VoiceWay(method: "rubberband", revision: 1)

    /// The way as the name of a folder in the project's cache: `rubberband-r1`, and `seed-vc-r1-4f2a9c1e` for a
    /// Natural way, which ends with the first eight characters of the sample's id. A character of the method
    /// that is no letter, digit, "-", "_" or "." becomes "-", so the name is always one folder.
    public var folderName: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let name = String(method.map { allowed.contains($0) ? $0 : "-" })
        let sample = sampleID.map { "-" + $0.uuidString.prefix(8).lowercased() } ?? ""
        return "\(name)-r\(revision)\(sample)"
    }
}

/// One made voice: the recording it was made from, the setting, and the way. It is what a voice's file is
/// named by, and what a job that makes one is known by.
public struct VoiceKey: Sendable, Hashable {
    public var recordingID: UUID
    public var knobs: VoiceKnobs
    public var way: VoiceWay

    public init(recordingID: UUID, knobs: VoiceKnobs, way: VoiceWay) {
        self.recordingID = recordingID
        self.knobs = knobs
        self.way = way
    }
}

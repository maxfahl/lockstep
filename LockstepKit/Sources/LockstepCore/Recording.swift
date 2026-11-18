import Foundation

/// One original recording of the microphone. Its file is never changed: clips play
/// parts of it, and everything done to a clip is a description kept in the project.
public struct Recording: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// "takes/<id>.wav" inside the project folder: 48 kHz mono, never changed.
    public var file: String
    public var lengthSamples: Int
    /// Song seconds of sample 0, before the delay is removed.
    public var rawStart: Double
    /// The calibrated delay that is removed, in seconds. 0 until calibrated (phase 12).
    public var delay: Double
    /// The devices it was made with. Nil when they are not known.
    public var devicePair: DevicePair?
    /// Sample positions of the markers Max excluded. Phase 20.
    public var excludedMarkers: [Int]
    /// The speed the take was recorded at, as a share of the song's: 0.85 for a take recorded at 85 %. Nil,
    /// and left out of `project.json`, for a take recorded at the song's own speed. Phase 31.
    ///
    /// With it set, the file holds the take as it was recorded, slow, and is never changed. Everything else
    /// here counts in the sped-up sound, which is song time: `lengthSamples`, `rawStart`, `delay`,
    /// `excludedMarkers`, and every segment's `inSample` and `outSample`. The sped-up sound is made from the
    /// file (`SpedUpTake` in `LockstepAudio`), so nothing that reads a recording's sound needs to know.
    public var recordedSpeed: Double?

    public init(
        id: UUID = UUID(),
        file: String? = nil,
        lengthSamples: Int = 0,
        rawStart: Double = 0,
        delay: Double = 0,
        devicePair: DevicePair? = nil,
        excludedMarkers: [Int] = [],
        recordedSpeed: Double? = nil
    ) {
        self.id = id
        self.file = file ?? Recording.fileName(for: id)
        self.lengthSamples = lengthSamples
        self.rawStart = rawStart
        self.delay = delay
        self.devicePair = devicePair
        self.excludedMarkers = excludedMarkers
        // Only a speed below the song's own is one. Anything else is a take recorded as usual.
        self.recordedSpeed = recordedSpeed.flatMap { $0.isFinite && $0 > 0 && $0 < 1 ? $0 : nil }
    }

    /// Reads a saved recording. A missing field gets its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            file: try container.decodeIfPresent(String.self, forKey: .file),
            lengthSamples: try container.decodeIfPresent(Int.self, forKey: .lengthSamples) ?? 0,
            rawStart: try container.decodeIfPresent(Double.self, forKey: .rawStart) ?? 0,
            delay: try container.decodeIfPresent(Double.self, forKey: .delay) ?? 0,
            devicePair: try container.decodeIfPresent(DevicePair.self, forKey: .devicePair),
            excludedMarkers: try container.decodeIfPresent([Int].self, forKey: .excludedMarkers) ?? [],
            recordedSpeed: try container.decodeIfPresent(Double.self, forKey: .recordedSpeed)
        )
    }

    /// Where the recording with this id is kept inside the project folder.
    public static func fileName(for id: UUID) -> String {
        "takes/\(id.uuidString).wav"
    }

    /// The one position rule: the song time, in seconds, of a sample of this
    /// recording when it is played by a segment that was moved by `offsetSamples`.
    ///
    /// This is the only place the rule is written. Everything that needs a
    /// time (drawing, playback, markers, snapping, export) comes here, directly
    /// or through `Project.start(of:)` and `Project.end(of:)`.
    public func songTime(ofSample sample: Int, offsetSamples: Int = 0) -> Double {
        rawStart - delay + Double(offsetSamples + sample) / Lockstep.sampleRate
    }
}

/// The two audio devices a recording was made with. The measured delay of
/// phase 12 belongs to such a pair.
public struct DevicePair: Codable, Sendable, Equatable, Hashable {
    public var outputUID: String
    public var outputName: String
    public var inputUID: String
    public var inputName: String

    public init(outputUID: String = "", outputName: String = "", inputUID: String = "", inputName: String = "") {
        self.outputUID = outputUID
        self.outputName = outputName
        self.inputUID = inputUID
        self.inputName = inputName
    }

    /// Reads a saved pair. A missing field is empty.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            outputUID: try container.decodeIfPresent(String.self, forKey: .outputUID) ?? "",
            outputName: try container.decodeIfPresent(String.self, forKey: .outputName) ?? "",
            inputUID: try container.decodeIfPresent(String.self, forKey: .inputUID) ?? "",
            inputName: try container.decodeIfPresent(String.self, forKey: .inputName) ?? ""
        )
    }
}

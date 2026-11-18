import Foundation

// Syllable markers in a project: where they are kept, which of them fall inside a clip
// and when they sound in the song, and which ones Max has excluded.
//
// Markers belong to a recording, not to a clip. They are found once per recording and
// kept in the project's cache, so splitting, joining and moving clips never changes or
// loses them:
//
//     let found = package.readMarkers(forRecording: id, version: detectorVersion)   // nil: find them again
//     try package.writeMarkers(markers, forRecording: id, version: detectorVersion)
//
//     for marker in project.markers(in: clip, allMarkers: markersByRecording) {
//         // marker.songTime is where to draw it, marker.isExcluded whether Max excluded it
//     }

/// The markers of one recording as they are kept on disk.
public struct MarkerFile: Codable, Sendable, Equatable {
    /// The version of the detector that found them.
    public var version: Int
    /// In the order of the recording.
    public var markers: [SyllableMarker]

    public init(version: Int, markers: [SyllableMarker]) {
        self.version = version
        self.markers = markers
    }
}

/// Keeping the markers of a recording in the project's `cache/markers/` folder, as
/// `<recording id>.json`: the detector's version number and the markers, each with its
/// sample position in the recording and its strength.
///
/// The file can be thrown away at any time. `readMarkers` then gives nil and the markers
/// are found again from the recording.
extension ProjectPackage {
    public var markersFolder: URL {
        cacheFolder.appendingPathComponent("markers", isDirectory: true)
    }

    public func markersFile(forRecording id: UUID) -> URL {
        markersFolder.appendingPathComponent("\(id.uuidString).json")
    }

    /// Reads the markers of a recording. Nil when the file is missing or damaged, or was
    /// written by another version of the detector than `version`: the markers then have
    /// to be found again.
    public func readMarkers(forRecording id: UUID, version: Int) -> [SyllableMarker]? {
        guard let data = try? Data(contentsOf: markersFile(forRecording: id)),
              let file = try? JSONDecoder().decode(MarkerFile.self, from: data),
              file.version == version
        else { return nil }
        return file.markers
    }

    /// Writes the markers of a recording, replacing the file that was there. The folder
    /// is made if it is missing.
    public func writeMarkers(_ markers: [SyllableMarker], forRecording id: UUID, version: Int) throws {
        try FileManager.default.createDirectory(at: markersFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(MarkerFile(version: version, markers: markers))
            .write(to: markersFile(forRecording: id), options: .atomic)
    }
}

/// One marker as a clip shows it: a syllable of a recording, placed in the song.
public struct ClipMarker: Sendable, Equatable {
    /// The recording the syllable is in.
    public var recordingID: UUID
    /// Where it is in that recording, in samples. Together with the recording this is
    /// the marker's identity, and what is stored when Max excludes it.
    public var sample: Int
    /// How sharply the voice rises there, in decibels.
    public var strength: Double
    /// When the syllable sounds, in song seconds, where the clip is now.
    public var songTime: Double
    /// Whether Max has excluded it from timing fixes.
    public var isExcluded: Bool

    public init(recordingID: UUID, sample: Int, strength: Double, songTime: Double, isExcluded: Bool = false) {
        self.recordingID = recordingID
        self.sample = sample
        self.strength = strength
        self.songTime = songTime
        self.isExcluded = isExcluded
    }
}

extension Recording {
    /// How far a marker may have shifted and still be the one Max excluded: 10 ms, in samples.
    public static let exclusionReachSamples = 480

    /// Which of these markers Max has excluded, as their sample positions.
    ///
    /// An exclusion is stored as the position the marker had when Max excluded it
    /// (`excludedMarkers`). When the markers are found again, by a newer detector, a
    /// marker may land a few milliseconds from where it was. So an exclusion applies to
    /// the marker closest to the stored position, if one is within 10 ms. If none is,
    /// the exclusion applies to nothing, and stays stored.
    public func excludedSamples(among markers: [SyllableMarker]) -> Set<Int> {
        var excluded = Set<Int>()
        for position in excludedMarkers {
            let closest = markers.min { abs($0.sample - position) < abs($1.sample - position) }
            if let closest, abs(closest.sample - position) <= Self.exclusionReachSamples {
                excluded.insert(closest.sample)
            }
        }
        return excluded
    }

    /// Excludes one of these markers from the timing fixes, or takes it back in.
    ///
    /// Excluding stores the marker's own position. Taking it back in removes every stored position that
    /// stands for this marker (`excludedSamples` says which do), so a position stored before the markers
    /// were found again is removed as well. Positions that stand for another marker, or for none, stay.
    ///
    /// - Parameters:
    ///   - sample: the marker's place in the recording, in samples.
    ///   - markers: the markers of this recording as they are known now.
    public mutating func setExcluded(_ isExcluded: Bool, markerAt sample: Int, among markers: [SyllableMarker]) {
        let isExcludedNow = excludedSamples(among: markers).contains(sample)
        guard isExcluded != isExcludedNow else { return }
        if isExcluded {
            excludedMarkers.append(sample)
        } else {
            excludedMarkers.removeAll { position in
                let closest = markers.min { abs($0.sample - position) < abs($1.sample - position) }
                return closest?.sample == sample && abs(sample - position) <= Self.exclusionReachSamples
            }
        }
    }
}

extension Project {
    /// The markers that fall inside a clip, in the order of the clip's segments, each
    /// with the moment it sounds in the song.
    ///
    /// A marker is inside a segment when its sample is one the segment plays. Its song
    /// time comes from the one position rule (`Recording.songTime`), so it follows the
    /// recording's measured delay and every move of the clip. After a split each marker
    /// is in exactly one of the two pieces.
    ///
    /// - Parameter allMarkers: the markers of every recording, by recording id, each list
    ///   in the order of its recording. A recording that has none yet gives none.
    public func markers(in clip: Clip, allMarkers: [UUID: [SyllableMarker]]) -> [ClipMarker] {
        Self.markers(in: clip, allMarkers: allMarkers, recording: recording)
    }

    /// The same, asking for each recording by its id: the project itself, or its lookup table.
    static func markers(
        in clip: Clip,
        allMarkers: [UUID: [SyllableMarker]],
        recording: (UUID) -> Recording?
    ) -> [ClipMarker] {
        var result: [ClipMarker] = []
        var excludedByRecording: [UUID: Set<Int>] = [:]
        for segment in clip.segments {
            guard let recording = recording(segment.recordingID),
                  let markers = allMarkers[recording.id], !markers.isEmpty
            else { continue }
            let excluded = excludedByRecording[recording.id] ?? recording.excludedSamples(among: markers)
            excludedByRecording[recording.id] = excluded
            for marker in markers where marker.sample >= segment.inSample && marker.sample < segment.outSample {
                result.append(ClipMarker(
                    recordingID: recording.id,
                    sample: marker.sample,
                    strength: marker.strength,
                    songTime: recording.songTime(ofSample: marker.sample, offsetSamples: segment.offsetSamples),
                    isExcluded: excluded.contains(marker.sample)
                ))
            }
        }
        return result
    }
}

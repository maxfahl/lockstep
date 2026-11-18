import Foundation
import LockstepAudio
import LockstepCore
import Observation

/// The syllable markers of every recording of the open project, and the work of getting them.
///
/// Markers belong to a recording. They are found once, away from the main thread, and kept
/// in the project at `cache/markers/<recording id>.json`. Reopening the project reads that
/// file. Only when it is missing, damaged or from an older version of the detector are the
/// markers found again from the recording, without a word to Max.
///
///     markers.open(package, recordings: project.recordings, sounds: sounds)   // a project was opened
///     markers.find(ofRecording: id, sound: samples, in: package)              // a take was just recorded
///     markers.byRecording[id]                                                 // nil until they are known
///
/// A view that reads `byRecording` is drawn again when the markers of a recording arrive.
@MainActor
@Observable
final class SyllableMarkers {
    /// The markers of each recording, by recording id, in the order of the recording. A
    /// recording that is not in here has not been looked at yet, or its sound could not be read.
    private(set) var byRecording: [UUID: [SyllableMarker]] = [:]

    /// Whether the model is listening for the next change that the drawn markers follow.
    /// See `CorrectionModel.showMarkers(in:of:)`.
    @ObservationIgnored var isWatched = false

    /// Which grid the Auto feel has found for each clip from these markers, kept so that a clip is listened
    /// to again only when its syllables or the beats have changed. See `CorrectionModel.grid(for:in:)`.
    @ObservationIgnored var feels = FeelMemory()

    /// The project the markers belong to.
    @ObservationIgnored private var package: ProjectPackage?
    /// The work on the recordings of the project that was opened, while it is going on.
    @ObservationIgnored private var opening: Task<Void, Never>?

    /// A project was opened: the markers of the project before it are forgotten, and the
    /// markers of this one are read from its cache, or found where the cache has none.
    ///
    /// - Parameter sounds: the sound of the project's recordings, by recording id, mono at 48,000 Hz.
    func open(_ package: ProjectPackage, recordings: [Recording], sounds: [UUID: [Float]]) {
        opening?.cancel()
        byRecording = [:]
        self.package = package
        let ids = recordings.map(\.id)
        guard !ids.isEmpty else { return }
        opening = Task { [weak self] in
            // The markers of many recordings are handed over together. Every change of `byRecording` has
            // the model go through all clips again (their tightened sounds, their rows), so one recording
            // at a time made opening a project of 685 recordings 685 such passes.
            var rest = ids[...]
            while !rest.isEmpty {
                let gathered = await Self.markers(
                    ofFirstOf: rest, sounds: sounds, in: package, gatheringFor: Self.gatherTime
                )
                guard !Task.isCancelled else { return }
                rest = rest.dropFirst(gathered.looked)
                self?.keep(gathered.found, in: package)
            }
        }
    }

    /// How long the markers of an opened project are gathered before they are handed over together. Markers
    /// that are read from the cache all come within it. Markers that have to be found from the sound come
    /// a few recordings at a time, so the first clips get their marks while the rest is still looked for.
    private static let gatherTime = Duration.milliseconds(250)

    /// A recording was just finished: its markers are found and kept in the project.
    func find(ofRecording id: UUID, sound: [Float], in package: ProjectPackage) {
        self.package = package
        Task { [weak self] in
            let found = await Self.markers(ofRecording: id, sound: sound, in: package)
            self?.keep(found, ofRecording: id, in: package)
        }
    }

    /// Takes in markers that were read or found, unless another project has been opened since.
    private func keep(_ found: [SyllableMarker]?, ofRecording id: UUID, in package: ProjectPackage) {
        guard let found, self.package == package else { return }
        byRecording[id] = found
    }

    /// Takes in the markers of several recordings as one change, unless another project has been opened since.
    private func keep(_ found: [UUID: [SyllableMarker]], in package: ProjectPackage) {
        guard !found.isEmpty, self.package == package else { return }
        byRecording.merge(found) { _, new in new }
    }

    /// The markers of the first recordings of a list, as many as are read or found within `gatheringFor`,
    /// and one at least. `looked` is how many recordings of the list were gone through. A recording without
    /// markers and without a sound to find them from is counted and not in `found`.
    @concurrent
    private nonisolated static func markers(
        ofFirstOf ids: ArraySlice<UUID>,
        sounds: [UUID: [Float]],
        in package: ProjectPackage,
        gatheringFor time: Duration
    ) async -> (looked: Int, found: [UUID: [SyllableMarker]]) {
        let end = ContinuousClock.now + time
        var looked = 0
        var found: [UUID: [SyllableMarker]] = [:]
        for id in ids {
            guard !Task.isCancelled else { break }
            found[id] = await markers(ofRecording: id, sound: sounds[id], in: package)
            looked += 1
            if ContinuousClock.now >= end { break }
        }
        return (looked, found)
    }

    /// The markers of one recording: from the project's cache when they are there, and
    /// otherwise found from the recording and written to the cache. Nil when they are not
    /// in the cache and there is no sound to find them from.
    ///
    /// The detector reads the loudness curve that was kept when the recording was made. If
    /// that file is gone, the curve is measured again and kept again.
    @concurrent
    private nonisolated static func markers(
        ofRecording id: UUID,
        sound: [Float]?,
        in package: ProjectPackage
    ) async -> [SyllableMarker]? {
        if let kept = package.readMarkers(forRecording: id, version: SyllableDetector.version) {
            return kept
        }
        guard let sound else { return nil }
        let envelope: VoiceEnvelope
        if let kept = VoiceEnvelope.read(forRecording: id, lengthSamples: sound.count, from: package) {
            envelope = kept
        } else {
            envelope = VoiceEnvelope.envelope(of: sound)
            try? envelope.write(forRecording: id, to: package)
        }
        let found = SyllableDetector.markers(in: envelope)
        // The markers can always be found again, so a failed write is not an error.
        try? package.writeMarkers(found, forRecording: id, version: SyllableDetector.version)
        return found
    }
}

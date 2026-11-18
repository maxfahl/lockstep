import Foundation
import LockstepCore
import Synchronization
import Testing
@testable import LockstepAudio

/// A tool, not a test: the timing gate of phase 37. It says whether the sound of a made voice lies where
/// the sound of its recording lies, at the recording's own syllable markers, pause edges and line ends, and
/// whether correcting the voice with the recording's markers puts it where correcting the recording puts
/// the recording.
///
/// It runs only when an environment variable names the files. `Scripts/measure-timing.sh` and
/// `Scripts/measure-commute.sh` are how it is run:
///
///     Scripts/measure-timing.sh line.wav line-darker.wav line-much-darker.wav
///     Scripts/measure-timing.sh --joins 10,20 line.wav line-by-a-voice-model.wav
///     Scripts/measure-commute.sh --make 'Scripts/voice-test/shift.py {in} {out} --depth 6 --pitch -1' \
///         line.wav line-darker.wav build/voice-test/commute/darker
///
/// What the gate is (since 16 November 2026, see `VoiceDisplacement` for the measure and its pass marks):
///
/// 1. Displacement. At every syllable marker, pause edge and line end of the recording, how far the
///    voice's sound lies from the recording's, measured from the sound in five bands.
/// 2. The corrected line. The recording is put on a made-up beat of 100 beats a minute and corrected with
///    All at 100 % and Stretch (`ClipTightening.render`), once from its own samples and once from the
///    voice's, both with the recording's markers and levels, which is what the app does to a track with a
///    Voice. Where the recording's syllables land in the two results, the displacement is measured again.
/// 3. Commutation, in `commute()`: correcting the voice must give the same sound as making the voice from
///    the corrected recording.
///
/// What is only reported. The syllable finder is run on the voice too, and the report says how many of the
/// recording's markers it finds again within 10 ms, and the same for pause edges. This was the gate at
/// first. It is no pass mark, because the app never runs the finder on a made voice, and the finder loses
/// markers in a voice that was taken apart and put together though no sound has moved.
///
/// Before anything is measured the voice is brought to the recording's loudness, by the measure Normalize
/// uses, as `VoiceFile.takeIn` will do before a voice is kept. A voice that is not as long as the recording
/// is measured with silence where it is short, and the report says by how much.
@Suite("Voice timing measure")
struct VoiceTimingMeasure {
    static let environment = ProcessInfo.processInfo.environment

    /// A place of the recording is found again by the finder when the voice has one within this, in
    /// milliseconds. For the reported agreement only.
    static let finderWithinMs = 10.0
    /// How far to each side of a join the numbers are given apart, in seconds.
    static let joinReachSeconds = 0.5
    /// How short a quiet stretch of the voice may be and still be held against a pause of the recording, in
    /// milliseconds: the correction's 30 less the 10 either edge may be off.
    static let voiceQuietMs = SyllablePauses.atLeastMs - 2 * finderWithinMs
    /// The made-up beat the line is corrected against, in beats a minute.
    static let beatsPerMinute = 100.0
    /// Where the recording starts in the made-up song, in seconds, so that its first line has room to slide
    /// earlier.
    static let recordingStartSeconds = 1.0

    // MARK: The finder's agreement, which is only reported

    /// One place of the recording that the finder does not find again in the voice.
    struct Lost: Codable, Equatable {
        var seconds: Double
        /// "start" or "end" for a pause edge, nil for a syllable.
        var kind: String?
        /// How far away the voice's nearest place of the same kind is, in milliseconds. Positive is later.
        var nearestMs: Double?
        /// For a syllable: how sharply the recording rises there, in decibels (`SyllableMarker.strength`).
        var strength: Double?
    }

    /// How far the finder agrees with itself on the two sounds.
    struct Agreement: Codable, Equatable {
        var total: Int
        var kept: Int
        var keptPercent: Double
        /// The middle and the furthest distance of the ones found again, in milliseconds.
        var middleMs: Double?
        var furthestMs: Double?
        var notKept: [Lost]
        /// How many places the finder has in the voice that the recording does not have within 10 ms.
        var extraInVoice: Int
    }

    struct Place: Equatable {
        var sample: Int
        var kind: String?
        var strength: Double?
    }

    static func agreement(_ reference: [Place], with made: [Place], extras: [Place]? = nil) -> Agreement {
        func nearest(to place: Place, in others: [Place]) -> Int? {
            others.lazy.filter { $0.kind == place.kind }.map { $0.sample - place.sample }.min { abs($0) < abs($1) }
        }
        func milliseconds(_ samples: Int) -> Double { Double(samples) / Lockstep.sampleRate * 1_000 }
        var distances: [Double] = []
        var notKept: [Lost] = []
        for place in reference {
            let away = nearest(to: place, in: made).map(milliseconds)
            if let away, abs(away) <= finderWithinMs {
                distances.append(abs(away))
            } else {
                notKept.append(Lost(
                    seconds: (Double(place.sample) / Lockstep.sampleRate * 1_000).rounded() / 1_000,
                    kind: place.kind,
                    nearestMs: away.map { ($0 * 100).rounded() / 100 },
                    strength: place.strength
                ))
            }
        }
        let extra = (extras ?? made).filter { place in
            nearest(to: place, in: reference).map { abs(milliseconds($0)) > finderWithinMs } ?? true
        }
        distances.sort()
        return Agreement(
            total: reference.count,
            kept: distances.count,
            keptPercent: reference.isEmpty ? 100 : (Double(distances.count) / Double(reference.count) * 1_000).rounded() / 10,
            middleMs: distances.isEmpty ? nil : distances[distances.count / 2],
            furthestMs: distances.last,
            notKept: notKept,
            extraInVoice: extra.count
        )
    }

    static func syllables(in envelope: VoiceEnvelope) -> [Place] {
        SyllableDetector.markers(in: envelope).map { Place(sample: $0.sample, strength: $0.strength) }
    }

    /// Every pause of a sound, earliest first: `SyllablePauses.longest` asked for the whole sound, and then
    /// for what lies before and after each pause it found.
    static func pauses(in levels: VoiceLevels, lengthSamples: Int) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var waiting = [0..<lengthSamples]
        while let range = waiting.popLast() {
            guard let pause = SyllablePauses.longest(in: range, levels: levels) else { continue }
            found.append(pause)
            waiting.append(range.lowerBound..<pause.lowerBound)
            waiting.append(pause.upperBound..<range.upperBound)
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Every stretch of at least `atLeastMs` in which a sound is at or below the level that counts as
    /// sound, earliest first: the rule of `SyllablePauses.longest` with the shortest length left open, for
    /// the voice.
    static func quietStretches(in levels: VoiceLevels, lengthSamples: Int, atLeastMs: Double) -> [Range<Int>] {
        let hop = levels.hopSamples
        let atLeast = max(Int((atLeastMs * Lockstep.sampleRate / 1_000).rounded()), 1)
        var found: [Range<Int>] = []
        var index = 0
        while index < levels.values.count {
            guard levels.values[index] <= levels.threshold else {
                index += 1
                continue
            }
            var end = index + 1
            while end < levels.values.count, levels.values[end] <= levels.threshold { end += 1 }
            let quiet = index * hop..<min(end * hop, lengthSamples)
            if quiet.count >= atLeast { found.append(quiet) }
            index = end
        }
        return found
    }

    /// Where pauses start and end. The first sample and the last are left out: they are the ends of the
    /// file, not edges of sound.
    static func edges(of pauses: [Range<Int>], lengthSamples: Int) -> [Place] {
        pauses.flatMap { pause -> [Place] in
            var edges: [Place] = []
            if pause.lowerBound > 0 { edges.append(Place(sample: pause.lowerBound, kind: "start")) }
            if pause.upperBound < lengthSamples { edges.append(Place(sample: pause.upperBound, kind: "end")) }
            return edges
        }
    }

    // MARK: The correction

    /// The three ways a clip is corrected.
    enum Way: String, CaseIterable, Codable {
        case lines, all
        case allStretch = "all-stretch"

        var clip: (tighten: ClipTighten, stretch: Bool) {
            switch self {
            case .lines: (.lines, false)
            case .all: (.all, false)
            case .allStretch: (.all, true)
            }
        }
    }

    /// What the correction did to the line, so that a reader sees it was not idle.
    struct Correction: Codable, Equatable {
        var lines: Int
        var syllables: Int
        /// Syllables that are heard at least half a millisecond from where they were recorded.
        var moved: Int
        var furthestMoveMs: Double
        /// How many runs of sound the stretcher was asked to stretch.
        var stretchedRuns: Int
    }

    /// Counts how often the stretcher is asked, and otherwise is Rubber Band, as in the app.
    final class CountingStretcher: TimeStretcher {
        let runs = Mutex(0)
        let stretcher = RubberBandStretcher()

        func stretch(_ samples: [Float], keyFrames: [(source: Int, target: Int)], outputLength: Int) -> [Float] {
            runs.withLock { $0 += 1 }
            return stretcher.stretch(samples, keyFrames: keyFrames, outputLength: outputLength)
        }
    }

    /// A sound corrected against the made-up beat at 100 %, with the markers and the levels of the
    /// recording: what is heard when the clip's samples are `sound`.
    ///
    /// - Returns: the corrected sound of the whole recording, the sample of that sound on which each of the
    ///   recording's syllables that lies in a line is heard, and what the correction did.
    static func corrected(
        _ sound: [Float], way: Way = .allStretch, markers: [SyllableMarker], levels: VoiceLevels
    ) -> (samples: [Float], landings: [Int], correction: Correction) {
        let recording = Recording(lengthSamples: sound.count, rawStart: recordingStartSeconds)
        let clip = Clip(
            segments: [Segment(recordingID: recording.id, inSample: 0, outSample: sound.count)],
            tighten: way.clip.tighten,
            strength: 1,
            stretch: way.clip.stretch
        )
        let songSeconds = Double(sound.count) / Lockstep.sampleRate + 2 * recordingStartSeconds
        let beat = 60 / beatsPerMinute
        let project = Project(
            songLengthSamples: Int(songSeconds * Lockstep.sampleRate),
            grid: Grid(beats: (0...Int(songSeconds / beat)).map { Beat(number: $0, time: Double($0) * beat) }),
            tracks: [Track(name: "Track 1", clips: [clip])],
            recordings: [recording]
        )
        let nothing = Correction(lines: 0, syllables: 0, moved: 0, furthestMoveMs: 0, stretchedRuns: 0)
        guard let inputs = ClipTightening.Inputs(correcting: clip, in: project, markers: [recording.id: markers], voices: .none) else {
            return (sound, markers.map(\.sample), nothing)
        }
        let stretcher = CountingStretcher()
        let made = ClipTightening.render(
            inputs, levels: [recording.id: levels], recordings: [recording.id: sound], stretcher: stretcher
        )
        guard let segment = made.first else { return (sound, markers.map(\.sample), nothing) }
        let lead = segment.samples == nil ? 0 : segment.leadSamples
        var moves: [Double] = []
        var landings: [Int] = []
        for line in segment.lines {
            for marker in line.line.markers {
                let heard = segment.samples == nil ? marker : line.map.result(ofSource: marker)
                moves.append(Double(heard - marker) / Lockstep.sampleRate * 1_000)
                landings.append(lead + heard)
            }
        }
        let correction = Correction(
            lines: segment.lines.count,
            syllables: moves.count,
            moved: moves.filter { abs($0) >= 0.5 }.count,
            furthestMoveMs: ((moves.map(abs).max() ?? 0) * 100).rounded() / 100,
            stretchedRuns: stretcher.runs.withLock { $0 }
        )
        return (segment.samples ?? sound, landings, correction)
    }

    // MARK: One voice

    struct Gate: Codable, Equatable {
        /// At the recording's syllables, pause edges and line ends.
        var displacement: VoiceDisplacement.Summary
        /// The same places by what they are.
        var syllables: VoiceDisplacement.Summary
        var pauseEdges: VoiceDisplacement.Summary
        var lineEnds: VoiceDisplacement.Summary
        /// Where the recording's syllables land in the corrected line: the corrected voice against the
        /// corrected recording.
        var correctedLine: VoiceDisplacement.Summary
        /// The places of each line of the recording, for the reader: a line's numbers are no pass mark of
        /// their own, as the whole is.
        var lines: [LineNumbers]

        var passed: Bool { displacement.passed && correctedLine.passed }
    }

    /// The numbers of one line of the recording: the places from a little before it starts to a little
    /// after it ends (`lineReachMs`).
    struct LineNumbers: Codable, Equatable {
        var startSeconds: Double
        var endSeconds: Double
        var displacement: VoiceDisplacement.Summary
    }

    /// How far before a line starts and after it ends its places are taken from, in milliseconds: the
    /// edges of the pauses round it lie within the line's own margins of 10 and 30 ms.
    static let lineReachMs = 40.0

    struct FinderAgreement: Codable, Equatable {
        var syllables: Agreement
        var pauseEdges: Agreement
        /// The finder on the corrected recording against the finder on the corrected voice.
        var correctedLine: Agreement
    }

    /// Everything about one voice, as it is written beside the voice as `<voice>.timing.json`.
    struct Report: Codable, Equatable {
        var recording: String
        var voice: String
        var recordingSamples: Int
        var voiceSamples: Int
        /// The gain that brought the voice to the recording's loudness, in decibels. Nil when one of the two
        /// is silent, and the voice was then measured as it is.
        var gainToRecordingDb: Double?
        var recordingNoiseFloorDb: Double
        var voiceNoiseFloorDb: Double
        /// The pass marks the verdict was taken by.
        var withinMs: Double
        var withinPercentToPass: Double
        var furthestStartMsToPass: Double
        var furthestEndMsToPass: Double
        var unconfidentPercentToPass: Double
        var gate: Gate
        /// The joins that were named, in seconds, and the gate over the places within `joinReachSeconds` of
        /// any of them.
        var joins: [Double]
        var joinReachSeconds: Double
        var aroundJoins: Gate?
        var correction: Correction
        var passed: Bool
        /// Reported, and no pass mark: how far the syllable finder and the pause finder agree on the two.
        var detectorVersion: Int
        var finder: FinderAgreement
        /// How many of the recording's places lie too near an end of the file to be measured
        /// (`VoiceDisplacement.measurable`), and are in no number.
        var notMeasured: Int
        /// Every place that was measured.
        var places: [VoiceDisplacement.Found]
        var correctedLinePlaces: [VoiceDisplacement.Found]
    }

    /// A voice as long as its recording (cut where it is long, silent where it is short) and as loud.
    static func fitted(_ original: [Float], to recording: [Float]) -> (samples: [Float], gainDb: Double?) {
        var voice = Array(original.prefix(recording.count))
        voice += [Float](repeating: 0, count: recording.count - voice.count)
        guard let wanted = Loudness.integrated(recording), let had = Loudness.integrated(voice) else { return (voice, nil) }
        let gain = Float(pow(10, (wanted - had) / 20))
        return (voice.map { $0 * gain }, wanted - had)
    }

    /// The displacement of one sound against another at places of the first.
    static func displacement(
        of other: [Float], against reference: [Float], at places: [(sample: Int, kind: String)]
    ) -> [VoiceDisplacement.Found] {
        let curves = VoiceDisplacement.Curves(of: reference)
        let floors = curves.floors
        return VoiceDisplacement.measure(
            places, reference: curves.lifted(to: floors), other: VoiceDisplacement.Curves(of: other).lifted(to: floors)
        )
    }

    /// Everything about one voice against its recording.
    ///
    /// - Parameter joins: the places where a voice model joined one stretch to the next, in seconds.
    static func measure(
        recording: [Float], voice original: [Float], joins: [Double], recordingPath: String, voicePath: String
    ) -> Report {
        let (voice, gainDb) = fitted(original, to: recording)
        let recordingEnvelope = VoiceEnvelope.envelope(of: recording)
        let voiceEnvelope = VoiceEnvelope.envelope(of: voice)
        let threshold = recordingEnvelope.noiseFloor + VoiceEnvelope.clearlyAboveDecibels
        func levels(_ envelope: VoiceEnvelope) -> VoiceLevels {
            VoiceLevels(values: envelope.values, threshold: threshold, hopSamples: VoiceEnvelope.hopSamples)
        }
        let markers = SyllableDetector.markers(in: recordingEnvelope)
        let recordingPauses = pauses(in: levels(recordingEnvelope), lengthSamples: recording.count)
        let recordingEdges = edges(of: recordingPauses, lengthSamples: recording.count)
        let lines = LineFinder.lines(
            in: 0..<recording.count, levels: levels(recordingEnvelope), markers: markers.map(\.sample)
        )

        // The gate: the sound itself at the recording's places.
        var places: [(sample: Int, kind: String)] = markers.map { ($0.sample, "syllable") }
        places += recordingEdges.map { ($0.sample, "pause \($0.kind ?? "")") }
        places += lines.flatMap { [($0.startSample, "line start"), ($0.endSample, "line end")] }
        let found = displacement(of: voice, against: recording, at: places)

        let fromRecording = corrected(recording, markers: markers, levels: levels(recordingEnvelope))
        let fromVoice = corrected(voice, markers: markers, levels: levels(recordingEnvelope))
        let correctedFound = displacement(
            of: fromVoice.samples, against: fromRecording.samples, at: fromRecording.landings.map { ($0, "syllable") }
        )

        func gate(_ counted: (Double) -> Bool) -> Gate {
            let here = found.filter { counted($0.seconds) }
            func kind(_ prefix: String) -> VoiceDisplacement.Summary {
                VoiceDisplacement.summary(of: here.filter { $0.kind.hasPrefix(prefix) })
            }
            return Gate(
                displacement: VoiceDisplacement.summary(of: here),
                syllables: kind("syllable"),
                pauseEdges: kind("pause"),
                lineEnds: kind("line"),
                // A syllable of the corrected line is heard up to a line's slide from where it was recorded,
                // which is little against the half second around a join.
                correctedLine: VoiceDisplacement.summary(of: correctedFound.filter { counted($0.seconds) }),
                lines: lines.compactMap { line in
                    let reach = lineReachMs / 1_000
                    let start = Double(line.startSample) / Lockstep.sampleRate, end = Double(line.endSample) / Lockstep.sampleRate
                    guard counted(start) || counted(end) else { return nil }
                    return LineNumbers(
                        startSeconds: (start * 1_000).rounded() / 1_000,
                        endSeconds: (end * 1_000).rounded() / 1_000,
                        displacement: VoiceDisplacement.summary(of: here.filter { $0.seconds >= start - reach && $0.seconds <= end + reach })
                    )
                }
            )
        }
        let whole = gate { _ in true }
        let aroundJoins = joins.isEmpty ? nil : gate { seconds in joins.contains { abs($0 - seconds) <= joinReachSeconds } }

        // Only reported: the finder on both.
        let correctedRecordingEnvelope = VoiceEnvelope.envelope(of: fromRecording.samples)
        let correctedVoiceEnvelope = VoiceEnvelope.envelope(of: fromVoice.samples)
        let finder = FinderAgreement(
            syllables: agreement(syllables(in: recordingEnvelope), with: syllables(in: voiceEnvelope)),
            pauseEdges: agreement(
                recordingEdges,
                with: edges(
                    of: quietStretches(in: levels(voiceEnvelope), lengthSamples: recording.count, atLeastMs: voiceQuietMs),
                    lengthSamples: recording.count
                ),
                extras: edges(of: pauses(in: levels(voiceEnvelope), lengthSamples: recording.count), lengthSamples: recording.count)
            ),
            correctedLine: agreement(syllables(in: correctedRecordingEnvelope), with: syllables(in: correctedVoiceEnvelope))
        )
        return Report(
            recording: recordingPath,
            voice: voicePath,
            recordingSamples: recording.count,
            voiceSamples: original.count,
            gainToRecordingDb: gainDb.map { ($0 * 100).rounded() / 100 },
            recordingNoiseFloorDb: Double((recordingEnvelope.noiseFloor * 10).rounded() / 10),
            voiceNoiseFloorDb: Double((voiceEnvelope.noiseFloor * 10).rounded() / 10),
            withinMs: VoiceDisplacement.Pass.withinMs,
            withinPercentToPass: VoiceDisplacement.Pass.withinPercent,
            furthestStartMsToPass: VoiceDisplacement.Pass.furthestStartMs,
            furthestEndMsToPass: VoiceDisplacement.Pass.furthestEndMs,
            unconfidentPercentToPass: VoiceDisplacement.Pass.unconfidentPercent,
            gate: whole,
            joins: joins,
            joinReachSeconds: joinReachSeconds,
            aroundJoins: aroundJoins,
            correction: fromRecording.correction,
            passed: whole.passed && (aroundJoins?.passed ?? true),
            detectorVersion: SyllableDetector.version,
            finder: finder,
            notMeasured: places.count - found.count,
            places: found,
            correctedLinePlaces: correctedFound
        )
    }

    // MARK: The words of a report

    /// The places a reader should look at: the confident ones that are not in place, furthest first, and how
    /// many are not confident.
    static func outliers(_ found: [VoiceDisplacement.Found]) -> [String] {
        let off = found.filter { $0.confident && abs($0.displacementMs) > VoiceDisplacement.Pass.withinMs }
            .sorted { abs($0.displacementMs) > abs($1.displacementMs) }
        var lines = off.prefix(8).map { place in
            String(format: "      %.3f s (\(place.kind)): %.1f ms ", place.seconds, abs(place.displacementMs))
                + (place.displacementMs > 0 ? "later" : "earlier")
        }
        if off.count > 8 { lines.append("      and \(off.count - 8) more, in the numbers") }
        return lines
    }

    static func words(of report: Report) -> String {
        var lines = ["\(report.voice)", "  against \(report.recording)"]
        let difference = report.voiceSamples - report.recordingSamples
        lines.append(
            difference == 0
                ? "  length: \(report.recordingSamples) samples, as the recording"
                : "  length: \(report.voiceSamples) samples, \(abs(difference)) \(difference > 0 ? "more" : "fewer") "
                    + "than the recording's \(report.recordingSamples): NOT AS LONG AS THE RECORDING"
        )
        lines.append(
            report.gainToRecordingDb.map { gain in
                abs(gain) < 0.05
                    ? "  loudness: as loud as the recording"
                    : String(format: "  loudness: %.1f dB ", abs(gain)) + (gain > 0 ? "quieter" : "louder")
                        + " than the recording, and brought to its loudness before it was measured"
            } ?? "  loudness: one of the two is silent, so the voice is measured as it is"
        )
        if report.notMeasured > 0 {
            let room = VoiceDisplacement.Marks.longReachMs + VoiceDisplacement.Marks.furthestMs
            lines.append("  \(report.notMeasured) of the recording's places lie within \(room) ms of an end of the file and are not measured")
        }
        func gate(_ gate: Gate, places: [VoiceDisplacement.Found], corrected: [VoiceDisplacement.Found], indent: String) {
            lines.append(indent + VoiceDisplacement.words("displacement at the recording's places", gate.displacement))
            lines.append(indent + "  " + VoiceDisplacement.words("syllables", gate.syllables, verdict: false))
            lines.append(indent + "  " + VoiceDisplacement.words("pause edges", gate.pauseEdges, verdict: false))
            lines.append(indent + "  " + VoiceDisplacement.words("line starts and ends", gate.lineEnds, verdict: false))
            for line in gate.lines {
                lines.append(indent + "  " + VoiceDisplacement.words(
                    String(format: "line %.3f to %.3f s", line.startSeconds, line.endSeconds), line.displacement, verdict: false
                ))
            }
            lines += outliers(places)
            lines.append(indent + VoiceDisplacement.words("corrected line, the voice against the recording", gate.correctedLine))
            lines += outliers(corrected)
        }
        gate(report.gate, places: report.places, corrected: report.correctedLinePlaces, indent: "  ")
        let correction = report.correction
        lines.append(
            "    (All at 100 % with Stretch, \(Int(beatsPerMinute)) beats a minute: \(correction.lines) lines, \(correction.moved) of "
                + "\(correction.syllables) syllables moved, furthest "
                + String(format: "%.1f ms, ", correction.furthestMoveMs) + "\(correction.stretchedRuns) runs stretched)"
        )
        if let around = report.aroundJoins {
            let near = { (place: VoiceDisplacement.Found) in report.joins.contains { abs($0 - place.seconds) <= report.joinReachSeconds } }
            lines.append(
                String(format: "  within %.1f s of the joins at ", report.joinReachSeconds)
                    + report.joins.map { String(format: "%.3f s", $0) }.joined(separator: ", ") + ":"
            )
            gate(around, places: report.places.filter(near), corrected: report.correctedLinePlaces.filter(near), indent: "    ")
        }
        func agreed(_ name: String, _ part: Agreement) -> String {
            "\(name) \(part.kept) of \(part.total)" + String(format: " (%.1f %%)", part.keptPercent)
        }
        lines.append(
            "  reported, no pass mark: the finder finds again within 10 ms: " + agreed("syllables", report.finder.syllables)
                + ", " + agreed("pause edges", report.finder.pauseEdges) + ", " + agreed("syllables of the corrected line", report.finder.correctedLine)
        )
        lines.append(report.passed ? "  passed" : "  FAILED")
        return lines.joined(separator: "\n")
    }

    /// Where the numbers of a voice are written: beside it, as `<voice without .wav>.timing.json`.
    static func reportFile(forVoice path: String) -> URL {
        URL(filePath: path).deletingPathExtension().appendingPathExtension("timing.json")
    }

    // MARK: The tools

    /// Reads a sound for a tool, or says in `said` why it cannot be measured.
    static func read(_ path: String, said: inout [String]) -> [Float]? {
        do {
            return try RecordingLoader.read(URL(filePath: path))
        } catch {
            said.append(
                "\(path)\n  could not be measured: "
                    + (error == .wrongSampleRate ? "it is not at 48,000 Hz" : "it cannot be read as sound")
            )
            return nil
        }
    }

    /// Prints what a tool found and writes it to the file `variable` names, with the verdict as its last
    /// line: "passed", "failed" or "error".
    static func finish(_ said: [String], verdict: String, reportVariable variable: String) throws {
        let text = (said + [verdict]).joined(separator: "\n") + "\n"
        print(text)
        if let report = environment[variable] {
            try text.write(to: URL(filePath: report), atomically: true, encoding: .utf8)
        }
    }

    /// `LOCKSTEP_VOICE_TIMING` names the recording, `LOCKSTEP_VOICE_TIMING_VOICES` the voices, one path a
    /// line, and `LOCKSTEP_VOICE_TIMING_JOINS` the joins, in seconds with commas between them. What is found
    /// is printed, written beside each voice as JSON, and written as words to the file
    /// `LOCKSTEP_VOICE_TIMING_REPORT` names, whose last line is "passed", "failed" or "error".
    @Test(.enabled(if: environment["LOCKSTEP_VOICE_TIMING"] != nil, "A tool: run by Scripts/measure-timing.sh."))
    func measure() throws {
        let recordingPath = try #require(Self.environment["LOCKSTEP_VOICE_TIMING"])
        let voicePaths = (Self.environment["LOCKSTEP_VOICE_TIMING_VOICES"] ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let joins = (Self.environment["LOCKSTEP_VOICE_TIMING_JOINS"] ?? "")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        var said: [String] = []
        var verdict = "passed"
        guard let recording = Self.read(recordingPath, said: &said), !voicePaths.isEmpty else {
            if voicePaths.isEmpty { said.append("No voice was named.") }
            try Self.finish(said, verdict: "error", reportVariable: "LOCKSTEP_VOICE_TIMING_REPORT")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for path in voicePaths {
            guard let voice = Self.read(path, said: &said) else {
                verdict = "error"
                continue
            }
            let report = Self.measure(
                recording: recording, voice: voice, joins: joins, recordingPath: recordingPath, voicePath: path
            )
            let file = Self.reportFile(forVoice: path)
            try encoder.encode(report).write(to: file, options: .atomic)
            said.append(Self.words(of: report) + "\n  numbers: \(file.path)")
            if !report.passed, verdict == "passed" { verdict = "failed" }
        }
        try Self.finish(said, verdict: verdict, reportVariable: "LOCKSTEP_VOICE_TIMING_REPORT")
    }

    // MARK: Commutation

    /// One way of correcting, in the commutation check.
    struct Commuted: Codable, Equatable {
        var way: Way
        var correction: Correction
        /// The corrected voice against the voice made from the corrected recording, where the recording's
        /// syllables land.
        var displacement: VoiceDisplacement.Summary
        var places: [VoiceDisplacement.Found]
        /// The two files that were compared.
        var correctedVoice: String
        var voiceOfCorrected: String
    }

    /// The functional check: does it matter whether a line is corrected before its voice is made or after?
    /// The app corrects after: it makes the voice of the whole recording once and corrects that with the
    /// recording's markers. If that gives the same sound as making the voice from the corrected recording,
    /// the recording's markers are right for the voice.
    ///
    /// `LOCKSTEP_VOICE_COMMUTE` names the recording and `LOCKSTEP_VOICE_COMMUTE_FOLDER` a folder.
    ///
    /// - Without `LOCKSTEP_VOICE_COMMUTE_VOICE`: the recording is corrected the three ways (Lines, All, All
    ///   with Stretch, each at 100 % against the made-up beat) and written to the folder as
    ///   `recording-lines.wav`, `recording-all.wav` and `recording-all-stretch.wav`. Whoever runs the check
    ///   then makes the voice of each, with the settings the voice was made with, as `made-lines.wav`,
    ///   `made-all.wav` and `made-all-stretch.wav` in the same folder.
    /// - With it: the voice (made from the recording as it is) is corrected the three ways with the
    ///   recording's markers, written as `voice-<way>.wav`, and held against `made-<way>.wav` with the
    ///   displacement measure. The numbers go to `commute.json` in the folder and, as words, to the file
    ///   `LOCKSTEP_VOICE_COMMUTE_REPORT` names. `Scripts/measure-commute.sh` adds the spectral distance.
    @Test(.enabled(if: environment["LOCKSTEP_VOICE_COMMUTE"] != nil, "A tool: run by Scripts/measure-commute.sh."))
    func commute() throws {
        let recordingPath = try #require(Self.environment["LOCKSTEP_VOICE_COMMUTE"])
        let folder = URL(filePath: try #require(Self.environment["LOCKSTEP_VOICE_COMMUTE_FOLDER"]))
        var said: [String] = []
        guard let recording = Self.read(recordingPath, said: &said) else {
            try Self.finish(said, verdict: "error", reportVariable: "LOCKSTEP_VOICE_COMMUTE_REPORT")
            return
        }
        let envelope = VoiceEnvelope.envelope(of: recording)
        let levels = VoiceLevels(
            values: envelope.values,
            threshold: envelope.noiseFloor + VoiceEnvelope.clearlyAboveDecibels,
            hopSamples: VoiceEnvelope.hopSamples
        )
        let markers = SyllableDetector.markers(in: envelope)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        guard let voicePath = Self.environment["LOCKSTEP_VOICE_COMMUTE_VOICE"] else {
            for way in Way.allCases {
                let made = Self.corrected(recording, way: way, markers: markers, levels: levels)
                let file = folder.appending(path: "recording-\(way.rawValue).wav")
                try WavWriter.write(made.samples, channels: 1, to: file)
                said.append("\(file.path): the recording corrected (\(way.rawValue)), \(made.samples.count) samples")
            }
            try Self.finish(said, verdict: "passed", reportVariable: "LOCKSTEP_VOICE_COMMUTE_REPORT")
            return
        }
        guard let original = Self.read(voicePath, said: &said) else {
            try Self.finish(said, verdict: "error", reportVariable: "LOCKSTEP_VOICE_COMMUTE_REPORT")
            return
        }
        let voice = Self.fitted(original, to: recording).samples
        var verdict = "passed"
        var found: [Commuted] = []
        said.append("\(voicePath)\n  against \(recordingPath): corrected after its voice was made, against made after it was corrected")
        for way in Way.allCases {
            let after = Self.corrected(voice, way: way, markers: markers, levels: levels)
            let afterFile = folder.appending(path: "voice-\(way.rawValue).wav")
            try WavWriter.write(after.samples, channels: 1, to: afterFile)
            let beforeFile = folder.appending(path: "made-\(way.rawValue).wav")
            guard let before = Self.read(beforeFile.path, said: &said) else {
                verdict = "error"
                continue
            }
            // The voice of the corrected recording is the reference: it is what a line corrected before its
            // voice was made sounds like. It is brought to the corrected voice's length and loudness.
            let reference = Self.fitted(before, to: after.samples).samples
            let places = Self.displacement(of: after.samples, against: reference, at: after.landings.map { ($0, "syllable") })
            let summary = VoiceDisplacement.summary(of: places)
            found.append(Commuted(
                way: way, correction: after.correction, displacement: summary, places: places,
                correctedVoice: afterFile.path, voiceOfCorrected: beforeFile.path
            ))
            said.append("  " + VoiceDisplacement.words(way.rawValue, summary))
            said += Self.outliers(places)
            if before.count != after.samples.count {
                said.append("    made-\(way.rawValue).wav has \(before.count) samples and the corrected voice \(after.samples.count)")
            }
            if !summary.passed, verdict == "passed" { verdict = "failed" }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(found).write(to: folder.appending(path: "commute.json"), options: .atomic)
        try Self.finish(said, verdict: verdict, reportVariable: "LOCKSTEP_VOICE_COMMUTE_REPORT")
    }

    /// Makes a take as one recorded slower would come into the app. `LOCKSTEP_VOICE_SLOW_TAKE` names a line,
    /// `LOCKSTEP_VOICE_SLOW_TAKE_OUT` where the sped-up sound is written, and `LOCKSTEP_VOICE_SLOW_TAKE_RATE`
    /// the speed (0.85 when it is left out). The line is slowed to that speed at the same pitch and then
    /// brought back with `SpedUpTake`, as the app brings a slow take back. With
    /// `LOCKSTEP_VOICE_SLOW_TAKE_IS_SLOW` the line is one that was recorded slower already, and it is only
    /// brought back. `LOCKSTEP_VOICE_SLOW_TAKE_SLOW` names where the slow sound is written, if it is wanted.
    /// `Scripts/voice-test/slow-take.sh` is how it is run.
    @Test(.enabled(if: environment["LOCKSTEP_VOICE_SLOW_TAKE"] != nil, "A tool: run by Scripts/voice-test/slow-take.sh."))
    func slowTake() throws {
        let source = try #require(Self.environment["LOCKSTEP_VOICE_SLOW_TAKE"])
        let output = try #require(Self.environment["LOCKSTEP_VOICE_SLOW_TAKE_OUT"])
        let rate = Self.environment["LOCKSTEP_VOICE_SLOW_TAKE_RATE"].flatMap(Double.init) ?? 0.85
        try #require(rate > SlowTime.slowestRate && rate < 1, "The speed must be below 1 and above a half.")
        let line = try RecordingLoader.read(URL(filePath: source))
        var slow = line
        if Self.environment["LOCKSTEP_VOICE_SLOW_TAKE_IS_SLOW"] == nil {
            let length = Int((Double(line.count) / rate).rounded())
            slow = WavWriter.asStored(RubberBandStretcher().stretch(line, keyFrames: [], outputLength: length))
        }
        if let kept = Self.environment["LOCKSTEP_VOICE_SLOW_TAKE_SLOW"] {
            try WavWriter.write(slow, channels: 1, to: URL(filePath: kept))
        }
        let made = SpedUpTake.make(from: slow, rate: rate)
        try WavWriter.write(made.samples, channels: 1, to: URL(filePath: output))
        print("slow take: \(slow.count) samples at \(rate) of the speed, \(made.samples.count) samples sped up, at \(output)")
    }
}

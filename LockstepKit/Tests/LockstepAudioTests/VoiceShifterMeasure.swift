import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// The Fast way of phase 37 made with Rubber Band, the library Lockstep already has, so that it can be held
/// against WORLD (`Scripts/voice-test/shift.py`) with the same tools. A tool, not a test: it only runs when
/// `LOCKSTEP_VOICE_TEST` names a folder.
///
///     LOCKSTEP_VOICE_TEST=build/voice-test/rb swift test --package-path LockstepKit --filter VoiceShifterMeasure
///     Scripts/voice-test/shift-rb.sh line.wav line-darker.wav --depth 6 --pitch -1
///
/// Every WAV file in the folder (mono, or its first channel, at 48,000 Hz) is shifted with
/// `VoiceShifter.shift(_:semitones:formantScale:)`, the engine of the doubles, at every setting of
/// `LOCKSTEP_VOICE_TEST_SETTINGS` ("depth,pitch" pairs with spaces or semicolons between them; the three
/// amounts of the design and no change when it is left out), and each answer is written beside its file as
/// `<name>.rb.d<depth>.p<pitch>.wav`, 48,000 Hz, 24-bit. Files whose name holds ".rb." are answers and are
/// not read. Unless `LOCKSTEP_VOICE_TEST_BACK` is 0, every setting that changes something is also taken
/// there and back: the answer shifted again by the opposite knobs, as `<name>.rb.d<depth>.p<pitch>.back.wav`.
/// How long each took is written to `<name>.rb.json`.
///
/// The knobs mean what the design says. Depth is percent, positive deeper: the formants are moved by
/// `1 - depth / 100`, which is what WORLD's envelope move does. Pitch is semitones, the formants kept where
/// they are.
///
/// No change. `VoiceShifter` hands back the very samples at 0 semitones and a formant scale of 1, and in the
/// app Depth 0 with Pitch 0 is the recording itself. What the test compares at no change is the cost of one
/// pass through the engine, so the answer of 0 and 0 is made with a formant scale of `1 - 1e-6`: a move of a
/// millionth, which no measure can see, but the engine takes the voice apart and puts it together.
struct VoiceShifterMeasure {
    static let environment = ProcessInfo.processInfo.environment

    /// One setting of the two knobs.
    struct Setting: Equatable, Codable {
        var depth: Double
        var pitch: Double

        var name: String { "d\(Self.number(depth)).p\(Self.number(pitch))" }
        var changesNothing: Bool { depth == 0 && pitch == 0 }
        var opposite: Setting { Setting(depth: -depth, pitch: -pitch) }

        /// The formant scale the engine is given. See "No change" above for the millionth.
        var formantScale: Double { changesNothing ? 1 - 1e-6 : 1 - depth / 100 }

        static func number(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }

        /// The settings named by `text`, or the design's three amounts and no change.
        static func list(_ text: String?) -> [Setting] {
            guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                return [
                    Setting(depth: 0, pitch: 0), Setting(depth: 3, pitch: -0.5), Setting(depth: 6, pitch: -1),
                    Setting(depth: 10, pitch: -2),
                ]
            }
            return text.split(whereSeparator: { $0 == ";" || $0 == " " || $0 == "\n" }).compactMap { pair in
                let parts = pair.split(separator: ",").compactMap { Double($0) }
                return parts.count == 2 ? Setting(depth: parts[0], pitch: parts[1]) : nil
            }
        }
    }

    /// How long one answer took.
    struct Timing: Codable, Equatable {
        var setting: Setting
        var file: String
        var secondsOfVoice: Double
        var secondsOfWork: Double
        var workPerSecondOfVoice: Double
        /// From reading the source to the finished file on disk.
        var secondsToFile: Double
    }

    static func shift(_ samples: [Float], by setting: Setting) -> [Float] {
        VoiceShifter.shift(samples, semitones: setting.pitch, formantScale: setting.formantScale)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Makes one answer and writes it, with how long it took. `readSeconds` is how long reading the source
    /// took, which belongs to the way from the start to the finished file.
    static func answer(
        _ samples: [Float], by setting: Setting, to url: URL, readSeconds: Double
    ) throws -> ([Float], Timing) {
        let clock = ContinuousClock()
        let before = clock.now
        let made = shift(samples, by: setting)
        let work = seconds(before.duration(to: clock.now))
        try WavWriter.write(made, channels: 1, to: url)
        let toFile = readSeconds + seconds(before.duration(to: clock.now))
        let length = Double(samples.count) / Lockstep.sampleRate
        return (
            made,
            Timing(
                setting: setting, file: url.lastPathComponent, secondsOfVoice: length, secondsOfWork: work,
                workPerSecondOfVoice: length > 0 ? work / length : 0, secondsToFile: toFile
            )
        )
    }

    @Test(.enabled(if: environment["LOCKSTEP_VOICE_TEST"] != nil, "A tool: run by Scripts/voice-test/shift-rb.sh."))
    func shiftFolder() throws {
        let folder = URL(filePath: try #require(Self.environment["LOCKSTEP_VOICE_TEST"]), directoryHint: .isDirectory)
        let settings = Setting.list(Self.environment["LOCKSTEP_VOICE_TEST_SETTINGS"])
        let back = Self.environment["LOCKSTEP_VOICE_TEST_BACK"] != "0"
        try #require(RubberBandStretcher.engineIsSetUp, "Rubber Band is not set up.")
        let sources = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" && !$0.lastPathComponent.contains(".rb.") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!sources.isEmpty, "There is no WAV file in \(folder.path).")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for source in sources {
            let stem = source.deletingPathExtension().lastPathComponent
            let clock = ContinuousClock()
            let started = clock.now
            let samples = try RecordingLoader.read(source)
            let readSeconds = Self.seconds(started.duration(to: clock.now))
            var timings: [Timing] = []
            for setting in settings {
                let file = folder.appending(path: "\(stem).rb.\(setting.name).wav")
                let (made, timing) = try Self.answer(samples, by: setting, to: file, readSeconds: readSeconds)
                timings.append(timing)
                print(
                    "\(file.path): " + String(format: "%.2f s, %.3f s of work for each second of voice, %.3f s to the file",
                        timing.secondsOfVoice, timing.workPerSecondOfVoice, timing.secondsToFile)
                )
                if back, !setting.changesNothing {
                    let backFile = folder.appending(path: "\(stem).rb.\(setting.name).back.wav")
                    let (_, backTiming) = try Self.answer(
                        WavWriter.asStored(made), by: setting.opposite, to: backFile, readSeconds: 0
                    )
                    timings.append(backTiming)
                }
            }
            try encoder.encode(timings).write(to: folder.appending(path: "\(stem).rb.json"), options: .atomic)
        }
    }
}

import Foundation
import LockstepCore
import Testing
@testable import LockstepAudio

/// A made-up take as it would be recorded against a slowed song: syllables of voiced sound, some running
/// together and some with a pause between them, with one click on every syllable start, and a held tone at
/// the end. It is the same on every run.
enum SlowTakeFixture {
    struct Take {
        var samples: [Float]
        /// Where each syllable starts: the sample its click is on.
        var starts: [Int]
        /// The held tone, a plain sine of `toneHz`.
        var tone: Range<Int>
    }

    static let toneHz = 440.0

    /// - Parameter rounds: how many times the row of syllables is said. One round is about three seconds.
    static func take(rounds: Int = 1) -> Take {
        var noise = StretchFixtures.Random(state: 31)
        func room(_ count: Int) -> [Float] { (0..<count).map { _ in Float((noise.next() * 2 - 1) * 0.001) } }
        func ms(_ milliseconds: Int) -> Int { milliseconds * 48 }

        // Each syllable: how long it sounds, the pause after it, and the length of one wave of its pitch.
        let syllables: [(sound: Int, pause: Int, period: Int)] = [
            (260, 0, 400), (300, 0, 300), (180, 0, 480), (220, 0, 360), (280, 120, 320),
            (150, 0, 436), (250, 0, 290), (300, 0, 410), (300, 200, 350), (240, 0, 380),
        ]
        var samples = room(ms(500))
        var starts: [Int] = []
        for _ in 0..<rounds {
            for syllable in syllables {
                starts.append(samples.count)
                var sound = StretchFixtures.syllable(period: syllable.period, count: ms(syllable.sound))
                sound[0] = 0.8
                samples += sound
                samples += room(ms(syllable.pause))
            }
            samples += room(ms(150))
        }
        // The held tone, with 5 ms to rise and to fall, and a short rest of room after it.
        let toneStart = samples.count
        let toneLength = ms(1200)
        starts.append(toneStart)
        samples += (0..<toneLength).map { index in
            let edge = min(1, Double(min(index, toneLength - index)) / 240)
            return Float(0.3 * edge * sin(2 * Double.pi * toneHz * Double(index) / 48_000))
        }
        samples += room(ms(100))
        return Take(samples: samples, starts: starts, tone: toneStart..<(toneStart + toneLength))
    }
}

@Suite("The sped-up sound of a slow take")
struct SpedUpTakeTests {
    /// The stretch tolerance in samples.
    private let tolerance = RubberBandStretcher.toleranceSeconds * 48_000

    /// The syllable start the detector found for a start of the made-up take: the first one at or after its click.
    private func detected(_ start: Int, among found: [Int]) -> Int? {
        found.first { $0 >= start && $0 - start < 480 }
    }

    @Test("Each click on a syllable start lands on its start times the rate", arguments: [0.85, 0.9])
    func clicksLandOnTheirStartsTimesTheRate(rate: Double) throws {
        let take = SlowTakeFixture.take()
        let made = SpedUpTake.make(from: take.samples, rate: rate)

        #expect(made.samples.count == Int((Double(take.samples.count) * rate).rounded()))
        #expect(made.samples.count == made.plan.targetLength)
        let found = SyllableDetector.markers(of: take.samples).map(\.sample)
        // The last start is the held tone, which has no click on it.
        for start in take.starts.dropLast() {
            // The detector puts a start where the vowel arrives: measured 0.5 to 7.5 ms after the click here.
            let vowel = try #require(detected(start, among: found))
            #expect(made.plan.target(ofSource: vowel) == Int((Double(vowel) * rate).rounded()))
            // The click lies in the stretch that keeps its length, so it goes where its start goes. Measured:
            // on the sample the plan gives for 19 of 20, 2 samples off for one.
            let planned = made.plan.target(ofSource: start)
            let peak = StretchFixtures.peak(in: made.samples, near: planned, search: 480)
            #expect(abs(peak - planned) <= 4)
            #expect(abs(made.samples[peak] - 0.8) < 0.05)
            // And so it is within the stretch tolerance of its own sample times the rate: measured 1.1 ms at most.
            #expect(abs(Double(peak) - Double(start) * rate) <= tolerance)
        }
    }

    @Test("The stretch around a syllable start is the sound that was recorded", arguments: [0.85, 0.9])
    func keptStretchIsTheRecordedSound(rate: Double) throws {
        let take = SlowTakeFixture.take()
        let made = SpedUpTake.make(from: take.samples, rate: rate)
        let found = SyllableDetector.markers(of: take.samples).map(\.sample)
        func ms(_ milliseconds: Int) -> Int { milliseconds * 48 }

        for start in take.starts.dropLast() {
            let vowel = try #require(detected(start, among: found))
            let target = made.plan.target(ofSource: vowel)
            // How far the sped-up sound is from the take around the start, at the best of a few samples' shift:
            // the library lets an error of a sample or two stand where it comes out of a squeeze.
            func difference(_ window: Range<Int>) -> (largest: Float, likeness: Double) {
                var best: (largest: Float, likeness: Double) = (.infinity, 0)
                for shift in -2...2 {
                    let slow = take.samples[(vowel + window.lowerBound)..<(vowel + window.upperBound)]
                    let fast = made.samples[(target + window.lowerBound + shift)..<(target + window.upperBound + shift)]
                    let largest = zip(slow, fast).map { abs($0 - $1) }.max() ?? 0
                    if largest < best.largest { best = (largest, StretchFixtures.correlation(slow, fast)) }
                }
                return best
            }
            // The attack itself, from 5 ms before the vowel arrives to 20 ms after it, is the samples that went
            // in. Measured: 0.022 of full scale off at most, where the click is 0.8, likeness 0.9997 or more.
            let attack = difference(ms(-5)..<ms(20))
            #expect(attack.largest < 0.03)
            #expect(attack.likeness > 0.999)
            // Nearly all of the kept stretch is the same sound. Towards its two ends the library goes over to
            // the squeezed sound. Measured: likeness 0.998 or more, 0.06 off at most.
            let kept = difference(ms(-10)..<ms(40))
            #expect(kept.largest < 0.08)
            #expect(kept.likeness > 0.995)
        }
    }

    @Test("A held tone keeps its pitch and gives up its share of the time", arguments: [0.85, 0.9])
    func heldToneKeepsItsPitch(rate: Double) {
        let take = SlowTakeFixture.take()
        let made = SpedUpTake.make(from: take.samples, rate: rate)

        // Away from its two ends. Measured 439.9999 Hz at both speeds.
        let middle = made.plan.target(ofSource: take.tone.lowerBound + 4_800)
            ..< made.plan.target(ofSource: take.tone.upperBound - 4_800)
        let pitch = StretchFixtures.frequency(of: made.samples[middle])
        #expect(abs(pitch / SlowTakeFixture.toneHz - 1) < 0.01)
        // The tone is 1.2 s with a tenth of a second of pause after it, so most of the time comes out of the tone.
        let length = made.plan.target(ofSource: take.tone.upperBound) - made.plan.target(ofSource: take.tone.lowerBound)
        #expect(Double(length) / Double(take.tone.count) < (1 + rate) / 2)
        // As loud as it was: measured 1.02 of the slow take, which has more pause in it.
        #expect(abs(StretchFixtures.loudness(made.samples) / StretchFixtures.loudness(take.samples) - 1) < 0.05)
    }

    @Test("The same take gives the same samples, each one a value a 24-bit file holds")
    func sameTakeGivesTheSameSamples() {
        let take = SlowTakeFixture.take()
        let first = SpedUpTake.make(from: take.samples, rate: 0.85)
        let second = SpedUpTake.make(from: take.samples, rate: 0.85)
        #expect(first.samples == second.samples)
        #expect(first.plan == second.plan)
        #expect(WavWriter.asStored(first.samples) == first.samples)
    }

    @Test("A take of 31 seconds is sped up in a moment")
    func longTake() {
        let take = SlowTakeFixture.take(rounds: 10)
        let began = Date()
        let made = SpedUpTake.make(from: take.samples, rate: 0.85)
        let taken = Date().timeIntervalSince(began)
        // Measured 1.2 s on Max's Mac on 15 November 2026.
        print("A slow take of \(Double(take.samples.count) / 48_000) s was sped up in \(taken) s")
        #expect(made.samples.count == made.plan.targetLength)
        #expect(taken < 20)
        // The clicks of the last round land as well as those of the first.
        for start in take.starts.dropLast().suffix(10) {
            let planned = made.plan.target(ofSource: start)
            #expect(abs(StretchFixtures.peak(in: made.samples, near: planned, search: 480) - planned) <= 4)
        }
    }

    @Test("At the song's own speed the take comes back as it is, and a take of nothing gives nothing")
    func fullSpeedAndNothing() {
        let take = SlowTakeFixture.take()
        let made = SpedUpTake.make(from: take.samples, rate: 1)
        #expect(made.samples == WavWriter.asStored(take.samples))
        #expect(made.plan.points.isEmpty)
        #expect(SpedUpTake.make(from: [], rate: 0.85).samples.isEmpty)
    }

    @Test("An s, which lies above the voice's band, counts as sound and not as a pause")
    func hissCountsAsSound() {
        var noise = StretchFixtures.Random(state: 7)
        var samples = (0..<96_000).map { _ in Float((noise.next() * 2 - 1) * 0.001) }
        // 100 ms of a faint tone at 10 kHz from 0.5 s, and a voiced syllable from 1 s.
        let hiss = 24_000..<28_800
        for index in hiss { samples[index] += Float(0.03 * sin(2 * Double.pi * 10_000 * Double(index) / 48_000)) }
        let voice = StretchFixtures.syllable(period: 400, count: 14_400)
        for (index, value) in voice.enumerated() { samples[48_000 + index] += value }

        let envelope = VoiceEnvelope.envelope(of: samples)
        // The voice's own curve does not hear it.
        #expect(!envelope.voicedStretches().contains { $0.overlaps(hiss) })
        let sound = SpedUpTake.sound(in: samples, envelope: envelope)
        let heard = sound.filter { $0.overlaps(hiss) }
        #expect(heard.count == 1)
        #expect(abs((heard.first?.lowerBound ?? 0) - hiss.lowerBound) <= 480)
        #expect(abs((heard.first?.upperBound ?? 0) - hiss.upperBound) <= 480)
        #expect(sound.contains { $0.overlaps(48_000..<62_400) })
        // The room between the two is still a pause.
        #expect(!sound.contains { $0.contains(38_400) })
    }
}

@Suite("The sped-up sound kept in the project's cache")
struct SpedUpTakeCacheTests {
    /// A project folder in a temporary place with a slow take in it: the take's samples, its recording as the
    /// project has it, and the folder to remove when the test is done.
    private func makeProject() throws -> (package: ProjectPackage, folder: URL, recording: Recording, slow: [Float]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockstep-sped-up-tests-\(UUID().uuidString)", isDirectory: true)
        let package = ProjectPackage(url: folder.appendingPathComponent("Song.lockstep", isDirectory: true))
        try FileManager.default.createDirectory(at: package.takesFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.cacheFolder, withIntermediateDirectories: true)
        let slow = WavWriter.asStored(SlowTakeFixture.take().samples)
        let slowRecording = Recording(lengthSamples: slow.count, rawStart: 10)
        try WavWriter.write(slow, channels: 1, to: package.url.appendingPathComponent(slowRecording.file))
        let plan = SpedUpTake.plan(for: slow, rate: 0.85)
        return (package, folder, plan.atFullTempo(slowRecording, clip: nil).recording, slow)
    }

    @Test("The cache gives back what was written, and nothing when it is missing or of another length")
    func cacheGivesBackWhatWasWritten() throws {
        let (package, folder, recording, slow) = try makeProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(SpedUpTake.read(for: recording, from: package) == nil)

        let made = SpedUpTake.make(from: slow, rate: 0.85).samples
        try SpedUpTake.write(made, forRecording: recording.id, to: package)

        #expect(package.spedUpFile(forRecording: recording.id).path.hasSuffix("cache/sped-up/\(recording.id.uuidString).wav"))
        #expect(SpedUpTake.read(for: recording, from: package) == made)
        var other = recording
        other.lengthSamples += 1
        #expect(SpedUpTake.read(for: other, from: package) == nil)
    }

    @Test("The sound of a slow take is the sped-up sound, made again to the same samples when the cache is gone")
    func soundOfASlowTake() throws {
        let (package, folder, recording, slow) = try makeProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = package.url.appendingPathComponent(recording.file)
        let original = try Data(contentsOf: file)
        let made = SpedUpTake.make(from: slow, rate: 0.85).samples
        #expect(recording.recordedSpeed == 0.85)
        #expect(recording.lengthSamples == made.count)

        // Nothing is kept yet: it is made from the file, and kept.
        #expect(try SpedUpTake.sound(of: recording, in: package) == made)
        #expect(SpedUpTake.read(for: recording, from: package) == made)
        // From the cache it is the same samples.
        #expect(try SpedUpTake.sound(of: recording, in: package) == made)
        // With the cache thrown away it is made again, to the same samples.
        try FileManager.default.removeItem(at: package.spedUpFolder)
        #expect(try SpedUpTake.sound(of: recording, in: package) == made)
        #expect(FileManager.default.fileExists(atPath: package.spedUpFile(forRecording: recording.id).path))
        // The file of the take is the slow original, byte for byte.
        #expect(try Data(contentsOf: file) == original)
        #expect(try RecordingLoader.read(file) == slow)
    }

    @Test("The sound of a take recorded as usual is its file, and a slow take without its file cannot be read")
    func soundOfOtherTakes() throws {
        let (package, folder, recording, slow) = try makeProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        var usual = recording
        usual.recordedSpeed = nil
        #expect(try SpedUpTake.sound(of: usual, in: package) == slow)
        #expect(!FileManager.default.fileExists(atPath: package.spedUpFolder.path))

        let lost = Recording(lengthSamples: 100, recordedSpeed: 0.85)
        #expect(throws: RecordingLoadError.unreadableFile) { try SpedUpTake.sound(of: lost, in: package) }
    }

    @Test("When a project opens, a slow take is read as its sped-up sound")
    func readAllGivesTheSpedUpSound() async throws {
        let (package, folder, recording, slow) = try makeProject()
        defer { try? FileManager.default.removeItem(at: folder) }
        let usual = Recording(lengthSamples: 1_000)
        let sound = (0..<1_000).map { Float($0 + 1) / 131_072 }
        try WavWriter.write(sound, channels: 1, to: package.url.appendingPathComponent(usual.file))

        let sounds = await RecordingLoader.readAll(of: Project(recordings: [recording, usual]), in: package)

        #expect(sounds[usual.id] == sound)
        #expect(sounds[recording.id] == SpedUpTake.make(from: slow, rate: 0.85).samples)
        #expect(sounds[recording.id]?.count == recording.lengthSamples)
    }
}

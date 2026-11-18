import Foundation
import Testing
import LockstepCore
@testable import LockstepAudio

@Suite struct VoiceEnvelopeTests {
    /// Room noise at a low level (about -55 dB) with tone bursts at about -15 dB on top.
    /// The same every time it is made.
    private func recording(
        seconds: Double, bursts: [ClosedRange<Double>], frequency: Double = 1000, gain: Float = 1
    ) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<Int(seconds * 48_000)).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = (Float(state >> 40) / Float(1 << 24) * 2 - 1) * 0.003
            let time = Double(index) / 48_000
            let tone = bursts.contains { $0.contains(time) } ? Float(0.25 * sin(2 * Double.pi * frequency * time)) : 0
            return (noise + tone) * gain
        }
    }

    private func seconds(_ sample: Int) -> Double { Double(sample) / 48_000 }

    @Test func burstIsFoundWithItsMargins() throws {
        let envelope = VoiceEnvelope.envelope(of: recording(seconds: 6, bursts: [2.0...3.5]))

        #expect(envelope.lengthSamples == 288_000)
        #expect(envelope.values.count == 6000)
        let range = try #require(envelope.voicedRange())
        #expect(abs(seconds(range.lowerBound) - 1.95) < 0.01)
        #expect(abs(seconds(range.upperBound) - 3.65) < 0.01)
    }

    @Test func burstBeforeTheRecordOriginIsKeptFromItsStart() throws {
        // A one-bar run-up of 2 s: the line starts with a pickup at 1.7 s, before the bar.
        let pickup = VoiceEnvelope.envelope(of: recording(seconds: 5, bursts: [1.7...3.0]))
        let range = try #require(pickup.voicedRange())
        #expect(abs(seconds(range.lowerBound) - 1.65) < 0.01)
        #expect(abs(seconds(range.upperBound) - 3.15) < 0.01)

        // Sound from the first sample to the last: the range stays inside the recording.
        let whole = VoiceEnvelope.envelope(of: recording(seconds: 3, bursts: [0.0...0.4, 2.9...3.0]))
        #expect(whole.voicedRange() == 0..<144_000)
    }

    @Test func noiseOnlyGivesNil() {
        let envelope = VoiceEnvelope.envelope(of: recording(seconds: 6, bursts: []))
        #expect(envelope.voicedRange() == nil)
        #expect(VoiceEnvelope.envelope(of: [Float](repeating: 0, count: 48_000)).voicedRange() == nil)
        #expect(VoiceEnvelope.envelope(of: []).voicedRange() == nil)
    }

    @Test func quieterRecordingGivesTheSameRange() throws {
        let loud = try #require(VoiceEnvelope.envelope(of: recording(seconds: 6, bursts: [2.0...3.5])).voicedRange())
        let quiet = VoiceEnvelope.envelope(of: recording(seconds: 6, bursts: [2.0...3.5], gain: 0.25))
        let range = try #require(quiet.voicedRange())
        #expect(abs(range.lowerBound - loud.lowerBound) <= 96)
        #expect(abs(range.upperBound - loud.upperBound) <= 96)
    }

    @Test func soundOutsideTheVoiceBandAndShortTicksAreNotVoice() {
        // A deep thump from the song in the headphones, and a tick 10 ms long.
        let thump = VoiceEnvelope.envelope(of: recording(seconds: 4, bursts: [1.0...1.5], frequency: 50))
        #expect(thump.voicedRange() == nil)
        let tick = VoiceEnvelope.envelope(of: recording(seconds: 4, bursts: [1.0...1.01]))
        #expect(tick.voicedRange() == nil)
    }

    @Test func noiseFloorIsTheLevelOfTheNoise() {
        let envelope = VoiceEnvelope.envelope(of: recording(seconds: 6, bursts: [2.0...3.5]))
        // The burst, at a quarter of full scale, reads -15 dB. The noise lies far below it.
        #expect(abs(envelope.values[2750] - -15.05) < 0.2)
        #expect(envelope.noiseFloor < -50)
        #expect(envelope.noiseFloor > -75)
    }

    // MARK: The stretches one by one

    @Test func stretchesAreFoundOneByOne() throws {
        let envelope = VoiceEnvelope.envelope(of: recording(seconds: 6, bursts: [1.0...1.3, 2.0...3.5]))
        let stretches = envelope.voicedStretches()
        try #require(stretches.count == 2)
        // Exactly where the sound is, with nothing added before or after.
        #expect(abs(seconds(stretches[0].lowerBound) - 1.0) < 0.01)
        #expect(abs(seconds(stretches[0].upperBound) - 1.3) < 0.01)
        #expect(abs(seconds(stretches[1].lowerBound) - 2.0) < 0.01)
        #expect(abs(seconds(stretches[1].upperBound) - 3.5) < 0.01)
        // The outer range is the first and the last of them with the margins.
        #expect(envelope.voicedRange() == stretches[0].lowerBound - 2_400..<stretches[1].upperBound + 7_200)
        #expect(VoiceEnvelope.envelope(of: recording(seconds: 6, bursts: [])).voicedStretches().isEmpty)
    }

    /// A take as the microphone hears it with a count-in: room noise all through, the song leaking from the
    /// headphones from `songFrom` seconds on (a steady tone at about -40 dB), and tone bursts at -12 dB for
    /// the voice.
    private func take(seconds: Double, songFrom: Double, voice: [ClosedRange<Double>]) -> [Float] {
        let room = recording(seconds: seconds, bursts: [])
        return room.indices.map { index in
            let time = Double(index) / 48_000
            let song = time >= songFrom ? 0.014 * sin(2 * Double.pi * 700 * time) : 0
            let word = voice.contains { $0.contains(time) } ? 0.25 * sin(2 * Double.pi * 1000 * time) : 0
            return room[index] + Float(song + word)
        }
    }

    @Test func noiseFloorCanBeMeasuredFromWhereTheSongIsAtFullLevel() throws {
        // Three quiet seconds of count-in, then the song leaks in for five. The voice is at 5 to 6 s.
        let envelope = VoiceEnvelope.envelope(of: take(seconds: 8, songFrom: 3, voice: [5.0...6.0]))

        // Measured over the whole take, the quiet count-in is the noise floor and all of the song is "sound".
        let whole = envelope.voicedStretches()
        try #require(whole.count == 1)
        #expect(abs(seconds(whole[0].lowerBound) - 3.0) < 0.01)
        #expect(whole[0].upperBound == 384_000)

        // Measured from where the song plays, the song is the floor and only the voice stands above it.
        let fromSong = envelope.voicedStretches(noiseFloorFrom: 144_000)
        try #require(fromSong.count == 1)
        #expect(abs(seconds(fromSong[0].lowerBound) - 5.0) < 0.01)
        #expect(abs(seconds(fromSong[0].upperBound) - 6.0) < 0.01)

        // With less than a second left after that sample, the whole take is measured.
        #expect(envelope.voicedStretches(noiseFloorFrom: 350_000) == whole)
    }

    // MARK: The count-in's click in the microphone

    /// A take with a count-in of one bar before the place at 10 s, with a click every 0.45 s. The microphone
    /// opened 0.1 s before the count-in, so the place is 1.9 s into the take, at sample 91,200. Every click of
    /// the count-in leaks into the microphone (the cowbell, the longest click, at half its level), and the
    /// verse starts 10 ms after the place.
    private func takeWithLeakingClicks(word: ClosedRange<Double>?) -> (recording: Recording, samples: [Float], leak: ClickLeak) {
        let clickTimes = [8.2, 8.65, 9.1, 9.55, 10.0]
        let takeStart = 8.1
        let voice = [word, 1.91...3.9].compactMap { $0 }
        var samples = recording(seconds: 5, bursts: voice)
        let click = ClickSound.cowbell.samples(accent: false)
        for time in clickTimes {
            let first = Int(((time - takeStart) * 48_000).rounded())
            for (offset, value) in click.enumerated() { samples[first + offset] += value * 0.5 }
        }
        return (
            Recording(lengthSamples: samples.count, rawStart: takeStart),
            samples,
            ClickLeak(times: clickTimes, soundSeconds: Double(click.count) / 48_000)
        )
    }

    @Test func leakingClicksLeaveTheClipStartingAtThePlace() throws {
        let take = takeWithLeakingClicks(word: nil)
        let stretches = VoiceEnvelope.envelope(of: take.samples).voicedStretches()
        // Each click of the count-in is heard as a short sound of its own, long enough to pass for a word.
        try #require(stretches.count == 5)
        #expect(stretches[..<4].allSatisfy { $0.count >= 2_880 })

        let clip = try #require(RecordingPlacement.clipSamples(
            of: take.recording, voicedStretches: stretches, origin: 10, grid: nil, clickLeak: take.leak
        ))
        // The clip starts with the verse on the place: 50 ms before the sound there, which the click on the
        // place itself begins.
        #expect(abs(seconds(clip.lowerBound) - 1.85) < 0.01)
        // Without the click times the clicks look like words that lead into the place, back to the first one.
        let fooled = try #require(RecordingPlacement.clipSamples(
            of: take.recording, voicedStretches: stretches, origin: 10, grid: nil
        ))
        #expect(fooled.lowerBound == 7_200)
    }

    @Test func wordBetweenLeakingClicksStartsTheClip() throws {
        // A word from 300 ms to 100 ms before the place, between the last two clicks of the count-in.
        let take = takeWithLeakingClicks(word: 1.6...1.8)
        let stretches = VoiceEnvelope.envelope(of: take.samples).voicedStretches()
        let clip = try #require(RecordingPlacement.clipSamples(
            of: take.recording, voicedStretches: stretches, origin: 10, grid: nil, clickLeak: take.leak
        ))
        // 50 ms before the word.
        #expect(abs(seconds(clip.lowerBound) - 1.55) < 0.01)
    }

    @Test func fileRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceEnvelopeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = ProjectPackage(url: folder.appendingPathComponent("Song.lockstep"))
        let id = UUID()
        let envelope = VoiceEnvelope.envelope(of: recording(seconds: 2.0005, bursts: [0.5...1.0]))

        #expect(VoiceEnvelope.read(forRecording: id, lengthSamples: envelope.lengthSamples, from: package) == nil)
        try envelope.write(forRecording: id, to: package)

        #expect(VoiceEnvelope.file(forRecording: id, in: package).path.hasSuffix("cache/envelope/\(id.uuidString).f32"))
        #expect(VoiceEnvelope.read(forRecording: id, lengthSamples: envelope.lengthSamples, from: package) == envelope)
        // A file that belongs to a recording of another length is not used.
        #expect(VoiceEnvelope.read(forRecording: id, lengthSamples: envelope.lengthSamples + 4800, from: package) == nil)
    }
}

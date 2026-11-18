import Foundation
import Testing
@testable import LockstepCore

/// The clicks of a count-in as sound: where each one starts, which sound it is, and how loud.
@Suite("ClickRenderer, count-in")
struct CountInClickTests {
    /// One bar of count-in to 2 s in a song without beats: clicks at 0, 0.5, 1 and 1.5 s, and the place at 2 s.
    private let countIn = RecordingPlacement.countIn(to: 2, bars: 1, grid: nil)

    private func loudest(_ samples: some Sequence<Float>) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    /// True when `sound`, multiplied by `gain`, lies in `row` from `sample` on.
    private func holds(_ row: [Float], _ sound: [Float], at sample: Int, gain: Float = 1) -> Bool {
        sound.indices.allSatisfy { abs(row[sample + $0] - sound[$0] * gain) < 1e-6 }
    }

    // MARK: The click to start on

    @Test("The click to start on is on the beat, higher than every click sound, and the same every time")
    func startClickKeepsToTheRules() {
        let samples = ClickSound.startSamples(peak: 0.8)
        #expect(samples.count == ClickSound.startLengthSamples)
        #expect(loudest(samples) == 0.8)
        // It is sound from its first sample, rising from next to nothing, and ends next to nothing.
        #expect(samples[0] != 0)
        #expect(abs(samples[0]) < 0.8 * 0.05)
        #expect(abs(samples[samples.count - 1]) < 0.8 * 0.01)
        // The loudest point comes within the first 3 ms (144 samples).
        #expect(loudest(samples[..<144]) >= 0.8 * 0.999)
        #expect(ClickSound.startSamples(peak: 0.8) == samples)

        // 3200 Hz: it crosses zero about 64 times in 10 ms, more often than any of the five sounds' accents.
        func crossings(_ sound: [Float]) -> Int {
            (1..<480).filter { (sound[$0 - 1] < 0) != (sound[$0] < 0) }.count
        }
        #expect((60...68).contains(crossings(samples)))
        for sound in ClickSound.allCases where sound != .hiHat {
            #expect(crossings(sound.samples(accent: true)) < crossings(samples))
        }
        // It is none of the sounds the song's click is made of.
        for sound in ClickSound.allCases {
            #expect(sound.samples(accent: true) != ClickSound.startSamples(peak: ClickSound.accentPeak))
        }
    }

    @Test("The click to start on is 6 dB louder than the first beat of a bar, and never above 1 dB below full scale")
    func startClickLevel() {
        // At half volume the first beat of a bar peaks at 0.4207, and there is room for 6 dB more.
        let half = ClickRenderer.startClickPeak(volume: 0.5, accentBeatOne: true)
        #expect(abs(20 * log10(Double(half / (ClickSound.accentPeak * 0.5))) - 6) < 0.01)
        // At the volume a new song starts with, and at full volume, the limit decides.
        #expect(ClickRenderer.startClickPeak(volume: 0.7, accentBeatOne: true) == ClickRenderer.peakLimit)
        #expect(ClickRenderer.startClickPeak(volume: 1, accentBeatOne: true) == ClickRenderer.peakLimit)
        #expect(ClickRenderer.startClickPeak(volume: 3, accentBeatOne: true) == ClickRenderer.peakLimit)
        // Without the accent the first beat of a bar is the plain click, and 6 dB above that is lower.
        let plain = ClickRenderer.startClickPeak(volume: 0.7, accentBeatOne: false)
        #expect(abs(20 * log10(Double(plain / (ClickSound.peak * 0.7))) - 6) < 0.01)
        #expect(ClickRenderer.startClickPeak(volume: 0, accentBeatOne: true) == 0)
    }

    // MARK: The row of clicks

    @Test("Every click of the count-in starts on its sample, and the place gets the click to start on", arguments: ClickSound.allCases)
    func clicksAreOnTheirSamples(sound: ClickSound) {
        let settings = ClickSettings(sound: sound, division: .beats)
        let row = ClickRenderer.renderCountIn(countIn, settings: settings, volume: 0.5)
        let plain = sound.samples(accent: false)
        let accent = sound.samples(accent: true)
        let start = ClickSound.startSamples(peak: ClickRenderer.startClickPeak(volume: 0.5, accentBeatOne: true))

        // It goes on past the place until the last click has rung out.
        #expect(row.count == 96_000 + max(accent.count, start.count))
        // The first beat of the bar is the accent, the others the plain sound, all at the click's volume.
        #expect(holds(row, accent, at: 0, gain: 0.5))
        for beat in [24_000, 48_000, 72_000] {
            #expect(holds(row, plain, at: beat, gain: 0.5))
            #expect(row[beat - 1] == 0)
        }
        // The click to start on is on the place, on the exact sample, and the loudest of them all.
        #expect(row[95_999] == 0)
        #expect(holds(row, start, at: 96_000))
        #expect(loudest(row[96_000...]) == loudest(row))
        #expect(abs(20 * log10(Double(loudest(row[96_000...]) / loudest(row[..<24_000]))) - 6) < 0.01)
        // Nothing sounds between the clicks.
        #expect(row[(72_000 + plain.count)..<96_000].allSatisfy { $0 == 0 })
        #expect(row[(96_000 + start.count)...].allSatisfy { $0 == 0 })
    }

    @Test("A count-in before the song is counted from its own first sample")
    func clicksBeforeTheSong() {
        // One bar to the second beat of a song whose beats are 0.5 s apart from 0.25 s on.
        let grid = Grid(beats: (0..<40).map { Beat(number: $0, time: 0.25 + Double($0) * 0.5) })
        let early = RecordingPlacement.countIn(to: 0.75, bars: 1, grid: grid)
        let row = ClickRenderer.renderCountIn(early, settings: ClickSettings(sound: .woodblock), volume: 1)
        let plain = ClickSound.woodblock.samples(accent: false)
        // Three clicks before the song, at 1.25, 0.75 and 0.25 s before it, then the song's first beat.
        for beat in [0, 24_000, 48_000] {
            #expect(holds(row, plain, at: beat))
        }
        #expect(holds(row, ClickSound.woodblock.samples(accent: true), at: 72_000))
        #expect(row[96_000] != 0)
        #expect(row[95_999] == 0)
        #expect(early.leadInSamples == 60_000)
    }

    @Test("A click that sounds more often than every beat does so in the count-in too")
    func clicksBetweenTheBeats() {
        let settings = ClickSettings(sound: .woodblock, division: .subBeats)
        let row = ClickRenderer.renderCountIn(countIn, settings: settings, volume: 1, accentBeatOne: false)
        let plain = ClickSound.woodblock.samples(accent: false)
        for beat in [0, 24_000, 48_000, 72_000] {
            #expect(holds(row, plain, at: beat))
            for part in 1...3 {
                #expect(holds(row, plain, at: beat + part * 6_000, gain: ClickRenderer.betweenBeatsGain))
            }
        }
        // Nothing follows the click to start on.
        #expect(row[(96_000 + ClickSound.startLengthSamples)...].allSatisfy { $0 == 0 })
    }

    @Test("The row never goes above 1 dB below full scale", arguments: ClickSound.allCases, [0.2, 0.7, 1.0] as [Float])
    func rowStaysUnderTheLimit(sound: ClickSound, volume: Float) {
        // A fast count-in, so that the tails of the longer sounds lie over the next click.
        let grid = Grid(beats: (0..<80).map { Beat(number: $0, time: Double($0) * 0.3) })
        let fast = RecordingPlacement.countIn(to: 6, bars: 2, grid: grid)
        let row = ClickRenderer.renderCountIn(fast, settings: ClickSettings(sound: sound, division: .subBeats), volume: volume)
        #expect(loudest(row) <= ClickRenderer.peakLimit + 1e-6)
        #expect(loudest(row) > 0)
    }

    @Test("Off and a volume of zero give no sound")
    func noClicks() {
        let off = RecordingPlacement.countIn(to: 2, bars: 0, grid: nil)
        #expect(ClickRenderer.renderCountIn(off, settings: ClickSettings(), volume: 1).isEmpty)
        #expect(ClickRenderer.renderCountIn(countIn, settings: ClickSettings(), volume: 0).allSatisfy { $0 == 0 })
        #expect(ClickRenderer.leak(of: off, settings: ClickSettings()) == .none)
    }

    // MARK: What leaks into the microphone

    @Test("The leak lists every click of the count-in and the length of the longest one")
    func leakListsEveryClick() {
        let beats = ClickRenderer.leak(of: countIn, settings: ClickSettings(sound: .woodblock, division: .beats))
        #expect(beats.times == [0, 0.5, 1, 1.5, 2])
        // The woodblock lasts 40 ms and the click to start on 60 ms.
        #expect(beats.soundSeconds == 0.06)

        let halves = ClickRenderer.leak(of: countIn, settings: ClickSettings(sound: .cowbell, division: .halfBeats))
        #expect(halves.times == [0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
        #expect(halves.soundSeconds == 0.15)
    }
}

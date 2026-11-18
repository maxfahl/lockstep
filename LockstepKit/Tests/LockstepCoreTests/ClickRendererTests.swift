import Foundation
import Testing
@testable import LockstepCore

@Suite("ClickRenderer")
struct ClickRendererTests {
    /// Four beats at times that do not fall on round sample numbers. The beat
    /// numbered 1 starts a bar, so it is the only bar start among the four.
    static let times = [0.5, 1.000_013, 1.500_31, 2.000_004]
    static let grid = Grid(
        beats: times.enumerated().map { Beat(number: $0.offset, time: $0.element) },
        barStartNumber: 1
    )
    /// Three seconds of song.
    static let length = 144_000

    static func sample(_ seconds: Double) -> Int {
        Int((seconds * 48_000).rounded())
    }

    static func render(
        _ grid: Grid? = grid,
        sound: ClickSound = .woodblock,
        division: ClickDivision = .beats,
        length: Int = length,
        accentBeatOne: Bool = true
    ) -> [Float] {
        ClickRenderer.render(
            grid: grid,
            settings: ClickSettings(sound: sound, division: division),
            lengthSamples: length,
            accentBeatOne: accentBeatOne
        )
    }

    /// Where the clicks of a rendered song start: every sample that is sound
    /// and has at least 5 ms of silence right before it.
    static func clickStarts(in click: [Float]) -> [Int] {
        var starts: [Int] = []
        var silentRun = 240
        for (index, value) in click.enumerated() {
            if value == 0 {
                silentRun += 1
            } else {
                if silentRun >= 240 { starts.append(index) }
                silentRun = 0
            }
        }
        return starts
    }

    static func loudest(_ samples: some Sequence<Float>) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    // MARK: - Where the clicks are

    @Test("The result is as long as the song and silent before the first click", arguments: ClickSound.allCases)
    func silentBeforeTheFirstClick(sound: ClickSound) {
        let click = Self.render(sound: sound)
        #expect(click.count == Self.length)
        #expect(click[..<24_000].allSatisfy { $0 == 0 })
        #expect(click[24_000] != 0)
    }

    @Test("Each click's first sample is on the exact sample of its beat", arguments: ClickSound.allCases)
    func everyClickStartsOnItsBeat(sound: ClickSound) {
        let click = Self.render(sound: sound)
        #expect(Self.clickStarts(in: click) == [24_000, 48_001, 72_015, 96_000])
        #expect(Self.clickStarts(in: click) == Self.times.map(Self.sample))
    }

    @Test("The first beat of a bar is the accent sound and the others the plain one", arguments: ClickSound.allCases)
    func barStartsUseTheAccent(sound: ClickSound) {
        let plain = sound.samples(accent: false)
        let accent = sound.samples(accent: true)
        #expect(plain != accent)

        let click = Self.render(sound: sound)
        for (number, time) in Self.times.enumerated() {
            let start = Self.sample(time)
            let expected = number == 1 ? accent : plain
            #expect(Array(click[start..<start + expected.count]) == expected)
        }

        // With the accent switched off, the bar start is like the others.
        let even = Self.render(sound: sound, accentBeatOne: false)
        #expect(Array(even[48_001..<48_001 + plain.count]) == plain)
    }

    @Test("Bars are counted from the grid's bar start, four beats to the bar")
    func everyFourthBeatIsAccented() {
        let grid = Grid(beats: (0..<10).map { Beat(number: $0, time: 0.25 + Double($0) * 0.25) }, barStartNumber: 2)
        let click = Self.render(grid, sound: .beep)
        let accent = ClickSound.beep.samples(accent: true)
        let accented = grid.beats.filter { beat in
            let start = Self.sample(beat.time)
            return Array(click[start..<start + accent.count]) == accent
        }
        #expect(accented.map(\.number) == [2, 6])
    }

    // MARK: - How often it clicks

    @Test("Half-beats add one quieter click halfway to the next beat")
    func halfBeats() {
        let click = Self.render(division: .halfBeats)
        let starts = Self.clickStarts(in: click)
        // Four beats and the three places between them. Nothing after the last beat.
        #expect(starts.count == 7)
        #expect(starts == Self.grid.subBeats(perBeat: 2, in: 0...3).map(Self.sample))

        let quieter = ClickSound.woodblock.samples(accent: false).map { $0 * ClickRenderer.betweenBeatsGain }
        let halfway = Self.sample((Self.times[0] + Self.times[1]) / 2)
        #expect(Array(click[halfway..<halfway + quieter.count]) == quieter)
        // 6 dB quieter than the beat's own click.
        #expect(abs(Self.loudest(quieter) / ClickSound.peak - 0.5012) < 0.0001)
    }

    @Test("Sub-beats give four evenly spaced clicks per beat, the three between beats quieter")
    func subBeats() {
        let click = Self.render(division: .subBeats)
        let starts = Self.clickStarts(in: click)
        #expect(starts.count == 13)
        #expect(starts == Self.grid.subBeats(perBeat: 4, in: 0...3).map(Self.sample))

        let plain = ClickSound.woodblock.samples(accent: false)
        let quieter = plain.map { $0 * ClickRenderer.betweenBeatsGain }
        let step = (Self.times[3] - Self.times[2]) / 4
        for part in 0..<4 {
            let start = Self.sample(Self.times[2] + step * Double(part))
            #expect(Array(click[start..<start + plain.count]) == (part == 0 ? plain : quieter))
        }
    }

    // MARK: - Where there are no beats

    @Test("A stretch without beats stays silent, at every setting", arguments: ClickDivision.allCases)
    func anUnfilledGapStaysSilent(division: ClickDivision) {
        // Beats 0 to 2, an empty stretch, then beats 10 and 11.
        let numbers = [0, 1, 2, 10, 11]
        let grid = Grid(beats: numbers.map { Beat(number: $0, time: 0.25 + Double($0) * 0.2) })
        let click = Self.render(grid, division: division)
        let soundLength = ClickSound.woodblock.samples(accent: false).count

        // Beat 2 clicks, and then nothing until beat 10.
        let lastBefore = Self.sample(0.25 + 2 * 0.2)
        let firstAfter = Self.sample(0.25 + 10 * 0.2)
        #expect(click[lastBefore] != 0)
        #expect(click[(lastBefore + soundLength)..<firstAfter].allSatisfy { $0 == 0 })
        #expect(click[firstAfter] != 0)

        // Nothing before the first beat and nothing after the last beat's own click.
        #expect(click[..<Self.sample(0.25)].allSatisfy { $0 == 0 })
        let last = Self.sample(0.25 + 11 * 0.2)
        #expect(click[(last + soundLength)...].allSatisfy { $0 == 0 })

        let between = ClickSettings(division: division).clicksPerBeat - 1
        #expect(Self.clickStarts(in: click).count == 5 + 3 * between)
    }

    @Test("Without beats the click is silence as long as the song")
    func noBeats() {
        #expect(Self.render(nil) == [Float](repeating: 0, count: Self.length))
        #expect(Self.render(Grid()) == [Float](repeating: 0, count: Self.length))
        #expect(Self.render(length: 0).isEmpty)
    }

    @Test("A click at the end of the song is cut where the song ends, and one outside it is left out")
    func clicksAtTheEdges() {
        let grid = Grid(beats: [-0.1, 0, 0.5, 0.999, 1, 1.4].enumerated().map { Beat(number: $0.offset, time: $0.element) })
        let click = Self.render(grid, sound: .beep, length: 48_000, accentBeatOne: false)
        #expect(click.count == 48_000)
        #expect(Self.clickStarts(in: click) == [0, 24_000, 47_952])
        let plain = ClickSound.beep.samples(accent: false)
        #expect(Array(click[47_952...]) == Array(plain[..<48]))
    }

    // MARK: - Loudness

    @Test("Clicks that do not overlap are not turned down", arguments: ClickSound.allCases)
    func aloneTheClicksKeepTheirLevel(sound: ClickSound) {
        let click = Self.render(sound: sound)
        #expect(Self.loudest(click) == ClickSound.accentPeak)
        #expect(Self.loudest(click) <= ClickRenderer.peakLimit)
    }

    @Test("Where tails add up, the whole click is turned down to 1 dB below full scale", arguments: ClickSound.allCases)
    func overlappingTailsStayUnderTheLimit(sound: ClickSound) {
        // Twenty beats one period of 1000 Hz apart: every sound piles up on itself.
        let grid = Grid(beats: (0..<20).map { Beat(number: $0, time: 0.1 + Double($0) * 0.001) })
        let piled = Self.render(grid, sound: sound, length: 24_000)
        let loudest = Self.loudest(piled)
        #expect(loudest <= ClickRenderer.peakLimit + 0.000_001)

        if sound == .beep {
            // The beep adds up to far more than full scale, so it was turned
            // down to the limit. The limit is -1 dBFS.
            #expect(abs(loudest - ClickRenderer.peakLimit) < 0.000_01)
            #expect(abs(20 * log10(Double(ClickRenderer.peakLimit)) + 1) < 0.001)
        }
    }

    // MARK: - The sounds the renderer places

    @Test("Every sound is on the beat: it starts at once and is loudest within 3 ms", arguments: ClickSound.allCases, [false, true])
    func soundsKeepToTheirRules(sound: ClickSound, accent: Bool) {
        let samples = sound.samples(accent: accent)
        let loudest = Self.loudest(samples)

        // 30 to 150 ms long.
        #expect((1_440...7_200).contains(samples.count))
        // The same level for every sound, the accent 3 dB louder and below full scale.
        #expect(loudest == (accent ? ClickSound.accentPeak : ClickSound.peak))
        #expect(abs(20 * log10(Double(ClickSound.accentPeak / ClickSound.peak)) - 3) < 0.01)
        #expect(ClickSound.accentPeak < ClickRenderer.peakLimit)
        // It is sound from its first sample, rising from next to nothing, and ends next to nothing.
        #expect(samples[0] != 0)
        #expect(abs(samples[0]) < loudest * 0.05)
        #expect(abs(samples[samples.count - 1]) < loudest * 0.01)
        // The loudest point comes within the first 3 ms (144 samples).
        #expect(Self.loudest(samples[..<144]) >= loudest * 0.999)
        // The same every time.
        #expect(sound.samples(accent: accent) == samples)
    }

    // MARK: - Saved projects

    @Test("A saved project without click settings, or with only some of them, opens with the defaults")
    func missingFieldsGetTheirDefaults() throws {
        let old = try JSONDecoder().decode(Project.self, from: Data(#"{"songName":"Old"}"#.utf8))
        #expect(old.songName == "Old")
        #expect(old.songFile == "song.wav")
        #expect(old.click == ClickSettings(isOn: false, sound: .woodblock, volume: 0.7, division: .beats))

        let partly = try JSONDecoder().decode(
            ClickSettings.self,
            from: Data(#"{"isOn":true,"sound":"cowbell","volume":7}"#.utf8)
        )
        #expect(partly == ClickSettings(isOn: true, sound: .cowbell, volume: 1, division: .beats))

        var project = Project(songName: "Now")
        project.click = ClickSettings(isOn: true, sound: .hiHat, volume: 0.25, division: .subBeats)
        let again = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(again.click == project.click)
        #expect(again.songName == "Now")
    }
}

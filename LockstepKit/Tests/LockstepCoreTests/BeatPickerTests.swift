import Foundation
import Testing
@testable import LockstepCore

/// Rows of made-up values stand in for the beat model's answer: one value per 20 ms step.
/// A step where the model is sure there is no beat holds -8, as in a real answer.
@Suite("BeatPicker")
struct BeatPickerTests {
    /// 100 beats a minute: a beat every 30 steps.
    static let stepsPerBeat = 30
    static let firstBeatStep = 20

    static func step(ofBeat number: Int) -> Int { firstBeatStep + stepsPerBeat * number }
    static func time(ofBeat number: Int) -> Double { Double(step(ofBeat: number)) / 50 }

    /// A row with one value on every beat of a 150 beat song, as `value` gives it, and -8 elsewhere.
    static func song(beats: Int = 150, _ value: (Int) -> Float) -> [Float] {
        var values = [Float](repeating: -8, count: step(ofBeat: beats) + 20)
        for number in 0..<beats { values[step(ofBeat: number)] = value(number) }
        return values
    }

    /// The beats of the quiet stretch in the songs below: 45 in a row, more than the 32 that are filled in.
    static let quiet = 50..<95

    /// Numbers between -1 and 1 that are the same on every run.
    struct Dice {
        var state: UInt64
        mutating func roll() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 2_000_001) / 1_000_000 - 1
        }
    }

    func pick(_ values: [Float], limit: Float = 0, maxGapBeats: Int = 32) -> BeatPicker.Picked {
        BeatPicker.pick(values: values, framesPerSecond: 50, limit: limit, maxGapBeats: maxGapBeats)
    }

    func holes(in beats: [Beat]) -> Int {
        zip(beats, beats.dropFirst()).filter { $1.number != $0.number + 1 }.count
    }

    // MARK: The steps and the floor

    @Test func theLimitIsLoweredAQuarterAtATimeDownToTheFloor() {
        #expect(BeatPicker.loosenedLimits(below: 0) == [-0.25, -0.5, -0.75, -1, -1.25, -1.5])
        // From a strict limit it goes six steps and no further.
        #expect(BeatPicker.loosenedLimits(below: 1.5) == [1.25, 1, 0.75, 0.5, 0.25, 0])
        // From a loose one it stops at the floor.
        #expect(BeatPicker.loosenedLimits(below: -1) == [-1.25, -1.5])
        #expect(BeatPicker.loosenedLimits(below: BeatPicker.floor).isEmpty)
        // The setting's loose end is that floor, and its strict end is as far the other way.
        #expect(SettingKey<Double>.certaintyLimit.range == -1.5...1.5)
        #expect(SettingKey<Double>.certaintyLimit.defaultValue == 0)
    }

    // MARK: The limit

    @Test func aPeakIsTakenOnlyAboveTheLimit() {
        var values = [Float](repeating: -8, count: 200)
        values[20] = 2
        values[50] = 0.5
        values[80] = -0.5
        values[110] = -0.5
        values[111] = -0.5

        #expect(BeatPicker.peaks(in: values).map(\.position) == [20, 50])
        #expect(BeatPicker.peaks(in: values, above: 1).map(\.position) == [20])
        // Two equal neighbours are one peak between them, at every limit.
        #expect(BeatPicker.peaks(in: values, above: -1) == [
            BeatPicker.Peak(position: 20, strength: 2),
            BeatPicker.Peak(position: 50, strength: 0.5),
            BeatPicker.Peak(position: 80, strength: -0.5),
            BeatPicker.Peak(position: 110.5, strength: -0.5),
        ])
    }

    @Test func aStricterLimitDropsTheBeatsBelowIt() {
        // Every beat is in tempo. The first 40 are sure, the last 20 only a little.
        let values = Self.song(beats: 60) { $0 < 40 ? 5 : 0.6 }

        #expect(pick(values).beats.count == 60)
        // The strict limit ends the song at the last sure beat: nothing is added after it,
        // because a stretch after the last beat is not a hole.
        let strict = pick(values, limit: 1)
        #expect(strict.beats.count == 40)
        #expect(strict.loosened.isEmpty)
        // A looser limit than the starting one takes weaker beats as they are, unmarked.
        let weak = Self.song(beats: 60) { $0 < 40 ? 5 : -0.6 }
        #expect(pick(weak).beats.count == 40)
        let loose = pick(weak, limit: -1)
        #expect(loose.beats.count == 60)
        #expect(loose.loosened.isEmpty)
    }

    // MARK: A quiet stretch

    @Test func aQuietStretchInTempoGetsItsBeatsMarkedAsLoosened() {
        // In the quiet stretch the model is less sure than not, by differing amounts.
        let weak: [Float] = [-0.3, -0.7, -1.2]
        var values = Self.song { Self.quiet.contains($0) ? weak[$0 % 3] : 5 }
        // And between some of those beats its values wobble, out of tempo and weaker still.
        let wobbles = stride(from: Self.quiet.lowerBound, to: Self.quiet.upperBound, by: 4).map { Self.step(ofBeat: $0) + 13 }
        for step in wobbles { values[step] = -1.4 }

        // Picking at the limit alone leaves the stretch empty: 45 beats are too many to fill in.
        let sure = BeatLevel.force(BeatPicker.peaks(in: values).map { $0.position / 50 })
        #expect(sure.count == 105)
        #expect(holes(in: sure) == 1)

        let picked = pick(values)

        #expect(picked.beats.count == 150)
        #expect(picked.beats.map(\.number) == Array(0..<150))
        #expect(picked.loosened == Set(Self.quiet))
        // Every beat is one the model reported, exactly where it reported it.
        #expect(picked.beats.allSatisfy { !$0.estimated })
        #expect(picked.beats.map(\.time) == (0..<150).map(Self.time(ofBeat:)))
    }

    @Test func weakBeatsThatAreOnlyPartlyThereAreTakenAndTheRestFilledIn() {
        // Three of every four quiet beats reach above the floor. The fourth never does.
        let values = Self.song { number in
            guard Self.quiet.contains(number) else { return 5 }
            return number % 4 == 0 ? -3 : -0.4
        }

        let picked = pick(values)

        #expect(picked.beats.count == 150)
        #expect(holes(in: picked.beats) == 0)
        #expect(picked.loosened == Set(Self.quiet.filter { $0 % 4 != 0 }))
        // What the model never reported is filled in between its neighbours, as in any short hole.
        #expect(picked.beats.filter(\.estimated).map(\.number) == Self.quiet.filter { $0 % 4 == 0 })
    }

    @Test func weakPeaksAtAnotherTempoAreNotTaken() {
        var values = Self.song { Self.quiet.contains($0) ? -8 : 5 }
        // A steady row of weak peaks, 19 steps apart where the beats are 30 apart.
        for step in stride(from: Self.step(ofBeat: 49) + 19, to: Self.step(ofBeat: 95) - 10, by: 19) {
            values[step] = -0.3
        }

        let picked = pick(values)

        #expect(picked.loosened.isEmpty)
        #expect(picked.beats.count == 105)
        #expect(holes(in: picked.beats) == 1)
        // The beats after the hole keep the numbers they would have had.
        #expect(picked.beats[50].number == 95)
    }

    @Test func wobblesWithNoTempoInAHoleAreNotTaken() {
        for seed in 1...8 {
            var dice = Dice(state: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15)
            var values = Self.song { Self.quiet.contains($0) ? -8 : 5 }
            // As where the model does not know: a small peak every 5 to 13 steps.
            var step = Self.step(ofBeat: 49) + 8
            while step < Self.step(ofBeat: 95) - 8 {
                values[step] = Float(-0.3 + 0.25 * dice.roll())
                step += 9 + Int((dice.roll() * 4).rounded())
            }

            let picked = pick(values)

            #expect(picked.loosened.isEmpty, "seed \(seed)")
            #expect(picked.beats.count == 105, "seed \(seed)")
        }
    }

    @Test func aHoleShortEnoughToFillIsFilledAsBeforeAndNothingIsLoosened() {
        // Ten weak beats in a row: the hole is filled with estimated beats, so there is no
        // stretch without beats to try again in.
        let values = Self.song { (50..<60).contains($0) ? -0.4 : 5 }

        let picked = pick(values)

        #expect(picked.loosened.isEmpty)
        #expect(picked.beats == BeatLevel.force((0..<150).filter { !(50..<60).contains($0) }.map(Self.time(ofBeat:))))
        #expect(picked.beats.filter(\.estimated).count == 10)
    }

    // MARK: A song with no sure beats

    @Test func aSteadyWeakPulseWithNothingAboveZeroGetsBeats() {
        var values = Self.song(beats: 100) { _ in -0.4 }
        // Weaker peaks between the beats, here and there.
        for number in stride(from: 3, to: 100, by: 5) { values[Self.step(ofBeat: number) + 11] = -1.1 }
        #expect(values.allSatisfy { $0 < 0 })
        #expect(BeatPicker.peaks(in: values).isEmpty)

        let picked = pick(values)

        #expect(picked.beats.map(\.time) == (0..<100).map(Self.time(ofBeat:)))
        #expect(picked.loosened == Set(0..<100))
        #expect(picked.beats.allSatisfy { !$0.estimated })
    }

    @Test func aWeakPulseWhoseTempoDriftsIsFollowed() {
        // From 100 to 91 beats a minute over the song, on the model's 20 ms steps.
        var values = [Float](repeating: -8, count: 3_400)
        var times: [Double] = []
        var time = 0.4
        for number in 0..<100 {
            let step = Int((time * 50).rounded())
            values[step] = -0.6
            times.append(Double(step) / 50)
            time += 0.6 + 0.0006 * Double(number)
        }

        let picked = pick(values)

        #expect(picked.beats.map(\.time) == times)
        #expect(picked.loosened.count == 100)
    }

    @Test func aRowOfNoiseGetsNoBeats() {
        for seed in 1...3 {
            var dice = Dice(state: UInt64(seed) &* 0xD1B5_4A32_D192_ED03)
            // 60 seconds in which every value is below 0 and above the floor, with no pattern.
            let values = (0..<3_000).map { _ in Float(-0.75 + 0.65 * dice.roll()) }
            #expect(BeatPicker.peaks(in: values, above: BeatPicker.floor).count > 300)

            #expect(pick(values).beats.isEmpty, "seed \(seed)")
        }
    }

    @Test func slowWobblesAroundTheModelsDoNotKnowValueGetNoBeats() {
        for seed in 1...4 {
            var dice = Dice(state: UInt64(seed) &* 0xA24B_AED4_963E_E407)
            // What the model gives for a held chord without drums: values that drift around
            // -0.4, with a small peak about five times a second.
            let rough = (0..<3_008).map { _ in dice.roll() }
            let values = (0..<3_000).map { index in
                Float(-0.4 + 0.4 * rough[index..<(index + 8)].reduce(0, +) / 8)
            }
            #expect(values.allSatisfy { $0 < 0 })
            #expect((250...350).contains(BeatPicker.peaks(in: values, above: BeatPicker.floor).count))

            #expect(pick(values).beats.isEmpty, "seed \(seed)")
        }
    }

    @Test func aSongWithNoValuesHasNoBeats() {
        #expect(pick([]).beats.isEmpty)
        #expect(pick([Float](repeating: -8, count: 3_000)).beats.isEmpty)
    }

    // MARK: Today's beats

    /// The model's own output for "Weighted Silence", kept from the start of the project, turned back into a
    /// row of values with a sure peak on every beat it reported.
    @Test func theStartingLimitGivesTodaysBeatsOnTheReferenceSong() throws {
        struct File: Decodable { var beats: [Double] }
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/weighted-silence-raw-beats.json")
        let raw = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).beats
        var values = [Float](repeating: -8, count: 10_599)
        // Every beat of this song was reported on a whole step.
        for time in raw { values[Int((time * 50).rounded())] = 6 }
        let today = BeatLevel.force(BeatPicker.peaks(in: values).map { $0.position / 50 })
        #expect(today.count == 313)
        #expect(zip(today, BeatLevel.force(raw)).allSatisfy { abs($0.time - $1.time) < 1e-9 && $0.number == $1.number })

        let picked = pick(values)

        #expect(picked.beats == today)
        #expect(picked.loosened.isEmpty)
    }
}

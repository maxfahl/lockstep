import Foundation
import Testing
@testable import LockstepCore

@Suite struct EchoRepeatsTests {
    /// The beats of a song that speeds up: each beat is 2 % shorter than the one before, from half a second.
    private static func driftingBeats(count: Int = 40) -> [Double] {
        var beats: [Double] = []
        var time = 1.0
        var length = 0.5
        for _ in 0..<count {
            beats.append(time)
            time += length
            length *= 0.98
        }
        return beats
    }

    @Test func quarterNoteRepeatsOfASoundOnABeatLandOnTheBeatsAfterIt() {
        let beats = Self.driftingBeats()

        let repeats = EchoRepeats.repeats(ofSoundAt: beats[4], note: .quarter, levelDb: -6, beats: beats)

        // -6, -12, … -36 dB: six repeats, and the seventh would be below -40 dB.
        #expect(repeats.count == 6)
        for (index, one) in repeats.enumerated() {
            #expect(one.number == index + 1)
            #expect(abs(one.position - beats[4 + one.number]) < 1e-9)
            #expect(abs(one.gainDb - (-6 - 6 * Double(index))) < 1e-9)
        }
        // The song speeds up, so no two repeats are the same distance apart: one fixed delay time would
        // walk away from the beats.
        let distances = zip(repeats, repeats.dropFirst()).map { $1.position - $0.position }
        #expect(zip(distances, distances.dropFirst()).allSatisfy { $1 < $0 })
    }

    @Test func eighthNoteRepeatsLandOnTheBeatsAndHalfwayBetweenThem() {
        let beats = Self.driftingBeats()

        let repeats = EchoRepeats.repeats(ofSoundAt: beats[10], note: .eighth, levelDb: -6, beats: beats)

        #expect(repeats.count == 6)
        #expect(abs(repeats[0].position - (beats[10] + beats[11]) / 2) < 1e-9)
        #expect(abs(repeats[1].position - beats[11]) < 1e-9)
        #expect(abs(repeats[2].position - (beats[11] + beats[12]) / 2) < 1e-9)
        #expect(abs(repeats[5].position - beats[13]) < 1e-9)
    }

    @Test func aSoundBetweenTwoBeatsKeepsItsPlaceBetweenTheBeatsItsRepeatsLandOn() {
        let beats = Self.driftingBeats()
        // A quarter of the way from beat 6 to beat 7.
        let start = beats[6] + 0.25 * (beats[7] - beats[6])

        let repeats = EchoRepeats.repeats(ofSoundAt: start, note: .quarter, levelDb: -6, beats: beats)

        #expect(abs(repeats[0].position - (beats[7] + 0.25 * (beats[8] - beats[7]))) < 1e-9)
        #expect(abs(repeats[2].position - (beats[9] + 0.25 * (beats[10] - beats[9]))) < 1e-9)
    }

    @Test func repeatsStopAtTwoBars() {
        let beats = Self.driftingBeats()

        // So loud that the level alone would allow nine repeats.
        let repeats = EchoRepeats.repeats(ofSoundAt: beats[2], note: .quarter, levelDb: 12, beats: beats)

        #expect(repeats.count == 8)
        #expect(abs((repeats.last?.position ?? 0) - beats[10]) < 1e-9)
    }

    @Test func repeatsStopWhereTheBeatsEnd() {
        let beats = Self.driftingBeats(count: 12)

        let repeats = EchoRepeats.repeats(ofSoundAt: beats[8], note: .quarter, levelDb: -6, beats: beats)

        // Beats 9, 10 and 11 are there. Nothing is made up after the last beat.
        #expect(repeats.map(\.number) == [1, 2, 3])
        #expect(abs((repeats.last?.position ?? 0) - beats[11]) < 1e-9)
    }

    @Test func thereIsNoEchoWhereTheGridHasNoBeats() {
        let beats = Self.driftingBeats(count: 12)

        #expect(EchoRepeats.repeats(ofSoundAt: 0.2, note: .quarter, levelDb: -6, beats: beats).isEmpty)
        #expect(EchoRepeats.repeats(ofSoundAt: beats[11] + 1, note: .quarter, levelDb: -6, beats: beats).isEmpty)
        #expect(EchoRepeats.repeats(ofSoundAt: 3, note: .quarter, levelDb: -6, beats: []).isEmpty)
        #expect(EchoRepeats.repeats(ofSoundAt: 3, note: .quarter, levelDb: -6, beats: [3]).isEmpty)
    }

    @Test func noRepeatIsPlacedAcrossAStretchThatWasLeftWithoutBeats() {
        // Eight beats, four seconds with none, eight more.
        let early: [Double] = (0..<8).map { 1 + 0.5 * Double($0) }
        let late: [Double] = (0..<8).map { 8.5 + 0.5 * Double($0) }
        let beats = early + late

        let before = EchoRepeats.repeats(ofSoundAt: beats[5], note: .quarter, levelDb: -6, beats: beats)
        let inside = EchoRepeats.repeats(ofSoundAt: 6, note: .quarter, levelDb: -6, beats: beats)
        let after = EchoRepeats.repeats(ofSoundAt: beats[8], note: .quarter, levelDb: -6, beats: beats)

        #expect(before.map(\.position) == [beats[6], beats[7]])
        #expect(inside.isEmpty)
        #expect(after.count == 6)
    }

    @Test func anEchoQuieterThanTheFloorHasNoRepeats() {
        let beats = Self.driftingBeats()

        #expect(EchoRepeats.repeats(ofSoundAt: beats[4], note: .eighth, levelDb: -41, beats: beats).isEmpty)
        #expect(EchoRepeats.repeats(ofSoundAt: beats[4], note: .eighth, levelDb: -40, beats: beats).count == 1)
    }

    @Test func positionsMayBeSamplesOfASoundWithBeatsBeforeItsStart() {
        // The beats as samples of a clip's dry sound: the song's beats lie before and after sample 0.
        let beats = (-3..<12).map { Double($0) * 24_000 + 6_000 }

        let repeats = EchoRepeats.repeats(ofSoundAt: 0, note: .quarter, levelDb: -18, beats: beats)

        #expect(repeats.map(\.position) == [24_000, 48_000, 72_000, 96_000])
        #expect(repeats.map(\.gainDb) == [-18, -24, -30, -36])
    }
}

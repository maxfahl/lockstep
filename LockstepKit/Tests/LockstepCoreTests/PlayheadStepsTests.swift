import Testing
@testable import LockstepCore

@Suite("PlayheadSteps")
struct PlayheadStepsTests {
    /// The song is 12 seconds long in every test.
    static let songLength = 12.0

    /// Beats at 2, 3, 4, 5 and 6 seconds: one second apart, so a sixteenth is 0.25 s, a triplet part a
    /// sixth of a second and a half beat 0.5 s.
    func grid() -> Grid {
        Grid(beats: (0..<5).map { Beat(number: $0, time: 2 + Double($0)) })
    }

    /// Beats at 2, 3 and 4 seconds, an empty gap, then beats at 8 and 9 seconds.
    func gridWithAGap() -> Grid {
        Grid(beats: [0, 1, 2, 6, 7].map { Beat(number: $0, time: 2 + Double($0)) })
    }

    func step(
        _ direction: StepDirection,
        _ step: PlayheadStep,
        from seconds: Double,
        in grid: Grid? = nil
    ) -> Double {
        (grid ?? self.grid()).stepPlace(
            direction,
            from: seconds,
            perBeat: step.perBeat,
            songLength: Self.songLength
        )
    }

    // MARK: - How a beat is cut

    @Test func aSubBeatStepIsASixteenth() {
        // The song has no sub-beats of its own, so the step never counts in triplets.
        #expect(PlayheadStep.subBeat.perBeat == 4)
        #expect(PlayheadStep.halfBeat.perBeat == 2)
        #expect(PlayheadStep.beat.perBeat == 1)
    }

    // MARK: - Between two places

    @Test func aPlayheadBetweenTwoPlacesGoesToTheClosestOneInThatDirection() {
        // 3.6 lies between the sixteenths at 3.5 and 3.75, the half beats at 3.5 and 4, and the beats at 3 and 4.
        #expect(step(.back, .subBeat, from: 3.6) == 3.5)
        #expect(step(.forward, .subBeat, from: 3.6) == 3.75)
        #expect(step(.back, .halfBeat, from: 3.6) == 3.5)
        #expect(step(.forward, .halfBeat, from: 3.6) == 4)
        #expect(step(.back, .beat, from: 3.6) == 3)
        #expect(step(.forward, .beat, from: 3.6) == 4)
    }

    // MARK: - On a line

    @Test func aPlayheadOnALineGoesToTheNextPlaceAndNotToTheLineItself() {
        // On a beat.
        #expect(step(.back, .subBeat, from: 4) == 3.75)
        #expect(step(.forward, .subBeat, from: 4) == 4.25)
        #expect(step(.back, .halfBeat, from: 4) == 3.5)
        #expect(step(.forward, .halfBeat, from: 4) == 4.5)
        #expect(step(.back, .beat, from: 4) == 3)
        #expect(step(.forward, .beat, from: 4) == 5)
        // On a sub-beat that is no beat.
        #expect(step(.back, .subBeat, from: 3.5) == 3.25)
        #expect(step(.forward, .subBeat, from: 3.5) == 3.75)
        #expect(step(.back, .halfBeat, from: 3.5) == 3)
        #expect(step(.forward, .halfBeat, from: 3.5) == 4)
        #expect(step(.back, .beat, from: 3.5) == 3)
        #expect(step(.forward, .beat, from: 3.5) == 4)
    }

    @Test func aPlayheadAHairBesideALineCountsAsStandingOnIt() {
        // The player reports a place to the nearest sample, which is up to 1/96,000 s off.
        let hair = 1.0 / 96_000
        for seconds in [4 - hair, 4 + hair] {
            #expect(step(.back, .subBeat, from: seconds) == 3.75)
            #expect(step(.forward, .subBeat, from: seconds) == 4.25)
            #expect(step(.back, .beat, from: seconds) == 3)
            #expect(step(.forward, .beat, from: seconds) == 5)
        }
    }

    @Test func steppingThereAndBackEndsWhereItStarted() {
        for kind in PlayheadStep.allCases {
            var place = 3.0
            // Three steps on, to the last beat at most, and three back.
            for _ in 0..<3 { place = step(.forward, kind, from: place) }
            for _ in 0..<3 { place = step(.back, kind, from: place) }
            #expect(abs(place - 3) < 1e-9)
        }
    }

    // MARK: - The ends of the song

    @Test func beforeTheFirstBeatAStepBackGoesToTheStartOfTheSong() {
        for kind in PlayheadStep.allCases {
            #expect(step(.back, kind, from: 1.3) == 0)
            // Also from the first beat itself, and from the start of the song.
            #expect(step(.back, kind, from: 2) == 0)
            #expect(step(.back, kind, from: 0) == 0)
            // Forward from there the first beat is the nearest place.
            #expect(step(.forward, kind, from: 1.3) == 2)
            #expect(step(.forward, kind, from: 0) == 2)
        }
    }

    @Test func afterTheLastBeatAStepForwardGoesToTheEndOfTheSong() {
        for kind in PlayheadStep.allCases {
            #expect(step(.forward, kind, from: 7.4) == Self.songLength)
            // Also from the last beat itself, and from the end of the song.
            #expect(step(.forward, kind, from: 6) == Self.songLength)
            #expect(step(.forward, kind, from: Self.songLength) == Self.songLength)
            // Back from there the last beat is the nearest place.
            #expect(step(.back, kind, from: 7.4) == 6)
            #expect(step(.back, kind, from: Self.songLength) == 6)
        }
        // The last stretch between two beats is still cut into parts.
        #expect(step(.forward, .subBeat, from: 5.75) == 6)
        #expect(step(.back, .subBeat, from: 6) == 5.75)
    }

    @Test func aPlaceIsNeverOutsideTheSong() {
        // A song that ends before its last beats.
        let short = grid().stepPlace(.forward, from: 4.9, perBeat: 1, songLength: 4.5)
        #expect(short == 4.5)
    }

    // MARK: - Gaps and no beats

    @Test func aGapWithoutBeatsHasNoPlacesInIt() {
        let grid = gridWithAGap()
        // The beat at 4 stands alone: the next place after it is the beat at 8.
        #expect(step(.forward, .subBeat, from: 4, in: grid) == 8)
        #expect(step(.forward, .subBeat, from: 5.5, in: grid) == 8)
        #expect(step(.back, .subBeat, from: 5.5, in: grid) == 4)
        #expect(step(.back, .subBeat, from: 8, in: grid) == 4)
        #expect(step(.back, .halfBeat, from: 8, in: grid) == 4)
        #expect(step(.back, .subBeat, from: 4, in: grid) == 3.75)
    }

    @Test func withoutBeatsAStepGoesToAnEndOfTheSong() {
        let empty = Grid()
        #expect(step(.back, .subBeat, from: 5, in: empty) == 0)
        #expect(step(.forward, .subBeat, from: 5, in: empty) == Self.songLength)
    }
}

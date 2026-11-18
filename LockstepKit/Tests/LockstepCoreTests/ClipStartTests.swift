import Testing
@testable import LockstepCore

/// Which part of a take becomes its clip when the voice is known stretch by stretch: the words just before
/// the place belong to the clip, and other sound before it does not.
///
/// The take of these tests was recorded from 6 s in the song with the place at 10 s, so the place is sample
/// 192,000 of the take. The song has no beats, so a bar is 2 s (96,000 samples) and the clip may start at
/// sample 96,000 at the earliest. The verse starts 10 ms after the place and lasts 3 s.
@Suite("RecordingPlacement, words before the place")
struct ClipStartTests {
    private let recording = Recording(lengthSamples: 480_000, rawStart: 6)
    private let place = 192_000
    private let verse = 192_480..<336_000
    /// 150 ms after the end of the verse.
    private let clipEnd = 343_200
    /// The clip of the verse alone: from 50 ms before its first sound.
    private var verseClip: Range<Int> { 190_080..<clipEnd }

    /// A stretch of the take from `from` to `to` seconds before the place.
    private func before(_ from: Double, _ to: Double) -> Range<Int> {
        place - Int(from * 48_000)..<place - Int(to * 48_000)
    }

    private func clip(
        _ stretches: [Range<Int>],
        of recording: Recording? = nil,
        origin: Double = 10,
        grid: Grid? = nil,
        clickLeak: ClickLeak = .none
    ) -> Range<Int>? {
        RecordingPlacement.clipSamples(
            of: recording ?? self.recording,
            voicedStretches: stretches,
            origin: origin,
            grid: grid,
            clickLeak: clickLeak
        )
    }

    @Test("A voice that starts on the place gives a clip from 50 ms before the voice to 150 ms after it")
    func clipStartsWithTheVoice() {
        #expect(clip([verse]) == verseClip)
        // The same for a voice that starts later.
        #expect(clip([240_000..<336_000]) == 237_600..<clipEnd)
    }

    @Test("A word 300 ms before the place is in the clip, with 50 ms before it")
    func wordJustBeforeThePlaceIsKept() {
        // The word lasts from 300 ms to 100 ms before the place.
        let word = before(0.3, 0.1)
        #expect(clip([word, verse]) == word.lowerBound - 2_400..<clipEnd)
        // Also when nothing follows it for a while: it was still said into the place.
        #expect(clip([word, 288_000..<336_000]) == word.lowerBound - 2_400..<clipEnd)
        // And a line that runs across the place is kept from its start.
        #expect(clip([before(0.3, -3)]) == before(0.3, 0).lowerBound - 2_400..<place + 144_000 + 7_200)
    }

    @Test("Words before the place are followed back as long as the pauses are 0.4 s at most")
    func severalWordsLeadIntoThePlace() {
        // "ey", a pause of 0.3 s, "yo", a pause of 0.2 s, the verse.
        let ey = before(1.0, 0.8)
        let yo = before(0.5, 0.2)
        #expect(clip([ey, yo, verse]) == ey.lowerBound - 2_400..<clipEnd)
        // With a pause of half a second between them only the second word leads into the place.
        let early = before(1.2, 1.0)
        #expect(clip([early, yo, verse]) == yo.lowerBound - 2_400..<clipEnd)
    }

    @Test("A sound two bars before the place is not in the clip")
    func soundTwoBarsBeforeIsLeftOut() {
        #expect(clip([before(4.0, 3.5), verse]) == verseClip)
    }

    @Test("A word that ends 1 second before the place is not in the clip")
    func wordThatEndsLongBeforeIsLeftOut() {
        #expect(clip([before(1.5, 1.0), verse]) == verseClip)
        // The longest pause that still leads into the place is 0.4 s.
        #expect(clip([before(0.7, 0.4), verse])?.lowerBound == before(0.7, 0).lowerBound - 2_400)
        #expect(clip([before(0.7, 0.41), verse]) == verseClip)
    }

    @Test("A 30 ms pop before the place is not in the clip")
    func popIsLeftOut() {
        #expect(clip([before(0.2, 0.17), verse]) == verseClip)
        // A pop between a word and the place does not hide the word.
        let word = before(0.5, 0.3)
        #expect(clip([word, before(0.2, 0.17), verse]) == word.lowerBound - 2_400..<clipEnd)
        // Sound of 60 ms counts as a word.
        #expect(clip([before(0.2, 0.14), verse])?.lowerBound == before(0.2, 0).lowerBound - 2_400)
    }

    @Test("The clip never starts more than one bar before the place")
    func clipStartsOneBarBackAtMost() {
        // Talking all the way from three seconds before the place.
        #expect(clip([before(3.0, 0.1), verse]) == place - 96_000..<clipEnd)
        // A word that starts just inside the bar is kept from its start, and the 50 ms before it stop at the bar.
        #expect(clip([before(1.99, 1.7), before(1.5, 0.1), verse]) == place - 96_000..<clipEnd)

        // With beats 0.4 s apart a bar is 1.6 s.
        let grid = Grid(beats: (0..<100).map { Beat(number: $0, time: Double($0) * 0.4) })
        #expect(clip([before(3.0, 0.1), verse], grid: grid) == place - 76_800..<clipEnd)
    }

    @Test("The clip never starts in the first 150 ms after the microphone opened")
    func clipLeavesOutTheMicrophoneOpening() {
        // A short count-in: the take began 0.5 s before the place.
        let take = Recording(lengthSamples: 240_000, rawStart: 9.5)
        // Sound from the take's very first sample into the place.
        #expect(clip([0..<20_000, 24_480..<120_000], of: take) == 7_200..<127_200)

        // With the count-in off the take begins 0.1 s before the place, and the clip starts at the place.
        let atOnce = Recording(lengthSamples: 240_000, rawStart: 9.9)
        #expect(clip([0..<120_000], of: atOnce) == 4_800..<127_200)
    }

    @Test("The measured delay moves the place in the take")
    func delayMovesThePlace() {
        var calibrated = recording
        calibrated.delay = 0.5
        // The place is now sample 216,000 of the take.
        #expect(clip([216_480..<336_000], of: calibrated) == 214_080..<clipEnd)
        #expect(clip([201_600..<211_200, 216_480..<336_000], of: calibrated) == 199_200..<clipEnd)
    }

    @Test("Without a voice from the place on the clip runs from the place to the stop, as before")
    func silentTake() {
        #expect(clip([]) == place..<480_000)
        // A cough long before the place is no voice for the clip.
        #expect(clip([before(3.0, 2.8)]) == place..<480_000)
        // Stopped before the place was reached: nothing to keep.
        #expect(clip([], of: Recording(lengthSamples: 96_000, rawStart: 6)) == nil)
        // A take shorter than 0.2 s is thrown away.
        #expect(clip([0..<9_000], of: Recording(lengthSamples: 9_120, rawStart: 10), origin: 10) == nil)
    }

    // MARK: The click leaking into the microphone

    /// A count-in of one bar at 120 beats a minute with a click that sounds for 150 ms.
    private let leak = ClickLeak(times: [8, 8.5, 9, 9.5, 10], soundSeconds: 0.15)

    /// What the microphone hears of each click before the place: 150 ms of sound from 2 ms after the click.
    private var clickBursts: [Range<Int>] {
        [2.0, 1.5, 1.0, 0.5].map { before($0 - 0.002, $0 - 0.152) }
    }

    @Test("A click-length burst on every beat of the count-in leaves the clip starting with the verse on the place")
    func clickLeakIsNotAWord() {
        #expect(clip(clickBursts + [verse], clickLeak: leak) == verseClip)
        // Without the click times the bursts look like words that lead into the place, one bar back.
        #expect(clip(clickBursts + [verse]) == place - 96_000..<clipEnd)
        // The click on the place itself, leaking alone, is no voice either.
        #expect(clip(clickBursts + [place + 96..<place + 7_296], clickLeak: leak) == place..<480_000)
    }

    @Test("The same bursts with a real word 300 ms before the place start the clip at the word")
    func wordBetweenLeakingClicksIsKept() {
        let word = before(0.3, 0.1)
        let stretches = (clickBursts + [word, verse]).sorted { $0.lowerBound < $1.lowerBound }
        #expect(clip(stretches, clickLeak: leak) == word.lowerBound - 2_400..<clipEnd)
    }

    @Test("Sound that starts on a click and goes on longer than the click rings is a word")
    func wordOnAClickIsKept() {
        // A word said exactly on the last beat of the count-in, 300 ms long.
        let word = before(0.5, 0.2)
        #expect(clip([word, verse], clickLeak: leak) == word.lowerBound - 2_400..<clipEnd)
        // A short sound that starts between two clicks is a word too.
        let offBeat = before(0.3, 0.2)
        #expect(clip([offBeat, verse], clickLeak: leak) == offBeat.lowerBound - 2_400..<clipEnd)
        // A leak may start up to 10 ms before its click and 25 ms after it, and ring 30 ms longer than the click.
        #expect(clip([before(0.51, 0.34), verse], clickLeak: leak) == verseClip)
        #expect(clip([before(0.475, 0.30), verse], clickLeak: leak) == verseClip)
        #expect(clip([before(0.47, 0.30), verse], clickLeak: leak)?.lowerBound == before(0.47, 0).lowerBound - 2_400)
    }
}

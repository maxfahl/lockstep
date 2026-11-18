import Testing
@testable import LockstepCore

/// A take that an agent adds from a file (`-addTake`) is placed as if Record had been pressed at the very start
/// of the song with the count-in off. Its clip is now chosen by the rule that looks at the voice stretch by
/// stretch. These tests hold that rule to what the rule before it gave for such a take: from 50 ms before the
/// first sound to 150 ms after the last, or the whole take when nothing in it counts as sound.
@Suite("RecordingPlacement, a take added at the start of the song")
struct AddedTakeClipTests {
    /// What `VoiceEnvelope.voicedRange()` made of the stretches, and so what the rule before was handed.
    private func outerRange(of stretches: [Range<Int>], length: Int) -> Range<Int>? {
        guard let first = stretches.first, let last = stretches.last else { return nil }
        let start = max(first.lowerBound - 2_400, 0)
        let end = min(last.upperBound + 7_200, length)
        return start < end ? start..<end : nil
    }

    private func newClip(_ stretches: [Range<Int>], length: Int) -> Range<Int>? {
        RecordingPlacement.clipSamples(
            of: Recording(lengthSamples: length, rawStart: 0),
            voicedStretches: stretches,
            origin: 0,
            grid: nil,
            clickLeak: .none
        )
    }

    private func oldClip(_ stretches: [Range<Int>], length: Int) -> Range<Int>? {
        RecordingPlacement.clipSamples(
            of: Recording(lengthSamples: length, rawStart: 0),
            voiced: outerRange(of: stretches, length: length),
            origin: 0
        )
    }

    @Test(
        "With the place at the start of the song and the count-in off, the clip is the one the rule before gave",
        arguments: [
            // One line in the middle of the take.
            ([48_000..<144_000], 240_000),
            // A voice from the very first sample, as in a file cut tight.
            ([0..<96_000], 240_000),
            // A voice that starts inside the first 50 ms and inside the first 150 ms.
            ([1_200..<96_000], 240_000),
            ([4_800..<96_000], 240_000),
            // A voice up to the very end, and one that ends inside the last 150 ms.
            ([48_000..<240_000], 240_000),
            ([48_000..<236_000], 240_000),
            // Several lines, with a short sound first and a short sound last.
            ([9_600..<11_040, 48_000..<96_000, 120_000..<168_000, 200_000..<201_500], 240_000),
            // Nothing that counts as sound: the whole take.
            ([], 240_000),
            // A take that is too short is thrown away, with a voice or without.
            ([1_000..<5_000], 9_000),
            ([], 9_000),
        ] as [([Range<Int>], Int)]
    )
    func sameClipAsBefore(stretches: [Range<Int>], length: Int) {
        #expect(newClip(stretches, length: length) == oldClip(stretches, length: length))
    }

    @Test("The clip of such a take runs from 50 ms before its first sound to 150 ms after its last")
    func clipInNumbers() {
        #expect(newClip([48_000..<144_000], length: 240_000) == 45_600..<151_200)
        #expect(newClip([0..<96_000], length: 240_000) == 0..<103_200)
        #expect(newClip([], length: 240_000) == 0..<240_000)
        #expect(newClip([1_000..<5_000], length: 9_000) == nil)
    }
}

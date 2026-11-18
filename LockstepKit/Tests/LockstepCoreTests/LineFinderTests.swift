import Foundation
import Testing
@testable import LockstepCore

@Suite("LineFinder")
struct LineFinderTests {
    /// One millisecond of the recording, in samples.
    private let ms = 48

    /// Loudness values, one per millisecond: -20 dB inside the bursts and -70 dB everywhere else, with sound
    /// counted from -58 dB. The bursts are given in milliseconds.
    private func levels(lengthMs: Int, bursts: [Range<Int>]) -> VoiceLevels {
        var values = [Float](repeating: -70, count: lengthMs)
        for burst in bursts {
            for index in burst { values[index] = -20 }
        }
        return VoiceLevels(values: values, threshold: -58, hopSamples: ms)
    }

    @Test func twoBurstsFourHundredMillisecondsApartAreTwoLines() {
        let found = LineFinder.lines(
            in: 0..<2000 * ms,
            levels: levels(lengthMs: 2000, bursts: [100..<600, 1000..<1500]),
            markers: [150 * ms, 300 * ms, 1100 * ms],
            pauseMs: 250
        )
        #expect(found.count == 2)
        // Each line starts 10 ms before its sound and ends 30 ms after it.
        #expect(found[0].startSample == 90 * ms)
        #expect(found[0].endSample == 630 * ms)
        #expect(found[1].startSample == 990 * ms)
        #expect(found[1].endSample == 1530 * ms)
        // Each marker is in the line it sounds in, and the first one names the line.
        #expect(found[0].markers == [150 * ms, 300 * ms])
        #expect(found[1].markers == [1100 * ms])
        #expect(found[0].identity == 150 * ms)
        #expect(found[1].identity == 1100 * ms)
    }

    @Test func twoBurstsTwoHundredMillisecondsApartAreOneLine() {
        let found = LineFinder.lines(
            in: 0..<2000 * ms,
            levels: levels(lengthMs: 2000, bursts: [100..<600, 800..<1300]),
            markers: [150 * ms, 900 * ms],
            pauseMs: 250
        )
        #expect(found.count == 1)
        #expect(found[0].startSample == 90 * ms)
        #expect(found[0].endSample == 1330 * ms)
        #expect(found[0].markers == [150 * ms, 900 * ms])
    }

    @Test func aPauseSettingOfOneHundredFiftySplitsTheTwoHundredCase() {
        let found = LineFinder.lines(
            in: 0..<2000 * ms,
            levels: levels(lengthMs: 2000, bursts: [100..<600, 800..<1300]),
            markers: [150 * ms, 900 * ms],
            pauseMs: 150
        )
        #expect(found.count == 2)
        #expect(found[0].endSample == 630 * ms)
        #expect(found[1].startSample == 790 * ms)
        #expect(found[0].markers == [150 * ms])
        #expect(found[1].markers == [900 * ms])
    }

    @Test func aPauseOfExactlyTheSettingSeparatesTwoLines() {
        // "At least" 250 ms: a pause of exactly that length counts, one a millisecond shorter does not.
        let exact = LineFinder.lines(
            in: 0..<2000 * ms, levels: levels(lengthMs: 2000, bursts: [100..<600, 850..<1300]), markers: []
        )
        #expect(exact.count == 2)
        let shorter = LineFinder.lines(
            in: 0..<2000 * ms, levels: levels(lengthMs: 2000, bursts: [100..<600, 849..<1300]), markers: []
        )
        #expect(shorter.count == 1)
    }

    @Test func aSplitInTheMiddleOfABurstGivesTwoLines() {
        // One burst from 100 to 900 ms, and a clip cut in two at 500 ms, in the middle of it.
        let recording = UUID()
        let cut = 500 * ms
        let clip = Clip(segments: [
            Segment(recordingID: recording, inSample: 0, outSample: cut),
            Segment(recordingID: recording, inSample: cut, outSample: 1500 * ms),
        ])
        let markers = [200, 400, 600, 800].map { SyllableMarker(sample: $0 * ms, strength: 6) }
        let found = LineFinder.lines(
            in: clip,
            levels: [recording: levels(lengthMs: 1500, bursts: [100..<900])],
            markers: [recording: markers],
            pauseMs: 250
        )
        #expect(found.count == 2)
        #expect(found[0].count == 1)
        #expect(found[1].count == 1)
        // The cut ends the first line and starts the second: neither reaches across it.
        #expect(found[0][0].startSample == 90 * ms)
        #expect(found[0][0].endSample == cut)
        #expect(found[1][0].startSample == cut)
        #expect(found[1][0].endSample == 930 * ms)
        #expect(found[0][0].markers == [200 * ms, 400 * ms])
        #expect(found[1][0].markers == [600 * ms, 800 * ms])
    }

    @Test func marginsNeverOverlapANeighbour() {
        // With pauses far shorter than the margins of 10 and 30 ms, every line still ends where the next
        // one starts or before it, and stays inside the stretch that was asked for.
        let bursts = [50..<100, 112..<160, 175..<230, 236..<300, 345..<400]
        let range = 40 * ms..<420 * ms
        let found = LineFinder.lines(
            in: range, levels: levels(lengthMs: 500, bursts: bursts), markers: [], pauseMs: 5
        )
        #expect(found.count == bursts.count)
        for (line, burst) in zip(found, bursts) {
            // The sound itself is always inside its line.
            #expect(line.startSample <= burst.lowerBound * ms)
            #expect(line.endSample >= burst.upperBound * ms)
            #expect(line.startSample >= range.lowerBound)
            #expect(line.endSample <= range.upperBound)
        }
        for (earlier, later) in zip(found, found.dropFirst()) {
            #expect(earlier.endSample <= later.startSample)
        }
        // Where there is room, the margins are the full 10 and 30 ms.
        #expect(found[3].endSample == 330 * ms)
        #expect(found[4].startSample == 335 * ms)
        #expect(found[0].startSample == range.lowerBound)
    }

    @Test func aLineWithNoMarkersIsKeptAndHasNoIdentity() {
        let found = LineFinder.lines(
            in: 0..<1000 * ms, levels: levels(lengthMs: 1000, bursts: [200..<500]), markers: [900 * ms]
        )
        #expect(found.count == 1)
        #expect(found[0].markers.isEmpty)
        #expect(found[0].identity == nil)
    }

    @Test func silenceAndMissingLevelsGiveNoLines() {
        #expect(LineFinder.lines(in: 0..<1000 * ms, levels: levels(lengthMs: 1000, bursts: []), markers: []).isEmpty)
        let clip = Clip(segments: [Segment(recordingID: UUID(), inSample: 0, outSample: 1000 * ms)])
        #expect(LineFinder.lines(in: clip, levels: [:], markers: [:]) == [[]])
    }
}

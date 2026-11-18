import Foundation
import LockstepCore
import Synchronization
import Testing
@testable import LockstepAudio

/// A made-up song in stereo: a tone of 440 Hz on the left and one of 660 Hz on the right, both quiet, with a
/// loud click on both channels at each of `clicks` (frames).
private func song(frames: Int, clicks: [Int]) -> [Float] {
    var samples = [Float](repeating: 0, count: frames * 2)
    for frame in 0..<frames {
        let time = Double(frame) / 48_000
        samples[frame * 2] = Float(0.2 * sin(2 * Double.pi * 440 * time))
        samples[frame * 2 + 1] = Float(0.2 * sin(2 * Double.pi * 660 * time))
    }
    for click in clicks {
        samples[click * 2] = 0.9
        samples[click * 2 + 1] = 0.9
    }
    return samples
}

private func channel(_ index: Int, of samples: [Float]) -> [Float] {
    stride(from: index, to: samples.count, by: 2).map { samples[$0] }
}

@Suite("The slowed song and row of voices")
struct SlowedBackingTests {
    private let tolerance = RubberBandStretcher.toleranceSeconds * 48_000

    @Test("The slowed song is its length divided by the rate, on the sample, and keeps its pitch", arguments: [0.85, 0.9])
    func slowedSong(rate: Double) throws {
        // 45 seconds, so the song is made in pieces, with a click on either side of where two of them meet.
        let frames = 2_160_000
        let clicks = [48_000, 151_111, 700_000, 940_000, 980_000, 1_300_000, 2_000_000]
        let made = song(frames: frames, clicks: clicks)
        let slow = SlowTime(rate: rate)

        let slowed = try #require(SlowedBacking.slowedNow(made, channels: 2, rate: rate))

        #expect(slowed.count == slow.slowLength(ofSong: frames) * 2)
        #expect(slow.slowLength(ofSong: frames) == Int((Double(frames) / rate).rounded()))
        let left = channel(0, of: slowed), right = channel(1, of: slowed)
        // Measured 440.0000 and 660.0000 Hz.
        #expect(abs(StretchFixtures.frequency(of: left[60_000..<100_000]) / 440 - 1) < 0.01)
        #expect(abs(StretchFixtures.frequency(of: right[60_000..<100_000]) / 660 - 1) < 0.01)
        // As loud as it was: measured 0.999.
        #expect(abs(StretchFixtures.loudness(left) / StretchFixtures.loudness(channel(0, of: made)) - 1) < 0.02)
        // A click is heard on its frame divided by the rate, in both channels. Measured: 1 ms off at most,
        // where the click stands on a tone that the measure takes for part of it.
        for click in clicks {
            let expected = slow.slowSample(forSong: click)
            for side in [left, right] {
                let peak = StretchFixtures.peak(in: side, near: expected, search: 2_000)
                #expect(abs(Double(peak - expected)) <= tolerance)
                #expect(abs(side[peak]) > 0.3)
            }
        }
    }

    @Test("What is the same in left and right comes out the same in both")
    func leftAndRightStayTogether() throws {
        let frames = 1_200_000
        var noise = StretchFixtures.Random(state: 3)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(0.3 * sin(2 * Double.pi * 330 * Double(frame) / 48_000) + (noise.next() - 0.5) * 0.1)
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        let slowed = try #require(SlowedBacking.slowedNow(samples, channels: 2, rate: 0.85))
        #expect(channel(0, of: slowed) == channel(1, of: slowed))
    }

    @Test("A row of voices keeps its silence, and its pieces meet in the silence between two clips")
    func slowedRowOfVoices() throws {
        // Three minutes of row with two clips in it: 2 s of voice from 0:05, and 15 s from 0:12 with a rest of
        // half a second 20.3 s into the row, near where two pieces would meet.
        let frames = 8_640_000
        var row = [Float](repeating: 0, count: frames)
        for index in 240_000..<336_000 { row[index] = Float(0.3 * sin(2 * Double.pi * 220 * Double(index) / 48_000)) }
        for index in 576_000..<1_296_000 where !(974_400..<998_400).contains(index) {
            row[index] = Float(0.3 * sin(2 * Double.pi * 330 * Double(index) / 48_000))
        }
        let slow = SlowTime(rate: 0.85)

        let edges = row.withUnsafeBufferPointer { SlowedBacking.edges(of: $0.baseAddress!, frames: frames, channels: 1) }
        #expect(edges.first == 0)
        #expect(edges.last == frames)
        #expect(edges.count == 10)
        #expect((974_400..<998_400).contains(edges[1]))
        for (earlier, later) in zip(edges, edges.dropFirst()) { #expect(later - earlier >= 864_000) }

        let began = Date()
        let slowed = try #require(SlowedBacking.slowedNow(row, channels: 1, rate: 0.85))
        // Only the pieces with a voice in them are stretched. Measured 0.6 s alone.
        print("A row of three minutes with 17 s of voice in it was slowed in \(Date().timeIntervalSince(began)) s")

        #expect(slowed.count == slow.slowLength(ofSong: frames))
        // Silence well away from the voices is still silence, and the voices are where they belong.
        #expect(slowed[..<slow.slowSample(forSong: 230_000)].allSatisfy { $0 == 0 })
        #expect(slowed[slow.slowSample(forSong: 1_920_000)...].allSatisfy { $0 == 0 })
        let first = slow.slowSample(forSong: 250_000)..<slow.slowSample(forSong: 326_000)
        let second = slow.slowSample(forSong: 600_000)..<slow.slowSample(forSong: 900_000)
        #expect(abs(StretchFixtures.frequency(of: slowed[first]) / 220 - 1) < 0.01)
        #expect(abs(StretchFixtures.frequency(of: slowed[second]) / 330 - 1) < 0.01)
        #expect(abs(StretchFixtures.loudness(slowed[second]) / (0.3 / 2.0.squareRoot()) - 1) < 0.03)
        // The voice starts within the stretch tolerance of where it started, divided by the rate.
        let start = slowed.firstIndex { abs($0) > 0.1 } ?? 0
        #expect(abs(Double(start - slow.slowSample(forSong: 240_000))) <= tolerance)
    }

    @Test("The work says how far it has come, and gives nothing when it is given up")
    func progressAndGivingUp() async throws {
        let made = song(frames: 2_160_000, clicks: [])
        let furthest = Mutex(0.0)
        let calls = Atomic<Int>(0)
        let slowed = await SlowedBacking.slowed(made, channels: 2, rate: 0.9) { done in
            calls.add(1, ordering: .relaxed)
            furthest.withLock { $0 = max($0, done) }
        }
        #expect(slowed?.count == SlowTime(rate: 0.9).slowLength(ofSong: 2_160_000) * 2)
        #expect(furthest.withLock { $0 } == 1)
        // Two pieces of two channels.
        #expect(calls.load(ordering: .relaxed) == 4)

        // Given up after the first piece: nothing comes back.
        let asked = Atomic<Int>(0)
        let givenUp = SlowedBacking.slowedNow(
            made, channels: 2, rate: 0.9, isGivenUp: { asked.add(1, ordering: .relaxed).newValue > 1 })
        #expect(givenUp == nil)

        // A task that is cancelled gives nothing either.
        let task = Task { await SlowedBacking.slowed(made, channels: 2, rate: 0.9) }
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test("At the song's own speed the sound comes back as it is")
    func fullSpeed() {
        let made = song(frames: 48_000, clicks: [10_000])
        #expect(SlowedBacking.slowedNow(made, channels: 2, rate: 1) == made)
        #expect(SlowedBacking.slowedNow([], channels: 1, rate: 0.85) == [])
    }

    @Test("A song of three and a half minutes is slowed in a few seconds")
    func wholeSong() throws {
        let frames = 10_080_000
        let made = song(frames: frames, clicks: [])
        let began = Date()
        let slowed = try #require(SlowedBacking.slowedNow(made, channels: 2, rate: 0.85))
        let taken = Date().timeIntervalSince(began)
        // Measured 2.0 s on Max's Mac on 15 November 2026, alone, and 4.2 s with the other tests running beside it.
        print("A song of three and a half minutes in stereo was slowed to 85 % in \(taken) s")
        #expect(slowed.count == SlowTime(rate: 0.85).slowLength(ofSong: frames) * 2)
        #expect(taken < 60)
    }
}

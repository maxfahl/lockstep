import Foundation
import Testing
@testable import LockstepCore

/// A sample value that is this many dB below full scale.
private func level(_ db: Double) -> Float {
    Float(pow(10, db / 20))
}

/// The peaks of made-up recordings, measured the plain way: the highest sample of the stretch, without its sign.
private func peaks(_ sounds: [UUID: [Float]]) -> RecordingPeak {
    { id, samples in
        guard let sound = sounds[id] else { return 0 }
        let first = min(max(samples.lowerBound, 0), sound.count)
        let end = min(max(samples.upperBound, first), sound.count)
        return sound[first..<end].reduce(0) { max($0, abs($1)) }
    }
}

/// A one-second recording that starts `start` seconds into the song. Its first half is a steady sound at
/// `firstDb` dBFS and its second half one at `secondDb`.
private func recording(at start: Double, _ firstDb: Double, _ secondDb: Double) -> (Recording, [Float]) {
    let sound = [Float](repeating: level(firstDb), count: 24_000) + [Float](repeating: -level(secondDb), count: 24_000)
    return (Recording(lengthSamples: 48_000, rawStart: start), sound)
}

/// A clip that plays the whole of a one-second recording.
private func wholeClip(of recording: Recording, gainDb: Double = 0, normalizeGainDb: Double? = nil) -> Clip {
    Clip(
        segments: [Segment(recordingID: recording.id, inSample: 0, outSample: 48_000)],
        gainDb: gainDb,
        normalizeGainDb: normalizeGainDb
    )
}

/// A twenty-second song with one track holding these clips.
private func song(_ recordings: [Recording], _ clips: [Clip]) -> Project {
    Project(songLengthSamples: 960_000, tracks: [Track(name: "Track 1", clips: clips)], recordings: recordings)
}

/// How loud every sample of a recording is played, in dB, by the sample of the recording: the answer of the
/// playback plan, which is what the player follows. Samples that are not heard are not in it.
private func heardGains(_ project: Project, _ peaks: RecordingPeak) -> [UUID: [Range<Int>: Double]] {
    var gains: [UUID: [Range<Int>: Double]] = [:]
    for piece in project.clipPlaybackPlan(from: 0, peaks: peaks, voices: .none) {
        gains[piece.recordingID, default: [:]][piece.offset..<(piece.offset + piece.length)] = piece.gainDb
    }
    return gains
}

/// The volume one sample of a recording is played with, or nil when it is not heard.
private func heardGain(ofSample sample: Int, of recording: UUID, in project: Project, _ peaks: RecordingPeak) -> Double? {
    heardGains(project, peaks)[recording]?.first { $0.key.contains(sample) }?.value
}

private func close(_ value: Double?, _ expected: Double, within tolerance: Double = 1e-4) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

/// Each clip's volume and the safe limit, worked out with numbers alone.
@Suite("Clip volume and the safe limit")
struct ClipGainTests {
    // MARK: The applied gain

    @Test func theAppliedGainIsTheTotalWhenThereIsRoom() {
        // The clip peaks at -20 dBFS. Normalize asks for +5 and Max for +3: 8 dB, far from the limit.
        let (source, sound) = recording(at: 1, -20, -30)
        let clip = wholeClip(of: source, gainDb: 3, normalizeGainDb: 5)
        let applied = clip.appliedGain(peaks: peaks([source.id: sound]))
        #expect(applied == AppliedGain(askedDb: 8, db: 8))
        #expect(!applied.isHeldBack)
        #expect(applied.heldBackDb == 0)

        // Turning a clip down is never held back, however loud the recording is.
        let (loud, loudSound) = recording(at: 1, 0, 0)
        let down = wholeClip(of: loud, gainDb: -6).appliedGain(peaks: peaks([loud.id: loudSound]))
        #expect(down == AppliedGain(askedDb: -6, db: -6))

        // A silent clip has no peak to hold it back, and neither has one whose sound is not there.
        let silent = Recording(lengthSamples: 48_000, rawStart: 3)
        let quiet = wholeClip(of: silent, gainDb: 12, normalizeGainDb: 20)
        #expect(quiet.appliedGain(peaks: peaks([silent.id: [Float](repeating: 0, count: 48_000)])).db == 32)
        #expect(quiet.appliedGain(peaks: peaks([:])).db == 32)
    }

    @Test func aClipPeakingAtMinus3AskedFor6IsGiven2AndFlagged() {
        let (source, sound) = recording(at: 1, -3, -20)
        let clip = wholeClip(of: source, gainDb: 6)
        let applied = clip.appliedGain(peaks: peaks([source.id: sound]))
        #expect(applied.askedDb == 6)
        #expect(close(applied.db, 2))
        #expect(applied.isHeldBack)
        #expect(close(applied.heldBackDb, 4))
        // The loudest sample after the volume sits on -1 dBFS and not above it.
        #expect(close(20 * log10(Double(level(-3))) + applied.db, -1, within: 1e-9))

        // The same when the highest sample points downward, and when Normalize is what asks.
        let (below, belowSound) = recording(at: 3, -20, -3)
        let normalised = wholeClip(of: below, gainDb: -1, normalizeGainDb: 7)
        let held = normalised.appliedGain(peaks: peaks([below.id: belowSound]))
        #expect(close(held.db, 2))
        #expect(held.isHeldBack)

        // Exactly as far as it goes is not held back.
        let onTheLimit = wholeClip(of: source, gainDb: 2).appliedGain(peaks: peaks([source.id: sound]))
        #expect(!onTheLimit.isHeldBack)
        #expect(onTheLimit.db == 2)
    }

    @Test func theSafeLimitWithNumbersAlone() {
        #expect(Clip.appliedGain(askedDb: 6, peakDb: -3) == AppliedGain(askedDb: 6, db: 2))
        #expect(Clip.appliedGain(askedDb: 6, peakDb: -10) == AppliedGain(askedDb: 6, db: 6))
        #expect(Clip.appliedGain(askedDb: 6, peakDb: -.infinity) == AppliedGain(askedDb: 6, db: 6))
        // A recording that itself peaks above the limit is brought down to it, also at 0 dB.
        #expect(Clip.appliedGain(askedDb: 0, peakDb: -0.25) == AppliedGain(askedDb: 0, db: -0.75))
    }

    // MARK: Segments

    @Test func segmentGainsAdd() {
        // One clip of two parts, as after a join. The second part carries -6 dB of its own.
        let (first, firstSound) = recording(at: 1, -20, -20)
        let (second, secondSound) = recording(at: 3, -20, -20)
        let sounds = peaks([first.id: firstSound, second.id: secondSound])
        let clip = Clip(
            segments: [
                Segment(recordingID: first.id, inSample: 0, outSample: 48_000),
                Segment(recordingID: second.id, inSample: 0, outSample: 48_000, gainDb: -6),
            ],
            gainDb: 2,
            normalizeGainDb: 1
        )
        let project = song([first, second], [clip])

        // The clip's own part is 3 dB, and each piece adds its segment's.
        #expect(clip.appliedGain(peaks: sounds).db == 3)
        #expect(project.clipPlaybackPlan(from: 0, peaks: sounds, voices: .none).map(\.gainDb) == [3, -3])
        // Played from inside the second part, that part is as loud as from the start.
        #expect(project.clipPlaybackPlan(from: 150_000, peaks: sounds, voices: .none).map(\.gainDb) == [-3])
        // With nothing known about the sound, the volume asked for is what is played.
        #expect(project.clipPlaybackPlan(from: 0, voices: .none).map(\.gainDb) == [3, -3])
        // A clip that was never given a volume is played as recorded.
        #expect(song([first], [wholeClip(of: first)]).clipPlaybackPlan(from: 0, peaks: sounds, voices: .none).map(\.gainDb) == [0])
        #expect(ClipPiece(recordingID: first.id, offset: 0, startDelay: 0, length: 1).gain == 1)
        #expect(abs(ClipPiece(recordingID: first.id, offset: 0, startDelay: 0, length: 1, gainDb: -6).gain - 0.501) < 0.0005)
    }

    @Test func aSegmentsOwnGainCountsForTheClipsPeak() {
        // The loud part, at -3 dBFS, carries -6 dB of its own, so it reaches -9. The other part is at -20.
        let (loud, loudSound) = recording(at: 1, -3, -3)
        let (soft, softSound) = recording(at: 3, -20, -20)
        let sounds = peaks([loud.id: loudSound, soft.id: softSound])
        let clip = Clip(
            segments: [
                Segment(recordingID: loud.id, inSample: 0, outSample: 48_000, gainDb: -6),
                Segment(recordingID: soft.id, inSample: 0, outSample: 48_000),
            ],
            gainDb: 10
        )
        #expect(close(clip.peakDb(sounds), -9))
        // 8 dB is as far as the clip goes: the loud part then sits on -1 dBFS.
        let applied = clip.appliedGain(peaks: sounds)
        #expect(close(applied.db, 8))
        #expect(applied.isHeldBack)
        let gains = song([loud, soft], [clip]).clipPlaybackPlan(from: 0, peaks: sounds, voices: .none).map(\.gainDb)
        #expect(close(gains[0], 2))
        #expect(close(gains[1], 8))
    }

    // MARK: Split, cut and join of a clip that is held back

    @Test func aHeldBackClipSplitSoOnePieceLosesThePeakPlaysBothPiecesAsLoudAsBefore() throws {
        // The first half peaks at -3 dBFS and the second at -20. Asked for +6, the clip is given +2.
        let (source, sound) = recording(at: 2, -3, -20)
        let sounds = peaks([source.id: sound])
        var project = song([source], [wholeClip(of: source, gainDb: 6)])
        let id = project.tracks[0].clips[0].id
        let before = try #require(heardGain(ofSample: 100, of: source.id, in: project, sounds))
        #expect(close(before, 2))
        #expect(heardGain(ofSample: 40_000, of: source.id, in: project, sounds) == before)

        // Split where the loud half ends: the second piece no longer holds the peak.
        let split = project.splitClip(id, at: 2.5, peaks: sounds, voices: .none)
        let pieces = try #require(split)
        #expect(close(heardGain(ofSample: 100, of: source.id, in: project, sounds), before, within: 1e-9))
        #expect(close(heardGain(ofSample: 40_000, of: source.id, in: project, sounds), before, within: 1e-9))

        // Both pieces keep the volume Max set. The lowering is now their own, so neither is held back.
        for piece in [pieces.first, pieces.second] {
            let clip = try #require(project.clip(piece))
            #expect(clip.gainDb == 6)
            #expect(close(clip.segments[0].gainDb, -4))
            #expect(!clip.appliedGain(peaks: sounds).isHeldBack)
        }

        // Joined again, it is one segment again and still as loud.
        let joined = project.joinClips([pieces.first, pieces.second], peaks: sounds, voices: .none)
        let clip = try #require(joined.flatMap { project.clip($0) })
        #expect(clip.segments.count == 1)
        #expect(clip.segments[0].inSample == 0 && clip.segments[0].outSample == 48_000)
        #expect(close(heardGain(ofSample: 100, of: source.id, in: project, sounds), before, within: 1e-9))
        #expect(close(heardGain(ofSample: 40_000, of: source.id, in: project, sounds), before, within: 1e-9))
    }

    @Test func aSplitWithoutThePeaksWouldLetTheQuietPieceLouder() throws {
        // What the peaks are handed in for: the same split without them leaves the second piece 4 dB louder.
        let (source, sound) = recording(at: 2, -3, -20)
        let sounds = peaks([source.id: sound])
        var project = song([source], [wholeClip(of: source, gainDb: 6)])
        let split = project.splitClip(project.tracks[0].clips[0].id, at: 2.5, voices: .none)
        #expect(split != nil)
        #expect(close(heardGain(ofSample: 100, of: source.id, in: project, sounds), 2))
        #expect(close(heardGain(ofSample: 40_000, of: source.id, in: project, sounds), 6))
    }

    @Test func aClipThatIsNotHeldBackIsSplitWithItsSegmentsLeftAsTheyWere() throws {
        let (source, sound) = recording(at: 2, -20, -30)
        let sounds = peaks([source.id: sound])
        var project = song([source], [wholeClip(of: source, gainDb: 6, normalizeGainDb: 3)])
        let split = project.splitClip(project.tracks[0].clips[0].id, at: 2.5, peaks: sounds, voices: .none)
        let pieces = try #require(split)
        for piece in [pieces.first, pieces.second] {
            let clip = try #require(project.clip(piece))
            #expect(clip.gainDb == 6 && clip.normalizeGainDb == 3)
            #expect(clip.segments.map(\.gainDb) == [0])
        }
        #expect(heardGains(project, sounds)[source.id]?.values.allSatisfy { $0 == 9 } == true)
    }

    @Test func aCutThatTakesThePeakAwayLeavesTheRestAsLoudAsItWas() throws {
        // The loud first half is deleted from a clip that was held back by it.
        let (source, sound) = recording(at: 2, -3, -20)
        let sounds = peaks([source.id: sound])
        var project = song([source], [wholeClip(of: source, gainDb: 6)])
        let before = try #require(heardGain(ofSample: 40_000, of: source.id, in: project, sounds))
        #expect(close(before, 2))
        let left = project.cut(range: 1.5..<2.5, onTrack: project.tracks[0].id, peaks: sounds, voices: .none)
        #expect(left?.count == 1)
        #expect(heardGain(ofSample: 100, of: source.id, in: project, sounds) == nil)
        #expect(close(heardGain(ofSample: 40_000, of: source.id, in: project, sounds), before, within: 1e-9))

        // A waiting take that is cut along with it keeps its own volume in the same way.
        let firstTake = wholeClip(of: source, gainDb: 6)
        var secondTake = wholeClip(of: source, gainDb: 9)
        secondTake.line = firstTake.line
        var takes = song([source], [firstTake, secondTake])
        takes.normalizeTakes()
        let waiting = try #require(takes.tracks[0].clips.first { !$0.isActiveTake }).id
        let leftOfTakes = takes.cut(range: 1.5..<2.5, onTrack: takes.tracks[0].id, peaks: sounds, voices: .none)
        #expect(leftOfTakes?.count == 2)
        takes.setActiveTake(waiting)
        #expect(close(heardGain(ofSample: 40_000, of: source.id, in: takes, sounds), before, within: 1e-9))
    }

    @Test func aJoinKeepsEveryPartAsLoudAsItWasHeldBackOrNot() throws {
        // The first clip is held back from +6 to +2. The second has room for its +3.
        let (loud, loudSound) = recording(at: 1, -3, -20)
        let (soft, softSound) = recording(at: 3, -20, -20)
        let sounds = peaks([loud.id: loudSound, soft.id: softSound])
        let first = wholeClip(of: loud, gainDb: 6)
        let second = wholeClip(of: soft, gainDb: 1, normalizeGainDb: 2)

        var project = song([loud, soft], [first, second])
        let before = try #require(heardGain(ofSample: 100, of: loud.id, in: project, sounds))
        #expect(close(before, 2))
        var joinedID = project.joinClips([first.id, second.id], peaks: sounds, voices: .none)
        var joined = try #require(joinedID.flatMap { project.clip($0) })
        #expect(close(heardGain(ofSample: 100, of: loud.id, in: project, sounds), before, within: 1e-9))
        #expect(close(heardGain(ofSample: 100, of: soft.id, in: project, sounds), 3, within: 1e-9))
        // The joined clip keeps the first clip's volume and is not held back.
        #expect(joined.gainDb == 6 && joined.normalizeGainDb == nil)
        #expect(!joined.appliedGain(peaks: sounds).isHeldBack)

        // The other way round: the clip that is held back comes second.
        let early = Recording(id: soft.id, lengthSamples: 48_000, rawStart: 0)
        project = song([loud, early], [second, first])
        joinedID = project.joinClips([first.id, second.id], peaks: sounds, voices: .none)
        joined = try #require(joinedID.flatMap { project.clip($0) })
        #expect(close(heardGain(ofSample: 100, of: loud.id, in: project, sounds), before, within: 1e-9))
        #expect(close(heardGain(ofSample: 100, of: soft.id, in: project, sounds), 3, within: 1e-9))
        #expect(joined.gainDb == 1 && joined.normalizeGainDb == 2)
        #expect(!joined.appliedGain(peaks: sounds).isHeldBack)
    }
}

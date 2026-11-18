import Foundation
import Synchronization
import Testing
import LockstepCore
@testable import LockstepAudio

@Suite(.serialized) struct BeatFinderTests {
    // MARK: Refitting from what was kept (no model needed)

    /// What beat finding would keep for a made-up song: 100 beats 0.6 s apart from 1.003 s,
    /// with a sharp onset exactly on every beat. The model's beats are rounded to its 20 ms
    /// frames and it reports a bar start on every fourth beat, starting with beat 2.
    private static let period = 0.6
    private static func trueTime(ofBeat number: Int) -> Double { 1.003 + period * Double(number) }

    private static let cache: BeatCache = {
        let times = (0..<100).map(trueTime(ofBeat:))
        var onsets = [Float](repeating: 0, count: Int(62.0 * 1_500))
        for time in times { onsets[Int((time * 1_500).rounded())] = 8 }
        let modelBeats = times.map { ($0 * 50).rounded() / 50 }
        let modelBarStarts = stride(from: 2, to: 100, by: 4).map { modelBeats[$0] }
        return BeatCache(
            model: BeatModelOutput(logits: [], beats: modelBeats, barStarts: modelBarStarts),
            onsets: OnsetCurve(values: onsets)
        )
    }()

    private func refit(
        settings: BeatSettings = .defaults,
        anchors: [Anchor] = [],
        tempoLevel: TempoLevel = .normal,
        beatOne: Double? = nil
    ) -> Grid {
        BeatFinder.refit(cache: Self.cache, settings: settings, anchors: anchors, tempoLevel: tempoLevel, beatOne: beatOne)
    }

    private func beat(_ grid: Grid, near time: Double) throws -> Beat {
        try #require(grid.beat(nearest: time))
    }

    @Test func aRefitPutsEveryBeatOnItsOnsetAndFindsTheBars() {
        let grid = refit()

        #expect(grid.beats.count == 100)
        for (number, beat) in grid.beats.enumerated() {
            // An onset value stands every 0.67 ms, so that is how close a beat can be.
            #expect(abs(beat.time - Self.trueTime(ofBeat: number)) < 0.001)
            #expect(!beat.estimated)
        }
        #expect(grid.barStartNumber == 2)
        #expect(grid.tempoLevel == .normal)
        #expect(grid.anchors.isEmpty && grid.beatOne == nil)
        #expect(grid.tempo(at: 30) == 100.0)
    }

    @Test func halveTempoFollowedByADraggedBeatStaysHalved() throws {
        let halved = refit(tempoLevel: .halved)
        #expect(halved.beats.count == 50)
        // Max drags a beat of the halved grid 30 ms later.
        let dragged = halved.beats[20]
        let anchor = Anchor(from: dragged.time, to: dragged.time + 0.030)

        let grid = refit(anchors: [anchor], tempoLevel: .halved)

        #expect(grid.tempoLevel == .halved)
        #expect(grid.beats.count == 50)
        #expect(grid.anchors == [anchor])
        #expect(grid.beats[20].time == anchor.to)
        // Every second beat: 1.2 s apart away from the dragged one.
        #expect(abs(grid.beats[41].time - grid.beats[40].time - 1.2) < 0.002)
    }

    @Test func thisIsBeatOneFollowedByAChangeOfSmoothingKeepsThatBeat() throws {
        // The model's bar starts say beats 2, 6, 10 and so on. Max says beat 21.
        let chosen = Self.trueTime(ofBeat: 21)
        let before = refit(beatOne: chosen)
        #expect(before.barStartNumber == 21)

        let grid = refit(settings: BeatSettings(smoothingBeats: 9), beatOne: chosen)

        #expect(grid.beatOne == chosen)
        #expect(grid.isBarStart(try beat(grid, near: chosen).number))
        #expect(grid.isBarStart(21) && !grid.isBarStart(22))
        // And through a change of tempo level, in both directions.
        for level in [TempoLevel.halved, .doubled] {
            let other = refit(tempoLevel: level, beatOne: chosen)
            #expect(other.isBarStart(try beat(other, near: chosen).number))
            #expect(abs(try beat(other, near: chosen).time - chosen) < 0.001)
        }
    }

    @Test func anAnchorMadeBeforeHalvingStillHoldsItsBeatAfterHalving() throws {
        // Beat 10 is a bar start, so halving keeps it.
        let from = refit().beats[10].time
        let anchor = Anchor(from: from, to: from - 0.025)
        let normal = refit(anchors: [anchor])
        #expect(normal.beats[10].time == anchor.to)
        #expect(!normal.beats[10].estimated)
        // Its neighbours follow part of the way, and beats far off stay.
        #expect(normal.beats[11].time < Self.trueTime(ofBeat: 11) - 0.005)
        #expect(abs(normal.beats[30].time - Self.trueTime(ofBeat: 30)) < 0.001)

        let halved = refit(anchors: [anchor], tempoLevel: .halved)

        let held = try beat(halved, near: anchor.to)
        #expect(held.time == anchor.to)
        #expect(halved.isBarStart(held.number))
        #expect(halved.anchors == [anchor])
    }

    /// What happens to an anchor whose beat is not in the grid at the tempo level shown.
    @Test func anAnchorOnABeatThatHalvingDropsStillPullsItsNeighbours() throws {
        // Beat 11 is not kept by halving (kept: 2, 4, 6 and so on, counted from a bar start).
        let from = refit().beats[11].time
        let anchor = Anchor(from: from, to: from + 0.040)

        let halved = refit(anchors: [anchor], tempoLevel: .halved)

        #expect(try beat(halved, near: anchor.to).time != anchor.to)
        // Beats 10 and 12 are shown, and each was pulled along by the anchor between them.
        #expect(try beat(halved, near: Self.trueTime(ofBeat: 10)).time > Self.trueTime(ofBeat: 10) + 0.01)
        #expect(try beat(halved, near: Self.trueTime(ofBeat: 12)).time > Self.trueTime(ofBeat: 12) + 0.01)
        // Back at the normal level the beat is exactly where Max put it.
        #expect(refit(anchors: [anchor]).beats[11].time == anchor.to)
    }

    @Test func aHalfwayBeatDraggedAtDoubleTempoGoesWhereItWasDragged() throws {
        let doubled = refit(tempoLevel: .doubled)
        #expect(doubled.beats.count == 199)
        // Beat 41 of the doubled grid is halfway between the fitted beats 20 and 21.
        let halfway = doubled.beats[41]
        #expect(abs(halfway.time - (Self.trueTime(ofBeat: 20) + 0.3)) < 0.001)
        let anchor = Anchor(from: halfway.time, to: halfway.time + 0.050)

        let grid = refit(anchors: [anchor], tempoLevel: .doubled)

        #expect(grid.beats[41].time == anchor.to)
        #expect(!grid.beats[41].estimated)
        // The fitted beats either side are on their own drum hits and do not move.
        #expect(grid.beats[40] == doubled.beats[40])
        #expect(grid.beats[42] == doubled.beats[42])
        // Dragged too far, it stops a quarter of the way from its neighbour.
        let tooFar = refit(anchors: [Anchor(from: halfway.time, to: halfway.time + 0.5)], tempoLevel: .doubled)
        #expect(abs(tooFar.beats[41].time - (doubled.beats[42].time - 0.15)) < 0.001)
        // At the normal level that beat does not exist, and nothing else is moved by its anchor.
        #expect(refit(anchors: [anchor]).beats == refit().beats)
    }

    @Test func theSettingsReachTheFit() {
        // A cache whose model missed five beats in a row.
        var modelBeats = Self.cache.model.beats
        modelBeats.removeSubrange(50..<55)
        let cache = BeatCache(
            model: BeatModelOutput(logits: [], beats: modelBeats, barStarts: Self.cache.model.barStarts),
            onsets: Self.cache.onsets
        )
        func count(maxGapBeats: Int) -> Int {
            BeatFinder.refit(
                cache: cache, settings: BeatSettings(maxGapBeats: maxGapBeats),
                anchors: [], tempoLevel: .normal, beatOne: nil
            ).beats.count
        }
        #expect(count(maxGapBeats: 32) == 100)
        #expect(count(maxGapBeats: 4) == 95)
        #expect(BeatSettings.defaults == BeatSettings(maxGapBeats: 32, smoothingBeats: 17))
    }

    // MARK: The limit, and trying again less strictly

    /// What beat finding would keep for a made-up song of 150 beats, 0.6 s apart from 0.4 s, with
    /// a drum hit on every beat: the model's value on each beat as `value` gives it, and -8 between.
    private static func keptForASong(_ value: (Int) -> Float) -> BeatCache {
        var logits = [Float](repeating: -8, count: 2 * 4_600)
        var onsets = [Float](repeating: 0, count: Int(92.0 * 1_500))
        for number in 0..<150 {
            let step = 20 + 30 * number
            logits[2 * step] = value(number)
            // Every fourth beat starts a bar, and the model is as sure of that as of the beat.
            logits[2 * step + 1] = number % 4 == 0 ? value(number) : -8
            onsets[step * 30] = 8
        }
        return BeatCache(model: BeatModelOutput(logits: logits), onsets: OnsetCurve(values: onsets))
    }

    @Test func aQuietStretchGetsItsBeatsFromALooserTryAndIsShownAsUncertain() throws {
        // Beats 50 to 94 are too weak for the limit, and 45 beats are too many to fill in.
        let cache = Self.keptForASong { (50..<95).contains($0) ? -0.6 : 5 }
        #expect(cache.model.beats.count == 105)
        #expect(BeatLevel.force(cache.model.beats).count == 105)

        let grid = BeatFinder.refit(cache: cache, settings: .defaults, anchors: [], tempoLevel: .normal, beatOne: nil)

        #expect(grid.beats.map(\.number) == Array(0..<150))
        #expect(grid.beats.filter(\.estimated).map(\.number) == Array(50..<95))
        #expect(BeatFinder.loosenedBeatCount(cache: cache, settings: .defaults) == 45)
        // Each of them sits on its drum hit, like the beats the model was sure of.
        for beat in grid.beats {
            #expect(abs(beat.time - (0.4 + 0.6 * Double(beat.number))) < 0.001)
        }
        // The window draws the stretch as one it is unsure of.
        #expect(BeatRefiner.uncertainRanges(in: grid.beats) == [grid.beats[50].time...grid.beats[94].time])
        // What Max corrected holds through it, as in every refit.
        let anchor = Anchor(from: grid.beats[70].time, to: grid.beats[70].time + 0.03)
        let corrected = BeatFinder.refit(
            cache: cache, settings: .defaults, anchors: [anchor], tempoLevel: .halved, beatOne: grid.beats[70].time
        )
        #expect(corrected.beats.count == 75)
        #expect(try beat(corrected, near: anchor.to).time == anchor.to)
        #expect(corrected.isBarStart(try beat(corrected, near: anchor.to).number))
    }

    @Test func theLimitFromSettingsReachesTheFit() {
        // The model is only a little sure of the last 30 beats.
        let cache = Self.keptForASong { $0 < 120 ? 5 : 0.6 }
        func count(limit: Double) -> Int {
            BeatFinder.refit(
                cache: cache, settings: BeatSettings(certaintyLimit: limit),
                anchors: [], tempoLevel: .normal, beatOne: nil
            ).beats.count
        }
        #expect(count(limit: 0) == 150)
        #expect(count(limit: 0.5) == 150)
        #expect(count(limit: 1) == 120)
        #expect(BeatSettings.defaults.certaintyLimit == 0)
    }

    /// The 70 second test sound's values, as the original model gave them.
    @Test func theStartingLimitGivesTodaysBeatsOnTheReferenceValues() throws {
        let model = BeatModelOutput(logits: try BeatFixture.reference.logits())
        #expect(model.beats.count == (try BeatFixture.reference.picked()).beats.count)
        let cache = BeatCache(model: model, onsets: OnsetCurve(values: [Float](repeating: 0, count: 105_000)))

        let picked = model.picked(limit: 0, maxGapBeats: 32)
        let grid = BeatFinder.refit(cache: cache, settings: .defaults, anchors: [], tempoLevel: .normal, beatOne: nil)

        // What was done before there was a limit: the beats above 0, at one beat level.
        let today = BeatLevel.force(model.beats)
        #expect(picked.beats == today)
        #expect(picked.loosened.isEmpty)
        let refined = BeatRefiner.refine(beats: today, onsetValues: cache.onsets.values, onsetTimes: cache.onsets.times)
        var expected = Grid(beats: refined.beats)
        expected.setBarStart(fromModelBarStarts: model.barStarts)
        #expect(grid == expected)
    }

    @Test func phasesHaveTheNamesTheWindowShows() {
        #expect(BeatFinder.Phase.listening.name == "Listening")
        #expect(BeatFinder.Phase.findingBeats.name == "Finding beats")
        #expect(BeatFinder.Phase.liningUp.name == "Lining up")
    }

    // MARK: The whole chain

    @Test func aMissingModelIsReportedAsNotInstalled() async {
        let song = ImportedSong(samples: [Float](repeating: 0, count: 9_600), lengthSamples: 4_800)
        await #expect(throws: BeatModelError.notInstalled) {
            _ = try await BeatFinder.findBeats(in: song, modelURL: URL(filePath: "/nonexistent/lockstep-test/BeatThis.mlpackage"))
        }
    }

    /// Needs the installed model. A made-up drum pattern at the app's own 48,000 Hz, 40 seconds
    /// at 120 beats per minute: a thump on every beat, a tick between beats, a noise burst on
    /// beats 2 and 4.
    @Test func findsTheBeatsOfADrumPattern() async throws {
        try #require(FileManager.default.fileExists(atPath: BeatModel.installedURL.path), "Run Scripts/install-beat-model.sh first.")
        let rate = 48_000.0
        let firstBeat = 0.25
        var mono = [Float](repeating: 0, count: Int(40 * rate))
        var noise = SystemRandomNumberGenerator()
        func add(at seconds: Double, length: Double, _ shape: (Double) -> Double) {
            let start = Int((seconds * rate).rounded())
            for index in 0..<Int(length * rate) where start + index < mono.count {
                mono[start + index] += Float(shape(Double(index) / rate))
            }
        }
        for number in 0..<80 {
            let time = firstBeat + 0.5 * Double(number)
            add(at: time, length: 0.25) { (t: Double) -> Double in
                let sweep: Double = 50 * t + (100.0 / 30) * (1 - exp(-30 * t))
                let thump: Double = 0.4 * sin(2 * Double.pi * sweep) * exp(-t * 18)
                let snap: Double = 0.12 * sin(2 * Double.pi * 2_500 * t) * exp(-t * 900)
                return thump + snap
            }
            add(at: time + 0.25, length: 0.03) { (t: Double) -> Double in
                let tone: Double = sin(2 * Double.pi * 6_000 * t)
                return 0.08 * tone * exp(-t * 250)
            }
            if number % 2 == 1 {
                add(at: time, length: 0.12) { (t: Double) -> Double in
                    let hiss = Double.random(in: -1...1, using: &noise)
                    return 0.16 * hiss * exp(-t * 35)
                }
            }
        }
        let song = ImportedSong(samples: mono.flatMap { [$0, $0] }, lengthSamples: mono.count)
        let reported = Mutex<[BeatFinder.Progress]>([])

        let found = try await BeatFinder.findBeats(in: song) { progress in reported.withLock { $0.append(progress) } }

        let beats = found.grid.beats
        print("Drum pattern: \(beats.count) beats, \(beats.filter(\.estimated).count) estimated, first at \(beats.first?.time ?? -1)")
        // The model may miss the very first or the very last thump, where it hears no surroundings.
        #expect(beats.count >= 78 && beats.count <= 80)
        for beat in beats {
            // Each beat line sits on a thump: within 3 ms of a multiple of half a second after the first.
            let sinceFirst = beat.time - firstBeat
            let offBy = abs(sinceFirst - (sinceFirst / 0.5).rounded() * 0.5)
            #expect(offBy < 0.003, "beat \(beat.number) at \(beat.time)")
        }
        #expect(found.grid.tempo(at: 20) == 120.0)
        // What is kept is enough to build the same grid again.
        #expect(found.cache.model.frameCount == 2_001)
        #expect(found.cache.onsets.values.count == 1 + mono.count / 32)
        #expect(BeatFinder.refit(cache: found.cache, settings: .defaults, anchors: [], tempoLevel: .normal, beatOne: nil) == found.grid)

        // Progress: the three phases in order, never going back, ending at 1.
        let progress = reported.withLock { $0 }
        #expect(progress.first == BeatFinder.Progress(phase: .listening, fraction: 0))
        #expect(progress.last == BeatFinder.Progress(phase: .liningUp, fraction: 1))
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        var phases: [BeatFinder.Phase] = []
        for step in progress where step.phase != phases.last { phases.append(step.phase) }
        #expect(phases == [.listening, .findingBeats, .liningUp])
    }

    /// Needs the installed model. A made-up song whose drums almost vanish under a held chord
    /// for 45 beats in the middle. With holes of more than four beats left open, the beats the
    /// model was sure of leave a hole there, and the looser tries find the weak beats in it.
    @Test func theWeakBeatsOfAQuietStretchAreFoundInARealSound() async throws {
        try #require(FileManager.default.fileExists(atPath: BeatModel.installedURL.path), "Run Scripts/install-beat-model.sh first.")
        let sound = MadeUpSound.drumsThatGoQuiet()
        try sound.writeIfAsked(as: "quiet-stretch.wav")
        let settings = BeatSettings(maxGapBeats: 4)

        let found = try await BeatFinder.findBeats(in: sound.song, settings: settings)

        let sure = BeatLevel.force(found.cache.model.beats, maxGapBeats: settings.maxGapBeats)
        let loosened = BeatFinder.loosenedBeatCount(cache: found.cache, settings: settings)
        let beats = found.grid.beats
        let holes = zip(beats, beats.dropFirst()).filter { $1.number != $0.number + 1 }.count
        let uncertain = BeatRefiner.uncertainRanges(in: beats)
        print("Quiet stretch: \(sure.count) beats from the limit alone, \(beats.count) with the looser tries, \(loosened) of them loosened, \(beats.filter(\.estimated).count) estimated, \(holes) holes, uncertain stretches: \(uncertain)")
        #expect(loosened >= 5)
        #expect(beats.count > sure.count)
        for beat in beats {
            // Every beat, the weak ones too, is on a drum hit: a hit comes every 0.6 s from 0.3 s.
            let sinceFirst = beat.time - 0.3
            let offBy = abs(sinceFirst - (sinceFirst / 0.6).rounded() * 0.6)
            #expect(offBy < 0.045, "beat \(beat.number) at \(beat.time)")
        }
    }

    /// Needs the installed model. Hiss has no beat, and no limit finds one in it.
    @Test func aSoundWithoutABeatGetsNoBeatsAtAnyLimit() async throws {
        try #require(FileManager.default.fileExists(atPath: BeatModel.installedURL.path), "Run Scripts/install-beat-model.sh first.")
        let sound = MadeUpSound.hiss()
        try sound.writeIfAsked(as: "no-beat.wav")

        let found = try await BeatFinder.findBeats(in: sound.song)

        #expect(found.grid.beats.isEmpty)
        let loosest = BeatSettings(certaintyLimit: SettingKey<Double>.certaintyLimit.range?.lowerBound ?? 0)
        #expect(BeatFinder.refit(cache: found.cache, settings: loosest, anchors: [], tempoLevel: .normal, beatOne: nil).beats.isEmpty)
    }

    @Test func cancellingStopsTheSearch() async throws {
        try #require(FileManager.default.fileExists(atPath: BeatModel.installedURL.path), "Run Scripts/install-beat-model.sh first.")
        let song = ImportedSong(samples: [Float](repeating: 0, count: 2 * 48_000 * 70), lengthSamples: 48_000 * 70)
        let task = Task {
            try await BeatFinder.findBeats(in: song) { progress in
                // Another song is dropped as soon as the model has started on this one.
                if progress.phase == .findingBeats { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    /// Max's reference song, when the test is given the file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCKSTEP_SONG"] != nil))
    func findsTheBeatsOfTheReferenceSong() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCKSTEP_SONG"]!)
        let song = try await SongImporter.importSong(from: url)
        let clock = ContinuousClock()
        let start = clock.now
        let found = try await BeatFinder.findBeats(in: song)
        let taken = clock.now - start

        let beats = found.grid.beats
        let spacings = zip(beats.dropFirst(), beats).filter { $0.number == $1.number + 1 }.map { $0.time - $1.time }
        let gaps = zip(beats.dropFirst(), beats).filter { $0.number != $1.number + 1 }.count
        let refitStart = clock.now
        let again = BeatFinder.refit(cache: found.cache, settings: .defaults, anchors: [], tempoLevel: .normal, beatOne: nil)
        let refitTaken = clock.now - refitStart
        print("""
            Beats of \(song.duration) s of song, found in \(taken) (a refit takes \(refitTaken)):
            \(found.cache.model.beats.count) beats and \(found.cache.model.barStarts.count) bar starts from the model,
            \(beats.count) beats in the grid from \(beats.first?.time ?? 0) s to \(beats.last?.time ?? 0) s, \(beats.filter(\.estimated).count) estimated, \(gaps) gaps left empty,
            spacing from \(spacings.min() ?? 0) to \(spacings.max() ?? 0) s, bar start at beat \(found.grid.barStartNumber),
            tempo \(found.grid.tempo(at: 10) ?? 0) at 10 s, \(found.grid.tempo(at: 100) ?? 0) at 100 s, \(found.grid.tempo(at: 200) ?? 0) at 200 s,
            uncertain stretches: \(BeatRefiner.uncertainRanges(in: beats))
            """)
        #expect(again == found.grid)
        #expect(beats.count > 290 && beats.count < 330)
        // Nothing in this song needs a looser try, so its beats are the ones found before there was one.
        #expect(BeatFinder.loosenedBeatCount(cache: found.cache, settings: .defaults) == 0)
        #expect(beats.map(\.number) == BeatLevel.force(found.cache.model.beats).map(\.number))
        for limit in [1.5, 0.75, -0.75, -1.5] {
            let other = BeatFinder.refit(
                cache: found.cache, settings: BeatSettings(certaintyLimit: limit), anchors: [], tempoLevel: .normal, beatOne: nil
            )
            print("With the limit at \(limit): \(other.beats.count) beats, \(other.beats.filter(\.estimated).count) estimated, from \(other.beats.first?.time ?? 0) s to \(other.beats.last?.time ?? 0) s, \(BeatRefiner.uncertainRanges(in: other.beats).count) uncertain stretches")
        }
        #expect(refitTaken < .seconds(1))
    }
}

/// Sounds made up for the tests that run the beat model, at the app's own 48,000 Hz. They are
/// the same on every run. Nothing is played.
///
/// To open one in the app, run these tests with `LOCKSTEP_BEAT_SOUNDS` naming a folder: each
/// sound is then also written there as a WAV file.
private struct MadeUpSound {
    static let rate = 48_000.0

    var mono: [Float]
    /// Gives numbers between -1 and 1 that are the same on every run.
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    var song: ImportedSong {
        ImportedSong(samples: mono.flatMap { [$0, $0] }, lengthSamples: mono.count)
    }

    init(seconds: Double) {
        mono = [Float](repeating: 0, count: Int(seconds * Self.rate))
    }

    /// 70 seconds at 100 beats a minute under a held chord. The drums play at full strength,
    /// then at 3 % of it for beats 33 to 77, then at full strength again.
    static func drumsThatGoQuiet() -> MadeUpSound {
        var sound = MadeUpSound(seconds: 70)
        sound.addChord(level: 0.25)
        sound.addDrums(from: 0.3, to: 20, level: 1)
        sound.addDrums(from: 0.3 + 0.6 * 33, to: 0.3 + 0.6 * 78, level: 0.03)
        sound.addDrums(from: 0.3 + 0.6 * 78, to: 69.5, level: 1)
        return sound
    }

    /// 40 seconds of hiss.
    static func hiss() -> MadeUpSound {
        var sound = MadeUpSound(seconds: 40)
        for index in sound.mono.indices { sound.mono[index] = Float(0.1 * sound.roll()) }
        return sound
    }

    func writeIfAsked(as name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["LOCKSTEP_BEAT_SOUNDS"] else { return }
        try WavWriter.write(song.samples, channels: 2, to: URL(filePath: folder).appending(path: name))
    }

    private mutating func roll() -> Double {
        Self.roll(&seed)
    }

    private static func roll(_ seed: inout UInt64) -> Double {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Double(seed % 2_000_001) / 1_000_000 - 1
    }

    private mutating func add(at seconds: Double, length: Double, _ shape: (Double) -> Double) {
        let start = Int((seconds * Self.rate).rounded())
        for index in 0..<Int(length * Self.rate) where mono.indices.contains(start + index) {
            mono[start + index] += Float(shape(Double(index) / Self.rate))
        }
    }

    /// A thump on every beat (a beat every 0.6 s), a tick between beats, and a burst of noise
    /// on every second beat.
    private mutating func addDrums(from: Double, to: Double, level: Double) {
        var number = 0
        var time = from
        while time < to {
            add(at: time, length: 0.25) { t in
                let sweep = 50 * t + (100.0 / 30) * (1 - exp(-30 * t))
                let thump = 0.4 * sin(2 * Double.pi * sweep) * exp(-t * 18)
                let snap = 0.12 * sin(2 * Double.pi * 2_500 * t) * exp(-t * 900)
                return level * (thump + snap)
            }
            add(at: time + 0.3, length: 0.03) { t in level * 0.08 * sin(2 * Double.pi * 6_000 * t) * exp(-t * 250) }
            if number % 2 == 1 {
                // Every burst is the same noise.
                var noise = seed
                add(at: time, length: 0.12) { t in level * 0.16 * Self.roll(&noise) * exp(-t * 35) }
            }
            number += 1
            time = from + 0.6 * Double(number)
        }
    }

    /// Five held tones that swell slowly, each at its own pace, and a little hiss.
    private mutating func addChord(level: Double) {
        let tones = [110.0, 164.8, 220.0, 277.2, 329.6]
        for index in mono.indices {
            let t = Double(index) / Self.rate
            var value = 0.0
            for (number, tone) in tones.enumerated() {
                let swell = 0.6 + 0.4 * sin(2 * Double.pi * (0.07 + 0.013 * Double(number)) * t)
                value += sin(2 * Double.pi * tone * t + Double(number)) * swell
            }
            mono[index] += Float(level * (value / 5 + 0.05 * roll()))
        }
    }
}

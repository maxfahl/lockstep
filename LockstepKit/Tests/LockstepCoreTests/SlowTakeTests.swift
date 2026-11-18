import Foundation
import Testing
@testable import LockstepCore

/// So many milliseconds as samples at 48,000 Hz.
private func ms(_ milliseconds: Double) -> Int {
    Int((milliseconds * 48).rounded())
}

/// A song whose tempo drifts, as in a song made by Suno: beat `n` is at `0.5 + 0.6 n + 0.002 n²` seconds, and
/// every fourth beat from beat 0 starts a bar.
private func driftingGrid(beats count: Int = 64) -> Grid {
    Grid(
        beats: (0..<count).map { Beat(number: $0, time: 0.5 + 0.6 * Double($0) + 0.002 * Double($0 * $0)) },
        barStartNumber: 0
    )
}

/// The key frames of a plan with the start and the end of the take around them.
private func allPoints(of plan: SpeedUpPlan) -> [SpeedUpPlan.Point] {
    [SpeedUpPlan.Point(source: 0, target: 0)] + plan.points
        + [SpeedUpPlan.Point(source: plan.sourceLength, target: plan.targetLength)]
}

@Suite("Slow time")
struct SlowTimeTests {
    @Test("A song time and its slow time go there and back, also before the song", arguments: [85, 90])
    func thereAndBack(percent: Int) {
        let slow = SlowTime(percent: percent)
        let rate = Double(percent) / 100
        #expect(slow.rate == rate)
        #expect(slow.isSlow)
        for seconds in [0, 0.5, 12.3456, 211.9, -1.2, -0.0001] {
            #expect(abs(slow.slowSeconds(forSong: seconds) - seconds / rate) < 1e-12)
            #expect(abs(slow.songSeconds(forSlow: slow.slowSeconds(forSong: seconds)) - seconds) < 1e-12)
        }
        // A count-in that starts 1.2 slow seconds before the song starts so much earlier in song time.
        #expect(abs(slow.songSeconds(forSlow: -1.2) - -1.2 * rate) < 1e-12)
    }

    @Test("At 100 % nothing is slow and nothing changes")
    func fullSpeedChangesNothing() {
        let full = SlowTime(percent: 100)
        let grid = driftingGrid()
        let place = SongPlace(cutStartSamples: 48_000, cutEndSamples: 96_000, zeroSample: 24_000)
        #expect(!full.isSlow)
        #expect(full.slowSeconds(forSong: 12.5) == 12.5)
        #expect(full.slowed(grid) == grid)
        #expect(full.slowLength(ofSong: 9_000_001) == 9_000_001)
        #expect(full.slowed(place, songLengthSamples: 9_000_000) == place)
    }

    @Test("A rate that is no speed counts as full speed, and none is slower than half")
    func ratesAreHeld() {
        #expect(SlowTime(rate: .nan).rate == 1)
        #expect(SlowTime(rate: 1.4).rate == 1)
        #expect(SlowTime(rate: 0.1).rate == 0.5)
        #expect(SlowTime(rate: 0.85).rate == 0.85)
    }

    @Test("Every beat of the slowed grid is at its time divided by the rate, and still the same beat")
    func slowedGrid() {
        var grid = driftingGrid()
        grid.anchors = [Anchor(from: 3.1, to: 3.2)]
        grid.beatOne = 2.9
        grid.beats[5].estimated = true
        let slowed = SlowTime(percent: 85).slowed(grid)
        #expect(slowed.beats.count == grid.beats.count)
        for (slow, beat) in zip(slowed.beats, grid.beats) {
            #expect(slow.number == beat.number)
            #expect(slow.estimated == beat.estimated)
            #expect(abs(slow.time - beat.time / 0.85) < 1e-12)
        }
        #expect(slowed.barStartNumber == grid.barStartNumber)
        #expect(slowed.tempoLevel == grid.tempoLevel)
        #expect(abs(slowed.anchors[0].from - 3.1 / 0.85) < 1e-12)
        #expect(abs(slowed.anchors[0].to - 3.2 / 0.85) < 1e-12)
        #expect(abs((slowed.beatOne ?? 0) - 2.9 / 0.85) < 1e-12)
    }

    @Test("The count-in made on the slowed beats is the song's count-in, slower, also where it starts before the song")
    func countInOnTheSlowedGrid() {
        let grid = driftingGrid()
        let slow = SlowTime(percent: 85)
        // Beat 2 has only two beats before it, so a count-in of one bar starts before the song. Beat 20 has room.
        for beat in [2, 20] {
            let place = grid.beats[beat].time
            let song = RecordingPlacement.countIn(to: place, bars: 1, grid: grid)
            let slowed = RecordingPlacement.countIn(
                to: slow.slowSeconds(forSong: place), bars: 1, grid: slow.slowed(grid))
            #expect(slowed.clicks.count == song.clicks.count)
            #expect(abs(slow.songSeconds(forSlow: slowed.start) - song.start) < 1e-9)
            for (slowClick, click) in zip(slowed.clicks, song.clicks) {
                #expect(slowClick.kind == click.kind)
                #expect(abs(slow.songSeconds(forSlow: slowClick.time) - click.time) < 1e-9)
            }
        }
        #expect(RecordingPlacement.countIn(to: grid.beats[2].time, bars: 1, grid: grid).start < 0)
    }

    @Test("The slowed song is its length divided by the rate, and its cut and its 00:00 lie on the same moments")
    func slowedLengthAndPlace() {
        let slow = SlowTime(percent: 85)
        let length = 10_080_000   // three and a half minutes
        let slowLength = slow.slowLength(ofSong: length)
        #expect(slowLength == Int((Double(length) / 0.85).rounded()))

        let place = SongPlace(cutStartSamples: 480_000, cutEndSamples: 960_000, zeroSample: 240_000)
        let slowed = slow.slowed(place, songLengthSamples: length)
        let kept = place.keptSamples(ofLength: length)
        let slowKept = slowed.keptSamples(ofLength: slowLength)
        #expect(slowKept.lowerBound == slow.slowSample(forSong: kept.lowerBound))
        #expect(slowKept.upperBound == slow.slowSample(forSong: kept.upperBound))
        #expect(slowed.zeroSample == slow.slowSample(forSong: 240_000))

        // A song that starts after the timeline's 00:00 has a 00:00 before its first sample.
        let late = slow.slowed(SongPlace(zeroSample: -85_000), songLengthSamples: length)
        #expect(late.zeroSample == -100_000)
        // An uncut song stays uncut.
        #expect(slow.slowed(SongPlace(), songLengthSamples: length) == SongPlace())
    }

    @Test("The slowed loop starts and ends on the same moments of the song")
    func slowedLoop() throws {
        let slow = SlowTime(percent: 90)
        let loop = try #require(LoopRegion(startSample: 432_000, lengthSamples: 172_800))
        let slowed = try #require(slow.slowed(loop))
        #expect(slowed.startSample == 480_000)
        #expect(slowed.endSample == slow.slowSample(forSong: loop.endSample))
        #expect(slowed.lengthSamples == 192_000)
    }

    @Test("The slowed project has the slow beats, length and place, and none of the clips, which are in song time")
    func slowedProject() {
        var project = Project(songName: "Song", songLengthSamples: 4_800_000, grid: driftingGrid())
        project.songPlace = SongPlace(cutStartSamples: 48_000)
        let recording = Recording(lengthSamples: 96_000, rawStart: 4)
        project.recordings = [recording]
        project.tracks[0].clips = [Clip(segments: [Segment(recordingID: recording.id, inSample: 0, outSample: 96_000)])]
        let slow = SlowTime(percent: 85)

        let slowed = slow.slowed(project)

        #expect(slowed.songLengthSamples == slow.slowLength(ofSong: 4_800_000))
        #expect(slowed.grid == slow.slowed(driftingGrid()))
        #expect(slowed.songPlace == slow.slowed(project.songPlace, songLengthSamples: 4_800_000))
        #expect(slowed.click == project.click)
        #expect(slowed.tracks.map(\.id) == project.tracks.map(\.id))
        #expect(slowed.tracks.allSatisfy { $0.clips.isEmpty })
        #expect(slowed.recordings.isEmpty)
        #expect(abs(slowed.keptSeconds.lowerBound - 1 / 0.85) < 1e-4)
    }
}

@Suite("The plan of the speed-up")
struct SpeedUpPlanTests {
    /// Four seconds of take, slow, with sound everywhere.
    private let length = 192_000

    @Test("Every syllable start lands on its own sample times the rate", arguments: [0.85, 0.9])
    func startsLandOnStartTimesRate(rate: Double) {
        let starts = [24_001, 38_400, 52_803, 96_000, 150_007]
        let plan = SpeedUpPlan(lengthSamples: length, rate: rate, syllableStarts: starts, sound: [0..<length])
        for start in starts {
            let target = Int((Double(start) * rate).rounded())
            #expect(plan.target(ofSource: start) == target)
            #expect(plan.points.contains(SpeedUpPlan.Point(source: start, target: target)))
        }
        #expect(plan.sourceLength == length)
        #expect(plan.targetLength == Int((Double(length) * rate).rounded()))
        #expect(plan.rate == rate)
    }

    @Test("The stretch around a start keeps its length: 15 ms before it to 45 ms after it")
    func keptStretchesKeepTheirLength() {
        let rules = SpeedUpPlan.Rules.standard
        #expect(rules.keptBeforeMs == 15)
        #expect(rules.keptAfterMs == 45)
        let starts = [48_000, 72_000, 120_000]
        let plan = SpeedUpPlan(lengthSamples: length, rate: 0.85, syllableStarts: starts, sound: [0..<length])
        for start in starts {
            let target = plan.target(ofSource: start)
            #expect(plan.target(ofSource: start - ms(15)) == target - ms(15))
            #expect(plan.target(ofSource: start + ms(45)) == target + ms(45))
            // Every sample of it moves as the start does.
            for offset in stride(from: -ms(15), through: ms(45), by: 97) {
                #expect(plan.target(ofSource: start + offset) == target + offset)
            }
            #expect(plan.points.contains(SpeedUpPlan.Point(source: start - ms(15), target: target - ms(15))))
            #expect(plan.points.contains(SpeedUpPlan.Point(source: start + ms(45), target: target + ms(45))))
        }
        // The time went out of what lies between: just outside a kept stretch the sound is shorter.
        let gap = plan.target(ofSource: 72_000 - ms(15)) - plan.target(ofSource: 48_000 + ms(45))
        #expect(gap < 72_000 - ms(15) - 48_000 - ms(45))
    }

    @Test("A pause that is long enough takes all of the time, and the sound around it keeps its length")
    func pausesShrinkBeforeVowels() {
        // Two starts half a second apart, and 200 ms of pause between them.
        let first = 48_000, second = 72_000
        let pause = 57_600..<67_200
        let plan = SpeedUpPlan(
            lengthSamples: length, rate: 0.85, syllableStarts: [first, second],
            sound: [0..<pause.lowerBound, pause.upperBound..<length])
        let taken = (second - first) - (plan.target(ofSource: second) - plan.target(ofSource: first))
        #expect(taken == 3_600)
        // The vowel before the pause and the sound after it are as long as they were.
        #expect(plan.target(ofSource: pause.lowerBound) - plan.target(ofSource: first) == pause.lowerBound - first)
        #expect(plan.target(ofSource: second) - plan.target(ofSource: pause.upperBound) == second - pause.upperBound)
        // The pause lost all of it, and is still more than half as long as it was.
        let pauseAfter = plan.target(ofSource: pause.upperBound) - plan.target(ofSource: pause.lowerBound)
        #expect(pauseAfter == pause.count - 3_600)
        #expect(pauseAfter * 2 >= pause.count)
    }

    @Test("A short pause shrinks to half, and the rest of the time comes out of the sound")
    func shortPauseShrinksToHalf() {
        #expect(SpeedUpPlan.Rules.standard.pauseShortestShare == 0.5)
        let first = 48_000, second = 72_000
        let pause = 60_000..<62_400   // 50 ms
        let plan = SpeedUpPlan(
            lengthSamples: length, rate: 0.85, syllableStarts: [first, second],
            sound: [0..<pause.lowerBound, pause.upperBound..<length])
        let pauseAfter = plan.target(ofSource: pause.upperBound) - plan.target(ofSource: pause.lowerBound)
        #expect(abs(pauseAfter - pause.count / 2) <= 1)
        // 3,600 samples go in all: 1,200 from the pause and 2,400 from the 18,720 of sound outside the kept stretches.
        let soundBefore = (first + ms(45))..<pause.lowerBound
        let soundAfter = pause.upperBound..<(second - ms(15))
        let before = plan.target(ofSource: soundBefore.upperBound) - plan.target(ofSource: soundBefore.lowerBound)
        let after = plan.target(ofSource: soundAfter.upperBound) - plan.target(ofSource: soundAfter.lowerBound)
        #expect(abs((soundBefore.count + soundAfter.count) - (before + after) - 2_400) <= 2)
        // Both pieces of sound are squeezed alike.
        #expect(abs(Double(before) / Double(soundBefore.count) - Double(after) / Double(soundAfter.count)) < 0.001)
    }

    @Test("Where the vowel would shrink below 70 %, the kept stretch is shortened until it does not")
    func shortSyllableShortensItsKeptStretch() {
        #expect(SpeedUpPlan.Rules.standard.soundShortestShare == 0.7)
        // Two starts 100 ms apart: 720 samples must go, and with 60 ms kept only 40 ms of vowel would be left
        // to take them from, which would leave it 62 % of its length.
        let first = 48_000, second = 52_800
        let plan = SpeedUpPlan(lengthSamples: length, rate: 0.85, syllableStarts: [first, second], sound: [0..<length])
        let inside = allPoints(of: plan).filter { $0.source >= first && $0.source <= second }
        #expect(inside.first?.source == first)
        #expect(inside.last?.source == second)
        // What still keeps its length around the two starts is shorter than 45 and 15 ms, and not gone.
        let keptAfter = inside.dropFirst().first
        let keptBefore = inside.dropLast().last
        let after = (keptAfter?.source ?? 0) - first
        let before = second - (keptBefore?.source ?? 0)
        #expect(after > 0 && after < ms(45))
        #expect(before > 0 && before < ms(15))
        #expect((keptAfter?.target ?? 0) - plan.target(ofSource: first) == after)
        #expect(plan.target(ofSource: second) - (keptBefore?.target ?? 0) == before)
        // As much is kept as the vowel allows: together half of the 100 ms, to the sample or nearly.
        #expect(abs(after + before - 2_400) <= 8)
        // And no piece between two points is squeezed below 70 %.
        for (earlier, later) in zip(inside, inside.dropFirst()) {
            let share = Double(later.target - earlier.target) / Double(later.source - earlier.source)
            #expect(share >= 0.7 - 0.002)
        }
    }

    @Test("With no syllables the whole take is squeezed evenly", arguments: [0.85, 0.9])
    func noSyllablesGivesAnEvenSqueeze(rate: Double) {
        let plan = SpeedUpPlan(
            lengthSamples: length, rate: rate, syllableStarts: [], sound: [10_000..<50_000, 90_000..<120_000])
        #expect(plan.points.isEmpty)
        #expect(plan.keyFrames.isEmpty)
        #expect(plan.targetLength == Int((Double(length) * rate).rounded()))
        for sample in [0, 1, 4_800, 96_000, length - 1, length] {
            #expect(abs(plan.target(ofSource: sample) - Int((Double(sample) * rate).rounded())) <= 1)
        }
        #expect(plan.target(ofSource: 0) == 0)
        #expect(plan.target(ofSource: length) == plan.targetLength)
    }

    @Test("The key frames only go forward, stay inside the take, and nothing is made longer", arguments: [0.85, 0.9])
    func keyFramesGoForward(rate: Double) {
        // A made-up take of 30 seconds: syllables from 75 to 400 ms apart, every third followed by a pause.
        var state: UInt64 = 20_261_115
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        let length = 1_440_001
        var starts: [Int] = []
        var pauses: [Range<Int>] = []
        var place = 30_000
        while place < length - 30_000 {
            starts.append(place)
            let gap = ms(75 + next() * 325)
            if starts.count % 3 == 0, gap > ms(150) {
                pauses.append((place + gap / 2)..<(place + gap / 2 + ms(20 + next() * 40)))
            }
            place += gap
        }
        var sound: [Range<Int>] = []
        var from = 0
        for pause in pauses where pause.lowerBound > from {
            sound.append(from..<pause.lowerBound)
            from = pause.upperBound
        }
        sound.append(from..<length)

        let plan = SpeedUpPlan(lengthSamples: length, rate: rate, syllableStarts: starts, sound: sound)

        #expect(plan.targetLength == Int((Double(length) * rate).rounded()))
        #expect(plan.keyFrames.count == plan.points.count)
        #expect(plan.points.count > starts.count)
        for point in plan.points {
            #expect(point.source > 0 && point.source < plan.sourceLength)
            #expect(point.target > 0 && point.target < plan.targetLength)
        }
        let points = allPoints(of: plan)
        for (earlier, later) in zip(points, points.dropFirst()) {
            #expect(later.source > earlier.source)
            #expect(later.target > earlier.target)
            #expect(later.target - earlier.target <= later.source - earlier.source)
        }
        for start in starts {
            #expect(plan.target(ofSource: start) == Int((Double(start) * rate).rounded()))
        }
        // The same take gives the same plan.
        #expect(plan == SpeedUpPlan(lengthSamples: length, rate: rate, syllableStarts: starts, sound: sound))
    }

    @Test("Starts outside the take, twice, or out of order do no harm")
    func oddStartsDoNoHarm() {
        let plan = SpeedUpPlan(
            lengthSamples: length, rate: 0.85, syllableStarts: [96_000, -5, 48_000, 96_000, length, length + 10, 0],
            sound: [0..<length])
        #expect(plan == SpeedUpPlan(lengthSamples: length, rate: 0.85, syllableStarts: [48_000, 96_000], sound: [0..<length]))
        // A take of nothing, and a take at full speed.
        #expect(SpeedUpPlan(lengthSamples: 0, rate: 0.85, syllableStarts: [], sound: []).targetLength == 0)
        let full = SpeedUpPlan(lengthSamples: length, rate: 1, syllableStarts: [48_000], sound: [0..<length])
        #expect(full.targetLength == length)
        #expect(full.target(ofSource: 77_777) == 77_777)
    }

    // MARK: The finished take at full tempo

    @Test("A take finished in slow time is mapped to song time: its place, its length and its clip")
    func mappedRecordingAndClip() throws {
        let devices = DevicePair(outputUID: "out", outputName: "Out", inputUID: "in", inputName: "In")
        let slowTake = Recording(
            lengthSamples: length, rawStart: 20, delay: 0.02, devicePair: devices, excludedMarkers: [48_000])
        let pause = 57_600..<67_200
        let plan = SpeedUpPlan(
            lengthSamples: length, rate: 0.85, syllableStarts: [48_000, 72_000, 120_000],
            sound: [0..<pause.lowerBound, pause.upperBound..<length])
        // The clip starts 50 ms before the first syllable and ends in the last one's tail.
        let slowClip = (48_000 - ms(50))..<150_000

        let mapped = plan.atFullTempo(slowTake, clip: slowClip)

        #expect(mapped.recording.id == slowTake.id)
        #expect(mapped.recording.file == slowTake.file)
        #expect(mapped.recording.devicePair == devices)
        #expect(mapped.recording.recordedSpeed == 0.85)
        #expect(mapped.recording.lengthSamples == plan.targetLength)
        #expect(abs(mapped.recording.rawStart - 17) < 1e-12)
        #expect(abs(mapped.recording.delay - 0.017) < 1e-12)
        #expect(mapped.recording.excludedMarkers == [40_800])
        // The clip's edges go through the plan's own map, so they are where the sound is. A plain
        // multiplication would put its start somewhere else: the 50 ms before the first syllable hold 15 ms
        // that kept their length.
        let clip = try #require(mapped.clip)
        #expect(clip == plan.target(ofSource: slowClip.lowerBound)..<plan.target(ofSource: slowClip.upperBound))
        #expect(clip.lowerBound != Int((Double(slowClip.lowerBound) * 0.85).rounded()))
        // A syllable is heard at the same place of the song as it was performed against the slow song.
        let slow = SlowTime(rate: 0.85)
        let performed = slow.songSeconds(forSlow: slowTake.songTime(ofSample: 72_000))
        let heard = mapped.recording.songTime(ofSample: plan.target(ofSource: 72_000))
        #expect(abs(heard - performed) < 0.5 / 48_000)
        // A take that is thrown away has no clip at full tempo either.
        #expect(plan.atFullTempo(slowTake, clip: nil).clip == nil)
    }

    @Test("A delay measured later moves a slow take by the delay times its speed")
    func laterDelayOfASlowTake() {
        let devices = DevicePair(outputUID: "out", outputName: "Out", inputUID: "in", inputName: "In")
        var project = Project()
        project.recordings = [
            Recording(lengthSamples: 48_000, rawStart: 4, devicePair: devices),
            Recording(lengthSamples: 40_800, rawStart: 8, devicePair: devices, recordedSpeed: 0.85),
        ]
        #expect(project.applyDelay(0.02, toRecordingsMadeWith: devices) == 2)
        #expect(project.recordings[0].delay == 0.02)
        #expect(abs(project.recordings[1].delay - 0.017) < 1e-12)
    }

    @Test("A slow take that has just been made is moved back by the delay times its speed")
    func delayOfANewSlowTake() {
        let devices = DevicePair(outputUID: "out", outputName: "Out", inputUID: "in", inputName: "In")
        let full = Recording(lengthSamples: 48_000, rawStart: 4, devicePair: devices).movedBack { _ in 0.02 }
        let slow = Recording(lengthSamples: 40_800, rawStart: 8, devicePair: devices, recordedSpeed: 0.85)
            .movedBack { _ in 0.02 }
        #expect(full.delay == 0.02)
        #expect(abs(slow.delay - 0.017) < 1e-12)
    }
}

@Suite("A recording made slower, saved")
struct RecordedSpeedSavingTests {
    @Test("A recording made at full speed is saved without recordedSpeed, and one made slower with it")
    func recordedSpeedInJSON() throws {
        let full = Recording(lengthSamples: 48_000, rawStart: 4)
        let slow = Recording(lengthSamples: 40_800, rawStart: 4, recordedSpeed: 0.85)
        let fullText = String(decoding: try JSONEncoder().encode(full), as: UTF8.self)
        let slowText = String(decoding: try JSONEncoder().encode(slow), as: UTF8.self)
        #expect(!fullText.contains("recordedSpeed"))
        #expect(slowText.contains("\"recordedSpeed\":0.85"))
        #expect(try JSONDecoder().decode(Recording.self, from: Data(fullText.utf8)) == full)
        #expect(try JSONDecoder().decode(Recording.self, from: Data(slowText.utf8)) == slow)
        #expect(full.recordedSpeed == nil)
    }

    @Test("A project saved before takes could be slow reads as it did and is written as it was")
    func oldProjectIsUnchanged() throws {
        let recording = Recording(lengthSamples: 96_000, rawStart: 3.5, delay: 0.011, excludedMarkers: [4_800])
        var project = Project(songName: "Song", songLengthSamples: 4_800_000)
        project.recordings = [recording]
        project.tracks[0].clips = [Clip(segments: [Segment(recordingID: recording.id, inSample: 0, outSample: 96_000)])]
        let saved = try ProjectPackage.encode(project)
        #expect(!String(decoding: saved, as: UTF8.self).contains("recordedSpeed"))

        let read = try ProjectPackage.decode(saved)
        #expect(read == project)
        #expect(read.recordings[0].recordedSpeed == nil)
        #expect(try ProjectPackage.encode(read) == saved)
    }

    @Test("A speed that is none is read as full speed")
    func oddSpeedsAreFullSpeed() throws {
        for text in ["0", "-0.85", "1", "1.5"] {
            let json = "{\"id\":\"\(UUID().uuidString)\",\"lengthSamples\":100,\"recordedSpeed\":\(text)}"
            #expect(try JSONDecoder().decode(Recording.self, from: Data(json.utf8)).recordedSpeed == nil)
        }
    }
}

@Suite("The recording speed setting")
@MainActor
struct RecordSpeedSettingTests {
    @Test("It starts at 100, keeps 90 and 85, and takes anything else for 100")
    func range() throws {
        let name = "lockstep-tests-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        let settings = AppSettings(store: store)
        let key = SettingKey<Int>.recordSpeedPercent

        #expect(key.name == "recording.speedPercent")
        #expect(key.choices == [100, 90, 85])
        #expect(key.choices == SlowTime.percents)
        #expect(settings[.recordSpeedPercent] == 100)
        for percent in [90, 85, 100] {
            settings[.recordSpeedPercent] = percent
            #expect(settings[.recordSpeedPercent] == percent)
            #expect(store.integer(forKey: "recording.speedPercent") == percent)
        }
        settings[.recordSpeedPercent] = 85
        settings[.recordSpeedPercent] = 70
        #expect(settings[.recordSpeedPercent] == 100)
        // A value written by hand that is none of the three is read as 100.
        store.set(95, forKey: "recording.speedPercent")
        #expect(AppSettings(store: store)[.recordSpeedPercent] == 100)
    }
}

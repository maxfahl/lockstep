import Foundation
import Testing
@testable import LockstepCore

/// A clip held against the syllables of another track in place of the sub-beats: how far each syllable of
/// one line moves, where the end of a held note goes, how a whole clip is corrected, and how its markers are
/// judged.
@Suite("A double held against its lead")
struct LockedDoubleTests {
    // MARK: One line

    /// The line's first sample in its recording: 200 ms in, so a mix-up of recording samples and song time
    /// shows, and a whole number of milliseconds, so a pause starts exactly where a test says.
    private let firstSample = 9_600

    private func sample(_ time: Double, from start: Double) -> Int {
        firstSample + Int(((time - start) * 48_000).rounded())
    }

    /// A line that sounds from `start` to `end` in the song, with syllables at the given song seconds.
    private func line(from start: Double, to end: Double, markers: [Double]) -> VoiceLine {
        VoiceLine(
            startSample: sample(start, from: start),
            endSample: sample(end, from: start),
            markers: markers.map { sample($0, from: start) }
        )
    }

    /// How far each pair of the map moves, in samples.
    private func moves(_ map: TimeMap) -> [Int] {
        map.pairs.map { $0.result - $0.source }
    }

    private func samples(ms: Double) -> Int { Int((ms * 48).rounded()) }

    /// How loud the recording of a line is, one value for every millisecond: sound all through, except for
    /// quiet between the song seconds given.
    private func levels(of line: VoiceLine, from start: Double, quiet: [Range<Double>]) -> VoiceLevels {
        var values = [Float](repeating: -20, count: line.endSample / 48 + 1)
        for stretch in quiet {
            for index in sample(stretch.lowerBound, from: start) / 48..<sample(stretch.upperBound, from: start) / 48 {
                values[index] = -70
            }
        }
        return VoiceLevels(values: values, threshold: -58, hopSamples: 48)
    }

    /// The lead's syllables at these song seconds, as what a line is held against.
    private func lead(_ times: [Double]) -> TimingTargets {
        .times(times.map { TimingTargets.Target(time: $0) })
    }

    /// Beats from 2 s on, half a second apart: a sixteenth is 125 ms.
    private let grid = Grid(beats: (0..<40).map { Beat(number: $0, time: 2 + Double($0) * 0.5) })

    @Test func heldAgainstSubBeatsEveryAnswerIsWhatItWas() {
        let line = line(from: 2.9, to: 3.7, markers: [3.0, 3.145, 3.25, 3.355, 3.5])
        let before = SyllableMoves.plan(
            line: line, shiftSamples: 240, carriedSamples: 96, songStart: 2.9, grid: grid, perBeat: 6, strength: 0.7
        )
        let handed = SyllableMoves.plan(
            line: line, shiftSamples: 240, carriedSamples: 96, songStart: 2.9,
            targets: .subBeats(grid: grid, perBeat: 6), strength: 0.7
        )
        #expect(before == handed)
        let times = [3.02, 3.145, 3.27]
        #expect(
            LineShift.slide(markerTimes: times, targets: .subBeats(grid: grid, perBeat: 4))
                == LineShift.toFirstSyllable(markerTimes: times, grid: grid, perBeat: 4)
        )
    }

    @Test func atFullStrengthAPairedSyllableLandsExactlyOnItsPartner() {
        // The lead is 10 ms after the sixteenths, so nothing here can be the grid's doing. The second
        // syllable of the double is 20 ms late for its partner and the fourth 20 ms early.
        let line = line(from: 2.9, to: 3.7, markers: [3.01, 3.155, 3.26, 3.345, 3.51])
        let map = SyllableMoves.plan(
            line: line, songStart: 2.9, targets: lead([3.01, 3.135, 3.26, 3.365, 3.51]), strength: 1
        )
        #expect(moves(map) == [0, 0, -960, 0, 960, 0, 0])
        #expect(map.pairs[2].result == firstSample + samples(ms: 235))
        #expect(map.pairs[4].result == firstSample + samples(ms: 465))
    }

    @Test func atHalfStrengthItGoesHalfTheWay() {
        let line = line(from: 2.9, to: 3.7, markers: [3.01, 3.155, 3.26, 3.345, 3.51])
        let map = SyllableMoves.plan(
            line: line, songStart: 2.9, targets: lead([3.01, 3.135, 3.26, 3.365, 3.51]), strength: 0.5
        )
        #expect(moves(map) == [0, 0, -480, 0, 480, 0, 0])
        let none = SyllableMoves.plan(
            line: line, songStart: 2.9, targets: lead([3.01, 3.135, 3.26, 3.365, 3.51]), strength: 0
        )
        #expect(moves(none) == [0, 0, 0, 0, 0, 0, 0])
    }

    @Test func howFarOffCountsAsDeliberateIsNotAsked() {
        // With "deliberate" at 1 % nothing would move toward a sub-beat. A double is meant to sit on the lead.
        let line = line(from: 2.5, to: 4.0, markers: [3.155])
        let strict = SyllableMoves.Limits(deliberatePercent: 1)
        let map = SyllableMoves.plan(line: line, songStart: 2.5, targets: lead([3.135]), strength: 1, limits: strict)
        #expect(moves(map) == [0, -960, 0])
    }

    @Test func aSyllableTheLeadDoesNotHaveStaysWhereItIs() {
        // The syllable at 3.07 is 55 ms from the nearest lead syllable, which also has a nearer one.
        let line = line(from: 2.9, to: 3.7, markers: [3.0, 3.07, 3.145, 3.25])
        let loose = SyllableMoves.Limits(maxStretchPercent: 1_000)
        let map = SyllableMoves.plan(
            line: line, songStart: 2.9, targets: lead([3.0, 3.125, 3.25]), strength: 1, limits: loose
        )
        #expect(moves(map) == [0, 0, 0, -960, 0, 0])
    }

    @Test func aSyllableFurtherFromTheLeadThanTheLimitStays() {
        let line = line(from: 2.5, to: 4.0, markers: [3.185])
        #expect(moves(SyllableMoves.plan(line: line, songStart: 2.5, targets: lead([3.125]), strength: 1)) == [0, 0, 0])
        // The setting decides how far is too far.
        let further = SyllableMoves.Limits(maxMoveMs: 70)
        let map = SyllableMoves.plan(line: line, songStart: 2.5, targets: lead([3.125]), strength: 1, limits: further)
        #expect(moves(map) == [0, -2_880, 0])
    }

    @Test func anExcludedSyllableStaysAndTakesNoPartner() {
        // Two syllables near one lead syllable: 15 ms before it and 20 ms after it. The nearer one has it.
        let line = line(from: 2.5, to: 4.0, markers: [3.11, 3.145])
        let loose = SyllableMoves.Limits(maxStretchPercent: 1_000)
        let free = SyllableMoves.plan(line: line, songStart: 2.5, targets: lead([3.125]), strength: 1, limits: loose)
        #expect(moves(free) == [0, 720, 0, 0])
        // With the nearer one excluded, it stays and the other has the lead syllable. It goes as far as the
        // 20 ms that two syllables always keep between them allow: 35 ms apart become 20.
        let excluded = SyllableMoves.plan(
            line: line, songStart: 2.5, targets: lead([3.125]), strength: 1,
            excluded: [line.markers[0]], limits: loose
        )
        #expect(moves(excluded) == [0, 0, -720, 0])
    }

    @Test func theSlideOfTheLineIsCountedBeforeASyllableIsMeasured() {
        // The line has slid 30 ms earlier. Where the slide put it, the second syllable is 10 ms late.
        let line = line(from: 2.9, to: 3.7, markers: [3.04, 3.175, 3.29])
        let map = SyllableMoves.plan(
            line: line, shiftSamples: -1_440, songStart: 2.9, targets: lead([3.01, 3.135, 3.26]), strength: 1
        )
        #expect(moves(map) == [-1_440, -1_440, -1_920, -1_440, -1_440])
    }

    // MARK: The end of a held note

    /// A line from 2.9 to 4.0: one syllable at 3.0, held until 3.6, quiet until 3.75, and a second syllable
    /// at 3.8.
    private var sung: (line: VoiceLine, levels: VoiceLevels) {
        let line = line(from: 2.9, to: 4.0, markers: [3.0, 3.8])
        return (line, levels(of: line, from: 2.9, quiet: [3.6..<3.75]))
    }

    /// The lead's two syllables on the double's, with the first note ending at `noteEnd`.
    private func sungLead(noteEnd: Double?, first: Double = 3.0) -> TimingTargets {
        .times([TimingTargets.Target(time: first, noteEnd: noteEnd), TimingTargets.Target(time: 3.8)])
    }

    private func sungPlan(
        _ targets: TimingTargets,
        strength: Double = 1,
        stretchPercent: Double = 25,
        levels: VoiceLevels? = nil,
        line: VoiceLine? = nil
    ) -> TimeMap {
        SyllableMoves.plan(
            line: line ?? sung.line, songStart: 2.9, targets: targets, strength: strength,
            limits: SyllableMoves.Limits(maxStretchPercent: stretchPercent), levels: levels ?? sung.levels
        )
    }

    @Test func withAStretchLimitTheEndOfAHeldNoteMovesOntoTheEndOfTheLeads() {
        // The double holds its note 100 ms longer than the lead does.
        let map = sungPlan(sungLead(noteEnd: 3.5))
        let end = sample(3.6, from: 2.9)
        #expect(map.pairs.map(\.source) == [sung.line.startSample, sung.line.markers[0], end, sung.line.markers[1], sung.line.endSample])
        #expect(moves(map) == [0, 0, -4_800, 0, 0])
        // And 100 ms shorter: the pause after the note gives what the note gets.
        #expect(moves(sungPlan(sungLead(noteEnd: 3.7))) == [0, 0, 4_800, 0, 0])
        // Strength is a share of the way, as for a syllable.
        #expect(moves(sungPlan(sungLead(noteEnd: 3.5), strength: 0.5)) == [0, 0, -2_400, 0, 0])
    }

    @Test func withTheStretchLimitAtZeroNoNoteEndMoves() {
        let map = sungPlan(sungLead(noteEnd: 3.5), stretchPercent: 0)
        #expect(map.pairs.map(\.source) == [sung.line.startSample] + sung.line.markers + [sung.line.endSample])
        #expect(moves(map) == [0, 0, 0, 0])
    }

    @Test func theNoteIsNeverStretchedPastTheLimitAndThePauseKeepsWhatItNeeds() {
        // 300 ms shorter is asked for. A note of 600 ms may lose 120 ms at 25 %.
        #expect(moves(sungPlan(sungLead(noteEnd: 3.3))) == [0, 0, -5_760, 0, 0])
        // 140 ms longer is asked for. The stretch limit would give 150 ms, but the pause of 150 ms keeps 21.
        #expect(moves(sungPlan(sungLead(noteEnd: 3.74))) == [0, 0, 6_192, 0, 0])
    }

    @Test func onlyNotesThatBothVoicesHoldAreMatched() {
        let plain = [sung.line.startSample] + sung.line.markers + [sung.line.endSample]
        // The lead's note is 200 ms long: not held.
        #expect(sungPlan(sungLead(noteEnd: 3.2)).pairs.map(\.source) == plain)
        // Where the lead's note ends is not known.
        #expect(sungPlan(sungLead(noteEnd: nil)).pairs.map(\.source) == plain)
        // The double's own note is 200 ms long.
        let short = levels(of: sung.line, from: 2.9, quiet: [3.2..<3.75])
        #expect(sungPlan(sungLead(noteEnd: 3.5), levels: short).pairs.map(\.source) == plain)
        // A syllable without a partner has no note to match.
        let alone = TimingTargets.times([TimingTargets.Target(time: 3.8)])
        #expect(sungPlan(alone).pairs.map(\.source) == plain)
        // Held against sub-beats there are no note ends at all.
        #expect(sungPlan(.subBeats(grid: grid, perBeat: 4)).pairs.map(\.source) == plain)
    }

    @Test func aNoteEndNeverHoldsItsSyllableBack() {
        // The syllable is 20 ms late, and its note should end 140 ms later than it does: more than the note
        // can be stretched by. The syllable goes all the way, and the end as far as it can from there.
        let line = line(from: 2.9, to: 4.0, markers: [3.02, 3.8])
        let levels = levels(of: line, from: 2.9, quiet: [3.6..<3.75])
        let map = sungPlan(sungLead(noteEnd: 3.74), levels: levels, line: line)
        #expect(moves(map) == [0, -960, 6_000, 0, 0])
    }

    @Test func theLastNoteOfALineCanBeMadeShorterButHardlyLonger() {
        // One syllable at 3.0, held until 30 ms before the line's end: the quiet a line always ends with.
        let line = line(from: 2.9, to: 4.0, markers: [3.0])
        let levels = levels(of: line, from: 2.9, quiet: [3.97..<4.0])
        func lead(noteEnd: Double) -> TimingTargets {
            .times([TimingTargets.Target(time: 3.0, noteEnd: noteEnd)])
        }
        // The lead lets go 170 ms sooner: the note is squeezed and the quiet after it gets longer.
        let shorter = sungPlan(lead(noteEnd: 3.8), levels: levels, line: line)
        #expect(shorter.pairs.map(\.source) == [line.startSample, line.markers[0], sample(3.97, from: 2.9), line.endSample])
        #expect(moves(shorter) == [0, 0, -8_160, 0])
        // The lead holds on 130 ms longer. The line keeps its length, so only the 30 ms of quiet can give,
        // and it keeps 21 ms: the note gets 9 ms longer.
        #expect(moves(sungPlan(lead(noteEnd: 4.1), levels: levels, line: line)) == [0, 0, 432, 0])
    }

    @Test func theSoundOfALineWithAMovedNoteEndCanBeBuilt() throws {
        let map = sungPlan(sungLead(noteEnd: 3.5))
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        let recording = (0..<sung.line.endSample + 480).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24) - 0.5
        }
        let stretcher = LinearStretcher()
        let sound = try #require(LineRenderer.quantized(
            line: sung.line, map: map, recording: recording, levels: sung.levels, stretcher: stretcher
        ))
        #expect(sound.count == sung.line.lengthSamples)
        #expect(!stretcher.promiseBroken)
        // The note of 600 ms was made 100 ms shorter and nothing else was stretched.
        #expect(stretcher.calls == 1)
        #expect(stretcher.mostStretch <= 1.25)
        #expect(stretcher.mostStretch > 1.19)
    }

    // MARK: A whole clip

    // The recording of `ClipTighteningTests`: it began one second into the song and holds three lines, with
    // syllables at 1.530, 1.655, 1.780 and 1.905, at 3.105, 3.230, 3.355 and 3.480, and at 4.250, 4.375 and
    // 4.500 song seconds.
    private typealias Fixture = ClipTighteningTests

    /// The lead as the double hears it: its first line 18 ms before the double's, its second 25 ms after,
    /// and nothing where the double has its third. None of it is on a sub-beat.
    private let leadTimes = [1.512, 1.637, 1.762, 1.887, 3.130, 3.255, 3.380, 3.505]

    private func aimed(
        at times: [Double]?,
        strength: Double = 0,
        lineStrength: Double = 1,
        settings: TightenSettings = TightenSettings()
    ) throws -> ClipTightening.Inputs {
        let clip = Self.wholeClip
        return try #require(ClipTightening.Inputs(
            clip: clip,
            in: Fixture.project([clip]),
            markers: Fixture.markers,
            settings: settings,
            strength: strength,
            lineStrength: lineStrength,
            aimedAt: times.map { $0.map { TimingTargets.Target(time: $0) } }, voices: .none
        ))
    }

    /// The clip that plays the whole recording: the same clip in every test, so two sets of inputs differ
    /// only in what a test changed.
    private static let wholeClip = Fixture.clip()

    private func shifts(_ inputs: ClipTightening.Inputs) -> [Int] {
        ClipTightening.lines(of: inputs, levels: Fixture.levels)[0].map(\.shiftSamples)
    }

    @Test func eachLineOfTheDoubleSlidesOntoTheLeadAndNotOntoTheBeat() throws {
        // Against the beat the three lines slide 30 ms earlier, 20 ms later and not at all.
        #expect(shifts(try aimed(at: nil)) == [-1_440, 960, 0])
        // Against the lead: 18 ms earlier, 25 ms later, and the line the lead does not have stays.
        #expect(shifts(try aimed(at: leadTimes)) == [-864, 1_200, 0])
    }

    @Test func strengthIsAShareOfTheSlideAsItIsAgainstTheBeat() throws {
        #expect(shifts(try aimed(at: leadTimes, lineStrength: 0.5)) == [-432, 600, 0])
        #expect(shifts(try aimed(at: leadTimes, lineStrength: 0)) == [0, 0, 0])
    }

    @Test func aLineSlidesNoFurtherThanTheSettingAllows() throws {
        // The lead is 60 ms before the double's first line. With the furthest slide set to 40 ms, the line
        // goes those 40 ms. (The syllables here are 125 ms apart, so a lead more than half of that away
        // would be nearer to the next syllable, and the line would be taken to be early.)
        let lead = [1.470, 1.595, 1.720, 1.845]
        #expect(shifts(try aimed(at: lead))[0] == -2_880)
        let tighter = TightenSettings(maxLineShiftMs: 40)
        #expect(shifts(try aimed(at: lead, settings: tighter))[0] == -1_920)
    }

    @Test func withAllASyllableThatIsOffItsPartnerIsMovedOntoIt() throws {
        // The second syllable of the lead is 10 ms later than the double's would be after the slide.
        var lead = leadTimes
        lead[1] = 1.647
        let inputs = try aimed(at: lead, strength: 1)
        let made = ClipTightening.render(
            inputs, levels: Fixture.levels, recordings: [Fixture.recording.id: Fixture.sound], stretcher: LinearStretcher()
        )
        let first = try #require(made.first?.lines.first)
        #expect(first.shiftSamples == -864)
        let ms = Fixture.ms
        #expect(first.map.result(ofSource: 530 * ms) - 530 * ms == -864)
        #expect(first.map.result(ofSource: 655 * ms) - 655 * ms == -864 + 480)
        #expect(first.map.result(ofSource: 780 * ms) - 780 * ms == -864)
        // The line says who each syllable was held against.
        #expect(first.partners.keys.sorted() == [530 * ms, 655 * ms, 780 * ms, 905 * ms])
        #expect(first.partners[655 * ms] == 1.647)
        #expect(first.matchedNoteEnds == 0)
        // The line the lead does not have has no partners.
        #expect(made[0].lines[2].partners.isEmpty)
    }

    @Test func theFirstSyllableOfALineIsCarriedOntoItsPartnerByTheWholeLine() throws {
        // After the slide of 18 ms the first syllable is still 8 ms early for its partner. Nothing lies
        // before it that could give the 8 ms, so the line goes with it and the others move back inside it.
        var lead = leadTimes
        lead[0] = 1.520
        let inputs = try aimed(at: lead, strength: 1)
        let line = try #require(ClipTightening.lines(of: inputs, levels: Fixture.levels)[0].first)
        #expect(line.shiftSamples == -480)
        #expect(line.carriedSamples == 384)
        #expect(line.slideSamples == -864)
        let made = ClipTightening.render(
            inputs, levels: Fixture.levels, recordings: [Fixture.recording.id: Fixture.sound], stretcher: LinearStretcher()
        )
        let map = try #require(made.first?.lines.first?.map)
        let ms = Fixture.ms
        #expect(map.result(ofSource: 530 * ms) - 530 * ms == -480)
        #expect(map.result(ofSource: 655 * ms) - 655 * ms == -864)
        #expect(map.result(ofSource: 780 * ms) - 780 * ms == -864)
        // With Lines alone the line only slides.
        #expect(shifts(try aimed(at: lead))[0] == -864)
    }

    @Test func theSoundIsMadeAgainWhenTheLeadsSyllablesChange() throws {
        let inputs = try aimed(at: leadTimes)
        #expect(inputs == (try aimed(at: leadTimes)))
        var moved = leadTimes
        moved[2] += 0.004
        #expect(inputs != (try aimed(at: moved)))
        #expect(inputs != (try aimed(at: nil)))
        // What is held against is the lead, in the order of the song.
        #expect(inputs.targets == .times(leadTimes.map { TimingTargets.Target(time: $0) }))
        #expect((try aimed(at: leadTimes.reversed())) == inputs)
        #expect((try aimed(at: nil)).targets == .subBeats(grid: Fixture.grid, perBeat: 4))
    }

    /// A project with the lead's track first and the double's second, and the double's clip aimed as given.
    /// The ids are the same in every answer, so two answers differ only in what a test changed.
    private func twoTracks(aim: (Track) -> UUID?, grid: Grid? = Fixture.grid) -> (project: Project, double: Clip) {
        let leadTrack = Track(id: Self.leadTrackID, name: "Lead")
        var clip = Fixture.clip()
        clip.id = Self.doubleClipID
        clip.tighten = .all
        clip.aimTrack = aim(leadTrack)
        let project = Project(
            songLengthSamples: Fixture.songSamples,
            grid: grid,
            tracks: [leadTrack, Track(id: Self.doubleTrackID, name: "Double", clips: [clip])],
            recordings: [Fixture.recording]
        )
        return (project, clip)
    }

    private static let leadTrackID = UUID()
    private static let doubleTrackID = UUID()
    private static let doubleClipID = UUID()

    private var handedIn: [TimingTargets.Target] {
        leadTimes.map { TimingTargets.Target(time: $0) }
    }

    @Test func aClipThatAimsAtATrackIsHeldAgainstTheSyllablesHandedIn() throws {
        let (project, clip) = twoTracks(aim: { $0.id })
        let inputs = try #require(ClipTightening.Inputs(
            correcting: clip, in: project, markers: Fixture.markers, aimedAt: handedIn, voices: .none
        ))
        #expect(inputs.targets == .times(handedIn))
        #expect(inputs.strength == 1)
    }

    @Test func aClipThatAimsAtTheBeatIsCorrectedAsBeforeWhateverIsHandedIn() throws {
        let (project, clip) = twoTracks(aim: { _ in nil })
        let plain = try #require(ClipTightening.Inputs(correcting: clip, in: project, markers: Fixture.markers, voices: .none))
        let handed = try #require(ClipTightening.Inputs(
            correcting: clip, in: project, markers: Fixture.markers, aimedAt: handedIn, voices: .none
        ))
        #expect(handed == plain)
        #expect(handed.targets == .subBeats(grid: Fixture.grid, perBeat: 4))
        // An aim at a track with nothing handed in is the beat too: the app does not know the lead yet.
        let (aimedProject, aimedClip) = twoTracks(aim: { $0.id })
        let waiting = try #require(ClipTightening.Inputs(correcting: aimedClip, in: aimedProject, markers: Fixture.markers, voices: .none))
        #expect(waiting.targets == .subBeats(grid: Fixture.grid, perBeat: 4))
        // And so is an aim at a track that is gone.
        let (goneProject, goneClip) = twoTracks(aim: { _ in UUID() })
        let gone = try #require(ClipTightening.Inputs(
            correcting: goneClip, in: goneProject, markers: Fixture.markers, aimedAt: handedIn, voices: .none
        ))
        #expect(gone.targets == .subBeats(grid: Fixture.grid, perBeat: 4))
    }

    @Test func leadSyllablesFarFromTheClipDoNotCount() throws {
        // The clip covers 1 s to 5 s of the song. A lead syllable at 0.5 s or at 5.5 s can never be a partner
        // of one of its syllables, so moving it must not make the double's sound again.
        let (project, clip) = twoTracks(aim: { $0.id })
        let far = [TimingTargets.Target(time: 0.5)] + handedIn + [TimingTargets.Target(time: 5.5)]
        let inputs = try #require(ClipTightening.Inputs(
            correcting: clip, in: project, markers: Fixture.markers, aimedAt: far, voices: .none
        ))
        #expect(inputs.targets == .times(handedIn))
    }

    @Test func aClipThatAimsAtATrackNeedsNoBeats() throws {
        let (project, clip) = twoTracks(aim: { $0.id }, grid: nil)
        // Against the beat there is nothing to correct without beats.
        #expect(ClipTightening.Inputs(correcting: clip, in: project, markers: Fixture.markers, voices: .none) == nil)
        let inputs = try #require(ClipTightening.Inputs(
            correcting: clip, in: project, markers: Fixture.markers, aimedAt: handedIn, voices: .none
        ))
        #expect(shifts(inputs) == [-864, 1_200, 0])
        // The beats are no part of what its sound depends on, so new beats do not make it again.
        let (withBeats, same) = twoTracks(aim: { $0.id })
        #expect(
            ClipTightening.Inputs(correcting: same, in: withBeats, markers: Fixture.markers, aimedAt: handedIn, voices: .none) == inputs
        )
    }

    // MARK: The markers

    @Test func againstSubBeatsAMarkerIsMeasuredAsItAlwaysWas() throws {
        let times = [3.0, 3.145, 3.19, 0.4]
        let measured = MarkerDistance.measure(times: times, against: .subBeats(grid: grid, perBeat: 4))
        #expect(measured.map(\.kind) == [.onBeat, .slightlyOff, .deliberate, .deliberate])
        let offsets = measured.map(\.offset)
        #expect(abs(try #require(offsets[1]) - 0.02) < 1e-9)
        #expect(abs(try #require(offsets[2]) + 0.06) < 1e-9)
        // Where the song has no beats there is no distance to read.
        #expect(offsets[3] == nil)
    }

    @Test func againstALeadAPairedSyllableIsJudgedByItsDistanceToItsPartner() throws {
        // On its partner, 25 ms late for it, one the lead does not have, and 8 ms early.
        let measured = MarkerDistance.measure(times: [3.0, 3.15, 3.3, 3.492], against: lead([3.0, 3.125, 3.5]))
        #expect(measured.map(\.kind) == [.onBeat, .slightlyOff, .deliberate, .onBeat])
        #expect(measured[0].offset == 0)
        #expect(abs(try #require(measured[1].offset) - 0.025) < 1e-9)
        // No partner: neutral, and no distance to read.
        #expect(measured[2].offset == nil)
        #expect(abs(try #require(measured[3].offset) + 0.008) < 1e-9)
    }

    @Test func aDoubleThatIsLateAsAWholeShowsHowLateEachSyllableIs() throws {
        // 60 ms late all through: further than a syllable may move, but the line would slide first, and the
        // markers say what the correction would then find.
        let leadTimes = [3.0, 3.2, 3.35, 3.6]
        let measured = MarkerDistance.measure(times: leadTimes.map { $0 + 0.06 }, against: lead(leadTimes))
        #expect(measured.map(\.kind) == [.slightlyOff, .slightlyOff, .slightlyOff, .slightlyOff])
        for one in measured {
            #expect(abs(try #require(one.offset) - 0.06) < 1e-9)
        }
    }

    @Test func anExcludedSyllableHasNoPartnerAndTheTimesMayComeInAnyOrder() {
        let measured = MarkerDistance.measure(times: [3.145, 3.11], excluded: [1], against: lead([3.125]))
        #expect(measured.map(\.kind) == [.slightlyOff, .deliberate])
        #expect(measured[1].offset == nil)
    }
}

import Foundation
import Testing
@testable import LockstepCore

/// Tighten lines from a clip to what is heard: the lines get their slides, the tightened sound is made, and the
/// plan and the offline mix play it in place of the recording, sample for sample.
///
/// The song of these tests is six seconds long with a beat every half second, so a sixteenth is 125 ms. The
/// recording is four seconds long and began one second into the song: sample `n` of it is heard on sample
/// `48,000 + n` of the song. It holds three lines:
///
/// - line 1, sound from 500 to 1,100 ms, every syllable 30 ms late,
/// - line 2, sound from 2,000 to 2,600 ms, every syllable 20 ms early,
/// - line 3, sound from 3,200 to 3,600 ms, every syllable on the beat.
@Suite("Clip tightening")
struct ClipTighteningTests {
    /// One millisecond, in samples.
    static let ms = 48
    static let songSamples = 288_000
    /// The sample of the song on which the recording's first sample is heard.
    static let recordingPlace = 48_000
    static let recordingMs = 4_000
    /// Where the three lines have sound, in milliseconds of the recording.
    static let bursts = [500..<1_100, 2_000..<2_600, 3_200..<3_600]
    /// The syllables, in milliseconds of the recording. A sixteenth of the song falls on every 125 ms of it.
    static let syllables = [530, 655, 780, 905, 2_105, 2_230, 2_355, 2_480, 3_250, 3_375, 3_500]

    static let grid = Grid(beats: (0...12).map { Beat(number: $0, time: Double($0) * 0.5) })
    static let recording = Recording(lengthSamples: recordingMs * ms, rawStart: 1)
    static let markers = [recording.id: syllables.map { SyllableMarker(sample: $0 * ms, strength: 12) }]

    /// Quiet room sound that never repeats and is never exactly silent, and a loud tone where the lines are.
    static let sound: [Float] = {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var samples = (0..<recordingMs * ms).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Float(state >> 40) / Float(1 << 24) - 0.5
            return noise == 0 ? 0.0005 : noise * 0.002
        }
        for burst in bursts {
            for index in burst.lowerBound * ms..<burst.upperBound * ms {
                samples[index] += 0.5 * sin(Float(index) * 2 * .pi * 220 / 48_000)
            }
        }
        return samples
    }()

    /// How loud the recording is, as the app measures it: one value for every millisecond.
    static let levels: [UUID: VoiceLevels] = {
        var values = [Float](repeating: -70, count: recordingMs)
        for burst in bursts {
            for index in burst { values[index] = -20 }
        }
        return [recording.id: VoiceLevels(values: values, threshold: -58, hopSamples: ms)]
    }()

    /// A clip that plays one stretch of the recording, moved by `offset` samples.
    static func clip(_ samples: Range<Int> = 0..<recordingMs * ms, offset: Int = 0, gainDb: Double = 0) -> Clip {
        Clip(
            segments: [Segment(
                recordingID: recording.id,
                inSample: samples.lowerBound,
                outSample: samples.upperBound,
                offsetSamples: offset
            )],
            gainDb: gainDb
        )
    }

    /// A project with one track that holds these clips, each with its lines tightened or not.
    static func project(_ clips: [Clip], tightenLines: Bool = true) -> Project {
        Project(
            songLengthSamples: songSamples,
            grid: grid,
            tracks: [Track(name: "Track 1", clips: clips.map { clip in
                var clip = clip
                clip.tighten = tightenLines ? .lines : .off
                return clip
            })],
            recordings: [recording]
        )
    }

    /// What the app does for every clip of a track with Tighten lines on: makes the tightened sound of each
    /// segment, keeps it with the recordings' samples under an id of its own, and notes the id in the lookup.
    static func tighten(
        _ project: Project,
        settings: TightenSettings = TightenSettings()
    ) throws -> (sounds: [UUID: [Float]], lookup: TightenedSounds, lines: [UUID: [[ClipTightening.Line]]]) {
        var sounds = [recording.id: sound]
        var lookup = TightenedSounds()
        var lines: [UUID: [[ClipTightening.Line]]] = [:]
        for clip in project.tracks.flatMap(\.clips) {
            let inputs = try #require(ClipTightening.Inputs(clip: clip, in: project, markers: markers, settings: settings, voices: .none))
            let made = ClipTightening.render(inputs, levels: levels, recordings: [recording.id: sound])
            lines[clip.id] = made.map(\.lines)
            for (index, segment) in made.enumerated() {
                guard let samples = segment.samples else { continue }
                let id = UUID()
                sounds[id] = samples
                lookup.set(
                    id, for: clip.segments[index], at: index, of: clip.id,
                    lead: segment.leadSamples, tail: segment.tailSamples, madeFrom: .recordings
                )
            }
        }
        return (sounds, lookup, lines)
    }

    /// The clips of a project as one row of samples, without fades at clip edges.
    static func row(
        _ project: Project,
        sounds: [UUID: [Float]],
        tightened: TightenedSounds = .none,
        from first: Int = 0,
        to end: Int? = nil
    ) -> [Float] {
        OfflineMix.render(
            project, from: first, to: end, recordings: sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, tightened: tightened, voices: .none
        )
    }

    @Test("Each line gets the slide that puts its first syllable on the beat")
    func linesGetTheirSlides() throws {
        let clip = Self.clip()
        let inputs = try #require(ClipTightening.Inputs(clip: clip, in: Self.project([clip]), markers: Self.markers, voices: .none))
        let lines = ClipTightening.lines(of: inputs, levels: Self.levels)
        try #require(lines.count == 1 && lines[0].count == 3)
        // 30 ms late slides about 30 ms earlier, 20 ms early about 20 ms later, on the beat stays.
        #expect(abs(lines[0][0].shiftMs + 30) <= 1)
        #expect(abs(lines[0][1].shiftMs - 20) <= 1)
        #expect(lines[0][2].shiftSamples == 0)
        // Where each line starts in the song: 10 ms before its sound, one second after the recording's start.
        #expect(abs(lines[0][0].songStart - 1.490) < 1e-9)
        #expect(abs(lines[0][1].songStart - 2.990) < 1e-9)
        #expect(abs(lines[0][2].songStart - 4.190) < 1e-9)
    }

    @Test("The first syllable of a line decides its slide, whatever the others say")
    func theFirstSyllableDecidesTheSlide() throws {
        // The first line's first syllable is 45 ms late now, and its other three are still 30 ms late. The
        // best fit of the four would be about 30 ms earlier. The line slides 45 ms earlier.
        var syllables = Self.syllables
        syllables[0] = 545
        let markers = [Self.recording.id: syllables.map { SyllableMarker(sample: $0 * Self.ms, strength: 12) }]
        let clip = Self.clip()
        let inputs = try #require(ClipTightening.Inputs(clip: clip, in: Self.project([clip]), markers: markers, voices: .none))
        let lines = ClipTightening.lines(of: inputs, levels: Self.levels)
        #expect(lines[0][0].shiftSamples == -45 * Self.ms)
        #expect(lines[0][1].shiftSamples == 20 * Self.ms)
        #expect(lines[0][2].shiftSamples == 0)
    }

    @Test("A syllable Max excluded does not count as the first, and a line with none left stays")
    func excludedSyllablesDoNotCount() throws {
        var syllables = Self.syllables
        syllables[0] = 545
        let markers = [Self.recording.id: syllables.map { SyllableMarker(sample: $0 * Self.ms, strength: 12) }]
        var recording = Self.recording
        // The first line's first syllable is excluded, so its second one, 30 ms late, is the first that
        // counts. Every syllable of the second line is excluded: nothing says where it belongs.
        recording.excludedMarkers = [545, 2_105, 2_230, 2_355, 2_480].map { $0 * Self.ms }
        var project = Self.project([Self.clip()])
        project.recordings = [recording]
        let inputs = try #require(ClipTightening.Inputs(clip: project.tracks[0].clips[0], in: project, markers: markers, voices: .none))
        let lines = ClipTightening.lines(of: inputs, levels: Self.levels)
        #expect(lines[0][0].shiftSamples == -30 * Self.ms)
        #expect(lines[0][1].shiftSamples == 0)
    }

    @Test("A line slides the strength's share of the way: not at all at 0 %, half at 50 %, all of it at 100 %")
    func theStrengthIsAShareOfTheSlide() throws {
        let clip = Self.clip()
        let project = Self.project([clip])
        func slides(lineStrength: Double) throws -> [Int] {
            let inputs = try #require(ClipTightening.Inputs(
                clip: clip, in: project, markers: Self.markers, lineStrength: lineStrength, voices: .none
            ))
            return ClipTightening.lines(of: inputs, levels: Self.levels)[0].map(\.shiftSamples)
        }
        // The first line is 30 ms late, the second 20 ms early and the third on the beat.
        #expect(try slides(lineStrength: 1) == [-30 * Self.ms, 20 * Self.ms, 0])
        #expect(try slides(lineStrength: 0.5) == [-15 * Self.ms, 10 * Self.ms, 0])
        #expect(try slides(lineStrength: 0) == [0, 0, 0])
        // With nothing sliding there is no sound to make.
        let still = try #require(ClipTightening.Inputs(clip: clip, in: project, markers: Self.markers, lineStrength: 0, voices: .none))
        #expect(ClipTightening.render(still, levels: Self.levels, recordings: [Self.recording.id: Self.sound])[0].samples == nil)
    }

    @Test("The strength is counted before the limit: half strength is half of the real distance")
    func theLimitIsCountedAfterTheStrength() throws {
        // The first line's first syllable is 60 ms late, and a line may slide 40 ms at most.
        var syllables = Self.syllables
        syllables[0] = 560
        let markers = [Self.recording.id: syllables.map { SyllableMarker(sample: $0 * Self.ms, strength: 12) }]
        let clip = Self.clip()
        let project = Self.project([clip])
        func firstSlide(lineStrength: Double) throws -> Int {
            let inputs = try #require(ClipTightening.Inputs(
                clip: clip, in: project, markers: markers, settings: TightenSettings(maxLineShiftMs: 40),
                lineStrength: lineStrength, voices: .none
            ))
            return ClipTightening.lines(of: inputs, levels: Self.levels)[0][0].shiftSamples
        }
        #expect(try firstSlide(lineStrength: 1) == -40 * Self.ms)
        #expect(try firstSlide(lineStrength: 0.5) == -30 * Self.ms)
    }

    @Test("A clip's own choice decides what its inputs ask for: nothing with Off, the slide with Lines, both with All")
    func theClipsChoiceDecidesItsInputs() throws {
        func inputs(_ tighten: ClipTighten, strength: Double, stretch: Bool = false) throws -> ClipTightening.Inputs {
            var clip = Self.clip()
            clip.tighten = tighten
            clip.strength = strength
            clip.stretch = stretch
            return try #require(ClipTightening.Inputs(
                correcting: clip, in: Self.project([clip]), markers: Self.markers, settings: TightenSettings(maxStretchPercent: 25), voices: .none
            ))
        }
        let off = try inputs(.off, strength: 0.6)
        #expect(off.lineStrength == 0 && off.strength == 0)
        let lines = try inputs(.lines, strength: 0.6)
        #expect(lines.lineStrength == 0.6 && lines.strength == 0)
        let all = try inputs(.all, strength: 0.6)
        #expect(all.lineStrength == 0.6 && all.strength == 0.6)
        // The voice is stretched only with All and Stretch on. Everywhere else the limit is 0.
        #expect(all.settings.maxStretchPercent == 0)
        #expect(try inputs(.all, strength: 0.6, stretch: true).settings.maxStretchPercent == 25)
        #expect(try inputs(.lines, strength: 0.6, stretch: true).settings.maxStretchPercent == 0)
    }

    @Test("With After the lines are heard at their new places, and with Before the clip is as recorded")
    func tightenedSoundIsHeardInPlaceOfTheRecording() throws {
        let project = Self.project([Self.clip()])
        let made = try Self.tighten(project)
        let lines = try #require(made.lines[project.tracks[0].clips[0].id]?.first)
        #expect(made.lookup.sounds.count == 1)

        // Before: no lookup. The row is the recording at its place, sample for sample.
        let before = Self.row(project, sounds: made.sounds)
        #expect(before[Self.recordingPlace...].prefix(Self.sound.count).elementsEqual(Self.sound))

        // After: every sample of every line is there, moved by the line's slide and otherwise untouched.
        let after = Self.row(project, sounds: made.sounds, tightened: made.lookup)
        #expect(after.count == before.count)
        for line in lines {
            let from = Self.recordingPlace + line.line.startSample + line.shiftSamples
            #expect(after[from..<from + line.line.lengthSamples].elementsEqual(
                Self.sound[line.line.startSample..<line.line.endSample]
            ))
        }
        // The line that stays, and everything from 10 ms after the line before it, is as recorded.
        let untouched = Self.recordingPlace + lines[1].line.endSample + lines[1].shiftSamples + 480
        #expect(after[untouched...] == before[untouched...])
        // Nothing sounds before or after the clip's own place.
        #expect(after[..<Self.recordingPlace].allSatisfy { $0 == 0 })
        #expect(after[(Self.recordingPlace + Self.sound.count)...].allSatisfy { $0 == 0 })
        // And the two really differ where the first line was moved.
        #expect(after != before)
    }

    @Test("A clip with its tightening off is played as recorded, whatever tightened sounds there are")
    func clipSwitchedOffPlaysTheRecording() throws {
        let made = try Self.tighten(Self.project([Self.clip()]))
        var off = Self.project([Self.clip()], tightenLines: false)
        // The same clip, so the lookup would fit.
        off.tracks[0].clips[0].id = try #require(made.lookup.sounds.keys.first?.clipID)
        #expect(Self.row(off, sounds: made.sounds, tightened: made.lookup) == Self.row(off, sounds: made.sounds))
    }

    @Test("A tightened piece differs from the recorded one only in which sound it reads, and from which sample")
    func piecesKeepPlaceLengthVolumeAndFades() throws {
        // A clip cut at both ends, turned up, with playback starting inside it and ending before its end.
        let project = Self.project([Self.clip(12_000..<180_000, gainDb: 3)])
        let made = try Self.tighten(project)
        let raw = try #require(project.clipPlaybackPlan(from: 70_000, to: 200_000, voices: .none).first)
        let tight = try #require(project.clipPlaybackPlan(from: 70_000, to: 200_000, tightened: made.lookup, voices: .none).first)
        let stand = try #require(made.lookup.sounds.values.first)

        #expect(tight.recordingID == stand.id)
        #expect(raw.recordingID == Self.recording.id)
        // The segment starts on sample 60,000 of the song, so playback from 70,000 is 10,000 samples into it:
        // sample 22,000 of the recording, and sample 10,000 of the tightened sound.
        #expect(raw.offset == 22_000)
        #expect(tight.offset == 10_000)
        var same = tight
        same.recordingID = raw.recordingID
        same.offset = raw.offset
        #expect(same == raw)
        #expect(raw.gainDb == 3 && raw.segmentBefore == 10_000 && raw.segmentAfter == 28_000)
    }

    @Test("Any stretch of a tightened clip is that stretch of the whole, also when it starts inside a moved line")
    func aStretchIsPartOfTheWhole() throws {
        let project = Self.project([Self.clip(12_000..<180_000)])
        let made = try Self.tighten(project)
        let whole = Self.row(project, sounds: made.sounds, tightened: made.lookup)
        // From inside the first line, which was moved, to inside the second.
        let part = Self.row(project, sounds: made.sounds, tightened: made.lookup, from: 85_000, to: 160_000)
        #expect(part.elementsEqual(whole[85_000..<160_000]))
    }

    @Test("A tightened sound made before a cut is not played in place of the part that is there now")
    func aSoundMadeBeforeACutIsNotUsed() throws {
        let uncut = Self.project([Self.clip()])
        let made = try Self.tighten(uncut)
        var cut = uncut
        cut.tracks[0].clips[0].segments[0].inSample = 12_000
        // The old sound is 12,000 samples longer than the part and starts earlier. Used, it would play the
        // wrong samples. It is passed over, and the part is heard as recorded until its own sound is made.
        #expect(Self.row(cut, sounds: made.sounds, tightened: made.lookup) == Self.row(cut, sounds: made.sounds))
    }

    @Test("Two clips that play the same recording at different places each get their own tightened sound")
    func theLookupIsPerClip() throws {
        // The second clip plays the same recording 60 ms later, so its first line is 90 ms late: further than
        // a line may slide, and nearer to the sub-beat after it.
        let project = Self.project([Self.clip(0..<96_000), Self.clip(0..<96_000, offset: 96_000 + 60 * Self.ms)])
        let made = try Self.tighten(project)
        let first = try #require(made.lines[project.tracks[0].clips[0].id]?.first?.first)
        let second = try #require(made.lines[project.tracks[0].clips[1].id]?.first?.first)
        #expect(abs(first.shiftMs + 30) <= 1)
        #expect(abs(second.shiftMs - 35) <= 1)
        #expect(made.lookup.sounds.count == 2)
        #expect(Set(made.lookup.sounds.values.map(\.id)).count == 2)

        let after = Self.row(project, sounds: made.sounds, tightened: made.lookup)
        for (line, place) in [(first, Self.recordingPlace), (second, Self.recordingPlace + 96_000 + 60 * Self.ms)] {
            let from = place + line.line.startSample + line.shiftSamples
            #expect(after[from..<from + line.line.lengthSamples].elementsEqual(
                Self.sound[line.line.startSample..<line.line.endSample]
            ))
        }
    }

    @Test("The inputs change with what moves the lines, and not with what only changes the volume")
    func inputsSayWhenToMakeTheSoundAgain() throws {
        let clip = Self.clip()
        let project = Self.project([clip])
        let inputs = try #require(ClipTightening.Inputs(clip: clip, in: project, markers: Self.markers, voices: .none))
        func made(_ change: (inout Clip, inout Project) -> Void) -> ClipTightening.Inputs? {
            var changedClip = clip
            var changedProject = project
            change(&changedClip, &changedProject)
            return ClipTightening.Inputs(clip: changedClip, in: changedProject, markers: Self.markers, voices: .none)
        }

        // The same again, a volume, a name, a mute: the sound that was made is still right.
        #expect(made { _, _ in } == inputs)
        #expect(made { clip, _ in clip.gainDb = 6; clip.segments[0].gainDb = -2; clip.name = "Verse"; clip.muted = true } == inputs)
        // The clip's place, a cut, the measured delay, an excluded syllable, the beats, a setting, the markers.
        #expect(made { clip, _ in clip.segments[0].offsetSamples = 480 } != inputs)
        #expect(made { clip, _ in clip.segments[0].outSample -= 4_800 } != inputs)
        #expect(made { _, project in project.recordings[0].delay = 0.012 } != inputs)
        #expect(made { _, project in project.recordings[0].excludedMarkers = [530 * Self.ms] } != inputs)
        #expect(made { _, project in project.grid?.beats[4].time += 0.01 } != inputs)
        #expect(ClipTightening.Inputs(
            clip: clip, in: project, markers: Self.markers, settings: TightenSettings(maxLineShiftMs: 40), voices: .none
        ) != inputs)
        #expect(ClipTightening.Inputs(clip: clip, in: project, markers: [:], voices: .none) != inputs)
        // Before the beats are found there is nothing to tighten against.
        #expect(made { _, project in project.grid = nil } == nil)
    }

    @Test("A line slides no further than the setting allows, and never so far that two lines could meet")
    func theLimitOnTheSlide() throws {
        #expect(TightenSettings().maxShiftSamples == 80 * Self.ms)
        // A pause of 150 ms leaves 90 ms after the margins and crossfades, shared by two lines.
        #expect(TightenSettings(linePauseMs: 150).maxShiftSamples == 45 * Self.ms)
        #expect(TightenSettings(linePauseMs: 40).maxShiftSamples == 0)
        #expect(TightenSettings(maxLineShiftMs: 0).maxShiftSamples == 0)

        // With the limit at 10 ms, the line that is 30 ms late slides as far as it may and no further. (Of
        // slides that fit within half a millisecond of each other the smallest is chosen, so 9.5 ms is as good.)
        let clip = Self.clip()
        let inputs = try #require(ClipTightening.Inputs(
            clip: clip, in: Self.project([clip]), markers: Self.markers, settings: TightenSettings(maxLineShiftMs: 10), voices: .none
        ))
        let lines = ClipTightening.lines(of: inputs, levels: Self.levels)
        #expect((-10 * Self.ms ... -9 * Self.ms).contains(lines[0][0].shiftSamples))
        // With the limit at 0 nothing moves, and no sound is made at all.
        let still = try #require(ClipTightening.Inputs(
            clip: clip, in: Self.project([clip]), markers: Self.markers, settings: TightenSettings(maxLineShiftMs: 0), voices: .none
        ))
        let made = ClipTightening.render(still, levels: Self.levels, recordings: [Self.recording.id: Self.sound])
        #expect(made.allSatisfy { $0.samples == nil })
    }

    @Test("A clip sent to DaVinci is the tightened clip")
    func theExportIsTightened() throws {
        let project = Self.project([Self.clip(12_000..<180_000)])
        let clipID = project.tracks[0].clips[0].id
        let made = try Self.tighten(project)
        let export = try #require(ClipExporter.export(
            clipID, in: project, recordings: made.sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, tightened: made.lookup, voices: .none
        ))
        let raw = try #require(ClipExporter.export(
            clipID, in: project, recordings: made.sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 0, voices: .none
        ))
        // The same place on the Resolve timeline and the same length, with or without tightening.
        #expect(export.timecode == raw.timecode)
        #expect(export.paddingSamples == raw.paddingSamples)
        #expect(export.samples.count == raw.samples.count)
        // The clip's sound in the file is what plays with After on.
        let after = Self.row(project, sounds: made.sounds, tightened: made.lookup)
        let first = try #require(ClipExporter.startSample(of: clipID, in: project, voices: .none))
        #expect(export.samples[export.paddingSamples..<export.paddingSamples + export.clipSamples]
            .elementsEqual(after[first..<first + export.clipSamples]))
        #expect(export.samples != raw.samples)
    }
}

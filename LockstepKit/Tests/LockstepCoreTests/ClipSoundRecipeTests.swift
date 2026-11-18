import Foundation
import Testing
@testable import LockstepCore

/// The answer of a call that changes what it is called on. Such a call cannot stand inside `#expect` itself.
private func answer<Answer>(_ change: () -> Answer) -> Answer {
    change()
}

/// A twenty-second song with two empty tracks and a beat every half second.
private func song() -> Project {
    var project = Project(
        songLengthSamples: 960_000,
        grid: Grid(beats: (0..<40).map { Beat(number: $0, time: Double($0) * 0.5) })
    )
    project.addTrack()
    return project
}

/// Records a clip the way the app does: a new recording whose clip begins `start` seconds into the song and is
/// `seconds` long. Returns the id of the clip.
@discardableResult
private func record(_ start: Double, _ seconds: Double = 1, in project: inout Project, track: Int = 0) -> UUID {
    let recording = Recording(lengthSamples: Int((seconds * Lockstep.sampleRate).rounded()), rawStart: start)
    return project.addRecording(recording, samples: 0..<recording.lengthSamples, asClipOn: project.tracks[track].id, voices: .none)!
}

private let rapLead = SoundPreset.builtIn[0].sound
private let sungLead = SoundPreset.builtIn[3].sound

@Suite("The recipe of a clip's finished sound")
struct ClipSoundRecipeTests {
    private func recipe(
        of clipID: UUID,
        in project: Project,
        tightened: TightenedSounds = .none,
        edgeFadeMs: Double = 5,
        peaks: RecordingPeak = Clip.unknownPeaks,
        grid: SubBeatGrid = .sixteenths,
        heardSample: ((UUID, Int) -> Int?)? = nil
    ) -> ClipSoundRecipe? {
        project.clip(clipID).flatMap {
            ClipSoundRecipe(
                of: $0, in: project, tightened: tightened, edgeFadeMs: edgeFadeMs, peaks: peaks, grid: grid,
                heardSample: heardSample, voices: .none
            )
        }
    }

    /// Changes one clip of a project in place.
    private func change(_ clipID: UUID, in project: inout Project, _ change: (inout Clip) -> Void) {
        for track in project.tracks.indices {
            for clip in project.tracks[track].clips.indices where project.tracks[track].clips[clip].id == clipID {
                change(&project.tracks[track].clips[clip])
            }
        }
    }

    // MARK: Whether a clip needs a finished sound

    @Test func aClipWithNoSoundOnItsTrackAndNoEffectNeedsNone() {
        var project = song()
        let clip = record(2, in: &project)
        #expect(recipe(of: clip, in: project) == nil)
        // Its own knobs make no sound while the track has none.
        project.setClips([clip], knob: .space, to: 0.8)
        #expect(recipe(of: clip, in: project) == nil)
        // A Sound on another track is not this clip's.
        project.setTrack(project.tracks[1].id, sound: rapLead)
        #expect(recipe(of: clip, in: project) == nil)
    }

    @Test func aClipOnATrackWithASoundHasTheChainOfItsTrackWithItsOwnKnobs() throws {
        var project = song()
        let clip = record(2, in: &project)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        change(clip, in: &project) {
            $0.gainDb = 3
            $0.normalizeGainDb = -4
        }
        project.setClips([clip], knob: .warmth, to: 0.9)

        let made = try #require(recipe(of: clip, in: project))
        var knobs = rapLead.knobs
        knobs.warmth = 0.9
        #expect(made.chain == SoundCharacter.rapLead.parameters(knobs))
        // The clip's own volume comes after the chain. What Normalize set comes before it.
        #expect(made.clipGainDb == 3)
        #expect(made.dry.gainDb == -4)
        #expect(made.dry.fadeSamples == 240)
        #expect(made.dry.tightenedIDs == [nil])
        #expect(made.effects.isEmpty)
        // Nothing in a rap lead follows the beats.
        #expect(made.beats.isEmpty)
        #expect(made.perBeat == 4)
    }

    @Test func aClipWithAnEffectHasARecipeAlsoWithoutASoundAndTheChainIsSkipped() throws {
        var project = song()
        let clip = record(2, in: &project)
        let effect = ClipEffect(kind: .thick, levelDb: -9)
        change(clip, in: &project) { $0.effects = [effect] }

        let made = try #require(recipe(of: clip, in: project))
        #expect(made.chain == nil)
        #expect(made.effects == [ClipSoundRecipe.HeardEffect(id: effect.id, kind: .thick, levelDb: -9)])
        #expect(made.beats.isEmpty)
    }

    @Test func theVolumeBeforeTheChainIsHeldBackByTheSafeLimitWithoutTheClipsOwnVolume() throws {
        var project = song()
        let clip = record(2, in: &project)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        change(clip, in: &project) {
            $0.gainDb = 6
            $0.normalizeGainDb = 10
        }
        // The highest sample is at -6 dBFS, so Normalize's 10 dB are held at 5: up to -1 dBFS.
        let made = try #require(recipe(of: clip, in: project, peaks: { _, _ in 0.501187 }))
        #expect(abs(made.dry.gainDb - 5) < 0.001)
        #expect(made.clipGainDb == 6)
    }

    // MARK: What makes the sound again

    @Test func aClipThatWasOnlyMovedHasTheSameRecipe() throws {
        var project = song()
        let clip = record(2, in: &project)
        let other = record(8, in: &project)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        project.setTrack(project.tracks[1].id, sound: rapLead)
        let before = try #require(recipe(of: clip, in: project))

        // Along the song.
        project.moveClips([clip], bySamples: 48_000 * 3 + 17, trackSteps: 0, voices: .none)
        #expect(recipe(of: clip, in: project) == before)
        // To another track with the same Sound.
        project.moveClips([clip], bySamples: 0, trackSteps: 1, voices: .none)
        #expect(project.tracks[1].clips.map(\.id) == [clip])
        #expect(recipe(of: clip, in: project) == before)
        // And nothing that happens to another clip changes it.
        project.removeClips([other])
        #expect(recipe(of: clip, in: project) == before)
        // A copy is made from the same recipe too.
        let copy = try #require(answer { project.paste(project.copyClips([clip]), onTrack: project.tracks[1].id, atSample: 48_000 * 12, voices: .none) }.first)
        #expect(recipe(of: copy.id, in: project) == before)
    }

    @Test func aJoinedClipThatWasOnlyMovedHasTheSameRecipeAndOneWhosePartsLieDifferentlyDoesNot() throws {
        var project = song()
        let first = record(2, in: &project)
        let second = record(4, in: &project)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        let joined = try #require(answer { project.joinClips([first, second], voices: .none) })
        let before = try #require(recipe(of: joined, in: project))
        #expect(before.dry.segments.count == 2)

        project.moveClips([joined], bySamples: 48_000 * 5, trackSteps: 0, voices: .none)
        #expect(recipe(of: joined, in: project) == before)

        // The second part a little later against the first: another dry sound.
        change(joined, in: &project) { $0.segments[1].offsetSamples += 480 }
        #expect(recipe(of: joined, in: project) != before)
    }

    @Test func aKnobTheVolumeACutAndTheFadeEachChangeTheRecipe() throws {
        var project = song()
        let clip = record(2, 2, in: &project)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        let before = try #require(recipe(of: clip, in: project))

        var turned = project
        turned.setClips([clip], knob: .space, to: 0.5)
        #expect(recipe(of: clip, in: turned) != before)
        #expect(recipe(of: clip, in: turned)?.dry == before.dry)

        var trackTurned = project
        var knobs = rapLead.knobs
        knobs.tone = 0.9
        trackTurned.setTrack(project.tracks[0].id, knobs: knobs)
        #expect(recipe(of: clip, in: trackTurned) != before)

        var louder = project
        louder.setClips([clip], gainDb: 2)
        #expect(recipe(of: clip, in: louder) != before)
        #expect(recipe(of: clip, in: louder)?.dry == before.dry)

        var cut = project
        _ = try #require(answer { cut.splitClip(clip, at: 3, voices: .none) })
        #expect(recipe(of: clip, in: cut) != before)

        #expect(recipe(of: clip, in: project, edgeFadeMs: 10) != before)

        var other = project
        other.setTrack(project.tracks[0].id, sound: sungLead)
        #expect(recipe(of: clip, in: other) != before)

        var none = project
        none.setTrack(project.tracks[0].id, sound: nil)
        #expect(recipe(of: clip, in: none) == nil)
    }

    @Test func aCorrectionChangesTheRecipeThroughTheTightenedSoundThatStandsIn() throws {
        var project = song()
        let clip = record(2, in: &project)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        let before = try #require(recipe(of: clip, in: project))

        project.setClips([clip], tighten: .lines)
        let segment = try #require(project.clip(clip)?.segments.first)
        // Corrected, but its tightened sound is not made yet: the dry sound is still the recording.
        #expect(recipe(of: clip, in: project)?.dry == before.dry)

        var tightened = TightenedSounds()
        let firstID = UUID()
        tightened.set(firstID, for: segment, at: 0, of: clip, madeFrom: .recordings)
        let corrected = try #require(recipe(of: clip, in: project, tightened: tightened))
        #expect(corrected.dry.tightenedIDs == [firstID])
        #expect(corrected != before)

        // Corrected anew, for instance at another strength: another sound stands in.
        tightened.set(UUID(), for: segment, at: 0, of: clip, madeFrom: .recordings)
        #expect(recipe(of: clip, in: project, tightened: tightened) != corrected)

        // Off again: the tightened sound that is still there does not count.
        project.setClips([clip], tighten: .off)
        #expect(recipe(of: clip, in: project, tightened: tightened) == before)
    }

    // MARK: The beats

    @Test func aSoundWithAnEchoHoldsTheBeatsAroundTheClipAsSamplesOfTheDrySound() throws {
        var project = song()
        // From 2.1 s to 3.1 s. The beats are at every half second.
        let clip = record(2.1, in: &project)
        project.setTrack(project.tracks[0].id, sound: sungLead)

        let made = try #require(recipe(of: clip, in: project))
        #expect(made.chain?.echo?.note == .quarter)
        // The beat before the one the clip starts after, which is 1.5 s: 0.6 s before the first sound.
        #expect(made.beats.first == -0.6 * 48_000)
        #expect(made.beats.contains(-0.1 * 48_000))
        // Two bars and two beats after the beat the clip ends after: 3.0 s and ten more, each half a second.
        #expect(made.beats.count == 14)
        #expect(made.beats.last == (8.0 - 2.1) * 48_000)
        #expect(made.beats == made.beats.sorted())
    }

    @Test func aClipWithAnEchoIsMadeAgainWhenItIsMovedAndWhenTheBeatsChange() throws {
        var project = song()
        let clip = record(2.1, in: &project)
        project.setTrack(project.tracks[0].id, sound: sungLead)
        let before = try #require(recipe(of: clip, in: project))

        var moved = project
        moved.moveClips([clip], bySamples: 4_800, trackSteps: 0, voices: .none)
        let after = try #require(recipe(of: clip, in: moved))
        #expect(after != before)
        #expect(after.dry == before.dry)
        #expect(after.beats.first == before.beats.first.map { $0 - 4_800 })

        var drifted = project
        drifted.grid?.beats[6].time += 0.02
        #expect(recipe(of: clip, in: drifted) != before)

        // With Space at nothing there is no echo, and the beats are left out again.
        var dry = project
        dry.setClips([clip], knob: .space, to: 0)
        #expect(recipe(of: clip, in: dry)?.beats.isEmpty == true)
    }

    @Test func aSongWithoutBeatsGivesAnEchoNoBeats() throws {
        var project = song()
        project.grid = nil
        let clip = record(2.1, in: &project)
        project.setTrack(project.tracks[0].id, sound: sungLead)
        #expect(try #require(recipe(of: clip, in: project)).beats.isEmpty)
    }

    @Test func anEffectThatFollowsTheBeatsBringsThemAndOnlyAStutterBringsTheClipsSubBeats() throws {
        var project = song()
        let clip = record(2.1, in: &project)

        change(clip, in: &project) { $0.effects = [ClipEffect(kind: .echoEighth, levelDb: -6)] }
        let echo = try #require(recipe(of: clip, in: project, grid: .triplets))
        #expect(!echo.beats.isEmpty)
        #expect(echo.perBeat == 4)

        change(clip, in: &project) { $0.effects = [ClipEffect(kind: .stutter)] }
        let stutter = try #require(recipe(of: clip, in: project, grid: .triplets))
        #expect(!stutter.beats.isEmpty)
        #expect(stutter.perBeat == 6)

        change(clip, in: &project) { $0.effects = [ClipEffect(kind: .lowOctave, levelDb: -10)] }
        let double = try #require(recipe(of: clip, in: project, grid: .triplets))
        #expect(double.beats.isEmpty)
        #expect(double.perBeat == 4)
    }

    // MARK: Effects on a stretch

    @Test func anEffectOnAStretchIsPlacedByWhereItsSamplesAreHeardAndLeftOutWhereTheyAreNot() throws {
        var project = song()
        let clip = record(2, in: &project)
        let recording = try #require(project.clip(clip)?.segments.first?.recordingID)
        let whole = ClipEffect(kind: .big, levelDb: -9)
        let word = ClipEffect(kind: .lowFourth, span: ClipSpan(recordingID: recording, inSample: 4_800, outSample: 9_600), levelDb: -8)
        change(clip, in: &project) { $0.effects = [whole, word] }

        // Nobody says where a sample is heard: it is heard where it was recorded.
        #expect(try #require(recipe(of: clip, in: project)).effects == [
            ClipSoundRecipe.HeardEffect(id: whole.id, kind: .big, levelDb: -9),
            ClipSoundRecipe.HeardEffect(id: word.id, kind: .lowFourth, levelDb: -8, span: 4_800..<9_600),
        ])

        // Heard 100 samples later than recorded, as after a correction.
        let made = try #require(recipe(of: clip, in: project, heardSample: { id, sample in
            id == recording ? sample + 100 : nil
        }))
        #expect(made.effects == [
            ClipSoundRecipe.HeardEffect(id: whole.id, kind: .big, levelDb: -9),
            ClipSoundRecipe.HeardEffect(id: word.id, kind: .lowFourth, levelDb: -8, span: 4_900..<9_700),
        ])

        // A clip whose only effect is on a stretch that is not heard needs no finished sound.
        change(clip, in: &project) { $0.effects = [word] }
        #expect(recipe(of: clip, in: project, heardSample: { _, _ in nil }) == nil)
    }

    @Test func aSpanThatReachesToTheClipsLastSampleIsPlacedToTheEndOfTheDrySound() throws {
        var project = song()
        let clip = record(2, in: &project)
        let recording = try #require(project.clip(clip)?.segments.first?.recordingID)
        let id = try #require(answer {
            project.addEffect(clip, kind: .lowOctave, span: ClipSpan(recordingID: recording, inSample: 38_400, outSample: 48_000))
        })
        #expect(try #require(recipe(of: clip, in: project)).effects == [
            ClipSoundRecipe.HeardEffect(id: id, kind: .lowOctave, levelDb: -10, span: 38_400..<48_000),
        ])
    }

    @Test func addingAnEffectAndTurningItsLevelChangeTheRecipeAndMovingTheClipDoesNot() throws {
        var project = song()
        let clip = record(2, in: &project)
        let recording = try #require(project.clip(clip)?.segments.first?.recordingID)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        let plain = try #require(recipe(of: clip, in: project))

        let id = try #require(answer {
            project.addEffect(clip, kind: .lowOctave, span: ClipSpan(recordingID: recording, inSample: 9_600, outSample: 19_200))
        })
        let doubled = try #require(recipe(of: clip, in: project))
        #expect(doubled != plain)
        #expect(doubled.dry == plain.dry)
        #expect(doubled.effects.map(\.span) == [9_600..<19_200])

        var louder = project
        #expect(answer { louder.setEffect(id, of: clip, levelDb: -4) })
        let turned = try #require(recipe(of: clip, in: louder))
        #expect(turned != doubled)
        #expect(turned.effects.map(\.levelDb) == [-4])

        // A double does not follow the beats: moved along the song, the clip has the same recipe.
        var moved = project
        moved.moveClips([clip], bySamples: 48_000 * 3 + 17, trackSteps: 0, voices: .none)
        #expect(recipe(of: clip, in: moved) == doubled)

        var removed = project
        #expect(answer { removed.removeEffect(id, from: clip) })
        #expect(recipe(of: clip, in: removed) == plain)
    }

    @Test func aCorrectionThatMovesTheSyllablesMovesTheEffectsStretchWithThem() throws {
        var project = song()
        let clip = record(2, in: &project)
        let recording = try #require(project.clip(clip)?.segments.first?.recordingID)
        project.addEffect(clip, kind: .lowOctave, span: ClipSpan(recordingID: recording, inSample: 9_600, outSample: 19_200))
        let shown = try #require(project.clip(clip))
        let recorded = try #require(recipe(of: clip, in: project))

        // The correction pulls that word 30 ms earlier.
        let earlier = project.heardSample(of: shown, voices: .none, shift: { _, _ in -1_440 })
        let corrected = try #require(recipe(of: clip, in: project, heardSample: earlier))
        #expect(corrected != recorded)
        #expect(corrected.effects.map(\.span) == [8_160..<17_760])
    }
}
